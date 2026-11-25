#!/usr/bin/env bash
# Exercise the shipped node through its mining routes, as an external miner
# does: block 1's target is the maximum, so nonce 0 mines it.
set -euo pipefail

node_binary="${1:?usage: smoke-lattice-node.sh <lattice-node> <lattice>}"
ctl_binary="${2:?usage: smoke-lattice-node.sh <lattice-node> <lattice>}"

for binary in "$node_binary" "$ctl_binary"; do
    [[ -x "$binary" ]] || {
        echo "artifact smoke requires an executable: $binary" >&2
        exit 1
    }
done
"$ctl_binary" --help >/dev/null
for command in curl jq; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "artifact smoke requires $command" >&2
        exit 1
    }
done

readonly expected_genesis="bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa"
readonly tmp="$(mktemp -d)"
readonly port="$((20000 + RANDOM % 20000))"
readonly rpc_port="$((port + 2))"
readonly node_log="$tmp/node.log"
readonly template_json="$tmp/template.json"
readonly work_json="$tmp/work.json"
readonly health_json="$tmp/health.json"
node_pid=""

is_running() {
    local process_pid="${1:-}"
    [[ -n "$process_pid" ]] || return 1
    kill -0 "$process_pid" 2>/dev/null || return 1
    local state
    state="$(ps -o stat= -p "$process_pid" 2>/dev/null || true)"
    [[ "$state" != *Z* ]]
}

dump_logs() {
    [[ ! -s "$health_json" ]] || {
        echo "last health response:" >&2
        cat "$health_json" >&2
    }
    [[ ! -s "$work_json" ]] || {
        echo "work response:" >&2
        cat "$work_json" >&2
    }
    [[ ! -s "$node_log" ]] || {
        echo "node log:" >&2
        cat "$node_log" >&2
    }
}

fail() {
    echo "$*" >&2
    dump_logs
    exit 1
}

stop_process_for_cleanup() {
    local process_pid="${1:-}"
    [[ -n "$process_pid" ]] || return 0
    if is_running "$process_pid"; then
        kill -TERM "$process_pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 20; attempt += 1)); do
            is_running "$process_pid" || break
            sleep 0.1
        done
        is_running "$process_pid" && kill -KILL "$process_pid" 2>/dev/null || true
    fi
    wait "$process_pid" 2>/dev/null || true
}

cleanup() {
    stop_process_for_cleanup "$node_pid"
    rm -rf "$tmp"
}
trap cleanup EXIT

# Isolated: with the shipped bootstrap peers the smoke would gossip its mined
# block to the public Nexus and fork-choose against whatever the network holds.
start_node() {
    "$node_binary" \
        --data-directory "$tmp/data" \
        --identity-key "$tmp/process.key" \
        --listen-port "$port" \
        --rpc-port "$rpc_port" \
        --no-default-peers \
        >>"$node_log" 2>&1 &
    node_pid=$!
}

stop_node() {
    local status=0

    if is_running "$node_pid"; then
        kill -TERM "$node_pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 20; attempt += 1)); do
            is_running "$node_pid" || break
            sleep 0.1
        done
    fi
    if is_running "$node_pid"; then
        kill -KILL "$node_pid" 2>/dev/null || true
    fi
    if wait "$node_pid"; then
        status=0
    else
        status=$?
    fi
    node_pid=""

    if ((status != 0)); then
        fail "node did not shut down cleanly (status $status)"
    fi
}

status_matches() {
    local expected_height="$1"
    local expected_tip="$2"

    jq -e \
        --arg genesis "$expected_genesis" \
        --arg tip "$expected_tip" \
        --arg height "$expected_height" \
        '
            .phase == "active"
            and .chainPath == ["Nexus"]
            and .nexusGenesisCID == $genesis
            and .tipCID == $tip
            and .height == $height
        ' "$health_json" >/dev/null
}

await_status() {
    local expected_height="$1"
    local expected_tip="$2"
    local label="$3"

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if curl --fail --silent --show-error --max-time 1 \
            "http://127.0.0.1:$rpc_port/health" >"$health_json" 2>/dev/null \
            && status_matches "$expected_height" "$expected_tip" 2>/dev/null; then
            return
        fi
        is_running "$node_pid" || fail "node exited before $label"
        sleep 0.1
    done

    fail "node did not reach $label"
}

mine_block_one() {
    local cookie
    cookie="$(cat "$tmp/data/.cookie")"
    curl --fail --silent --show-error --max-time 30 --user "$cookie" \
        --header 'Content-Type: application/json' --data '{"recipients":[]}' \
        "http://127.0.0.1:$rpc_port/mining/templates" >"$template_json" \
        || fail "the node served no mining template"
    local work_id
    work_id="$(jq -er '.workID' "$template_json")" || fail "the template has no workID"
    curl --fail --silent --show-error --max-time 30 --user "$cookie" \
        --header 'Content-Type: application/json' \
        --data "$(jq -cn --arg work "$work_id" '{workID: $work, nonce: 0}')" \
        "http://127.0.0.1:$rpc_port/mining/work" >"$work_json" \
        || fail "the node refused the submitted work"
    jq -e \
        --arg genesis "$expected_genesis" \
        '
            .accepted == true
            and .disposition == "canonicalized"
            and (.tipCID | type == "string" and length > 0)
            and .tipCID != $genesis
        ' "$work_json" >/dev/null \
        || fail "the node did not canonicalize the mined block"
}

start_node
await_status 0 "$expected_genesis" "active Nexus genesis"
# The operator port needs the cookie the node wrote (bitcoind-style).
[[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$rpc_port/status")" == 401 ]] \
    || fail "operator /status answered without the cookie"
[[ "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "$(cat "$tmp/data/.cookie")" "http://127.0.0.1:$rpc_port/status")" == 200 ]] \
    || fail "operator /status refused the node's cookie"
mine_block_one

if ! mined_tip="$(jq -er '.tipCID' "$work_json")"; then
    fail "the work response has no tip CID"
fi
await_status 1 "$mined_tip" "mined Nexus tip"

stop_node
start_node
await_status 1 "$mined_tip" "recovered Nexus tip"
stop_node

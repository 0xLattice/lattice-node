#!/usr/bin/env bash
# Exercise the shipped node, coordinator, and worker as one mining pipeline.
set -euo pipefail

node_binary="${1:?usage: smoke-lattice-node.sh <lattice-node> <lattice-mining-coordinator> <lattice-miner>}"
coordinator_binary="${2:?usage: smoke-lattice-node.sh <lattice-node> <lattice-mining-coordinator> <lattice-miner>}"
miner_binary="${3:?usage: smoke-lattice-node.sh <lattice-node> <lattice-mining-coordinator> <lattice-miner>}"

for binary in "$node_binary" "$coordinator_binary" "$miner_binary"; do
    [[ -x "$binary" ]] || {
        echo "artifact smoke requires an executable: $binary" >&2
        exit 1
    }
done
for command in curl jq; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "artifact smoke requires $command" >&2
        exit 1
    }
done

readonly expected_genesis="bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq"
readonly tmp="$(mktemp -d)"
readonly port="$((20000 + RANDOM % 20000))"
readonly rpc_port="$((port + 2))"
readonly node_log="$tmp/node.log"
readonly coordinator_output="$tmp/coordinator.json"
readonly coordinator_log="$tmp/coordinator.log"
readonly health_json="$tmp/health.json"
node_pid=""
coordinator_pid=""

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
    [[ ! -s "$coordinator_output" ]] || {
        echo "coordinator output:" >&2
        cat "$coordinator_output" >&2
    }
    [[ ! -s "$coordinator_log" ]] || {
        echo "coordinator log:" >&2
        cat "$coordinator_log" >&2
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
    stop_process_for_cleanup "$coordinator_pid"
    stop_process_for_cleanup "$node_pid"
    rm -rf "$tmp"
}
trap cleanup EXIT

start_node() {
    "$node_binary" \
        --data-directory "$tmp/data" \
        --identity-key "$tmp/process.key" \
        --listen-port "$port" \
        --fact-listen-port "$((port + 1))" \
        --rpc-port "$rpc_port" \
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
        --argjson height "$expected_height" \
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

run_coordinator() {
    "$coordinator_binary" \
        --node "http://127.0.0.1:$rpc_port" \
        --worker-executable "$miner_binary" \
        --workers 1 \
        --once \
        --batch-size 1 \
        >"$coordinator_output" 2>"$coordinator_log" &
    coordinator_pid=$!

    for ((attempt = 0; attempt < 200; attempt += 1)); do
        is_running "$coordinator_pid" || break
        sleep 0.1
    done
    if is_running "$coordinator_pid"; then
        kill -TERM "$coordinator_pid" 2>/dev/null || true
        wait "$coordinator_pid" 2>/dev/null || true
        coordinator_pid=""
        fail "mining coordinator did not finish within 20 seconds"
    fi

    local status=0
    if wait "$coordinator_pid"; then
        status=0
    else
        status=$?
    fi
    coordinator_pid=""
    ((status == 0)) || fail "mining coordinator exited with status $status"

    jq -e \
        --arg genesis "$expected_genesis" \
        '
            .result == "submitted"
            and .accepted == true
            and .disposition == "canonicalized"
            and (.tipCID | type == "string" and length > 0)
            and .tipCID != $genesis
        ' "$coordinator_output" >/dev/null \
        || fail "mining coordinator did not report an accepted canonical block"
}

start_node
await_status 0 "$expected_genesis" "active Nexus genesis"
run_coordinator

if ! mined_tip="$(jq -er '.tipCID' "$coordinator_output")"; then
    fail "mining coordinator did not return a tip CID"
fi
await_status 1 "$mined_tip" "mined Nexus tip"

stop_node
start_node
await_status 1 "$mined_tip" "recovered Nexus tip"
stop_node

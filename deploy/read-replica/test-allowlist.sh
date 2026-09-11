#!/usr/bin/env bash
# Asserts the read-replica nginx allowlist boundary: only the bounded GET read
# routes reach the (loopback) node; /v1/status, every write POST, and unknown
# paths get 403. This is the auditor-required public/internal boundary — a
# TESTED part of the config, not prose.
#
# Also asserts the limits: bursts and excess in-flight requests get 429, the
# expensive routes trip before the general budget while block detail stays on
# it, one client's burst does not throttle another, a Fly-Client-IP header from
# a source that is not fly-proxy cannot split one client into many, enough
# distinct clients still hit the server-wide ceiling, and fly's health check is
# never throttled.
#
# Runs the ACTUAL nginx.conf against a stub upstream that stands in for the node
# (returns 200 to any request). nginx and the stub share one network namespace
# so the config's hardcoded `proxy_pass http://127.0.0.1:8080` resolves — exactly
# the production layout (nginx + node co-located on loopback). Portable: needs
# only Docker (no host networking, no host nginx).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_IMAGE="nginx:1.18"
UPSTREAM_IMAGE="python:3-alpine"
PROXY_PORT=8081
CID="bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq"

cleanup() {
  docker rm -f rr-allowlist-nginx rr-allowlist-upstream >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# Stub node in its own netns, publishing the proxy port to the host; the stub
# returns 200 to any GET (so a non-403 proves the request was proxied through).
# /api/slow holds its reply for 3s, so concurrent requests are in flight together.
docker run --rm -d --name rr-allowlist-upstream \
  -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" "$UPSTREAM_IMAGE" \
  python3 -c '
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def _ok(self):
        if self.path.startswith("/api/slow"):
            time.sleep(3)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    do_GET = do_HEAD = do_POST = _ok
    def log_message(self, *a): pass
ThreadingHTTPServer(("127.0.0.1", 8080), H).serve_forever()
' >/dev/null

# nginx shares the stub's netns: its 127.0.0.1:8080 reaches the stub and its
# own listen 8081 is published via the stub container above.
docker run --rm -d --name rr-allowlist-nginx \
  --network "container:rr-allowlist-upstream" \
  -v "$DIR/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" >/dev/null

# Ready means a proxied 200: nginx alone answers 502 until the stub listens.
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/health")" = 200 ] \
    && break || sleep 1
done

fail=0
check() {
  local method="$1" path="$2" want="$3" desc="$4" got
  got=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" \
    --max-time 5 "http://127.0.0.1:$PROXY_PORT$path")
  if [ "$got" = "$want" ]; then
    echo "  ok   $method $path -> $got ($desc)"
  else
    echo "  FAIL $method $path -> $got, wanted $want ($desc)"
    fail=1
  fi
}

echo "== allowed: bounded GET reads reach the node (200) =="
check GET  /health                 200 "health"
check GET  /v1/blocks              200 "recent blocks"
check GET  "/v1/blocks/$CID"       200 "block by cid"
check GET  "/v1/transactions/$CID" 200 "tx by cid"
check GET  "/v1/accounts/$CID"     200 "account"
check GET  /api/chain/children     200 "explorer api"
check GET  /api/block/latest       200 "explorer api"
check GET  "/api/chain/endpoints?chainPath=Nexus/Child" 200 "endpoint discovery"
check GET  /api/block/1/transactions 200 "block transactions"
check GET  /api/block/1/children   200 "block children"

echo "== denied: gated/mutating + writes + unknown get 403 =="
check GET  /v1/status              403 "gated status off the public surface"
check GET  /random                 403 "unknown path"
check GET  /                       403 "root"
check POST /v1/transactions        403 "write POST"
check POST /v1/blocks              403 "POST to an allowlisted read route"
check POST /api/block/latest       403 "POST to /api"
check POST /api/chain/endpoints    403 "POST to endpoint discovery"
check POST /api/block/1/transactions 403 "POST to block transactions"

ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
# lines <text> <sed range>: the selected status lines.
lines() { printf '%s\n' "$1" | sed -n "$2p"; }
# count <text> <code>: how many status lines equal <code>.
count() { printf '%s\n' "$1" | grep -c "^$2\$" || true; }
# The server-wide ceiling is ONE bucket for every request, so a heavy block
# leaves it nearly full. Let it drain before a block that asserts no 429.
drain() { sleep 2; }

# fire <inside|outside> <client-ip> <path> <count> [<client-ip> <path> <count>]...
# Sends every request in ONE curl run, so a burst lands well inside a rate
# window, and prints one status code per line, in order.
#   inside:  from the proxy's own netns. nginx sees loopback, a trusted source
#            like fly-proxy in production, and keys on Fly-Client-IP.
#   outside: from the host through the published port. nginx sees the Docker
#            gateway, an untrusted source, so Fly-Client-IP must be ignored.
fire() {
  local where="$1" args=()
  shift
  while [ "$#" -ge 3 ]; do
    [ "${#args[@]}" -eq 0 ] || args+=(--next)
    args+=(-s --max-time 30 -w '%{http_code}\n' -H "Fly-Client-IP: $1")
    for _ in $(seq 1 "$3"); do
      args+=(-o /dev/null "http://127.0.0.1:$PROXY_PORT$2")
    done
    shift 3
  done
  if [ "$where" = inside ]; then
    docker exec rr-allowlist-nginx curl "${args[@]}"
  else
    curl "${args[@]}"
  fi
}

# Each block below uses its own client addresses, so none spends another's budget.
echo "== rate limits: per client, keyed on Fly-Client-IP from a trusted source =="
got=$(fire inside 198.51.100.1 /api/block/latest 1 198.51.100.1 /v1/blocks 1)
if [ "$(count "$got" 200)" -eq 2 ]; then
  ok "one request succeeds on a general route and on an expensive route"
else
  bad "one request should succeed on both routes, got: $(echo $got)"
fi

got=$(fire inside 198.51.100.2 /api/block/latest 200)
n=$(count "$got" 429)
if [ "$(lines "$got" 1)" = 200 ] && [ "$n" -gt 0 ]; then
  ok "a 200-request burst on a general route gets 429 ($n of 200)"
else
  bad "a 200-request burst on a general route should get 429, got $n"
fi
drain

got=$(fire inside \
  198.51.100.3 /v1/blocks 30 \
  198.51.100.4 "/api/chain/endpoints?chainPath=Nexus/Child" 30 \
  198.51.100.10 "/api/block/1/transactions?limit=100" 30 \
  198.51.100.11 "/v1/blocks/$CID" 30 \
  198.51.100.5 /api/block/latest 30)
list=$(count "$(lines "$got" 1,30)" 429)
endpoints=$(count "$(lines "$got" 31,60)" 429)
blocktxs=$(count "$(lines "$got" 61,90)" 429)
detail=$(count "$(lines "$got" 91,120)" 429)
general=$(count "$(lines "$got" 121,150)" 429)
if [ "$list" -gt 0 ] && [ "$endpoints" -gt 0 ] && [ "$blocktxs" -gt 0 ] \
   && [ "$detail" -eq 0 ] && [ "$general" -eq 0 ]; then
  ok "30 requests trip the expensive routes (429s: list $list, endpoints $endpoints, block txs $blocktxs) but not block detail or a general route"
else
  bad "30 requests should trip only the expensive routes (429s: list $list, endpoints $endpoints, block txs $blocktxs, detail $detail, general $general)"
fi
drain

# A bursts, B sends one, A sends two more: B must pass while A is still limited
# (two, because at most one of A's can land on a refill).
got=$(fire inside \
  198.51.100.6 /v1/blocks 30 \
  198.51.100.7 /v1/blocks 1 \
  198.51.100.6 /v1/blocks 2)
a=$(count "$(lines "$got" 1,30)" 429)
b=$(lines "$got" 31)
a_after=$(count "$(lines "$got" 32,33)" 429)
if [ "$a" -gt 0 ] && [ "$b" = 200 ] && [ "$a_after" -gt 0 ]; then
  ok "client A's burst (429s: $a) leaves client B at 200 while A stays limited"
else
  bad "clients should be limited independently (A burst 429s: $a, B: $b, A after B 429s: $a_after)"
fi

echo "== in-flight limit: per client =="
got=$(docker exec rr-allowlist-nginx sh -c "for i in \$(seq 1 40); do curl -s -o /dev/null --max-time 30 -w '%{http_code}\n' -H 'Fly-Client-IP: 198.51.100.8' http://127.0.0.1:$PROXY_PORT/api/slow & done; wait")
n=$(count "$got" 429)
if [ "$n" -gt 0 ] && [ "$(count "$got" 200)" -gt 0 ]; then
  ok "40 concurrent slow requests from one client: $n get 429, the rest proxy"
else
  bad "40 concurrent slow requests from one client should get some 429 (got $n)"
fi

echo "== server-wide ceiling: bounds total upstream load, not just one client =="
# 500 clients, one request each: every per-client budget is untouched, so a 429
# here can only come from the server-wide bucket.
many=()
for i in $(seq 1 500); do
  many+=("198.18.$((i / 256)).$((i % 256))" /api/block/latest 1)
done
got=$(fire inside "${many[@]}")
n=$(count "$got" 429)
if [ "$n" -gt 0 ] && [ "$(count "$got" 200)" -gt 0 ]; then
  ok "500 clients with one request each: $n get 429 from the server-wide ceiling"
else
  bad "500 single-request clients should hit the server-wide ceiling (429s: $n)"
fi
drain

# Last two blocks: these spend the budget of the host's own address.
echo "== untrusted source: a client-sent Fly-Client-IP does not split the budget =="
spoofed=()
for i in $(seq 1 200); do spoofed+=("203.0.113.$i" /api/block/latest 1); done
got=$(fire outside "${spoofed[@]}")
n=$(count "$got" 429)
if [ "$n" -gt 0 ]; then
  ok "200 requests claiming 200 different Fly-Client-IPs still share one budget ($n got 429)"
else
  bad "200 requests claiming different Fly-Client-IPs from an untrusted source should get 429 (got $n)"
fi

echo "== fly's health check is never throttled =="
# The block above just spent the budget for the host's own address — which is
# where a header-less request falls back, and where every client would land if
# the trusted range were ever wrong. /health must answer anyway, or fly would
# depool the machine under public load.
health_bad=0
for _ in $(seq 1 5); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:$PROXY_PORT/health")
  [ "$code" = 200 ] || health_bad=1
done
if [ "$health_bad" -eq 0 ]; then
  ok "/health still answers 200 with the fallback budget spent"
else
  bad "/health must not be rate limited: it 429'd with the fallback budget spent"
fi

if [ "$fail" -ne 0 ]; then
  echo "ALLOWLIST TEST FAILED"
  exit 1
fi
echo "ALLOWLIST TEST PASSED"

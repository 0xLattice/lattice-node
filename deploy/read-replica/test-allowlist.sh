#!/usr/bin/env bash
# Asserts the read-replica nginx allowlist boundary: only the bounded GET read
# routes reach the (loopback) node; /v1/status, every write POST, and unknown
# paths get 403. This is the auditor-required public/internal boundary — a
# TESTED part of the config, not prose.
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
docker run --rm -d --name rr-allowlist-upstream \
  -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" "$UPSTREAM_IMAGE" \
  python3 -c '
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _ok(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    do_GET = do_HEAD = do_POST = _ok
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 8080), H).serve_forever()
' >/dev/null

# nginx shares the stub's netns: its 127.0.0.1:8080 reaches the stub and its
# own listen 8081 is published via the stub container above.
docker run --rm -d --name rr-allowlist-nginx \
  --network "container:rr-allowlist-upstream" \
  -v "$DIR/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" >/dev/null

for _ in $(seq 1 30); do
  curl -s -o /dev/null "http://127.0.0.1:$PROXY_PORT/health" && break || sleep 1
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

echo "== denied: gated/mutating + writes + unknown get 403 =="
check GET  /v1/status              403 "gated status off the public surface"
check GET  /random                 403 "unknown path"
check GET  /                       403 "root"
check POST /v1/transactions        403 "write POST"
check POST /v1/blocks              403 "POST to an allowlisted read route"
check POST /api/block/latest       403 "POST to /api"

if [ "$fail" -ne 0 ]; then
  echo "ALLOWLIST TEST FAILED"
  exit 1
fi
echo "ALLOWLIST TEST PASSED"

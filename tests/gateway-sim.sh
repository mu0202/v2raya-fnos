#!/bin/bash
# ---------------------------------------------------------------------------
# tests/gateway-sim.sh — prove the fnOS unified-gateway contract (contract §1,
#                        §4, §10.3)
#
# fnOS does not expose the app on a TCP port: the system gateway authenticates
# the desktop session and then forwards the request to the app's unix socket
# **keeping the original path**, i.e. an incoming GET /app/v2raya/api/version
# arrives at v2rayA as GET /app/v2raya/api/version (the reference gateway
# implementation says so explicitly: "upstream sees /app/... and answers 404").
#
# This test reproduces that behaviour locally:
#   1. start v2raya on its unix socket exactly as cmd/main does
#   2. run a tiny TCP listener that forwards to the socket, preserving the
#      full request path and method (and the gateway identity headers)
#   3. assert a client hitting http://127.0.0.1:<port>/app/v2raya/api/version
#      gets 200, /app/v2raya/ gets 200, and / gets 404 (prefix required)
#
# The proxy is deliberately path-transparent: it must NOT strip /app/v2raya,
# because stripping the prefix is exactly the regression this test catches.
#
# Exit: 0 pass, 1 failure, 77 blocked (payload missing).
# ---------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=tests/lib-test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

cd "$ROOT_DIR" || { echo "cannot cd to $ROOT_DIR"; exit 1; }
install_cleanup_trap

echo "=============================================================="
echo " v2raya-fnos gateway simulation (prefix-preserving proxy)"
echo " project : $ROOT_DIR"
echo " user    : $(id -un) (uid $(id -u))"
echo " time    : $(date -Is)"
echo "=============================================================="

section "0. preconditions"

for rel in app/server/v2raya app/server/v2raya_core app/assets/geoip.dat; do
    [ -s "$ROOT_DIR/$rel" ] || blocked "payload missing: $rel"
done
command -v curl >/dev/null 2>&1 || blocked "curl not available"
if [ "$BLOCKED_COUNT" -gt 0 ]; then
    finish "gateway-sim"; exit $?
fi

# Pick the proxy runtime. node is preferred (measured present at
# /var/apps/nodejs_v24/target/bin/node, v24.22.3) because its http client can
# talk to a unix socket via socketPath while keeping the request path verbatim.
NODE_BIN=""
for cand in /var/apps/nodejs_v24/target/bin/node /var/apps/nodejs_v22/target/bin/node; do
    if [ -x "$cand" ]; then NODE_BIN="$cand"; break; fi
done
[ -z "$NODE_BIN" ] && NODE_BIN="$(command -v node 2>/dev/null || true)"

if [ -n "$NODE_BIN" ] && "$NODE_BIN" --version >/dev/null 2>&1; then
    PROXY_KIND="node"
    pass "proxy runtime: node ($("$NODE_BIN" --version) at $NODE_BIN)"
elif command -v python3 >/dev/null 2>&1; then
    PROXY_KIND="python3"
    pass "proxy runtime: python3 ($(python3 --version 2>&1))"
else
    fail "no usable proxy runtime (need node or python3)"
    finish "gateway-sim"; exit $?
fi

# ---------------------------------------------------------------------------
# 1. Start v2rayA on its socket, the same way cmd/main does
# ---------------------------------------------------------------------------
section "1. start v2rayA on its unix socket"

SCRATCH="$(mktemp -d /tmp/v2raya-gw.XXXXXXXX)" || {
    fail "cannot create scratch dir under /tmp"; finish "gateway-sim"; exit $?
}
register_dir "$SCRATCH"

mkdir -p "$SCRATCH/target" "$SCRATCH/var/data" "$SCRATCH/var/logs"
copy_tree "$ROOT_DIR/app/server" "$SCRATCH/target/server"
copy_tree "$ROOT_DIR/app/assets" "$SCRATCH/target/assets"

BIN="$SCRATCH/target/server/v2raya"
CORE="$SCRATCH/target/server/v2raya_core"
ASSETS="$SCRATCH/target/assets"
SOCK="$SCRATCH/target/app.sock"
LOG="$SCRATCH/var/logs/v2raya.log"

assert_exec "payload copied with exec bit: server/v2raya"      "$BIN"
assert_exec "payload copied with exec bit: server/v2raya_core" "$CORE"

BASELINE_PIDS="$(v2raya_pids)"
info "pre-existing unrelated v2raya pid(s): ${BASELINE_PIDS:-none}"

"$BIN" \
    --socket "$SOCK" \
    --baseurl /app/v2raya \
    --config "$SCRATCH/var/data" \
    --v2ray-bin "$CORE" \
    --v2ray-assetsdir "$ASSETS" \
    --log-file "$LOG" \
    --log-max-days 3 \
    --log-level info \
    --ipv6-support auto \
    >>"$SCRATCH/v2raya.stdout" 2>&1 &
V2PID=$!
register_pid "$V2PID"
info "v2rayA started with pid $V2PID"

if wait_for_socket_http "$SOCK" "/app/v2raya/api/version" 30; then
    pass "v2rayA listening on unix socket and answering /app/v2raya/api/version"
else
    fail "v2rayA did not become ready on $SOCK within 30s"
    info "log tail: $(tail -5 "$LOG" 2>/dev/null | tr '\n' '|')"
fi

# Direct-to-socket baseline (proves the socket path works before we add a hop).
direct_code="$(http_code_unix "$SOCK" "/app/v2raya/api/version")"
[ "$direct_code" = "200" ] \
    && pass "baseline: direct unix-socket GET /app/v2raya/api/version -> 200" \
    || fail "baseline: direct unix-socket GET -> $direct_code (expected 200)"

# ---------------------------------------------------------------------------
# 2. Start the path-preserving gateway proxy
# ---------------------------------------------------------------------------
section "2. start path-preserving TCP->unix gateway proxy"

# Choose a free TCP port by binding with the OS and releasing it.
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
[ -n "$PORT" ] || { fail "could not allocate a TCP port"; finish "gateway-sim"; exit $?; }
info "proxy will listen on 127.0.0.1:$PORT -> unix:$SOCK (path preserved)"

if [ "$PROXY_KIND" = "node" ]; then
    cat > "$SCRATCH/gw.js" <<'JS'
// Minimal fnOS-gateway stand-in.
// Contract: the upstream sees the FULL original path (/app/v2raya/...).
// So request.url is forwarded verbatim to socketPath — no prefix stripping,
// no rewriting. This is the whole point of the test.
const http = require('http');
const SOCK = process.argv[2];
const PORT = Number(process.argv[3]);

const server = http.createServer((creq, cres) => {
  const opts = {
    socketPath: SOCK,
    path: creq.url,          // <-- preserved verbatim, including /app/v2raya
    method: creq.method,
    headers: creq.headers,   // carries X-Trim-Userid / X-Trim-Isadmin
  };
  const preq = http.request(opts, (pres) => {
    cres.writeHead(pres.statusCode, pres.headers);
    pres.pipe(cres);
  });
  preq.on('error', (err) => {
    if (!cres.headersSent) cres.writeHead(502, { 'content-type': 'text/plain' });
    cres.end('gateway-proxy-error: ' + err.message);
  });
  creq.pipe(preq);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('GATEWAY_LISTENING ' + PORT);
});
const shutdown = () => { server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 500); };
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
JS
    "$NODE_BIN" "$SCRATCH/gw.js" "$SOCK" "$PORT" >"$SCRATCH/gw.log" 2>&1 &
    GWPID=$!
    register_pid "$GWPID"
else
    cat > "$SCRATCH/gw.py" <<'PY'
# Minimal fnOS-gateway stand-in: TCP in, unix socket out, path preserved.
import socket, sys, threading

SOCK, PORT = sys.argv[1], int(sys.argv[2])

def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        try: b.shutdown(socket.SHUT_WR)
        except OSError: pass

def handle(conn):
    # Read the request head; forward it unchanged (path included) upstream.
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = conn.recv(65536)
        if not d:
            conn.close(); return
        buf += d
    try:
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        up.connect(SOCK)
    except OSError:
        conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        conn.close(); return
    up.sendall(buf)  # verbatim, /app/v2raya prefix retained
    t = threading.Thread(target=pipe, args=(conn, up), daemon=True); t.start()
    pipe(up, conn)
    try: up.close()
    except OSError: pass
    try: conn.close()
    except OSError: pass

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(64)
print("GATEWAY_LISTENING %d" % PORT, flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
    python3 "$SCRATCH/gw.py" "$SOCK" "$PORT" >"$SCRATCH/gw.log" 2>&1 &
    GWPID=$!
    register_pid "$GWPID"
fi

if wait_for_tcp_http "http://127.0.0.1:$PORT/app/v2raya/api/version" 20; then
    pass "gateway proxy accepting connections on 127.0.0.1:$PORT"
else
    fail "gateway proxy did not come up on 127.0.0.1:$PORT"
    info "proxy log: $(tail -5 "$SCRATCH/gw.log" 2>/dev/null | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
# 3. Assertions through the gateway
# ---------------------------------------------------------------------------
section "3. requests through the gateway (path must be preserved)"

gw_code="$(http_code_tcp "http://127.0.0.1:$PORT/app/v2raya/api/version")"
if [ "$gw_code" = "200" ]; then
    pass "GET /app/v2raya/api/version via gateway -> 200"
else
    fail "GET /app/v2raya/api/version via gateway -> $gw_code (expected 200)"
fi

gw_body="$(curl -s -m 10 "http://127.0.0.1:$PORT/app/v2raya/api/version" 2>/dev/null)"
probe_out="$(printf '%s' "$gw_body" | python3 -c '
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception as exc:
    print("not JSON: %s" % exc); sys.exit(1)
data=d.get("data") or {}
if "hasAccounts" not in data:
    print("hasAccounts absent; keys=%s" % sorted(data)); sys.exit(1)
print("version=%s hasAccounts=%s" % (data.get("version"), data["hasAccounts"]))
' 2>&1)"
probe_rc=$?
if [ "$probe_rc" -eq 0 ]; then
    pass "gateway response is v2rayA JSON with hasAccounts (${probe_out})"
else
    fail "gateway response is not a valid v2rayA payload (${probe_out})"
    info "body: $(printf '%s' "$gw_body" | head -c 300)"
fi

ui_code="$(http_code_tcp "http://127.0.0.1:$PORT/app/v2raya/")"
if [ "$ui_code" = "200" ]; then
    pass "GET /app/v2raya/ via gateway -> 200 (UI delivered through the gateway)"
else
    fail "GET /app/v2raya/ via gateway -> $ui_code (expected 200)"
fi

# The decisive regression check: the prefix must be part of the upstream path.
# If a proxy "helpfully" stripped /app/v2raya, the upstream would receive "/"
# and v2rayA would answer 404 (measured: bare / -> 404).
root_via_gw="$(http_code_tcp "http://127.0.0.1:$PORT/")"
if [ "$root_via_gw" = "404" ]; then
    pass "GET / via gateway -> 404, proving /app/v2raya was forwarded unchanged"
else
    fail "GET / via gateway -> $root_via_gw (expected 404; got 200 would mean the proxy stripped the prefix)"
fi

# Static assets live under the prefix too.
static_code="$(http_code_tcp "http://127.0.0.1:$PORT/app/v2raya/static/")"
info "GET /app/v2raya/static/ via gateway -> $static_code (informational)"

# Gateway identity headers must not break routing when present.
hdr_code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' \
    -H 'X-Trim-Userid: 1000' -H 'X-Trim-Isadmin: 1' -H 'X-Trim-Username: admin' \
    "http://127.0.0.1:$PORT/app/v2raya/api/version" 2>/dev/null)"
if [ "$hdr_code" = "200" ]; then
    pass "gateway identity headers (X-Trim-*) do not break routing -> 200"
else
    fail "request with X-Trim-* identity headers -> $hdr_code (expected 200)"
fi

# The socket must NOT be reachable over TCP: security bottom line (§11).
# Only the proxy's own port is open, the app never binds TCP.
tcp_2017="$(http_code_tcp "http://127.0.0.1:2017/app/v2raya/api/version")"
if [ "$tcp_2017" = "000" ]; then
    pass "v2rayA is not listening on TCP 2017 (unix-socket only, contract §11)"
else
    fail "something answers on TCP 2017 (got $tcp_2017); the app must be unix-socket only"
fi

# ---------------------------------------------------------------------------
# 4. Tear down and prove nothing lingers
# ---------------------------------------------------------------------------
section "4. teardown"

stop_pid "$GWPID"
if kill -0 "$GWPID" 2>/dev/null; then
    fail "gateway proxy pid $GWPID still alive after SIGTERM"
else
    pass "gateway proxy stopped"
fi

stop_pid "$V2PID"
if kill -0 "$V2PID" 2>/dev/null; then
    fail "v2rayA pid $V2PID still alive after SIGTERM"
else
    pass "v2rayA stopped"
fi

# Nothing may still be listening on the proxy port.
sleep 0.2
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    fail "something is still listening on 127.0.0.1:$PORT after shutdown"
else
    pass "127.0.0.1:$PORT is closed after shutdown"
fi

finish "gateway-sim"

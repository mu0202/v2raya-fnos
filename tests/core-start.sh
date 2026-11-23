#!/bin/bash
# Verify the PROXY CORE actually starts and binds its inbounds.
#
# Why this test exists
# --------------------
# The first shipped build passed lint/smoke/gateway-sim but the user still hit:
#
#    无法启动核心：无法启动 v2raya_core:
#    v2raya_core exited right after starting; the reason is in the v2rayA log
#
# Two independent root causes, both invisible to the earlier suites because they
# only ever exercised the HTTP UI, never the core process:
#
#  1. The bundled geosite.dat (v2fly domain-list-community `dlc.dat`) has no
#     `gfw` category. Any gfwlist-style routing rule makes the core fail with
#     "illegal domain rule: geosite:gfw ... EOF" and exit immediately.
#  2. `--v2ray-assetsdir` configures v2rayA itself and is NOT propagated to the
#     core process. The core resolves geosite.dat/geoip.dat from its own working
#     directory unless XRAY_LOCATION_ASSET / V2RAY_LOCATION_ASSET is exported,
#     so it cannot find them even when they are right there.
#
# This test fails if either regresses. It runs the REAL core binary from
# app/server/ with the REAL assets from app/assets/.
#
# Usage: bash tests/core-start.sh
# No network, no root, no fnOS required.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT_DIR="$PWD"

# shellcheck source=lib-test.sh
. tests/lib-test.sh 2>/dev/null || { echo "cannot load tests/lib-test.sh"; exit 1; }

CORE="$ROOT_DIR/app/server/v2raya_core"
ASSETS="$ROOT_DIR/app/assets"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/v2raya-core.XXXXXX")" || exit 1
# Kill only the process we started. Never `pkill -x v2raya_core`: this box may be
# running a real v2rayA install whose core has the same argv[0], and killing it
# would both break the user's proxy and make "core survived SIGTERM" fail for a
# reason unrelated to the code under test.
kill_ours() {
    local pid="$1"
    [ -n "${pid:-}" ] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 25 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
}

CORE_PID=""

cleanup() {
    kill_ours "$CORE_PID"
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== core-start: exercising the real core binary"

# ---------------------------------------------------------------------------
echo
echo "--- 1. binaries and assets present"
if [ -x "$CORE" ]; then
    pass "core binary is present and executable"
else
    fail "core binary missing: $CORE"
    finish "core-start"; exit $?
fi

ver="$("$CORE" version 2>&1 | head -1)"
case "$ver" in
    *2.5.16*) pass "core reports $ver" ;;
    *)        fail "unexpected core version: $ver" ;;
esac

for f in geoip.dat geosite.dat LoyalsoldierSite.dat; do
    if [ -f "$ASSETS/$f" ]; then
        pass "asset present: $f ($(human_size "$(stat -c '%s' "$ASSETS/$f")"))"
    else
        fail "asset missing: $f"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "--- 2. geosite.dat must satisfy the categories v2rayA routes on"
# The core is the authority here; parse-defeating format differences make
# hand-rolled parsers unreliable. Ask the core directly: if it can build a
# routing config referencing the category, the asset supports it.
mkdir -p "$WORK/assets"
cp "$ASSETS/geoip.dat" "$ASSETS/geosite.dat" "$ASSETS/LoyalsoldierSite.dat" "$WORK/assets/" 2>/dev/null

cat > "$WORK/probe.json" <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "probe", "port": 10899, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [ { "type": "field", "domain": [ "geosite:gfw", "geosite:cn" ], "outboundTag": "direct" } ]
  }
}
JSON

# v2rayA emits BOTH syntaxes depending on the routing mode:
#   geosite:gfw                          (built-in category lookup)
#   ext:LoyalsoldierSite.dat:gfw         (GFWList mode, file-based lookup)
# The ext: form parses LoyalsoldierSite.dat with the SAME geosite wire format as
# geosite.dat. Shipping a differently-encoded file there reproduces the real
# failure seen on device:
#   illegal domain rule: ext:LoyalsoldierSite.dat:gfw
#   > failed to check code GFW from LoyalsoldierSite.dat
#   > invalid body length: 2186385218
# So the probe must exercise BOTH forms, not just geosite:.
cat > "$WORK/probe-ext.json" <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "probe", "port": 10898, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [ { "type": "field", "domain": [ "ext:LoyalsoldierSite.dat:gfw" ], "outboundTag": "direct" } ]
  }
}
JSON

probe_out="$WORK/probe.log"
( cd "$WORK" && XRAY_LOCATION_ASSET="$WORK/assets" V2RAY_LOCATION_ASSET="$WORK/assets" \
  timeout 12 "$CORE" run -c "$WORK/probe.json" >"$probe_out" 2>&1 ) &
probe_pid=$!
sleep 6
kill_ours "$probe_pid"
wait "$probe_pid" 2>/dev/null

if grep -q "Xray .* started" "$probe_out" 2>/dev/null; then
    pass "core accepts geosite:gfw and geosite:cn routing rules (asset has the categories)"
elif grep -qi "illegal domain rule" "$probe_out" 2>/dev/null; then
    fail "core rejects geosite:gfw -- bundled geosite.dat lacks the gfw category ($(grep -oiE 'illegal domain rule[^>]*' "$probe_out" | head -1))"
elif grep -qi "failed to open geosite.dat" "$probe_out" 2>/dev/null; then
    fail "core cannot locate geosite.dat even with XRAY_LOCATION_ASSET set"
else
    fail "core did not start with a geosite routing rule; output: $(head -c 300 "$probe_out" 2>/dev/null)"
fi

# The ext: form is a separate code path (file-based geosite parsing).
ext_out="$WORK/probe-ext.log"
( cd "$WORK" && XRAY_LOCATION_ASSET="$WORK/assets" V2RAY_LOCATION_ASSET="$WORK/assets" \
  timeout 12 "$CORE" run -c "$WORK/probe-ext.json" >"$ext_out" 2>&1 ) &
ext_pid=$!
sleep 6
kill_ours "$ext_pid"
wait "$ext_pid" 2>/dev/null

if grep -q "Xray .* started" "$ext_out" 2>/dev/null; then
    pass "core accepts ext:LoyalsoldierSite.dat:gfw (GFWList mode file is geosite-format)"
elif grep -qi "invalid body length" "$ext_out" 2>/dev/null; then
    fail "LoyalsoldierSite.dat is NOT in geosite format (invalid body length) -- GFWList mode cannot start"
elif grep -qi "illegal domain rule" "$ext_out" 2>/dev/null; then
    fail "core rejects ext:LoyalsoldierSite.dat:gfw: $(grep -oiE 'illegal domain rule[^>]*' "$ext_out" | head -1)"
else
    fail "ext: probe inconclusive: $(head -c 300 "$ext_out" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 3. core starts AND binds inbound ports (the user's actual failure)"
# Pick free ports instead of hardcoding v2rayA's defaults (20170/20171).
# A real v2rayA install running on the same box holds those ports, which would
# make this test fail for a reason unrelated to the code under test.
free_port() {
    local p
    for p in $(seq "$1" "$2"); do
        if ! ss -lnt 2>/dev/null | grep -q ":$p " 2>/dev/null; then
            printf '%s' "$p"; return 0
        fi
    done
    printf '%s' "$1"
}
SOCKS_PORT="$(free_port 20370 20399)"
HTTP_PORT="$(free_port 20470 20499)"

cat > "$WORK/run.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": $SOCKS_PORT, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": true } },
    { "tag": "http",  "port": $HTTP_PORT, "listen": "127.0.0.1", "protocol": "http",  "settings": {} }
  ],
  "outbounds": [
    { "tag": "proxy",  "protocol": "shadowsocks",
      "settings": { "servers": [ { "address": "127.0.0.1", "port": 8388, "method": "aes-256-gcm", "password": "testpass" } ] } },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "domain": [ "geosite:gfw" ], "outboundTag": "proxy" },
      { "type": "field", "domain": [ "geosite:cn"  ], "outboundTag": "direct" }
    ]
  }
}
JSON

run_out="$WORK/run.log"
( cd "$WORK" && XRAY_LOCATION_ASSET="$WORK/assets" V2RAY_LOCATION_ASSET="$WORK/assets" \
  timeout 25 "$CORE" run -c "$WORK/run.json" >"$run_out" 2>&1 ) &
CORE_PID=$!
sleep 7

if grep -q "Xray .* started" "$run_out" 2>/dev/null; then
    pass "core started (no 'exited right after starting')"
else
    fail "core did not reach 'started'; output: $(head -c 300 "$run_out" 2>/dev/null)"
fi

# Check OUR process, not "any v2raya_core on the box": a real install running
# alongside would otherwise make this pass even if our core died.
if [ -n "${CORE_PID:-}" ] && kill -0 "$CORE_PID" 2>/dev/null; then
    pass "core process is alive after startup (pid $CORE_PID)"
else
    fail "core process is not alive after startup (pid ${CORE_PID:-none})"
fi

# Port binding is the part a user actually notices: it means the proxy works.
bound=0
check_port() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ":$p " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -q ":$p " && return 0
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && return 0
    fi
    return 1
}
for p in "$SOCKS_PORT" "$HTTP_PORT"; do
    check_port "$p" && bound=$((bound + 1))
done

if [ "$bound" -eq 2 ]; then
    pass "both inbound ports ($SOCKS_PORT socks, $HTTP_PORT http) are listening"
elif [ "$bound" -ge 1 ]; then
    pass "$bound of 2 inbound ports listening ($SOCKS_PORT/$HTTP_PORT)"
else
    fail "no inbound port is listening (0 of 2, tried $SOCKS_PORT/$HTTP_PORT) -- the proxy would not work"
fi

our_core_pid="$CORE_PID"
kill_ours "$our_core_pid"
wait "$CORE_PID" 2>/dev/null
CORE_PID=""
sleep 1
# Judge only OUR pid. `pgrep -x v2raya_core` would also match a real v2rayA
# install running on this machine, which is expected to be alive.
if [ -n "$our_core_pid" ] && kill -0 "$our_core_pid" 2>/dev/null; then
    fail "core survived SIGTERM (pid $our_core_pid)"
else
    pass "core exits cleanly on SIGTERM"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 4. cmd/main must export the asset location to the core"
# Root cause #2: --v2ray-assetsdir is not inherited by the core. If cmd/main
# stops exporting these, geosite lookups break again even with good assets.
MAIN="$ROOT_DIR/cmd/main"
if [ -f "$MAIN" ]; then
    if grep -q 'XRAY_LOCATION_ASSET' "$MAIN" && grep -q 'V2RAY_LOCATION_ASSET' "$MAIN"; then
        pass "cmd/main exports XRAY_LOCATION_ASSET and V2RAY_LOCATION_ASSET"
    else
        fail "cmd/main does not export the core asset env vars (core cannot find geosite.dat)"
    fi
    if grep -q -- '--v2ray-assetsdir' "$MAIN"; then
        pass "cmd/main still passes --v2ray-assetsdir to v2rayA"
    else
        fail "cmd/main lost --v2ray-assetsdir"
    fi
else
    fail "cmd/main missing"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 5. TUN mode needs root (this is why the app runs as root)"
# The app used to run as the package user, which cannot create a TUN device:
#   non-root + TUN inbound -> "failed to start proxy > operation not permitted"
# that is exactly what the UI reports as "v2raya_core exited right after starting".
# Two things must therefore hold:
#   a) config/privilege asks for root
#   b) the TUN inbound genuinely works once it has the privileges
PRIV_FILE="$ROOT_DIR/config/privilege"
if [ -f "$PRIV_FILE" ]; then
    run_as=$(python3 -c "import json;print(json.load(open('$PRIV_FILE'))['defaults']['run-as'])" 2>/dev/null)
    if [ "$run_as" = "root" ]; then
        pass "config/privilege requests run-as=root (required for TUN)"
    else
        fail "config/privilege run-as=$run_as; TUN needs root or the core exits with 'operation not permitted'"
    fi
else
    fail "config/privilege missing"
fi

cat > "$WORK/tun.json" <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "tun", "protocol": "tun",
      "settings": { "name": "xray0", "MTU": 1500, "gateway": [ "10.66.0.1/16" ] } }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
JSON

# Probe whether TUN can start. Unprivileged -> expected to fail with
# "operation not permitted"; with CAP_NET_ADMIN (root, or a userns that maps us
# to root) it must start. We assert the privileged path when we can obtain it,
# and otherwise record the known limitation instead of faking a pass.
tun_out="$WORK/tun.log"
unshare -r -n true >/dev/null 2>&1
have_userns=$?
if [ "$have_userns" -eq 0 ]; then
    ( cd "$WORK" && unshare -r -n timeout 12 "$CORE" run -c "$WORK/tun.json" >"$tun_out" 2>&1 )
    if grep -q "Xray .* started" "$tun_out" 2>/dev/null; then
        pass "TUN inbound starts once the process has root-equivalent privileges"
    elif grep -qi "operation not permitted" "$tun_out" 2>/dev/null; then
        fail "TUN inbound got 'operation not permitted' even with elevated privileges"
    else
        fail "TUN probe inconclusive: $(head -c 240 "$tun_out" 2>/dev/null)"
    fi
else
    skip "userns unavailable; cannot simulate root here. TUN path not exercised."
fi

# Baseline: as the current unprivileged user TUN must fail, proving the privilege
# requirement is real and that our root choice is not cargo-culted.
( cd "$WORK" && timeout 12 "$CORE" run -c "$WORK/tun.json" >"$WORK/tun-unpriv.log" 2>&1 )
if grep -qi "operation not permitted" "$WORK/tun-unpriv.log" 2>/dev/null; then
    pass "unprivileged TUN fails with 'operation not permitted' (confirms root is required)"
else
    info "unprivileged TUN did not report EPERM (environment may be unusual)"  # informational only
fi

# ---------------------------------------------------------------------------
echo
echo "--- 6. no runtime migration is shipped (v2rayA's own UI owns the setting)"
# We deliberately do NOT rewrite v2raya.db at startup. transparentType is the
# user's choice (tun / tproxy / redirect); guessing a replacement for a stale
# lite-era "system_proxy" value would silently pick a proxy mode for them.
# The supported path is: open the UI, pick a mode, save -- v2rayA rejects
# system_proxy itself when running as root.
MAIN="${ROOT_DIR}/cmd/main"
if [ -f "$MAIN" ]; then
    if grep -q "migrate_lite_settings" "$MAIN"; then
        fail "cmd/main still carries a DB migration; the setting is the user's to choose"
    else
        pass "cmd/main performs no database migration"
    fi
    # Look for an actual invocation, not the word in a comment.
    if grep -vE '^[[:space:]]*#' "$MAIN" | grep -qE '(^|[^-[:alnum:]_])(python3?|py)([[:space:]]|$)'; then
        fail "cmd/main references python at runtime"
    else
        pass "cmd/main has no python dependency at runtime"
    fi
else
    fail "cmd/main missing"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 7. nftables named priorities must be avoided (redirect/tproxy on fnOS)"
# fnOS ships nftables 1.0.6, whose parser rejects the named priority constants
# v2rayA emits for its DNS-redirect chain:
#   type nat hook output priority dstnat - 1
#   -> Error: invalid priority expression value in this context
# Measured: only "filter" is accepted by name; numeric (-100/-101) works.
# Consequence: transparentType=redirect and tproxy fail while tun is fine.
# cmd/main must force the iptables path with --nftables-support off.
MAIN="${ROOT_DIR}/cmd/main"
if [ -f "$MAIN" ]; then
    if grep -q -- "--nftables-support off" "$MAIN"; then
        pass "cmd/main passes --nftables-support off (avoids fnOS nft parser bug)"
    else
        fail "cmd/main does not disable nftables; redirect/tproxy will fail on fnOS nftables 1.0.6"
    fi
else
    fail "cmd/main missing"
fi

# If nftables is present and we can run it, prove the incompatibility is real so
# this assertion can never rot into a superstition.
if command -v nft >/dev/null 2>&1 && [ -w "${TMPDIR:-/tmp}" ]; then
    nftdir="$WORK/nft"; mkdir -p "$nftdir"
    cat > "$nftdir/named.nft" <<'JSON'
table inet v2raya_probe {
  chain o {
    type nat hook output priority dstnat - 1; policy accept;
  }
}
JSON
    named_out="$(nft -c -f "$nftdir/named.nft" 2>&1 || true)"
    case "$named_out" in
        *"invalid priority expression"*)
            pass "nft rejects 'priority dstnat - 1' (confirms the bug this flag works around)" ;;
        *"Operation not permitted"*|*"cache initialization failed"*)
            skip "cannot probe nft without CAP_NET_ADMIN; incompatibility unverified here" ;;
        "")
            info "nft accepted the named priority here (newer nftables?); the flag is harmless" ;;
        *)
            info "nft probe returned: $(printf '%s' "$named_out" | head -c 160)" ;;
    esac
else
    skip "nft not available; cannot probe the priority incompatibility"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 8. the package adds no networking features of its own"
# This package is an adaptation layer, not a feature fork. Everything network
# related (transparent proxy, TUN, routing, DNS, LAN access via portSharing) is
# v2rayA's own job and is configured in its UI. Two things must therefore hold:
#   a) cmd/main never manipulates iptables/nftables itself
#   b) it never redirects DNS -- in TUN mode the core already answers plain
#      port-53 traffic that enters the TUN (tunDnsTarget in v2rayA)
MAIN="${ROOT_DIR}/cmd/main"
if [ -f "$MAIN" ]; then
    if grep -vE '^[[:space:]]*#' "$MAIN" | grep -qE '(^|[^-[:alnum:]_])(iptables|ip6tables|nft)([[:space:]]|$)'; then
        fail "cmd/main invokes a firewall tool; that belongs to v2rayA, not the package"
    else
        pass "cmd/main does not touch iptables/nftables"
    fi
    if grep -vE '^[[:space:]]*#' "$MAIN" | grep -qE -- "--dport 53|REDIRECT --to-ports"; then
        fail "cmd/main redirects DNS; the core already handles it in TUN mode"
    else
        pass "cmd/main does not redirect DNS"
    fi
    if grep -vE '^[[:space:]]*#' "$MAIN" | grep -qE 'sysctl|ip_forward'; then
        fail "cmd/main tweaks kernel forwarding; that belongs to v2rayA"
    else
        pass "cmd/main does not tweak kernel forwarding"
    fi
else
    fail "cmd/main missing"
fi

echo
finish "core-start"
exit $?

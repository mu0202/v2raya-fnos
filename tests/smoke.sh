#!/bin/bash
# ---------------------------------------------------------------------------
# tests/smoke.sh — simulate a real fnOS install and exercise the lifecycle
#                  (contract §6.1, §10.2)
#
# Everything happens in a throw-away tree under /tmp; the project tree is
# never used as runtime storage and is never modified.
#
# Sequence:
#   1. build a fake install tree (target/ = $TRIM_APPDEST, plus var/etc/home/tmp)
#      by copying the real app/server + app/assets + cmd/
#   2. bash cmd/main start        -> expect exit 0
#   3. GET /app/v2raya/api/version over the unix socket -> 200 + hasAccounts
#   4. GET /app/v2raya/           over the unix socket -> 200  (UI serves)
#   5. bash cmd/main status       -> expect exit 0
#   6. bash cmd/main stop         -> then status -> expect exit 3
#   7. no v2raya process started by this test survives
#
# Exit: 0 pass, 1 failure, 77 blocked (cmd/ not implemented yet).
# ---------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=tests/lib-test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

cd "$ROOT_DIR" || { echo "cannot cd to $ROOT_DIR"; exit 1; }
install_cleanup_trap

echo "=============================================================="
echo " v2raya-fnos smoke test (simulated install)"
echo " project : $ROOT_DIR"
echo " user    : $(id -un) (uid $(id -u))"
echo " time    : $(date -Is)"
echo "=============================================================="

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------
section "0. preconditions"

if ! require_impl; then
    blocked "cmd/main not implemented — cannot run the install simulation"
    finish "smoke"
    exit $?
fi

for rel in app/server/v2raya app/server/v2raya_core app/assets/geoip.dat app/assets/geosite.dat; do
    if [ ! -s "$ROOT_DIR/$rel" ]; then
        blocked "payload missing: $rel"
    fi
done
if [ "$BLOCKED_COUNT" -gt 0 ]; then
    finish "smoke"
    exit $?
fi
pass "payload present: server binaries + geo assets"

if command -v curl >/dev/null 2>&1; then
    pass "curl available ($(curl --version | head -1 | cut -d' ' -f1-2))"
else
    fail "curl is required but not installed"
    finish "smoke"; exit $?
fi

# Baseline: another agent may have its own v2raya running on this shared box.
# We record those pids so we never mistake a foreign process for our survivor,
# and so our cleanup never kills a teammate's work.
BASELINE_PIDS="$(v2raya_pids)"
if [ -n "$BASELINE_PIDS" ]; then
    info "note: $(echo "$BASELINE_PIDS" | wc -l) unrelated v2raya process(es) already running: $(echo $BASELINE_PIDS)"
    info "      these belong to other sessions; this test will not touch them"
else
    info "no pre-existing v2raya processes"
fi

# Pids of v2raya processes that did not exist when this test started.
# Implemented with plain bash so it does not depend on collation-aware tools
# (comm requires lexicographic order, which is unsafe for variable-width pids).
new_v2raya_pids() {
    local p out=""
    for p in $(v2raya_pids); do
        case " ${BASELINE_PIDS:-} " in
            *" $p "*) continue ;;
        esac
        out="$out $p"
    done
    printf '%s' "${out# }"
}

# Like new_v2raya_pids, but keep only processes that actually belong to *this*
# scratch install. cmd/main is required to reference the scratch tree in its
# own invocation (--socket/--config/--v2ray-assetsdir all live there).
#
# This matters because the box is shared: a teammate session may start its own
# v2raya (observed: ./appserver/v2raya --socket /tmp/vtest-exp/app.sock) after
# our baseline snapshot, which a naive `pgrep -x v2raya` would blame on us.
own_new_v2raya_pids() {
    local p out="" cmd
    for p in $(new_v2raya_pids); do
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
        case "$cmd" in
            *"$SCRATCH"*) out="$out $p" ;;
        esac
    done
    printf '%s' "${out# }"
}

# New v2raya processes that do NOT reference our scratch tree (someone else's).
foreign_new_v2raya_pids() {
    local p out="" cmd
    for p in $(new_v2raya_pids); do
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
        case "$cmd" in
            *"$SCRATCH"*) ;;
            *) out="$out $p" ;;
        esac
    done
    printf '%s' "${out# }"
}

# Give a just-signalled process a moment to actually disappear before deciding
# it survived. SIGTERM shutdown was measured at ~44 ms, but the process stays
# visible to pgrep until it is reaped; a 2 s settle window avoids flapping.
settle_v2raya() {
    local i
    for i in $(seq 1 20); do
        [ -z "$(own_new_v2raya_pids)" ] && return 0
        sleep 0.1
    done
    return 0
}

# ---------------------------------------------------------------------------
# 1. Build the fake install tree
# ---------------------------------------------------------------------------
section "1. build install tree"

SCRATCH="$(mktemp -d /tmp/v2raya-smoke.XXXXXXXX)" || {
    fail "cannot create scratch dir under /tmp"
    finish "smoke"; exit $?
}
register_dir "$SCRATCH"

export TRIM_APPDEST="$SCRATCH/target"
export TRIM_PKGVAR="$SCRATCH/var"
export TRIM_PKGETC="$SCRATCH/etc"
export TRIM_PKGHOME="$SCRATCH/home"
export TRIM_PKGTMP="$SCRATCH/tmp"
export TRIM_TEMP_LOGFILE="$SCRATCH/tmp/install.log"
export TRIM_APPNAME="v2raya"
export TRIM_SYS_ARCH="x86_64"
export TRIM_SYS_VERSION="1.2.1102"
export TRIM_SYS_VERSION_MAJOR="1"
export TRIM_UID="$(id -u)"
export TRIM_USERNAME="$(id -un)"
export TRIM_RUN_UID="$(id -u)"
export TRIM_RUN_USERNAME="$(id -un)"
export TRIM_DATA_SHARE_PATHS="$SCRATCH/shares"

mkdir -p "$TRIM_APPDEST" "$TRIM_PKGVAR" "$TRIM_PKGETC" "$TRIM_PKGHOME" \
         "$TRIM_PKGTMP" "$TRIM_DATA_SHARE_PATHS"

# Payload exactly as fnOS would lay it down under @appcenter/<appname>/.
# NOTE: copy_tree (not `cp -a`) because the vendored binaries carry a btrfs ACL
# with mask::r-- which makes `cp -a` produce 640, non-executable copies.
copy_tree "$ROOT_DIR/app/server" "$TRIM_APPDEST/server"
copy_tree "$ROOT_DIR/app/assets" "$TRIM_APPDEST/assets"
[ -d "$ROOT_DIR/app/ui" ]  && copy_tree "$ROOT_DIR/app/ui"  "$TRIM_APPDEST/ui"
[ -d "$ROOT_DIR/app/www" ] && copy_tree "$ROOT_DIR/app/www" "$TRIM_APPDEST/www"

# cmd/ lives beside target/ in the installed package.
copy_tree "$ROOT_DIR/cmd" "$SCRATCH/cmd"
chmod 755 "$SCRATCH"/cmd/* 2>/dev/null

assert_exec "installed target/server/v2raya is executable"      "$TRIM_APPDEST/server/v2raya"
assert_exec "installed target/server/v2raya_core is executable" "$TRIM_APPDEST/server/v2raya_core"
assert_file "installed target/assets/geoip.dat"                 "$TRIM_APPDEST/assets/geoip.dat"
assert_file "installed target/assets/geosite.dat"               "$TRIM_APPDEST/assets/geosite.dat"
assert_file "installed cmd/main"                                "$SCRATCH/cmd/main"

if [ ! -f "$SCRATCH/cmd/main" ]; then
    info "scratch tree: $SCRATCH"
    finish "smoke"; exit $?
fi
pass "install tree ready: $SCRATCH"

SOCK="$TRIM_APPDEST/app.sock"
# The location of the pidfile is an implementation detail of cmd/main, so the
# test never reads it; it is recorded only for diagnostics.
PIDFILE="$TRIM_PKGVAR/app.pid"

# ---------------------------------------------------------------------------
# 2. start
# ---------------------------------------------------------------------------
section "2. cmd/main start"

start_out="$(cd "$SCRATCH/cmd" && bash main start 2>&1)"
start_rc=$?
if [ "$start_rc" -eq 0 ]; then
    pass "bash cmd/main start -> exit 0"
else
    fail "bash cmd/main start -> exit $start_rc (expected 0)"
    info "output: $(printf '%s' "$start_out" | tail -5 | tr '\n' '|')"
    if [ -s "$TRIM_TEMP_LOGFILE" ]; then
        info "TRIM_TEMP_LOGFILE tail: $(tail -5 "$TRIM_TEMP_LOGFILE" | tr '\n' '|')"
    fi
fi
[ -n "$start_out" ] && info "start output: $(printf '%s' "$start_out" | tail -3 | tr '\n' '|')"

# Pids we are now responsible for.
NEW_PIDS="$(new_v2raya_pids)"
if [ -n "$NEW_PIDS" ]; then
    pass "started v2raya pid(s): $(echo $NEW_PIDS)"
    for p in $NEW_PIDS; do register_pid "$p"; done
else
    info "no new v2raya pid detected yet (will re-check after socket probes)"
fi

# ---------------------------------------------------------------------------
# 3. api/version over the unix socket
# ---------------------------------------------------------------------------
section "3. /app/v2raya/api/version over unix socket"

if [ ! -S "$SOCK" ]; then
    info "expected socket not present at $SOCK; searching for any socket in the install tree..."
    found_sock="$(find "$SCRATCH" -maxdepth 3 -type s 2>/dev/null | head -1)"
    if [ -n "$found_sock" ]; then
        info "found socket: $found_sock (contract §6.1 expects \$TRIM_APPDEST/app.sock)"
        fail "socket is not at \$TRIM_APPDEST/app.sock (contract §6.1 deviation); found $found_sock"
        SOCK="$found_sock"
    else
        fail "no unix socket appeared anywhere in the install tree"
    fi
else
    pass "unix socket exists at \$TRIM_APPDEST/app.sock"
fi

if [ -S "$SOCK" ] && wait_for_socket_http "$SOCK" "/app/v2raya/api/version" 30; then
    pass "GET /app/v2raya/api/version -> HTTP 200 within 30s"
else
    fail "GET /app/v2raya/api/version did not return 200 within 30s (got $(http_code_unix "$SOCK" /app/v2raya/api/version))"
fi

version_body="$(curl -s -m 10 --unix-socket "$SOCK" http://localhost/app/v2raya/api/version 2>/dev/null)"
probe_out="$(printf '%s' "$version_body" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as exc:
    print("response is not JSON: %s" % exc); sys.exit(1)
data = d.get("data")
if not isinstance(data, dict):
    print("response has no data object"); sys.exit(1)
if "hasAccounts" not in data:
    print("data.hasAccounts is absent; keys=%s" % sorted(data)); sys.exit(1)
if not isinstance(data["hasAccounts"], bool):
    print("data.hasAccounts is not a boolean: %r" % (data["hasAccounts"],)); sys.exit(1)
print("hasAccounts=%s version=%s lite=%s isRoot=%s" % (
    data["hasAccounts"], data.get("version"), data.get("lite"), data.get("isRoot")))
' 2>&1)"
probe_rc=$?
if [ "$probe_rc" -eq 0 ]; then
    pass "response JSON contains boolean 'hasAccounts' (${probe_out})"
else
    fail "response JSON missing 'hasAccounts' (${probe_out})"
    info "body: $(printf '%s' "$version_body" | head -c 300)"
fi

# ---------------------------------------------------------------------------
# 4. UI is served
# ---------------------------------------------------------------------------
section "4. /app/v2raya/ (UI) over unix socket"

ui_code="$(http_code_unix "$SOCK" "/app/v2raya/")"
if [ "$ui_code" = "200" ]; then
    pass "GET /app/v2raya/ -> HTTP 200 (UI served)"
else
    fail "GET /app/v2raya/ -> HTTP $ui_code (expected 200)"
fi

# Sanity: the prefix must actually be required, i.e. the server is mounted at
# /app/v2raya and not at /. A bare / returning 404 proves the prefix routing.
root_code="$(http_code_unix "$SOCK" "/")"
if [ "$root_code" = "404" ]; then
    pass "GET / -> HTTP 404 (confirms baseurl /app/v2raya is honoured)"
else
    info "GET / -> HTTP $root_code (informational; contract §1.1 expects 404)"
fi

# ---------------------------------------------------------------------------
# 5. status while running
# ---------------------------------------------------------------------------
section "5. cmd/main status (running)"

(cd "$SCRATCH/cmd" && bash main status) >/dev/null 2>&1
st_rc=$?
if [ "$st_rc" -eq 0 ]; then
    pass "bash cmd/main status -> exit 0 while running"
else
    fail "bash cmd/main status -> exit $st_rc while running (expected 0)"
fi

# ---------------------------------------------------------------------------
# 6. stop
# ---------------------------------------------------------------------------
section "6. cmd/main stop"

(cd "$SCRATCH/cmd" && bash main stop) >/dev/null 2>&1
stop_rc=$?
if [ "$stop_rc" -eq 0 ]; then
    pass "bash cmd/main stop -> exit 0"
else
    fail "bash cmd/main stop -> exit $stop_rc (expected 0)"
fi

# Give the socket a moment to disappear if the implementation removes it.
for _ in $(seq 1 20); do
    [ -S "$SOCK" ] || break
    sleep 0.1
done

section "7. cmd/main status (stopped) and no survivors"

(cd "$SCRATCH/cmd" && bash main status) >/dev/null 2>&1
st2_rc=$?
if [ "$st2_rc" -eq 3 ]; then
    pass "bash cmd/main status -> exit 3 after stop (contract §6.1)"
else
    fail "bash cmd/main status -> exit $st2_rc after stop (expected 3)"
fi

# A survivor is a NEW v2raya pid that references this scratch install — this is
# what "no v2raya process survives" means, scoped so that a teammate's
# concurrently running v2raya cannot produce a false failure.
settle_v2raya
survivors="$(own_new_v2raya_pids)"
if [ -z "$survivors" ]; then
    pass "no v2raya process started by this test survives"
else
    fail "v2raya process(es) survived stop: $(echo $survivors)"
    for p in $survivors; do
        info "  pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | head -c 200)"
    done
fi
foreign="$(foreign_new_v2raya_pids)"
if [ -n "$foreign" ]; then
    info "note: unrelated v2raya process(es) appeared during the run and are ignored: $(echo $foreign)"
fi

# Also require that no live process references our scratch dir, regardless of
# how it was named — this catches a renamed/duplicated daemon.
stray="$(pgrep -af "$SCRATCH" 2>/dev/null | grep -v -E 'smoke\.sh|lib-test\.sh' || true)"
if [ -z "$stray" ]; then
    pass "no process references the scratch install tree"
else
    fail "process(es) still reference the scratch install tree:"
    printf '%s\n' "$stray" | while IFS= read -r l; do info "  $l"; done
fi

# Socket hygiene (informational: a stale socket is survivable, an active
# listener is not).
if [ -S "$SOCK" ]; then
    info "note: socket file still present after stop ($SOCK) — stale socket, harmless but cmd/main should unlink it"
fi

# ---------------------------------------------------------------------------
# 8. Idempotency: start twice, stop twice
# ---------------------------------------------------------------------------
section "8. idempotency (double start / double stop)"

if [ -f "$SCRATCH/cmd/main" ]; then
    (cd "$SCRATCH/cmd" && bash main start) >/dev/null 2>&1
    rc1=$?
    (cd "$SCRATCH/cmd" && bash main start) >/dev/null 2>&1
    rc2=$?
    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
        pass "start twice -> exit 0 both times (idempotent)"
    else
        fail "start twice -> exit $rc1 then $rc2 (both must be 0; contract §6.2 requires idempotency)"
    fi

    # Track pids this second start created, then stop them.
    for p in $(new_v2raya_pids); do register_pid "$p"; done

    (cd "$SCRATCH/cmd" && bash main stop) >/dev/null 2>&1
    s1=$?
    (cd "$SCRATCH/cmd" && bash main stop) >/dev/null 2>&1
    s2=$?
    if [ "$s1" -eq 0 ] && [ "$s2" -eq 0 ]; then
        pass "stop twice -> exit 0 both times (idempotent)"
    else
        fail "stop twice -> exit $s1 then $s2 (both must be 0; contract §6.2 requires idempotency)"
    fi

    (cd "$SCRATCH/cmd" && bash main status) >/dev/null 2>&1
    if [ $? -eq 3 ]; then
        pass "status -> exit 3 after idempotency round"
    else
        fail "status did not return 3 after the idempotency round"
    fi
fi

# Final survivor sweep after the idempotency round.
settle_v2raya
final_survivors="$(own_new_v2raya_pids)"
if [ -z "$final_survivors" ]; then
    pass "final sweep: no v2raya process survives the whole run"
else
    fail "final sweep found surviving v2raya pid(s): $(echo $final_survivors)"
    for p in $final_survivors; do register_pid "$p"; done
fi

# ---------------------------------------------------------------------------
# 9. error-path sanity: unknown verb must not hang and must not exit 0
# ---------------------------------------------------------------------------
section "9. cmd/main unknown verb"

if [ -f "$SCRATCH/cmd/main" ]; then
    (cd "$SCRATCH/cmd" && timeout 15 bash main definitely-not-a-verb) >/dev/null 2>&1
    bad_rc=$?
    if [ "$bad_rc" -ne 0 ]; then
        pass "bash cmd/main <unknown verb> -> exit $bad_rc (non-zero, as required)"
    else
        fail "bash cmd/main <unknown verb> -> exit 0 (should be non-zero)"
    fi
else
    blocked "cmd/main missing — cannot test unknown verb"
fi

finish "smoke"

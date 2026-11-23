#!/bin/bash
# Regression: reinstall over data kept from a previous uninstall.
#
# Why this exists
# ---------------
# fnOS keeps $TRIM_PKGVAR when the user uninstalls with "保留数据". Our install
# creates $TRIM_PKGVAR/assets as a SYMLINK into $TRIM_APPDEST/assets. Uninstall
# deletes @appcenter/<app>, so the kept data leaves a DANGLING symlink behind.
#
# The original guard was:
#     if [ ! -e "${PKGVAR}/assets" ]; then ln -s ... ; fi
# which is broken for exactly this case: `-e` follows the link and reports
# "absent", the `ln -s` then hits "File exists" and fails, and `|| true` hides
# it. The dangling link survived and GFWList mode could not find
# LoyalsoldierSite.dat (user-visible: "目录 ... 中缺少 GFWList").
#
# Fix: `ln -sfn` (replace in place, never dereference). This test locks it in.
#
# Usage: bash tests/reinstall-keepdata.sh
# Requires: a built dist/*.fpk (run build.sh first). No network, no root.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT_DIR="$PWD"

# shellcheck source=lib-test.sh
. tests/lib-test.sh 2>/dev/null || { echo "cannot load tests/lib-test.sh"; exit 1; }

FPK="${1:-}"
if [ -z "$FPK" ]; then
    FPK=$(ls -1t "$ROOT_DIR"/dist/*.fpk 2>/dev/null | head -1)
fi
if [ -z "$FPK" ] || [ ! -f "$FPK" ]; then
    fail "no .fpk found; run build.sh first"
    finish "reinstall-keepdata"; exit $?
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/v2raya-reinstall.XXXXXX")" || exit 1
APP="$WORK/var-apps/v2raya"
DAEMON_PID=""

cleanup() {
    [ -n "$DAEMON_PID" ] && kill -TERM "$DAEMON_PID" 2>/dev/null
    [ -S "$APP/target/app.sock" ] && rm -f "$APP/target/app.sock" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== reinstall-keepdata: $FPK"
tar -xf "$FPK" -C "$WORK" || { fail "cannot unpack $FPK"; finish "reinstall-keepdata"; exit $?; }

setup_app() {
    rm -rf "$WORK/vol/@appcenter/v2raya"
    mkdir -p "$WORK/vol/@appcenter/v2raya" "$WORK/vol/@appdata/v2raya" "$WORK/vol/@appconf/v2raya"
    tar -xzf "$WORK/app.tgz" -C "$WORK/vol/@appcenter/v2raya" || return 1
    rm -rf "$APP"; mkdir -p "$APP"
    cp -r "$WORK/cmd" "$WORK/config" "$WORK/manifest" "$APP/" || return 1
    ln -sfn "$WORK/vol/@appcenter/v2raya" "$APP/target"
    ln -sfn "$WORK/vol/@appdata/v2raya"   "$APP/var"
    ln -sfn "$WORK/vol/@appconf/v2raya"   "$APP/etc"
}

export TRIM_APPDEST="$APP/target"
export TRIM_PKGVAR="$APP/var"
export TRIM_PKGETC="$APP/etc"
export TRIM_APPNAME=v2raya
export TRIM_APPVER=2.5.16-2
export TRIM_TEMP_LOGFILE="$WORK/temp-log.txt"

# ---------------------------------------------------------------------------
echo
echo "--- 1. first install"
setup_app || { fail "layout setup failed"; finish "reinstall-keepdata"; exit $?; }
bash "$APP/cmd/install_callback" >/dev/null 2>&1
if [ "$?" = "0" ]; then
    pass "install_callback (round 1) exit -> 0";
else
    fail "install_callback (round 1) exit -> $? (want 0)";
fi

if [ -L "$TRIM_PKGVAR/assets" ] && [ -e "$TRIM_PKGVAR/assets" ]; then
    pass "assets symlink created and resolves after first install"
else
    fail "assets symlink missing or dangling after first install"
fi

export TRIM_APPDEST_X="$TRIM_APPDEST"
bash "$APP/cmd/main" start >/dev/null 2>&1
if [ "$?" = "0" ]; then
    pass "cmd/main start (round 1) exit -> 0";
else
    fail "cmd/main start (round 1) exit -> $? (want 0)";
fi
if [ -S "$TRIM_APPDEST/app.sock" ]; then
    pass "socket present after first start"
    DAEMON_PID=$(cat "$TRIM_PKGVAR/app.pid" 2>/dev/null | head -1)
else
    fail "socket missing after first start"
fi
bash "$APP/cmd/main" stop >/dev/null 2>&1
DAEMON_PID=""

# ---------------------------------------------------------------------------
echo
echo "--- 2. uninstall while KEEPING data (removes @appcenter, keeps \$TRIM_PKGVAR)"
# Order matters: fnOS deletes @appcenter/<app> but keeps the data dir, so the
# symlink in $TRIM_PKGVAR/assets is left pointing at a path that no longer
# exists. Creating the dangling link BEFORE removing the target would let the
# removal silently clean it up, so assert the result rather than assume it.
rm -rf "$WORK/vol/@appcenter/v2raya"
if [ -L "$TRIM_PKGVAR/assets" ] && [ ! -e "$TRIM_PKGVAR/assets" ]; then
    pass "kept data now holds a DANGLING assets symlink (the precondition this test guards)"
else
    fail "expected a dangling assets symlink after uninstall-keeping-data, got: $(readlink "$TRIM_PKGVAR/assets" 2>/dev/null) (exists=$([ -e "$TRIM_PKGVAR/assets" ] && echo yes || echo no))"
fi
# The app entry itself is gone too, exactly like a real uninstall.
rm -rf "$APP"

# ---------------------------------------------------------------------------
echo
echo "--- 3. reinstall over the kept data"
setup_app || { fail "re-layout failed"; finish "reinstall-keepdata"; exit $?; }
bash "$APP/cmd/install_callback" >/dev/null 2>&1
if [ "$?" = "0" ]; then
    pass "install_callback (round 2) exit -> 0";
else
    fail "install_callback (round 2) exit -> $? (want 0)";
fi

if [ -e "$TRIM_PKGVAR/assets" ]; then
    pass "assets symlink resolves again after reinstall (was dangling)"
else
    fail "assets symlink STILL DANGLING after reinstall -- GFWList would break"
fi

if [ -f "$TRIM_PKGVAR/assets/LoyalsoldierSite.dat" ]; then
    pass "LoyalsoldierSite.dat reachable through kept-data assets dir"
else
    fail "LoyalsoldierSite.dat NOT reachable through kept-data assets dir"
fi

for f in geoip.dat geosite.dat; do
    if [ -f "$TRIM_PKGVAR/assets/$f" ]; then
        pass "$f reachable through kept-data assets dir"
    else
        fail "$f NOT reachable through kept-data assets dir"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "--- 4. the user-visible symptom must be gone"
bash "$APP/cmd/main" start >/dev/null 2>&1
if [ "$?" = "0" ]; then
    pass "cmd/main start (round 2) exit -> 0";
else
    fail "cmd/main start (round 2) exit -> $? (want 0)";
fi
DAEMON_PID=$(cat "$TRIM_PKGVAR/app.pid" 2>/dev/null | head -1)

SOCK="$TRIM_APPDEST/app.sock"
if [ -S "$SOCK" ]; then
    pass "socket present after reinstall"
else
    fail "socket missing after reinstall"
fi

if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$SOCK" \
        "http://localhost/app/v2raya/api/version" 2>/dev/null)
    if [ "$code" = "200" ]; then
    pass "GET /app/v2raya/api/version after reinstall -> 200";
else
    fail "GET /app/v2raya/api/version after reinstall -> $code (want 200)";
fi

    # Account creation is idempotent-safe here: a fresh data dir has no account.
    TOK=$(curl -s --max-time 10 --unix-socket "$SOCK" -H 'Content-Type: application/json' \
        -X POST -d '{"username":"admin","password":"reinstall-test-pw"}' \
        "http://localhost/app/v2raya/api/account" 2>/dev/null \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    if [ -z "$TOK" ]; then
        TOK=$(curl -s --max-time 10 --unix-socket "$SOCK" -H 'Content-Type: application/json' \
            -X POST -d '{"username":"admin","password":"reinstall-test-pw"}' \
            "http://localhost/app/v2raya/api/login" 2>/dev/null \
            | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    fi

    if [ -n "$TOK" ]; then
        pass "obtained an API token on the reinstalled instance"
        RESP=$(curl -s --max-time 20 --unix-socket "$SOCK" \
            -H "Authorization: $TOK" -H 'Content-Type: application/json' \
            -X PUT -d '{"transparent":"gfwlist"}' \
            "http://localhost/app/v2raya/api/setting" 2>/dev/null)
        case "$RESP" in
            *'"code":"SUCCESS"'*)
                pass "saving GFWList mode succeeds (original bug: GFWLIST_MISSING)" ;;
            *GFWLIST_MISSING*)
                fail "saving GFWList mode still fails with GFWLIST_MISSING" ;;
            *)
                fail "unexpected response saving GFWList mode: $(printf '%s' "$RESP" | head -c 200)" ;;
        esac
    else
        fail "could not obtain an API token on the reinstalled instance"
    fi
else
    info "curl unavailable; skipped the HTTP symptom checks"
fi

bash "$APP/cmd/main" stop >/dev/null 2>&1
DAEMON_PID=""
st=$(bash "$APP/cmd/main" status >/dev/null 2>&1; echo $?)
if [ "$st" = "3" ]; then
    pass "cmd/main status after stop -> 3 (not running)"
else
    fail "cmd/main status after stop -> $st (want 3)"
fi

echo
finish "reinstall-keepdata"
exit $?

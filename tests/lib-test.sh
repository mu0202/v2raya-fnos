#!/bin/bash
# ---------------------------------------------------------------------------
# tests/lib-test.sh — shared helpers for the v2raya-fnos acceptance suite.
#
# Sourced, never executed. Provides PASS/FAIL accounting, a cleanup registry
# that survives early exits, and small probes (PNG dims, HTTP status, JSON).
#
# See docs/ARCHITECTURE.md for the overall design.
#
# Design notes (measured on this box, fnOS 1.2.1102 / x86_64):
#   * No set -e here. Test scripts must be able to run every assertion and
#     report a full tally instead of dying on the first failure.
#   * Exit codes used by the suite:
#         0  all assertions passed
#         1  one or more assertions failed
#        77  BLOCKED — the artifact under test (cmd/, manifest, wizard/, …)
#            does not exist yet. This is NOT a pass and NOT a code defect.
# ---------------------------------------------------------------------------

# Resolve the project root from this file's location, so tests work no matter
# what the caller's cwd is.
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
    _dir="$(cd -P "$(dirname "$_self")" && pwd)"
    _self="$(readlink "$_self")"
    case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
TESTS_DIR="$(cd -P "$(dirname "$_self")" && pwd)"
ROOT_DIR="$(cd -P "$TESTS_DIR/.." && pwd)"
export TESTS_DIR ROOT_DIR

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
BLOCKED_COUNT=0
declare -a _FAILED_NAMES=()
declare -a _BLOCKED_NAMES=()

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS  %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    _FAILED_NAMES+=("$*")
    printf 'FAIL  %s\n' "$*"
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf 'SKIP  %s\n' "$*"
}

# Something we genuinely cannot test yet because a peer's artifact is absent.
blocked() {
    BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
    _BLOCKED_NAMES+=("$*")
    printf 'BLOCKED  %s\n' "$*"
}

section() {
    printf '\n--- %s ---\n' "$*"
}

info() {
    printf '        %s\n' "$*"
}

# assert_ok <label> <command...>  — command must exit 0
assert_ok() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
        return 0
    fi
    fail "$label"
    return 1
}

# assert_file <label> <path> — regular file must exist and be non-empty.
# Reports exactly one PASS or FAIL (never both) for the given label.
assert_file() {
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then
        fail "$label (missing: $path)"
        return 1
    fi
    if [ -d "$path" ]; then
        fail "$label (is a directory: $path)"
        return 1
    fi
    if [ ! -s "$path" ]; then
        fail "$label (present but empty: $path)"
        return 1
    fi
    pass "$label"
    return 0
}

# assert_exec <label> <path> — regular file, non-empty, and executable.
# Reports exactly one PASS or FAIL for the given label.
assert_exec() {
    local label="$1" path="$2"
    if [ ! -e "$path" ] || [ -d "$path" ] || [ ! -s "$path" ]; then
        fail "$label (missing or empty: $path)"
        return 1
    fi
    if [ ! -x "$path" ]; then
        fail "$label (not executable: $path)"
        return 1
    fi
    pass "$label"
    return 0
}

# copy_tree <src> <dst>
#
# Copy a payload directory into the simulated install tree with *explicit*
# modes.
#
# Why not `cp -a`: on this box the vendored binaries carry a btrfs ACL whose
# mask is `r--` (getfacl app/server/v2raya shows mask::r--). `cp -a` preserves
# that ACL onto the copy, and the resulting file is 640 and NOT executable —
# verified: `cp -a app/server /tmp/x` then running it gives "Permission denied".
# The install tree therefore fixes modes explicitly, which is exactly what a
# real .fpk install gets from tar (measured: tar restores 755 for these files).
copy_tree() {
    local src="$1" dst="$2"
    [ -d "$src" ] || return 1
    mkdir -p "$dst"
    # --no-preserve=all drops the source ACL that caps the mode.
    cp -r --no-preserve=all --no-target-directory "$src"/. "$dst"/ 2>/dev/null
    # Normalise: directories 755, regular files 644 by default.
    find "$dst" -type d -exec chmod 755 {} + 2>/dev/null
    find "$dst" -type f -exec chmod 644 {} + 2>/dev/null
    # Restore the executable bits the package actually relies on.
    if [ -d "$dst/server" ]; then
        chmod 755 "$dst/server"/v2raya "$dst/server"/v2raya_core 2>/dev/null
        for b in "$dst"/server/*; do
            [ -f "$b" ] && [ -x "$src/server/$(basename "$b")" ] && chmod 755 "$b"
        done
    fi
    # Any file that was executable at the source stays executable.
    local rel
    while IFS= read -r rel; do
        [ -f "$src/$rel" ] || continue
        [ -x "$src/$rel" ] && chmod 755 "$dst/$rel" 2>/dev/null
    done < <(cd "$src" && find . -type f -perm -u+x -printf '%P\n' 2>/dev/null)
    return 0
}

finish() {
    local name="$1"
    printf '\n===== %s summary =====\n' "$name"
    printf 'passed=%d failed=%d skipped=%d blocked=%d\n' \
        "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$BLOCKED_COUNT"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf 'failures:\n'
        local f
        for f in "${_FAILED_NAMES[@]}"; do
            printf '  - %s\n' "$f"
        done
    fi
    if [ "$BLOCKED_COUNT" -gt 0 ]; then
        printf 'blocked:\n'
        local b
        for b in "${_BLOCKED_NAMES[@]}"; do
            printf '  - %s\n' "$b"
        done
    fi

    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf 'RESULT: FAIL\n'
        return 1
    fi
    if [ "$BLOCKED_COUNT" -gt 0 ]; then
        printf 'RESULT: BLOCKED (incomplete inputs; not a pass)\n'
        return 77
    fi
    printf 'RESULT: PASS\n'
    return 0
}

# ---------------------------------------------------------------------------
# Cleanup registry — always tear down, even on failure/interrupt.
# ---------------------------------------------------------------------------
declare -a _CLEAN_PIDS=()
declare -a _CLEAN_DIRS=()
declare -a _CLEAN_FILES=()

register_pid() { _CLEAN_PIDS+=("$1"); }
register_dir() { _CLEAN_DIRS+=("$1"); }
register_file() { _CLEAN_FILES+=("$1"); }

# Terminate a pid politely, then forcibly. Never touch pids we did not start.
stop_pid() {
    local pid="$1" i
    [ -n "${pid:-}" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    return 0
}

run_cleanups() {
    local pid dir f
    for pid in "${_CLEAN_PIDS[@]:-}"; do
        [ -n "$pid" ] && stop_pid "$pid"
    done
    for dir in "${_CLEAN_DIRS[@]:-}"; do
        [ -n "$dir" ] && [ -d "$dir" ] && rm -rf -- "$dir"
    done
    for f in "${_CLEAN_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f -- "$f"
    done
    _CLEAN_PIDS=()
    _CLEAN_DIRS=()
    _CLEAN_FILES=()
}

install_cleanup_trap() {
    trap 'run_cleanups' EXIT
    trap 'run_cleanups; exit 130' INT
    trap 'run_cleanups; exit 143' TERM
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

# png_dims <file> -> "WIDTH HEIGHT" on stdout, non-zero on unreadable/non-PNG.
# Pure python3, no Pillow dependency (Pillow happens to exist here, but the
# packaging pipeline must not require it).
png_dims() {
    python3 - "$1" <<'PY'
import struct, sys
p = sys.argv[1]
try:
    with open(p, "rb") as fh:
        head = fh.read(24)
except OSError as exc:
    print("cannot read %s: %s" % (p, exc), file=sys.stderr)
    sys.exit(1)
if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
    print("%s is not a PNG" % p, file=sys.stderr)
    sys.exit(1)
if head[12:16] != b"IHDR":
    print("%s has no IHDR" % p, file=sys.stderr)
    sys.exit(1)
w, h = struct.unpack(">II", head[16:24])
print("%d %d" % (w, h))
PY
}

json_valid() {
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
}

human_size() {
    local n="${1:-0}"
    if [ "$n" -ge 1048576 ]; then
        awk -v b="$n" 'BEGIN{printf "%.2f MiB", b/1048576}'
    elif [ "$n" -ge 1024 ]; then
        awk -v b="$n" 'BEGIN{printf "%.1f KiB", b/1024}'
    else
        printf '%s B' "$n"
    fi
}

# Sorted list of pids of processes whose executable is exactly `v2raya`.
# Used to prove the smoke test leaves no survivors *of its own* without
# false-failing on unrelated v2raya instances started by a teammate.
v2raya_pids() {
    pgrep -x v2raya 2>/dev/null | sort -n || true
}

# HTTP status code over a unix socket. Prints exactly one 3-digit code.
# Note: curl's -w already prints 000 when the connection fails, so a fallback
# `|| echo 000` would double the output ("000000"); it is deliberately absent.
http_code_unix() {
    local sock="$1" path="$2" code
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' --unix-socket "$sock" \
        "http://localhost${path}" 2>/dev/null)"
    printf '%s' "${code:-000}" | tail -c 3
}

# HTTP status code over TCP. Prints exactly one 3-digit code.
http_code_tcp() {
    local url="$1" code
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null)"
    printf '%s' "${code:-000}" | tail -c 3
}

# Wait until a unix socket answers 200 on <path> with success, up to <secs>.
wait_for_socket_http() {
    local sock="$1" path="$2" secs="${3:-20}" i
    local deadline=$(( $(date +%s) + secs ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        [ -S "$sock" ] || { sleep 0.2; continue; }
        if [ "$(http_code_unix "$sock" "$path")" = "200" ]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# Wait until a TCP URL answers 200, up to <secs>.
wait_for_tcp_http() {
    local url="$1" secs="${2:-20}"
    local deadline=$(( $(date +%s) + secs ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        if [ "$(http_code_tcp "$url")" = "200" ]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# True when an implementation artifact the suite depends on is missing.
# Prints a human-readable reason and returns non-zero when absent.
require_impl() {
    local missing=0
    if [ ! -d "$ROOT_DIR/cmd" ] || [ -z "$(ls -A "$ROOT_DIR/cmd" 2>/dev/null)" ]; then
        info "cmd/ is missing or empty — not yet implemented by the cmd/ owner"
        missing=1
    elif [ ! -f "$ROOT_DIR/cmd/main" ]; then
        info "cmd/main is missing — cmd/ not yet implemented"
        missing=1
    fi
    [ "$missing" -eq 0 ]
}

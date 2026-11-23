#!/bin/bash
# ---------------------------------------------------------------------------
# tests/run-all.sh — run the whole acceptance suite in dependency order and
#                    print one consolidated result.
#
# Order matters:
#   1. lint.sh          static checks on the source tree (no build needed)
#   2. build.sh         produce dist/v2raya_<version>_x86.fpk
#   3. fpk-structure.sh assertions on the produced .fpk
#   4. smoke.sh         simulated install: start / probe / status / stop
#   5. gateway-sim.sh   prefix-preserving gateway reproduction
#   6. reinstall-keepdata.sh  reinstall over uninstall-kept data (dangling symlink)
#   7. core-start.sh    the proxy core really starts and binds inbound ports
#
# Usage:
#   bash tests/run-all.sh              run everything
#   bash tests/run-all.sh --no-build   skip build.sh (verify an existing .fpk)
#
# Exit: 0 all passed, 1 any failure, 77 something is BLOCKED.
#
# Note on exit code 77: it means a prerequisite artefact (cmd/, manifest,
# wizard/, an .fpk) does not exist yet — it is explicitly NOT a pass.
# ---------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=tests/lib-test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

cd "$ROOT_DIR" || { echo "cannot cd to $ROOT_DIR"; exit 1; }

DO_BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown argument: $arg"; exit 1 ;;
    esac
done

echo "=============================================================="
echo " v2raya-fnos full acceptance suite"
echo " project : $ROOT_DIR"
echo " user    : $(id -un) (uid $(id -u))"
echo " time    : $(date -Is)"
echo "=============================================================="

STAGE_NAMES=()
STAGE_RCS=()
STAGE_SECS=()

run_stage() {
    local name="$1" script="$2"
    shift 2
    printf '\n'
    echo "##############################################################"
    echo "# STAGE: $name"
    echo "##############################################################"
    local t0 t1 rc
    t0=$(date +%s)
    bash "$script" "$@"
    rc=$?
    t1=$(date +%s)
    STAGE_NAMES+=("$name")
    STAGE_RCS+=("$rc")
    STAGE_SECS+=("$((t1 - t0))")
    case "$rc" in
        0)  echo ">>> STAGE $name: PASS (${STAGE_SECS[-1]}s)" ;;
        77) echo ">>> STAGE $name: BLOCKED (${STAGE_SECS[-1]}s)" ;;
        *)  echo ">>> STAGE $name: FAIL (rc=$rc, ${STAGE_SECS[-1]}s)" ;;
    esac
    return 0
}

# 1. lint
run_stage "lint" "$TESTS_DIR/lint.sh"

# 2. build
if [ "$DO_BUILD" -eq 1 ]; then
    run_stage "build" "$ROOT_DIR/build.sh"
else
    echo ""
    echo ">>> skipping build stage (--no-build)"
    STAGE_NAMES+=("build (skipped)")
    STAGE_RCS+=("0")
    STAGE_SECS+=("0")
fi

# 3. fpk structure (needs an artifact)
run_stage "fpk-structure" "$TESTS_DIR/fpk-structure.sh"

# 4. smoke (the critical install simulation)
run_stage "smoke" "$TESTS_DIR/smoke.sh"

# 5. gateway simulation
run_stage "gateway-sim" "$TESTS_DIR/gateway-sim.sh"

# 6. reinstall over data kept from a previous uninstall (dangling assets symlink)
run_stage "reinstall-keepdata" "$TESTS_DIR/reinstall-keepdata.sh"

# 7. the proxy core actually starts and binds inbounds (geosite categories +
#    XRAY_LOCATION_ASSET propagation). Guards the "v2raya_core exited right
#    after starting" failure that the HTTP-only suites could not see.
run_stage "core-start" "$TESTS_DIR/core-start.sh"

# ---------------------------------------------------------------------------
# Consolidated result
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================="
echo " SUITE SUMMARY"
echo "=============================================================="
printf '%-16s %-10s %s\n' "STAGE" "RESULT" "TIME"
overall=0
for i in "${!STAGE_NAMES[@]}"; do
    rc="${STAGE_RCS[$i]}"
    case "$rc" in
        0)  label="PASS" ;;
        77) label="BLOCKED"; [ "$overall" -eq 0 ] && overall=77 ;;
        *)  label="FAIL"; overall=1 ;;
    esac
    printf '%-16s %-10s %ss\n' "${STAGE_NAMES[$i]}" "$label" "${STAGE_SECS[$i]}"
done

# Show the artifact if there is one.
artifact="$(ls -1t "$ROOT_DIR"/dist/*.fpk 2>/dev/null | head -1)"
echo "--------------------------------------------------------------"
if [ -n "$artifact" ]; then
    echo "artifact : $artifact"
    echo "size     : $(stat -c '%s' "$artifact") bytes"
    echo "sha256   : $(sha256sum "$artifact" | cut -d' ' -f1)"
else
    echo "artifact : none produced"
fi
echo "--------------------------------------------------------------"

case "$overall" in
    0)  echo "OVERALL: PASS" ;;
    77) echo "OVERALL: BLOCKED (some stages could not run — this is NOT a pass)" ;;
    *)  echo "OVERALL: FAIL" ;;
esac
echo "=============================================================="

exit "$overall"

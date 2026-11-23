#!/bin/bash
# ---------------------------------------------------------------------------
# tests/fpk-structure.sh — assert the packed artefact has the structure fnOS
#                          expects (contract §1, §3, §10.4)
#
# Checks, on a real .fpk produced by build.sh:
#   * the outer container is a (gzip-compressed) tar
#   * it contains: app.tgz, manifest, cmd/main, config/privilege,
#     config/resource, ICON.PNG, ICON_256.PNG
#   * the embedded app.tgz contains: server/v2raya, server/v2raya_core,
#     assets/geoip.dat, assets/geosite.dat, assets/LoyalsoldierSite.dat, ui/config
#   * the embedded app.tgz preserves the executable bit on the two binaries
#     (measured: fnpack does preserve it when it is set in the source tree)
#   * the manifest inside the .fpk has appname=v2raya and platform=x86, and
#     carries the `checksum` that fnpack injects at build time
#   * app/ui/config inside the package has no unfilled {placeholder} tokens
#
# Usage: bash tests/fpk-structure.sh [path/to/app.fpk]
#   With no argument the newest dist/*.fpk is used; if there is none the test
#   reports BLOCKED and exits 77 (run build.sh first).
#
# Exit: 0 pass, 1 failure, 77 blocked.
# ---------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=tests/lib-test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

cd "$ROOT_DIR" || { echo "cannot cd to $ROOT_DIR"; exit 1; }
install_cleanup_trap

echo "=============================================================="
echo " v2raya-fnos fpk structure check"
echo " project : $ROOT_DIR"
echo " time    : $(date -Is)"
echo "=============================================================="

# ---------------------------------------------------------------------------
# 0. Locate the artefact
# ---------------------------------------------------------------------------
section "0. artefact"

FPK="${1:-}"
if [ -z "$FPK" ]; then
    # Newest dist/*.fpk wins; fall back to any *.fpk at the project root.
    FPK="$(ls -1t "$ROOT_DIR"/dist/*.fpk 2>/dev/null | head -1)"
    [ -z "$FPK" ] && FPK="$(ls -1t "$ROOT_DIR"/*.fpk 2>/dev/null | head -1)"
fi

if [ -z "$FPK" ] || [ ! -f "$FPK" ]; then
    blocked "no .fpk found — run 'bash build.sh' first (looked in dist/*.fpk and ./*.fpk)"
    finish "fpk-structure"
    exit $?
fi

pass "artefact found: $FPK"
info "size: $(human_size "$(stat -c '%s' "$FPK")")"
info "sha256: $(sha256sum "$FPK" | cut -d' ' -f1)"

# The contract calls the outer container a plain tar; on this fnOS box with
# fnpack 1.2.4 it is gzipped (measured: `file` reports "gzip compressed data").
# Accept either, and say which one it is.
kind="$(file -b "$FPK" 2>/dev/null)"
case "$kind" in
    *gzip*) info "container: gzip-compressed tar ($kind)" ;;
    *tar*)  info "container: plain tar ($kind)" ;;
    *)      fail "artefact is neither tar nor gzip: $kind"; finish "fpk-structure"; exit $? ;;
esac

if tar -tf "$FPK" >/dev/null 2>&1; then
    pass "artefact is a readable tar archive"
else
    fail "artefact cannot be listed with tar"
    finish "fpk-structure"; exit $?
fi

WORK="$(mktemp -d /tmp/v2raya-fpk.XXXXXXXX)" || {
    fail "cannot create scratch dir under /tmp"; finish "fpk-structure"; exit $?
}
register_dir "$WORK"

tar -xf "$FPK" -C "$WORK" 2>/dev/null
[ $? -eq 0 ] || { fail "artefact could not be extracted"; finish "fpk-structure"; exit $?; }

# ---------------------------------------------------------------------------
# 1. Outer container members (contract §1)
# ---------------------------------------------------------------------------
section "1. outer container members"

for member in app.tgz manifest cmd/main config/privilege config/resource ICON.PNG ICON_256.PNG; do
    if [ -e "$WORK/$member" ]; then
        pass "fpk contains $member"
    else
        fail "fpk is missing $member"
    fi
done

# Directory presence (fnpack validates these exist; confirm they survived).
for d in cmd config wizard; do
    [ -d "$WORK/$d" ] \
        && pass "fpk contains directory $d/" \
        || fail "fpk is missing directory $d/"
done

# The outer tar must not leak build-only files into the package.
for unwanted in build.sh tests dist .git; do
    [ -e "$WORK/$unwanted" ] \
        && fail "fpk wrongly contains build-only path: $unwanted" \
        || pass "fpk excludes build-only path: $unwanted"
done

# ---------------------------------------------------------------------------
# 2. Embedded app.tgz
# ---------------------------------------------------------------------------
section "2. embedded app.tgz"

APP_TGZ="$WORK/app.tgz"
if [ ! -f "$APP_TGZ" ]; then
    fail "app.tgz missing — cannot inspect the application payload"
    finish "fpk-structure"; exit $?
fi
pass "app.tgz present ($(human_size "$(stat -c '%s' "$APP_TGZ")"))"
info "app.tgz sha256: $(sha256sum "$APP_TGZ" | cut -d' ' -f1)"

if tar -tzf "$APP_TGZ" >/dev/null 2>&1; then
    pass "app.tgz is a readable tar.gz"
else
    fail "app.tgz is not a readable tar.gz"
    finish "fpk-structure"; exit $?
fi

APPWORK="$WORK/_app"
mkdir -p "$APPWORK"
tar -xzf "$APP_TGZ" -C "$APPWORK" 2>/dev/null

for member in server/v2raya server/v2raya_core assets/geoip.dat assets/geosite.dat assets/LoyalsoldierSite.dat ui/config; do
    if [ -f "$APPWORK/$member" ]; then
        pass "app.tgz contains $member ($(human_size "$(stat -c '%s' "$APPWORK/$member")"))"
    else
        fail "app.tgz is missing $member"
    fi
done

# Executable bits must survive packing, otherwise the app cannot start after
# install (measured: fnpack preserves 755 for these files inside app.tgz).
for b in server/v2raya server/v2raya_core; do
    if [ -f "$APPWORK/$b" ]; then
        if [ -x "$APPWORK/$b" ]; then
            pass "app.tgz preserves exec bit on $b"
        else
            fail "app.tgz lost exec bit on $b (mode $(stat -c '%a' "$APPWORK/$b"))"
        fi
    fi
done

# The binaries must be intact, not truncated.
if [ -f "$APPWORK/server/v2raya" ] && [ -x "$APPWORK/server/v2raya" ]; then
    v="$("$APPWORK/server/v2raya" --version 2>&1 | head -1)"
    case "$v" in
        2.*) pass "packed server/v2raya runs and reports $v" ;;
        *)   fail "packed server/v2raya --version printed '$v'" ;;
    esac
fi

# Geo assets must be full-size, otherwise first start would try to download.
for a in assets/geoip.dat assets/geosite.dat assets/LoyalsoldierSite.dat; do
    if [ -f "$APPWORK/$a" ]; then
        sz=$(stat -c '%s' "$APPWORK/$a")
        if [ "$sz" -ge 1048576 ]; then
            pass "app.tgz $a is non-trivial ($(human_size "$sz"))"
        else
            fail "app.tgz $a is suspiciously small ($(human_size "$sz")) — first start would try to download it"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 3. Embedded manifest
# ---------------------------------------------------------------------------
section "3. manifest inside the fpk"

MAN="$WORK/manifest"
if [ ! -f "$MAN" ]; then
    fail "manifest missing from the fpk"
else
    get_key() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$MAN" | head -1; }

    appname="$(get_key appname)"
    platform="$(get_key platform)"
    version="$(get_key version)"
    checksum="$(get_key checksum)"

    [ "$appname" = "v2raya" ] \
        && pass "fpk manifest appname == v2raya" \
        || fail "fpk manifest appname is '$appname' (expected v2raya)"
    [ "$platform" = "x86" ] \
        && pass "fpk manifest platform == x86" \
        || fail "fpk manifest platform is '$platform' (expected x86)"

    if [ -n "$version" ]; then
        pass "fpk manifest version == $version"
        # fnpack 1.2.4 only accepts x.y.z or x.y.z-r; a packed artifact proving
        # it is in-range is a useful guard against a manifest regression.
        case "$version" in
            [0-9]*.[0-9]*.[0-9]*-[0-9]*) pass "version uses fnpack revision grammar (x.y.z-r)" ;;
            [0-9]*.[0-9]*.[0-9]*)        pass "version uses fnpack grammar (x.y.z)" ;;
            *) fail "version '$version' is outside fnpack's accepted grammar x.y.z[-r]" ;;
        esac
    else
        fail "fpk manifest has no version"
    fi

    # fnpack computes this at build time (contract §1).
    if [ -n "$checksum" ]; then
        pass "fpk manifest carries build-injected checksum ($checksum)"
    else
        fail "fpk manifest has no checksum — fnpack did not inject it"
    fi

    # The .fpk name must match the declared version + platform.
    base="$(basename "$FPK")"
    case "$base" in
        "v2raya_${version}_x86.fpk")
            pass "artefact filename matches version and platform: $base" ;;
        *)
            info "artefact filename '$base' does not follow v2raya_<version>_x86.fpk"
            case "$base" in
                v2raya_*_x86.fpk) info "  (it does follow the v2raya_<version>_x86.fpk shape)" ;;
            esac ;;
    esac
fi

# ---------------------------------------------------------------------------
# 4. Desktop entry inside the package must be fully resolved
# ---------------------------------------------------------------------------
section "4. app/ui/config inside the package"

UIC="$APPWORK/ui/config"
if [ ! -f "$UIC" ]; then
    fail "app.tgz is missing ui/config"
else
    leftover="$(grep -oE '\{[^}]{1,64}\}' "$UIC" 2>/dev/null | grep -v '^{0}$' | sort -u)"
    if [ -z "$leftover" ]; then
        pass "packed app/ui/config has no unfilled {placeholder} tokens"
    else
        fail "packed app/ui/config still contains placeholder(s): $(echo $leftover)"
        info "fnpack does NOT substitute placeholders (contract §1) — build.sh must supply literal values"
    fi

    python3 - "$UIC" <<'PY' > "$WORK/uicheck.out" 2>&1
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
e = cfg.get(".url", {}).get("v2raya.Application")
if e is None:
    print("FAIL  packed ui/config has no v2raya.Application entry"); sys.exit(0)
for k, want in [("gatewayPrefix", "/app/v2raya"), ("gatewaySocket", "app.sock"),
                ("url", "/app/v2raya/"), ("type", "iframe")]:
    got = e.get(k)
    print(("PASS  packed ui/config %s == %r" % (k, want)) if got == want
          else ("FAIL  packed ui/config %s == %r, expected %r" % (k, got, want)))
PY
    while IFS= read -r l; do
        case "$l" in
            PASS\ *) pass "${l#PASS  }" ;;
            FAIL\ *) fail "${l#FAIL  }" ;;
        esac
    done < "$WORK/uicheck.out"
fi

# ---------------------------------------------------------------------------
# 5. cmd/ scripts inside the package stay executable
# ---------------------------------------------------------------------------
section "5. cmd/ scripts inside the fpk"

for name in main install_init install_callback upgrade_init upgrade_callback \
            uninstall_init uninstall_callback config_init config_callback; do
    f="$WORK/cmd/$name"
    if [ -f "$f" ]; then
        if [ -x "$f" ]; then
            pass "fpk cmd/$name is executable"
        else
            fail "fpk cmd/$name lost its exec bit (mode $(stat -c '%a' "$f")) — fnOS would run it with bash and fail"
        fi
    else
        fail "fpk is missing cmd/$name"
    fi
done

finish "fpk-structure"

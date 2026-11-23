#!/bin/bash
# ---------------------------------------------------------------------------
# tests/lint.sh — static checks for the v2raya-fnos package (contract §10.1)
#
# Verifies, without executing the application:
#   * every JSON artefact parses (config/privilege, config/resource,
#     app/ui/config, wizard/*)
#   * manifest carries every field contract §3 requires and none it forbids
#   * cmd/* scripts have a bash shebang, the executable bit, and `bash -n`
#   * icons are 64x64 / 256x256 PNG and <= 1024 KiB each
#   * no hardcoded /vol{n} paths inside cmd/
#   * no custom (non-system) TRIM_-prefixed variables in wizard/
#   * app/ui/config contains no unfilled {placeholder} tokens, and the
#     gateway fields match contract §4
#
# Exit: 0 pass, 1 failure, 77 blocked (artefacts not written yet).
# Never dies on a missing file — a missing file is reported as FAIL/BLOCKED.
# ---------------------------------------------------------------------------

set -uo pipefail

# shellcheck source=tests/lib-test.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"

cd "$ROOT_DIR" || { echo "cannot cd to $ROOT_DIR"; exit 1; }

echo "=============================================================="
echo " v2raya-fnos static lint"
echo " project : $ROOT_DIR"
echo " user    : $(id -un) (uid $(id -u))"
echo " time    : $(date -Is)"
echo "=============================================================="

MANIFEST="$ROOT_DIR/manifest"
ICON64="$ROOT_DIR/ICON.PNG"
ICON256="$ROOT_DIR/ICON_256.PNG"
UICONFIG="$ROOT_DIR/app/ui/config"
PRIV="$ROOT_DIR/config/privilege"
RES="$ROOT_DIR/config/resource"

# Required lifecycle scripts, contract §2.
REQUIRED_CMD=(
    main
    install_init install_callback
    upgrade_init upgrade_callback
    uninstall_init uninstall_callback
    config_init config_callback
)

# System-provided TRIM_* names. Anything outside this set that shows up in a
# wizard field is a *custom* variable squatting on the reserved prefix, which
# contract §10.1 forbids. Derived from the live inventory on this fnOS box
# (`grep -rhoE 'TRIM_[A-Z0-9_]+' /var/apps/*/cmd /var/apps/*/wizard`).
SYSTEM_TRIM_VARS="TRIM_API_TOKEN TRIM_APPDEST TRIM_APPDEST_VOL TRIM_APPNAME
TRIM_APPVER TRIM_APP_STATUS TRIM_BACKUP_DATA_DIR TRIM_BACKUP_DIR
TRIM_CLI_DISTRIBUTION TRIM_DATA_ACCESSIBLE_PATHS TRIM_DATA_SHARE_PATHS
TRIM_ERROR TRIM_GID TRIM_GROUPNAME TRIM_HORIZON TRIM_OLD_APPVER
TRIM_OVERRIDE TRIM_PKGCONFIG TRIM_PKGDATA TRIM_PKGDEST TRIM_PKGETC
TRIM_PKGHOME TRIM_PKGINFO TRIM_PKGINST_TEMP_DIR TRIM_PKGLOG TRIM_PKGMETA
TRIM_PKGTEMP TRIM_PKGTMP TRIM_PKGVAR TRIM_RESTORE_DATA_DIR TRIM_RUN_GROUPNAME
TRIM_RUN_UID TRIM_RUN_USERNAME TRIM_RUNTIME_PYTHON TRIM_SERVICE_PORT
TRIM_SYS_ARCH TRIM_SYS_VERSION TRIM_SYS_VERSION_MAJOR TRIM_TEMP_LOGFILE
TRIM_TEMP_TPKFILE TRIM_TEMP_UPGRADE_FOLDER TRIM_UID TRIM_USERNAME"

trim_is_system() {
    case " $(echo $SYSTEM_TRIM_VARS) " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ===========================================================================
section "1. JSON artefacts"
# ===========================================================================
json_files=()

if [ -f "$PRIV" ];  then json_files+=("config/privilege"); else blocked "config/privilege not present yet"; fi
if [ -f "$RES" ];   then json_files+=("config/resource");  else blocked "config/resource not present yet"; fi
if [ -f "$UICONFIG" ]; then json_files+=("app/ui/config"); else blocked "app/ui/config not present yet"; fi

shopt -s nullglob
wizard_files=("$ROOT_DIR"/wizard/*)
shopt -u nullglob
if [ ${#wizard_files[@]} -eq 0 ]; then
    blocked "wizard/ has no files yet"
else
    for wf in "${wizard_files[@]}"; do
        [ -f "$wf" ] && json_files+=("wizard/$(basename "$wf")")
    done
fi

for rel in "${json_files[@]}"; do
    if python3 -m json.tool "$ROOT_DIR/$rel" >/dev/null 2>&1; then
        pass "valid JSON: $rel"
    else
        fail "invalid JSON: $rel"
        info "$(python3 -m json.tool "$ROOT_DIR/$rel" 2>&1 | head -3 | tr '\n' ' ')"
    fi
done

# wizard entries must be a JSON array of steps (measured format of fnOS
# wizard/* files, e.g. /var/apps/qBittorrent/wizard/install).
for wf in "${wizard_files[@]}"; do
    [ -f "$wf" ] || continue
    rel="wizard/$(basename "$wf")"
    python3 - "$wf" <<'PY'
import json, sys
p = sys.argv[1]
try:
    data = json.load(open(p, encoding="utf-8"))
except Exception as exc:
    print("not JSON: %s" % exc)
    sys.exit(1)
if not isinstance(data, list):
    print("top level is %s, expected a list of steps" % type(data).__name__)
    sys.exit(1)
for i, step in enumerate(data):
    if not isinstance(step, dict):
        print("step %d is not an object" % i)
        sys.exit(1)
    if "items" in step and not isinstance(step["items"], list):
        print("step %d: items is not a list" % i)
        sys.exit(1)
sys.exit(0)
PY
    if [ $? -eq 0 ]; then
        pass "wizard schema is a step list: $rel"
    else
        fail "wizard schema is not a step list: $rel"
    fi
done

# ===========================================================================
section "2. manifest"
# ===========================================================================
if [ ! -f "$MANIFEST" ]; then
    blocked "manifest not present yet"
else
    # Contract §3 required keys and forbidden keys.
    REQUIRED_KEYS="appname version display_name desc platform source maintainer maintainer_url distributor os_min_version desktop_uidir desktop_applaunchname checkport ctl_stop micro_app"
    FORBIDDEN_KEYS="service_port install_dep_apps"

    parsed="$(python3 - "$MANIFEST" <<'PY'
import sys, re
keys = {}
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    keys[k.strip()] = v.strip()
for k, v in keys.items():
    print("KEY\t%s\t%s" % (k, v))
PY
)"
    if [ $? -ne 0 ] || [ -z "$parsed" ]; then
        fail "manifest could not be parsed as key = value pairs"
    else
        declare -A MV=()
        while IFS=$'\t' read -r _tag k v; do
            [ "$_tag" = "KEY" ] && MV["$k"]="$v"
        done <<< "$parsed"

        for k in $REQUIRED_KEYS; do
            if [ -n "${MV[$k]:-}" ]; then
                pass "manifest key present: $k = ${MV[$k]}"
            else
                fail "manifest key missing or empty: $k"
            fi
        done
        for k in $FORBIDDEN_KEYS; do
            if [ -n "${MV[$k]:-}" ]; then
                fail "manifest key forbidden by contract §3: $k = ${MV[$k]}"
            else
                pass "manifest key correctly absent: $k"
            fi
        done

        [ "${MV[appname]:-}" = "v2raya" ] \
            && pass "manifest appname == v2raya" \
            || fail "manifest appname must be 'v2raya', got '${MV[appname]:-}'"
        [ "${MV[platform]:-}" = "x86" ] \
            && pass "manifest platform == x86" \
            || fail "manifest platform must be 'x86', got '${MV[platform]:-}'"
        [ "${MV[source]:-}" = "thirdparty" ] \
            && pass "manifest source == thirdparty" \
            || fail "manifest source must be 'thirdparty', got '${MV[source]:-}'"
        [ "${MV[desktop_applaunchname]:-}" = "v2raya.Application" ] \
            && pass "manifest desktop_applaunchname == v2raya.Application" \
            || fail "manifest desktop_applaunchname must be 'v2raya.Application', got '${MV[desktop_applaunchname]:-}'"

        # Version: contract §3 asks for 2.5.16.<fpk-rev>, but fnpack 1.2.4
        # REJECTS a four-part version ("Invalid version ... Expected format:
        # x.y.z[-r]", verified by probing it). The revision therefore uses
        # fnpack's separator: 2.5.16-<rev>. Both spellings keep the contract's
        # intent (upstream 2.5.16 + integer fpk revision); anything else is a
        # real error.
        case "${MV[version]:-}" in
            2.5.16-[0-9]*)
                pass "manifest version follows 2.5.16-<rev> (fnpack grammar): ${MV[version]}" ;;
            2.5.16.[0-9]*)
                pass "manifest version follows 2.5.16.<rev>: ${MV[version]} (build.sh will normalise it to 2.5.16-<rev> for fnpack)" ;;
            *)
                fail "manifest version must be 2.5.16-<rev> or 2.5.16.<rev>, got '${MV[version]:-}'" ;;
        esac
    fi
fi

# ===========================================================================
section "3. cmd/ lifecycle scripts"
# ===========================================================================
if [ ! -d "$ROOT_DIR/cmd" ] || [ -z "$(ls -A "$ROOT_DIR/cmd" 2>/dev/null)" ]; then
    blocked "cmd/ is missing or empty — 'cmd/ not yet implemented'; skipping all cmd checks"
else
    for name in "${REQUIRED_CMD[@]}"; do
        f="$ROOT_DIR/cmd/$name"
        rel="cmd/$name"
        if [ ! -f "$f" ]; then
            fail "required script missing: $rel"
            continue
        fi
        if [ ! -x "$f" ]; then
            fail "script not executable: $rel (chmod 755 needed)"
        else
            pass "script executable: $rel"
        fi
        first_line="$(head -n 1 "$f" 2>/dev/null)"
        case "$first_line" in
            '#!/bin/bash'|'#!/usr/bin/env bash'|'#!/bin/sh'|'#!/usr/bin/env sh')
                pass "script has shell shebang: $rel ($first_line)" ;;
            *)
                fail "script has no shell shebang: $rel (first line: '$first_line')" ;;
        esac
        if bash -n "$f" 2>/tmp/.lint_bashn.$$; then
            pass "bash -n clean: $rel"
        else
            fail "bash -n failed: $rel"
            info "$(head -3 /tmp/.lint_bashn.$$ | tr '\n' ' ')"
        fi
        rm -f /tmp/.lint_bashn.$$
    done
fi

# ===========================================================================
section "4. icons"
# ===========================================================================
check_icon() {
    local label="$1" path="$2" want="$3" rel="$4"
    if [ ! -f "$path" ]; then
        fail "$label missing: $rel"
        return
    fi
    local size
    size=$(stat -c '%s' "$path" 2>/dev/null || echo 0)
    if [ "$size" -le 1048576 ]; then
        pass "$label size <= 1024 KiB ($(human_size "$size"))"
    else
        fail "$label exceeds 1024 KiB ($(human_size "$size"))"
    fi
    local dims
    if ! dims="$(png_dims "$path")"; then
        fail "$label is not a readable PNG: $rel"
        return
    fi
    if [ "$dims" = "$want" ]; then
        pass "$label dimensions == ${want/x/ x }"
    else
        fail "$label dimensions are '${dims}' expected '${want}': $rel"
    fi
}
check_icon "ICON.PNG"     "$ICON64"  "64 64"   "ICON.PNG"
check_icon "ICON_256.PNG" "$ICON256" "256 256" "ICON_256.PNG"

# Desktop icons referenced by app/ui/config as "images/icon_{0}.png".
for pair in "64:icon_64.png" "256:icon_256.png"; do
    dim="${pair%%:*}"; file="${pair##*:}"
    p="$ROOT_DIR/app/ui/images/$file"
    if [ -f "$p" ]; then
        if d="$(png_dims "$p")" && [ "$d" = "$dim $dim" ]; then
            pass "ui icon ${dim}x${dim}: app/ui/images/$file"
        else
            fail "ui icon wrong dimensions (want ${dim}x${dim}, got '${d:-unreadable}'): app/ui/images/$file"
        fi
    else
        blocked "app/ui/images/$file not present yet"
    fi
done

# ===========================================================================
section "5. no hardcoded /vol paths in cmd/"
# ===========================================================================
if [ -d "$ROOT_DIR/cmd" ] && [ -n "$(ls -A "$ROOT_DIR/cmd" 2>/dev/null)" ]; then
    vol_hits=0
    vol_comment_hits=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        file="${line%%:*}"
        rest="${line#*:}"
        content="${rest#*:}"
        # Ignore matches that only occur inside a comment: a path in a comment
        # cannot leak a hardcoded volume into runtime behaviour.
        stripped="$(printf '%s' "$content" | sed 's/#.*//')"
        if printf '%s' "$stripped" | grep -qE '/vol[0-9]+'; then
            fail "hardcoded volume path in cmd/: ${line#*/cmd/}"
            vol_hits=$((vol_hits + 1))
        elif printf '%s' "$content" | grep -qE '/vol[0-9]+'; then
            vol_comment_hits=$((vol_comment_hits + 1))
        fi
    done < <(grep -rnE '/vol[0-9]+' "$ROOT_DIR/cmd" 2>/dev/null)
    if [ "$vol_hits" -eq 0 ]; then
        pass "no hardcoded /vol{n} paths in executed cmd/ code"
        [ "$vol_comment_hits" -gt 0 ] && info "note: $vol_comment_hits mention(s) of /vol{n} inside comments (harmless, not executed)"
    fi
else
    blocked "cmd/ absent — cannot scan for hardcoded /vol paths"
fi

# ===========================================================================
section "6. no custom TRIM_-prefixed variables in wizard/"
# ===========================================================================
if [ ${#wizard_files[@]} -eq 0 ]; then
    blocked "wizard/ has no files — cannot scan for custom TRIM_ vars"
else
    bad_trim=0
    for wf in "${wizard_files[@]}"; do
        [ -f "$wf" ] || continue
        rel="wizard/$(basename "$wf")"
        while IFS= read -r tok; do
            [ -n "$tok" ] || continue
            if trim_is_system "$tok"; then
                info "$rel references system variable $tok (allowed)"
            else
                fail "$rel uses custom TRIM_-prefixed variable: $tok (reserved prefix)"
                bad_trim=$((bad_trim + 1))
            fi
        done < <(grep -oE 'TRIM_[A-Z0-9_]+' "$wf" 2>/dev/null | sort -u)
    done
    [ "$bad_trim" -eq 0 ] && pass "no custom TRIM_-prefixed variables in wizard/"
fi

# Also report (do not fail) unfamiliar TRIM_ names in cmd/: the cmd/ owner may
# legitimately use a system variable that is absent from this box's inventory.
if [ -d "$ROOT_DIR/cmd" ] && [ -n "$(ls -A "$ROOT_DIR/cmd" 2>/dev/null)" ]; then
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        trim_is_system "$tok" || info "note: cmd/ references '$tok', not in the known system inventory (allowed, informational)"
    done < <(grep -rhoE 'TRIM_[A-Z0-9_]+' "$ROOT_DIR/cmd" 2>/dev/null | sort -u)
fi

# ===========================================================================
section "7. app/ui/config: no unfilled placeholders + gateway fields"
# ===========================================================================
if [ ! -f "$UICONFIG" ]; then
    blocked "app/ui/config not present yet"
else
    # {0} is legitimate: fnOS substitutes it at render time to pick the DPI
    # icon (images/icon_{0}.png), as shipped by e.g. /var/apps/Lucky/ui/config.
    leftover="$(grep -oE '\{[^}]{1,64}\}' "$UICONFIG" 2>/dev/null | grep -v '^{0}$' | sort -u)"
    if [ -z "$leftover" ]; then
        pass "app/ui/config has no unfilled {placeholder} tokens"
    else
        fail "app/ui/config still contains placeholder token(s): $(echo $leftover)"
    fi

    # A python check prints PASS/FAIL lines; fold them into our tally.
    while IFS= read -r l; do
        case "$l" in
            PASS\ *) pass "${l#PASS  }" ;;
            FAIL\ *) fail "${l#FAIL  }" ;;
        esac
    done < <(python3 - "$UICONFIG" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    print("FAIL  app/ui/config is not valid JSON: %s" % exc); sys.exit(0)
urls = cfg.get(".url")
if not isinstance(urls, dict) or not urls:
    print("FAIL  app/ui/config has no .url object"); sys.exit(0)
name = "v2raya.Application"
if name not in urls:
    print("FAIL  app/ui/config .url has no '%s' entry (has: %s)" % (name, ", ".join(urls))); sys.exit(0)
print("PASS  app/ui/config declares desktop entry: %s" % name)
e = urls[name]
for k, want in [("type","iframe"),("gatewayPrefix","/app/v2raya"),("gatewaySocket","app.sock"),("url","/app/v2raya/"),("protocol","")]:
    got = e.get(k, "<absent>")
    print(("PASS  app/ui/config %s == %r" % (k, want)) if got == want else ("FAIL  app/ui/config %s == %r, expected %r" % (k, got, want)))
cu = e.get("control", {})
print("PASS  app/ui/config control.accessPerm == readonly" if isinstance(cu, dict) and cu.get("accessPerm") == "readonly" else "FAIL  app/ui/config control.accessPerm must be 'readonly', got %r" % (cu,))
print("PASS  app/ui/config allUsers == false" if e.get("allUsers") is False else "FAIL  app/ui/config allUsers must be false, got %r" % (e.get("allUsers"),))
PY
)
fi

# ===========================================================================
section "8. payload binaries and assets"
# ===========================================================================
for rel in app/server/v2raya app/server/v2raya_core; do
    if assert_exec "$rel present and executable" "$ROOT_DIR/$rel"; then
        v="$("$ROOT_DIR/$rel" --version 2>&1 | head -1)"
        if [ -n "$v" ]; then
            pass "$rel runs (--version: $v)"
        else
            fail "$rel --version produced no output"
        fi
    fi
done
for rel in app/assets/geoip.dat app/assets/geosite.dat app/assets/LoyalsoldierSite.dat; do
    p="$ROOT_DIR/$rel"
    if [ -f "$p" ]; then
        sz=$(stat -c '%s' "$p")
        if [ "$sz" -ge 1048576 ]; then
            pass "$rel present and non-trivial ($(human_size "$sz"))"
        else
            fail "$rel suspiciously small ($(human_size "$sz"))"
        fi
    else
        blocked "$rel not present yet"
    fi
done

finish "lint"

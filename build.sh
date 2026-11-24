#!/bin/bash
# ===========================================================================
# build.sh — packaging pipeline for the v2rayA fnOS application
#
# See docs/ARCHITECTURE.md for the packaging design.
#
# Produces: dist/v2raya_<version>_x86.fpk
#
# Properties this script guarantees:
#   * fails loudly and early, with an actionable message, before packing
#   * non-interactive, no network access, no secrets
#   * idempotent: safe to run any number of times, always yields the same
#     artefact name and never leaves a misleading stale .fpk behind
#   * verifies what the official packer actually produced instead of trusting
#     its exit code (fnpack 1.2.4 exits 0 even when packing FAILS — measured)
#
# Usage:
#   bash build.sh [--help] [--version-suffix N] [--keep]
# ===========================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root from this script's location (independent of caller cwd)
# ---------------------------------------------------------------------------
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
    _d="$(cd -P "$(dirname "$SELF")" && pwd)"
    SELF="$(readlink "$SELF")"
    case "$SELF" in /*) ;; *) SELF="$_d/$SELF" ;; esac
done
ROOT="$(cd -P "$(dirname "$SELF")" && pwd)"

APPNAME="v2raya"
PLATFORM="x86"
FN_PACK_BIN="${FN_PACK_BIN:-/usr/local/bin/fnpack}"
DIST_DIR="$ROOT/dist"

# Icons: contract §1 — 64x64 and 256x256, each <= 1024 KiB.
ICON_MAX_BYTES=$((1024 * 1024))
# Geo assets are looked up on first start; a truncated file makes v2rayA try to
# download (contract §1.1), so refuse anything implausibly small.
GEO_MIN_BYTES=$((1024 * 1024))

VERBOSE=0
KEEP_WORK=0
VERSION_SUFFIX=""

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  [ ok ] %s\n' "$*"; }

die() {
    printf '\nBUILD FAILED: %s\n' "$*" >&2
    printf '      (no artifact was produced; previous artifacts were already removed)\n' >&2
    exit 1
}

usage() {
    cat <<USAGE
Pack the v2rayA fnOS application into dist/${APPNAME}_<version>_${PLATFORM}.fpk

Options:
  -h, --help              show this help
      --version-suffix N  override the trailing fpk revision in the artifact
                          name and embedded manifest version (e.g. 3 -> 2.5.16.3)
      --keep              keep the temporary fnpack work directory for debugging
  -v, --verbose           echo every executed check

Environment:
  FN_PACK_BIN             path to fnpack (default: /usr/local/bin/fnpack)

Exit: 0 success, 1 any check or packing failure.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)          usage; exit 0 ;;
        -v|--verbose)       VERBOSE=1 ;;
        --keep)             KEEP_WORK=1 ;;
        --version-suffix)   shift; VERSION_SUFFIX="${1:-}" ;;
        --version-suffix=*) VERSION_SUFFIX="${1#*=}" ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Track what this run produced so the summary is always truthful.
# ---------------------------------------------------------------------------
WORKDIR=""
ARTIFACT=""

cleanup() {
    local rc=$?
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        if [ "$KEEP_WORK" -eq 1 ]; then
            printf '  (kept work directory: %s)\n' "$WORKDIR"
        else
            rm -rf -- "$WORKDIR"
        fi
    fi
    return $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
say "=============================================================="
say " v2rayA / fnOS package build"
say " project : $ROOT"
say " user    : $(id -un) (uid $(id -u))"
say " host    : $(uname -m) / $(uname -s)"
say " time    : $(date -Is)"
say "=============================================================="

cd "$ROOT" || die "cannot cd to project root: $ROOT"

# ---------------------------------------------------------------------------
# 0. Remove any stale artifact FIRST.
#
# Rationale: if a later check fails, the operator must not find an old .fpk in
# dist/ and assume the current source built successfully.
# ---------------------------------------------------------------------------
step "0. clean previous artifacts"
if [ -d "$DIST_DIR" ]; then
    removed=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f -- "$f"
        info "removed stale $(basename "$f")"
        removed=$((removed + 1))
    done < <(find "$DIST_DIR" -maxdepth 1 -name '*.fpk' -type f 2>/dev/null)
    [ "$removed" -eq 0 ] && info "no stale artifacts in dist/"
else
    mkdir -p "$DIST_DIR"
    info "created dist/"
fi
# fnpack drops <appname>.fpk in the directory it runs in; make sure a leftover
# from an older manual build cannot be mistaken for this run's output.
rm -f -- "$ROOT/$APPNAME.fpk" 2>/dev/null || true
ok "dist/ is clean"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "1. preflight"

# --- 1a. packer ---
if [ ! -x "$FN_PACK_BIN" ]; then
    # Fall back to PATH so a relocated install still works.
    if command -v fnpack >/dev/null 2>&1; then
        FN_PACK_BIN="$(command -v fnpack)"
    else
        die "fnpack not found at $FN_PACK_BIN and not in PATH.
      Install the official fnOS packer (expected: /usr/local/bin/fnpack, v1.2.4)."
    fi
fi
FNPACK_VERSION="$("$FN_PACK_BIN" --help 2>&1 | sed -n 's/^Version[[:space:]]*//p' | head -1)"
[ -n "$FNPACK_VERSION" ] || FNPACK_VERSION="unknown"
ok "fnpack: $FN_PACK_BIN (version $FNPACK_VERSION)"

# --- 1b. payload binaries: exist, executable, and actually run ---
check_binary() {
    local rel="$1" name="$2"
    local path="$ROOT/$rel"
    [ -f "$path" ] || die "$rel is missing.
      It must be vendored into the repository before packaging (contract §2)."
    [ -x "$path" ] || die "$rel exists but is not executable.
      Fix with: chmod 755 $rel"
    local out rc=0
    out="$("$path" --version 2>&1 | head -1)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        die "$rel did not run successfully ('--version' exit $rc, output: '${out}').
      The binary is corrupt, truncated, or built for another architecture."
    fi
    case "$out" in
        *"$name"*) : ;;
        *) : ;;  # different banner text is fine; non-empty output is what matters
    esac
    ok "$rel runs: $out"
}
check_binary "app/server/v2raya"      "v2raya"
check_binary "app/server/v2raya_core" "v2raya_core"

# --- 1c. geo assets present and non-trivial (no runtime download) ---
for a in geoip.dat geosite.dat LoyalsoldierSite.dat; do
    p="$ROOT/app/assets/$a"
    [ -f "$p" ] || die "app/assets/$a is missing.
      Without it v2rayA downloads geo data on first start (contract §1.1), which
      hangs on restricted networks. Vendor the file into app/assets/."
    sz=$(stat -c '%s' "$p")
    [ "$sz" -ge "$GEO_MIN_BYTES" ] || die "app/assets/$a is only $sz bytes (< $GEO_MIN_BYTES).
      It is truncated or a placeholder; first start would try to download it."
    ok "app/assets/$a: $sz bytes"
done

# --- 1d. icons: exact dimensions and size cap ---
check_icon() {
    local rel="$1" want="$2"
    local path="$ROOT/$rel"
    [ -f "$path" ] || die "$rel is missing (contract §1 requires it at the project root)."
    local sz; sz=$(stat -c '%s' "$path")
    [ "$sz" -le "$ICON_MAX_BYTES" ] || die "$rel is $sz bytes, exceeding the 1024 KiB limit (contract §1)."
    local dims
    dims="$(python3 - "$path" <<'PY'
import struct, sys
p = sys.argv[1]
with open(p, "rb") as fh:
    head = fh.read(24)
if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
    sys.exit(1)
print("%d %d" % struct.unpack(">II", head[16:24]))
PY
)" || die "$rel is not a valid PNG file."
    [ "$dims" = "$want" ] || die "$rel is ${dims/x/ x } but must be ${want/x/ x } (contract §1)."
    ok "$rel: ${want/x/ x }, $sz bytes"
}
check_icon "ICON.PNG"     "64 64"
check_icon "ICON_256.PNG" "256 256"

# Desktop icon files referenced by app/ui/config as images/icon_{0}.png.
for pair in "64:icon_64.png" "256:icon_256.png"; do
    w="${pair%%:*}"; f="${pair##*:}"
    p="$ROOT/app/ui/images/$f"
    [ -f "$p" ] || die "app/ui/images/$f is missing.
      app/ui/config references images/icon_{0}.png, so the 64 and 256 variants must exist."
    dims="$(python3 - "$p" <<'PY'
import struct, sys
p = sys.argv[1]
with open(p, "rb") as fh:
    head = fh.read(24)
if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
    sys.exit(1)
print("%d %d" % struct.unpack(">II", head[16:24]))
PY
)" || die "app/ui/images/$f is not a valid PNG."
    [ "$dims" = "$w $w" ] || die "app/ui/images/$f is ${dims/x/ x } but must be ${w}x${w}."
    ok "app/ui/images/$f: ${w}x${w}"
done

# --- 1e. manifest exists with the fields contract §3 requires ---
MANIFEST="$ROOT/manifest"
[ -f "$MANIFEST" ] || die "manifest is missing at the project root (contract §3)."

manifest_get() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$MANIFEST" | head -1 | sed 's/[[:space:]]*$//'
}

REQUIRED_MANIFEST_KEYS="appname version display_name desc platform source maintainer maintainer_url distributor os_min_version desktop_uidir desktop_applaunchname checkport ctl_stop micro_app"
missing_keys=""
for k in $REQUIRED_MANIFEST_KEYS; do
    v="$(manifest_get "$k")"
    [ -n "$v" ] || missing_keys="$missing_keys $k"
done
[ -z "$missing_keys" ] || die "manifest is missing required key(s):$missing_keys
      Contract §3 lists the full set."

MANIFEST_APPNAME="$(manifest_get appname)"
MANIFEST_PLATFORM="$(manifest_get platform)"
MANIFEST_VERSION="$(manifest_get version)"

[ "$MANIFEST_APPNAME" = "$APPNAME" ] \
    || die "manifest appname is '$MANIFEST_APPNAME' but this pipeline builds '$APPNAME'."
[ "$MANIFEST_PLATFORM" = "$PLATFORM" ] \
    || die "manifest platform is '$MANIFEST_PLATFORM' but this pipeline targets '$PLATFORM'."
ok "manifest: appname=$MANIFEST_APPNAME platform=$MANIFEST_PLATFORM version=$MANIFEST_VERSION"

# Contract §3: keys that must NOT be present for a unix-socket-only app.
for forbidden in service_port install_dep_apps; do
    v="$(manifest_get "$forbidden")"
    [ -z "$v" ] || die "manifest declares '$forbidden', which contract §3 forbids for this app.
      It only listens on a unix socket and has no runtime dependencies."
done
ok "manifest: no forbidden keys (service_port, install_dep_apps)"

# fnpack 1.2.4 accepts exactly x.y.z or x.y.z-r (verified by probing it:
# "2.5.16.1" and "2.5.16-r1" are both REJECTED with
#    Invalid version "...". Expected format: x.y.z[-r]
# and every fnOS app installed on this box uses x.y.z or x.y.z-<tag>).
#
# Contract §3 asks for version = 2.5.16.<fpk-rev>. A four-part version is NOT
# packable, so we keep the contract's intent (upstream x.y.z + an integer fpk
# revision) and express the revision with fnpack's separator: 2.5.16.1 -> 2.5.16-1.
# The rewrite happens on the staged copy only; the repository's manifest is
# never modified (it belongs to another owner).
MANIFEST_VERSION_RAW="$MANIFEST_VERSION"
if [[ "$MANIFEST_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
    MANIFEST_VERSION="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    ok "version normalised for fnpack: $MANIFEST_VERSION_RAW -> $MANIFEST_VERSION (contract §3 intent preserved)"
elif [[ "$MANIFEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]]; then
    ok "manifest version is already packable: $MANIFEST_VERSION"
else
    die "manifest version '$MANIFEST_VERSION_RAW' is not packable.
      fnpack 1.2.4 requires exactly x.y.z or x.y.z-r (integers only).
      Accepted: 2.5.16, 2.5.16-1, or a four-part 2.5.16.1 (auto-converted).
      Rejected by fnpack: 2.5.16-r1, 2.5.16.1.2, 2.5.16-beta."
fi

# Optional override of the fpk revision (does NOT rewrite the manifest on disk:
# manifest is owned elsewhere; we only stages a copy for packing).
if [ -n "$VERSION_SUFFIX" ]; then
    case "$VERSION_SUFFIX" in
        ''|*[!0-9]*) die "--version-suffix must be a non-negative integer, got '$VERSION_SUFFIX'" ;;
    esac
    # Strip an existing -r revision, then append the new one in fnpack's grammar.
    base="${MANIFEST_VERSION%%-*}"
    MANIFEST_VERSION="${base}-${VERSION_SUFFIX}"
    ok "version overridden by --version-suffix: $MANIFEST_VERSION"
fi

ARTIFACT_NAME="${APPNAME}_${MANIFEST_VERSION}_${PLATFORM}.fpk"
ok "target artifact: dist/$ARTIFACT_NAME"

# ---------------------------------------------------------------------------
# 2. JSON validation (contract §9)
# ---------------------------------------------------------------------------
step "2. validate JSON files"

python3 -c 'import sys' 2>/dev/null || die "python3 is required for JSON validation but is not available."

json_candidates=()
[ -f "$ROOT/config/privilege" ] && json_candidates+=("config/privilege")
[ -f "$ROOT/config/resource" ]  && json_candidates+=("config/resource")
[ -f "$ROOT/app/ui/config" ]    && json_candidates+=("app/ui/config")
shopt -s nullglob
for wf in "$ROOT"/wizard/*; do
    [ -f "$wf" ] && json_candidates+=("wizard/$(basename "$wf")")
done
shopt -u nullglob

[ ${#json_candidates[@]} -gt 0 ] || die "no JSON artefacts found to validate (expected config/privilege, config/resource, app/ui/config, wizard/*)."

for rel in "${json_candidates[@]}"; do
    [ -f "$ROOT/$rel" ] || die "$rel is missing but is part of the package contract (§2)."
    if [ "$VERBOSE" -eq 1 ]; then info "python3 -m json.tool $rel"; fi
    python3 -m json.tool "$ROOT/$rel" >/dev/null 2>"$ROOT/.build_json.err" \
        || die "invalid JSON in $rel:
$(head -3 "$ROOT/.build_json.err" | sed 's/^/      /')"
    rm -f "$ROOT/.build_json.err"
    ok "valid JSON: $rel"
done

# Contract §2 requires all nine lifecycle scripts.
REQUIRED_CMD="main install_init install_callback upgrade_init upgrade_callback uninstall_init uninstall_callback config_init config_callback"

# ---------------------------------------------------------------------------
# 3. cmd/ script validation (exec bit + bash -n)
# ---------------------------------------------------------------------------
step "3. validate cmd/ lifecycle scripts"

[ -d "$ROOT/cmd" ] || die "cmd/ directory is missing (contract §2)."
if [ -z "$(ls -A "$ROOT/cmd" 2>/dev/null)" ]; then
    die "cmd/ is empty — lifecycle scripts are not implemented yet.
      Refusing to build a package that cannot be started or stopped."
fi

for name in $REQUIRED_CMD; do
    f="$ROOT/cmd/$name"
    [ -f "$f" ] || die "cmd/$name is missing (contract §2 requires all nine lifecycle scripts)."
done
ok "all nine required lifecycle scripts present"

cmd_count=0
shopt -s nullglob
for f in "$ROOT"/cmd/*; do
    [ -f "$f" ] || continue
    rel="cmd/$(basename "$f")"
    case "$rel" in
        cmd/*.md|cmd/*.txt|cmd/*.log|cmd/*.swp|cmd/*~) warning="(non-script file, still checked)" ;;
        *) warning="" ;;
    esac
    [ -x "$f" ] || die "$rel is not executable.
      fnOS invokes these scripts directly; a missing exec bit breaks install.
      Fix with: chmod 755 $rel"
    if [ "$VERBOSE" -eq 1 ]; then info "bash -n $rel"; fi
    bash -n "$f" 2>"$ROOT/.build_bashn.err" \
        || die "cmd/$rel has a bash syntax error:
$(head -5 "$ROOT/.build_bashn.err" | sed 's/^/      /')"
    first_line="$(head -n 1 "$f")"
    case "$first_line" in
        '#!'*) : ;;
        *) die "cmd/$rel has no shebang (first line: '$first_line'). Contract §6 requires #!/bin/bash." ;;
    esac
    cmd_count=$((cmd_count + 1))
    ok "$rel: executable, bash -n clean"
done
rm -f "$ROOT/.build_bashn.err"
shopt -u nullglob
ok "$cmd_count script(s) validated"

# ---------------------------------------------------------------------------
# 4. Contract rules: no hardcoded /vol paths, no custom TRIM_ vars
# ---------------------------------------------------------------------------
step "4. contract rule checks"

# 4a. cmd/ must not hardcode /vol{n} (contract §6). Comment-only mentions are
#     tolerated because they cannot affect runtime behaviour.
vol_violations=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%:*}"
    rest="${line#*:}"; rest="${rest#*:}"
    code_only="$(printf '%s' "$rest" | sed 's/#.*//')"
    if printf '%s' "$code_only" | grep -qE '/vol[0-9]+'; then
        vol_violations="${vol_violations}
      ${line##*/cmd/}"
    fi
done < <(grep -rnE '/vol[0-9]+' "$ROOT/cmd" 2>/dev/null || true)

if [ -n "$vol_violations" ]; then
    die "hardcoded volume path(s) found in executed cmd/ code:$vol_violations
      Contract §6 forbids this: the install volume (/vol1, /vol2, …) varies per
      device. Use \$TRIM_APPDEST / \$TRIM_PKGVAR / \$TRIM_PKGETC instead."
fi
ok "no hardcoded /vol{n} paths in cmd/"

# 4b. wizard/ must not introduce custom variables on the reserved TRIM_ prefix.
#     The allowlist is the system inventory measured on this fnOS box.
SYSTEM_TRIM="TRIM_API_TOKEN TRIM_APPDEST TRIM_APPDEST_VOL TRIM_APPNAME TRIM_APPVER TRIM_APP_STATUS TRIM_BACKUP_DATA_DIR TRIM_BACKUP_DIR TRIM_CLI_DISTRIBUTION TRIM_DATA_ACCESSIBLE_PATHS TRIM_DATA_SHARE_PATHS TRIM_ERROR TRIM_GID TRIM_GROUPNAME TRIM_HORIZON TRIM_OLD_APPVER TRIM_OVERRIDE TRIM_PKGCONFIG TRIM_PKGDATA TRIM_PKGDEST TRIM_PKGETC TRIM_PKGHOME TRIM_PKGINFO TRIM_PKGINST_TEMP_DIR TRIM_PKGLOG TRIM_PKGMETA TRIM_PKGTEMP TRIM_PKGTMP TRIM_PKGVAR TRIM_RESTORE_DATA_DIR TRIM_RUN_GROUPNAME TRIM_RUN_UID TRIM_RUN_USERNAME TRIM_RUNTIME_PYTHON TRIM_SERVICE_PORT TRIM_SYS_ARCH TRIM_SYS_VERSION TRIM_SYS_VERSION_MAJOR TRIM_TEMP_LOGFILE TRIM_TEMP_TPKFILE TRIM_TEMP_UPGRADE_FOLDER TRIM_UID TRIM_USERNAME"

trim_violations=""
shopt -s nullglob
for wf in "$ROOT"/wizard/*; do
    [ -f "$wf" ] || continue
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case " $SYSTEM_TRIM " in
            *" $tok "*) : ;;
            *) trim_violations="${trim_violations}
      wizard/$(basename "$wf"): $tok" ;;
        esac
    done < <(grep -oE 'TRIM_[A-Z0-9_]+' "$wf" 2>/dev/null | sort -u || true)
done
shopt -u nullglob

if [ -n "$trim_violations" ]; then
    die "custom variable(s) using the reserved TRIM_ prefix found in wizard/:$trim_violations
      Contract §10.1 forbids shadowing the reserved TRIM_ namespace. Rename to a
      non-reserved name (e.g. wizard_*)."
fi
ok "no custom TRIM_-prefixed variables in wizard/"

# ---------------------------------------------------------------------------
# 5. app/ui/config must contain final literal values (no placeholders)
# ---------------------------------------------------------------------------
step "5. verify app/ui/config is fully resolved"

UICONFIG="$ROOT/app/ui/config"
[ -f "$UICONFIG" ] || die "app/ui/config is missing (contract §4 requires the desktop entry here)."

# {0} is legal: fnOS substitutes it to pick the DPI-specific icon, exactly as
# shipped by the reference app at /var/apps/Lucky/ui/config (icon_{0}.png).
leftover="$(grep -oE '\{[^}]{1,64}\}' "$UICONFIG" 2>/dev/null | grep -v '^{0}$' | sort -u || true)"
if [ -n "$leftover" ]; then
    die "app/ui/config still contains unfilled placeholder(s):
$(printf '%s\n' "$leftover" | sed 's/^/      /')
      fnpack does NOT substitute {display_name}/{port}/{url-path} (contract §1);
      the final literal values must be committed in app/ui/config."
fi
ok "app/ui/config has no unfilled placeholders (only the legal {0} icon token, if any)"

# The gateway entry must be present — this is how the desktop launches the app.
python3 - "$UICONFIG" <<'PY' || die "app/ui/config does not satisfy contract §4"
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
entry = cfg.get(".url", {}).get("v2raya.Application")
if entry is None:
    sys.exit("missing .url['v2raya.Application']")
expect = {"type": "iframe", "gatewayPrefix": "/app/v2raya",
          "gatewaySocket": "app.sock", "url": "/app/v2raya/"}
bad = {k: (entry.get(k), v) for k, v in expect.items() if entry.get(k) != v}
if bad:
    sys.exit("wrong value(s): " + ", ".join("%s=%r(want %r)" % (k, a, b) for k, (a, b) in bad.items()))
PY
ok "app/ui/config declares the gateway desktop entry (type=iframe, gatewayPrefix=/app/v2raya)"

# ---------------------------------------------------------------------------
# 6. Pack
# ---------------------------------------------------------------------------
step "6. pack with fnpack"

# fnpack is ALWAYS run against a staged copy, never against the repository
# itself. Two measured reasons:
#
#  1. fnpack copies the tree into /tmp/fnpack.<ts>/ preserving the literal
#     source mode. Several source directories here are mode 000 (d--------- on
#     app, app/assets, app/ui, app/ui/images, app/server; access is granted by
#     a btrfs ACL, not by the mode bits). fnpack creates the destination
#     directory with mode 000 and then cannot write into it:
#         Copy pack ... error : mkdir /tmp/fnpack.N/app/assets: permission denied
#     Normalising the staged modes to 755/644 removes that failure, and is what
#     a real .fpk contains anyway (verified: app.tgz entries are 755).
#  2. fnpack writes <appname>.fpk into the *current working directory*. Running
#     it in a temp dir guarantees the repository never receives a stray .fpk.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/v2raya-build.XXXXXXXX")" \
    || die "cannot create a temporary build directory."
PACK_SRC="$WORKDIR/src"
mkdir -p "$PACK_SRC"

stage_entry() {
    local src="$1"
    [ -e "$src" ] || die "cannot stage missing path: $src"
    cp -r --no-preserve=all "$src" "$PACK_SRC/" 2>/dev/null \
        || die "failed to stage $src into $PACK_SRC"
}
stage_entry "$ROOT/app"
stage_entry "$ROOT/cmd"
stage_entry "$ROOT/config"
stage_entry "$ROOT/wizard"
stage_entry "$ROOT/manifest"
stage_entry "$ROOT/ICON.PNG"
stage_entry "$ROOT/ICON_256.PNG"

# Normalise modes: directories 755, files 644, then restore the exec bits the
# package actually relies on (the source tree is authoritative for those).
find "$PACK_SRC" -type d -exec chmod 755 {} + 2>/dev/null || true
find "$PACK_SRC" -type f -exec chmod 644 {} + 2>/dev/null || true
for rel in app/server/v2raya app/server/v2raya_core; do
    chmod 755 "$PACK_SRC/$rel" 2>/dev/null || die "failed to set exec bit on staged $rel"
done
for f in "$PACK_SRC"/cmd/*; do
    [ -f "$f" ] && chmod 755 "$f"
done
ok "staged a mode-normalised copy in $PACK_SRC"

# Write the fpk revision so the embedded manifest and the artifact name agree.
sed -i "s/^\([[:space:]]*version[[:space:]]*=[[:space:]]*\).*/\1${MANIFEST_VERSION}/" \
    "$PACK_SRC/manifest"
staged_ver="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*//p' "$PACK_SRC/manifest" | head -1 | sed 's/[[:space:]]*$//')"
[ "$staged_ver" = "$MANIFEST_VERSION" ] \
    || die "failed to write version=$MANIFEST_VERSION into the staged manifest (got '$staged_ver')"
ok "staged manifest version=$MANIFEST_VERSION"

# IMPORTANT: `-d` only tells fnpack where the SOURCE is; it always writes
# <appname>.fpk into the process working directory (measured: running it from
# the repo root with -d<tmp> still dropped v2raya.fpk in the repo root).
# So run it *inside* the temp dir and never in the repository.
info "running: (cd $WORKDIR && fnpack build -d $PACK_SRC)"
set +e
PACK_OUT="$(cd "$WORKDIR" && "$FN_PACK_BIN" build -d "$PACK_SRC" 2>&1)"
PACK_RC=$?
set -e

printf '%s\n' "$PACK_OUT" | sed 's/^/      /'

if [ "$PACK_RC" -ne 0 ]; then
    die "fnpack exited $PACK_RC.
      Output above. Nothing was copied to dist/."
fi

# fnpack 1.2.4 EXITS 0 EVEN WHEN PACKING FAILS (measured: missing ICON_256.PNG,
# missing manifest, invalid config JSON all print "Packing failed." and return 0).
# So the exit code is worthless here; the truth is (a) the message and (b) the
# presence of a real output file.
if printf '%s' "$PACK_OUT" | grep -qi 'packing failed'; then
    die "fnpack reported 'Packing failed.' (it still exited 0, which is a known
      fnpack 1.2.4 quirk — see the message above for the actual cause)."
fi
printf '%s' "$PACK_OUT" | grep -qi 'packing successfully' \
    || die "fnpack gave no success confirmation; refusing to trust its exit code.
      Output: $(printf '%s' "$PACK_OUT" | tr '\n' ' ')"

PRODUCED="$WORKDIR/$APPNAME.fpk"
if [ ! -f "$PRODUCED" ]; then
    # Defensive: locate anything fnpack may have emitted. Written with an
    # explicit `if` because a failing `ls` inside $() still trips `set -e`.
    PRODUCED=""
    for cand in "$WORKDIR"/*.fpk; do
        [ -f "$cand" ] || continue
        PRODUCED="$cand"
    done
fi
[ -n "$PRODUCED" ] && [ -f "$PRODUCED" ] \
    || die "fnpack claimed success but produced no .fpk in $WORKDIR."
ok "fnpack produced $(basename "$PRODUCED") ($(stat -c '%s' "$PRODUCED") bytes)"

# ---------------------------------------------------------------------------
# 7. Verify the archive before publishing it
# ---------------------------------------------------------------------------
step "7. verify the packed archive"

tar -tf "$PRODUCED" >/dev/null 2>&1 \
    || die "the produced .fpk is not a readable tar archive."

VERIFY="$WORKDIR/verify"
mkdir -p "$VERIFY"
tar -xf "$PRODUCED" -C "$VERIFY" 2>/dev/null \
    || die "the produced .fpk could not be extracted."

for member in app.tgz manifest cmd/main config/privilege config/resource ICON.PNG ICON_256.PNG; do
    [ -e "$VERIFY/$member" ] || die "the produced .fpk is missing $member (contract §1)."
done
ok "archive members present: app.tgz manifest cmd/main config/{privilege,resource} ICON*.PNG"

# The embedded manifest must carry the checksum fnpack computes at build time.
if ! sed -n 's/^[[:space:]]*checksum[[:space:]]*=[[:space:]]*//p' "$VERIFY/manifest" | head -1 | grep -q .; then
    die "the packed manifest has no checksum; fnpack did not inject it (contract §1)."
fi
packed_ver="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*//p' "$VERIFY/manifest" | head -1 | sed 's/[[:space:]]*$//')"
[ "$packed_ver" = "$MANIFEST_VERSION" ] \
    || die "packed manifest version is '$packed_ver' but the artifact name claims '$MANIFEST_VERSION'."
ok "packed manifest version=$packed_ver, checksum injected"

# app.tgz must really carry the runnable payload.
tar -tzf "$VERIFY/app.tgz" >/dev/null 2>&1 \
    || die "app.tgz inside the .fpk is not a readable tar.gz."
# Capture the listing ONCE into a variable. Piping tar into `grep -q` is a trap
# under `set -o pipefail`: grep exits at the first match, tar takes SIGPIPE and
# the pipeline reports failure even though the member is present.
APP_TGZ_ENTRIES="$(tar -tzf "$VERIFY/app.tgz" 2>/dev/null || true)"
for member in server/v2raya server/v2raya_core assets/geoip.dat assets/geosite.dat assets/LoyalsoldierSite.dat ui/config; do
    printf '%s\n' "$APP_TGZ_ENTRIES" | grep -qx -- "$member" \
        || die "app.tgz is missing $member."
done
ok "app.tgz carries server/{v2raya,v2raya_core}, assets/{geoip,geosite,LoyalsoldierSite}.dat, ui/config"

# Exec bits inside app.tgz (a 644 v2raya binary cannot start after install).
app_tgz_listing="$(tar -tvzf "$VERIFY/app.tgz" 2>/dev/null)"
for b in server/v2raya server/v2raya_core; do
    line="$(printf '%s\n' "$app_tgz_listing" | awk -v f="$b" '$NF == f {print; exit}')"
    case "$line" in
        -rwx*) : ;;
        '')    die "app.tgz does not contain $b." ;;
        *)     die "app.tgz lost the exec bit on $b: '$line'.
      Installed binaries must be 755 or the app cannot start." ;;
    esac
done
ok "app.tgz preserves exec bits on both binaries"

# cmd/ scripts inside the outer tar must stay executable.
for name in $REQUIRED_CMD; do
    [ -x "$VERIFY/cmd/$name" ] \
        || die "cmd/$name inside the .fpk is not executable (mode $(stat -c '%a' "$VERIFY/cmd/$name")).
      fnOS runs these directly; the exec bit must be set in the source tree."
done
ok "all nine cmd/ scripts inside the .fpk are executable"

# ---------------------------------------------------------------------------
# 8. Publish
# ---------------------------------------------------------------------------
step "8. publish artifact"

mkdir -p "$DIST_DIR"
ARTIFACT="$DIST_DIR/$ARTIFACT_NAME"
mv -f -- "$PRODUCED" "$ARTIFACT" || die "failed to move the artifact into $DIST_DIR."
chmod 644 "$ARTIFACT" 2>/dev/null || true
[ -f "$ARTIFACT" ] || die "artifact is not present at $ARTIFACT after publishing."
ok "artifact: $ARTIFACT"

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
SIZE="$(stat -c '%s' "$ARTIFACT")"
SHA="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
HUMAN="$(awk -v b="$SIZE" 'BEGIN{ if (b>=1048576) printf "%.2f MiB", b/1048576; else if (b>=1024) printf "%.1f KiB", b/1024; else printf "%d B", b }')"

say ""
say "=============================================================="
say " BUILD OK"
say "=============================================================="
say " artifact : $ARTIFACT"
say " size     : $SIZE bytes ($HUMAN)"
say " sha256   : $SHA"
say " version  : $MANIFEST_VERSION"
say " built by : $(id -un)"
say "=============================================================="
say ""
say "Next steps:"
say "  bash tests/fpk-structure.sh \"$ARTIFACT\"   # verify package structure"
say "  bash tests/lint.sh                        # static contract checks"
say "  bash tests/smoke.sh                       # simulated install (start/stop)"
say "  bash tests/gateway-sim.sh                 # gateway prefix-preservation"

exit 0

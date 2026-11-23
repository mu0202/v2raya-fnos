#!/bin/bash
# Fetch the third-party payload that is .gitignore'd from this repository:
#   app/server/v2raya          - v2rayA web/control binary   (upstream release)
#   app/server/v2raya_core     - v2rayA core (xray based)    (upstream release)
#   app/assets/geoip.dat       - IP rule database            (v2fly release)
#   app/assets/geosite.dat     - domain rule database        (Loyalsoldier release)
#   app/assets/LoyalsoldierSite.dat - same wire format as geosite.dat; v2rayA
#                                     reads it for GFWList mode via
#                                     `ext:LoyalsoldierSite.dat:gfw`
#
# These are deliberately NOT committed: they are ~108 MB of third-party
# artifacts that change with every upstream release.
#
# Usage:  bash scripts/fetch-payload.sh            # fetch what is missing
#         bash scripts/fetch-payload.sh --force    # re-download everything
#
# Requires: curl, and network access to github.com.

set -euo pipefail

V2RAYA_VERSION="${V2RAYA_VERSION:-2.5.16}"
ARCH="${ARCH:-amd64}"          # fnOS x86_64
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/app/server"
ASSETS="$ROOT/app/assets"
mkdir -p "$SERVER" "$ASSETS"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m[ ok ]\033[0m %s\n' "$*"; }
info() { printf '  \033[33m[ .. ]\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need=0
for f in "$SERVER/v2raya" "$SERVER/v2raya_core" \
         "$ASSETS/geoip.dat" "$ASSETS/geosite.dat" "$ASSETS/LoyalsoldierSite.dat"; do
    [ "$FORCE" -eq 1 ] || [ ! -f "$f" ] && need=1
done
if [ "$need" -eq 0 ]; then
    say "payload already present; nothing to do (use --force to refresh)"
    exit 0
fi

fetch() {  # fetch <url> <dest> <min-bytes> <label>
    local url="$1" dest="$2" min="$3" label="$4"
    if [ "$FORCE" -eq 0 ] && [ -f "$dest" ] && [ "$(stat -c '%s' "$dest")" -ge "$min" ]; then
        ok "$label already present ($(stat -c '%s' "$dest") bytes)"
        return 0
    fi

    say "downloading $label"
    local tmp="${dest}.part" attempt size
    # Two failure modes are common on this network:
    #   * "HTTP/2 stream was not closed cleanly" — connection dropped mid-body
    #   * transfer stalls and is eventually killed
    # curl's own --retry does not cover the first one, and -C - resumes the second
    # so a 30 MB file does not restart from zero after an interruption.
    for attempt in 1 2 3 4 5; do
        curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 30 \
             -C - -o "$tmp" "$url" >/dev/null 2>&1
        # curl exits non-zero when -C - finds nothing left to fetch (already
        # complete), so judge by file size, not by exit status alone.
        size="$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)"
        if [ "$size" -ge "$min" ]; then
            mv -f "$tmp" "$dest"
            ok "$label ($size bytes)"
            return 0
        fi
        info "attempt $attempt: incomplete ($size/$min bytes), retrying in $((attempt * 3))s"
        sleep $((attempt * 3))
    done
    rm -f "$tmp"
    die "download failed after 5 attempts: $url"
}

say "v2rayA $V2RAYA_VERSION for $ARCH"

fetch "https://github.com/v2rayA/v2rayA/releases/download/v${V2RAYA_VERSION}/v2raya_linux_x64_${V2RAYA_VERSION}" \
      "$SERVER/v2raya" 20000000 "server/v2raya"
fetch "https://github.com/v2rayA/v2rayA/releases/download/v${V2RAYA_VERSION}/v2raya_core_linux_x64_${V2RAYA_VERSION}" \
      "$SERVER/v2raya_core" 20000000 "server/v2raya_core"

# geoip/geosite: Loyalsoldier's build is the one v2rayA itself downloads, and it
# is the only variant that contains the `gfw` category the GFWList mode routes on.
# geoip.dat comes from v2fly/geoip (the canonical xray geoip release). It is a
# *different, larger* dataset than the geoip.dat inside Loyalsoldier's bundle;
# either works, but pin one source so builds stay reproducible.
fetch "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
      "$ASSETS/geoip.dat" 5000000 "assets/geoip.dat"
fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
      "$ASSETS/geosite.dat" 5000000 "assets/geosite.dat"

chmod 755 "$SERVER/v2raya" "$SERVER/v2raya_core"

# LoyalsoldierSite.dat must be byte-identical to geosite.dat: v2rayA parses it as
# a geosite database (`ext:LoyalsoldierSite.dat:<category>`). Shipping a
# differently encoded file here makes the core die with
# "failed to check code GFW from LoyalsoldierSite.dat / invalid body length".
say "deriving assets/LoyalsoldierSite.dat from geosite.dat"
cp -f "$ASSETS/geosite.dat" "$ASSETS/LoyalsoldierSite.dat"
ok "assets/LoyalsoldierSite.dat (same geosite wire format)"

say "verifying binaries run"
"$SERVER/v2raya" --version 2>&1 | sed 's/^/  /'
"$SERVER/v2raya_core" version 2>&1 | sed 's/^/  /'

say "done — now run: bash build.sh"

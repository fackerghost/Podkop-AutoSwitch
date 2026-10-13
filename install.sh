#!/bin/sh
# Install or update only Podkop AutoSwitch. BusyBox ash and bash compatible.
set -eu
REPO=${PAS_REPO:-fackerghost/Podkop-AutoSwitch}
VERSION=${PAS_VERSION:-latest}
CHECK=0
case "${1:-}" in
    --check) CHECK=1;;
    --help|-h) echo 'Usage: sh install.sh [--check] (optional PAS_VERSION=vX.Y.Z)'; exit 0;;
    '') ;;
    *) echo 'Unknown argument. Use --check or --help.' >&2; exit 1;;
esac
die() { echo "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die 'Run as root on OpenWrt'
[ -f /etc/openwrt_release ] || die 'OpenWrt required'
command -v podkop >/dev/null || die 'Install official ITDog Podkop first'
for tool in curl jq sha256sum; do command -v "$tool" >/dev/null || die "Required command: $tool"; done
if command -v apk >/dev/null 2>&1; then
    manager=apk; suffix=.apk
    installed=$(apk info -v podkop-autoswitch 2>/dev/null | sed -n 's/^podkop-autoswitch-//p' | head -n 1)
elif command -v opkg >/dev/null 2>&1; then
    manager=opkg; suffix=_all.ipk
    installed=$(opkg status podkop-autoswitch 2>/dev/null | awk '/^Version:/ {v=$2} /^Status:.* installed$/ {ok=1} END {if(ok) print v}')
else die 'No supported package manager'; fi
umask 077
work=$(mktemp -d /tmp/podkop-autoswitch-install.XXXXXX)
cleanup() {
    # Restore the legacy hook only if installation did not replace it itself.
    if [ -f "$work/guarded-prerm" ] && cmp -s "$work/guarded-prerm" /usr/lib/opkg/info/podkop-autoswitch.prerm; then
        cp "$work/original-prerm" /usr/lib/opkg/info/podkop-autoswitch.prerm
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
download() {
    curl -q -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 90 \
        --retry 2 --max-filesize 4194304 "$1" -o "$2"
}
if [ "$VERSION" = latest ]; then
    download "https://api.github.com/repos/$REPO/releases?per_page=100" "$work/releases.json" || die 'Cannot check GitHub releases; no changes made'
    # Include preview releases, but never a draft or an incompletely uploaded release.
    # No jq regex dependency: OpenWrt jq may be built without oniguruma.
    VERSION=$(jq -er --arg suffix "$suffix" '
      [.[] | select(.draft==false) |
        select(any(.assets[]?; .name=="SHA256SUMS")) |
        select(any(.assets[]?; (.name|startswith("podkop-autoswitch")) and (.name|endswith($suffix))))] |
      sort_by(.published_at) | last | .tag_name // empty' "$work/releases.json") || die 'No complete release for this package manager'
fi
printf '%s\n' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die 'Invalid release version'
BASE="https://github.com/$REPO/releases/download/$VERSION"
download "$BASE/SHA256SUMS" "$work/SHA256SUMS" || die 'Cannot download release checksums; no changes made'
if [ "$manager" = apk ]; then
    package=$(awk '$2 ~ /^podkop-autoswitch-[0-9][A-Za-z0-9.+_-]*\.apk$/ {print $2; exit}' "$work/SHA256SUMS")
    target=${package#podkop-autoswitch-}; target=${target%.apk}
else
    package=$(awk '$2 ~ /^podkop-autoswitch_[0-9][A-Za-z0-9.+_-]*_all\.ipk$/ {print $2; exit}' "$work/SHA256SUMS")
    target=${package#podkop-autoswitch_}; target=${target%_all.ipk}
fi
[ -n "$package" ] || die 'No matching release asset'
case "$target" in "${VERSION#v}"-*) ;; *) die 'Package version does not match release tag';; esac
echo "Installed: ${installed:-none}; available: $target ($VERSION)"
if [ -n "$installed" ]; then
    if [ "$manager" = opkg ]; then
        if opkg compare-versions "$installed" '>=' "$target"; then echo 'Already up to date. No changes made.'; exit 0; fi
    else
        comparison=$(apk version -t "$installed" "$target")
        case "$comparison" in '='|'>') echo 'Already up to date. No changes made.'; exit 0;; '<') ;; *) die 'Cannot compare package versions';; esac
    fi
fi
[ "$CHECK" = 0 ] || { echo 'A newer package is available. Run without --check to install.'; exit 0; }
download "$BASE/$package" "$work/$package" || die 'Package download failed; no changes made'
awk -v file="$package" '$2==file {print; n++} END {if(n!=1) exit 1}' "$work/SHA256SUMS" > "$work/checksum" || die 'Invalid checksum manifest'
(cd "$work"; sha256sum -c checksum) || die 'Checksum mismatch; no changes made'
[ ! -d /etc/podkop-autoswitch/transaction ] || die 'Podkop AutoSwitch has an unfinished transaction; retry after recovery'
if [ "$manager" = opkg ]; then
    # 0.1.0's prerm also detached the pool on upgrade. Backport the upgrade-only
    # guard to our own hook; normal removal is unchanged, Podkop files untouched.
    if [ "$installed" = 0.1.0-1 ] && [ -f /usr/lib/opkg/info/podkop-autoswitch.prerm ]; then
        cp -p /usr/lib/opkg/info/podkop-autoswitch.prerm "$work/original-prerm"
        { printf '#!/bin/sh\ncase "$1" in upgrade|failed-upgrade) exit 0;; esac\n'; cat "$work/original-prerm"; } > "$work/guarded-prerm"
        cp "$work/guarded-prerm" /usr/lib/opkg/info/podkop-autoswitch.prerm
        chmod 755 /usr/lib/opkg/info/podkop-autoswitch.prerm
    fi
    opkg update
    opkg install "$work/$package"
else
    # SDK APKs are unsigned. Trust only this local HTTPS/checksum-verified asset.
    apk add --allow-untrusted "$work/$package"
fi
echo 'Podkop AutoSwitch installed/updated. Settings retained. Open Services -> Podkop AutoSwitch.'
echo 'On first installation, proxy monitoring and switching are disabled.'

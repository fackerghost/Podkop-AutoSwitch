#!/bin/sh
# Compatible with BusyBox ash and bash. Does not enable proxy switching.
set -eu
REPO=${PAS_REPO:-fackerghost/Podkop-AutoSwitch}
VERSION=${PAS_VERSION:-v0.1.0}
case "$VERSION" in latest) BASE="https://github.com/$REPO/releases/latest/download";;
  *) BASE="https://github.com/$REPO/releases/download/$VERSION";; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root on OpenWrt' >&2; exit 1; }
[ -f /etc/openwrt_release ] || { echo 'OpenWrt required' >&2; exit 1; }
command -v podkop >/dev/null || { echo 'Install official ITDog Podkop first' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl is required (installed with Podkop)' >&2; exit 1; }
work=$(mktemp -d /tmp/podkop-autoswitch-install.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM HUP
curl -q -fLsS --proto '=https' --proto-redir '=https' --max-time 60 "$BASE/SHA256SUMS" -o "$work/SHA256SUMS"
if command -v apk >/dev/null 2>&1; then
    package=$(awk '/podkop-autoswitch.*\.apk$/ {print $2; exit}' "$work/SHA256SUMS")
    manager=apk
elif command -v opkg >/dev/null 2>&1; then
    package=$(awk '/podkop-autoswitch.*_all\.ipk$/ {print $2; exit}' "$work/SHA256SUMS")
    manager=opkg
else echo 'No supported package manager' >&2; exit 1; fi
case "$package" in podkop-autoswitch*[!a-zA-Z0-9_.+-]*|'') echo 'No matching release asset' >&2; exit 1;; podkop-autoswitch*) ;; *) exit 1;; esac
curl -q -fLsS --proto '=https' --proto-redir '=https' --max-time 60 "$BASE/$package" -o "$work/$package"
(cd "$work"; awk -v file="$package" '$2==file' SHA256SUMS | sha256sum -c -)
if [ "$manager" = opkg ]; then
    opkg update
    opkg install "$work/$package"
else
    # SDK-built release APKs are unsigned; explicit local installation trusts the
    # exact asset whose checksum was verified over the GitHub HTTPS channel.
    apk add --allow-untrusted "$work/$package"
fi
echo 'Installed. Open Services -> Podkop AutoSwitch. Automatic switching remains disabled by default.'

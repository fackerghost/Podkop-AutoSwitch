#!/bin/sh
# Run on OpenWrt; GitHub and package-manager mutations are replaced by fixtures.
set -eu
installer=$1
root=$(mktemp -d /tmp/pas-installer-test.XXXXXX)
trap 'rm -rf "$root"' EXIT
export PAS_INSTALL_TEST="$root" PAS_REAL_OPKG="$(command -v opkg)"
mkdir "$root/bin"
export PATH="$root/bin:$PATH"
cat > "$root/bin/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in https://*) url=$1;; -o) shift; output=$1;; esac
    shift
done
case "$url" in
    *api.github.com*) [ ! -f "$PAS_INSTALL_TEST/api-fail" ] || exit 22; cp "$PAS_INSTALL_TEST/releases.json" "$output";;
    */v0.1.1/SHA256SUMS) cp "$PAS_INSTALL_TEST/SHA256SUMS" "$output";;
    */v0.1.1/podkop-autoswitch_0.1.1-1_all.ipk) cp "$PAS_INSTALL_TEST/podkop-autoswitch_0.1.1-1_all.ipk" "$output";;
    *) echo 'Unexpected URL' >&2; exit 22;;
esac
SH
cat > "$root/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
    status) v=$(cat "$PAS_INSTALL_TEST/installed"); [ -z "$v" ] || printf 'Version: %s\nStatus: install ok installed\n' "$v";;
    compare-versions) exec "$PAS_REAL_OPKG" "$@";;
    update|install) echo "$1" >> "$PAS_INSTALL_TEST/mutations";;
    *) exit 1;;
esac
SH
chmod 700 "$root/bin/"*
cat > "$root/releases.json" <<'JSON'
[
 {"tag_name":"v9.0.0","draft":true,"published_at":"2030-01-01","assets":[{"name":"SHA256SUMS"},{"name":"podkop-autoswitch_9.0.0-1_all.ipk"}]},
 {"tag_name":"v8.0.0","draft":false,"published_at":"2029-01-01","assets":[{"name":"podkop-autoswitch_8.0.0-1_all.ipk"}]},
 {"tag_name":"v0.1.1","draft":false,"prerelease":true,"published_at":"2026-10-14","assets":[{"name":"SHA256SUMS"},{"name":"podkop-autoswitch_0.1.1-1_all.ipk"}]}
]
JSON
printf 'test package\n' > "$root/podkop-autoswitch_0.1.1-1_all.ipk"
(cd "$root"; sha256sum podkop-autoswitch_0.1.1-1_all.ipk > SHA256SUMS)
printf '0.0.9-1\n' > "$root/installed"
sh "$installer" > "$root/output"
[ "$(cat "$root/mutations")" = "$(printf 'update\ninstall')" ]
echo 'PASS chooses complete preview release and upgrades older package'
rm "$root/mutations"
printf '0.1.1-1\n' > "$root/installed"
sh "$installer" > "$root/output"
[ ! -e "$root/mutations" ]
printf '0.2.0-1\n' > "$root/installed"
sh "$installer" > "$root/output"
[ ! -e "$root/mutations" ]
echo 'PASS same and newer installed versions cause no writes'
: > "$root/installed"
sh "$installer" --check > "$root/output"
[ ! -e "$root/mutations" ]
sh "$installer" > "$root/output"
[ -e "$root/mutations" ]
echo 'PASS check-only and initial installation'
rm "$root/mutations"
echo 'corrupt download' >> "$root/podkop-autoswitch_0.1.1-1_all.ipk"
if sh "$installer" > "$root/output" 2>&1; then echo 'FAIL corrupt download accepted'; exit 1; fi
[ ! -e "$root/mutations" ]
touch "$root/api-fail"
if sh "$installer" > "$root/output" 2>&1; then echo 'FAIL API error accepted'; exit 1; fi
[ ! -e "$root/mutations" ]
echo 'PASS checksum and GitHub errors abort before package-manager writes'

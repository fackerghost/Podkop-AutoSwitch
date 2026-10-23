#!/bin/sh
# No production writes. CGI and CIDR authorization use dynamic netifd fixtures.
set -eu
files=$1
root=$(mktemp -d /tmp/pas-panel-test.XXXXXX)
trap 'rm -rf "$root"' EXIT
export PAS_LIB="$files/usr/lib/podkop-autoswitch" PAS_RUN="$root/run" PAS_BIN="$root/cli" PAS_LAN_FIXTURE="$root/network.json" PAS_PANEL_TEST="$root"
mkdir -p "$root/bin" "$PAS_RUN"
export PATH="$root/bin:$PATH"
cat > "$PAS_LAN_FIXTURE" <<'JSON'
{"interface":[{"interface":"lan","up":true,"ipv4-address":[{"address":"10.23.8.1","mask":23}],"ipv6-prefix-assignment":[{"local-address":{"address":"fd34:1234:5678:1::1","mask":64}}]},{"interface":"wan","up":true,"ipv4-address":[{"address":"192.168.77.1","mask":24}]}]}
JSON
cat > "$root/bin/ubus" <<'SH'
#!/bin/sh
cat "$PAS_LAN_FIXTURE"
SH
cat > "$PAS_BIN" <<'SH'
#!/bin/sh
case "$1" in
status) echo '{"enabled":true,"attached":true,"monitor_running":true,"phase":"healthy","available":[{"tag":"pas_aaaaaaaaaaaaaaaaaaaaaaaa-out","active":true}]}' ;;
request-scan|request-fetch) echo "$1" >> "$PAS_PANEL_TEST/actions"; echo '{"queued":true}' ;;
*) exit 1;;
esac
SH
chmod 700 "$root/bin/ubus" "$PAS_BIN"
export REMOTE_ADDR=10.23.9.25 HTTP_HOST=10.23.8.1 REQUEST_METHOD=GET
cgi="$files/www/cgi-bin/pas-panel"
"$cgi" > "$root/response"
grep -q '200 OK' "$root/response"
echo 'PASS anonymous LAN status with dynamically discovered /23 subnet, no 192.168.1.1 assumption'
for address in 10.23.10.1 192.168.77.10 203.0.113.4; do
    REMOTE_ADDR=$address "$cgi" | grep -q '403 Forbidden'
done
echo 'PASS adjacent subnet, WAN interface subnet and external clients denied'
REMOTE_ADDR=fd34:1234:5678:1::20 HTTP_HOST='[fd34:1234:5678:1::1]:8080' "$cgi" > "$root/ipv6-response"
grep -q '200 OK' "$root/ipv6-response" || { cat "$root/ipv6-response"; exit 1; }
REMOTE_ADDR=fd34:1234:5678:2::20 HTTP_HOST='[fd34:1234:5678:1::1]' "$cgi" | grep -q '403 Forbidden'
REMOTE_ADDR=::ffff:10.23.9.25 "$cgi" | grep -q '200 OK'
echo 'PASS IPv6 LAN prefix and IPv4-mapped address support'
HTTP_HOST=attacker.example "$cgi" | grep -q '403 Forbidden'
HTTP_HOST=203.0.113.1 "$cgi" | grep -q '403 Forbidden'
echo 'PASS untrusted Host denied against DNS rebinding'
export REQUEST_METHOD=POST CONTENT_TYPE=application/json HTTP_X_PAS_PANEL=1 HTTP_ORIGIN=http://10.23.8.1
post() { CONTENT_LENGTH=${#1} "$cgi" <<EOF
$1
EOF
}
post '{"action":"scan"}' | grep -q '200 OK'
[ "$(cat "$root/actions")" = request-scan ]
HTTP_ORIGIN=https://attacker.example post '{"action":"fetch"}' | grep -q '403 Forbidden'
HTTP_X_PAS_PANEL='' post '{"action":"fetch"}' | grep -q '403 Forbidden'
post '{"action":"shell"}' | grep -q '400 Bad Request'
post '{"action":"select","tag":"invalid"}' | grep -q '400 Bad Request'
post '{"action":"select","tag":"pas_aaaaaaaaaaaaaaaaaaaaaaaa-out"}' | grep -q '200 OK'
[ "$(cat "$PAS_RUN/request-select")" = pas_aaaaaaaaaaaaaaaaaaaaaaaa-out ]
[ "$(wc -l < "$root/actions")" = 1 ]
echo 'PASS anonymous limited actions, invalid input/cross-origin protection, atomic selection queue'

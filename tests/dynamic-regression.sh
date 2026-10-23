#!/bin/sh
# Actual importer and sync orchestration. Downloader fixtures replace remote
# providers; integration boundary records calls instead of modifying Podkop.
set -eu
files=$1
root=$(mktemp -d /tmp/pas-dynamic-test.XXXXXX)
export PAS_LIB="$files/usr/lib/podkop-autoswitch" PAS_RUN="$root/run" PAS_HOME="$root/home" PAS_UCI="$root/uci" PAS_SB=sing-box PAS_CONFIG_PATH=/etc/sing-box/config.json
mkdir -p "$PAS_RUN" "$PAS_HOME" "$PAS_UCI"
cp "$files/etc/config/podkop-autoswitch" "$PAS_UCI/podkop-autoswitch"
. "$PAS_LIB/common.sh"
. "$PAS_LIB/subscriptions.sh"
trap 'cleanup; rm -rf "$root"' EXIT
uci -c "$PAS_UCI" set podkop-autoswitch.first=subscription
uci -c "$PAS_UCI" set podkop-autoswitch.first.url=https://first.example/sub
uci -c "$PAS_UCI" set podkop-autoswitch.second=subscription
uci -c "$PAS_UCI" set podkop-autoswitch.second.url=https://second.example/sub
uci -c "$PAS_UCI" commit podkop-autoswitch
echo initial > "$root/mode"
echo online > "$root/wan"
config
# Exercise real HTTPS importer flow without exposing or relying on real tokens.
curl() {
    local conf='' output='' url node
    while [ "$#" -gt 0 ]; do
        case "$1" in -K) conf=$2; shift;; -o) output=$2; shift;; esac
        shift
    done
    url=$(sed 's/^url = //' "$conf" | jq -r .)
    if [ "$(cat "$root/mode")" = offline ]; then return 7; fi
    case "$url" in
        *first.example*) [ "$(cat "$root/mode")" != partial ] || return 7; node=1;;
        *second.example*) if [ "$(cat "$root/mode")" = initial ]; then node=2; else node=3; fi;;
        *) return 7;;
    esac
    jq -n --argjson port "$node" '[{type:"socks",tag:("node-"+($port|tostring)),server:"127.0.0.1",server_port:$port}]' > "$output"
}
wan_probe() { [ "$(cat "$root/wan")" = online ]; }
apply_pool() { jq -r '.[].server_port' "$PAS_HOME/staged.json" >> "$root/applied"; }
(sync_pool)
[ "$(wc -l < "$root/applied")" = 2 ]
jq -e '.state=="ready"' "$PAS_RUN/sync-status.json" >/dev/null
echo 'PASS saving subscriptions with default automatic mode fetches and attaches without a separate apply action'
echo partial > "$root/mode"
(sync_pool) && { echo 'FAIL partial update must retry'; exit 1; }
jq -e '[.[].server_port]|sort==[1,3]' "$PAS_HOME/staged.json" >/dev/null
jq -e '.state=="partial" and .failed_sources==1 and .nodes==2' "$PAS_RUN/subscription-status.json" >/dev/null
[ "$(wc -l < "$root/applied")" = 4 ]
echo 'PASS one failed provider retains cached nodes while new nodes from the other provider are applied automatically'
cp "$PAS_HOME/staged.json" "$root/last-good"
echo offline > "$root/mode"; echo offline > "$root/wan"
(sync_pool) && exit 1
cmp "$root/last-good" "$PAS_HOME/staged.json"
[ "$(wc -l < "$root/applied")" = 4 ]
jq -e '.code=="wan_unavailable"' "$PAS_RUN/sync-status.json" >/dev/null
echo 'PASS total WAN/provider outage preserves last good pool and prevents integration writes'
echo recovered > "$root/mode"; echo online > "$root/wan"
(sync_pool)
[ "$(wc -l < "$root/applied")" = 6 ]
echo 'PASS next automatic cycle recovers without user apply or reload'
uci -c "$PAS_UCI" set podkop-autoswitch.main.enabled=0
uci -c "$PAS_UCI" commit podkop-autoswitch
(sync_pool)
[ "$(wc -l < "$root/applied")" = 6 ]
echo 'PASS explicit pause prevents automatic routing ownership'

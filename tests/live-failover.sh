#!/bin/sh
# Destructive actions are restricted to processes/configs under the lab directory.
set -eu
: "${PAS_HOME:?}" "${PAS_RUN:?}" "${PAS_LIB:?}" "${PAS_BIN:?}" "${PAS_UCI:?}"
lab="$PAS_RUN/live"
mkdir -p "$lab/config" "$lab/home" "$lab/run"
cp "$PAS_UCI/podkop" "$lab/config/podkop"
cp "$PAS_UCI/podkop-autoswitch" "$lab/config/podkop-autoswitch"
jq -n --slurpfile pool "$PAS_HOME/staged.json" --slurpfile result "$PAS_RUN/staged-health.json" \
  '[$result[0][]|select(.delay_ms!=null)]|sort_by(.delay_ms)|.[0:2]|map(.tag) as $tags |
   [$pool[0][]|select(.tag as $t|$tags|index($t)!=null)]' > "$lab/home/pool.json"
[ "$(jq length "$lab/home/pool.json")" = 2 ] || { echo 'Need two payload-qualified nodes'; exit 1; }
cp "$lab/home/pool.json" "$lab/original-pool.json"
cp "$lab/home/pool.json" "$lab/home/staged.json"
uci -c "$lab/config" set podkop-autoswitch.main.cooldown=0
uci -c "$lab/config" commit podkop-autoswitch
export PAS_HOME="$lab/home" PAS_RUN="$lab/run" PAS_UCI="$lab/config" PAS_CONFIG_PATH="$lab/config.json"
secret=$(head -c 24 /dev/urandom | base64)
generate() {
    jq -n --slurpfile pool "$PAS_HOME/pool.json" --arg secret "$secret" --arg current "$1" '
      {log:{level:"error"},outbounds:($pool[0]|map(del(._pas_label))) +
        [{type:"selector",tag:"main-out",outbounds:[$pool[0][].tag],default:$current,interrupt_exist_connections:true}],
       inbounds:[{type:"mixed",tag:"service-mixed-in",listen:"127.0.0.1",listen_port:19534}],
       route:{rules:[{inbound:["service-mixed-in"],outbound:"main-out"}]},
       experimental:{clash_api:{external_controller:"127.0.0.1:19092",secret:$secret}}}' > "$PAS_CONFIG_PATH"
}
core_pid=''; monitor_pid=''
cleanup() {
    [ -z "$monitor_pid" ] || kill "$monitor_pid" 2>/dev/null || :
    [ -z "$core_pid" ] || kill "$core_pid" 2>/dev/null || :
    [ -z "$monitor_pid" ] || wait "$monitor_pid" 2>/dev/null || :
    [ -z "$core_pid" ] || wait "$core_pid" 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 1' INT TERM
generate "$(jq -r '.[0].tag' "$PAS_HOME/pool.json")"
sing-box run -c "$PAS_CONFIG_PATH" > "$lab/core.log" 2>&1 & core_pid=$!
sleep 2
"$PAS_BIN" run > "$lab/monitor.log" 2>&1 & monitor_pid=$!
i=0
while [ "$i" -lt 60 ]; do
    if [ -s "$PAS_RUN/status.json" ] && jq -e '.phase=="healthy"' "$PAS_RUN/status.json" >/dev/null; then break; fi
    sleep 2; i=$((i+1))
done
[ "$i" -lt 60 ] || { echo 'Startup qualification failed'; exit 1; }
before=$(jq -r .current "$PAS_RUN/status.json")
echo 'PASS real selector startup and HTTPS payload health'
# Restart only the isolated core, making exactly the active node unreachable.
kill "$core_pid"; wait "$core_pid" 2>/dev/null || :; core_pid=''
jq --arg tag "$before" 'map(if .tag==$tag then .server="127.0.0.1"|.server_port=1 else . end)' "$PAS_HOME/pool.json" > "$lab/broken.json"
mv "$lab/broken.json" "$PAS_HOME/pool.json"
generate "$before"
sing-box run -c "$PAS_CONFIG_PATH" > "$lab/core.log" 2>&1 & core_pid=$!
i=0; seen_one=0; seen_two=0; after=$before
while [ "$i" -lt 90 ]; do
    sleep 1; i=$((i+1))
    failures=$(jq -r '.failures // 0' "$PAS_RUN/status.json")
    [ "$failures" != 1 ] || seen_one=1
    [ "$failures" != 2 ] || seen_two=1
    after=$(jq -r .current "$PAS_RUN/status.json")
    [ "$after" = "$before" ] || break
done
[ "$after" != "$before" ] && [ "$seen_one" = 1 ] && [ "$seen_two" = 1 ] || { echo 'Failover assertions failed'; exit 1; }
echo 'PASS real three-failure sequence and API switch to payload-qualified backup'
# Recover the original node without resetting the currently selected backup.
kill "$core_pid"; wait "$core_pid" 2>/dev/null || :; core_pid=''
cp "$lab/original-pool.json" "$PAS_HOME/pool.json"
generate "$after"
sing-box run -c "$PAS_CONFIG_PATH" > "$lab/core.log" 2>&1 & core_pid=$!
sleep 16
[ "$(jq -r .current "$PAS_RUN/status.json")" = "$after" ] || { echo 'Unexpected failback'; exit 1; }
echo 'PASS real recovered node does not trigger failback'
# Exercise the actual manual-selection implementation and payload gate.
"$PAS_BIN" select "$before"
sleep 6
[ "$(jq -r .current "$PAS_RUN/status.json")" = "$before" ] || { echo 'Manual selection not adopted'; exit 1; }
echo 'PASS manual selection after payload qualification'
grep -E '^(VmRSS|VmSize):' "/proc/$monitor_pid/status" | sed 's/^/monitor /'
grep -E '^(VmRSS|VmSize):' "/proc/$core_pid/status" | sed 's/^/isolated core /'

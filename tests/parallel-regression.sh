#!/bin/sh
# Tests the actual scheduler around an isolated sing-box; payload timing is mocked.
set -eu
files=$1
root=$(mktemp -d /tmp/pas-parallel-test.XXXXXX)
export PAS_LIB="$files/usr/lib/podkop-autoswitch" PAS_RUN="$root/run" PAS_HOME="$root/home" PAS_UCI="$root/config" PAS_SB=sing-box PAS_CONFIG_PATH=/etc/sing-box/config.json
mkdir -p "$PAS_RUN" "$PAS_HOME" "$PAS_UCI"
cp "$files/etc/config/podkop-autoswitch" "$PAS_UCI/podkop-autoswitch"
. "$PAS_LIB/common.sh"
. "$PAS_LIB/subscriptions.sh"
. "$PAS_LIB/preflight.sh"
trap 'cleanup; rm -rf "$root"' EXIT
config
jq -n '[range(0;3)|{type:"socks",tag:("test-"+tostring),server:"127.0.0.1",server_port:9}]' > "$root/pool.json"
data_probe() {
    printf '+ %s\n' "$1" >> "$root/events"
    sleep 2
    printf -- '- %s\n' "$1" >> "$root/events"
    echo "$((19200-$1))"
}
QUALIFY_ATTEMPTS=2; QUALIFY_SUCCESSES=2
for concurrency in 1 3; do
    PARALLEL_CHECKS=$concurrency
    : > "$root/events"
    start=$(now)
    preflight "$root/pool.json" "$root/check-$concurrency"
    elapsed=$(($(now)-start))
    peak=$(awk '$1=="+" {n++; if(n>peak)peak=n} $1=="-" {n--} END {if(n!=0)exit 1; print peak}' "$root/events")
    [ "$peak" -eq "$concurrency" ]
    jq -se 'length==3 and all(.[]; .attempts==2 and .delay_ms!=null)' "$root/check-$concurrency/results.ndjson" >/dev/null
    [ "$(cat "$root/check-$concurrency/selected")" = test-2 ]
    echo "PASS concurrency=$concurrency, observed peak=$peak, elapsed=${elapsed}s, minimum selected"
done
# Transient N/A still requires two subsequent successes; permanently bad nodes stay.
data_probe() {
    case "$1" in
        19100) if [ ! -f "$root/retried" ]; then touch "$root/retried"; return 1; fi; echo 100;;
        19101) return 1;;
        *) echo 90;;
    esac
}
QUALIFY_ATTEMPTS=4; PARALLEL_CHECKS=3
preflight "$root/pool.json" "$root/retries"
jq -se 'length==3 and any(.[]; .tag=="test-0" and .attempts==3 and .delay_ms==100) and any(.[]; .tag=="test-1" and .attempts==4 and .delay_ms==null)' "$root/retries/results.ndjson" >/dev/null
echo 'PASS parallel retries, consecutive success requirement and retention of failed nodes'

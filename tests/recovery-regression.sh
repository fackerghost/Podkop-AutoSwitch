#!/bin/sh
# Real monitor with deterministic faults at the network boundary; no routing writes.
set -eu
: "${PAS_LIB:?}" "${PAS_RUN:?}" "${PAS_HOME:?}" "${PAS_UCI:?}"
. "$PAS_LIB/common.sh"
. "$PAS_LIB/monitor.sh"
config
root=$(mktemp -d "$PAS_RUN/recovery-test.XXXXXX")
for scenario in wan ranking retry wan_during_scan; do
  (
    PAS_RUN="$root/$scenario/run"; PAS_HOME="$root/$scenario/home"
    mkdir -p "$PAS_RUN" "$PAS_HOME"
    echo '{"section":"main","sections":[]}' > "$PAS_HOME/attachment.json"
    INTERVAL=5; THRESHOLD=3; COOLDOWN=0; AUTO=1; DATA_CHECK=0; RECOVERY_RETRY=5
    a=pas_aaaaaaaaaaaaaaaaaaaaaaaa-out; b=pas_bbbbbbbbbbbbbbbbbbbbbbbb-out; c=pas_cccccccccccccccccccccccc-out
    echo "$a" > "$PAS_RUN/choice"; echo 0 > "$PAS_RUN/tick"
    tick() { cat "$PAS_RUN/tick"; }
    now() { echo $(($(tick)*5)); }
    api_config() { return 0; }
    group() { jq -n --arg a "$a" --arg b "$b" --arg c "$c" --arg current "$(cat "$PAS_RUN/choice")" '{type:"Selector",all:[$a,$b,$c],now:$current}' > "$PAS_RUN/group.$$"; }
    probe() {
        if [ "$scenario" = retry ] && [ "$(tick)" -lt 8 ]; then return 1; fi
        case "$1" in "$a") echo 1;; "$b") echo 20;; "$c") echo 30;; esac
    }
    active_probe() {
        if [ "$1" = "$a" ]; then [ "$(tick)" = 0 ] || return 1
        elif [ "$scenario" = ranking ] && [ "$1" = "$b" ]; then return 1
        elif [ "$scenario" = retry ] && [ "$(tick)" -lt 8 ]; then return 1; fi
        echo 50
    }
    wan_probe() {
        if [ "$scenario" = wan ] && [ "$(tick)" -ge 1 ] && [ "$(tick)" -le 4 ]; then return 1; fi
        if [ "$scenario" = wan_during_scan ] && [ -e "$PAS_RUN/scanned" ]; then return 1; fi
        return 0
    }
    select_proxy() { echo "$1" > "$PAS_RUN/choice"; echo "$1" >> "$PAS_RUN/selections"; }
    # Wrap the real scan, injecting WAN loss only after candidates were checked.
    if [ "$scenario" = wan_during_scan ]; then
        eval "$(sed -n '/^scan() {/,/^}/p' "$PAS_LIB/monitor.sh" | sed '1s/scan()/real_scan()/')"
        scan() { real_scan; touch "$PAS_RUN/scanned"; }
    fi
    sleep() {
        cat "$PAS_RUN/status.json" >> "$root/$scenario/history"
        [ ! -e "$PAS_RUN/request-recovery" ] || touch "$root/$scenario/recovery-requested"
        next=$(($(tick)+1)); [ "$next" -lt 11 ] || exit 0
        echo "$next" > "$PAS_RUN/tick"
    }
    monitor
  )
done
jq -se 'all(.[0:5][]; .current=="pas_aaaaaaaaaaaaaaaaaaaaaaaa-out" and .failures==0) and all(.[1:5][];.phase=="wan_unavailable") and .[5].failures==1 and .[6].failures==2 and .[7].current=="pas_bbbbbbbbbbbbbbbbbbbbbbbb-out" and .[10].current==.[7].current' "$root/wan/history" >/dev/null
echo 'PASS WAN outage freezes selection, resets proxy failures, resumes automatically after three fresh failures'
printf '%s\n' pas_bbbbbbbbbbbbbbbbbbbbbbbb-out pas_aaaaaaaaaaaaaaaaaaaaaaaa-out pas_cccccccccccccccccccccccc-out > "$root/expected"
cmp "$root/expected" "$root/ranking/run/selections"
jq -se '.[3].current=="pas_cccccccccccccccccccccccc-out" and .[3].failures==0 and .[10].current==.[3].current' "$root/ranking/history" >/dev/null
echo 'PASS fastest current node excluded; candidate failing real route rolled back; next qualified candidate selected'
[ -e "$root/retry/recovery-requested" ]
jq -se '.[3].phase=="no_healthy_backup" and .[7].phase=="no_healthy_backup" and .[8].current=="pas_bbbbbbbbbbbbbbbbbbbbbbbb-out"' "$root/retry/history" >/dev/null
echo 'PASS exhausted pool requests urgent subscription refresh and keeps retrying until a node recovers'
[ ! -e "$root/wan_during_scan/run/selections" ]
jq -se '.[3].phase=="wan_unavailable" and all(.[];.current=="pas_aaaaaaaaaaaaaaaaaaaaaaaa-out")' "$root/wan_during_scan/history" >/dev/null
echo 'PASS WAN loss during qualification prevents a subsequent selector change'
mkdir "$PAS_RUN/mutation.lock"; echo 99999999 > "$PAS_RUN/mutation.lock/pid"
if lock_busy; then echo 'FAIL stale lock blocks monitor'; exit 1; fi
echo 'PASS stale mutation lock recovered'
rm -rf "$root"

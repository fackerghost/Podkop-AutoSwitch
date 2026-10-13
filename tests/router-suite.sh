#!/bin/sh
# Run only in a temporary laboratory directory; never mutates production UCI.
set -eu
: "${PAS_LIB:?}" "${PAS_RUN:?}" "${PAS_HOME:?}" "${PAS_UCI:?}"
. "$PAS_LIB/common.sh"
. "$PAS_LIB/subscriptions.sh"
config
work=$(mktemp -d "$PAS_RUN/tests.XXXXXX")
test_root=$work
export test_root
ucode "$PAS_LIB/links.uc" "$1/protocols.txt" 64 > "$work/protocols.ndjson"
jq -se 'length==6 and ([.[].type]|sort)==["hysteria2","shadowsocks","trojan","tuic","vless","vmess"]' "$work/protocols.ndjson" >/dev/null
normalize "$1/protocols.txt" "$work/pool.json" "$work"
jq '{outbounds:map(del(._pas_label))}' "$work/pool.json" > "$work/config.json"
"$PAS_SB" check -c "$work/config.json" > "$work/sing-box.log" 2>&1
echo 'PASS six protocol URI fixtures and installed sing-box validation'
printf '%s\n' 'vless://00000000-0000-0000-0000-000000000001@example.com:443?unknown=1' > "$work/bad.txt"
if ucode "$PAS_LIB/links.uc" "$work/bad.txt" > /dev/null 2>&1; then echo 'FAIL unknown parameter accepted'; exit 1; fi
echo 'PASS unknown parameter rejected'
printf '%s\n' '[{"type":"trojan","server":"example.com","server_port":443,"password":"test","tls":{"enabled":true,"certificate_path":"/etc/shadow"}}]' > "$work/bad.json"
if normalize "$work/bad.json" "$work/bad-pool.json" "$work" 2>/dev/null; then echo 'FAIL local file allowed'; exit 1; fi
echo 'PASS subscription local-file reference rejected'

# Deterministic fault injection exercises the real monitor, not a duplicate model.
mkdir -p "$work/fsm/run" "$work/fsm/home"
(
    PAS_RUN="$test_root/fsm/run"; PAS_HOME="$test_root/fsm/home"
    . "$PAS_LIB/monitor.sh"
    INTERVAL=5; THRESHOLD=3; COOLDOWN=0; AUTO=1; MAX_NODES=64; DATA_CHECK=0
    a=pas_aaaaaaaaaaaaaaaaaaaaaaaa-out
    b=pas_bbbbbbbbbbbbbbbbbbbbbbbb-out
    printf '0\n' > "$test_root/tick"
    printf '%s\n' "$a" > "$test_root/selected"
    now() { echo $(($(cat "$test_root/tick")*5)); }
    api_config() { return 0; }
    group() {
        [ "$(cat "$test_root/tick")" != 6 ] || return 1
        jq -n --arg a "$a" --arg b "$b" --arg current "$(cat "$test_root/selected")" \
          '{type:"Selector",all:[$a,$b],now:$current}' > "$PAS_RUN/group.$$"
    }
    probe() {
        local tick; tick=$(cat "$test_root/tick")
        if [ "$1" = "$a" ]; then
            [ "$tick" = 0 ] && echo 100 || echo 10
        elif [ "$tick" -ge 2 ] && [ "$tick" -le 4 ]; then return 1
        else [ "$tick" = 0 ] && echo 50 || echo 1; fi
    }
    active_probe() { probe "$1"; }
    select_proxy() { printf '%s\n' "$1" > "$test_root/selected"; }
    sleep() {
        cat "$PAS_RUN/status.json" >> "$test_root/history.ndjson"
        local tick; tick=$(($(cat "$test_root/tick")+1))
        [ "$tick" -lt 8 ] || exit 0
        echo "$tick" > "$test_root/tick"
    }
    monitor
)
jq -se '
  .[0].current=="pas_bbbbbbbbbbbbbbbbbbbbbbbb-out" and
  .[1].current==.[0].current and
  .[2].failures==1 and .[3].failures==2 and
  .[4].current=="pas_aaaaaaaaaaaaaaaaaaaaaaaa-out" and .[4].failures==0 and
  .[5].current==.[4].current and
  .[6].phase=="api_unavailable" and .[6].failures==0 and
  .[7].current==.[4].current
' "$work/history.ndjson" >/dev/null
echo 'PASS startup minimum, three failures, failover, no failback, API-outage distinction'
printf '%s\n' '{"current":"a","failures":2,"threshold":3,"auto":true,"now":10,"last_switch":0,"cooldown":30,"healthy":false,"candidate":"b"}' |
    jq -f "$PAS_LIB/policy.jq" | jq -e '.action=="cooldown"' >/dev/null
printf '%s\n' '{"current":"a","failures":2,"threshold":3,"auto":false,"now":99,"last_switch":0,"cooldown":0,"healthy":false,"candidate":"b"}' |
    jq -f "$PAS_LIB/policy.jq" | jq -e '.action=="disabled"' >/dev/null
echo 'PASS cooldown and disabled automatic switching'

# Exercise the real watchdog against temporary files with a harmless init stub.
mkdir -p "$work/recovery/config" "$work/recovery/home/transaction"
tx="$work/recovery/home/transaction"
printf 'old UCI\n' > "$tx/podkop"
printf 'old sing-box\n' > "$tx/config.json"
printf '%s\n' "$work/recovery/sing-box.json" > "$tx/config-path"
printf 'new UCI\n' > "$work/recovery/config/podkop"
printf 'new sing-box\n' > "$work/recovery/sing-box.json"
printf '#!/bin/sh\nexit 0\n' > "$work/recovery/init"
chmod 700 "$work/recovery/init"
PAS_PODKOP_INIT="$work/recovery/init" sh "$PAS_LIB/watchdog.sh" "$tx" "$work/recovery/config" "$work/recovery/home" now
[ "$(cat "$work/recovery/config/podkop")" = 'old UCI' ]
[ "$(cat "$work/recovery/sing-box.json")" = 'old sing-box' ]
[ ! -d "$tx" ]
echo 'PASS watchdog restores both files without touching production service'
rm -rf "$work"

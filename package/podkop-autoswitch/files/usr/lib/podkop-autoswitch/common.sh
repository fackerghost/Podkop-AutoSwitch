# SPDX-License-Identifier: GPL-2.0-or-later
PAS_LIB=${PAS_LIB:-/usr/lib/podkop-autoswitch}
PAS_RUN=${PAS_RUN:-/tmp/podkop-autoswitch}
PAS_HOME=${PAS_HOME:-/etc/podkop-autoswitch}
PAS_UCI=${PAS_UCI:-/etc/config}
PAS_SB=${PAS_SB:-sing-box}
PAS_PODKOP_INIT=${PAS_PODKOP_INIT:-/etc/init.d/podkop}
umask 077
mkdir -p "$PAS_RUN" "$PAS_HOME" || exit 1
chmod 700 "$PAS_RUN" "$PAS_HOME"
cleanup() {
    if [ -n "${PAS_SCAN_CHILD:-}" ]; then kill "$PAS_SCAN_CHILD" 2>/dev/null || :; wait "$PAS_SCAN_CHILD" 2>/dev/null || :; fi
    if [ "$(cat "$PAS_RUN/monitor.pid" 2>/dev/null)" = "$$" ]; then rm -f "$PAS_RUN/monitor.pid"; fi
    if [ "${PAS_FETCH_ACTIVE:-0}" = 1 ]; then
        fetch_status error interrupted
    fi
    if [ "${PAS_SCAN_ACTIVE:-0}" = 1 ]; then
        scan_status error interrupted
    fi
    if [ "$(cat "$PAS_RUN/preflight.lock/pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$PAS_RUN/preflight.lock/pid"; rmdir "$PAS_RUN/preflight.lock" 2>/dev/null || :
    fi
    if [ "$(cat "$PAS_RUN/updater.pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$PAS_RUN/updater.pid"
    fi
    case "${PAS_WORK:-}" in "$PAS_RUN"/fetch.*|"$PAS_RUN"/plan.*|"$PAS_RUN"/apply.*) rm -rf "$PAS_WORK";; esac
    local kind
    for kind in mutation fetch; do
        if [ "$(cat "$PAS_RUN/$kind.lock/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$PAS_RUN/$kind.lock/pid"; rmdir "$PAS_RUN/$kind.lock" 2>/dev/null || :
        fi
    done
    rm -f "$PAS_RUN"/auth.$$.* "$PAS_RUN/group.$$" "$PAS_RUN/results.$$" "$PAS_RUN/candidates.$$" "$PAS_RUN/members.$$" "$PAS_RUN/selected.$$"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
log() { logger -t podkop-autoswitch -- "$*"; }
fail() { log "$*"; printf '%s\n' "$*" >&2; return 1; }
get() { local x; x=$(uci -c "$PAS_UCI" -q get "podkop-autoswitch.main.$1"); printf '%s\n' "${x:-$2}"; }
num() { case "$2" in ''|*[!0-9]*) return 1;; esac; [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || return 1; }
config() {
    SECTION=$(get section main)
    case "$SECTION" in ''|*[!a-zA-Z0-9_]*|pas_*) fail 'Invalid target section'; return 1;; esac
    SELECTOR="$SECTION-out"
    INTERVAL=$(get interval 5); THRESHOLD=$(get failure_threshold 3)
    TIMEOUT=$(get timeout_ms 1500); COOLDOWN=$(get cooldown 30)
    AUTO=$(get auto_switch 1); UPDATE=$(get update_interval 3600)
    RECOVERY_RETRY=$(get recovery_retry 10); OUTAGE_REFRESH=$(get outage_refresh 60)
    MAX_NODES=$(get max_nodes 64)
    MAX_BYTES=$(get max_bytes 1048576)
    DATA_CHECK=$(get data_check 1)
    DATA_URL=$(get data_url 'https://www.cloudflare.com/cdn-cgi/trace')
    DATA_FALLBACK=$(get data_fallback_url 'https://www.google.com/robots.txt')
    QUALIFY_URL=$(get qualify_url 'https://speed.cloudflare.com/__down?bytes=16384')
    QUALIFY_ATTEMPTS=$(get qualify_attempts 4); QUALIFY_SUCCESSES=$(get qualify_successes 2)
    PARALLEL_CHECKS=$(get parallel_checks 3)
    num interval "$INTERVAL" 2 3600 && num threshold "$THRESHOLD" 1 20 &&
    num timeout "$TIMEOUT" 200 10000 && num cooldown "$COOLDOWN" 0 86400 &&
    num update "$UPDATE" 300 2592000 && num nodes "$MAX_NODES" 1 256 &&
    num bytes "$MAX_BYTES" 1024 8388608 || { fail 'Invalid numeric configuration'; return 1; }
    case "$AUTO" in 0|1) ;; *) return 1;; esac
    num attempts "$QUALIFY_ATTEMPTS" 2 6 && num successes "$QUALIFY_SUCCESSES" 2 "$QUALIFY_ATTEMPTS" || return 1
    num parallel_checks "$PARALLEL_CHECKS" 1 8 || return 1
    num recovery_retry "$RECOVERY_RETRY" 5 300 && num outage_refresh "$OUTAGE_REFRESH" 15 3600 || return 1
    WAN_URLS=$(get wan_url 'https://1.1.1.1/cdn-cgi/trace https://8.8.8.8/resolve?name=example.com&type=A')
    local wan_url wan_count=0
    for wan_url in $WAN_URLS; do
        case "$wan_url" in https://*) ;; *) return 1;; esac
        wan_count=$((wan_count+1))
    done
    [ "$wan_count" -ge 1 ] && [ "$wan_count" -le 3 ] || return 1
    case "$DATA_CHECK" in 0|1) ;; *) return 1;; esac
    case "$DATA_URL:$QUALIFY_URL:$DATA_FALLBACK" in https://*:https://*:https://*) ;; *) return 1;; esac
    URLS=$(get test_url 'https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204')
    local url n=0
    for url in $URLS; do
        case "$url" in https://*) ;; *) fail 'Health URLs must use HTTPS'; return 1;; esac
        n=$((n+1))
    done
    [ "$n" -ge 1 ] && [ "$n" -le 3 ] || return 1
    CONFIG_PATH=${PAS_CONFIG_PATH:-$(uci -c "$PAS_UCI" -q get podkop.settings.config_path)}
    CONFIG_PATH=${CONFIG_PATH:-/etc/sing-box/config.json}
}
now() { cut -d. -f1 /proc/uptime; }
lock_busy() {
    local directory="$PAS_RUN/${1:-mutation}.lock" pid
    [ -d "$directory" ] || return 1
    pid=$(cat "$directory/pid" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$directory/pid"; rmdir "$directory" 2>/dev/null || return 0
        return 1
    fi
    return 0
}
lock() {
    local directory="$PAS_RUN/${1:-mutation}.lock"
    if ! mkdir "$directory" 2>/dev/null; then
        local pid; pid=$(cat "$directory/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$directory/pid"
            rmdir "$directory" 2>/dev/null || return 1
            mkdir "$directory" 2>/dev/null || return 1
        else
            fail 'Another update/transaction is running'; return 1
        fi
    fi
    echo $$ > "$directory/pid"
    trap cleanup EXIT
    trap 'exit 1' INT TERM HUP
}
unlock() {
    local directory="$PAS_RUN/${1:-mutation}.lock"
    if [ "$(cat "$directory/pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$directory/pid"; rmdir "$directory" 2>/dev/null || :
    fi
}
atomic() { cp "$1" "$2.new.$$" && chmod 600 "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
api_config() {
    local addr secret host port
    addr=$(jq -er '.experimental.clash_api.external_controller' "$CONFIG_PATH") || return 1
    host=${addr%:*}; port=${addr##*:}
    num port "$port" 1 65535 || return 1
    case "$host" in
        0.0.0.0|127.0.0.1) host=127.0.0.1;;
        *) ip -4 addr show | grep -F "inet $host/" >/dev/null || { fail 'Controller must be local IPv4'; return 1; };;
    esac
    API="http://$host:$port"
    AUTH="$PAS_RUN/auth.$$.$port"
    # Header is kept off the process command line. jq escapes curl config syntax.
    jq -r '(.experimental.clash_api.secret // "") | if length > 0 then
        "header = " + ("Authorization: Bearer " + . | @json) else "" end' "$CONFIG_PATH" > "$AUTH"
}
api() {
    local method="$1" path="$2"; shift 2
    curl -q -K "$AUTH" --noproxy '*' -fsS --connect-timeout 2 --max-time "$((TIMEOUT/1000+3))" \
        -X "$method" "$API$path" "$@" 2>/dev/null
}
uri() { jq -nr --arg s "$1" '$s|@uri'; }
group() {
    api GET "/proxies/$(uri "$SELECTOR")" > "$PAS_RUN/group.$$" &&
    jq -e '.type == "Selector" and (.all|type == "array") and (.now|type == "string")' "$PAS_RUN/group.$$" >/dev/null
}
probe() {
    local tag="$1" url delay best='' enc
    enc=$(uri "$tag")
    for url in $URLS; do
        delay=$(api GET "/proxies/$enc/delay?timeout=$TIMEOUT&url=$(uri "$url")" | jq -er '.delay | select(type == "number" and . >= 0)' 2>/dev/null)
        if [ -n "$delay" ]; then
            if [ -z "$best" ] || [ "$delay" -lt "$best" ]; then best=$delay; fi
            # First successful endpoint is sufficient and avoids double traffic every tick.
            break
        fi
    done
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}
data_probe() {
    local port="$1" url="$2" minimum="$3" result
    # Full HTTPS GET through SOCKS, with bounded bytes/time and a required body.
    # A responding TCP port, ICMP, or an HTTP redirect/error is not sufficient.
    result=$(curl -q --noproxy '' --socks5-hostname "127.0.0.1:$port" -sS \
        --proto '=https' --connect-timeout 2 --max-time "$((TIMEOUT/1000+2))" \
        --max-filesize 65536 -o /dev/null -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null) || return 1
    printf '%s\n' "$result" | awk -v minimum="$minimum" '$1 == 200 && $2 >= minimum {printf "%.0f\n", $3*1000; ok=1} END {if (!ok) exit 1}'
}
active_probe() {
    if [ "$DATA_CHECK" = 1 ]; then
        local port
        port=$(jq -er '.inbounds[]|select(.tag=="service-mixed-in" and .listen=="127.0.0.1")|.listen_port' "$CONFIG_PATH") || return 1
        data_probe "$port" "$DATA_URL" 32 || data_probe "$port" "$DATA_FALLBACK" 32
    else probe "$1"; fi
}
select_proxy() {
    local tag="$1" data
    group || return 1
    jq -e --arg t "$tag" '.all | index($t) != null' "$PAS_RUN/group.$$" >/dev/null || return 1
    data=$(jq -nc --arg t "$tag" '{name:$t}')
    api PUT "/proxies/$(uri "$SELECTOR")" -H 'Content-Type: application/json' --data-binary "$data" >/dev/null || return 1
    group && [ "$(jq -r .now "$PAS_RUN/group.$$")" = "$tag" ]
}
doctor() {
    local x ok=1
    for x in uci ucode jq curl sha256sum base64 logger ip "$PAS_SB"; do
        command -v "$x" >/dev/null || { printf 'Missing dependency: %s\n' "$x"; ok=0; }
    done
    [ "$ok" = 1 ] || return 1
    "$PAS_SB" version | head -n 3
    [ -r /etc/openwrt_release ] && cat /etc/openwrt_release
    for x in helpers.sh sing_box_config_facade.sh sing_box_config_manager.sh; do
        [ -r "/usr/lib/podkop/$x" ] || { fail 'Podkop library missing'; return 1; }
    done
    grep -q 'sing_box_cf_add_json_outbound()' /usr/lib/podkop/sing_box_config_facade.sh &&
    grep -q 'sing_box_cm_add_raw_outbound()' /usr/lib/podkop/sing_box_config_manager.sh || return 1
    [ "$(uci -c "$PAS_UCI" -q get "podkop.$SECTION")" = section ] || return 1
    [ "$(uci -c "$PAS_UCI" -q get "podkop.$SECTION.connection_type")" = proxy ] || { fail 'Target is not a proxy section'; return 1; }
    "$PAS_SB" check -c "$CONFIG_PATH" > "$PAS_RUN/check.log" 2>&1 || { fail 'Current sing-box configuration fails validation'; return 1; }
    api_config && api GET /version | jq -e 'type == "object"' || { fail 'Clash API unavailable'; return 1; }
}

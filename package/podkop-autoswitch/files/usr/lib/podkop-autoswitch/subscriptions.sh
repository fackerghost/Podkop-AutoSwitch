# SPDX-License-Identifier: GPL-2.0-or-later
normalize() {
    local input="$1" output="$2" work="$3" line count=0 json hash tag label
    : > "$work/nodes.ndjson"
    if jq -e . "$input" >/dev/null 2>&1; then
        jq -c 'if type=="array" then . elif .outbounds then .outbounds elif .type then [.] else error("No outbounds") end |
            if type!="array" then error("Invalid outbounds") else .[] end' "$input" > "$work/raw.ndjson" || return 1
    else
        if ! ucode "$PAS_LIB/links.uc" "$input" "$MAX_NODES" > "$work/raw.ndjson" 2> "$work/parse.log"; then
            fail 'Unsupported subscription URI/format; use native sing-box JSON for advanced options'; return 1
        fi
    fi
    count=0
    while IFS= read -r json; do
        count=$((count+1)); [ "$count" -le "$MAX_NODES" ] || return 1
        # Remote subscriptions supply independent outbounds, never local file paths,
        # chaining, routing, selectors, or process execution settings.
        printf '%s' "$json" | jq -e '
            type=="object" and (.type|type=="string") and (.server|type=="string" and length>0) and
            (.server_port|type=="number" and .>=1 and .<=65535 and floor==.) and
            (.type as $t | ["direct","block","dns","selector","urltest"]|index($t)==null) and
            (has("detour")|not) and
            ([paths as $p | select($p != ["transport","path"]) | $p[-1] | select(type=="string") |
                select(. == "path" or . == "paths" or endswith("_path") or endswith("_paths") or . == "command" or . == "script")] | length==0)
        ' >/dev/null || { fail "Unsafe or non-independent outbound at index $count"; return 1; }
        # transport.path is a URL path, not a filesystem path (handled below).
        label=$(printf '%s' "$json" | jq -r '.tag // (.type + " #" + (.server_port|tostring))')
        json=$(printf '%s' "$json" | jq -cS 'del(.tag, ._pas_label)') || return 1
        hash=$(printf '%s' "$json" | sha256sum | cut -c1-24)
        tag="pas_$hash-out"
        printf '%s' "$json" | jq -c --arg tag "$tag" --arg label "$label" '. + {tag:$tag,_pas_label:$label}' >> "$work/nodes.ndjson" || return 1
    done < "$work/raw.ndjson"
    jq -sc 'unique_by(.tag) | sort_by(.tag) | if length==0 then error("Empty subscription") else . end' "$work/nodes.ndjson" > "$output"
}
fetch() {
    config || return 1
    lock || return 1
    PAS_FETCH_ACTIVE=1; PAS_FETCH_SOURCE=0; PAS_FETCH_CODE=internal_error; PAS_FETCH_DETAIL=0
    fetch_status running
    if fetch_pool; then
        fetch_status success
        PAS_FETCH_ACTIVE=0
        return 0
    fi
    fetch_status error "$PAS_FETCH_CODE"
    PAS_FETCH_ACTIVE=0
    return 1
}
# Only safe status codes, counts and timestamps leave this interface. The raw
# downloader/parser/core diagnostics may contain subscription credentials.
fetch_status() {
    local previous=/dev/null nodes=0
    [ ! -s "$PAS_RUN/subscription-status.json" ] || previous="$PAS_RUN/subscription-status.json"
    [ ! -s "$PAS_HOME/staged.json" ] || nodes=$(jq length "$PAS_HOME/staged.json")
    jq -n --slurpfile old "$previous" --arg state "$1" --arg code "${2:-}" \
        --argjson time "$(date +%s)" --argjson nodes "$nodes" \
        --argjson source "${PAS_FETCH_SOURCE:-0}" --argjson detail "${PAS_FETCH_DETAIL:-0}" \
        '{state:$state,code:$code,updated_at:$time,nodes:$nodes,source:$source,detail:$detail,
          last_success:(if $state=="success" then $time else ($old[0].last_success // null) end)}' \
        > "$PAS_RUN/subscription-status.json.$$" &&
        mv "$PAS_RUN/subscription-status.json.$$" "$PAS_RUN/subscription-status.json"
}
fetch_error() { PAS_FETCH_CODE=$1; fail "$2"; }
fetch_pool() {
    local work section url enabled count=0
    work=$(mktemp -d "$PAS_RUN/fetch.XXXXXX") || return 1
    PAS_WORK=$work
    : > "$work/pools.ndjson"
    uci -c "$PAS_UCI" -q show podkop-autoswitch | sed -n 's/^podkop-autoswitch\.\([^=]*\)=subscription$/\1/p' > "$work/sources"
    while IFS= read -r section; do
        enabled=$(uci -c "$PAS_UCI" -q get "podkop-autoswitch.$section.enabled")
        [ "$enabled" != 0 ] || continue
        PAS_FETCH_SOURCE=$((count+1))
        fetch_status running
        url=$(uci -c "$PAS_UCI" -q get "podkop-autoswitch.$section.url")
        case "$url" in https://*) ;; *) fetch_error invalid_url 'Subscription must use HTTPS'; return 1;; esac
        # curl config quotes/escapes untrusted text. URL is never a shell argument.
        jq -nr --arg url "$url" '"url = " + ($url|@json)' > "$work/curl.conf"
        # ulimit also bounds chunked responses on older curl implementations.
        (ulimit -f "$((MAX_BYTES/512+2))"; curl -q -K "$work/curl.conf" --proto '=https' --proto-redir '=https' \
            --noproxy '*' -fLsS --connect-timeout 10 --max-time 45 --max-redirs 3 \
            --max-filesize "$MAX_BYTES" -A 'Podkop-AutoSwitch/0.1 sing-box' -o "$work/body" 2> "$work/download.log") || {
                PAS_FETCH_DETAIL=$?
                fetch_error download_failed "Subscription $PAS_FETCH_SOURCE download failed (curl $PAS_FETCH_DETAIL); active pool preserved"; return 1;
            }
        [ "$(wc -c < "$work/body")" -le "$MAX_BYTES" ] || { fetch_error too_large 'Subscription exceeds byte limit'; return 1; }
        normalize "$work/body" "$work/pool.json" "$work" || { PAS_FETCH_CODE=unsupported_format; return 1; }
        cat "$work/pool.json" >> "$work/pools.ndjson"
        count=$((count+1))
    done < "$work/sources"
    [ "$count" -gt 0 ] || { fetch_error no_subscriptions 'No enabled subscriptions'; return 1; }
    jq -sc 'add | unique_by(.tag) | sort_by(.tag)' "$work/pools.ndjson" > "$work/combined.json" || return 1
    [ "$(jq length "$work/combined.json")" -le "$MAX_NODES" ] || { fetch_error too_many_nodes 'Combined pool too large'; return 1; }
    # Validate with the actual installed core before accepting any update.
    jq -n --slurpfile nodes "$work/combined.json" '{outbounds:($nodes[0]|map(del(._pas_label)))}' > "$work/check.json"
    "$PAS_SB" check -c "$work/check.json" > "$work/check.log" 2>&1 || { fetch_error core_rejected 'Installed sing-box rejects subscription; active pool preserved'; return 1; }
    if ! cmp -s "$work/combined.json" "$PAS_HOME/staged.json"; then
        atomic "$work/combined.json" "$PAS_HOME/staged.json" || return 1
    fi
    date +%s > "$PAS_RUN/last-fetch"
    log "Subscription staged: $(jq length "$work/combined.json") servers"
    # Work directory contains credentials; remove only this mktemp-owned directory.
    rm -rf "$work"
}
updater() {
    local due=0 t
    printf '%s\n' "$$" > "$PAS_RUN/updater.pid"
    while :; do
        t=$(now)
        if [ "$t" -ge "$due" ] || [ -e "$PAS_RUN/request-fetch" ]; then
            rm -f "$PAS_RUN/request-fetch"
            if "$PAS_BIN" fetch; then
                due=$((t+UPDATE))
                # Disabling monitoring must also prevent automatic Podkop writes.
                [ "$AUTO_APPLY" = 1 ] && [ "$(get enabled 0)" = 1 ] && "$PAS_BIN" apply
            else
                due=$((t+300)); log 'Subscription update failed; retry in 300s'
            fi
        fi
        if [ -e "$PAS_RUN/request-apply" ]; then
            rm -f "$PAS_RUN/request-apply"
            if [ "$(get enabled 0)" = 1 ]; then
                "$PAS_BIN" apply || log 'Requested application failed; inspect status and system log'
            else
                log 'Application skipped: monitoring is disabled'
            fi
        fi
        if [ -e "$PAS_RUN/request-scan" ]; then
            rm -f "$PAS_RUN/request-scan"
            "$PAS_BIN" preflight > /dev/null || log 'Pool preflight found no usable server'
        fi
        sleep 5
    done
}
request_work() {
    local action="$1" pid init="${PAS_INIT:-/etc/init.d/podkop-autoswitch}"
    if [ "$action" = apply ] && [ "$(get enabled 0)" != 1 ]; then
        echo '{"ok":false,"code":"monitoring_disabled"}'; return 1
    fi
    if [ "$action" = scan ] && [ ! -s "$PAS_HOME/staged.json" ]; then
        echo '{"ok":false,"code":"no_pool"}'; return 1
    fi
    touch "$PAS_RUN/request-$action" || return 1
    pid=$(cat "$PAS_RUN/updater.pid" 2>/dev/null)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        # Also recover after an explicit service stop or an older installation.
        if ! "$init" start >/dev/null 2>&1; then
            rm -f "$PAS_RUN/request-$action"
            echo '{"ok":false,"code":"worker_unavailable"}'; return 1
        fi
    fi
    echo '{"queued":true}'
}

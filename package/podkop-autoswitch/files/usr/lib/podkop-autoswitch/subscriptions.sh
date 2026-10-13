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
    local work section url enabled count=0
    work=$(mktemp -d "$PAS_RUN/fetch.XXXXXX") || return 1
    PAS_WORK=$work
    : > "$work/pools.ndjson"
    uci -c "$PAS_UCI" -q show podkop-autoswitch | sed -n 's/^podkop-autoswitch\.\([^=]*\)=subscription$/\1/p' > "$work/sources"
    while IFS= read -r section; do
        enabled=$(uci -c "$PAS_UCI" -q get "podkop-autoswitch.$section.enabled")
        [ "$enabled" != 0 ] || continue
        url=$(uci -c "$PAS_UCI" -q get "podkop-autoswitch.$section.url")
        case "$url" in https://*) ;; *) fail 'Subscription must use HTTPS'; return 1;; esac
        # curl config quotes/escapes untrusted text. URL is never a shell argument.
        jq -nr --arg url "$url" '"url = " + ($url|@json)' > "$work/curl.conf"
        # ulimit also bounds chunked responses on older curl implementations.
        (ulimit -f "$((MAX_BYTES/512+2))"; curl -q -K "$work/curl.conf" --proto '=https' --proto-redir '=https' \
            --noproxy '*' -fLsS --connect-timeout 10 --max-time 45 --max-redirs 3 \
            --max-filesize "$MAX_BYTES" -A 'Podkop-AutoSwitch/0.1 sing-box' -o "$work/body" 2> "$work/download.log") || {
                fail 'Subscription download failed; active pool preserved'; return 1;
            }
        [ "$(wc -c < "$work/body")" -le "$MAX_BYTES" ] || return 1
        normalize "$work/body" "$work/pool.json" "$work" || return 1
        cat "$work/pool.json" >> "$work/pools.ndjson"
        count=$((count+1))
    done < "$work/sources"
    [ "$count" -gt 0 ] || { fail 'No enabled subscriptions'; return 1; }
    jq -sc 'add | unique_by(.tag) | sort_by(.tag)' "$work/pools.ndjson" > "$work/combined.json" || return 1
    [ "$(jq length "$work/combined.json")" -le "$MAX_NODES" ] || { fail 'Combined pool too large'; return 1; }
    # Validate with the actual installed core before accepting any update.
    jq -n --slurpfile nodes "$work/combined.json" '{outbounds:($nodes[0]|map(del(._pas_label)))}' > "$work/check.json"
    "$PAS_SB" check -c "$work/check.json" > "$work/check.log" 2>&1 || { fail 'Installed sing-box rejects subscription; active pool preserved'; return 1; }
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
    while :; do
        t=$(now)
        if [ "$t" -ge "$due" ] || [ -e "$PAS_RUN/request-fetch" ]; then
            rm -f "$PAS_RUN/request-fetch"
            if "$PAS_BIN" fetch; then
                due=$((t+UPDATE))
                [ "$AUTO_APPLY" = 1 ] && "$PAS_BIN" apply
            else
                due=$((t+300)); log 'Subscription update failed; retry in 300s'
            fi
        fi
        if [ -e "$PAS_RUN/request-apply" ]; then
            rm -f "$PAS_RUN/request-apply"
            "$PAS_BIN" apply || log 'Requested application failed; inspect status and system log'
        fi
        if [ -e "$PAS_RUN/request-scan" ]; then
            rm -f "$PAS_RUN/request-scan"
            "$PAS_BIN" preflight > /dev/null || log 'Pool preflight found no usable server'
        fi
        sleep 5
    done
}

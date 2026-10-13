# SPDX-License-Identifier: GPL-2.0-or-later
# Isolated core: loopback API only, no TUN/TPROXY/DNS listeners and no routing rules.
preflight() (
    local pool="$1" work="$2" port=19091 pid secret selected='' best=2147483647 tag delay i index=0 attempt streak sample
    mkdir -p "$work" || exit 1
    : > "$work/results.ndjson"
    rm -f "$work/selected"
    # Bind failure is safe: never kill an existing process to claim a port.
    secret=$(head -c 24 /dev/urandom | base64 | tr -d '\n')
    jq -n --slurpfile pool "$pool" --arg secret "$secret" --argjson port "$port" \
      '{log:{level:"error"},outbounds:($pool[0]|map(del(._pas_label))),
        inbounds:[$pool[0]|to_entries[]|{type:"mixed",tag:("probe-"+(.key|tostring)),listen:"127.0.0.1",listen_port:(19100+.key)}],
        route:{rules:[$pool[0]|to_entries[]|{inbound:[("probe-"+(.key|tostring))],outbound:.value.tag}]},
        experimental:{clash_api:{external_controller:("127.0.0.1:"+($port|tostring)),secret:$secret}}}' > "$work/config.json"
    "$PAS_SB" check -c "$work/config.json" > "$work/core.log" 2>&1 || exit 1
    "$PAS_SB" run -c "$work/config.json" >> "$work/core.log" 2>&1 & pid=$!
    trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "${AUTH:-$work/no-auth}"' EXIT
    trap 'exit 1' INT TERM HUP
    CONFIG_PATH="$work/config.json"
    api_config || exit 1
    i=0
    while [ "$i" -lt 15 ]; do
        kill -0 "$pid" 2>/dev/null || exit 1
        api GET /version >/dev/null && break
        sleep 1; i=$((i+1))
    done
    jq -r '.[].tag' "$pool" > "$work/tags"
    : > "$work/results.ndjson"
    while IFS= read -r tag; do
        # Transient N/A is retried. Two consecutive payload transfers are required
        # to catch servers that are briefly reachable before provider blocking.
        attempt=0; streak=0; delay=''
        while [ "$attempt" -lt "$QUALIFY_ATTEMPTS" ]; do
            attempt=$((attempt+1))
            if sample=$(data_probe "$((19100+index))" "$QUALIFY_URL" 1024); then
                streak=$((streak+1)); delay=$sample
                [ "$streak" -lt "$QUALIFY_SUCCESSES" ] || break
            else streak=0; delay=''; fi
            sleep 1
        done
        [ "$streak" -ge "$QUALIFY_SUCCESSES" ] || delay=''
        jq -nc --arg tag "$tag" --argjson ms "${delay:-null}" '{tag:$tag,delay_ms:$ms}' >> "$work/results.ndjson"
        if [ "${PAS_SCAN_ACTIVE:-0}" = 1 ]; then scan_status running; fi
        if [ -n "$delay" ] && [ "$delay" -lt "$best" ]; then best=$delay; selected=$tag; fi
        index=$((index+1))
    done < "$work/tags"
    [ -n "$selected" ] || exit 1
    printf '%s\n' "$selected" > "$work/selected"
)
scan_status() {
    local results=/dev/null total=0
    [ ! -s "$PAS_HOME/staged.json" ] || total=$(jq length "$PAS_HOME/staged.json")
    [ ! -f "$PAS_RUN/preflight/results.ndjson" ] || results="$PAS_RUN/preflight/results.ndjson"
    jq -sn --slurpfile results "$results" --arg state "$1" --arg code "${2:-}" \
        --argjson total "$total" --argjson time "$(date +%s)" \
        '{state:$state,code:$code,total:$total,checked:($results|length),
          healthy:([$results[]|select(.delay_ms!=null)]|length),updated_at:$time}' \
        > "$PAS_RUN/scan-status.json.$$" && mv "$PAS_RUN/scan-status.json.$$" "$PAS_RUN/scan-status.json"
}
scan_pool() {
    local pid result checked total
    [ -s "$PAS_HOME/staged.json" ] || { scan_status error no_pool; return 1; }
    # Independent lock: an isolated scan must not freeze active health checks.
    if ! mkdir "$PAS_RUN/preflight.lock" 2>/dev/null; then
        pid=$(cat "$PAS_RUN/preflight.lock/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PAS_RUN/preflight.lock/pid"
            rmdir "$PAS_RUN/preflight.lock" && mkdir "$PAS_RUN/preflight.lock" || return 1
        else fail 'Another pool check is running'; return 1; fi
    fi
    printf '%s\n' "$$" > "$PAS_RUN/preflight.lock/pid"
    PAS_SCAN_ACTIVE=1
    mkdir -p "$PAS_RUN/preflight"
    : > "$PAS_RUN/preflight/results.ndjson"
    scan_status running
    preflight "$PAS_HOME/staged.json" "$PAS_RUN/preflight"; result=$?
    jq -s --argjson time "$(date +%s)" 'map(. + {healthy:(.delay_ms!=null),checked_at:$time})' \
        "$PAS_RUN/preflight/results.ndjson" > "$PAS_RUN/staged-health.json.new" &&
        mv "$PAS_RUN/staged-health.json.new" "$PAS_RUN/staged-health.json"
    checked=$(jq -s length "$PAS_RUN/preflight/results.ndjson")
    total=$(jq length "$PAS_HOME/staged.json")
    if [ "$checked" -ne "$total" ]; then scan_status error scan_failed
    elif [ "$result" -ne 0 ]; then scan_status error no_healthy_nodes
    else scan_status success; fi
    PAS_SCAN_ACTIVE=0
    cat "$PAS_RUN/preflight/results.ndjson"
    return "$result"
}

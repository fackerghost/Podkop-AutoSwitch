# SPDX-License-Identifier: GPL-2.0-or-later
record() {
    local tag="$1" delay="$2" healthy=false
    [ -n "$delay" ] && healthy=true
    jq -nc --arg tag "$tag" --argjson healthy "$healthy" --argjson ms "${delay:-null}" \
        --argjson time "$(date +%s)" '{tag:$tag,healthy:$healthy,delay_ms:$ms,checked_at:$time}' >> "$PAS_RUN/results.$$"
}
scan() {
    local tag delay best='' best_ms=2147483647
    if [ -s "$PAS_HOME/pool.json" ] && [ "$DATA_CHECK" = 1 ]; then
        if preflight "$PAS_HOME/pool.json" "$PAS_RUN/failover-check"; then best=$(cat "$PAS_RUN/failover-check/selected"); fi
        if [ -s "$PAS_RUN/failover-check/results.ndjson" ]; then
            jq -c --argjson time "$(date +%s)" '. + {healthy:(.delay_ms!=null),checked_at:$time}' "$PAS_RUN/failover-check/results.ndjson" >> "$PAS_RUN/results.$$"
        fi
        [ -n "$best" ] || return 1
        printf '%s\n' "$best"; return 0
    fi
    group || return 1
    jq -r '.all[]' "$PAS_RUN/group.$$" > "$PAS_RUN/members.$$"
    [ "$(wc -l < "$PAS_RUN/members.$$")" -le "$MAX_NODES" ] || return 1
    while IFS= read -r tag; do
        case "$tag" in pas_*-out) ;; *) continue;; esac
        delay=$(probe "$tag") || delay=''
        record "$tag" "$delay"
        if [ -n "$delay" ] && [ "$delay" -lt "$best_ms" ]; then best=$tag; best_ms=$delay; fi
    done < "$PAS_RUN/members.$$"
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}
publish() {
    local phase="$1" current="$2" failures="$3" switched="$4"
    [ -s "$PAS_RUN/results.$$" ] || echo '{}' > "$PAS_RUN/results.$$"
    [ -s "$PAS_RUN/status.json" ] || echo '{"servers":[]}' > "$PAS_RUN/status.json"
    jq -s --slurpfile old "$PAS_RUN/status.json" --arg phase "$phase" --arg current "$current" \
        --argjson failures "$failures" --argjson switched "$switched" --argjson time "$(date +%s)" \
        '{phase:$phase,current:$current,failures:$failures,last_switch_uptime:$switched,updated_at:$time,
          servers: (($old[0].servers + map(select(has("tag")))) | group_by(.tag) | map(last))}' \
        "$PAS_RUN/results.$$" > "$PAS_RUN/status.json.new.$$" && mv "$PAS_RUN/status.json.new.$$" "$PAS_RUN/status.json"
    : > "$PAS_RUN/results.$$"
}
remember() {
    [ "$(cat "$PAS_HOME/last-selected" 2>/dev/null)" = "$1" ] && return
    printf '%s\n' "$1" > "$PAS_RUN/selected.$$"
    atomic "$PAS_RUN/selected.$$" "$PAS_HOME/last-selected"
}
monitor() {
    local current='' failures=0 switched=0 candidate delay phase start elapsed wait previous='' initialized=0 action next_scan=0
    trap 'rm -f "$PAS_RUN"/auth.$$.* "$PAS_RUN/results.$$" "$PAS_RUN/group.$$" "$PAS_RUN/members.$$" "$PAS_RUN/selected.$$"; exit 0' INT TERM EXIT
    : > "$PAS_RUN/results.$$"
    # A service reload must not cause a healthy server to be replaced.
    if [ -s "$PAS_RUN/status.json" ]; then
        previous=$(jq -r '.current // ""' "$PAS_RUN/status.json")
        switched=$(jq -r '.last_switch_uptime // 0' "$PAS_RUN/status.json")
    fi
    while :; do
        start=$(now); phase=healthy
        if [ -d "$PAS_RUN/mutation.lock" ]; then
            publish applying "$current" "$failures" "$switched"
            sleep "$INTERVAL"; continue
        fi
        if ! api_config || ! group; then
            publish api_unavailable "$current" "$failures" "$switched"
            sleep "$INTERVAL"; continue
        fi
        current=$(jq -r .now "$PAS_RUN/group.$$")
        if [ "$DATA_CHECK" = 1 ] && ! jq -e 'any(.inbounds[]; .tag=="service-mixed-in" and .listen=="127.0.0.1")' "$CONFIG_PATH" >/dev/null; then
            publish integration_error "$current" "$failures" "$switched"
            sleep "$INTERVAL"; continue
        fi
        # Only control selectors created by this addon. No urltest nesting.
        if ! jq -e '(.all|length)>0 and all(.all[]; startswith("pas_") and endswith("-out") and length==32)' "$PAS_RUN/group.$$" >/dev/null; then
            publish unmanaged "$current" 0 "$switched"; sleep "$INTERVAL"; continue
        fi
        if [ "$initialized" = 0 ]; then
            if [ -n "$previous" ] && jq -e --arg p "$previous" '.all|index($p)!=null' "$PAS_RUN/group.$$" >/dev/null && delay=$(probe "$previous"); then
                select_proxy "$previous" && current=$previous
                record "$previous" "$delay"
            else
                candidate=$(scan) || candidate=''
                if [ -n "$candidate" ] && select_proxy "$candidate"; then
                    current=$candidate; switched=$(now); remember "$current"
                fi
            fi
            initialized=1; previous=$current
        elif [ -n "$previous" ] && [ "$current" != "$previous" ]; then
            # sing-box may have restarted or an administrator selected another node.
            # Restore sticky selection only after a restart: known selection is not
            # overridden blindly; external changes are adopted and reported.
            log 'Selector changed externally; adopting current selection'
            failures=0; switched=$(now); previous=$current
        fi
        delay=$(active_probe "$current") || delay=''
        record "$current" "$delay"
        if [ -n "$delay" ]; then
            failures=0; remember "$current"
        else
            # Distinguish a dead controller from a dead proxy.
            if ! group; then
                phase=api_unavailable
            else
                action=$(jq -nc --arg current "$current" --argjson failures "$failures" \
                    --argjson threshold "$THRESHOLD" --argjson auto "$([ "$AUTO" = 1 ] && echo true || echo false)" \
                    --argjson now "$(now)" --argjson last_switch "$switched" --argjson cooldown "$COOLDOWN" \
                    '{current:$current, failures:$failures, threshold:$threshold, auto:$auto, now:$now,
                      last_switch:$last_switch,cooldown:$cooldown,healthy:false,candidate:null}' | jq -c -f "$PAS_LIB/policy.jq")
                failures=$(printf '%s' "$action" | jq -r .failures)
                phase=$(printf '%s' "$action" | jq -r .action)
                if [ "$phase" = scan ] && [ "$(now)" -ge "$next_scan" ]; then
                    publish scanning "$current" "$failures" "$switched"
                    candidate=$(scan) || candidate=''
                    # If the old server recovered during the scan, retain it.
                    if delay=$(active_probe "$current"); then
                        record "$current" "$delay"; failures=0; phase=healthy
                    elif [ -n "$candidate" ] && [ "$candidate" != "$current" ] && probe "$candidate" >/dev/null && select_proxy "$candidate"; then
                        current=$candidate; previous=$current; failures=0; switched=$(now)
                        remember "$current"; phase=switched; log "Selected $current after repeated failures"
                    else
                        phase=no_healthy_backup
                    fi
                    next_scan=$(($(now)+30))
                fi
            fi
        fi
        if [ -f "$PAS_RUN/request-select" ]; then
            candidate=$(cat "$PAS_RUN/request-select"); rm -f "$PAS_RUN/request-select"
            if "$PAS_BIN" select "$candidate"; then
                current=$candidate; previous=$current; switched=$(now); failures=0; phase=manual
            else phase=manual_failed; fi
        fi
        publish "$phase" "$current" "$failures" "$switched"
        elapsed=$(($(now)-start)); wait=$((INTERVAL-elapsed))
        [ "$wait" -gt 0 ] || wait=1
        sleep "$wait"
    done
}

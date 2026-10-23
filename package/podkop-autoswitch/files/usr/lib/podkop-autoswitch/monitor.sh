# SPDX-License-Identifier: GPL-2.0-or-later
record() {
    local tag="$1" delay="$2" healthy=false
    [ -n "$delay" ] && healthy=true
    jq -nc --arg tag "$tag" --argjson healthy "$healthy" --argjson ms "${delay:-null}" \
        --argjson time "$(date +%s)" '{tag:$tag,healthy:$healthy,delay_ms:$ms,checked_at:$time}' >> "$PAS_RUN/results.$$"
}
scan() {
    local tag delay
    : > "$PAS_RUN/candidates.$$"
    if [ -s "$PAS_HOME/pool.json" ] && [ "$DATA_CHECK" = 1 ]; then
        preflight "$PAS_HOME/pool.json" "$PAS_RUN/failover-check" failover || :
        if [ -s "$PAS_RUN/failover-check/results.ndjson" ]; then
            jq -c --argjson time "$(date +%s)" '. + {healthy:(.delay_ms!=null),checked_at:$time}' "$PAS_RUN/failover-check/results.ndjson" >> "$PAS_RUN/results.$$"
            jq -sr '[.[]|select(.delay_ms!=null)]|sort_by(.delay_ms,.tag)|.[].tag' "$PAS_RUN/failover-check/results.ndjson" > "$PAS_RUN/candidates.$$"
        fi
        [ -s "$PAS_RUN/candidates.$$" ]; return $?
    fi
    group || return 1
    jq -r '.all[]' "$PAS_RUN/group.$$" > "$PAS_RUN/members.$$"
    [ "$(wc -l < "$PAS_RUN/members.$$")" -le "$MAX_NODES" ] || return 1
    while IFS= read -r tag; do
        case "$tag" in pas_*-out) ;; *) continue;; esac
        delay=$(probe "$tag") || delay=''
        record "$tag" "$delay"
    done < "$PAS_RUN/members.$$"
    jq -sr '[.[]|select(.delay_ms!=null)]|sort_by(.delay_ms,.tag)|.[].tag' "$PAS_RUN/results.$$" > "$PAS_RUN/candidates.$$"
    [ -s "$PAS_RUN/candidates.$$" ]
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
    local current='' failures=0 switched=0 candidate delay phase start elapsed wait previous='' action next_scan=0
    printf '%s\n' "$$" > "$PAS_RUN/monitor.pid"
    trap 'cleanup; rm -f "$PAS_RUN/results.$$" "$PAS_RUN/members.$$" "$PAS_RUN/selected.$$" "$PAS_RUN/candidates.$$"' EXIT
    trap 'exit 0' INT TERM HUP
    : > "$PAS_RUN/results.$$"
    # A service reload must not cause a healthy server to be replaced.
    if [ -s "$PAS_RUN/status.json" ]; then
        previous=$(jq -r '.current // ""' "$PAS_RUN/status.json")
        switched=$(jq -r '.last_switch_uptime // 0' "$PAS_RUN/status.json")
    fi
    while :; do
        start=$(now); phase=healthy
        if lock_busy; then
            publish applying "$current" "$failures" "$switched"
            sleep "$INTERVAL"; continue
        fi
        if [ ! -s "$PAS_HOME/attachment.json" ]; then
            publish awaiting_pool "$current" 0 "$switched"
            sleep "$INTERVAL"; continue
        fi
        if [ "$(sha256sum "$PAS_UCI/podkop" 2>/dev/null | cut -d' ' -f1)" != "$(cat "$PAS_HOME/applied-sha256" 2>/dev/null)" ]; then
            touch "$PAS_RUN/request-reconcile"
        fi
        if ! api_config; then
            publish api_unavailable '' 0 "$switched"
            sleep "$INTERVAL"; continue
        fi
        if ! group; then
            phase=$(group_failure_phase)
            [ "$phase" != selector_missing ] || touch "$PAS_RUN/request-reconcile"
            publish "$phase" '' 0 "$switched"
            sleep "$INTERVAL"; continue
        fi
        current=$(jq -r .now "$PAS_RUN/group.$$")
        if [ "$DATA_CHECK" = 1 ] && ! jq -e 'any(.inbounds[]; .tag=="service-mixed-in" and .listen=="127.0.0.1")' "$CONFIG_PATH" >/dev/null; then
            touch "$PAS_RUN/request-reconcile"
            publish integration_error "$current" "$failures" "$switched"
            sleep "$INTERVAL"; continue
        fi
        # Only control selectors created by this addon. No urltest nesting.
        if ! jq -e '(.all|length)>0 and all(.all[]; startswith("pas_") and endswith("-out") and length==32)' "$PAS_RUN/group.$$" >/dev/null; then
            publish unmanaged "$current" 0 "$switched"; sleep "$INTERVAL"; continue
        fi
        if [ -n "$previous" ] && [ "$current" != "$previous" ]; then
            # sing-box may have restarted or an administrator selected another node.
            # Restore sticky selection only after a restart: known selection is not
            # overridden blindly; external changes are adopted and reported.
            log 'Selector changed externally; adopting current selection'
            failures=0; switched=$(now); previous=$current
        fi
        previous=$current
        delay=$(active_probe "$current") || delay=''
        record "$current" "$delay"
        if [ -n "$delay" ]; then
            failures=0; remember "$current"; rm -f "$PAS_RUN/request-recovery"
        else
            # Distinguish a dead controller from a dead proxy.
            if ! group; then
                phase=api_unavailable
            elif ! wan_probe; then
                # Missing direct Internet is not a proxy failure. Start a fresh
                # failure sequence after WAN returns; never churn selectors.
                failures=0; phase=wan_unavailable; next_scan=0
                rm -f "$PAS_RUN/request-recovery"
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
                    scan || :
                    # If the old server recovered during the scan, retain it.
                    if lock_busy; then
                        phase=applying
                    elif ! api_config || ! group; then
                        phase=api_unavailable
                    elif [ "$(jq -r .now "$PAS_RUN/group.$$")" != "$current" ]; then
                        current=$(jq -r .now "$PAS_RUN/group.$$"); previous=$current; failures=0; phase=external_change
                    elif delay=$(active_probe "$current"); then
                        record "$current" "$delay"; failures=0; phase=healthy
                    elif ! wan_probe; then
                        failures=0; phase=wan_unavailable
                    elif lock; then
                        phase=no_healthy_backup
                        while IFS= read -r candidate; do
                            [ "$candidate" != "$current" ] || continue
                            if select_proxy "$candidate" && delay=$(active_probe "$candidate"); then
                                current=$candidate; previous=$current; failures=0; switched=$(now)
                                record "$current" "$delay"; remember "$current"; phase=switched
                                log "Selected $current after verified payload transfer"; break
                            fi
                            record "$candidate" ''
                            # Restore the previous choice if the real route fails.
                            select_proxy "$current" || { phase=api_unavailable; break; }
                            wan_probe || { failures=0; phase=wan_unavailable; break; }
                        done < "$PAS_RUN/candidates.$$"
                        unlock
                        [ "$phase" != no_healthy_backup ] || touch "$PAS_RUN/request-recovery"
                    else
                        phase=applying
                    fi
                    next_scan=$(($(now)+RECOVERY_RETRY))
                elif [ "$phase" = scan ]; then
                    phase=no_healthy_backup
                fi
            fi
        fi
        if [ -f "$PAS_RUN/request-select" ] && [ "$phase" != wan_unavailable ]; then
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

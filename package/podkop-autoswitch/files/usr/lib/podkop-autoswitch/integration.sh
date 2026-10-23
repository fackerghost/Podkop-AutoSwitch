# SPDX-License-Identifier: GPL-2.0-or-later
prepare() {
    local work="$1" tag section node existing current='' target
    [ -s "$PAS_HOME/staged.json" ] || { fail 'Fetch a subscription first'; return 1; }
    [ ! -s "$PAS_HOME/attachment.json" ] || [ "$(jq -r .section "$PAS_HOME/attachment.json")" = "$SECTION" ] || {
        fail 'Detach the previous target before changing section'; return 1;
    }
    # Never absorb uncommitted edits from another LuCI session.
    [ -z "$(uci -c "$PAS_UCI" -q changes podkop)" ] || { fail 'Commit pending Podkop edits first'; return 1; }
    mkdir -p "$work/uci"
    cp "$PAS_UCI/podkop" "$work/uci/podkop" || return 1
    cp "$PAS_HOME/staged.json" "$work/pool.json" || return 1
    if [ "$DATA_CHECK" = 1 ]; then
        # Official Podkop's only per-section loopback mixed inbound is the service
        # proxy for downloading lists. Reuse it without opening any LAN listener.
        local download_section download_enabled
        download_enabled=$(uci -c "$work/uci" -q get podkop.settings.download_lists_via_proxy)
        download_section=$(uci -c "$work/uci" -q get podkop.settings.download_lists_via_proxy_section)
        if [ "$download_enabled" = 1 ] && [ "$download_section" != "$SECTION" ]; then
            fail 'Service mixed proxy already belongs to another section; resolve this conflict or disable data_check'; return 1
        fi
        grep -q 'SB_SERVICE_MIXED_INBOUND_PORT=4534' /usr/lib/podkop/constants.sh || { fail 'Unverified service proxy port'; return 1; }
        uci -c "$work/uci" set podkop.settings.download_lists_via_proxy=1 &&
        uci -c "$work/uci" set "podkop.settings.download_lists_via_proxy_section=$SECTION" || return 1
    fi
    if api_config && group; then current=$(jq -r .now "$PAS_RUN/group.$$"); fi
    # Keep a removed but active node until it stops working, avoiding a subscription-induced switch.
    if [ -n "$current" ] && [ -s "$PAS_HOME/pool.json" ]; then
        jq --arg current "$current" --slurpfile old "$PAS_HOME/pool.json" \
            '. + [$old[0][]|select(.tag==$current)] | unique_by(.tag)|sort_by(.tag)' "$work/pool.json" > "$work/keep.json" &&
            mv "$work/keep.json" "$work/pool.json" || return 1
    fi
    [ "$(jq length "$work/pool.json")" -le "$MAX_NODES" ] || { fail 'Pool limit includes retained active node'; return 1; }
    target=$(jq -r --arg current "$current" 'if any(.[];.tag==$current) then $current else .[0].tag end' "$work/pool.json")
    # Owned section list, not a wildcard deletion, protects unrelated user settings.
    if [ -s "$PAS_HOME/attachment.json" ]; then
        jq -r '.sections[]' "$PAS_HOME/attachment.json" > "$work/old-sections"
        while IFS= read -r section; do
            [ "$(uci -c "$work/uci" -q get "podkop.$section.pas_managed")" = 1 ] || { fail 'Managed section ownership conflict'; return 1; }
            uci -c "$work/uci" -q delete "podkop.$section" || return 1
        done < "$work/old-sections"
    fi
    jq -c '.[]|del(._pas_label)' "$work/pool.json" > "$work/nodes"
    : > "$work/sections"
    while IFS= read -r node; do
        tag=$(printf '%s' "$node" | jq -r .tag); section=${tag%-out}
        existing=$(uci -c "$work/uci" -q get "podkop.$section")
        [ -z "$existing" ] || { fail 'Generated section name conflict'; return 1; }
        uci -c "$work/uci" set "podkop.$section=section" &&
        uci -c "$work/uci" set "podkop.$section.connection_type=proxy" &&
        uci -c "$work/uci" set "podkop.$section.proxy_config_type=outbound" &&
        uci -c "$work/uci" set "podkop.$section.pas_managed=1" &&
        uci -c "$work/uci" set "podkop.$section.outbound_json=$node" || return 1
        printf '%s\n' "$section" >> "$work/sections"
    done < "$work/nodes"
    node=$(jq -nc --slurpfile nodes "$work/pool.json" --arg tag "$SELECTOR" --arg target "$target" \
        '{type:"selector",tag:$tag,outbounds:[$nodes[0][].tag],default:$target,interrupt_exist_connections:true}')
    uci -c "$work/uci" set "podkop.$SECTION.proxy_config_type=outbound" &&
    uci -c "$work/uci" set "podkop.$SECTION.outbound_json=$node" &&
    uci -c "$work/uci" commit podkop || return 1
    # Candidate uses the exact existing routing/DNS/inbounds. Replace only managed outbounds.
    jq --arg selector "$SELECTOR" --argjson group "$node" --slurpfile nodes "$work/pool.json" \
        --slurpfile owned "$PAS_RUN/owned.json" \
        '.outbounds |= (map(select(.tag != $selector and (.tag as $t | $owned[0] | index($t)==null))) +
          [$group] + ($nodes[0]|map(del(._pas_label))))' "$CONFIG_PATH" > "$work/config.json" || return 1
    if [ "$DATA_CHECK" = 1 ]; then
        jq --arg selector "$SELECTOR" '
          .inbounds = ([.inbounds[]|select(.tag!="service-mixed-in")] + [{type:"mixed",tag:"service-mixed-in",listen:"127.0.0.1",listen_port:4534}]) |
          .route.rules = ([.route.rules[]|select((.inbound // [] | if type=="string" then [.] else . end | index("service-mixed-in"))==null)] +
            [{inbound:["service-mixed-in"],outbound:$selector}])' "$work/config.json" > "$work/data-config.json" &&
            mv "$work/data-config.json" "$work/config.json" || return 1
    fi
    "$PAS_SB" check -c "$work/config.json" > "$work/check.log" 2>&1 || { fail 'Candidate failed sing-box check'; return 1; }
    jq -Rn --arg section "$SECTION" '[inputs] | {section:$section,sections:.}' < "$work/sections" > "$work/attachment.json"
}
owned() {
    if [ -s "$PAS_HOME/attachment.json" ]; then jq '[.sections[] + "-out"]' "$PAS_HOME/attachment.json";
    else echo '[]'; fi > "$PAS_RUN/owned.json"
}
plan() {
    config && lock && doctor > "$PAS_RUN/doctor.log" 2>&1 || return 1
    owned
    local work; work=$(mktemp -d "$PAS_RUN/plan.XXXXXX") || return 1
    PAS_WORK=$work
    prepare "$work" || return 1
    printf 'Validated plan: %s servers, target %s; applying restarts Podkop once.\n' "$(jq length "$work/pool.json")" "$SECTION"
    rm -rf "$work"
}
apply_pool() {
    config && doctor > "$PAS_RUN/doctor.log" 2>&1 || return 1
    [ ! -d "$PAS_HOME/transaction" ] || { fail 'Pending recovery; run recover first'; return 1; }
    owned
    local work tx="$PAS_HOME/transaction" candidate ready=0 i=0 before
    before=$(sha256sum "$PAS_UCI/podkop" | cut -d' ' -f1)
    if [ -s "$PAS_HOME/attachment.json" ] && [ "$before" != "$(cat "$PAS_HOME/applied-sha256" 2>/dev/null)" ]; then
        fail 'Podkop was edited outside AutoSwitch; refusing to overwrite changes'; return 1
    fi
    work=$(mktemp -d "$PAS_RUN/apply.XXXXXX") || return 1
    PAS_WORK=$work
    prepare "$work" || return 1
    if [ -s "$PAS_HOME/attachment.json" ] && [ -s "$PAS_HOME/pool.json" ] && cmp -s "$work/pool.json" "$PAS_HOME/pool.json" && group; then
        log 'Pool unchanged'; rm -rf "$work"; return 0
    fi
    # Probe the candidate pool in an isolated sing-box before touching production.
    preflight "$work/pool.json" "$work/preflight" apply || { fail 'No usable server in candidate pool'; return 1; }
    jq -s --argjson time "$(date +%s)" 'map(. + {healthy:(.delay_ms!=null),checked_at:$time})' \
        "$work/preflight/results.ndjson" > "$PAS_RUN/staged-health.json.$$" &&
        mv "$PAS_RUN/staged-health.json.$$" "$PAS_RUN/staged-health.json"
    candidate=$(cat "$work/preflight/selected")
    # Only the short mutation phase pauses monitoring; qualification runs in an
    # independent core while the existing selected server keeps being checked.
    lock || return 1
    [ "$before" = "$(sha256sum "$PAS_UCI/podkop" | cut -d' ' -f1)" ] || { fail 'Podkop changed during qualification; retrying later'; return 1; }
    PAS_WAN_ROLE=sync
    wan_probe || { fail 'Direct Internet unavailable; pool update deferred'; return 1; }
    # Existing healthy selection wins over the preflight speed ranking.
    if api_config && group; then
        local old; old=$(jq -r .now "$PAS_RUN/group.$$")
        if [ -s "$PAS_HOME/attachment.json" ] && active_probe "$old" >/dev/null; then
            jq -e --arg old "$old" 'any(.[];.tag==$old)' "$work/pool.json" >/dev/null || { fail 'Selection changed during preparation; retrying later'; return 1; }
            candidate=$old
        fi
    fi
    local selector_json
    selector_json=$(uci -c "$work/uci" -q get "podkop.$SECTION.outbound_json" | jq -c --arg t "$candidate" '.default=$t')
    uci -c "$work/uci" set "podkop.$SECTION.outbound_json=$selector_json" && uci -c "$work/uci" commit podkop || return 1
    mkdir "$tx" || return 1
    cp "$PAS_UCI/podkop" "$tx/podkop"
    cp "$CONFIG_PATH" "$tx/config.json"
    printf '%s\n' "$CONFIG_PATH" > "$tx/config-path"
    for i in pool.json attachment.json applied-sha256; do [ ! -f "$PAS_HOME/$i" ] || cp "$PAS_HOME/$i" "$tx/$i"; done
    # Keep original UCI for detach. Checksum guards against overwriting later admin edits.
    if [ ! -f "$PAS_HOME/attachment.json" ]; then
        cp "$PAS_UCI/podkop" "$PAS_HOME/original-podkop"
        cp "$CONFIG_PATH" "$PAS_HOME/original-singbox.json"
    fi
    sync
    /bin/sh "$PAS_LIB/watchdog.sh" "$tx" "$PAS_UCI" "$PAS_HOME" > "$PAS_RUN/rollback.log" 2>&1 &
    atomic "$work/uci/podkop" "$PAS_UCI/podkop" || return 1
    "$PAS_PODKOP_INIT" restart > "$PAS_RUN/restart.log" 2>&1 || { recover; return 1; }
    i=0
    while [ "$i" -lt 20 ]; do
        if api_config && group && select_proxy "$candidate" && active_probe "$candidate" >/dev/null; then ready=1; break; fi
        sleep 2; i=$((i+1))
    done
    [ "$ready" = 1 ] || { recover; fail 'Application failed; rollback requested'; return 1; }
    # Do not commit after watchdog has taken ownership of recovery.
    mkdir "$tx/decision" 2>/dev/null || { fail 'Watchdog already recovering'; return 1; }
    echo $$ > "$tx/decision/pid"
    atomic "$work/pool.json" "$PAS_HOME/pool.json" && atomic "$work/attachment.json" "$PAS_HOME/attachment.json" || return 1
    sha256sum "$PAS_UCI/podkop" | cut -d' ' -f1 > "$PAS_HOME/applied-sha256"
    touch "$tx/committed"
    sync
    rm -rf "$tx" "$work"
    log 'Pool applied and proxy health verified'
}
recover() {
    [ -d "$PAS_HOME/transaction" ] || return 0
    /bin/sh "$PAS_LIB/watchdog.sh" "$PAS_HOME/transaction" "$PAS_UCI" "$PAS_HOME" now
}
detach() {
    config && lock || return 1
    [ -f "$PAS_HOME/attachment.json" ] || return 0
    local tx="$PAS_HOME/transaction" ready=0 i=0
    [ ! -d "$tx" ] || { fail 'Pending transaction; run recover first'; return 1; }
    [ "$(sha256sum "$PAS_UCI/podkop" | cut -d' ' -f1)" = "$(cat "$PAS_HOME/applied-sha256" 2>/dev/null)" ] || {
        fail 'Podkop was edited after attachment; restore original-podkop manually after merging your edits'; return 1;
    }
    "$PAS_SB" check -c "$PAS_HOME/original-singbox.json" > "$PAS_RUN/detach-check.log" 2>&1 || {
        fail 'Original sing-box config is incompatible with the installed version'; return 1;
    }
    mkdir "$tx" || return 1
    cp "$PAS_UCI/podkop" "$tx/podkop" && cp "$CONFIG_PATH" "$tx/config.json" || return 1
    printf '%s\n' "$CONFIG_PATH" > "$tx/config-path"
    for i in pool.json attachment.json applied-sha256; do [ ! -f "$PAS_HOME/$i" ] || cp "$PAS_HOME/$i" "$tx/$i"; done
    sync
    /bin/sh "$PAS_LIB/watchdog.sh" "$tx" "$PAS_UCI" "$PAS_HOME" > "$PAS_RUN/rollback.log" 2>&1 &
    atomic "$PAS_HOME/original-podkop" "$PAS_UCI/podkop" || return 1
    "$PAS_PODKOP_INIT" restart || { recover; return 1; }
    i=0
    while [ "$i" -lt 15 ]; do
        if api_config && probe "$SELECTOR" >/dev/null; then ready=1; break; fi
        sleep 2; i=$((i+1))
    done
    [ "$ready" = 1 ] || { recover; fail 'Original proxy did not recover; restored attached pool'; return 1; }
    mkdir "$tx/decision" 2>/dev/null || return 1
    echo $$ > "$tx/decision/pid"
    rm -f "$PAS_HOME/attachment.json" "$PAS_HOME/pool.json" "$PAS_HOME/applied-sha256" "$PAS_RUN/status.json"
    touch "$tx/committed"; sync
    rm -rf "$tx"
    log 'Original Podkop configuration restored'
}

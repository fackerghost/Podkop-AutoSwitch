# SPDX-License-Identifier: GPL-2.0-or-later
# Only sections recorded in our attachment may be replaced. Missing sections
# are normal after an administrator removes the generated pool in LuCI.
owned_sections() {
    [ -s "$PAS_HOME/attachment.json" ] || return 0
    jq -e '.sections|type=="array"' "$PAS_HOME/attachment.json" >/dev/null || return 1
    jq -r '.sections[]' "$PAS_HOME/attachment.json" | while IFS= read -r section; do
        printf '%s\n' "$section" | grep -Eq '^pas_[a-f0-9]{24}$' || return 1
        printf '%s\n' "$section"
    done
}
remove_owned_sections() {
    local directory="$1" list="$2" section kind
    mkdir -p "$directory/.delta" || return 1
    while IFS= read -r section; do
        kind=$(uci -c "$directory" -t "$directory/.delta" -q get "podkop.$section")
        [ -n "$kind" ] || continue
        [ "$kind" = section ] && [ "$(uci -c "$directory" -t "$directory/.delta" -q get "podkop.$section.pas_managed")" = 1 ] || {
            fail 'Generated section name is now owned by another configuration'; return 1;
        }
        # A user may have added routing rules to a generated section. Never
        # silently delete those rules while rebuilding subscription outbounds.
        uci -c "$directory" -t "$directory/.delta" -q show "podkop.$section" | sed '1d' |
            cut -d= -f1 | sed 's/.*\.//' | grep -Ev '^(connection_type|proxy_config_type|pas_managed|outbound_json)$' > "$list.extra" || :
        [ ! -s "$list.extra" ] || { fail 'Generated section contains user options; move these rules to the target section first'; return 1; }
        uci -c "$directory" -t "$directory/.delta" -q delete "podkop.$section" || return 1
    done < "$list"
}
copy_option() {
    local source="$1" destination="$2" key="$3" value
    if value=$(uci -c "$source" -t "$source/.delta" -q get "podkop.$key"); then
        uci -c "$destination" -t "$destination/.delta" set "podkop.$key=$value"
    else
        uci -c "$destination" -t "$destination/.delta" -q delete "podkop.$key" || :
    fi
}
prepare_restore() {
    local work="$1" current owned_target=0
    mkdir -p "$work/restore/.delta" "$work/previous/.delta"
    cp "$PAS_UCI/podkop" "$work/restore/podkop" || return 1
    remove_owned_sections "$work/restore" "$work/old-sections" || return 1
    current=$(uci -c "$PAS_UCI" -q get "podkop.$SECTION.outbound_json")
    if [ "$(uci -c "$PAS_UCI" -q get "podkop.$SECTION.proxy_config_type")" = outbound ] &&
        printf '%s' "$current" | jq -e --arg tag "$SELECTOR" --slurpfile owned "$PAS_RUN/owned.json" '
          .type=="selector" and .tag==$tag and (.outbounds|type)=="array" and
          (.outbounds|length)>0 and all(.outbounds[]; . as $t | $owned[0]|index($t)!=null)' >/dev/null 2>&1; then
        owned_target=1
    fi
    if [ -s "$PAS_HOME/original-podkop" ]; then
        cp "$PAS_HOME/original-podkop" "$work/previous/podkop" || return 1
        # Restore only the two fields owned by AutoSwitch. Current domain lists,
        # proxy_string, routing options and unrelated sections remain untouched.
        if [ "$owned_target" = 1 ]; then
            copy_option "$work/previous" "$work/restore" "$SECTION.proxy_config_type" &&
            copy_option "$work/previous" "$work/restore" "$SECTION.outbound_json" || return 1
        fi
        if [ -s "$PAS_HOME/attachment.json" ] &&
            [ "$(uci -c "$PAS_UCI" -q get podkop.settings.download_lists_via_proxy)" = 1 ] &&
            [ "$(uci -c "$PAS_UCI" -q get podkop.settings.download_lists_via_proxy_section)" = "$SECTION" ]; then
            copy_option "$work/previous" "$work/restore" settings.download_lists_via_proxy &&
            copy_option "$work/previous" "$work/restore" settings.download_lists_via_proxy_section || return 1
        fi
    elif [ "$owned_target" = 1 ]; then
        fail 'Original target configuration is missing; cannot prepare safe detach'; return 1
    fi
    uci -c "$work/restore" -t "$work/restore/.delta" commit podkop || return 1
    # This JSON is a compatibility check for detach; Podkop generates its actual
    # restored configuration from the merged UCI snapshot, never from this file.
    if [ "$owned_target" = 1 ]; then
        cp "$PAS_HOME/original-singbox.json" "$work/restore-config.json" || return 1
    else
        jq --slurpfile owned "$PAS_RUN/owned.json" '
            .outbounds |= map(select(.tag as $t | $owned[0]|index($t)==null))' "$CONFIG_PATH" > "$work/restore-config.json" || return 1
    fi
    "$PAS_SB" check -c "$work/restore-config.json" > "$work/restore-check.log" 2>&1 || {
        fail 'Restored configuration would reference removed outbounds'; return 1;
    }
}
managed_signature() {
    local directory="$1" list="$2" section value
    for section in "$SECTION" $(cat "$list"); do
        printf '%s\n' "$section"
        uci -c "$directory" -q get "podkop.$section.connection_type" || return 1
        uci -c "$directory" -q get "podkop.$section.proxy_config_type" || return 1
        if [ "$section" != "$SECTION" ]; then
            uci -c "$directory" -q get "podkop.$section.pas_managed" || return 1
        fi
        value=$(uci -c "$directory" -q get "podkop.$section.outbound_json") || return 1
        if [ "$section" = "$SECTION" ]; then
            printf '%s' "$value" | jq -cS 'del(.default)' || return 1
        else printf '%s' "$value" | jq -cS . || return 1; fi
    done
    if [ "$DATA_CHECK" = 1 ]; then
        uci -c "$directory" -q get podkop.settings.download_lists_via_proxy || return 1
        uci -c "$directory" -q get podkop.settings.download_lists_via_proxy_section || return 1
    fi
}
commit_restore() {
    atomic "$1/restore/podkop" "$PAS_HOME/original-podkop" &&
        atomic "$1/restore-config.json" "$PAS_HOME/original-singbox.json"
}
runtime_matches() {
    jq -e --slurpfile pool "$1/pool.json" --arg selector "$SELECTOR" --arg data "$DATA_CHECK" '
        ($pool[0]|map(del(._pas_label))|sort_by(.tag)) as $nodes |
        ([$nodes[].tag]) as $tags |
        ([.outbounds[]|select(.tag as $t | $tags|index($t)!=null)]|sort_by(.tag))==$nodes and
        any(.outbounds[]; .tag==$selector and .type=="selector" and (.outbounds|sort)==($tags|sort)) and
        ($data!="1" or (any(.inbounds[]; .tag=="service-mixed-in" and .listen=="127.0.0.1" and .listen_port==4534) and
          any(.route.rules[]; .outbound==$selector and ((.inbound // [] | if type=="string" then [.] else . end)|index("service-mixed-in")!=null))))
    ' "$CONFIG_PATH" >/dev/null
}

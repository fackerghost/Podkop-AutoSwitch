# SPDX-License-Identifier: GPL-2.0-or-later
# Only used when proxy health is uncertain or before changing routing. A direct
# outbound carries Podkop's verified bypass mark, so its checks cannot loop back
# through the failing proxy. Numeric HTTPS endpoints also avoid proxy DNS.
wan_probe() (
    local work pid child children='' url index=0 port=19890
    grep -Fq 'NFT_OUTBOUND_MARK="0x00200000"' /usr/lib/podkop/constants.sh || exit 1
    # Separate ports for monitor, updater/application and explicit selections.
    case "${PAS_WAN_ROLE:-monitor}" in sync) port=19891;; manual) port=19892;; esac
    work=$(mktemp -d "$PAS_RUN/wan.XXXXXX") || exit 1
    jq -n --argjson port "$port" '{log:{level:"error"},
      inbounds:[{type:"mixed",tag:"wan-in",listen:"127.0.0.1",listen_port:$port}],
      outbounds:[{type:"direct",tag:"wan-direct",routing_mark:2097152}],route:{final:"wan-direct"}}' > "$work/config.json"
    "$PAS_SB" check -c "$work/config.json" > "$work/core.log" 2>&1 || { rm -rf "$work"; exit 1; }
    "$PAS_SB" run -c "$work/config.json" >> "$work/core.log" 2>&1 & pid=$!
    trap 'for child in $children; do kill "$child" 2>/dev/null || :; done; kill "$pid" 2>/dev/null || :; for child in $children; do wait "$child" 2>/dev/null || :; done; wait "$pid" 2>/dev/null || :; rm -rf "$work"' EXIT
    trap 'exit 1' INT TERM HUP
    sleep 1
    kill -0 "$pid" 2>/dev/null || exit 1
    for url in $WAN_URLS; do
        index=$((index+1))
        (trap - EXIT; trap 'exit 1' INT TERM HUP; data_probe "$port" "$url" 16 > /dev/null && touch "$work/online-$index") &
        children="$children $!"
    done
    for child in $children; do wait "$child" 2>/dev/null || :; done
    children=''
    for child in "$work"/online-*; do [ ! -f "$child" ] || exit 0; done
    exit 1
)

#!/bin/sh
# Native UCI and sing-box validation; only network health and service boundaries
# are fixtures. No production router, routes or subscriptions are used.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
lab=$(mktemp -d /tmp/pas-reconcile.XXXXXX)
export PAS_LIB="$repo/package/podkop-autoswitch/files/usr/lib/podkop-autoswitch"
export PAS_HOME="$lab/home" PAS_RUN="$lab/run" PAS_UCI="$lab/uci" PAS_CONFIG_PATH="$lab/config.json"
export PAS_PODKOP_INIT="$lab/init" PAS_TEST_LAB="$lab" PAS_TEST_DELTA="$lab/delta"
export PAS_TEST_UCI_BIN="$(command -v uci)"
mkdir -p "$PAS_HOME" "$PAS_RUN" "$PAS_UCI" "$lab/bin" "$PAS_TEST_DELTA"
cat > "$lab/bin/uci" <<'SH'
#!/bin/sh
exec "$PAS_TEST_UCI_BIN" -t "$PAS_TEST_DELTA" "$@"
SH
chmod +x "$lab/bin/uci"
export PATH="$lab/bin:$PATH"
cp "$repo/package/podkop-autoswitch/files/etc/config/podkop-autoswitch" "$PAS_UCI/"
cat > "$PAS_UCI/podkop" <<'UCI'
config settings 'settings'
config section 'main'
    option connection_type 'proxy'
    option proxy_config_type 'url'
    option proxy_string 'manual-original'
    list user_domains 'original.example'
config section 'personal'
    option connection_type 'proxy'
    option proxy_config_type 'url'
    option proxy_string 'personal-proxy'
    list user_domains 'private.example'
UCI
uci -c "$PAS_UCI" set podkop-autoswitch.main.data_check=0
uci -c "$PAS_UCI" commit podkop-autoswitch
a=pas_aaaaaaaaaaaaaaaaaaaaaaaa-out
b=pas_bbbbbbbbbbbbbbbbbbbbbbbb-out
jq -n --arg a "$a" --arg b "$b" '[{type:"vless",server:"example.com",server_port:443,uuid:"00000000-0000-0000-0000-000000000001",tag:$a},
  {type:"vless",server:"example.org",server_port:443,uuid:"00000000-0000-0000-0000-000000000002",tag:$b}]' > "$PAS_HOME/staged.json"
cat > "$PAS_PODKOP_INIT" <<'SH'
#!/bin/sh
set -eu
: > "$PAS_TEST_LAB/outbounds"
for s in $(uci -c "$PAS_UCI" show podkop | sed -n 's/^podkop\.\([^=]*\)=section$/\1/p'); do
    if [ "$(uci -c "$PAS_UCI" get "podkop.$s.proxy_config_type")" = outbound ]; then
        uci -c "$PAS_UCI" get "podkop.$s.outbound_json" >> "$PAS_TEST_LAB/outbounds"
    else
        jq -nc --arg tag "$s-out" '{type:"vless",tag:$tag,server:"example.net",server_port:443,uuid:"00000000-0000-0000-0000-000000000003"}' >> "$PAS_TEST_LAB/outbounds"
    fi
done
jq -s '{outbounds:.,inbounds:[],route:{rules:[]},experimental:{clash_api:{external_controller:"127.0.0.1:19093"}}}' "$PAS_TEST_LAB/outbounds" > "$PAS_CONFIG_PATH"
sing-box check -c "$PAS_CONFIG_PATH"
echo restart >> "$PAS_TEST_LAB/restarts"
SH
chmod +x "$PAS_PODKOP_INIT"
"$PAS_PODKOP_INIT" restart
. "$PAS_LIB/common.sh"
. "$PAS_LIB/integration.sh"
. "$PAS_LIB/subscriptions.sh"
trap 'cleanup; rm -rf "$lab"' EXIT
config || exit 1
doctor() { [ "${1:-}" = prepare ] || sing-box check -c "$CONFIG_PATH"; }
api_config() { return 0; }
group() {
    jq -e '.outbounds[]|select(.tag=="main-out" and .type=="selector")|{type:"Selector",all:.outbounds,now:.default}' "$CONFIG_PATH" > "$PAS_RUN/group.$$"
}
select_proxy() {
    jq --arg t "$1" '(.outbounds[]|select(.tag=="main-out")).default=$t' "$CONFIG_PATH" > "$lab/selected.json"
    mv "$lab/selected.json" "$CONFIG_PATH"
}
active_probe() { [ ! -e "$lab/health-failed" ] || return 1; echo 20; }
probe() { active_probe; }
wan_probe() { [ ! -e "$lab/wan-failed" ]; }
sleep() { :; }
preflight() {
    [ ! -e "$lab/no-candidate" ] || return 1
    mkdir -p "$2"
    jq -r '.[0].tag' "$1" > "$2/selected"
    jq -c '.[]|{tag,delay_ms:20}' "$1" > "$2/results.ndjson"
    if [ -e "$lab/race" ]; then
        uci -c "$PAS_UCI" set podkop.main.user_domains=racing-edit.example
        uci -c "$PAS_UCI" commit podkop
    fi
}
apply() { (trap cleanup EXIT; apply_pool); }
restarts() { wc -l < "$lab/restarts"; }
manual() {
    uci -c "$PAS_UCI" set podkop.main.proxy_config_type=url
    uci -c "$PAS_UCI" set podkop.main.proxy_string=manual-new
    uci -c "$PAS_UCI" commit podkop
    "$PAS_PODKOP_INIT" restart
}
apply
[ "$(restarts)" = 2 ]
select_proxy "$b"
apply
[ "$(restarts)" = 2 ]
echo 'PASS initial attachment and unchanged sticky pool avoid redundant restarts'

manual
uci -c "$PAS_UCI" delete "podkop.${a%-out}"
uci -c "$PAS_UCI" delete "podkop.${b%-out}"
uci -c "$PAS_UCI" add_list podkop.main.user_domains=cloudflare.example
uci -c "$PAS_UCI" commit podkop
"$PAS_PODKOP_INIT" restart
apply
[ "$(uci -c "$PAS_UCI" get podkop.main.proxy_config_type)" = outbound ]
[ "$(uci -c "$PAS_UCI" get "podkop.${a%-out}.pas_managed")" = 1 ]
[ "$(uci -c "$PAS_UCI" get "podkop.${b%-out}.pas_managed")" = 1 ]
[ "$(uci -c "$PAS_UCI" get podkop.main.user_domains)" = 'original.example cloudflare.example' ]
[ "$(uci -c "$PAS_UCI" get podkop.personal.proxy_string)" = personal-proxy ]
mkdir "$lab/baseline"
cp "$PAS_HOME/original-podkop" "$lab/baseline/podkop"
[ "$(uci -c "$lab/baseline" get podkop.main.proxy_string)" = manual-new ]
[ "$(uci -c "$lab/baseline" get podkop.main.proxy_config_type)" = url ]
! uci -c "$lab/baseline" -q get "podkop.${a%-out}"
echo 'PASS manual URL plus deleted pool repaired; user routes and fresh detach baseline retained'

uci -c "$PAS_UCI" delete "podkop.${a%-out}"
uci -c "$PAS_UCI" commit podkop
n=$(restarts)
apply
[ "$(restarts)" = "$((n+1))" ]
echo 'PASS deleted section rebuilt even while old runtime selector is still present'

jq --arg t "$a" '.outbounds |= map(select(.tag!=$t))' "$CONFIG_PATH" > "$lab/broken.json"
mv "$lab/broken.json" "$CONFIG_PATH"
n=$(restarts)
apply
[ "$(restarts)" = "$((n+1))" ]
sing-box check -c "$CONFIG_PATH"
echo 'PASS incomplete generated runtime config rebuilt instead of requiring a healthy existing pool'

uci -c "$PAS_UCI" add_list podkop.main.user_domains=later.example
uci -c "$PAS_UCI" commit podkop
n=$(restarts)
apply
[ "$(restarts)" = "$n" ]
cp "$PAS_HOME/original-podkop" "$lab/baseline/podkop"
[ "$(uci -c "$lab/baseline" get podkop.main.user_domains)" = 'original.example cloudflare.example later.example' ]
echo 'PASS unrelated edits preserved in detach snapshot without restarting healthy pool'

uci -c "$PAS_UCI" delete "podkop.${a%-out}.pas_managed"
uci -c "$PAS_UCI" commit podkop
cp "$PAS_UCI/podkop" "$lab/collision"
if apply; then echo 'FAIL ownership collision accepted'; exit 1; fi
cmp "$PAS_UCI/podkop" "$lab/collision"
uci -c "$PAS_UCI" set "podkop.${a%-out}.pas_managed=1"
uci -c "$PAS_UCI" add_list "podkop.${a%-out}.user_domains=keep.example"
uci -c "$PAS_UCI" commit podkop
cp "$PAS_UCI/podkop" "$lab/collision"
if apply; then echo 'FAIL user rules in managed section discarded'; exit 1; fi
cmp "$PAS_UCI/podkop" "$lab/collision"
uci -c "$PAS_UCI" delete "podkop.${a%-out}.user_domains"
uci -c "$PAS_UCI" commit podkop
echo 'PASS foreign ownership and user rules inside generated sections are protected'

manual
touch "$lab/wan-failed"
cp "$PAS_UCI/podkop" "$lab/before"
n=$(restarts)
if apply; then echo 'FAIL applied without direct Internet'; exit 1; fi
cmp "$PAS_UCI/podkop" "$lab/before"
[ "$(restarts)" = "$n" ]
rm "$lab/wan-failed"
uci -c "$PAS_UCI" set podkop.main.user_domains=uncommitted.example
if apply; then echo 'FAIL pending LuCI edit accepted'; exit 1; fi
cmp "$PAS_UCI/podkop" "$lab/before"
uci -c "$PAS_UCI" revert podkop
echo 'PASS WAN outage and pending LuCI edits postpone reconciliation'

touch "$lab/no-candidate"
cp "$PAS_UCI/podkop" "$lab/before"
n=$(restarts)
if apply; then echo 'FAIL no healthy candidate accepted'; exit 1; fi
cmp "$PAS_UCI/podkop" "$lab/before"
[ "$(restarts)" = "$n" ]
rm "$lab/no-candidate"
touch "$lab/race"
if apply; then echo 'FAIL concurrent edit overwritten'; exit 1; fi
[ "$(uci -c "$PAS_UCI" get podkop.main.user_domains)" = racing-edit.example ]
[ "$(restarts)" = "$n" ]
rm "$lab/race"
echo 'PASS qualification failure and concurrent edits leave live configuration intact'

cp "$PAS_UCI/podkop" "$lab/before"
cp "$PAS_HOME/original-podkop" "$lab/before-baseline"
touch "$lab/health-failed"
if apply; then echo 'FAIL unhealthy application committed'; exit 1; fi
cmp "$PAS_UCI/podkop" "$lab/before"
cmp "$PAS_HOME/original-podkop" "$lab/before-baseline"
rm "$lab/health-failed"
apply
(trap cleanup EXIT; detach)
[ "$(uci -c "$PAS_UCI" get podkop.main.proxy_config_type)" = url ]
[ "$(uci -c "$PAS_UCI" get podkop.main.proxy_string)" = manual-new ]
[ "$(uci -c "$PAS_UCI" get podkop.main.user_domains)" = racing-edit.example ]
! uci -c "$PAS_UCI" -q get "podkop.${a%-out}"
echo 'PASS rollback preserves edited proxy and metadata; detach restores latest manual settings'

api() { echo '{}'; }
[ "$(group_failure_phase)" = selector_missing ]
api() { return 1; }
[ "$(group_failure_phase)" = api_unavailable ]
uci -c "$PAS_UCI" set podkop-autoswitch.main.enabled=0
uci -c "$PAS_UCI" commit podkop-autoswitch
fetch() { PAS_FETCH_CODE=''; return 0; }
cp "$PAS_UCI/podkop" "$lab/before"
(trap cleanup EXIT; sync_pool)
cmp "$PAS_UCI/podkop" "$lab/before"
[ "$(jq -r .state "$PAS_RUN/sync-status.json")" = paused ]
echo 'PASS missing selector distinguished from API failure; disabled mode preserves manual proxy'

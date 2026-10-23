#!/bin/sh
# Actual transaction, UCI generator, API and HTTPS checks in an isolated core.
# The init fixture only operates on a PID/config inside this mktemp directory.
set -eu
: "${PAS_HOME:?}" "${PAS_RUN:?}" "${PAS_LIB:?}" "${PAS_BIN:?}"
source_home=$PAS_HOME; source_run=$PAS_RUN
lab=$(mktemp -d "$PAS_RUN/integration-test.XXXXXX")
export PAS_HOME="$lab/home" PAS_RUN="$lab/run" PAS_UCI="$lab/uci" PAS_CONFIG_PATH="$lab/config.json" PAS_PODKOP_INIT="$lab/init"
export PAS_INTEGRATION_LAB="$lab"
mkdir -p "$PAS_HOME" "$PAS_RUN" "$PAS_UCI"
cp "$PAS_LIB/../../../etc/config/podkop-autoswitch" "$PAS_UCI/podkop-autoswitch"
jq -n --slurpfile pool "$source_home/staged.json" --slurpfile health "$source_run/staged-health.json" '
  [$health[0][]|select(.delay_ms!=null)]|sort_by(.delay_ms)|.[0:3]|map(.tag) as $tags |
  [$pool[0][]|select(.tag as $t|$tags|index($t)!=null)]' > "$lab/three.json"
[ "$(jq length "$lab/three.json")" = 3 ] || { echo 'Need three qualified nodes'; exit 1; }
jq '.[0:2]' "$lab/three.json" > "$PAS_HOME/staged.json"
cat > "$PAS_UCI/podkop" <<'UCI'
config settings 'settings'
config section 'main'
    option connection_type 'proxy'
    option proxy_config_type 'outbound'
UCI
original=$(jq -c '.[0]|del(._pas_label)|.tag="main-out"' "$lab/three.json")
uci -c "$PAS_UCI" set "podkop.main.outbound_json=$original"
uci -c "$PAS_UCI" commit podkop
cat > "$PAS_PODKOP_INIT" <<'SH'
#!/bin/sh
set -eu
lab=$PAS_INTEGRATION_LAB
case "$lab" in /tmp/*/integration-test.*) ;; *) exit 1;; esac
if [ -s "$lab/core.pid" ]; then
    pid=$(cat "$lab/core.pid")
    if [ -r "/proc/$pid/cmdline" ] && tr '\000' ' ' < "/proc/$pid/cmdline" | grep -F "$lab/config.json" >/dev/null; then kill "$pid"; fi
fi
[ "$1" != stop ] || exit 0
: > "$lab/outbounds"
for section in $(uci -c "$PAS_UCI" show podkop | sed -n 's/^podkop\.\([^=]*\)=section$/\1/p'); do
    uci -c "$PAS_UCI" get "podkop.$section.outbound_json" >> "$lab/outbounds"
done
jq -s '{log:{level:"error"},outbounds:.,
  inbounds:[{type:"mixed",tag:"service-mixed-in",listen:"127.0.0.1",listen_port:4534}],
  route:{rules:[{inbound:["service-mixed-in"],outbound:"main-out"}]},
  experimental:{clash_api:{external_controller:"127.0.0.1:19093",secret:"isolated-test-only"}}}' "$lab/outbounds" > "$lab/config.json"
sing-box check -c "$lab/config.json" > "$lab/check.log" 2>&1
sing-box run -c "$lab/config.json" > "$lab/core.log" 2>&1 < /dev/null &
echo $! > "$lab/core.pid"
echo restart >> "$lab/restarts"
sleep 1
kill -0 "$(cat "$lab/core.pid")"
SH
chmod 700 "$PAS_PODKOP_INIT"
trap '"$PAS_PODKOP_INIT" stop || :' EXIT
trap 'exit 1' INT TERM HUP
"$PAS_PODKOP_INIT" restart
"$PAS_BIN" apply
[ -s "$PAS_HOME/attachment.json" ]
[ "$(jq length "$PAS_HOME/pool.json")" = 2 ]
echo 'PASS actual initial attachment transaction, native selector creation and routed HTTPS verification'
. "$PAS_LIB/common.sh"
trap 'cleanup; "$PAS_PODKOP_INIT" stop || :' EXIT
config; api_config; group
selected=$(jq -r .now "$PAS_RUN/group.$$")
cp "$lab/three.json" "$PAS_HOME/staged.json"
"$PAS_BIN" apply
api_config; group
[ "$(jq -r .now "$PAS_RUN/group.$$")" = "$selected" ]
[ "$(jq length "$PAS_HOME/pool.json")" = 3 ]
[ "$(wc -l < "$lab/restarts")" = 3 ]
echo 'PASS changed subscription pool integrated with healthy current server retained'
"$PAS_BIN" apply
[ "$(wc -l < "$lab/restarts")" = 3 ]
echo 'PASS unchanged subscriptions do not restart Podkop'
"$PAS_BIN" detach
[ ! -e "$PAS_HOME/attachment.json" ]
echo 'PASS detach restores original proxy after real integration tests'
"$PAS_PODKOP_INIT" stop

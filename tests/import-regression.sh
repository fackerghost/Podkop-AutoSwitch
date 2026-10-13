#!/bin/sh
# Real importer/RPC/worker; only temporary configuration and loopback test cores.
# Pass the uploaded files/ directory and a private test UCI file with an HTTPS URL.
set -eu
files=$1
root=$(mktemp -d /tmp/pas-import-test.XXXXXX)
export PAS_LIB="$files/usr/lib/podkop-autoswitch" PAS_RUN="$root/run" PAS_HOME="$root/home" PAS_UCI="$root/config"
export PAS_BIN="$root/cli" PAS_INIT="$root/init" PAS_REAL_BIN="$files/usr/bin/podkop-autoswitch"
export PAS_TEST_ROOT="$root"
mkdir -p "$PAS_UCI" "$PAS_RUN" "$PAS_HOME"
cleanup_test() {
    pid=$(cat "$PAS_RUN/updater.pid" 2>/dev/null || :)
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || :
    rm -rf "$root"
}
trap cleanup_test EXIT
trap 'exit 1' INT TERM HUP
cp "$2" "$PAS_UCI/podkop-autoswitch"
uci -c "$PAS_UCI" set podkop-autoswitch.main.enabled=0
uci -c "$PAS_UCI" set podkop-autoswitch.main.auto_apply=1
uci -c "$PAS_UCI" set podkop-autoswitch.main.qualify_attempts=2
uci -c "$PAS_UCI" set podkop-autoswitch.main.qualify_successes=2
uci -c "$PAS_UCI" set podkop-autoswitch.main.timeout_ms=200
uci -c "$PAS_UCI" commit podkop-autoswitch
cat > "$PAS_BIN" <<'SH'
#!/bin/sh
case "$1" in apply|attach|detach|run) touch "$PAS_TEST_ROOT/UNSAFE"; exit 1;; esac
exec "$PAS_REAL_BIN" "$@"
SH
cat > "$PAS_INIT" <<'SH'
#!/bin/sh
"$PAS_BIN" updater > "$PAS_RUN/worker.log" 2>&1 < /dev/null &
SH
chmod 700 "$PAS_BIN" "$PAS_INIT"
rpc() { "$files/usr/libexec/rpcd/podkop-autoswitch" call "$1"; }
wait_import() {
    i=0
    while [ "$i" -lt 90 ]; do
        [ ! -f "$PAS_RUN/subscription-status.json" ] || {
            state=$(jq -r .state "$PAS_RUN/subscription-status.json")
            [ "$state" != "$1" ] || return 0
        }
        sleep 1; i=$((i+1))
    done
    echo 'FAIL import timeout'; return 1
}
"$PAS_BIN" status | jq -e '.enabled==false and (.available|length)==0' >/dev/null
rpc scan | jq -e '.ok==false and .code=="no_pool"' >/dev/null
rpc apply | jq -e '.ok==false and .code=="monitoring_disabled"' >/dev/null
rpc fetch | jq -e '.queued==true' >/dev/null
wait_import success
"$PAS_BIN" status | jq -e '.enabled==false and .attached==false and .worker_running==true and (.available|length)>0' >/dev/null
[ ! -e "$root/UNSAFE" ]
cp "$PAS_HOME/staged.json" "$root/good-pool.json"
echo 'PASS fresh disabled addon imports through RPC and starts worker without applying'

# Reject a failing source visibly; retain the complete previous pool.
source=$(uci -c "$PAS_UCI" show podkop-autoswitch | sed -n 's/^podkop-autoswitch\.\([^=]*\)=subscription$/\1/p' | head -n 1)
url=$(uci -c "$PAS_UCI" get "podkop-autoswitch.$source.url")
uci -c "$PAS_UCI" set "podkop-autoswitch.$source.url=https://127.0.0.1:9/private-test"
uci -c "$PAS_UCI" commit podkop-autoswitch
rpc fetch | jq -e '.queued==true' >/dev/null
wait_import error
"$PAS_BIN" status | jq -e '.subscription.code=="download_failed" and .subscription.detail>0 and .subscription.source==1' >/dev/null
cmp "$root/good-pool.json" "$PAS_HOME/staged.json"
echo 'PASS download failure is visible and preserves all nodes'
uci -c "$PAS_UCI" set "podkop-autoswitch.$source.url=$url"
duplicate=$(uci -c "$PAS_UCI" add podkop-autoswitch subscription)
uci -c "$PAS_UCI" set "podkop-autoswitch.$duplicate.url=$url"
uci -c "$PAS_UCI" set "podkop-autoswitch.$duplicate.enabled=1"
uci -c "$PAS_UCI" commit podkop-autoswitch
rpc fetch | jq -e '.queued==true' >/dev/null
wait_import success
cmp "$root/good-pool.json" "$PAS_HOME/staged.json"
echo 'PASS recovery and duplicate anonymous subscription import'

# Real payload failures, with no external traffic: force both candidates to a
# closed loopback port. Testing stays available even with monitoring disabled.
jq '.[0:2] | map(.server="127.0.0.1" | .server_port=9)' "$root/good-pool.json" > "$PAS_HOME/staged.json"
rpc scan | jq -e '.queued==true' >/dev/null
i=0
while [ "$i" -lt 90 ]; do
    if [ -f "$PAS_RUN/scan-status.json" ] && jq -e '.state=="error" and .code=="no_healthy_nodes" and .checked==2' "$PAS_RUN/scan-status.json" >/dev/null; then break; fi
    sleep 1; i=$((i+1))
done
[ "$i" -lt 90 ]
"$PAS_BIN" status | jq -e '(.available|length)==2 and (.servers|length)==2 and .scan.healthy==0' >/dev/null
[ ! -e "$root/UNSAFE" ]
echo 'PASS queued pool scan while disabled reports actual failures and retains nodes'
uci -c "$PAS_UCI" set podkop-autoswitch.main.enabled=1
uci -c "$PAS_UCI" commit podkop-autoswitch
rm -f "$PAS_RUN/scan-status.json"
rpc scan | jq -e '.queued==true' >/dev/null
i=0
while [ "$i" -lt 90 ]; do
    if [ -f "$PAS_RUN/scan-status.json" ] && jq -e '.state=="error" and .code=="no_healthy_nodes" and .checked==2' "$PAS_RUN/scan-status.json" >/dev/null; then break; fi
    sleep 1; i=$((i+1))
done
[ "$i" -lt 90 ]
[ ! -e "$root/UNSAFE" ]
echo 'PASS pool scan with monitoring enabled returns real result, no disabled-service error'

# Init registers the updater even while disabled, and both processes when enabled.
(
    . "$files/etc/init.d/podkop-autoswitch"
    config_load() { :; }; config_get_bool() { enabled=$test_enabled; }
    procd_open_instance() { echo "$1" >> "$root/instances"; }
    procd_set_param() { :; }; procd_close_instance() { :; }
    test_enabled=0; start_service
    [ "$(cat "$root/instances")" = updater ]
    : > "$root/instances"
    test_enabled=1; start_service
    [ "$(wc -l < "$root/instances")" -eq 2 ]
)
echo 'PASS procd starts loader when disabled and monitor plus loader when enabled'

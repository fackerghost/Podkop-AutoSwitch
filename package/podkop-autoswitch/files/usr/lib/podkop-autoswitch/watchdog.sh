#!/bin/sh
# Persistent rollback record is also recovered before service start after reboot.
umask 077
tx=$1; ucidir=$2; home_dir=$3
[ "$4" = now ] || sleep 90
[ -d "$tx" ] && [ ! -e "$tx/committed" ] || exit 0
if ! mkdir "$tx/decision" 2>/dev/null; then
    # A commit/rollback owns the decision. A dead owner (including after reboot)
    # must not permanently suppress crash recovery.
    owner=$(cat "$tx/decision/pid" 2>/dev/null)
    if [ "$4" != now ] && [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then exit 0; fi
    [ "$4" = now ] || [ -n "$owner" ] || exit 0
fi
echo $$ > "$tx/decision/pid"
config_path=$(cat "$tx/config-path")
cp "$tx/podkop" "$ucidir/podkop.rollback" && mv "$ucidir/podkop.rollback" "$ucidir/podkop" || exit 1
cp "$tx/config.json" "$config_path.rollback" && mv "$config_path.rollback" "$config_path" || exit 1
metadata='pool.json attachment.json applied-sha256'
[ ! -e "$tx/restore-snapshot-v2" ] || metadata="$metadata original-podkop original-singbox.json"
for name in $metadata; do
    if [ -f "$tx/$name" ]; then cp "$tx/$name" "$home_dir/$name"; else rm -f "$home_dir/$name"; fi
done
"${PAS_PODKOP_INIT:-/etc/init.d/podkop}" restart
logger -t podkop-autoswitch 'Unconfirmed transaction rolled back'
rm -rf "$home_dir/last-rollback.previous"
[ ! -d "$home_dir/last-rollback" ] || mv "$home_dir/last-rollback" "$home_dir/last-rollback.previous"
mv "$tx" "$home_dir/last-rollback"

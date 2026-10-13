#!/bin/sh
# Persistent rollback record is also recovered before service start after reboot.
umask 077
tx=$1; ucidir=$2; home_dir=$3
[ "$4" = now ] || sleep 90
[ -d "$tx" ] && [ ! -e "$tx/committed" ] || exit 0
mkdir "$tx/decision" 2>/dev/null || exit 0
config_path=$(cat "$tx/config-path")
cp "$tx/podkop" "$ucidir/podkop.rollback" && mv "$ucidir/podkop.rollback" "$ucidir/podkop" || exit 1
cp "$tx/config.json" "$config_path.rollback" && mv "$config_path.rollback" "$config_path" || exit 1
for name in pool.json attachment.json; do
    if [ -f "$tx/$name" ]; then cp "$tx/$name" "$home_dir/$name"; else rm -f "$home_dir/$name"; fi
done
/etc/init.d/podkop restart
logger -t podkop-autoswitch 'Unconfirmed transaction rolled back'
mv "$tx" "$home_dir/last-rollback-$(date +%s)"

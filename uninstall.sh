#!/bin/sh
set -eu
[ "$(id -u)" = 0 ] || exit 1
if [ -f /etc/podkop-autoswitch/attachment.json ]; then
    /usr/bin/podkop-autoswitch detach
fi
/etc/init.d/podkop-autoswitch stop
if command -v apk >/dev/null 2>&1; then apk del podkop-autoswitch; else opkg remove podkop-autoswitch; fi
echo 'Removed. Configuration and recovery backups are retained in /etc/podkop-autoswitch.'

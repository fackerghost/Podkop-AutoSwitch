"""Reproducible architecture-independent OpenWrt IPK, no host compiler required."""
from pathlib import Path
import gzip
import hashlib
import io
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.1.3'
EPOCH = 1792756800

def tar_gz(files):
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode='wb', mtime=EPOCH, filename='') as zipped:
        with tarfile.open(fileobj=zipped, mode='w', format=tarfile.GNU_FORMAT) as tar:
            directories = set()
            for name, _, _ in files:
                directories.update(str(p).replace('\\', '/') for p in Path(name).parents if str(p) != '.')
            for name in sorted(directories, key=lambda n: (n.count('/'), n)):
                info = tarfile.TarInfo('./' + name + '/')
                info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, EPOCH
                info.uid = info.gid = 0
                tar.addfile(info)
            for name, data, mode in sorted(files):
                info = tarfile.TarInfo('./' + name)
                info.size, info.mode, info.mtime = len(data), mode, EPOCH
                info.uid = info.gid = 0
                tar.addfile(info, io.BytesIO(data))
    return raw.getvalue()

def build():
    files = []
    for p in (ROOT / 'package/podkop-autoswitch/files').rglob('*'):
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT / 'package/podkop-autoswitch/files').as_posix()
        data = p.read_bytes()
        mode = 0o755 if data.startswith(b'#!/') else 0o644
        if rel.startswith('etc/config/'):
            mode = 0o600
        files.append((rel, data, mode))
    control = f'''Package: podkop-autoswitch
Version: {VERSION}-1
Architecture: all
Maintainer: Podkop AutoSwitch contributors
Section: net
Priority: optional
License: GPL-2.0-or-later
Depends: podkop, curl, jq, ucode, ucode-mod-fs, ca-bundle, luci-base, rpcd
Installed-Size: {sum(len(d) for _, d, _ in files)}
Description: Sticky proxy failover and subscription management for Podkop with LuCI
'''
    postinst = '''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
chmod 600 /etc/config/podkop-autoswitch
/etc/init.d/podkop-autoswitch enable
/etc/init.d/podkop-autoswitch restart
/etc/init.d/rpcd reload
exit 0
'''
    prerm = '''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
case "$1" in upgrade|failed-upgrade) exit 0;; esac
/etc/init.d/podkop-autoswitch stop
if [ -f /etc/podkop-autoswitch/attachment.json ]; then
  /usr/bin/podkop-autoswitch detach || exit 1
fi
/etc/init.d/podkop-autoswitch disable
exit 0
'''
    metadata = tar_gz([
        ('control', control.encode(), 0o644),
        ('conffiles', b'/etc/config/podkop-autoswitch\n', 0o644),
        ('postinst', postinst.encode(), 0o755), ('prerm', prerm.encode(), 0o755),
    ])
    out = ROOT / 'dist'; out.mkdir(exist_ok=True)
    path = out / f'podkop-autoswitch_{VERSION}-1_all.ipk'
    path.write_bytes(tar_gz([('debian-binary', b'2.0\n', 0o644),
        ('control.tar.gz', metadata, 0o644), ('data.tar.gz', tar_gz(files), 0o644)]))
    (out / 'SHA256SUMS').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n')
    print(path)

if __name__ == '__main__':
    build()

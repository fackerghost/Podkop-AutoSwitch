"""Development transport. Password is read from environment, never written.

Example: python tools/router.py HOST exec < read-only-command.sh
First connection requires a separately recorded host key in .tools/known_hosts.
"""
import argparse
import io
import os
from pathlib import Path
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '.tools/python'))
import paramiko

p = argparse.ArgumentParser()
p.add_argument('host')
p.add_argument('action', choices=['exec', 'upload'])
p.add_argument('source', nargs='?')
p.add_argument('destination', nargs='?')
a = p.parse_args()
c = paramiko.SSHClient()
c.load_host_keys('.tools/known_hosts')
c.connect(a.host, username='root', password=os.environ['PAS_ROUTER_PASSWORD'],
          timeout=15, look_for_keys=False, allow_agent=False)
if a.action == 'upload':
    import shlex
    source = Path(a.source)
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:gz') as tar:
        for path in source.rglob('*'):
            if not path.is_file():
                continue
            relative = path.relative_to(source).as_posix()
            data = path.read_bytes()
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mode = 0o755 if (data.startswith(b'#!/') or relative.startswith('usr/bin/')) else 0o600
            tar.addfile(info, io.BytesIO(data))
    cmd = f'mkdir -p {shlex.quote(a.destination)} && tar -xzf - -C {shlex.quote(a.destination)}'
    stdin, out, err = c.exec_command(cmd)
    stdin.write(stream.getvalue())
    stdin.channel.shutdown_write()
else:
    stdin, out, err = c.exec_command('/bin/sh', timeout=600)
    stdin.write(sys.stdin.buffer.read().replace(b'\r\n', b'\n'))
    stdin.channel.shutdown_write()
print(out.read().decode('utf-8', errors='replace'), end='')
print(err.read().decode('utf-8', errors='replace'), end='', file=sys.stderr)
rc = out.channel.recv_exit_status()
c.close()
sys.exit(rc)

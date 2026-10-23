"""Publish only explicitly listed source paths. Authentication stays in memory."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import os
import re
from pathlib import Path
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = 'fackerghost/Podkop-AutoSwitch'
TOKEN = os.environ['GITHUB_TOKEN']

def api(path, data=None, method=None, raw=None, mime=None):
    url = path if path.startswith('https://') else 'https://api.github.com' + path
    body = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    req = urllib.request.Request(url, data=body, method=method,
        headers={'Authorization': 'Bearer ' + TOKEN, 'Accept': 'application/vnd.github+json',
                 'Content-Type': mime or 'application/json', 'User-Agent': 'Podkop-AutoSwitch-build'})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r) if r.status != 204 else None

def source_files():
    files = []
    for item in ['package', 'tools', 'tests', 'docs', '.github', 'README.md', 'LICENSE',
                 'install.sh', 'uninstall.sh', '.gitignore', '.gitattributes']:
        p = ROOT / item
        files += [p] if p.is_file() else [x for x in p.rglob('*') if x.is_file() and '__pycache__' not in x.parts]
    return files

def publish(message):
    ref = api(f'/repos/{REPO}/git/ref/heads/main')
    parent = ref['object']['sha']
    def blob(p):
        content = p.read_bytes()
        # Block accidental credential files/content before any public upload.
        if re.search(rb'gh[pousr]_[A-Za-z0-9]{20,}', content):
            raise RuntimeError('Potential credential in ' + str(p))
        sha = api(f'/repos/{REPO}/git/blobs', {'content': base64.b64encode(content).decode(), 'encoding': 'base64'})['sha']
        return {'path': p.relative_to(ROOT).as_posix(), 'mode': '100755' if content.startswith(b'#!/') else '100644', 'type': 'blob', 'sha': sha}
    # Pre-scan everything before uploading any blob.
    files = source_files()
    for p in files:
        secrets = [os.environ.get(k, '').encode() for k in ['GITHUB_TOKEN', 'PAS_ROUTER_PASSWORD', 'PAS_SUBSCRIPTION']]
        if any(s and s in p.read_bytes() for s in secrets):
            raise RuntimeError('Credential detected in source')
    with ThreadPoolExecutor(max_workers=4) as pool:
        entries = list(pool.map(blob, files))
    tree = api(f'/repos/{REPO}/git/trees', {'tree': entries})['sha']
    commit = api(f'/repos/{REPO}/git/commits', {'message': message, 'tree': tree, 'parents': [parent]})['sha']
    api(f'/repos/{REPO}/git/refs/heads/main', {'sha': commit, 'force': False}, 'PATCH')
    print('Published', commit)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('action', choices=['create', 'push', 'release', 'runs'])
    p.add_argument('--message', default='Implement Podkop AutoSwitch with LuCI and runtime checks')
    p.add_argument('--version', default='0.1.2')
    p.add_argument('--commit', default='main')
    a = p.parse_args()
    if a.action == 'create':
        try:
            existing = api('/repos/' + REPO)
            print('Existing repository:', existing['html_url'])
        except urllib.error.HTTPError as e:
            if e.code != 404: raise
            repo = api('/user/repos', {'name': REPO.split('/')[1], 'description': 'Sticky proxy failover and subscription management for ITDog Podkop on OpenWrt', 'private': False, 'auto_init': True})
            print('Created', repo['html_url'])
    elif a.action == 'push': publish(a.message)
    elif a.action == 'release':
        body = (ROOT / 'docs/RELEASE.md').read_text(encoding='utf-8')
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', a.version): raise ValueError('Invalid version')
        r = api(f'/repos/{REPO}/releases', {'tag_name': 'v' + a.version, 'target_commitish': a.commit, 'name': 'Podkop AutoSwitch ' + a.version + ' (preview)', 'body': body, 'prerelease': True, 'draft': False})
        print(r['html_url'])
    else:
        runs = api(f'/repos/{REPO}/actions/runs?per_page=5')['workflow_runs']
        print(json.dumps([{k:r[k] for k in ['id','name','status','conclusion','html_url','head_sha']} for r in runs], indent=2))

if __name__ == '__main__': main()

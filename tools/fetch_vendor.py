#!/usr/bin/env python3
"""Fetch pinned MIT reference sources only; never execute downloaded code."""
import hashlib, json, pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
TAG = 'v3.0.17'
FILES = ['LICENSE', 'SMC/smc.swift', 'Modules/Sensors/values.swift']
def main():
    dest = ROOT / 'Vendor' / 'Stats'
    dest.mkdir(parents=True, exist_ok=True)
    manifest = {'repository': 'https://github.com/exelban/stats', 'ref': TAG, 'files': []}
    for name in FILES:
        url = f'https://raw.githubusercontent.com/exelban/stats/{TAG}/{name}'
        data = subprocess.run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error', '--connect-timeout', '10', '--max-time', '35', url], check=True, capture_output=True, timeout=40).stdout
        if len(data) > 1_000_000:
            raise ValueError('Reference file exceeds limit')
        target = dest / name.replace('/', '_')
        target.write_bytes(data)
        manifest['files'].append({'source': url, 'local': target.name, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
    (dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))
if __name__ == '__main__':
    main()

"""Verify external resources without downloading or reading local settings."""
import argparse
import hashlib
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hash', action='store_true', help='Also verify SHA-256; otherwise check path and size.')
args = parser.parse_args()
manifest = json.loads((ROOT / 'resources/manifest.json').read_text(encoding='utf-8'))
missing, invalid, optional = [], [], []
for item in manifest['files']:
    path = (ROOT / item['path']).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError('Invalid resource path')
    if not path.is_file():
        (missing if item['required'] else optional).append(item['path'])
        continue
    if path.stat().st_size != item['bytes']:
        invalid.append(item['path'])
    elif args.hash:
        with path.open('rb') as handle:
            if hashlib.file_digest(handle, 'sha256').hexdigest() != item['sha256']:
                invalid.append(item['path'])
print('Required missing:', len(missing), 'Invalid:', len(invalid), 'Optional missing:', len(optional))
for name in (missing + invalid)[:12]:
    print('  ' + name)
if missing or invalid:
    print('See docs/ASSETS.md. This repository contains source code, not the external content pack.')
raise SystemExit(1 if missing or invalid else 0)

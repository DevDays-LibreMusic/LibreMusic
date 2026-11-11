#!/usr/bin/env python3
"""Build independent, reproducible Mornye packages without dependencies."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import zipfile

BASE = Path(__file__).resolve().parent
PROVIDERS = ('zvuk', 'vk-music', 'kion-music', 'deezer-direct',
             'amazon-direct', 'ytmusic-direct', 'qobuz-direct', 'tidal-direct', 'beatport-direct')


def package(name):
    directory = BASE / name
    manifest = json.loads((directory / 'manifest.json').read_text())
    parts = [] if name == 'kion-music' else [BASE / 'shared/provider.js']
    if name == 'vk-music':
        parts.append(BASE / 'shared/hls.js')
    if name in ('qobuz-direct', 'tidal-direct', 'beatport-direct'):
        parts.append(BASE / 'shared/direct.js')
    parts.append(directory / 'index.js')
    files = {'index.js': '\n'.join(p.read_text() for p in parts).encode()}
    for filename in ('manifest.json', 'README.md', 'THIRD_PARTY_NOTICES.txt'):
        files[filename] = (directory / filename).read_bytes()
    for filename in ('LICENSE', 'COPYING', 'NOTICE'):
        files[filename] = (BASE.parent / filename).read_bytes()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        for filename, content in sorted(files.items()):
            info = zipfile.ZipInfo(filename, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content)
    return manifest, buffer.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('providers', nargs='*', help='Default: all providers')
    parser.add_argument('--output-dir', type=Path, default=BASE.parent / '.tmp/extensions')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for name in args.providers or PROVIDERS:
        if name not in PROVIDERS:
            parser.error('Unknown provider: ' + name)
        manifest, data = package(name)
        target = args.output_dir / (name + '-' + manifest['version'] + '.sflx')
        if args.check:
            if not target.is_file() or target.read_bytes() != data:
                parser.exit(1, 'Package differs or is missing: ' + str(target) + '\n')
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        print(str(target) + '\nSHA-256: ' + hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build the LibreMusic HTTPS extension catalog from maintained local sources."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
from urllib.parse import urlsplit

from build import BASE, PROVIDERS, package

DEFAULT_URL = ('https://raw.githubusercontent.com/DevDays-LibreMusic/'
               'LibreMusic/main/extensions/catalog')


def catalog_files(base_url):
    url = urlsplit(base_url)
    if url.scheme != 'https' or not url.hostname or url.query or url.fragment:
        raise ValueError('Base URL must be an HTTPS directory URL without query or fragment')
    base_url = base_url.rstrip('/')
    spec = importlib.util.spec_from_file_location('yandex_build', BASE / 'yandex-music/build.py')
    yandex = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(yandex)
    packages = [package(name) for name in PROVIDERS]
    packages.append((json.loads((BASE / 'yandex-music/manifest.json').read_text()), yandex.package()))
    files = {}
    entries = []
    for manifest, data in sorted(packages, key=lambda item: item[0]['name']):
        name = manifest['name']
        if Path(name).name != name or name in ('.', '..'):
            raise ValueError('Invalid extension name: ' + name)
        filename = 'packages/' + name + '.sflx'
        if filename in files:
            raise ValueError('Duplicate extension: ' + name)
        files[filename] = data
        entries.append({
            'id': name, 'name': name, 'display_name': manifest['displayName'],
            'version': manifest['version'], 'description': manifest['description'],
            'download_url': base_url + '/' + filename,
            'sha256': hashlib.sha256(data).hexdigest(),
            'min_app_version': manifest['minAppVersion'], 'runtime': 'javascript',
            'category': 'download' if 'download_provider' in manifest['type'] else 'integration',
            'tags': manifest['type'],
        })
    files['registry.json'] = (json.dumps({'version': 1, 'extensions': entries},
                                        ensure_ascii=False, indent=2) + '\n').encode()
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=BASE / 'catalog')
    parser.add_argument('--base-url', default=DEFAULT_URL)
    parser.add_argument('--check', action='store_true', help='Verify sources, packages and index without writing')
    args = parser.parse_args()
    try:
        files = catalog_files(args.base_url)
    except ValueError as error:
        parser.error(str(error))
    stale = []
    for name, data in files.items():
        path = args.output_dir / name
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                stale.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    extra = sorted(str(path.relative_to(args.output_dir))
                   for path in (args.output_dir / 'packages').glob('*.sflx')
                   if str(path.relative_to(args.output_dir)) not in files)
    if stale or extra:
        parser.exit(1, 'Catalog differs: ' + ', '.join(stale + extra) + '\n')
    print(('Verified' if args.check else 'Built') + f' {len(files) - 1} extensions: {args.output_dir}')


if __name__ == '__main__':
    main()

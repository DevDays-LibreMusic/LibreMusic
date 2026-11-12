"""Regression checks for the distributable catalog and integrity verification."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE))
import build_catalog


class CatalogTest(unittest.TestCase):
    def test_installable_packages_match_index(self):
        files = build_catalog.catalog_files(build_catalog.DEFAULT_URL)
        index = json.loads(files['registry.json'])
        self.assertEqual(index['version'], 1)
        entries = index['extensions']
        self.assertEqual(len(entries), 10)
        self.assertEqual(len({entry['id'] for entry in entries}), 10)
        for entry in entries:
            with self.subTest(provider=entry['id']):
                path = 'packages/' + entry['id'] + '.sflx'
                data = files[path]
                self.assertEqual(entry['download_url'], build_catalog.DEFAULT_URL + '/' + path)
                self.assertEqual(entry['sha256'], hashlib.sha256(data).hexdigest())
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertTrue({'index.js', 'manifest.json', 'README.md', 'LICENSE', 'COPYING', 'NOTICE'} <= set(archive.namelist()))
                    manifest = json.loads(archive.read('manifest.json'))
                    self.assertEqual(entry['id'], manifest['name'])
                    self.assertEqual(entry['version'], manifest['version'])
                    self.assertEqual(entry['min_app_version'], manifest['minAppVersion'])
        self.assertEqual(files, build_catalog.catalog_files(build_catalog.DEFAULT_URL))

    def test_check_detects_corruption_missing_and_extra_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            args = [sys.executable, str(BASE / 'build_catalog.py'), '--output-dir', directory]
            subprocess.run(args, check=True, capture_output=True)
            subprocess.run(args + ['--check'], check=True, capture_output=True)
            package = Path(directory) / 'packages/zvuk.sflx'
            original = package.read_bytes()
            for corrupted in (b'broken archive', None):
                if corrupted is None:
                    package.unlink()
                else:
                    package.write_bytes(corrupted)
                result = subprocess.run(args + ['--check'], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'packages/zvuk.sflx', result.stderr)
                package.write_bytes(original)
            (Path(directory) / 'packages/obsolete.sflx').write_bytes(original)
            result = subprocess.run(args + ['--check'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'obsolete.sflx', result.stderr)

    def test_custom_host_and_invalid_urls(self):
        index = json.loads(build_catalog.catalog_files('https://example.org/catalog/')['registry.json'])
        self.assertTrue(all(entry['download_url'].startswith('https://example.org/catalog/packages/')
                            for entry in index['extensions']))
        for url in ('http://example.org', 'file:///tmp/catalog', 'https://',
                    'https://example.org/?token=x', 'https://example.org/#index'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                build_catalog.catalog_files(url)


if __name__ == '__main__':
    unittest.main()

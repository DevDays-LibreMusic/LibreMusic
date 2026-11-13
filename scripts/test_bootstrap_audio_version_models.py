import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import bootstrap_audio_version_models as bootstrap


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = b'official-model-fixture'
        self.pin = {'bytes': len(self.payload), 'sha256': hashlib.sha256(self.payload).hexdigest()}

    def test_verified_source_reused_without_network(self):
        source = self.root / 'source'
        source.write_bytes(self.payload)
        with patch.object(bootstrap.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            bootstrap.source_file(source, 'https://example.invalid/model', self.pin)

    def test_corrupt_cached_source_fails_without_download(self):
        source = self.root / 'source'
        source.write_bytes(b'bad')
        with patch.object(bootstrap.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            with self.assertRaisesRegex(RuntimeError, 'length mismatch'):
                bootstrap.source_file(source, 'https://example.invalid/model', self.pin)

    def test_download_is_not_published_until_verified(self):
        import io
        source = self.root / 'source'
        with patch.object(bootstrap.urllib.request, 'urlopen', return_value=io.BytesIO(b'x' * len(self.payload))):
            with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                bootstrap.source_file(source, 'https://example.invalid/model', self.pin)
        self.assertFalse(source.exists())
        self.assertFalse(source.with_suffix('.partial').exists())

    def test_missing_or_changed_export_is_rejected(self):
        model = dict(self.pin, source='model.onnx')
        with self.assertRaises(RuntimeError):
            bootstrap.verify_exports(self.root, [model])
        (self.root / 'model.onnx').write_bytes(self.payload)
        bootstrap.verify_exports(self.root, [model])
        (self.root / 'model.onnx').write_bytes(b'x' * len(self.payload))
        with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
            bootstrap.verify_exports(self.root, [model])


if __name__ == '__main__':
    unittest.main()

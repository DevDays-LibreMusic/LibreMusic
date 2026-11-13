from pathlib import Path
import hashlib
import tempfile
import unittest
import zipfile

import bundle_audio_version_models as bundle


class ModelBundleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'inputs/model.onnx'
        self.source.parent.mkdir()
        self.source.write_bytes(b'pinned model')
        self.models = [{'source': 'model.onnx', 'asset': 'audio-version-models/model.onnx',
                        'bytes': self.source.stat().st_size,
                        'sha256': hashlib.sha256(self.source.read_bytes()).hexdigest()}]
        self.staging = self.root / 'assets'

    def test_stage_validated_links_and_replace_stale_contents(self):
        self.staging.mkdir()
        (self.staging / 'stale').write_text('old')
        evidence = bundle.stage(self.source.parent, self.staging, self.models)
        link = self.staging / self.models[0]['asset']
        self.assertTrue(link.is_symlink())
        self.assertEqual(self.source.resolve(), link.resolve())
        self.assertFalse((self.staging / 'stale').exists())
        self.assertEqual(str(self.source.resolve()), evidence[0]['canonical_input'])
        self.assertEqual([], list(self.root.glob('.bundled-model-assets-*')))

    def test_invalid_inputs_fail_before_replacing_previous_stage(self):
        self.staging.mkdir()
        old = self.staging / 'previous'
        old.write_text('preserve')
        for value in (b'wrong length', b'bad model!!!'):
            self.source.write_bytes(value)
            with self.assertRaises(RuntimeError):
                bundle.stage(self.source.parent, self.staging, self.models)
            self.assertEqual('preserve', old.read_text())
        with self.assertRaises(RuntimeError):
            bundle.stage(None, self.staging, self.models)

    def test_canonical_input_cannot_escape_root(self):
        self.source.unlink()
        outside = self.root / 'outside'
        outside.write_bytes(b'pinned model')
        self.source.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, 'escapes'):
            bundle.stage(self.source.parent, self.staging, self.models)

    def archive(self, entries):
        path = self.root / 'fixture.apk'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, value in entries:
                archive.writestr(name, value)
        return zipfile.ZipFile(path)

    def test_apk_requires_exact_models_and_rejects_training_payloads(self):
        name = 'assets/' + self.models[0]['asset']
        cases = [([], 'Missing'), ([(name, b'bad')], 'differs'),
                 ([(name, b'pinned model'), ('assets/debug.npz', b'x')], 'Unexpected'),
                 ([(name, b'pinned model'), (name, b'pinned model')], 'duplicate')]
        for entries, error in cases:
            with self.subTest(error=error), self.archive(entries) as archive:
                with self.assertRaisesRegex(RuntimeError, error):
                    bundle.audit_archive(archive, self.models)
        with self.archive([(name, b'pinned model')]) as archive:
            self.assertEqual(self.models[0]['sha256'], bundle.audit_archive(archive, self.models)[0]['sha256'])


if __name__ == '__main__':
    unittest.main()

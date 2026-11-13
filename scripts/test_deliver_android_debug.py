from pathlib import Path
import tempfile
import unittest
import json
import os
import subprocess
from unittest.mock import patch
import zipfile

import deliver_android_debug as delivery


class DeliverySafetyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_failed_checks_or_build_never_publish_and_config_follows_checks(self):
        for failure in ('check', 'apk'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                flutter = root / '.fvm/flutter_sdk/bin/flutter'
                flutter.parent.mkdir(parents=True)
                flutter.touch()
                (root / '.fvmrc').write_text(json.dumps({'flutter': 'pinned'}))
                patch_file = root / 'patches/flutter/pinned-semantics-geometry.patch'
                patch_file.parent.mkdir(parents=True)
                patch_file.write_text('patch')
                sdk_file = flutter.parent.parent / 'packages/flutter/lib/src/rendering/object.dart'
                sdk_file.parent.mkdir(parents=True)
                sdk_file.write_text('patched source')
                sdk = root / 'sdk'
                for name in ('apksigner', 'aapt'):
                    tool = sdk / 'build-tools/37.0.0' / name
                    tool.parent.mkdir(parents=True, exist_ok=True)
                    tool.touch()
                out = root / 'exports'
                commands = []
                def fake_run(command, **kwargs):
                    commands.append(command)
                    fails = ('--run' in command if failure == 'check' else '--debug' in command)
                    return subprocess.CompletedProcess(command, 7 if fails else 0)
                with patch.object(delivery, 'ROOT', root), \
                     patch.object(delivery.models, 'stage', return_value=[]), \
                     patch.object(delivery, 'clean_source', return_value='a' * 40), \
                     patch.object(delivery.subprocess, 'check_output', return_value=b'{"frameworkVersion":"pinned"}'), \
                     patch.object(delivery.subprocess, 'run', side_effect=fake_run), \
                     patch.dict(os.environ, {'ANDROID_HOME': str(sdk)}), \
                     patch('sys.argv', ['delivery', '--output-dir', str(out), '--check-area', 'logging']):
                    with self.assertRaisesRegex(RuntimeError, 'failed with exit 7'):
                        delivery.main()
                self.assertEqual([], list(out.iterdir()))
                self.assertIn('scripts/prepare_flutter_sdk.dart', commands[0])
                self.assertEqual(['pub', 'get', '--enforce-lockfile'], commands[1][-3:])
                self.assertIn('--run', commands[2])
                if failure == 'check':
                    self.assertEqual(3, len(commands))
                else:
                    self.assertIn('--config-only', commands[3])
                    self.assertEqual(['bash', 'scripts/build_rust_backend.sh', 'android'], commands[4])
                    self.assertIn('--debug', commands[5])

    def test_missing_model_root_refuses_before_toolchain_or_build(self):
        with patch.object(delivery, 'ROOT', self.root), \
             patch.object(delivery, 'clean_source', return_value='a' * 40), \
             patch.object(delivery.subprocess, 'run') as run, \
             patch.dict(os.environ, {}, clear=True), \
             patch('sys.argv', ['delivery', '--check-area', 'build']):
            with self.assertRaisesRegex(RuntimeError, 'Self-contained APK requires'):
                delivery.main()
            run.assert_not_called()

    def test_delivery_lock_excludes_second_builder(self):
        first = delivery.acquire_lock(self.root)
        try:
            with self.assertRaisesRegex(RuntimeError, 'lock'):
                delivery.acquire_lock(self.root)
        finally:
            first.close()
        delivery.acquire_lock(self.root).close()

    def test_signature_requires_v2_and_checks_explicit_update_certificate(self):
        digest = 'a' * 64
        signature = ('certificate SHA-256 digest: ' + digest + '\n'
                     'Verified using v2 scheme (APK Signature Scheme v2): true')
        self.assertEqual(digest, delivery.audit_signature(signature))
        self.assertEqual(digest, delivery.audit_signature(signature, digest.upper()))
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            delivery.audit_signature(signature, 'b' * 64)
        with self.assertRaisesRegex(RuntimeError, 'valid APK v2'):
            delivery.audit_signature(signature.replace('true', 'false'))

    def test_clean_gate_rejects_tracked_untracked_and_changed_head(self):
        with patch.object(delivery, 'git', return_value=' M lib/player.dart'):
            with self.assertRaisesRegex(RuntimeError, 'dirty'):
                delivery.clean_source(self.root)
        with patch.object(delivery, 'git', return_value='?? .env'):
            with self.assertRaises(RuntimeError):
                delivery.clean_source(self.root)
        with patch.object(delivery, 'git', side_effect=['', 'new-head']):
            with self.assertRaisesRegex(RuntimeError, 'HEAD changed'):
                delivery.clean_source(self.root, 'old-head')
        with patch.object(delivery, 'git', side_effect=['', 'same']):
            self.assertEqual('same', delivery.clean_source(self.root, 'same'))

    def test_cleanup_preserves_unrelated_output_and_rejects_symlink(self):
        preserved = self.root / 'build/user-download.txt'
        preserved.parent.mkdir()
        preserved.write_text('keep')
        generated = self.root / delivery.GENERATED[0]
        generated.mkdir(parents=True)
        (generated / 'cache').write_text('generated')
        delivery.clean_packaging(self.root)
        self.assertFalse(generated.exists())
        self.assertEqual('keep', preserved.read_text())
        generated.parent.mkdir(parents=True, exist_ok=True)
        generated.symlink_to(preserved.parent, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            delivery.clean_packaging(self.root)
        self.assertTrue(preserved.exists())

    def apk(self, marker='expected', extra=None, padding=0):
        path = self.root / 'app.apk'
        with path.open('wb') as stream:
            stream.write(b'x' * padding)
        with zipfile.ZipFile(path, 'a') as archive:
            archive.writestr('assets/flutter_assets/kernel_blob.bin', marker)
            for lib in ('libflutter.so', 'libmornye_mobile.so', 'libjnidispatch.so'):
                archive.writestr('lib/arm64-v8a/' + lib, b'native')
            if extra:
                archive.writestr(extra, 'secret placeholder')
        native = self.root / 'native.so'
        native.write_bytes(b'native')
        return path, native

    def audit(self, path, native):
        with patch.object(delivery.payload, 'check_elf'), \
             patch.object(delivery.payload, 'check_backend_markers'):
            return delivery.audit_apk(path, 'expected', native, [])

    def test_audit_rejects_marker_native_mismatch_secret_entries_and_gaps(self):
        path, native = self.apk()
        self.assertEqual(4, self.audit(path, native)['entries'])
        native.write_bytes(b'stale')
        with self.assertRaisesRegex(RuntimeError, 'Rust payload'):
            self.audit(path, native)
        for name in ('assets/.env', 'assets/.env.local', 'assets/lastfm-session.json',
                     'lib/arm64-v8a/libdiscord_partner_sdk.so'):
            path, native = self.apk(extra=name)
            with self.assertRaisesRegex(RuntimeError, 'Forbidden'):
                self.audit(path, native)
        path, native = self.apk(marker='old build')
        with self.assertRaisesRegex(RuntimeError, 'marker'):
            self.audit(path, native)
        path, native = self.apk(padding=delivery.MAX_ZIP_OVERHEAD + 1)
        with self.assertRaisesRegex(RuntimeError, 'overhead'):
            self.audit(path, native)


if __name__ == '__main__':
    unittest.main()

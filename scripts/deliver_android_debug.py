#!/usr/bin/env python3
"""Build a committed ARM64 Lite debug APK and its measured provenance manifest."""
import argparse
import atexit
import fcntl
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

import check_backend_apk as payload

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.zarz.mornye.debug'
ABI = 'arm64-v8a'
MAX_ZIP_OVERHEAD = 1024 * 1024
GENERATED = (
    'build/app/intermediates/incremental/packageDebug',
    'build/app/outputs/apk/debug',
    'build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk',
)


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def clean_source(root, expected=None):
    if git(root, 'status', '--porcelain=v1', '--untracked-files=all'):
        raise RuntimeError('Commit or isolate intended changes first: tracked/untracked source is dirty.')
    commit = git(root, 'rev-parse', 'HEAD')
    if expected and commit != expected:
        raise RuntimeError('HEAD changed during delivery; artifact cannot be attributed to the initial commit.')
    return commit


def clean_packaging(root):
    root = root.resolve()
    for relative in GENERATED:
        path = root / relative
        if any(p.is_symlink() for p in [path, *path.parents] if p.is_relative_to(root)):
            raise RuntimeError('Refusing packaging cleanup through a symlink.')
        if not path.resolve().is_relative_to(root.resolve()):
            raise RuntimeError('Generated packaging path escapes repository.')
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def audit_apk(path, marker, native):
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = archive.namelist()
        payload.check_archive_integrity(archive, infos)
        payload.check_abi_directories(names, (ABI,))
        payload.check_backend_markers(archive, infos, 'rust')
        forbidden = [name for name in names if
                     Path(name).name.startswith('.env') or
                     Path(name).name in ('lastfm-session.json', 'lastfm-pending-auth.json',
                                         'libdiscord_partner_sdk.so')]
        if forbidden:
            raise RuntimeError('Forbidden APK entries: ' + ', '.join(forbidden))
        kernel = archive.read('assets/flutter_assets/kernel_blob.bin')
        if marker.encode() not in kernel:
            raise RuntimeError('Diagnostic source marker is absent from the Dart payload.')
        for lib in ('libflutter.so', 'libmornye_mobile.so', 'libjnidispatch.so'):
            name = f'lib/{ABI}/{lib}'
            payload.check_elf(archive.read(name)[:20], name, ABI)
        native_hash = hashlib.sha256(archive.read(f'lib/{ABI}/libmornye_mobile.so')).hexdigest()
        if native_hash != sha(native):
            raise RuntimeError('APK Rust payload differs from the current stripped build output.')
        compressed = sum(info.compress_size for info in infos)
        overhead = path.stat().st_size - compressed
        if overhead > MAX_ZIP_OVERHEAD:
            raise RuntimeError(f'Unexpected ZIP packaging overhead: {overhead} bytes.')
        return {'entries': len(infos), 'compressed_payload_bytes': compressed,
                'packaging_overhead_bytes': overhead, 'rust_payload_sha256': native_hash,
                'forbidden_entry_name_check': 'passed (not a general secret scanner)'}


def audit_signature(signature, expected=None):
    cert = re.search(r'certificate SHA-256 digest: ([0-9a-f]{64})', signature)
    if not cert or 'Verified using v2 scheme (APK Signature Scheme v2): true' not in signature:
        raise RuntimeError('Expected a valid APK v2 signature.')
    if expected and cert.group(1) != expected.lower():
        raise RuntimeError('APK signing certificate differs from the expected update certificate.')
    return cert.group(1)


def acquire_lock(root):
    directory = root / 'build'
    directory.mkdir(exist_ok=True)
    handle = (directory / 'local-delivery.lock').open('a')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError('Another delivery owns the repository build lock.') from None
    return handle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=Path.home() / 'Downloads')
    parser.add_argument('--check-area', action='append', required=True,
                        choices=('lastfm', 'playback', 'logging', 'build'))
    parser.add_argument('--expected-certificate', help='Expected signing certificate SHA-256 for an update delivery')
    args = parser.parse_args()
    if args.expected_certificate and not re.fullmatch(r'[0-9a-fA-F]{64}', args.expected_certificate):
        parser.error('--expected-certificate must contain 64 hexadecimal characters')
    lock = acquire_lock(ROOT)
    atexit.register(lock.close)
    commit = clean_source(ROOT)
    marker = f'commit-{commit[:12]}-debug-arm64-lite'
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output = args.output_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    name = f'LibreMusic-debug-arm64-{commit[:12]}-{stamp}'
    apk_out, manifest_out = output / (name + '.apk'), output / (name + '.json')
    if apk_out.exists() or manifest_out.exists():
        raise RuntimeError('Delivery destination already exists; refusing overwrite.')
    env = os.environ.copy()
    env.setdefault('JAVA_HOME', str(Path.home() / '.local/share/mise/installs/java/temurin-25.0.5+8.0.LTS/Contents/Home'))
    env['PATH'] = str(Path(env['JAVA_HOME']) / 'bin') + os.pathsep + env.get('PATH', '')
    env.setdefault('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools')
    env['ANDROID_NDK_HOME'] = str(Path(env['ANDROID_HOME']) / 'ndk/30.0.16248370')
    env['MORNYE_RUST_ANDROID_ABIS'] = ABI
    env['MORNYE_DISCORD_SDK'] = '0'
    flutter = ROOT / '.fvm/flutter_sdk/bin/flutter'
    if not flutter.is_file():
        raise RuntimeError('Install the pinned SDK with FVM before delivery.')
    pinned = json.loads((ROOT / '.fvmrc').read_text())['flutter']
    sdk_version = json.loads(subprocess.check_output([str(flutter), '--version', '--machine'], env=env))
    actual = sdk_version['frameworkVersion']
    if actual != pinned:
        raise RuntimeError(f'Expected pinned Flutter {pinned}; found {actual}.')
    build_tools = Path(env['ANDROID_HOME']) / 'build-tools/37.0.0'
    for tool in ('apksigner', 'aapt'):
        if not (build_tools / tool).is_file():
            raise RuntimeError(f'Missing Android build tool: {tool}')
    records = []
    logdir = ROOT / 'build/delivery-logs' / name
    logdir.mkdir(parents=True)

    def run(label, command):
        started = dt.datetime.now(dt.timezone.utc).isoformat()
        logfile = logdir / (label + '.log')
        print(f'{label} → {logfile}', flush=True)
        with logfile.open('w') as stream:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT)
        records.append({'stage': label, 'command': command, 'started_utc': started,
                        'exit_code': result.returncode, 'log_path': str(logfile.relative_to(ROOT)),
                        'log_sha256': sha(logfile)})
        if result.returncode:
            raise RuntimeError(f'{label} failed with exit {result.returncode}; inspect {logfile}. No delivery manifest produced.')
        return logfile.read_text()

    run('prepare-sdk', [str(flutter.with_name('dart')), 'scripts/prepare_flutter_sdk.dart'])
    patch_file = ROOT / 'patches/flutter' / f'{pinned}-semantics-geometry.patch'
    patched_sdk_file = flutter.parent.parent / 'packages/flutter/lib/src/rendering/object.dart'
    sdk_evidence = {'framework_revision': sdk_version.get('frameworkRevision'),
                    'patch_sha256': sha(patch_file),
                    'patched_rendering_object_sha256': sha(patched_sdk_file)}
    run('dependencies', [str(flutter), 'pub', 'get', '--enforce-lockfile'])
    clean_source(ROOT, commit)
    for area in dict.fromkeys(args.check_area):
        run('check-' + area, [sys.executable, 'scripts/check_local_changes.py', '--run', area])
    clean_source(ROOT, commit)
    # Tests can alter plugin registrations: config-only must be AFTER all checks.
    run('config', [str(flutter), 'build', 'apk', '--config-only'])
    # Cargo checks the current source even when Gradle considers native outputs cached.
    run('native', ['bash', 'scripts/build_rust_backend.sh', 'android'])
    clean_packaging(ROOT)
    private_defines = env.get('MORNYE_LASTFM_CONFIG_FILE')
    extra_defines = [f'--dart-define-from-file={private_defines}'] if private_defines else []
    run('apk', [str(flutter), 'build', 'apk', '--debug', '--target-platform', 'android-arm64',
                '--split-per-abi', f'--dart-define=MORNYE_DIAGNOSTIC_BUILD={marker}',
                f'--dart-define=GIT_COMMIT={commit}', *extra_defines])
    clean_source(ROOT, commit)
    apk = ROOT / GENERATED[-1]
    native = ROOT / 'build/app/intermediates/stripped_native_libs/debug/stripDebugDebugSymbols/out/lib/arm64-v8a/libmornye_mobile.so'
    native_input = ROOT / 'rust_backend/target/android/jniLibs/arm64-v8a/libmornye_mobile.so'
    strips = list(Path(env['ANDROID_NDK_HOME']).glob('toolchains/llvm/prebuilt/*/bin/llvm-strip'))
    if len(strips) != 1:
        raise RuntimeError('Cannot identify the pinned NDK llvm-strip tool.')
    with tempfile.TemporaryDirectory(prefix='mornye-native-audit-') as directory:
        expected = Path(directory) / 'libmornye_mobile.so'
        run('strip-audit', [str(strips[0]), '--strip-unneeded', '-o', str(expected), str(native_input)])
        if sha(expected) != sha(native):
            raise RuntimeError('Gradle native output is stale relative to current Cargo/JNI input.')
        audit = audit_apk(apk, marker, expected)
    audit['rust_jni_input_sha256'] = sha(native_input)
    signature = run('signature', [str(build_tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)])
    certificate = audit_signature(signature, args.expected_certificate)
    badging = run('package', [str(build_tools / 'aapt'), 'dump', 'badging', str(apk)])
    if f"package: name='{PACKAGE}'" not in badging or f"native-code: '{ABI}'" not in badging:
        raise RuntimeError('Unexpected application ID or ABI.')
    version = re.search(r"versionCode='([^']+)' versionName='([^']+)'", badging)
    if not version:
        raise RuntimeError('Cannot read APK version metadata.')
    clean_source(ROOT, commit)
    if sha(patched_sdk_file) != sdk_evidence['patched_rendering_object_sha256']:
        raise RuntimeError('Patched Flutter SDK changed during delivery.')
    manifest = {'schema': 1, 'source_commit': commit, 'source_tree': git(ROOT, 'rev-parse', 'HEAD^{tree}'),
                'built_utc': dt.datetime.now(dt.timezone.utc).isoformat(), 'build_marker': marker,
                'variant': 'debug', 'lite': True, 'package': PACKAGE, 'abis': [ABI],
                'version_code': version.group(1), 'version_name': version.group(2),
                'flutter': actual, 'flutter_sdk_evidence': sdk_evidence,
                'android_build_tools': '37.0.0', 'android_ndk': '30.0.16248370',
                'certificate_sha256': certificate,
                'apk': apk_out.name, 'apk_sha256': sha(apk), 'apk_bytes': apk.stat().st_size,
                'audit': audit, 'checks_and_builds': records,
                'device_validation': 'not performed by this delivery command',
                'scope': 'Only listed checks ran; exit 0 is command success, not proof every case executed. See logs for skips; no claim of a green full test suite.'}
    # Exclusive creation prevents accidental overwrites even if another process races.
    with apk_out.open('xb') as target, apk.open('rb') as source:
        shutil.copyfileobj(source, target)
    if sha(apk_out) != manifest['apk_sha256']:
        raise RuntimeError('Copied APK hash mismatch; do not distribute.')
    with manifest_out.open('x') as stream:
        json.dump(manifest, stream, indent=2)
        stream.write('\n')
    print(json.dumps({'apk': str(apk_out), 'manifest': str(manifest_out),
                      'source_commit': commit, 'sha256': manifest['apk_sha256'],
                      'bytes': manifest['apk_bytes']}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Delivery refused: {error}', file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Recover exact mobile exports from checksum-pinned official inputs, or verify cache.

No alternative weights or export formats are accepted. A platform-dependent export
that differs from the published pins fails before Android packaging.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

from bundle_audio_version_models import descriptors, digest, stage, validate

ROOT = Path(__file__).resolve().parent
EXPORT = ROOT / 'mobile_model_export'


def source_file(destination, url, pin):
    """Reuse only verified input; publish downloaded bytes after checksum validation."""
    if destination.exists():
        verify_source(destination, pin)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + '.partial')
    try:
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as output:
            while block := response.read(1024 * 1024):
                output.write(block)
        verify_source(temporary, pin)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def verify_source(path, pin):
    if 'bytes' in pin and path.stat().st_size != pin['bytes']:
        raise RuntimeError(f'Official source length mismatch: {path}')
    with path.open('rb') as stream:
        if digest(stream) != pin['sha256']:
            raise RuntimeError(f'Official source SHA-256 mismatch: {path}')


def verify_exports(root, models=None):
    for model in descriptors() if models is None else models:
        validate(root / model['source'], model)


def recover(root):
    manifest = json.loads((EXPORT / 'sources.json').read_text())
    # Source weights/intermediates are temporary and never enter the export cache.
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='mobile-model-inputs-') as temporary:
        work = Path(temporary)
        snapshots = []
        for source in manifest['sources']:
            snapshot = work / 'hf' / ('models--' + source['repo'].replace('/', '--')) / 'snapshots' / source['revision']
            for name, pin in source['files'].items():
                url = f"https://huggingface.co/{source['repo']}/resolve/{source['revision']}/{name}"
                source_file(snapshot / name, url, pin)
            refs = snapshot.parent.parent / 'refs'
            refs.mkdir(exist_ok=True)
            (refs / 'main').write_text(source['revision'])
            snapshots.append(snapshot)
        env = dict(os.environ, HF_HUB_CACHE=str(work / 'hf'), HF_HUB_OFFLINE='1',
                   TRANSFORMERS_OFFLINE='1', OPENBLAS_NUM_THREADS='1', OMP_NUM_THREADS='1')
        subprocess.run([sys.executable, str(EXPORT / 'export_wavlm_mobile.py'),
                        '--snapshot', str(snapshots[0]), '--output', str(root / 'wavlm')], check=True, env=env)
        # Original recovery used exactly this deterministic PCM fixture, not music.
        import numpy as np
        import wave
        i = np.arange(343980, dtype=np.float64)
        a = .2 * np.sin(2 * np.pi * 220 * i / 44100) + .07 * np.sin(2 * np.pi * 653 * i / 44100)
        b = .18 * np.sin(2 * np.pi * 330 * i / 44100) + .05 * np.cos(2 * np.pi * 887 * i / 44100)
        audio = work / 'synthetic.wav'
        with wave.open(str(audio), 'wb') as output:
            output.setnchannels(2)
            output.setsampwidth(2)
            output.setframerate(44100)
            output.writeframes((np.stack([a, b], axis=1) * 32767).astype('<i2').tobytes())
        subprocess.run([sys.executable, str(EXPORT / 'export_demucs_mobile.py'),
                        '--audio', str(audio), '--output', str(root / 'demucs')], check=True, env=env)
    verify_exports(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-root', default=os.environ.get('LIBREMUSIC_MODEL_ROOT',
                        str(Path.home() / '.cache/libremusic/mobile-models')))
    parser.add_argument('--require-existing', action='store_true')
    args = parser.parse_args()
    root = Path(args.model_root).expanduser().resolve()
    # Partial/corrupt caches are errors, never silently repaired or trusted.
    if args.require_existing or any((root / m['source']).exists() for m in descriptors()):
        verify_exports(root)
    else:
        recover(root)
    print(json.dumps(stage(root), indent=2))


if __name__ == '__main__':
    main()

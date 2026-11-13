#!/usr/bin/env python3
"""Validate pinned local exports and atomically stage Android assets without copies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / 'scripts/audio_version_model_pins.json'
STAGING = ROOT / 'android/app/.bundled-model-assets'


def digest(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(block)
    return result.hexdigest()


def descriptors(path=PINS):
    models = json.loads(path.read_text())['models']
    if not models or len({m['asset'] for m in models}) != len(models):
        raise RuntimeError('Invalid model descriptor set')
    for model in models:
        for key in ('source', 'asset'):
            relative = Path(model[key])
            if relative.is_absolute() or '..' in relative.parts:
                raise RuntimeError('Model paths must be relative and contained')
    return models


def validate(path, model):
    if not path.is_file() or path.stat().st_size != model['bytes']:
        raise RuntimeError(f'Missing or wrong-size pinned model: {path}')
    with path.open('rb') as stream:
        actual = digest(stream)
    if actual != model['sha256']:
        raise RuntimeError(f'Pinned model SHA-256 mismatch: {path}')


def stage(model_root, staging=STAGING, models=None):
    models = descriptors() if models is None else models
    if not model_root:
        raise RuntimeError('Self-contained APK requires --model-root or LIBREMUSIC_MODEL_ROOT')
    root = Path(model_root).expanduser().resolve()
    if not root.is_dir():
        raise RuntimeError(f'Missing model root: {root}')
    inputs = []
    for model in models:
        source = (root / model['source']).resolve()
        if not source.is_relative_to(root):
            raise RuntimeError('Model input escapes canonical model root')
        validate(source, model)
        inputs.append((model, source))
    staging.parent.mkdir(parents=True, exist_ok=True)
    if staging.is_symlink():
        raise RuntimeError('Refusing symlink staging root')
    temporary = Path(tempfile.mkdtemp(prefix='.bundled-model-assets-', dir=staging.parent))
    previous = temporary / '.previous'
    try:
        for model, source in inputs:
            target = temporary / model['asset']
            target.parent.mkdir(parents=True, exist_ok=True)
            # Symlinks work across filesystems, consume no extra model-sized space,
            # and AGP follows asset-file links. Audit the packaged bytes afterwards.
            target.symlink_to(source)
            validate(target, model)
        # Same-filesystem renames keep complete generations visible. Roll back
        # on publication failure and remove only this helper's old generation.
        if staging.exists():
            staging.rename(previous)
        try:
            temporary.rename(staging)
        except OSError:
            if previous.exists():
                previous.rename(staging)
            raise
        old = staging / '.previous'
        if old.exists():
            shutil.rmtree(old)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return [{**model, 'canonical_input': str(source), 'apk_entry': 'assets/' + model['asset']}
            for model, source in inputs]


def audit_archive(archive, models=None):
    models = descriptors() if models is None else models
    expected = {'assets/' + m['asset']: m for m in models}
    names = archive.namelist()
    unexpected = [n for n in names if Path(n).suffix.lower() in
                  ('.onnx', '.pt', '.pth', '.npz') and n not in expected]
    if unexpected:
        raise RuntimeError('Unexpected model/debug payload: ' + ', '.join(unexpected))
    measured = []
    for name, model in expected.items():
        if names.count(name) != 1:
            raise RuntimeError('Missing or duplicate bundled model: ' + name)
        info = archive.getinfo(name)
        with archive.open(info) as stream:
            actual = digest(stream)
        if info.file_size != model['bytes'] or actual != model['sha256']:
            raise RuntimeError('APK bundled model differs from pinned export: ' + name)
        measured.append({'apk_entry': name, 'bytes': info.file_size, 'sha256': actual})
    return measured


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-root', default=os.environ.get('LIBREMUSIC_MODEL_ROOT'))
    args = parser.parse_args()
    print(json.dumps(stage(args.model_root), indent=2))

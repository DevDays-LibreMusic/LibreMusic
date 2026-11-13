#!/usr/bin/env python3
"""Audit actual bundled ONNX ZIP streams in every supplied Android APK."""
import argparse
import json
from pathlib import Path
import zipfile
from bundle_audio_version_models import audit_archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', nargs='+', type=Path)
    args = parser.parse_args()
    for path in args.apk:
        with zipfile.ZipFile(path) as archive:
            print(json.dumps({'apk': str(path), 'models': audit_archive(archive)}, indent=2))


if __name__ == '__main__':
    main()

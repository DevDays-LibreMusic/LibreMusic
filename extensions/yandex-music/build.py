#!/usr/bin/env python3
"""Build a reproducible extension archive; keep build outputs out of Git."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import zipfile


def package(source=None):
    source = source or Path(__file__).resolve().parent
    root = source.parent.parent
    files = {name: source / name for name in ("manifest.json", "index.js", "README.md")}
    files.update({name: root / name for name in ("LICENSE", "COPYING", "NOTICE")})
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, path in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
    data = buffer.getvalue()
    return data


def main():
    source = Path(__file__).resolve().parent
    root = source.parent.parent
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / ".tmp" / (
        "yandex-music-" + manifest["version"] + ".sflx"))
    parser.add_argument("--check", action="store_true", help="Compare an existing package with source")
    args = parser.parse_args()
    data = package(source)
    if args.check:
        if not args.output.is_file() or args.output.read_bytes() != data:
            parser.exit(1, "Package is missing or differs from source. Run build.py first.\n")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
    print(args.output)
    print("SHA-256: " + hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    main()

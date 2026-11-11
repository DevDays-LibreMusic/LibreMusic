"""Copy resolved ELF dependencies from the build image into the runtime root."""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1])
for binary in (root / "usr/local/bin").iterdir():
    output = subprocess.check_output(["ldd", str(binary)], text=True)
    if "not found" in output:
        raise SystemExit(f"Unresolved dependency for {binary.name}")
    for line in output.splitlines():
        fields = line.split()
        path = next((Path(field) for field in fields if field.startswith("/")), None)
        if path is None:
            continue
        destination = root / str(path).lstrip("/")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)

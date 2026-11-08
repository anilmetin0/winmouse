#!/usr/bin/env python3
"""Generate the native updater manifest from the exact stable release image."""
import hashlib
import json
from pathlib import Path
import re
import sys

version, image_path = sys.argv[1:]
if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
    raise SystemExit("Native updates require a stable X.Y.Z version")
image = Path(image_path)
if image.name != f"WinMouse-{version}.dmg":
    raise SystemExit("The image filename does not match the release")
print(json.dumps({
    "version": version,
    "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
    "size": image.stat().st_size,
    "url": f"https://github.com/anilmetin0/winmouse/releases/download/v{version}/{image.name}",
    "releaseNotes": f"https://github.com/anilmetin0/winmouse/releases/tag/v{version}",
}, indent=2))

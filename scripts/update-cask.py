#!/usr/bin/env python3
"""Pin the stable cask after its release assets exist; optionally emit a GitHub PUT body."""
import argparse
import base64
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("version")
parser.add_argument("checksum")
parser.add_argument("--github-sha", help="Existing contents API SHA; emit a payload instead of writing")
args = parser.parse_args()
if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
    parser.error("a stable X.Y.Z version is required")
if not re.fullmatch(r"[0-9a-f]{64}", args.checksum):
    parser.error("a pinned SHA-256 checksum is required")

path = Path("Casks/winmouse.rb")
source = path.read_text()
old = re.findall(r'^  version "(\d+\.\d+\.\d+)"$', source, re.M)
if len(old) != 1 or tuple(map(int, args.version.split("."))) < tuple(map(int, old[0].split("."))):
    parser.error("the cask must have one stable version and must not be downgraded")
content, versions = re.subn(r'^  version "[^"\n]+"$', f'  version "{args.version}"', source, flags=re.M)
content, checksums = re.subn(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{args.checksum}"', content, flags=re.M)
if versions != 1 or checksums != 1:
    parser.error("expected exactly one version and one pinned checksum")
if args.github_sha:
    if not re.fullmatch(r"[0-9a-f]{40}", args.github_sha):
        parser.error("invalid GitHub contents SHA")
    print(json.dumps({"message": f"Update Homebrew cask to {args.version}", "branch": "main",
                      "sha": args.github_sha, "content": base64.b64encode(content.encode()).decode()}))
else:
    path.write_text(content)

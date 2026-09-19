#!/bin/sh
# Adapted from the forge template; Python keeps this repo free of jq.
set -eu
scriptDir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 - "$scriptDir/.." <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

repo = Path(sys.argv[1]).resolve()
try:
    plugin = json.loads((repo / ".claude-plugin/plugin.json").read_text())
    marketplace = json.loads((repo / ".claude-plugin/marketplace.json").read_text())
    result = subprocess.run([str(repo / "skills/jev-skill/bin/jev"), "--version"], capture_output=True, text=True, timeout=10, check=True)
    match = re.fullmatch(r"jev (\d+\.\d+\.\d+)\n?", result.stdout)
    entries = marketplace["plugins"]
    valid = len(entries) == 1 and entries[0]["name"] == plugin["name"] == marketplace["name"] == "jev-skills"
    versions = [plugin["version"], entries[0]["version"], match[1] if match else None]
    valid = valid and match is not None and len(set(versions)) == 1 and not result.stderr
    print("plugin / marketplace / CLI: " + " / ".join(str(v) for v in versions))
except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError):
    valid = False
if not valid:
    print("check-version-chain: FAIL", file=sys.stderr)
    sys.exit(1)
print("check-version-chain: PASS (versions agree; this is not a release verdict)")
PY

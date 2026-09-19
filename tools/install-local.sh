#!/bin/sh
# Link a caller-selected canonical skill directory. Never replace a destination.
set -eu
exec python3 - "$@" <<'PY'
import argparse
import os
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description="Install shared Jev symlinks without replacing existing paths.")
parser.add_argument("--check", action="store_true", help="verify all links without writing")
parser.add_argument("skillPath", help="absolute canonical path to the jev-skill directory")
args = parser.parse_args()


def fail(message):
    print("install-local: FAIL " + message, file=sys.stderr)
    sys.exit(1)


def expectedLink(path, target):
    return path.is_symlink() and path.resolve(strict=True) == target.resolve(strict=True)


try:
    source = Path(args.skillPath)
    if not source.is_absolute() or source.resolve(strict=True) != source:
        fail("skill path must be absolute and canonical")
    if not (source / "SKILL.md").is_file() or not (source / "bin/jev").is_file() or not os.access(source / "bin/jev", os.X_OK):
        fail("source must contain SKILL.md and executable bin/jev")
    userRoot = Path.home()
    links = (
        (userRoot / ".codex/skills/jev-skill", source),
        (userRoot / ".agents/skills/jev-skill", source),
        (userRoot / ".local/bin/jev", source / "bin/jev"),
    )
    missing = []
    # Preflight the entire plan before creating any directory or link.
    for destination, target in links:
        if os.path.lexists(destination):
            if not expectedLink(destination, target):
                fail("destination conflicts: " + str(destination))
        else:
            missing.append((destination, target))
        for parent in destination.parents:
            if os.path.lexists(parent) and not parent.is_dir():
                fail("parent is not a directory: " + str(parent))
    if args.check:
        if missing:
            fail("missing links: " + ", ".join(str(path) for path, _ in missing))
    else:
        for destination, target in missing:
            destination.parent.mkdir(parents=True, exist_ok=True)
            # Exclusive creation also refuses a destination appearing after preflight.
            try:
                destination.symlink_to(target, target_is_directory=target.is_dir())
            except FileExistsError:
                if not expectedLink(destination, target):
                    fail("destination changed during installation: " + str(destination))
    for destination, target in links:
        if not expectedLink(destination, target):
            fail("link verification failed: " + str(destination))
        print(str(destination) + " -> " + str(target))
except (OSError, RuntimeError):
    fail("cannot resolve or create the requested links; inspect source and destination paths")
print("install-local: PASS" + (" (check only)" if args.check else ""))
PY

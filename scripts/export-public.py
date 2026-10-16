#!/usr/bin/env python3
"""Export a reviewed, one-way source snapshot without private Git history.

Usage: python3 scripts/export-public.py DEST [--ref HEAD]
DEST must be empty. Only committed files from the explicit allowlist are read.
"""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EXACT = {
    ".gitignore", "README.md", "README_EN.md", "LICENSE", "THIRD-PARTY-NOTICES",
    "project.yml", "build.sh", "keys.json", "icon/AppIcon.png", "icon/AppIcon.icns",
    "scripts/make-icons.py", "scripts/notarize.sh", "scripts/install.sh",
    "scripts/export-public.py",
}
PREFIXES = ("App/", "Shared/", "Extension/", "Tests/", "scripts/accept/", "docs/media/")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("destination", type=Path)
    ap.add_argument("--ref", default="HEAD")
    args = ap.parse_args()
    destination = args.destination.expanduser().resolve()
    if destination == ROOT or ROOT in destination.parents:
        ap.error("Export outside the development repository.")
    if destination.exists() and any(destination.iterdir()):
        ap.error("Destination must be empty; no files were replaced.")
    revision = git("rev-parse", "--verify", args.ref + "^{commit}").decode().strip()
    names = git("ls-tree", "-r", "--name-only", revision).decode().splitlines()
    selected = [n for n in names if n in EXACT or n.startswith(PREFIXES)]
    if not EXACT.issubset(selected):
        ap.error("Required public files are missing from the committed revision.")
    destination.mkdir(parents=True, exist_ok=True)
    for name in selected:
        content = git("show", f"{revision}:{name}")
        if name in ("build.sh", "scripts/accept/native_ui.sh"):
            content = content.replace(b"${PYTHON:-$HOME/Dev/.venv/bin/python}", b"${PYTHON:-python3}")
        if name == "project.yml":
            content = content.replace(b"DEVELOPMENT_TEAM: B9LJH93LA4", b'DEVELOPMENT_TEAM: ""')
        if name == "build.sh":
            content = content.replace(b"-quiet build", b'${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} -quiet build')
            # The development-only Chapter receipt adapter is outside the public allowlist.
            content = b"\n".join(line for line in content.split(b"\n") if b'exec "${PYTHON:-python3}" scripts/build-candidate.py' not in line)
        if name == "README.md":
            content = "\n".join(line for line in content.decode().split("\n") if not line.startswith('- `bash build.sh --candidate`')).encode()
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    print(f"Exported {len(selected)} committed files from {revision} to {destination}")


if __name__ == "__main__":
    main()

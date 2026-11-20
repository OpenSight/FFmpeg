#!/usr/bin/env python3
"""Verify locked FFmpeg, x264 and x265 source inputs.

The lock file is the single source of truth for the source bytes used by both
the Podman build entry point and the RPM build (``%prep``).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
import sys

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class LockError(Exception):
    pass


def load_lock(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LockError(f"cannot read source lock {path}: {exc}") from exc
    if data.get("schema_version") != 1:
        raise LockError(f"unsupported source lock schema in {path}")
    sources = data.get("sources")
    if not isinstance(sources, dict) or not sources:
        raise LockError(f"source lock {path} has no sources")
    return sources


def source_path(source_dir: Path, name: str, entry: dict) -> Path:
    filename = entry.get("file")
    if not isinstance(filename, str) or not filename:
        raise LockError(f"source {name} has no file name")
    if filename != Path(filename).name or filename in {".", ".."}:
        raise LockError(f"source {name} has an unsafe file name: {filename!r}")
    return source_dir / filename


def verify_one(source_dir: Path, name: str, entry: dict) -> str:
    expected_sha = entry.get("sha256")
    expected_size = entry.get("size_bytes")
    if not isinstance(expected_sha, str) or not SHA256_RE.fullmatch(expected_sha):
        raise LockError(f"source {name} has an invalid sha256")
    if not isinstance(expected_size, int) or expected_size <= 0:
        raise LockError(f"source {name} has an invalid size_bytes")
    path = source_path(source_dir, name, entry)
    if not path.is_file():
        raise LockError(f"source {name} is missing: {path}")
    actual_size = path.stat().st_size
    if actual_size != expected_size:
        raise LockError(
            f"source {name} size mismatch: expected {expected_size}, got {actual_size}"
        )
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    actual_sha = digest.hexdigest()
    if actual_sha != expected_sha:
        raise LockError(
            f"source {name} sha256 mismatch: expected {expected_sha}, got {actual_sha}"
        )
    return f"verified {name}: {path.name} sha256={actual_sha} size={actual_size}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument(
        "--name",
        action="append",
        dest="names",
        help="verify only this source (repeatable; default: all sources)",
    )
    parser.add_argument(
        "--print-files",
        action="store_true",
        help="print the locked file names instead of verifying",
    )
    args = parser.parse_args(argv)

    try:
        sources = load_lock(args.lock)
        names = args.names or list(sources)
        unknown = sorted(set(names) - set(sources))
        if unknown:
            raise LockError(f"source lock has no entry for: {', '.join(unknown)}")
        if args.print_files:
            for name in names:
                print(source_path(args.source_dir, name, sources[name]).name)
            return 0
        for name in names:
            print(verify_one(args.source_dir, name, sources[name]))
    except LockError as exc:
        print(f"source verification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

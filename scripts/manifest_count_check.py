#!/usr/bin/env python3
"""Manifest structural count truth check.

The payload manifest at <root>/.payload.manifest has two structurally
distinct sections:

  * Header lines (starting with "# " or empty)
  * File entries of the form `sha256  <hex64>  <relpath>`

The install-time generator also records the discovered file count in a
`# file_count=<N>` header line.

This module reads the manifest and the live active payload boundary and
reports three authoritative counts. It then asserts:

    PAYLOAD_MANIFEST_FILE_ENTRIES == INSTALLED_ACTIVE_FILES

so a manifest with a missing/extra entry, or a manifest truncated by
install.sh, fails closed instead of masquerading as PASS via the legacy
header-only check.

Used by validate.sh --installed as the structural manifest truth gate.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import re
import sys


DISPOSABLE_GLOBS = (
    "*/__pycache__/*",
    "*.pyc",
    "*.pyo",
    "*.pyd",
    "./.payload.manifest",
    "./.payload.manifest.tmp",
)
USER_STATE_GLOBS = (
    "./logs/*",
    "./.git/*",
    "./.ownframework-loop/*",
)


def _is_disposable(rel: str) -> bool:
    return any(fnmatch.fnmatch(rel, pat) for pat in DISPOSABLE_GLOBS)


def _is_user_state(rel: str) -> bool:
    return any(fnmatch.fnmatch(rel, pat) for pat in USER_STATE_GLOBS)


def _walk_active_payload(root: str) -> list[str]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_prefix = "./"
        else:
            rel_prefix = "./" + rel_dir.replace(os.sep, "/") + "/"
        skip = False
        for pat in USER_STATE_GLOBS:
            if fnmatch.fnmatch(rel_prefix, pat):
                skip = True
                break
        if skip:
            dirnames[:] = []
            continue
        for fn in filenames:
            rel = rel_prefix + fn
            if _is_disposable(rel):
                continue
            out.append(rel)
    return sorted(out)


_FILE_ENTRY_RE = re.compile(r"^sha256\s+([0-9a-f]{64})\s+(\S.*)$")
_HEADER_COUNT_RE = re.compile(r"^#\s*file_count\s*=\s*(\d+)\s*$")


def parse_manifest(manifest_path: str) -> tuple[int, int, int]:
    """Return (header_lines, file_entries, declared_file_count)."""
    if not os.path.isfile(manifest_path):
        print(f"  FAIL: payload manifest missing at {manifest_path}")
        return 0, 0, -1
    header_lines = 0
    file_entries = 0
    declared = -1
    for raw in open(manifest_path, encoding="utf-8").read().splitlines():
        if raw == "" or raw.startswith("# "):
            header_lines += 1
            m = _HEADER_COUNT_RE.match(raw)
            if m:
                declared = int(m.group(1))
            continue
        if _FILE_ENTRY_RE.match(raw):
            file_entries += 1
    return header_lines, file_entries, declared


def check(root: str, manifest: str) -> int:
    header_lines, file_entries, declared = parse_manifest(manifest)
    if header_lines == 0 and file_entries == 0:
        return 1
    active = _walk_active_payload(root)
    active_count = len(active)

    # Report authoritative counts (printed for human and machine).
    print(f"  PAYLOAD_MANIFEST_HEADER_LINES={header_lines}")
    print(f"  PAYLOAD_MANIFEST_FILE_ENTRIES={file_entries}")
    print(f"  INSTALLED_ACTIVE_FILES={active_count}")
    if declared >= 0:
        print(f"  PAYLOAD_MANIFEST_DECLARED_COUNT={declared}")

    failures = []
    if file_entries != active_count:
        failures.append(
            f"manifest file entry count {file_entries} != installed active file count {active_count}"
        )
    if declared >= 0 and declared != file_entries:
        failures.append(
            f"declared file_count header {declared} != actual file entries {file_entries}"
        )
    if failures:
        for f in failures:
            print(f"  FAIL: {f}")
        return 1
    print(f"  PASS: manifest count truth (file entries == active files == {file_entries})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--manifest", required=True)
    args = ap.parse_args()
    return check(args.root, args.manifest)


if __name__ == "__main__":
    sys.exit(main())

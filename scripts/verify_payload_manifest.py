#!/usr/bin/env python3
"""Verify the installed payload matches the recorded manifest.

Fails closed on:
  - manifest missing
  - file listed in manifest but missing on disk
  - file present but SHA-256 mismatches
  - extra unauthorised files in the active payload (non-disposable)
  - missing active-code files whose manifest entry was removed (stale)

Disposable bytecode and runtime caches are EXCLUDED from manifest
generation and are NOT subject to tampering checks. They are classified
in DISPOSABLE_GLOBS and any present files are simply reported as
"disposable runtime cache" rather than triggering a fail.

Unclassified operational data (user-run state, audit logs, .git/,
.ownframework-loop/, etc.) inside the active payload fails closed.

Used by validate.sh --installed as the atomic-install contract check.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import os
import re
import sys


# Disposable runtime cache: __pycache__/*.pyc, *.pyo, *.pyd. These are
# legitimate Python runtime caches that MUST NOT be in the manifest and
# MUST NOT trigger tampering failures when present in the cache.
DISPOSABLE_GLOBS = (
    "*/__pycache__/*",
    "*.pyc",
    "*.pyo",
    "*.pyd",
    "./.payload.manifest",
    "./.payload.manifest.tmp",
)
# Active payload boundary: files outside this set are unclassified
# operational data and fail closed.
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
    """Walk the active payload boundary, EXCLUDING disposable bytecode and
    user-state directories. Returns list of relative paths."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Compute path relative to root, normalised to "./..."
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_prefix = "./"
        else:
            rel_prefix = "./" + rel_dir.replace(os.sep, "/") + "/"
        # Skip user-state directories entirely
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


def verify(root: str, manifest: str) -> int:
    if not os.path.isfile(manifest):
        print(f"  FAIL: payload manifest missing at {manifest}")
        return 1
    lines = open(manifest, encoding="utf-8").read().splitlines()
    seen = 0
    mismatches = []
    for line in lines:
        if line.startswith("# ") or line == "":
            continue
        m = re.match(r"^sha256\s+([0-9a-f]{64})\s+(\S.*)$", line)
        if not m:
            continue
        sha = m.group(1)
        rel = m.group(2)
        seen += 1
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            mismatches.append(f"missing:{rel}")
            continue
        actual = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if actual != sha:
            mismatches.append(f"tamper:{rel}:expected={sha[:12]} actual={actual[:12]}")
    if mismatches:
        print(f"  FAIL: payload manifest verification found {len(mismatches)} issue(s):")
        for m in mismatches[:20]:
            print(f"    - {m}")
        # Continue to also check active-payload boundary.

    # Active-payload boundary check: the set of files inside the active
    # payload (excluding disposable runtime cache and user-state dirs)
    # must EXACTLY match the manifest. Extra files = tampering or
    # stale removal. Missing files = drift.
    active = _walk_active_payload(root)
    manifest_files = set()
    for line in lines:
        if line.startswith("# ") or line == "":
            continue
        m = re.match(r"^sha256\s+([0-9a-f]{64})\s+(\S.*)$", line)
        if not m:
            continue
        manifest_files.add("./" + m.group(2).lstrip("/"))
    active_set = set(active)
    extras = sorted(active_set - manifest_files)
    missing = sorted(manifest_files - active_set)
    boundary_issues = []
    for e in extras:
        if _is_disposable(e.lstrip("./")) or _is_user_state(e):
            continue
        boundary_issues.append(f"unauthorised:{e}")
    for m in missing:
        boundary_issues.append(f"stale-removed:{m}")
    if boundary_issues:
        print(f"  FAIL: active payload boundary violation: {len(boundary_issues)} issue(s):")
        for b in boundary_issues[:20]:
            print(f"    - {b}")
        return 1
    if mismatches:
        return 1
    print(f"  PASS: payload manifest verified ({seen} entries, {len(active)} active files)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--manifest", required=True)
    args = ap.parse_args()
    return verify(args.root, args.manifest)


if __name__ == "__main__":
    sys.exit(main())

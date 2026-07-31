#!/usr/bin/env python3
"""Verify the installed payload matches the recorded manifest.

Fails closed on:
  - manifest missing
  - file listed in manifest but missing on disk
  - file present but SHA-256 mismatches

Used by validate.sh --installed as the atomic-install contract check.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys


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
        return 1
    print(f"  PASS: payload manifest verified ({seen} entries)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--manifest", required=True)
    args = ap.parse_args()
    return verify(args.root, args.manifest)


if __name__ == "__main__":
    sys.exit(main())

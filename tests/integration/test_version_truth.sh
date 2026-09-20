#!/usr/bin/env bash
# OwnFramework Loop — version-truth gate (fail-closed).
# Derives the expected source version from lib/ownframework_loop/__init__.py
# (canonical source-version authority) and asserts every source mirror agrees.
# Publication is a separate authority: immutable Git tag + GitHub Release.
# This static test intentionally does not infer live publication state from a
# final source version and does not call GitHub or consume a release-state knob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export ROOT

python3 -B <<'PYEOF'
import json, os, re, sys
ROOT = os.environ["ROOT"]

try:
    lib_text = open(os.path.join(ROOT, "lib/ownframework_loop/__init__.py")).read()
    m = re.search(r'^__version__\s*=\s*["\']([^"\']+)', lib_text, re.MULTILINE)
    EXPECTED = m.group(1) if m else ""
except Exception:
    EXPECTED = ""
if not EXPECTED:
    print("  FAIL: could not derive EXPECTED from lib/ownframework_loop/__init__.py")
    sys.exit(1)

FROZEN_RELEASE_TAG = "v0.9.1"
FROZEN_RELEASE_SHA = "d23cadca751c9ed37b5eeab25415c8b0574dae4e"
PUBLICATION_AUTHORITY_TEXT = (
    "Publication authority is the immutable Git tag together with its corresponding GitHub Release."
)

failures = []

def check(label, ok, detail=""):
    if ok:
        print(f"  PASS: {label} {detail}".rstrip())
    else:
        msg = f"  FAIL: {label} {detail}".rstrip()
        print(msg)
        failures.append(msg)

def normalized(text):
    return " ".join(text.split())

# 1. plugin.json
try:
    with open(os.path.join(ROOT, ".claude-plugin/plugin.json")) as f:
        plugin_data = json.load(f)
    plugin_ver = plugin_data.get("version", "")
    check("plugin.json version", plugin_ver == EXPECTED, f"= {plugin_ver!r}, expected {EXPECTED!r}")
except Exception as e:
    check("plugin.json readable", False, f"({e})")
    plugin_ver = ""

# 2. marketplace.json
try:
    with open(os.path.join(ROOT, ".claude-plugin/marketplace.json")) as f:
        mkt_data = json.load(f)
    mkt_ver = mkt_data.get("plugins", [{}])[0].get("version", "")
    check("marketplace.json plugin version", mkt_ver == EXPECTED, f"= {mkt_ver!r}, expected {EXPECTED!r}")
except Exception as e:
    check("marketplace.json readable", False, f"({e})")
    mkt_ver = ""

# 3. lib/__init__.py
try:
    text = open(os.path.join(ROOT, "lib/ownframework_loop/__init__.py")).read()
    m = re.search(r'^__version__\s*=\s*["\']([^"\']+)', text, re.MULTILINE)
    lib_ver = m.group(1) if m else ""
    check("lib __version__", lib_ver == EXPECTED, f"= {lib_ver!r}, expected {EXPECTED!r}")
except Exception as e:
    check("lib __init__.py readable", False, f"({e})")
    lib_ver = ""

# 4. README.md
try:
    text = open(os.path.join(ROOT, "README.md")).read()
    flat = normalized(text)
    m = re.search(r"Source/master release line:\s*\*\*([0-9]+\.[0-9]+\.[0-9]+(?:\.dev\d+)?)\*\*", text)
    readme_ver = m.group(1) if m else ""
    check("README source/master release line", readme_ver == EXPECTED, f"= {readme_ver!r}, expected {EXPECTED!r}")
    check("README publication authority", PUBLICATION_AUTHORITY_TEXT in flat)
    check(
        "README frozen historical release reference",
        FROZEN_RELEASE_TAG in text and FROZEN_RELEASE_SHA in text,
        f"(must retain {FROZEN_RELEASE_TAG} @ {FROZEN_RELEASE_SHA})",
    )
    check(
        "README workspace concurrency truth",
        "Current concurrency is workspace-scoped" in text
        and "execution ownership is that" in text
        and "run-frozen candidate branch" in text
        and "may run concurrently" in text,
    )
except Exception as e:
    check("README readable", False, f"({e})")
    readme_ver = ""

# 5. SECURITY.md
try:
    text = open(os.path.join(ROOT, "SECURITY.md")).read()
    flat = normalized(text)
    m = re.search(r"source/master supported line in this repository is\s*\*\*([0-9]+\.[0-9]+\.[0-9]+(?:\.dev\d+)?)\*\*", text)
    sec_ver = m.group(1) if m else ""
    check("SECURITY source/master supported line", sec_ver == EXPECTED, f"= {sec_ver!r}, expected {EXPECTED!r}")
    check("SECURITY publication authority", PUBLICATION_AUTHORITY_TEXT in flat)
    check(
        "SECURITY frozen historical release reference",
        FROZEN_RELEASE_TAG in text and FROZEN_RELEASE_SHA in text,
        f"(must retain {FROZEN_RELEASE_TAG} @ {FROZEN_RELEASE_SHA})",
    )
except Exception as e:
    check("SECURITY readable", False, f"({e})")
    sec_ver = ""

# Current workspace-doctrine/template truth.
try:
    arch = open(os.path.join(ROOT, "docs/ARCHITECTURE.md")).read()
    model = open(os.path.join(ROOT, "docs/architecture/SUPERVISOR_MODEL.md")).read()
    template = open(os.path.join(ROOT, "templates/WORK_PACKET.md")).read()
    check("ARCHITECTURE workspace concurrency", "Repository identity is the resolved Git common directory" in arch and "Distinct workspaces in one repository" in arch)
    check("SUPERVISOR_MODEL bounded workspace concurrency", "configurable bounded host concurrency" in model and "repository-wide\nmutex" in model)
    check("WORK_PACKET default candidate branch valid-by-omission", '"candidate_branch_prefix": "factory/candidate/"' not in template)
except Exception as e:
    check("current doctrine surfaces readable", False, f"({e})")

# 6. CHANGELOG.md (most recent entry must equal EXPECTED; historical publication
# reference remains a frozen audit fact, not a claim about live latest-release state).
try:
    text = open(os.path.join(ROOT, "CHANGELOG.md")).read()
    flat = normalized(text)
    m = re.search(r"^## ([0-9]+\.[0-9]+\.[0-9]+(?:\.dev\d+)?)\s+[—\-]", text, re.MULTILINE)
    cl_ver = m.group(1) if m else ""
    check("CHANGELOG most recent entry", cl_ver == EXPECTED, f"= {cl_ver!r}, expected {EXPECTED!r}")
    check("CHANGELOG publication authority", PUBLICATION_AUTHORITY_TEXT in flat)
    check(
        "CHANGELOG frozen historical release reference",
        FROZEN_RELEASE_TAG in text and FROZEN_RELEASE_SHA in text,
        f"(must retain {FROZEN_RELEASE_TAG} @ {FROZEN_RELEASE_SHA})",
    )
except Exception as e:
    check("CHANGELOG readable", False, f"({e})")
    cl_ver = ""

print()
if failures:
    print(f"  VERSION_TRUTH=FAIL ({len(failures)} mismatch(es))")
    sys.exit(1)
print(
    "  VERSION_TRUTH=PASS "
    f"(source line = {EXPECTED}; publication authority = immutable Git tag + GitHub Release; "
    f"historical release = {FROZEN_RELEASE_TAG} @ {FROZEN_RELEASE_SHA})"
)
PYEOF

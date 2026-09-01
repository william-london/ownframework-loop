#!/usr/bin/env bash
# OwnFramework Loop — version-truth gate (fail-closed).
# v0.4.2: derives the expected version from lib/ownframework_loop/__init__.py
# (canonical single source of truth) and asserts every other release surface
# matches. Future patches only need to update lib + the matching JSON/Markdown
# files; this test follows automatically.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export ROOT

python3 -B <<'PYEOF'
import json, os, re, sys
ROOT = os.environ["ROOT"]

# Derive EXPECTED from the canonical lib version. Fall back to a string
# match if the regex misses (so a test-time lib bug doesn't silently
# compare against empty).
try:
    lib_text = open(os.path.join(ROOT, "lib/ownframework_loop/__init__.py")).read()
    m = re.search(r'^__version__\s*=\s*["\']([^"\']+)', lib_text, re.MULTILINE)
    EXPECTED = m.group(1) if m else ""
except Exception:
    EXPECTED = ""
if not EXPECTED:
    print("  FAIL: could not derive EXPECTED from lib/ownframework_loop/__init__.py")
    sys.exit(1)
failures = []

def check(label, ok, detail=""):
    if ok:
        print(f"  PASS: {label} {detail}".rstrip())
    else:
        msg = f"  FAIL: {label} {detail}".rstrip()
        print(msg)
        failures.append(msg)

# 1. plugin.json
try:
    with open(os.path.join(ROOT, ".claude-plugin/plugin.json")) as f:
        plugin_data = json.load(f)
    plugin_ver = plugin_data.get("version", "")
    check("plugin.json version", plugin_ver == EXPECTED, f"= {plugin_ver!r}, expected {EXPECTED!r}")
except Exception as e:
    check("plugin.json readable", False, f"({e})")
    plugin_ver = ""

# 2. marketplace.json (from ROOT, not parent)
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
    m = re.search(r"Source/master release line:\s*\*\*([0-9]+\.[0-9]+\.[0-9]+)\*\*", text)
    readme_ver = m.group(1) if m else ""
    check("README source/master release line", readme_ver == EXPECTED, f"= {readme_ver!r}, expected {EXPECTED!r}")
    check("README published release truth", "Latest published GitHub Release: **v0.8.4**" in text and "134a7ce543e2d5858b3a4613c49d49959fe0b029" in text)
    check("README workspace concurrency truth", "execution ownership is that" in text and "run-frozen candidate branch" in text and "may run concurrently" in text)
except Exception as e:
    check("README readable", False, f"({e})")
    readme_ver = ""

# 5. SECURITY.md
try:
    text = open(os.path.join(ROOT, "SECURITY.md")).read()
    m = re.search(r"source/master supported line in this repository is\s*\*\*([0-9]+\.[0-9]+\.[0-9]+)\*\*", text)
    sec_ver = m.group(1) if m else ""
    check("SECURITY source/master supported line", sec_ver == EXPECTED, f"= {sec_ver!r}, expected {EXPECTED!r}")
    check("SECURITY published release truth", "latest published GitHub Release is **v0.8.4**" in text and "134a7ce543e2d5858b3a4613c49d49959fe0b029" in text)
except Exception as e:
    check("SECURITY readable", False, f"({e})")
    sec_ver = ""

# Current v0.9.1 doctrine/template truth.
try:
    arch = open(os.path.join(ROOT, "docs/ARCHITECTURE.md")).read()
    model = open(os.path.join(ROOT, "docs/architecture/SUPERVISOR_MODEL.md")).read()
    template = open(os.path.join(ROOT, "templates/WORK_PACKET.md")).read()
    check("ARCHITECTURE workspace concurrency", "Repository identity is the resolved Git common directory" in arch and "Distinct workspaces in one repository" in arch)
    check("SUPERVISOR_MODEL bounded workspace concurrency", "configurable bounded host concurrency" in model and "repository-wide\nmutex" in model)
    check("WORK_PACKET default candidate branch valid-by-omission", '"candidate_branch_prefix": "factory/candidate/"' not in template)
except Exception as e:
    check("current v0.9.1 doctrine surfaces readable", False, f"({e})")

# 6. CHANGELOG.md (most recent entry must equal EXPECTED)
try:
    text = open(os.path.join(ROOT, "CHANGELOG.md")).read()
    m = re.search(r"^## ([0-9]+\.[0-9]+\.[0-9]+)\s+[—\-]", text, re.MULTILINE)
    cl_ver = m.group(1) if m else ""
    check("CHANGELOG most recent entry", cl_ver == EXPECTED, f"= {cl_ver!r}, expected {EXPECTED!r}")
except Exception as e:
    check("CHANGELOG readable", False, f"({e})")
    cl_ver = ""

print()
if failures:
    print(f"  VERSION_TRUTH=FAIL ({len(failures)} mismatch(es))")
    sys.exit(1)
print(f"  VERSION_TRUTH=PASS (source line = {EXPECTED}; published release = v0.8.4; v0.9.1 workspace doctrine current)")
PYEOF

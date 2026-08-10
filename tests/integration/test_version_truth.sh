#!/usr/bin/env bash
# OwnFramework Loop — version-truth gate (fail-closed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export ROOT

python3 -B <<'PYEOF'
import json, os, re, sys
ROOT = os.environ["ROOT"]
EXPECTED = "0.3.8"
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
    m = re.search(r"Current release line:\s*\*\*([0-9]+\.[0-9]+\.[0-9]+)\*\*", text)
    readme_ver = m.group(1) if m else ""
    check("README current release line", readme_ver == EXPECTED, f"= {readme_ver!r}, expected {EXPECTED!r}")
except Exception as e:
    check("README readable", False, f"({e})")
    readme_ver = ""

# 5. SECURITY.md
try:
    text = open(os.path.join(ROOT, "SECURITY.md")).read()
    m = re.search(r"supported release line is\s*\*\*([0-9]+\.[0-9]+\.[0-9]+)\*\*", text)
    sec_ver = m.group(1) if m else ""
    check("SECURITY supported release line", sec_ver == EXPECTED, f"= {sec_ver!r}, expected {EXPECTED!r}")
except Exception as e:
    check("SECURITY readable", False, f"({e})")
    sec_ver = ""

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
print(f"  VERSION_TRUTH=PASS (all 6 surfaces = {EXPECTED})")
PYEOF

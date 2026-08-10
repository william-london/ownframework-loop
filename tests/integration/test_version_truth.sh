#!/usr/bin/env bash
# OwnFramework Loop — version-truth gate.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export ROOT

python3 <<'PYEOF'
import json, os, re, sys
ROOT = os.environ["ROOT"]
PLUGIN_JSON = os.path.join(ROOT, ".claude-plugin/plugin.json")
MKT_JSON = os.path.join(os.path.dirname(ROOT), ".claude-plugin/marketplace.json")
INIT_PY = os.path.join(ROOT, "lib/ownframework_loop/__init__.py")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")

try:
    plugin_ver = json.load(open(PLUGIN_JSON))["version"]
    print(f"OK: plugin.json version = {plugin_ver}")
except Exception as e:
    print(f"FAIL: plugin.json read: {e}")
    sys.exit(1)

try:
    mkt_ver = json.load(open(MKT_JSON))["plugins"][0]["version"]
    if mkt_ver == plugin_ver:
        print(f"OK: marketplace.json version = {mkt_ver} (matches)")
    else:
        print(f"FAIL: marketplace.json version = {mkt_ver} (mismatch)")
except Exception as e:
    print(f"FAIL: marketplace.json read: {e}")

try:
    text = open(INIT_PY).read()
    m = re.search(r'__version__\s*=\s*["\']([^"\']+)', text)
    lib_ver = m.group(1) if m else None
    if lib_ver == plugin_ver:
        print(f"OK: __init__.py __version__ = {lib_ver} (matches)")
    else:
        print(f"FAIL: __init__.py __version__ = {lib_ver} (mismatch)")
except Exception as e:
    print(f"FAIL: __init__.py read: {e}")

# Version must be >= 0.3.0
maj, mn = (int(x) for x in plugin_ver.split(".")[:2])
if maj > 0 or (maj == 0 and mn >= 3):
    print(f"OK: version {plugin_ver} >= 0.3.0")
else:
    print(f"FAIL: version {plugin_ver} < 0.3.0")

# CHANGELOG must contain v<version> entry
if re.search(rf"^## {re.escape(plugin_ver)}\b", open(CHANGELOG).read(), re.MULTILINE):
    print(f"OK: CHANGELOG contains {plugin_ver} entry")
else:
    print(f"FAIL: CHANGELOG missing {plugin_ver} entry")
PYEOF

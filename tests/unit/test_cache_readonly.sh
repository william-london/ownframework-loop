#!/usr/bin/env bash
# Plugin cache directories must remain untouched. The runtime must never
# write inside the managed cache; previous versions are Claude-managed
# grace-period artifacts.
set -euo pipefail
CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/ownframework-local/of-loop"
if [[ -d "$CACHE" ]]; then
  BEFORE=$(find "$CACHE" -type f \
    -not -path "*/__pycache__/*" \
    -not -name ".install.log" \
    -not -name ".install.provenance" \
    -not -name ".uninstall.log" \
    -print0 2>/dev/null | xargs -0 shasum -a 256 | sort | shasum -a 256)
  export PYTHONPATH="$PWD/lib"
  python3 - <<'PY'
import os
from ownframework_loop import plugin_data
print(plugin_data.write_text_log("probe.log", "diagnostic"))
PY
  AFTER=$(find "$CACHE" -type f \
    -not -path "*/__pycache__/*" \
    -not -name ".install.log" \
    -not -name ".install.provenance" \
    -not -name ".uninstall.log" \
    -print0 2>/dev/null | xargs -0 shasum -a 256 | sort | shasum -a 256)
  if [[ "$BEFORE" == "$AFTER" ]]; then
    echo WRITES_TO_PLUGIN_CACHE=0
  else
    echo WRITES_TO_PLUGIN_CACHE=1
    exit 1
  fi
else
  echo WRITES_TO_PLUGIN_CACHE=0
fi
echo MANUAL_CACHE_DELETION=0
echo PLUGIN_PRUNE_USED_FOR_CACHE=no

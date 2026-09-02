#!/usr/bin/env bash
# v0.8.5 distribution parity: source↔installed bytes + immutable adapter source.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d -t ofloop-v085-dist-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
fail(){ echo "FAIL: $*" >&2; exit 1; }

A="$TMP/source-a"; B="$TMP/source-b"
python3 -B - "$ROOT_DIR" "$A" "$B" <<'PY'
import shutil,sys
from pathlib import Path
root,a,b=map(Path,sys.argv[1:])
ignore=shutil.ignore_patterns(".git","__pycache__",".ownframework-loop","logs","*.pyc")
shutil.copytree(root,a,ignore=ignore)
shutil.copytree(root,b,ignore=ignore)
with (b/"adapters"/"README.md").open("a",encoding="utf-8") as fh:
    fh.write("\nparity-differential-fixture\n")
PY
export HOME="$TMP/parity-home"
export XDG_DATA_HOME="$TMP/parity-data"
export XDG_STATE_HOME="$TMP/parity-state"
export OFLOOP_BIN_DIR="$TMP/parity-bin"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$OFLOOP_BIN_DIR"
OUT="$(bash "$A/install.sh")"
INSTALLED="$(sed -n 's/^CORE_ROOT=//p' <<<"$OUT" | tail -n1)"
bash "$A/validate.sh" --installed "$INSTALLED" --skip-tests >/dev/null
PYTHONPATH="$A/lib" python3 -B - "$A" "$B" "$INSTALLED" <<'PY'
import sys
from pathlib import Path
from ownframework_loop.release_gate_runtime import _installed_parity_status
a,b,installed=map(Path,sys.argv[1:])
same=_installed_parity_status(a,installed)
different=_installed_parity_status(b,installed)
assert same["status"]=="PASS", same
assert same["source_digest"]==same["installed_digest"], same
assert different["status"]=="MISMATCH", different
assert different["source_version"]==different["installed_version"], different
assert different["source_digest"]!=different["installed_digest"], different
PY

# Dirty Git checkout: managed core comes from immutable HEAD, and Claude adapter
# registration must use that CORE_ROOT rather than dirty checkout bytes.
SRC="$TMP/dirty-git"
git clone -q "$ROOT_DIR" "$SRC"
python3 -B - "$SRC/.claude-plugin/plugin.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding="utf-8"))
d["version"]="999.0.0"
open(p,"w",encoding="utf-8").write(json.dumps(d,indent=2)+"\n")
PY
DIRTY_HOME="$TMP/dirty-home"; DIRTY_DATA="$TMP/dirty-data"; DIRTY_STATE="$TMP/dirty-state"; DIRTY_BIN="$TMP/dirty-bin"; FAKE="$TMP/fake"
mkdir -p "$DIRTY_HOME" "$DIRTY_DATA" "$DIRTY_STATE" "$DIRTY_BIN" "$FAKE"
CLAUDE_LOG="$TMP/claude.log"; export CLAUDE_LOG
cat > "$FAKE/claude" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_LOG"
if [[ "${1:-} ${2:-}" == "plugin list" ]]; then
  echo "of-loop@ownframework"
fi
exit 0
SH
chmod +x "$FAKE/claude"
ADAPTER_OUT="$(HOME="$DIRTY_HOME" XDG_DATA_HOME="$DIRTY_DATA" XDG_STATE_HOME="$DIRTY_STATE" OFLOOP_BIN_DIR="$DIRTY_BIN" PATH="$FAKE:$PATH" bash "$SRC/bin/install-adapter" claude-code)"
grep -F 'ADAPTER_INSTALL=PASS' <<<"$ADAPTER_OUT" >/dev/null || fail "dirty-source Claude adapter did not install: $ADAPTER_OUT"
CORE_ROOT="$(sed -n 's/^CORE_ROOT=//p' <<<"$ADAPTER_OUT" | tail -n1)"
grep -F "ADAPTER_SOURCE_ROOT=$CORE_ROOT" <<<"$ADAPTER_OUT" >/dev/null || fail "adapter source root not reported as managed core"
grep -F "plugin marketplace add $CORE_ROOT" "$CLAUDE_LOG" >/dev/null || fail "Claude marketplace was not registered from CORE_ROOT"
if grep -F "plugin marketplace add $SRC" "$CLAUDE_LOG" >/dev/null; then
  fail "dirty checkout was used as Claude marketplace source"
fi
MANAGED_PLUGIN_VERSION="$(python3 -B - "$CORE_ROOT/.claude-plugin/plugin.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["version"])
PY
)"
[[ "$MANAGED_PLUGIN_VERSION" != "999.0.0" ]] || fail "dirty plugin bytes leaked into managed core"

echo "V085_DISTRIBUTION_PARITY=PASS"

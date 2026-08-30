#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d -t ofloop-codex-install-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/data"
export OFLOOP_BIN_DIR="$TMP/bin"
export OFLOOP_AGENT_SKILLS_DIR="$TMP/skills"
export XDG_STATE_HOME="$TMP/state"
mkdir -p "$HOME" "$OFLOOP_BIN_DIR" "$OFLOOP_AGENT_SKILLS_DIR" "$XDG_STATE_HOME"

bash install-adapter.sh codex | tee "$TMP/install.txt"
grep -F 'ADAPTER_INSTALL=PASS' "$TMP/install.txt" >/dev/null
grep -F 'ADAPTER=codex' "$TMP/install.txt" >/dev/null
EXPECTED_VERSION="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -c "import sys; sys.path.insert(0, '$ROOT/lib'); from ownframework_loop import __version__; print(__version__)")"
grep -F "VERSION=$EXPECTED_VERSION" "$TMP/install.txt" >/dev/null

test -x "$OFLOOP_BIN_DIR/ofloop"
"$OFLOOP_BIN_DIR/ofloop" adapter show codex | tee "$TMP/adapter.json"
grep -F '"maturity": "experimental"' "$TMP/adapter.json" >/dev/null
grep -F '"live_verified": false' "$TMP/adapter.json" >/dev/null

for skill in of-loop-spec of-loop-build of-loop-review of-loop-status; do
  test -f "$OFLOOP_AGENT_SKILLS_DIR/$skill/SKILL.md"
  marker="$OFLOOP_AGENT_SKILLS_DIR/$skill/.ownframework-loop-managed"
  test -f "$marker"
  grep -F 'adapter=codex' "$marker" >/dev/null
  grep -F "managed_object=agent-skill:$skill" "$marker" >/dev/null
done

bash install-adapter.sh codex >/dev/null

bash uninstall-adapter.sh codex >/dev/null
mkdir -p "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec"
printf 'user-owned\n' > "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec/SKILL.md"
if bash install-adapter.sh codex >"$TMP/conflict.txt" 2>&1; then
  echo 'FAIL: installer replaced unmanaged Agent Skill' >&2
  exit 1
fi
grep -F 'reason=unmanaged_agent_skill' "$TMP/conflict.txt" >/dev/null
grep -F 'user-owned' "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec/SKILL.md" >/dev/null
rm -rf "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec"

CORE_ROOT_EARLY="$(sed -n 's/^CORE_ROOT=//p' "$TMP/install.txt" | tail -n1)"
check_bad_marker() {
  local label="$1" marker_body="$2"
  local dest="$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec"
  rm -rf "$dest"
  mkdir -p "$dest"
  printf 'user-owned-%s\n' "$label" > "$dest/SKILL.md"
  printf '%s' "$marker_body" > "$dest/.ownframework-loop-managed"
  if bash uninstall-adapter.sh codex >"$TMP/bad-marker-$label.txt" 2>&1; then
    echo "FAIL: $label marker authorized destructive Codex uninstall" >&2
    exit 1
  fi
  grep -F 'reason=unmanaged_agent_skill' "$TMP/bad-marker-$label.txt" >/dev/null
  grep -F "user-owned-$label" "$dest/SKILL.md" >/dev/null
  rm -rf "$dest"
}
check_bad_marker empty ''
check_bad_marker wrong-adapter $'adapter=claude-code\nmanaged_object=agent-skill:of-loop-spec\n'
check_bad_marker malformed $'adapter=codex\nmanaged_object=not-an-agent-skill\n'
check_bad_marker copied-object $'adapter=codex\nmanaged_object=agent-skill:of-loop-build\n'
check_bad_marker malformed-extra "$(printf 'adapter=codex\nmanaged_object=agent-skill:of-loop-spec\nversion=%s\ncore_root=%s\nBROKEN-LINE\n' "$EXPECTED_VERSION" "$CORE_ROOT_EARLY")"
check_bad_marker duplicate-key "$(printf 'adapter=codex\nadapter=codex\nmanaged_object=agent-skill:of-loop-spec\nversion=%s\ncore_root=%s\n' "$EXPECTED_VERSION" "$CORE_ROOT_EARLY")"

bash install-adapter.sh codex >/dev/null
CORE_ROOT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B - "$OFLOOP_BIN_DIR/ofloop" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False).parent.parent)
PY
)"
test -d "$CORE_ROOT"
bash uninstall-adapter.sh codex | tee "$TMP/uninstall.txt"
grep -F 'ADAPTER_UNINSTALL=PASS' "$TMP/uninstall.txt" >/dev/null
grep -F 'CORE_PRESERVED=yes' "$TMP/uninstall.txt" >/dev/null
test -x "$OFLOOP_BIN_DIR/ofloop"
test -d "$CORE_ROOT"
"$OFLOOP_BIN_DIR/ofloop" adapter show generic-cli >/dev/null
for skill in of-loop-spec of-loop-build of-loop-review of-loop-status; do
  test ! -e "$OFLOOP_AGENT_SKILLS_DIR/$skill"
done

bash uninstall.sh >/dev/null
test ! -e "$OFLOOP_BIN_DIR/ofloop"
test ! -e "$CORE_ROOT"

echo 'CODEX_ADAPTER_INSTALL_TEST=PASS'

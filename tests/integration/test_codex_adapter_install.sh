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
mkdir -p "$HOME" "$OFLOOP_BIN_DIR" "$OFLOOP_AGENT_SKILLS_DIR"

bash install-adapter.sh codex | tee "$TMP/install.txt"
grep -F 'ADAPTER_INSTALL=PASS' "$TMP/install.txt" >/dev/null
grep -F 'ADAPTER=codex' "$TMP/install.txt" >/dev/null
grep -F 'VERSION=0.4.0' "$TMP/install.txt" >/dev/null

test -x "$OFLOOP_BIN_DIR/ofloop"
"$OFLOOP_BIN_DIR/ofloop" adapter show codex | tee "$TMP/adapter.json"
grep -F '"maturity": "experimental"' "$TMP/adapter.json" >/dev/null
grep -F '"live_verified": false' "$TMP/adapter.json" >/dev/null

for skill in of-loop-spec of-loop-build of-loop-review of-loop-status; do
  test -f "$OFLOOP_AGENT_SKILLS_DIR/$skill/SKILL.md"
  test -f "$OFLOOP_AGENT_SKILLS_DIR/$skill/.ownframework-loop-managed"
done

# Reinstall must be idempotent for OwnFramework-managed paths.
bash install-adapter.sh codex >/dev/null

# Unmanaged conflicts must refuse before replacing user content.
bash uninstall-adapter.sh codex >/dev/null
mkdir -p "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec"
printf 'user-owned\n' > "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec/SKILL.md"
if bash install-adapter.sh codex >"$TMP/conflict.txt" 2>&1; then
  echo 'FAIL: installer replaced unmanaged Agent Skill' >&2
  exit 1
fi
grep -F 'refusing to replace unmanaged Agent Skill' "$TMP/conflict.txt" >/dev/null
grep -F 'user-owned' "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec/SKILL.md" >/dev/null
rm -rf "$OFLOOP_AGENT_SKILLS_DIR/of-loop-spec"

# Clean install/uninstall round trip.
bash install-adapter.sh codex >/dev/null
bash uninstall-adapter.sh codex | tee "$TMP/uninstall.txt"
grep -F 'ADAPTER_UNINSTALL=PASS' "$TMP/uninstall.txt" >/dev/null

test ! -e "$OFLOOP_BIN_DIR/ofloop"
for skill in of-loop-spec of-loop-build of-loop-review of-loop-status; do
  test ! -e "$OFLOOP_AGENT_SKILLS_DIR/$skill"
done

echo 'CODEX_ADAPTER_INSTALL_TEST=PASS'

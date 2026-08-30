#!/usr/bin/env bash
# Vendor-neutral core install/discovery/uninstall portability regression.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d -t ofloop-core-install-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/data"
export XDG_STATE_HOME="$TMP/state"
export OFLOOP_BIN_DIR="$TMP/bin"
mkdir -p "$HOME" "$OFLOOP_BIN_DIR" "$XDG_STATE_HOME"

# Core install must not require any agent host.
OUT="$TMP/install.out"
bash "$ROOT_DIR/install.sh" | tee "$OUT"
grep -F 'CORE_INSTALL=PASS' "$OUT" >/dev/null
CORE_ROOT="$(sed -n 's/^CORE_ROOT=//p' "$OUT" | tail -n1)"
VERSION="$(sed -n 's/^VERSION=//p' "$OUT" | tail -n1)"
test -d "$CORE_ROOT"
test -f "$CORE_ROOT/.ownframework-loop-managed"
grep -F 'kind=core' "$CORE_ROOT/.ownframework-loop-managed" >/dev/null
test -f "$CORE_ROOT/.payload.manifest"
test -L "$OFLOOP_BIN_DIR/ofloop"
test "$(python3 -B - "$OFLOOP_BIN_DIR/ofloop" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve(strict=False))
PY
)" = "$CORE_ROOT/bin/ofloop"
"$OFLOOP_BIN_DIR/ofloop" adapter doctor generic-cli | grep -F '"doctor": "PASS"' >/dev/null

# Bare installed validation discovers core through PATH, never a plugin registry.
PATH="$OFLOOP_BIN_DIR:$PATH" bash "$ROOT_DIR/validate.sh" --installed --skip-tests | tee "$TMP/validate.out"
grep -F 'validate (INSTALLED CORE)' "$TMP/validate.out" >/dev/null
grep -F "discovered active core: $CORE_ROOT" "$TMP/validate.out" >/dev/null

# Idempotent reinstall keeps the same versioned core root.
bash "$ROOT_DIR/install.sh" >"$TMP/reinstall.out"
grep -F "CORE_ROOT=$CORE_ROOT" "$TMP/reinstall.out" >/dev/null

# Unmanaged launcher is never replaced.
bash "$ROOT_DIR/uninstall.sh" >/dev/null
mkdir -p "$OFLOOP_BIN_DIR"
printf '#!/bin/sh\necho user-owned\n' > "$OFLOOP_BIN_DIR/ofloop"
chmod +x "$OFLOOP_BIN_DIR/ofloop"
if bash "$ROOT_DIR/install.sh" >"$TMP/conflict.out" 2>&1; then
  echo "FAIL: generic installer replaced unmanaged launcher" >&2
  exit 1
fi
grep -F 'reason=unmanaged_launcher' "$TMP/conflict.out" >/dev/null
grep -F 'user-owned' "$OFLOOP_BIN_DIR/ofloop" >/dev/null
rm -f "$OFLOOP_BIN_DIR/ofloop"

# Source-release install must work without .git metadata.
SRC="$TMP/source-release"
mkdir -p "$SRC"
git -C "$ROOT_DIR" archive HEAD | tar -x -C "$SRC"
export XDG_DATA_HOME="$TMP/release-data"
export OFLOOP_BIN_DIR="$TMP/release-bin"
bash "$SRC/install.sh" | tee "$TMP/release.out"
grep -F 'CORE_INSTALL=PASS' "$TMP/release.out" >/dev/null
grep -F 'SOURCE_KIND=source-tree' "$TMP/release.out" >/dev/null
RELEASE_ROOT="$(sed -n 's/^CORE_ROOT=//p' "$TMP/release.out" | tail -n1)"
test ! -e "$RELEASE_ROOT/.git"
test -f "$RELEASE_ROOT/.payload.manifest"

# Core uninstall preserves durable state and independently-owned adapter data.
mkdir -p "$XDG_STATE_HOME/ownframework-loop"
printf 'evidence\n' > "$XDG_STATE_HOME/ownframework-loop/preserve.txt"
ADAPTER_SENTINEL="$TMP/adapter-sentinel"
printf 'adapter\n' > "$ADAPTER_SENTINEL"
bash "$SRC/uninstall.sh" | tee "$TMP/uninstall.out"
grep -F 'CORE_UNINSTALL=PASS' "$TMP/uninstall.out" >/dev/null
test -f "$XDG_STATE_HOME/ownframework-loop/preserve.txt"
test -f "$ADAPTER_SENTINEL"

echo "CORE_INSTALL_PORTABILITY=PASS"

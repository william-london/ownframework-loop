#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="${1:-}"

if [[ "$ADAPTER" != "codex" ]]; then
  echo "Usage: bash install-adapter.sh codex" >&2
  echo "Claude Code users should continue using: bash install.sh" >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "ERROR: tar is required" >&2; exit 1; }

VERSION="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/lib" python3 - <<'PY'
from ownframework_loop import __version__
print(__version__)
PY
)"

DATA_BASE="${OFLOOP_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ownframework-loop}"
INSTALL_ROOT="$DATA_BASE/$VERSION"
BIN_DIR="${OFLOOP_BIN_DIR:-$HOME/.local/bin}"
SKILLS_ROOT="${OFLOOP_AGENT_SKILLS_DIR:-$HOME/.agents/skills}"
LAUNCHER="$BIN_DIR/ofloop"
ROOT_MARKER="$INSTALL_ROOT/.ownframework-loop-managed"
SKILLS=(of-loop-spec of-loop-build of-loop-review of-loop-status)

# Validate every possible conflict before mutating user state.
if [[ -e "$INSTALL_ROOT" && ! -f "$ROOT_MARKER" ]]; then
  echo "ERROR: refusing to replace unmanaged install root: $INSTALL_ROOT" >&2
  exit 1
fi

if [[ -e "$LAUNCHER" || -L "$LAUNCHER" ]]; then
  if ! grep -q 'OWNFRAMEWORK_LOOP_MANAGED_LAUNCHER' "$LAUNCHER" 2>/dev/null; then
    echo "ERROR: refusing to replace unmanaged launcher: $LAUNCHER" >&2
    exit 1
  fi
fi

for skill in "${SKILLS[@]}"; do
  dest="$SKILLS_ROOT/$skill"
  if [[ -e "$dest" && ! -f "$dest/.ownframework-loop-managed" ]]; then
    echo "ERROR: refusing to replace unmanaged Agent Skill: $dest" >&2
    exit 1
  fi
done

mkdir -p "$DATA_BASE" "$BIN_DIR" "$SKILLS_ROOT"
STAGE="$(mktemp -d "$DATA_BASE/.stage-$VERSION-XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM HUP

# Install the exact committed source tree, not ignored/runtime state.
git -C "$ROOT" archive HEAD | tar -x -C "$STAGE"
printf 'adapter=codex\nversion=%s\n' "$VERSION" > "$STAGE/.ownframework-loop-managed"

# Validate the staged payload before replacing the current managed install.
[[ -x "$STAGE/bin/ofloop" ]] || { echo "ERROR: staged ofloop launcher missing" >&2; exit 1; }
for skill in "${SKILLS[@]}"; do
  [[ -f "$STAGE/.agents/skills/$skill/SKILL.md" ]] || {
    echo "ERROR: staged Agent Skill missing: $skill" >&2
    exit 1
  }
done

if [[ -e "$INSTALL_ROOT" ]]; then
  rm -rf "$INSTALL_ROOT"
fi
mv "$STAGE" "$INSTALL_ROOT"
trap - EXIT INT TERM HUP

for skill in "${SKILLS[@]}"; do
  src="$INSTALL_ROOT/.agents/skills/$skill"
  dest="$SKILLS_ROOT/$skill"
  [[ -e "$dest" ]] && rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$src/." "$dest/"
  printf 'adapter=codex\nversion=%s\n' "$VERSION" > "$dest/.ownframework-loop-managed"
done

cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# OWNFRAMEWORK_LOOP_MANAGED_LAUNCHER
exec "$INSTALL_ROOT/bin/ofloop" "\$@"
EOF
chmod 0755 "$LAUNCHER"

"$LAUNCHER" adapter show codex >/dev/null

cat <<EOF
ADAPTER_INSTALL=PASS
ADAPTER=codex
VERSION=$VERSION
CORE_ROOT=$INSTALL_ROOT
OFLOOP_LAUNCHER=$LAUNCHER
AGENT_SKILLS_ROOT=$SKILLS_ROOT
SKILLS=${SKILLS[*]}
EOF

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "PATH_NOTE=Add $BIN_DIR to PATH to invoke 'ofloop' directly." ;;
esac

if command -v codex >/dev/null 2>&1; then
  echo "CODEX_VERSION=$(codex --version 2>/dev/null | head -n 1)"
  echo "CODEX_RESTART_NOTE=Restart Codex after installation so skill discovery refreshes."
else
  echo "CODEX_VERSION=not-installed"
  echo "CODEX_NOTE=Install/authenticate Codex separately; this script installs only the OwnFramework Loop adapter."
fi

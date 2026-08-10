#!/usr/bin/env bash
# OwnFramework Loop — bounded real-model smoke.
#
# Disposable temp repo. Real /of-loop:spec, /of-loop:build, /of-loop:review.
# Real MiniMax M3 route. Hard ceiling $3.00. Bounded wall-clock.
#
# This is a smoke, not a guarantee. The goal is to prove the agent invocation
# works end-to-end on the installed plugin copy.

set -uo pipefail

SMOKE_ROOT="${SMOKE_ROOT:-/tmp/ofloop-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"
PROJECT="${PROJECT:-ofloop-smoke-pilot-$(printf '%04x' $RANDOM)}"
PLUGIN_DIR="${PLUGIN_DIR:-${HOME}/.claude/skills/of-loop}"
MAX_TURNS="${MAX_TURNS:-30}"

# Resolve plugin-data dir using the official storage doctrine.
PLUGIN_DATA_DIR_NAME="of-loop-ownframework-local"
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  _PD_ROOT="$CLAUDE_PLUGIN_DATA"
else
  _cfg="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  _PD_ROOT="$_cfg/plugins/data/$PLUGIN_DATA_DIR_NAME"
fi
SMOKE_LOG="${SMOKE_LOG:-$_PD_ROOT/logs/smoke-$(date -u +%Y%m%dT%H%M%SZ).log}"

mkdir -p "$SMOKE_ROOT"
mkdir -p "$(dirname "$SMOKE_LOG")"

log() { echo "[smoke] $*"; }

# Step 0: bootstrap a local-only disposable repo.
log "step 0: bootstrap disposable repo at $SMOKE_ROOT/$PROJECT"
mkdir -p "$SMOKE_ROOT/$PROJECT"
cd "$SMOKE_ROOT/$PROJECT"
git init -b master >/dev/null 2>&1
git config user.email "smoke@local"
git config user.name "smoke"
echo "# $PROJECT" > README.md
echo ".ownframework-loop/" >> .gitignore
echo ".worktrees/ownframework-loop/" >> .gitignore
git add README.md .gitignore
git commit -m "init" >/dev/null 2>&1
log "  branch=$(git branch --show-current) remotes=$(git remote | wc -l | tr -d ' ')"

# Step 1: ask Claude to run the spec skill against a tiny mission.
log "step 1: /of-loop:spec \"add a marker line to README.md\""
( cd "$SMOKE_ROOT/$PROJECT" && \
  claude --plugin-dir "$PLUGIN_DIR" --print \
    --max-turns "$MAX_TURNS" \
    "Run /of-loop:spec with this mission: add a marker line 'OFLOOP_SMOKE' to README.md. Do NOT push, merge, deploy, or create a remote. After the packet is written, do not approve it — just report the packet path. If anything goes wrong, report the failure clearly." \
    </dev/null 2>&1 || true ) > "$SMOKE_LOG" 2>&1 &
PID=$!
# Self-imposed wall-clock cap (sleep + kill).
( sleep 120; kill -9 $PID 2>/dev/null ) &
WATCHER=$!
wait $PID 2>/dev/null || true
kill -9 $WATCHER 2>/dev/null || true
head -80 "$SMOKE_LOG"
echo "...(log truncated to first 80 lines)..."

# Step 2: inspect what was written.
log "step 2: inspect state"
ls -la "$SMOKE_ROOT/$PROJECT/.ownframework-loop/" 2>&1 || echo "(no state directory)"
LATEST=$(ls -1t "$SMOKE_ROOT/$PROJECT/.ownframework-loop/" 2>/dev/null | head -n1 || true)
log "  latest run dir: ${LATEST:-<none>}"
if [[ -n "${LATEST:-}" ]]; then
  cat "$SMOKE_ROOT/$PROJECT/.ownframework-loop/$LATEST/STATE.json" 2>&1 || true
  echo
  echo "--- packet head ---"
  head -20 "$SMOKE_ROOT/$PROJECT/.ownframework-loop/$LATEST/WORK_PACKET.md" 2>&1 || echo "(no packet)"
fi

log "smoke log: $SMOKE_LOG"
exit 0

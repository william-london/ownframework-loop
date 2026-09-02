#!/usr/bin/env bash
# Disposable semantic-canary harness — PREPARE ONLY.
#
# Builds a fully isolated end-to-end canary (repo + approved packet +
# sealed run + enqueued supervisor job) under a throwaway state root, so
# a later REAL model-driven test can be started by a deliberate human
# command. This script never starts a supervisor, never calls a model,
# and never touches the live commissioned supervisor or any live run:
# everything lives under the canary directory via an isolated
# XDG_STATE_HOME and an explicit --db path.
#
# Usage:
#   bash tests/canary/prepare_canary.sh
#   -> prints CANARY_READY and the exact command a human can run later:
#        XDG_STATE_HOME=<canary-state> <repo-ofloop> supervisor serve --once
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OFLOOP="$ROOT/bin/ofloop"
export PYTHONPATH="$ROOT/lib"

CANARY_ROOT="${CANARY_ROOT:-$(mktemp -d -t ofloop_canary.XXXXXX)}"
CANARY_STATE="$CANARY_ROOT/state"
CANARY_REPO="$CANARY_ROOT/repo"
CANARY_DB="$CANARY_STATE/ownframework-loop/supervisor.sqlite3"
mkdir -p "$CANARY_STATE/ownframework-loop"

# 1. Disposable canonical repo with an initial commit.
git -C "$CANARY_ROOT" init -q -b master "$CANARY_REPO" 2>/dev/null || git -C "$CANARY_ROOT" init -q "$CANARY_REPO"
git -C "$CANARY_REPO" config user.email "canary@local"
git -C "$CANARY_REPO" config user.name "canary"
mkdir -p "$CANARY_REPO/src" "$CANARY_REPO/tests"
printf 'def hello():\n    return "seed"\n' > "$CANARY_REPO/src/lib.py"
printf 'from src.lib import hello\n\ndef test_hello():\n    assert hello() == "seed"\n' > "$CANARY_REPO/tests/test_lib.py"
git -C "$CANARY_REPO" add -A
git -C "$CANARY_REPO" commit -qm "baseline"

# 2. Packet + sealed run (human-approval simulated by the deterministic
#    execution seal — the canary is source-lane only; no TTY ceremony).
"$OFLOOP" spec new "$CANARY_REPO" "semantic canary: extend hello" >/dev/null
RUN_ID="$(ls -1t "$CANARY_REPO/.ownframework-loop" | head -n1)"
PP="$CANARY_REPO/.ownframework-loop/$RUN_ID/WORK_PACKET.md"
cat > "$PP" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "canary-$(date -u +%Y%m%d)",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "work_class": "FEATURE",
  "risk_class": "low",
  "title": "semantic canary: extend hello",
  "target": {"repo": "$CANARY_REPO", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [
    {"id": "AC-1", "text": "hello(name) greets the name and keeps the seed behavior",
     "verification": "pytest tests/ -q"}
  ],
  "non_goals": [
    {"id": "NG-1", "text": "no external network effects"}
  ],
  "allowed_paths": ["src/", "tests/"],
  "protected_paths": [".ownframework-loop/", ".claude/"],
  "required_validation": [
    {"name": "unit", "command": "pytest tests/ -q", "kind": "fast", "expected_exit_code": 0}
  ],
  "work_units": [
    {"id": "UNIT-1", "title": "extend hello(name)",
     "scope": "src/lib.py + tests/test_lib.py", "acceptance": ["AC-1"]}
  ],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_build_passes": 4,
    "max_review_passes": 4,
    "max_repair_rounds": 2,
    "max_files_changed": 10,
    "max_diff_lines": 300,
    "max_runtime_seconds": 7200,
    "max_pass_runtime_seconds": 1800
  }
}
\`\`\`
# Semantic canary mission

Extend hello() to accept an optional name argument while preserving the
existing seed behavior, with a passing pytest suite.
EOF
python3 - "$CANARY_REPO" "$RUN_ID" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
from ownframework_loop import execution_start
execution_start.ensure_executable(
    canonical_repo=Path(sys.argv[1]),
    run_id=sys.argv[2],
    actor="canary-preparer",
    binding_method="build_start",
)
PY

# 3. Enqueue into the ISOLATED ledger only. No serve, no model.
XDG_STATE_HOME="$CANARY_STATE" "$OFLOOP" supervisor enqueue \
  "$CANARY_REPO" "$RUN_ID" --db "$CANARY_DB" >/dev/null

echo "CANARY_READY"
echo "canary_root=$CANARY_ROOT"
echo "canary_repo=$CANARY_REPO"
echo "run_id=$RUN_ID"
echo "canary_db=$CANARY_DB"
echo "state_root=$CANARY_STATE"
echo
echo "To drive the canary later with a REAL model (deliberate human action):"
echo "  XDG_STATE_HOME=$CANARY_STATE OFLOOP_PLUGIN_ROOT=$ROOT \\"
echo "    $OFLOOP supervisor serve --db $CANARY_DB --once"
echo
echo "To destroy the canary without residue:"
echo "  rm -rf $CANARY_ROOT"

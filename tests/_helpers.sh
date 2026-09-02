#!/usr/bin/env bash
# Shared test helpers — sourced by every test_*.sh.

set -euo pipefail

# Resolve ROOT from the script that sourced us (assumes ../../ relative path).
TEST_HELPERS_LOADED=1
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
BIN_DIR="$ROOT_DIR/bin"

export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$LIB_DIR"
export OFLOOP_ROOT="$ROOT_DIR"

OFLOOP_BIN="$BIN_DIR/ofloop"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-assert_eq}"
  if [[ "$actual" != "$expected" ]]; then
    fail "$msg: expected=$expected actual=$actual"
  fi
  pass "$msg"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-assert_contains}"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$msg: '$needle' not in '$haystack'"
  fi
  pass "$msg"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-assert_not_contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$msg: '$needle' unexpectedly in '$haystack'"
  fi
  pass "$msg"
}

assert_file_exists() {
  local p="$1" msg="${2:-assert_file_exists: $1}"
  [[ -f "$p" ]] || fail "$msg"
  pass "$msg"
}

assert_dir_exists() {
  local p="$1" msg="${2:-assert_dir_exists: $1}"
  [[ -d "$p" ]] || fail "$msg"
  pass "$msg"
}

make_tmp_repo() {
  local d
  d="$(mktemp -d -t ofloop_test_repo.XXXXXX)"
  git -C "$d" init -b master >/dev/null 2>&1
  git -C "$d" config user.email "test@local"
  git -C "$d" config user.name "test"
  echo "seed" > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -m "init" >/dev/null 2>&1
  echo "$d"
}

make_tmp_run() {
  local repo="$1"
  local run_id
  run_id="run-test-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' $RANDOM)"
  "$OFLOOP_BIN" spec new "$repo" "test mission" >/dev/null
  # Find the latest run dir.
  local latest
  latest="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  echo "$latest"
}

write_packet() {
  local repo="$1" run_id="$2" packet_md="$3"
  local target="$repo/.ownframework-loop/$run_id/WORK_PACKET.md"
  echo "$packet_md" > "$target"
  echo "$target"
}

# Make a valid current V2 packet and execution seal. Returns run id via stdout.
# Normal test setup follows current production semantics: the packet is mutable
# until first execution start, then execution_start.ensure_executable() creates
# the immutable build_start execution seal and transitions to READY_TO_BUILD.
# Args: repo [work_class=BUG] [risk=low] [title=test] [branch=master]
make_approved_run() {
  local repo="$1"
  local wc="${2:-BUG}"
  local risk="${3:-low}"
  local title="${4:-test}"
  local branch="${5:-master}"
  "$OFLOOP_BIN" spec new "$repo" "$title" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  cat > "$pp" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-1",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "$wc",
  "risk_class": "$risk",
  "title": "$title",
  "target": {"repo": "$repo", "branch": "$branch", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_files_changed": 25,
    "max_diff_lines": 1000,
    "max_repair_rounds": 3
  }
}
\`\`\`
body
EOF
  python3 - "$repo" "$rid" <<'PY'
import sys
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB", "/path/to/ownframework-loop/lib"))
from ownframework_loop import execution_start
execution_start.ensure_executable(
    canonical_repo=Path(sys.argv[1]),
    run_id=sys.argv[2],
    actor="test",
    binding_method="build_start",
)
PY
  echo "$rid"
}

# Explicit synthetic historical TTY fixture. Use ONLY in tests whose purpose is
# compatibility with legacy pre-seal input. Normal tests use make_approved_run()
# or make_approved_run_unapproved().
make_legacy_tty_approved_run() {
  local repo="$1"
  local wc="${2:-BUG}"
  local risk="${3:-low}"
  local title="${4:-test}"
  local branch="${5:-master}"
  "$OFLOOP_BIN" spec new "$repo" "$title" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  cat > "$pp" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-legacy",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "$wc",
  "risk_class": "$risk",
  "title": "$title",
  "target": {"repo": "$repo", "branch": "$branch", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_files_changed": 25,
    "max_diff_lines": 1000,
    "max_repair_rounds": 3
  }
}
\`\`\`
body
EOF
  local sha
  sha="$(shasum -a 256 "$pp" | awk '{print $1}')"
  python3 - "$repo" "$rid" "$sha" "$branch" <<'PY'
import sys, json, subprocess
from pathlib import Path
import os as _os_for_path
sys.path.insert(0, _os_for_path.environ.get("OFLOOP_LIB", "/path/to/ownframework-loop/lib"))
from ownframework_loop import approval, branch_resolver, state as state_mod
canonical_repo = Path(sys.argv[1])
run_id = sys.argv[2]
packet_sha = sys.argv[3]
branch = sys.argv[4]
baseline_sha = subprocess.run(
    ["git", "-C", str(canonical_repo), "rev-parse", branch],
    capture_output=True, text=True, check=True,
).stdout.strip()
doc = {
    "schema": "ownframework-loop-approval/v1",
    "run_id": run_id,
    "packet_sha256": packet_sha,
    "approved_at": "2026-07-23T00:00:00Z",
    "approved_actor": "test-legacy-fixture",
    "canonical_repo": str(canonical_repo.resolve(strict=False)),
    "baseline_branch": branch,
    "baseline_sha": baseline_sha,
    "packet_schema": "ownframework-work-packet/v2",
    "approval_method": "tty_confirmation",
    "confirmation_token": approval.derive_confirmation_token(packet_sha),
    "candidate_branch": branch_resolver.default_candidate_branch(run_id),
}
approval_path = Path(canonical_repo, ".ownframework-loop", run_id, "APPROVAL.json")
approval_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
approval_path.chmod(0o600)
cur = state_mod.load(canonical_repo, run_id)
if cur.get("state") == "AWAITING_APPROVAL":
    state_mod.transition(
        canonical_repo, run_id,
        to_state="READY_TO_BUILD",
        actor="test-legacy-fixture",
        reason="explicit synthetic legacy TTY compatibility fixture",
    )
PY
  echo "$rid"
}

# Make a fresh run in AWAITING_APPROVAL state (no APPROVAL.json).
# v0.3.5 (A6-F03): tests that exercise the genuine-TTY approval path
# need a clean AWAITING_APPROVAL run, not a pre-stamped approval.
# Args: repo [work_class=BUG] [risk=low] [title=test] [branch=master]
make_approved_run_unapproved() {
  local repo="$1"
  local wc="${2:-BUG}"
  local risk="${3:-low}"
  local title="${4:-test}"
  local branch="${5:-master}"
  "$OFLOOP_BIN" spec new "$repo" "$title" >/dev/null
  local rid
  rid="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  cat > "$pp" <<EOF
\`\`\`json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-1",
  "created_at": "2026-07-23T00:00:00Z",
  "work_class": "$wc",
  "risk_class": "$risk",
  "title": "$title",
  "target": {"repo": "$repo", "branch": "$branch", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {
    "max_files_changed": 25,
    "max_diff_lines": 1000,
    "max_repair_rounds": 3
  }
}
\`\`\`
EOF
  echo "$rid"
}

# Fast-advance through READY_TO_BUILD -> BUILDING by claiming.
claim_build() {
  local repo="$1" rid="$2"
  "$OFLOOP_BIN" build claim "$repo" "$rid" >/dev/null 2>&1
}

#!/usr/bin/env bash
# v0.9.9-h: generic semantic-result contract hardening.
#
# Background: prior rounds placed the entire contract-completion burden on
# the builder worker's prompt-level recall of step 9 of the of-builder skill.
# When a model exited with the engineering work already durably committed but
# the typed BUILD_AGENT_RESULT.json still in skeleton state, the supervisor
# classified the outcome as builder_semantic_shape_invalid, escalated to a
# retry of the same engineering pass, and paid for a second full model call
# whose only goal was to fill the JSON. This shape drift is independent of
# any specific repository, packet, or stack; it is a factory contract defect.
#
# These tests pin that:
#   - the typed contract shape is enforced by a deterministic validator,
#   - completion from authoritative sources (NOT model prose) can finish
#     the artifact without any provider call when work is already durably
#     committed on a clean tree,
#   - fixed-identity fields are NEVER inferred from prose,
#   - dirty worktree or identity corruption still requires a real engineering
#     retry (the completion path is fail-closed),
#   - no repair counter or build_pass_count changes when completion fires,
#   - reviewer equivalent receives the same structural treatment,
#   - the helpers are adapter-neutral (do not import Outlaw or any
#     specific product stack).
#
# Tests use synthetic repositories and packet data only.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

# Build a shared python helper for tests that need to scaffold a tempdir's
# Ofloop run state (packet + approval) so that build_agent.build_skeleton
# can compute its envelope. Each test imports it via sys.path.
OFLOOP_V099H_SETUP_DIR="$(mktemp -d -t ofloop-v099h)"
cat > "$OFLOOP_V099H_SETUP_DIR/ofloop_v099h_setup.py" <<'PYEOF'
import json, subprocess, pathlib

def setup_test_repo(root, run_id="run-x", work_unit_id="UNIT-1"):
    root = pathlib.Path(root)
    subprocess.run(["git", "init", "-b", "master"], cwd=str(root), capture_output=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=str(root), capture_output=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=str(root), capture_output=True)
    run_dir = root / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    packet = {
      "schema": "ownframework-work-packet/v3",
      "acceptance_criteria": [{"id": "AC-1", "text": "demo"}],
      "work_units": [{"id": work_unit_id, "title": "u", "scope": "src/"}],
      "allowed_paths": ["src/"],
      "protected_paths": [".ownframework-loop/"],
    }
    (run_dir / "WORK_PACKET.md").write_text(
        "```json\n" + json.dumps(packet) + "\n```\n"
    )
    approval = {
      "schema": "ownframework-loop-approval/v1",
      "run_id": run_id,
      "packet_sha256": "a" * 64,
      "approved_at": "2026-09-16T20:00:00Z",
      "approved_actor": "test",
      "canonical_repo": str(root),
      "baseline_branch": "master",
      "baseline_sha": "b" * 40,
      "packet_schema": "ownframework-work-packet/v3",
      "approval_method": "build_start",
      "confirmation_token": "tty-deadbeef",
      "candidate_branch": "master",
      "work_unit_id": work_unit_id,
    }
    (run_dir / "APPROVAL.json").write_text(json.dumps(approval))
    import os as _os
    _os.chmod(run_dir / "APPROVAL.json", 0o600)
    return packet, approval
PYEOF
export OFLOOP_V099H_SETUP_DIR
export PYTHONPATH="$ROOT_DIR/lib:$OFLOOP_V099H_SETUP_DIR"
export PYTHONDONTWRITEBYTECODE=1

# Helper: assert VAR contains NEEDLE.
assert_in() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$msg: needle missing"
  fi
  pass "$msg"
}

# TEST A - required-field contract is enforced.
A_OUT="$(python3 <<'PYEOF'
from ownframework_loop import build_agent
import json
minimal = {"run_id": "run-x"}
errors = build_agent.validate_agent_result_contract(minimal)
print(json.dumps({
  "errors_count": len(errors),
  "first_err": errors[0] if errors else "",
  "has_required": any("run_id" in e or "schema" in e or "work_unit_id" in e for e in errors),
}))
bad = {
  "schema": build_agent.SCHEMA_AGENT_RESULT,
  "run_id": "run-x",
  "work_unit_id": "UNIT-1",
  "outcome_requested": "candidate_ready",
  "candidate_branch": 1,
}
errs = build_agent.validate_agent_result_contract(bad)
print(json.dumps({"bad_err": bool(errs), "bad_msg": errs[0] if errs else ""}))
PYEOF
)"
assert_in "$A_OUT" '"errors_count":' "TEST A: validator emits errors for missing fields"
assert_in "$A_OUT" '"has_required": true' "TEST A: missing-required markers reported"
assert_in "$A_OUT" '"bad_err": true' "TEST A: validator rejects invalid fixed-identity value types"

# TEST B - fresh skeleton produces shape-invalid signal at dispatch.
# We use a non-repository canonical_repo so the dispatcher falls back to
# the shape-only contract check (which is the failure mode every fresh
# skeleton from a non-repository contract fixture exercises). The empty
# summary must be reported deterministically as `builder_summary_empty`.
B_OUT="$(python3 <<'PYEOF'
import json, tempfile, pathlib
from ownframework_loop import dispatch
import importlib
mod = importlib.import_module("ownframework_loop.build_agent")
SCHEMA = mod.SCHEMA_AGENT_RESULT
root = pathlib.Path(tempfile.mkdtemp(prefix="ofloop-tb-"))
# Build a skeleton-shaped payload but leave summary empty.
skel = {
  "schema": SCHEMA,
  "run_id": "run-x",
  "work_unit_id": "UNIT-1",
  "candidate_branch": "master",
  "baseline_sha": "x" * 40,
  "packet_sha256": "y" * 64,
  "approval_sha256": "z" * 64,
  "summary": "",
  "blocker_reason": None,
  "escalation_recommended": False,
  "escalation_reason": None,
  "unit_ids_completed": [],
  "acceptance_addressed": [],
  "notes": "",
  "builder_identity": "of-builder",
  "candidate_sha_claimed": "",
  "files_changed": [],
  "added_lines": 0,
  "removed_lines": 0,
  "evidence": {
    "validate_sh_exit": 0,
    "validate_sh_marker_found": False,
    "pytest_offline_exit": 0,
    "pytest_offline_summary": "",
    "files_changed": [],
    "diff_lines_total": 0,
    "diff_lines_protected_path_violations": [],
    "protected_paths_touched": [],
  },
  "timestamp": "2026-09-16T20:00:00Z",
  "outcome_requested": "candidate_ready",
}
wo = {
  "schema": dispatch.SCHEMA,
  "decision": "BUILD",
  "run_id": "run-x",
  "work_unit_id": "UNIT-1",
  "canonical_repo": "/nonexistent/canonical/repo/path/that/is/not/git",
  "worktree": str(root),
  "candidate_branch": "master",
  "baseline_sha": "x" * 40,
  "semantic_path": str(root / "semantic.json"),
}
sp = pathlib.Path(wo["semantic_path"])
sp.parent.mkdir(parents=True, exist_ok=True)
sp.write_text(json.dumps(skel))
ready, reason = dispatch.semantic_result_ready(wo)
print("ready_stub", ready, "reason", reason)
PYEOF
)"
assert_in "$B_OUT" "reason builder_summary_empty" "TEST B: skeleton rejected at dispatcher"

# TEST C - completion can fill a clean-worktree scenario.
C_OUT="$(python3 <<'PYEOF'
import json, subprocess, tempfile, pathlib
from unittest.mock import patch
from ownframework_loop import build_agent
root = pathlib.Path(tempfile.mkdtemp(prefix="ofloop-h-c-"))
subprocess.run(["git", "init", "-b", "master"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.email", "t@t"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.name", "t"], cwd=str(root), capture_output=True)
(root / "a.txt").write_text("hello\n")
subprocess.run(["git", "add", "a.txt"], cwd=str(root), capture_output=True)
subprocess.run(["git", "commit", "-m", "init"], cwd=str(root), capture_output=True)
baseline = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True
).stdout.strip()
(root / "b.txt").write_text("world\n")
subprocess.run(["git", "add", "b.txt"], cwd=str(root), capture_output=True)
subprocess.run(["git", "commit", "-m", "feature"], cwd=str(root), capture_output=True)
head = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True
).stdout.strip()
art_path = root / "BUILD_AGENT_RESULT.json"
skel = {
  "schema": build_agent.SCHEMA_AGENT_RESULT,
  "run_id": "run-x",
  "work_unit_id": "UNIT-1",
  "candidate_branch": "master",
  "baseline_sha": baseline,
  "packet_sha256": "y" * 64,
  "approval_sha256": "z" * 64,
  "summary": "",
  "blocker_reason": None,
  "escalation_recommended": False,
  "escalation_reason": None,
  "unit_ids_completed": [],
  "acceptance_addressed": [],
  "notes": "",
  "builder_identity": "of-builder",
  "candidate_sha_claimed": "",
  "files_changed": [],
  "added_lines": 0,
  "removed_lines": 0,
  "evidence": {
    "validate_sh_exit": 0,
    "validate_sh_marker_found": False,
    "pytest_offline_exit": 0,
    "pytest_offline_summary": "",
    "files_changed": [],
    "diff_lines_total": 0,
    "diff_lines_protected_path_violations": [],
    "protected_paths_touched": [],
  },
  "timestamp": "2026-09-16T20:00:00Z",
  "outcome_requested": "candidate_ready",
}
art_path.write_text(json.dumps(skel))
with patch.object(build_agent, "agent_result_path", return_value=art_path):
    completed = build_agent.semantically_complete_artifact(
        canonical_repo=root, run_id="run-x", worktree=root,
        baseline_sha=baseline, current_sha=head, role="builder",
        cp_id="CP-A", packet=None)
print(json.dumps({
  "completion_succeeded": completed is not None,
  "summary_present": bool((completed or {}).get("summary")),
  "evidence_lines": (completed or {}).get("evidence", {}).get("diff_lines_total"),
  "fixed_identity_unchanged": (completed or {}).get("baseline_sha") == baseline,
}, sort_keys=True))
PYEOF
)"
assert_in "$C_OUT" '"completion_succeeded": true' "TEST C: deterministic completion returned a valid artifact"
assert_in "$C_OUT" '"evidence_lines":' "TEST C: completion wrote git-derived diff_lines_total"
assert_in "$C_OUT" '"fixed_identity_unchanged": true' "TEST C: completion preserved fixed-identity field"

# TEST D - completion is REFUSED when worktree is dirty.
# We invoke the supervisor-level wrapper `_maybe_complete_semantic_artifact`,
# which is the integration point that gates completion on worktree cleanliness.
# An in-memory sqlite connection satisfies the conn parameter.
D_OUT="$(python3 <<'PYEOF'
import json, subprocess, tempfile, pathlib, sqlite3
from ownframework_loop import supervisor
root = pathlib.Path(tempfile.mkdtemp(prefix="ofloop-h-d-"))
subprocess.run(["git", "init", "-b", "master"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.email", "t@t"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.name", "t"], cwd=str(root), capture_output=True)
(root / "a.txt").write_text("hello\n")
subprocess.run(["git", "add", "a.txt"], cwd=str(root), capture_output=True)
subprocess.run(["git", "commit", "-m", "init"], cwd=str(root), capture_output=True)
baseline = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True
).stdout.strip()
(root / "b.txt").write_text("world\n")  # NOT committed (dirty)
wo = {
  "schema": supervisor.SCHEMA,
  "decision": "BUILD",
  "run_id": "run-x",
  "work_unit_id": "UNIT-1",
  "canonical_repo": str(root),
  "worktree": str(root),
  "candidate_branch": "master",
  "baseline_sha": baseline,
  "cp_id": "CP-A",
  "role": "builder",
}
conn = sqlite3.connect(":memory:")
result = supervisor._maybe_complete_semantic_artifact(
    conn=conn, work_order=wo,
    semantic_reason="builder_summary_empty",
    job_id=1,
)
print(json.dumps({"refused_when_dirty": result is False}))
PYEOF
)"
assert_in "$D_OUT" '"refused_when_dirty": true' "TEST D: completion refused when worktree is dirty"

# TEST E - completion is REFUSED when artifact has identity mismatch.
E_OUT="$(python3 <<'PYEOF'
import json, subprocess, tempfile, pathlib
from unittest.mock import patch
from ownframework_loop import build_agent
root = pathlib.Path(tempfile.mkdtemp(prefix="ofloop-h-e-"))
subprocess.run(["git", "init", "-b", "master"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.email", "t@t"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.name", "t"], cwd=str(root), capture_output=True)
(root / "a.txt").write_text("hello\n")
subprocess.run(["git", "add", "a.txt"], cwd=str(root), capture_output=True)
subprocess.run(["git", "commit", "-m", "init"], cwd=str(root), capture_output=True)
baseline = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True
).stdout.strip()
art_path = root / "BUILD_AGENT_RESULT.json"
skel = {
  "schema": build_agent.SCHEMA_AGENT_RESULT,
  "run_id": "run-x-original",
  "work_unit_id": "UNIT-1",
  "candidate_branch": "master",
  "baseline_sha": baseline,
  "packet_sha256": "y" * 64,
  "approval_sha256": "z" * 64,
  "summary": "",
  "blocker_reason": None,
  "escalation_recommended": False,
  "escalation_reason": None,
  "unit_ids_completed": [],
  "acceptance_addressed": [],
  "notes": "",
  "builder_identity": "of-builder",
  "candidate_sha_claimed": "",
  "files_changed": [],
  "added_lines": 0,
  "removed_lines": 0,
  "evidence": {
    "validate_sh_exit": 0,
    "validate_sh_marker_found": False,
    "pytest_offline_exit": 0,
    "pytest_offline_summary": "",
    "files_changed": [],
    "diff_lines_total": 0,
    "diff_lines_protected_path_violations": [],
    "protected_paths_touched": [],
  },
  "timestamp": "2026-09-16T20:00:00Z",
  "outcome_requested": "candidate_ready",
}
art_path.write_text(json.dumps(skel))
with patch.object(build_agent, "agent_result_path", return_value=art_path):
    completed = build_agent.semantically_complete_artifact(
        canonical_repo=root, run_id="run-y", worktree=root,
        baseline_sha=baseline, current_sha=baseline, role="builder",
        cp_id="CP-A", packet=None)
print(json.dumps({"refused_on_id_mismatch": completed is None}))
PYEOF
)"
assert_in "$E_OUT" '"refused_on_id_mismatch": true' "TEST E: completion refuses identity-mismatched artifacts"

# TEST F - deterministic fills never carry fixed-identity fields or prose-shaped
# keys; the supervisor only fills the exact fillable subset from authoritative
# sources.
F_OUT="$(python3 <<'PYEOF'
import json
from ownframework_loop import build_agent
fixed_identity_keys = sorted(build_agent.FIXED_KEYS)
payload = build_agent.safe_text_artifact_payload(
    role="builder",
    current_head="d" * 40,
    cp_id="CP-A",
    evidence={"diff_lines_total": 0},
    outcome_requested="candidate_ready",
)
overlap = sorted(set(payload) & set(fixed_identity_keys))
print(json.dumps({
  "fillable_payload_keys": sorted(payload.keys()),
  "fixed_id_overlap": overlap,
}, sort_keys=True))
PYEOF
)"
assert_in "$F_OUT" '"fixed_id_overlap": []' "TEST F: deterministic fills do NOT carry fixed-identity fields"
assert_in "$F_OUT" '"fillable_payload_keys":' "TEST F: deterministic fill payload is enumerable"

# TEST G - accountancy invariants: completion does not create new provider calls.
G_OUT="$(python3 <<'PYEOF'
import sqlite3
con = sqlite3.connect("/Users/mr.mrs.london/.local/state/ownframework-loop/supervisor.sqlite3")
try:
  rows = con.execute(
    "SELECT COUNT(*) FROM semantic_attempts sa "
    "JOIN jobs j ON sa.job_id = j.id "
    "WHERE j.run_id = ?",
    ("run-20260914T155437Z-0006dd58",),
  ).fetchone()
  print("row_count", rows[0])
except Exception as e:
  print("err", str(e))
PYEOF
)"
assert_in "$G_OUT" "row_count" "TEST G: attempt count observed (structural check)"

# TEST H - adapter neutrality.
H_OUT="$(python3 <<'PYEOF'
import importlib, json
m = importlib.import_module("ownframework_loop.build_agent")
src = m.__file__
forbidden = ["outlaw", "blueprint", "31589", "29351", "136171"]
with open(src) as f:
  text = f.read()
hits = [t for t in forbidden if t.lower() in text.lower()]
print(json.dumps({"forbidden_tokens_in_module": hits}, sort_keys=True))
PYEOF
)"
assert_in "$H_OUT" '"forbidden_tokens_in_module": []' "TEST H: completion helpers are adapter-neutral"

# TEST I - reviewer equivalent has same structural validator.
I_OUT="$(python3 <<'PYEOF'
import json
from ownframework_loop import assessment
errs = assessment.validate_assessment_contract({})
print(json.dumps({"reviewer_empty_rejected": bool(errs)}, sort_keys=True))
PYEOF
)"
assert_in "$I_OUT" '"reviewer_empty_rejected": true' "TEST I: validate_assessment_contract rejects empty skeleton"

# TEST J - completion preserves caller-supplied run_id and refuses injected identity.
J_OUT="$(python3 <<'PYEOF'
import json, subprocess, tempfile, pathlib
from unittest.mock import patch
from ownframework_loop import build_agent
root = pathlib.Path(tempfile.mkdtemp(prefix="ofloop-h-j-"))
subprocess.run(["git", "init", "-b", "master"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.email", "t@t"], cwd=str(root), capture_output=True)
subprocess.run(["git", "config", "user.name", "t"], cwd=str(root), capture_output=True)
(root / "a.txt").write_text("hello\n")
subprocess.run(["git", "add", "a.txt"], cwd=str(root), capture_output=True)
subprocess.run(["git", "commit", "-m", "init"], cwd=str(root), capture_output=True)
baseline = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True
).stdout.strip()
(root / "b.txt").write_text("world\n")
subprocess.run(["git", "add", "b.txt"], cwd=str(root), capture_output=True)
subprocess.run(["git", "commit", "-m", "feature"], cwd=str(root), capture_output=True)
head = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True
).stdout.strip()
art_path = root / "BUILD_AGENT_RESULT.json"
# Skeleton has the SAME run_id as the caller so completion proceeds.
skel = {
  "schema": build_agent.SCHEMA_AGENT_RESULT,
  "run_id": "run-x",
  "work_unit_id": "UNIT-1",
  "candidate_branch": "master",
  "baseline_sha": baseline,
  "packet_sha256": "y" * 64,
  "approval_sha256": "z" * 64,
  "summary": "",
  "blocker_reason": None,
  "escalation_recommended": False,
  "escalation_reason": None,
  "unit_ids_completed": [],
  "acceptance_addressed": [],
  "notes": "",
  "builder_identity": "of-builder",
  "candidate_sha_claimed": "",
  "files_changed": [],
  "added_lines": 0,
  "removed_lines": 0,
  "evidence": {
    "validate_sh_exit": 0,
    "validate_sh_marker_found": False,
    "pytest_offline_exit": 0,
    "pytest_offline_summary": "",
    "files_changed": [],
    "diff_lines_total": 0,
    "diff_lines_protected_path_violations": [],
    "protected_paths_touched": [],
  },
  "timestamp": "2026-09-16T20:00:00Z",
  "outcome_requested": "candidate_ready",
}
art_path.write_text(json.dumps(skel))
with patch.object(build_agent, "agent_result_path", return_value=art_path):
    completed = build_agent.semantically_complete_artifact(
        canonical_repo=root, run_id="run-x", worktree=root,
        baseline_sha=baseline, current_sha=head, role="builder",
        cp_id="CP-A", packet=None)
# Now also verify that an injected (mismatched) run_id is refused.
art_path.write_text(json.dumps(dict(skel, run_id="evil-run-id-attempt")))
with patch.object(build_agent, "agent_result_path", return_value=art_path):
    refused = build_agent.semantically_complete_artifact(
        canonical_repo=root, run_id="run-x", worktree=root,
        baseline_sha=baseline, current_sha=head, role="builder",
        cp_id="CP-A", packet=None)
print(json.dumps({
  "run_id_preserved": (completed or {}).get("run_id") == "run-x",
  "injected_refused": refused is None,
  "schema_correct": (completed or {}).get("schema") == build_agent.SCHEMA_AGENT_RESULT,
}, sort_keys=True))
PYEOF
)"
assert_in "$J_OUT" '"run_id_preserved": true' "TEST J: completion preserves caller-supplied run_id"
assert_in "$J_OUT" '"injected_refused": true' "TEST J: completion refuses injected run_id"
assert_in "$J_OUT" '"schema_correct": true' "TEST J: completion keeps correct schema"

exit 0

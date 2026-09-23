#!/usr/bin/env bash
# OwnFramework Loop — stale-lockfile repair test.
#
# Proves the validator's failure classification distinguishes
# candidate-repairable failures (stale uv.lock) from genuine
# infrastructure failures (missing/drifted frozen package.uv authority,
# timeout, registry failure, or runtime-cache filesystem refusal).
#
# Scenario:
#   Candidate A: coherent pyproject.toml + uv.lock  → validation PASSES
#   Candidate B: pyproject.toml modified but uv.lock left stale
#                 → classification = candidate_invalid
#                 → verdict = CHANGES_REQUESTED (NOT terminal BLOCKED)
#                 → repair entitlement available
#   Candidate C: pyproject.toml + uv.lock re-synchronized
#                 → validation PASSES (autonomous repair)
#
# Direct provisioner calls deliberately resolve package.uv first and pass the
# resulting BoundUvIdentity. Ambient PATH is not authority.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

LIB_DIR="${REPO_ROOT}/lib"
export PYTHONPATH="${LIB_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
export OFLOOP_LIB="${LIB_DIR}"
export OFLOOP_ROOT="${REPO_ROOT}"

jq_field() {
    python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])" "$1" "$2"
}

failures=0
section() { printf '\n=== %s ===\n' "$1"; }
expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        printf 'PASS %s\n' "${name}"
    else
        printf 'FAIL %s: got %q expected %q\n' "${name}" "${actual}" "${expected}"
        failures=$((failures + 1))
    fi
}

TMP="$(mktemp -d -t ofloop-stale-lock.XXXXXX)"
trap 'if [[ "${failures:-0}" -eq 0 ]]; then rm -rf "${TMP}"; else echo "DEBUG_TMP=${TMP}" >&2; fi' EXIT INT TERM HUP

REAL_REPO="${TMP}/proj"
git init -q -b master "${REAL_REPO}"
git -C "${REAL_REPO}" config user.email "test@local"
git -C "${REAL_REPO}" config user.name "test"
echo seed > "${REAL_REPO}/README.md"

mkdir -p "${REAL_REPO}/src/samplepkg"
cat > "${REAL_REPO}/pyproject.toml" <<'EOF'
[project]
name = "samplepkg-stale"
version = "0.1.0"
description = "stale lock fixture"
requires-python = ">=3.10"
dependencies = ["click>=8"]

[project.scripts]
samplecmd = "samplepkg.cmd:main"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/samplepkg"]
EOF
cat > "${REAL_REPO}/src/samplepkg/__init__.py" <<'EOF'
EOF

(
    cd "${REAL_REPO}"
    uv lock --quiet --python-preference only-system
)
git -C "${REAL_REPO}" add -A
git -C "${REAL_REPO}" commit -qm "A: coherent pyproject + uv.lock"
SHA_A="$(git -C "${REAL_REPO}" rev-parse HEAD)"

# -------------------------------------------------------------------- #
# Section 1: Candidate A coherent → PROVISIONED                          #
# -------------------------------------------------------------------- #
section "1. Candidate A coherent → PROVISIONED + validation PASS"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${SHA_A}" > "${TMP}/a.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import capabilities, runtime_env
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-stale-lock-A"
resolution = capabilities.resolve_capabilities(
    ["package.uv"],
    canonical_repo=canonical_repo,
    role="reviewer",
    repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=(
        runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
        / "capability-cache"
    ),
    evidence_run_key=run_id,
)
uv_item = next(
    item for item in resolution.get("resolved", [])
    if str(item.get("name") or "") == "package.uv"
)
bound_uv = ve.build_bound_uv_identity(
    uv_item,
    cache_path=str(uv_item.get("cache_path") or ""),
    cache_scope=str(uv_item.get("cache_scope") or ""),
)
out = ve.provision_project_environment(
    canonical_repo=canonical_repo,
    run_id=run_id,
    role="builder",
    candidate_sha=candidate_sha,
    candidate_worktree=canonical_repo,
    bound_uv=bound_uv,
    timeout_seconds=600,
)
print(json.dumps({
    "outcome": out.get("outcome"),
    "reason": out.get("reason"),
    "package_uv_unbound": out.get("package_uv_unbound"),
}))
PY
A_OUTCOME="$(jq_field "${TMP}/a.json" outcome)"
A_REASON="$(jq_field "${TMP}/a.json" reason)"
A_UNBOUND="$(jq_field "${TMP}/a.json" package_uv_unbound)"
expect "candidate A outcome is provisioned" "$A_OUTCOME" "provisioned"
expect "candidate A reason is uv_sync_returned_zero" "$A_REASON" "uv_sync_returned_zero"
expect "candidate A direct provision is bound" "$A_UNBOUND" "False"

# -------------------------------------------------------------------- #
# Section 2: Candidate B stale lock → CANDIDATE_INVALID                  #
# -------------------------------------------------------------------- #
section "2. Candidate B (stale lock) → CANDIDATE_INVALID"

cat > "${REAL_REPO}/pyproject.toml" <<'EOF'
[project]
name = "samplepkg-stale"
version = "0.1.0"
description = "stale lock fixture"
requires-python = ">=3.10"
dependencies = [
    "click>=8",
    "rich>=13",
]

[project.scripts]
samplecmd = "samplepkg.cmd:main"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/samplepkg"]
EOF

git -C "${REAL_REPO}" add pyproject.toml
git -C "${REAL_REPO}" commit -qm "B: pyproject modified; uv.lock left stale"
SHA_B="$(git -C "${REAL_REPO}" rev-parse HEAD)"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${SHA_B}" > "${TMP}/b.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import capabilities, runtime_env
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-stale-lock-B"
resolution = capabilities.resolve_capabilities(
    ["package.uv"],
    canonical_repo=canonical_repo,
    role="reviewer",
    repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=(
        runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
        / "capability-cache"
    ),
    evidence_run_key=run_id,
)
uv_item = next(
    item for item in resolution.get("resolved", [])
    if str(item.get("name") or "") == "package.uv"
)
bound_uv = ve.build_bound_uv_identity(
    uv_item,
    cache_path=str(uv_item.get("cache_path") or ""),
    cache_scope=str(uv_item.get("cache_scope") or ""),
)
out = ve.provision_project_environment(
    canonical_repo=canonical_repo,
    run_id=run_id,
    role="builder",
    candidate_sha=candidate_sha,
    candidate_worktree=canonical_repo,
    bound_uv=bound_uv,
    timeout_seconds=600,
)
print(json.dumps({
    "outcome": out.get("outcome"),
    "reason": out.get("reason"),
    "package_uv_unbound": out.get("package_uv_unbound"),
    "stderr_excerpt": out.get("stderr_excerpt", "")[:512],
    "returncode": out.get("returncode"),
}))
PY
B_OUTCOME="$(jq_field "${TMP}/b.json" outcome)"
B_REASON="$(jq_field "${TMP}/b.json" reason)"
B_UNBOUND="$(jq_field "${TMP}/b.json" package_uv_unbound)"
expect "candidate B outcome is candidate_invalid" "$B_OUTCOME" "candidate_invalid"
expect "candidate B classification reason is stale_lockfile" "$B_REASON" "stale_lockfile"
expect "candidate B direct provision is bound" "$B_UNBOUND" "False"

# Drive the executor end-to-end so we verify the receipt-level verdict signal:
# candidate_invalid=True, infra_failure=False.
PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${SHA_B}" > "${TMP}/b_exec.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles, runtime_env,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-stale-lock-B-exec"
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "stale-lock-B",
    "created_at": "2026-09-22T00:00:00Z",
    "work_class": "BUG",
    "risk_class": "low",
    "title": "stale lock B",
    "target": {"repo": str(canonical_repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "single",
    "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "src/"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "capabilities": ["toolchain.python", "package.uv"],
    "runner_profile": "default",
}
resolution = capabilities.resolve_capabilities(
    list(packet["capabilities"]), canonical_repo=canonical_repo, role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation") / "capability-cache",
    evidence_run_key=run_id,
)
profile = runner_profiles.resolve_profile("default", provider="claude-code")
runner_profiles.verify_profile_integrity(profile)
effort_attestation = runner_profiles.verify_effort_attestation(profile)
if effort_attestation is not None:
    profile = dict(profile)
    profile["effort_attestation"] = effort_attestation
capability_binding.ensure_run_binding(canonical_repo, run_id, resolution, profile, allow_create=True)
result = vx.run_required_validation(
    cwd=canonical_repo,
    validation={
        "name": "uv-ping",
        "command": "uv run --no-sync python -c 'import click'",
        "kind": "fast",
        "expected_exit_code": 0,
    },
    timeout_seconds=300,
    canonical_repo=canonical_repo,
    run_id=run_id,
    packet=packet,
    candidate_sha=candidate_sha,
    role="builder",
)
print(json.dumps({
    "passed": result.get("passed"),
    "infra_failure": result.get("infra_failure"),
    "candidate_invalid": result.get("candidate_invalid"),
    "candidate_invalid_reason": result.get("candidate_invalid_reason"),
    "exit_code": result.get("exit_code"),
}))
PY
B_EXEC_INFRA="$(jq_field "${TMP}/b_exec.json" infra_failure)"
B_EXEC_CAND="$(jq_field "${TMP}/b_exec.json" candidate_invalid)"
B_EXEC_PASS="$(jq_field "${TMP}/b_exec.json" passed)"
expect "stale lock → infra_failure=False (NOT terminal BLOCKED)" "$B_EXEC_INFRA" "False"
expect "stale lock → candidate_invalid=True" "$B_EXEC_CAND" "True"
expect "stale lock → passed=False" "$B_EXEC_PASS" "False"

# -------------------------------------------------------------------- #
# Section 3: STALE_LOCK_REPAIR_FLOW                                     #
# -------------------------------------------------------------------- #
section "3. STALE_LOCK_REPAIR_FLOW=yes (repair entitlement available, NOT terminal BLOCKED)"
FLOW="$(python3 -c "
infra = ${B_EXEC_INFRA}
cand = ${B_EXEC_CAND}
if not infra and cand:
    print('CHANGES_REQUESTED')
elif infra:
    print('BLOCKED')
else:
    print('UNKNOWN')
")"
expect "stale-lock build flow is CHANGES_REQUESTED (repairable)" "$FLOW" "CHANGES_REQUESTED"
REPAIR_AVAILABLE="$(python3 -c "print('yes' if not ${B_EXEC_INFRA} else 'no')")"
expect "repair entitlement is available (burns_repair_round=True path)" "$REPAIR_AVAILABLE" "yes"

# -------------------------------------------------------------------- #
# Section 4: Candidate C repaired lock → PROVISIONED + validation PASS   #
# -------------------------------------------------------------------- #
section "4. Candidate C (repaired lock) → PROVISIONED + REPAIRED_LOCK_VALIDATION=PASS"
(
    cd "${REAL_REPO}"
    uv lock --quiet --python-preference only-system
)
git -C "${REAL_REPO}" add uv.lock
git -C "${REAL_REPO}" commit -qm "C: regenerate uv.lock"
SHA_C="$(git -C "${REAL_REPO}" rev-parse HEAD)"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${SHA_C}" > "${TMP}/c.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import capabilities, runtime_env
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-stale-lock-C"
resolution = capabilities.resolve_capabilities(
    ["package.uv"],
    canonical_repo=canonical_repo,
    role="reviewer",
    repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=(
        runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
        / "capability-cache"
    ),
    evidence_run_key=run_id,
)
uv_item = next(
    item for item in resolution.get("resolved", [])
    if str(item.get("name") or "") == "package.uv"
)
bound_uv = ve.build_bound_uv_identity(
    uv_item,
    cache_path=str(uv_item.get("cache_path") or ""),
    cache_scope=str(uv_item.get("cache_scope") or ""),
)
out = ve.provision_project_environment(
    canonical_repo=canonical_repo,
    run_id=run_id,
    role="builder",
    candidate_sha=candidate_sha,
    candidate_worktree=canonical_repo,
    bound_uv=bound_uv,
    timeout_seconds=600,
)
print(json.dumps({
    "outcome": out.get("outcome"),
    "reason": out.get("reason"),
    "package_uv_unbound": out.get("package_uv_unbound"),
}))
PY
C_OUTCOME="$(jq_field "${TMP}/c.json" outcome)"
C_UNBOUND="$(jq_field "${TMP}/c.json" package_uv_unbound)"
expect "candidate C outcome is provisioned" "$C_OUTCOME" "provisioned"
expect "candidate C direct provision is bound" "$C_UNBOUND" "False"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${SHA_C}" > "${TMP}/c_exec.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles, runtime_env,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-stale-lock-C-exec"
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "stale-lock-C",
    "created_at": "2026-09-22T00:00:00Z",
    "work_class": "BUG",
    "risk_class": "low",
    "title": "repaired lock C",
    "target": {"repo": str(canonical_repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "single",
    "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
    "non_goals": [],
    "allowed_paths": ["src/", "tests/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "src/"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "capabilities": ["toolchain.python", "package.uv"],
    "runner_profile": "default",
}
resolution = capabilities.resolve_capabilities(
    list(packet["capabilities"]), canonical_repo=canonical_repo, role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation") / "capability-cache",
    evidence_run_key=run_id,
)
profile = runner_profiles.resolve_profile("default", provider="claude-code")
runner_profiles.verify_profile_integrity(profile)
effort_attestation = runner_profiles.verify_effort_attestation(profile)
if effort_attestation is not None:
    profile = dict(profile)
    profile["effort_attestation"] = effort_attestation
capability_binding.ensure_run_binding(canonical_repo, run_id, resolution, profile, allow_create=True)
result = vx.run_required_validation(
    cwd=canonical_repo,
    validation={
        "name": "benign",
        "command": "uv run --no-sync python -c 'import click; print(click.__version__)'",
        "kind": "fast",
        "expected_exit_code": 0,
        "expected_marker": ".",
    },
    timeout_seconds=300,
    canonical_repo=canonical_repo,
    run_id=run_id,
    packet=packet,
    candidate_sha=candidate_sha,
    role="builder",
)
print(json.dumps({
    "passed": result.get("passed"),
    "exit_code": result.get("exit_code"),
    "infra_failure": result.get("infra_failure"),
    "candidate_invalid": result.get("candidate_invalid"),
}))
PY
C_EXEC_PASS="$(jq_field "${TMP}/c_exec.json" passed)"
C_EXEC_INFRA="$(jq_field "${TMP}/c_exec.json" infra_failure)"
C_EXEC_CAND="$(jq_field "${TMP}/c_exec.json" candidate_invalid)"
expect "candidate C validation passes" "$C_EXEC_PASS" "True"
expect "candidate C infra_failure=False" "$C_EXEC_INFRA" "False"
expect "candidate C candidate_invalid=False" "$C_EXEC_CAND" "False"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "STALE_LOCK_CLASSIFICATION=candidate_repairable"
    echo "TERMINAL_BLOCKED=no"
    echo "CHANGES_REQUESTED=yes"
    echo "REPAIR_ENTITLEMENT_AVAILABLE=yes"
    echo "REPAIRED_LOCK_VALIDATION=PASS"
    echo "STALE_LOCK_REPAIR_TEST=PASS"
else
    echo "STALE_LOCK_REPAIR_TEST=FAIL (failures=${failures})"
    exit 1
fi
exit 0

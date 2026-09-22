#!/usr/bin/env bash
# OwnFramework Loop — REAL candidate-bound uv project end-to-end.
#
# This is NOT the no-pyproject branch and NOT a fake success stub.
# It builds a real Python project (pyproject.toml + uv.lock + src/samplepkg/
# + tests/) and proves that direct deterministic provisioning and the
# production validation executor both use an explicitly frozen package.uv
# identity rather than ambient PATH authority.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

LIB_DIR="${REPO_ROOT}/lib"
export PYTHONPATH="${LIB_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
export OFLOOP_LIB="${LIB_DIR}"
export OFLOOP_ROOT="${REPO_ROOT}"

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
jq_field() {
    python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])" "$1" "$2"
}

TMP="$(mktemp -d -t ofloop-real-uv.XXXXXX)"
trap 'if [[ "${failures:-0}" -eq 0 ]]; then rm -rf "${TMP}"; else echo "DEBUG_TMP=${TMP}" >&2; fi' EXIT INT TERM HUP

REAL_REPO="${TMP}/realproj"
git init -q -b master "${REAL_REPO}"
git -C "${REAL_REPO}" config user.email "test@local"
git -C "${REAL_REPO}" config user.name "test"
echo seed > "${REAL_REPO}/README.md"

mkdir -p "${REAL_REPO}/src/samplepkg" "${REAL_REPO}/tests"
cat > "${REAL_REPO}/pyproject.toml" <<'EOF'
[project]
name = "samplepkg-real"
version = "0.1.0"
description = "real fixture for candidate-bound env"
requires-python = ">=3.10"
dependencies = ["pytest>=8"]

[project.optional-dependencies]
dev = ["pytest>=8"]

[project.scripts]
samplecmd = "samplepkg.cmd:main"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/samplepkg"]
EOF

cat > "${REAL_REPO}/src/samplepkg/__init__.py" <<'EOF'
VERSION = "0.1.0"
EOF

cat > "${REAL_REPO}/src/samplepkg/cmd.py" <<'EOF'
def main() -> int:
    print("samplecmd-from-external-env OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOF

cat > "${REAL_REPO}/tests/test_smoke.py" <<'EOF'
def test_imports():
    import samplepkg
    assert samplepkg.VERSION == "0.1.0"


def test_version_string():
    import samplepkg
    assert isinstance(samplepkg.VERSION, str)
    assert len(samplepkg.VERSION) > 0
EOF

cat > "${REAL_REPO}/.gitignore" <<'EOF'
.venv/
__pycache__/
.pytest_cache/
*.egg-info/
EOF

git -C "${REAL_REPO}" add -A
git -C "${REAL_REPO}" commit -qm "baseline: real uv project"
(
    cd "${REAL_REPO}"
    uv lock --quiet --python-preference only-system
)
git -C "${REAL_REPO}" add uv.lock
git -C "${REAL_REPO}" commit -qm "baseline: add uv.lock"

CANDIDATE_SHA="$(git -C "${REAL_REPO}" rev-parse HEAD)"
echo "CANDIDATE_SHA=${CANDIDATE_SHA}"

# -------------------------------------------------------------------- #
# Section 1: direct provisioner gets an explicit frozen uv identity     #
# -------------------------------------------------------------------- #
section "1. real bound uv sync --project <cand> --locked → PROVISIONED"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/prov.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import capabilities, runtime_env
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-real-uv-test"

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
    "provisioned": out.get("provisioned"),
    "marker_path": out.get("marker_path"),
    "identity": out.get("identity"),
    "package_uv_unbound": out.get("package_uv_unbound"),
}))
PY

OUTCOME="$(jq_field "${TMP}/prov.json" outcome)"
REASON="$(jq_field "${TMP}/prov.json" reason)"
PROVISIONED="$(jq_field "${TMP}/prov.json" provisioned)"
ENV_PATH="$(jq_field "${TMP}/prov.json" marker_path)"
IDENTITY="$(jq_field "${TMP}/prov.json" identity)"
UNBOUND="$(jq_field "${TMP}/prov.json" package_uv_unbound)"

expect "outcome is provisioned" "$OUTCOME" "provisioned"
expect "reason is uv_sync_returned_zero" "$REASON" "uv_sync_returned_zero"
expect "provisioned flag is True" "$PROVISIONED" "True"
expect "package.uv provenance is bound" "$UNBOUND" "False"
expect "env_id is non-empty 64-hex" \
    "$([ "${#IDENTITY}" -eq 64 ] && echo True || echo False)" "True"
[[ -n "${ENV_PATH}" ]] && [[ -d "${ENV_PATH}" ]] && ENV_CREATED=yes || ENV_CREATED=no
expect "external project env created under supervisor runtime cache" "$ENV_CREATED" "yes"

# -------------------------------------------------------------------- #
# Section 2: env is outside worktree                                    #
# -------------------------------------------------------------------- #
section "2. PROJECT_ENV_OUTSIDE_WORKTREE=yes"
INSIDE_CHECK="$(ENV_PATH="${ENV_PATH}" REAL_REPO="${REAL_REPO}" python3 -c "
from pathlib import Path
import os
env = Path(os.environ['ENV_PATH']).resolve()
wt = Path(os.environ['REAL_REPO']).resolve()
try:
    env.relative_to(wt)
    print('inside')
except ValueError:
    print('outside')
")"
expect "env_dir is OUTSIDE the candidate worktree" "$INSIDE_CHECK" "outside"

# -------------------------------------------------------------------- #
# Section 3: production executor performs bound pytest validation       #
# -------------------------------------------------------------------- #
section "3. production executor: uv run --no-sync pytest -q"
if command -v pytest >/dev/null 2>&1; then
    GLOBAL_PYTEST_FOUND="$(command -v pytest)"
else
    GLOBAL_PYTEST_FOUND=""
fi
expect "GLOBAL_PYTEST_REQUIRED=no" "$([ -z "${GLOBAL_PYTEST_FOUND}" ] && echo no || echo yes)" "no"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/pytest.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles, runtime_env,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-real-uv-executor-pytest"
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "real-uv-pytest",
    "created_at": "2026-09-22T00:00:00Z",
    "work_class": "NEW_REPOSITORY",
    "risk_class": "low",
    "title": "real uv run pytest",
    "target": {"repo": str(canonical_repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "single",
    "acceptance_criteria": [{"id": "AC-1", "text": "pytest passes"}],
    "non_goals": [],
    "allowed_paths": ["src/", "tests/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "src/,tests/"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "capabilities": ["toolchain.python", "package.uv"],
    "runner_profile": "default",
}
resolution = capabilities.resolve_capabilities(
    list(packet["capabilities"]),
    canonical_repo=canonical_repo,
    role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=(
        runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
        / "capability-cache"
    ),
    evidence_run_key=run_id,
)
profile = runner_profiles.resolve_profile("default", provider="claude-code")
runner_profiles.verify_profile_integrity(profile)
effort = runner_profiles.verify_effort_attestation(profile)
if effort is not None:
    profile = dict(profile)
    profile["effort_attestation"] = effort
capability_binding.ensure_run_binding(
    canonical_repo, run_id, resolution, profile, allow_create=True
)
result = vx.run_required_validation(
    cwd=canonical_repo,
    validation={
        "name": "pytest",
        "command": "uv run --no-sync pytest -q",
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
    "exit_code": result.get("exit_code"),
    "infra_failure": result.get("infra_failure"),
    "candidate_invalid": result.get("candidate_invalid"),
}))
PY

expect "uv run --no-sync pytest → passed" "$(jq_field "${TMP}/pytest.json" passed)" "True"
expect "uv run --no-sync pytest → exit_code=0" "$(jq_field "${TMP}/pytest.json" exit_code)" "0"
expect "uv run --no-sync pytest → infra_failure=False" "$(jq_field "${TMP}/pytest.json" infra_failure)" "False"
expect "uv run --no-sync pytest → candidate_invalid=False" "$(jq_field "${TMP}/pytest.json" candidate_invalid)" "False"

# -------------------------------------------------------------------- #
# Section 4: production executor performs bound console-script run      #
# -------------------------------------------------------------------- #
section "4. production executor: uv run --no-sync samplecmd"
if command -v samplecmd >/dev/null 2>&1; then
    GLOBAL_SAMPLECMD_FOUND="$(command -v samplecmd)"
else
    GLOBAL_SAMPLECMD_FOUND=""
fi
expect "GLOBAL_SAMPLECMD_REQUIRED=no" "$([ -z "${GLOBAL_SAMPLECMD_FOUND}" ] && echo no || echo yes)" "no"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/cmd.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles, runtime_env,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-real-uv-executor-cmd"
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "real-uv-samplecmd",
    "created_at": "2026-09-22T00:00:00Z",
    "work_class": "NEW_REPOSITORY",
    "risk_class": "low",
    "title": "real uv run samplecmd",
    "target": {"repo": str(canonical_repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "single",
    "acceptance_criteria": [{"id": "AC-1", "text": "samplecmd runs"}],
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
    list(packet["capabilities"]),
    canonical_repo=canonical_repo,
    role="builder",
    repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=(
        runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
        / "capability-cache"
    ),
    evidence_run_key=run_id,
)
profile = runner_profiles.resolve_profile("default", provider="claude-code")
runner_profiles.verify_profile_integrity(profile)
effort = runner_profiles.verify_effort_attestation(profile)
if effort is not None:
    profile = dict(profile)
    profile["effort_attestation"] = effort
capability_binding.ensure_run_binding(
    canonical_repo, run_id, resolution, profile, allow_create=True
)
result = vx.run_required_validation(
    cwd=canonical_repo,
    validation={
        "name": "samplecmd",
        "command": "uv run --no-sync samplecmd",
        "kind": "fast",
        "expected_exit_code": 0,
        "expected_marker": "samplecmd-from-external-env OK",
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
    "marker_match": result.get("marker_match"),
    "infra_failure": result.get("infra_failure"),
}))
PY

expect "uv run --no-sync samplecmd → passed" "$(jq_field "${TMP}/cmd.json" passed)" "True"
expect "uv run --no-sync samplecmd → exit_code=0" "$(jq_field "${TMP}/cmd.json" exit_code)" "0"
expect "uv run --no-sync samplecmd → marker_match=True" "$(jq_field "${TMP}/cmd.json" marker_match)" "True"
expect "uv run --no-sync samplecmd → infra_failure=False" "$(jq_field "${TMP}/cmd.json" infra_failure)" "False"

# -------------------------------------------------------------------- #
# Section 5: worktree remains immutable                                 #
# -------------------------------------------------------------------- #
section "5. WORKTREE_DOT_VENV_CREATED=no"
[[ -e "${REAL_REPO}/.venv" ]] && VENV_IN_WORKTREE=yes || VENV_IN_WORKTREE=no
expect "WORKTREE_DOT_VENV_CREATED=no" "$VENV_IN_WORKTREE" "no"

# -------------------------------------------------------------------- #
# Section 6: direct builder/reviewer provisioning uses same binding     #
# -------------------------------------------------------------------- #
section "6. BUILDER_ENV_PROVISION + REVIEWER_ENV_PROVISION + parity"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/parity.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import capabilities, runtime_env
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-real-uv-test"
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
b = ve.provision_project_environment(
    canonical_repo=canonical_repo,
    run_id=run_id,
    role="builder",
    candidate_sha=candidate_sha,
    candidate_worktree=canonical_repo,
    bound_uv=bound_uv,
    timeout_seconds=600,
)
r = ve.provision_project_environment(
    canonical_repo=canonical_repo,
    run_id=run_id,
    role="reviewer",
    candidate_sha=candidate_sha,
    candidate_worktree=canonical_repo,
    bound_uv=bound_uv,
    timeout_seconds=600,
)
print(json.dumps({
    "builder_outcome": b.get("outcome"),
    "reviewer_outcome": r.get("outcome"),
    "isolated": b.get("marker_path") != r.get("marker_path"),
    "same_id": b.get("identity") == r.get("identity"),
    "builder_unbound": b.get("package_uv_unbound"),
    "reviewer_unbound": r.get("package_uv_unbound"),
}))
PY

expect "BUILDER_ENV_PROVISION=PASS (outcome=provisioned)" "$(jq_field "${TMP}/parity.json" builder_outcome)" "provisioned"
expect "REVIEWER_ENV_PROVISION=PASS (outcome=provisioned)" "$(jq_field "${TMP}/parity.json" reviewer_outcome)" "provisioned"
expect "builder/reviewer envs are isolated (different paths)" "$(jq_field "${TMP}/parity.json" isolated)" "True"
expect "builder/reviewer env_ids match (same candidate metadata)" "$(jq_field "${TMP}/parity.json" same_id)" "True"
expect "builder direct provision is bound" "$(jq_field "${TMP}/parity.json" builder_unbound)" "False"
expect "reviewer direct provision is bound" "$(jq_field "${TMP}/parity.json" reviewer_unbound)" "False"

# Production executor parity for both roles.
PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/parity_exec.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles, runtime_env,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]

def make_packet() -> dict:
    return {
        "schema": "ownframework-work-packet/v3",
        "packet_id": "parity-test",
        "created_at": "2026-09-22T00:00:00Z",
        "work_class": "NEW_REPOSITORY",
        "risk_class": "low",
        "title": "parity",
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

def seal(run_id: str, role: str) -> None:
    resolution = capabilities.resolve_capabilities(
        ["toolchain.python", "package.uv"],
        canonical_repo=canonical_repo,
        role=role,
        repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
        ephemeral_cache_root=(
            runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
            / "capability-cache"
        ),
        evidence_run_key=run_id,
    )
    profile = runner_profiles.resolve_profile("default", provider="claude-code")
    runner_profiles.verify_profile_integrity(profile)
    effort = runner_profiles.verify_effort_attestation(profile)
    if effort is not None:
        profile = dict(profile)
        profile["effort_attestation"] = effort
    capability_binding.ensure_run_binding(
        canonical_repo, run_id, resolution, profile, allow_create=True
    )

run_id_b = "run-2026-real-uv-parity-b"
run_id_r = "run-2026-real-uv-parity-r"
seal(run_id_b, "builder")
seal(run_id_r, "reviewer")
validation = {
    "name": "samplecmd",
    "command": "uv run --no-sync samplecmd",
    "kind": "fast",
    "expected_exit_code": 0,
    "expected_marker": "samplecmd-from-external-env OK",
}
b = vx.run_required_validation(
    cwd=canonical_repo,
    validation=validation,
    timeout_seconds=300,
    canonical_repo=canonical_repo,
    run_id=run_id_b,
    packet=make_packet(),
    candidate_sha=candidate_sha,
    role="builder",
)
r = vx.run_required_validation(
    cwd=canonical_repo,
    validation=validation,
    timeout_seconds=300,
    canonical_repo=canonical_repo,
    run_id=run_id_r,
    packet=make_packet(),
    candidate_sha=candidate_sha,
    role="reviewer",
)
print(json.dumps({
    "builder_passed": b.get("passed"),
    "reviewer_passed": r.get("passed"),
    "parity": (
        b.get("passed") == r.get("passed")
        and not b.get("infra_failure")
        and not r.get("infra_failure")
    ),
}))
PY

expect "BUILDER_VALIDATION=PASS" "$(jq_field "${TMP}/parity_exec.json" builder_passed)" "True"
expect "REVIEWER_VALIDATION=PASS" "$(jq_field "${TMP}/parity_exec.json" reviewer_passed)" "True"
expect "BUILDER_REVIEWER_SEMANTIC_PARITY=PASS" "$(jq_field "${TMP}/parity_exec.json" parity)" "True"

# -------------------------------------------------------------------- #
# Section 7: no validator pollution                                     #
# -------------------------------------------------------------------- #
section "7. REVIEWER_WORKTREE_DIRTY=no"
if [[ -e "${REAL_REPO}/.venv" ]] || [[ -e "${REAL_REPO}/__pycache__" ]]; then
    REVIEWER_DIRTY=yes
else
    REVIEWER_DIRTY=no
fi
expect "REVIEWER_WORKTREE_DIRTY=no" "$REVIEWER_DIRTY" "no"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "REAL_UV_SYNC=PASS"
    echo "EXTERNAL_PROJECT_ENV_CREATED=yes"
    echo "PROJECT_ENV_OUTSIDE_WORKTREE=yes"
    echo "PYTEST_FROM_EXTERNAL_ENV=yes"
    echo "CONSOLE_SCRIPT_FROM_EXTERNAL_ENV=yes"
    echo "GLOBAL_PYTEST_REQUIRED=no"
    echo "GLOBAL_SAMPLECMD_REQUIRED=no"
    echo "WORKTREE_DOT_VENV_CREATED=no"
    echo "REVIEWER_WORKTREE_DIRTY=no"
    echo "BUILDER_ENV_PROVISION=PASS"
    echo "REVIEWER_ENV_PROVISION=PASS"
    echo "BUILDER_REVIEWER_SEMANTIC_PARITY=PASS"
    echo "REAL_UV_PROJECT_ENV_TEST=PASS"
else
    echo "REAL_UV_PROJECT_ENV_TEST=FAIL (failures=${failures})"
    exit 1
fi
exit 0

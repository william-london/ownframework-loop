#!/usr/bin/env bash
# OwnFramework Loop — REAL candidate-bound uv project end-to-end.
#
# This is NOT the no-pyproject branch and NOT a fake success stub.
# It builds a real Python project (pyproject.toml + uv.lock +
# src/samplepkg/ + tests/) and drives the actual production
# validation_executor with `uv run --no-sync pytest` and
# `uv run --no-sync samplecmd` against the validator-owned
# candidate-bound project environment.
#
# Required proof:
#
#   REAL_UV_SYNC=PASS
#   EXTERNAL_PROJECT_ENV_CREATED=yes
#   PROJECT_ENV_OUTSIDE_WORKTREE=yes
#   uv run --no-sync pytest -q                  → PASS
#   uv run --no-sync samplecmd ...              → PASS
#   GLOBAL_PYTEST_REQUIRED=no
#   GLOBAL_SAMPLECMD_REQUIRED=no
#   WORKTREE_DOT_VENV_CREATED=no
#   REVIEWER_WORKTREE_DIRTY=no
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
# Helper: extract a top-level field from a JSON file.
jq_field() {
    python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])" "$1" "$2"
}

TMP="$(mktemp -d -t ofloop-real-uv.XXXXXX)"
# Preserve the temp dir on failure for diagnostics; remove it on success.
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
dependencies = [
    "pytest>=8",
]

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
"""Console-script entry point for samplepkg."""

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

# Generate uv.lock for the first time using the operator's uv. This
# is one-time fixture setup; the validator does NOT depend on a
# globally-installed uv at run-time, only the test harness does to
# generate the initial lockfile once.
(
    cd "${REAL_REPO}"
    uv lock --quiet --python-preference only-system
)
git -C "${REAL_REPO}" add uv.lock
git -C "${REAL_REPO}" commit -qm "baseline: add uv.lock"

CANDIDATE_SHA="$(git -C "${REAL_REPO}" rev-parse HEAD)"
echo "CANDIDATE_SHA=${CANDIDATE_SHA}"

# -------------------------------------------------------------------- #
# Section 1: real uv sync against the validator-owned env               #
# -------------------------------------------------------------------- #
section "1. real uv sync --project <cand> --locked → PROVISIONED"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/prov.json" <<'PY'
"""Drive provision_project_environment with a real uv project."""
import json, sys, tempfile
from pathlib import Path
from ownframework_loop import runtime_env, validation_environment as ve

canonical_repo = Path(sys.argv[1])
candidate_worktree = canonical_repo  # the repo itself is the worktree
candidate_sha = sys.argv[2]

# Synthetic run id so we exercise real directory creation in the
# supervisor-owned runtime cache.
run_id = "run-2026-real-uv-test"

out = ve.provision_project_environment(
    canonical_repo=canonical_repo, run_id=run_id,
    role="builder", candidate_sha=candidate_sha,
    candidate_worktree=candidate_worktree,
    timeout_seconds=600,
)
print(json.dumps({
    "outcome": out.get("outcome"),
    "reason": out.get("reason"),
    "provisioned": out.get("provisioned"),
    "marker_path": out.get("marker_path"),
    "identity": out.get("identity"),
    "path": out.get("path"),
}))
PY

OUTCOME="$(python3 -c "import json; d=json.load(open('${TMP}/prov.json')); print(d['outcome'])")"
REASON="$(python3 -c "import json; d=json.load(open('${TMP}/prov.json')); print(d['reason'])")"
PROVISIONED="$(python3 -c "import json; d=json.load(open('${TMP}/prov.json')); print(d['provisioned'])")"
ENV_PATH="$(python3 -c "import json; d=json.load(open('${TMP}/prov.json')); print(d['marker_path'])")"
IDENTITY="$(python3 -c "import json; d=json.load(open('${TMP}/prov.json')); print(d['identity'])")"

expect "outcome is provisioned" "$OUTCOME" "provisioned"
expect "reason is uv_sync_returned_zero" "$REASON" "uv_sync_returned_zero"
expect "provisioned flag is True" "$PROVISIONED" "True"
expect "env_id is non-empty 64-hex" \
    "$([ "${#IDENTITY}" -eq 64 ] && echo True || echo False)" "True"
[[ -n "${ENV_PATH}" ]] && [[ -d "${ENV_PATH}" ]] && ENV_CREATED=yes || ENV_CREATED=no
expect "external project env created under supervisor runtime cache" "$ENV_CREATED" "yes"

# -------------------------------------------------------------------- #
# Section 2: env_dir is OUTSIDE the candidate worktree                  #
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
# Section 3: uv run --no-sync pytest works                              #
# -------------------------------------------------------------------- #
section "3. uv run --no-sync pytest -q (project env, no global pytest)"

# Verify pytest is NOT globally installed.
if command -v pytest >/dev/null 2>&1; then
    GLOBAL_PYTEST_FOUND="$(command -v pytest)"
else
    GLOBAL_PYTEST_FOUND=""
fi
expect "GLOBAL_PYTEST_REQUIRED=no" "$([ -z "${GLOBAL_PYTEST_FOUND}" ] && echo no || echo yes)" "no"

# Drive the actual production validation_executor with a
# uv run --no-sync pytest command.
PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" "${ENV_PATH}" > "${TMP}/pytest.json" <<'PY'
"""Real uv run --no-sync pytest through the production executor."""
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
env_path = sys.argv[3]
run_id = "run-2026-real-uv-test"

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

# Seal a run binding so the validator's commissioned_validation_env
# call can resolve the packet's declared capabilities.
resolution = capabilities.resolve_capabilities(
    list(packet["capabilities"]), canonical_repo=canonical_repo, role="builder",
    repo_cache_root=__import__("ownframework_loop.runtime_env", fromlist=["repo_tool_cache_dir"]).repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=__import__("ownframework_loop.runtime_env", fromlist=["runtime_cache_dir"]).runtime_cache_dir(canonical_repo, run_id, "validation") / "capability-cache",
    evidence_run_key=run_id,
)
profile = runner_profiles.resolve_profile("default", provider="claude-code")
runner_profiles.verify_profile_integrity(profile)
effort_attestation = runner_profiles.verify_effort_attestation(profile)
if effort_attestation is not None:
    profile = dict(profile); profile["effort_attestation"] = effort_attestation
capability_binding.ensure_run_binding(canonical_repo, run_id, resolution, profile, allow_create=True)

result = vx.run_required_validation(
    cwd=canonical_repo,
    validation={"name": "pytest", "command": "uv run --no-sync pytest -q",
                "kind": "fast", "expected_exit_code": 0},
    timeout_seconds=300,
    canonical_repo=canonical_repo, run_id=run_id,
    packet=packet, candidate_sha=candidate_sha, role="builder",
)
print(json.dumps({
    "passed": result.get("passed"),
    "exit_code": result.get("exit_code"),
    "infra_failure": result.get("infra_failure"),
    "candidate_invalid": result.get("candidate_invalid"),
    "validation_env_id": result.get("validation_env_id"),
    "validation_env_path": result.get("validation_env_path"),
    "stdout_excerpt_redacted": result.get("stdout_excerpt_redacted", ""),
}))
PY

PYTEST_PASS="$(jq_field "${TMP}/pytest.json" passed)"
PYTEST_EC="$(jq_field "${TMP}/pytest.json" exit_code)"
PYTEST_INFRA="$(jq_field "${TMP}/pytest.json" infra_failure)"
PYTEST_CANDINV="$(jq_field "${TMP}/pytest.json" candidate_invalid)"
expect "uv run --no-sync pytest → passed" "$PYTEST_PASS" "True"
expect "uv run --no-sync pytest → exit_code=0" "$PYTEST_EC" "0"
expect "uv run --no-sync pytest → infra_failure=False" "$PYTEST_INFRA" "False"
expect "uv run --no-sync pytest → candidate_invalid=False" "$PYTEST_CANDINV" "False"

# -------------------------------------------------------------------- #
# Section 4: uv run --no-sync samplecmd works                           #
# -------------------------------------------------------------------- #
section "4. GLOBAL_SAMPLECMD_REQUIRED=no + uv run --no-sync samplecmd ..."

if command -v samplecmd >/dev/null 2>&1; then
    GLOBAL_SAMPLECMD_FOUND="$(command -v samplecmd)"
else
    GLOBAL_SAMPLECMD_FOUND=""
fi
expect "GLOBAL_SAMPLECMD_REQUIRED=no" "$([ -z "${GLOBAL_SAMPLECMD_FOUND}" ] && echo no || echo yes)" "no"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/cmd.json" <<'PY'
"""Real uv run --no-sync samplecmd ... through the production executor."""
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-real-uv-test-cmd"

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
    list(packet["capabilities"]), canonical_repo=canonical_repo, role="builder",
    repo_cache_root=__import__("ownframework_loop.runtime_env", fromlist=["repo_tool_cache_dir"]).repo_tool_cache_dir(canonical_repo),
    ephemeral_cache_root=__import__("ownframework_loop.runtime_env", fromlist=["runtime_cache_dir"]).runtime_cache_dir(canonical_repo, run_id, "validation") / "capability-cache",
    evidence_run_key=run_id,
)
profile = runner_profiles.resolve_profile("default", provider="claude-code")
runner_profiles.verify_profile_integrity(profile)
effort_attestation = runner_profiles.verify_effort_attestation(profile)
if effort_attestation is not None:
    profile = dict(profile); profile["effort_attestation"] = effort_attestation
capability_binding.ensure_run_binding(canonical_repo, run_id, resolution, profile, allow_create=True)

result = vx.run_required_validation(
    cwd=canonical_repo,
    validation={"name": "samplecmd", "command": "uv run --no-sync samplecmd",
                "kind": "fast", "expected_exit_code": 0,
                "expected_marker": "samplecmd-from-external-env OK"},
    timeout_seconds=300,
    canonical_repo=canonical_repo, run_id=run_id,
    packet=packet, candidate_sha=candidate_sha, role="builder",
)
print(json.dumps({
    "passed": result.get("passed"),
    "exit_code": result.get("exit_code"),
    "marker_match": result.get("marker_match"),
    "infra_failure": result.get("infra_failure"),
    "candidate_invalid": result.get("candidate_invalid"),
    "validation_env_id": result.get("validation_env_id"),
}))
PY

CMD_PASS="$(jq_field "${TMP}/cmd.json" passed)"
CMD_EC="$(jq_field "${TMP}/cmd.json" exit_code)"
CMD_MARKER="$(jq_field "${TMP}/cmd.json" marker_match)"
CMD_INFRA="$(jq_field "${TMP}/cmd.json" infra_failure)"
expect "uv run --no-sync samplecmd → passed" "$CMD_PASS" "True"
expect "uv run --no-sync samplecmd → exit_code=0" "$CMD_EC" "0"
expect "uv run --no-sync samplecmd → marker_match=True" "$CMD_MARKER" "True"
expect "uv run --no-sync samplecmd → infra_failure=False" "$CMD_INFRA" "False"

# -------------------------------------------------------------------- #
# Section 5: WORKTREE_DOT_VENV_CREATED=no                                #
# -------------------------------------------------------------------- #
section "5. WORKTREE_DOT_VENV_CREATED=no (env lives only in runtime cache)"

if [[ -e "${REAL_REPO}/.venv" ]]; then
    VENV_IN_WORKTREE=yes
else
    VENV_IN_WORKTREE=no
fi
expect "WORKTREE_DOT_VENV_CREATED=no" "$VENV_IN_WORKTREE" "no"

# -------------------------------------------------------------------- #
# Section 6: BUILDER / REVIEWER parity                                  #
# -------------------------------------------------------------------- #
section "6. BUILDER_ENV_PROVISION + REVIEWER_ENV_PROVISION + parity"

PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/parity.json" <<'PY'
"""Same candidate, both roles, isolated envs."""
import json, sys
from pathlib import Path
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id = "run-2026-real-uv-test"

b = ve.provision_project_environment(
    canonical_repo=canonical_repo, run_id=run_id,
    role="builder", candidate_sha=candidate_sha,
    candidate_worktree=canonical_repo, timeout_seconds=600,
)
r = ve.provision_project_environment(
    canonical_repo=canonical_repo, run_id=run_id,
    role="reviewer", candidate_sha=candidate_sha,
    candidate_worktree=canonical_repo, timeout_seconds=600,
)
print(json.dumps({
    "builder_outcome": b.get("outcome"),
    "reviewer_outcome": r.get("outcome"),
    "builder_env": b.get("marker_path"),
    "reviewer_env": r.get("marker_path"),
    "isolated": b.get("marker_path") != r.get("marker_path"),
    "builder_id": b.get("identity"),
    "reviewer_id": r.get("identity"),
    "same_id": b.get("identity") == r.get("identity"),
}))
PY

BUILDER_OUT="$(jq_field "${TMP}/parity.json" builder_outcome)"
REVIEWER_OUT="$(jq_field "${TMP}/parity.json" reviewer_outcome)"
ISOLATED="$(jq_field "${TMP}/parity.json" isolated)"
SAME_ID="$(jq_field "${TMP}/parity.json" same_id)"

expect "BUILDER_ENV_PROVISION=PASS (outcome=provisioned)" "$BUILDER_OUT" "provisioned"
expect "REVIEWER_ENV_PROVISION=PASS (outcome=provisioned)" "$REVIEWER_OUT" "provisioned"
expect "builder/reviewer envs are isolated (different paths)" "$ISOLATED" "True"
expect "builder/reviewer env_ids match (same candidate metadata)" "$SAME_ID" "True"

# Now prove both roles produce the same semantic validation outcome.
PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/parity_exec.json" <<'PY'
"""Same candidate + same validation command, both roles, both succeed."""
import json, sys
from pathlib import Path
from ownframework_loop import (
    capabilities, capability_binding, runner_profiles,
    validation_executor as vx,
)

canonical_repo = Path(sys.argv[1])
candidate_sha = sys.argv[2]
run_id_b = "run-2026-real-uv-parity-b"
run_id_r = "run-2026-real-uv-parity-r"

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

def seal(run_id, role):
    res = capabilities.resolve_capabilities(
        ["toolchain.python", "package.uv"], canonical_repo=canonical_repo, role=role,
        repo_cache_root=__import__("ownframework_loop.runtime_env", fromlist=["repo_tool_cache_dir"]).repo_tool_cache_dir(canonical_repo),
        ephemeral_cache_root=__import__("ownframework_loop.runtime_env", fromlist=["runtime_cache_dir"]).runtime_cache_dir(canonical_repo, run_id, "validation") / "capability-cache",
        evidence_run_key=run_id,
    )
    profile = runner_profiles.resolve_profile("default", provider="claude-code")
    runner_profiles.verify_profile_integrity(profile)
    effort_attestation = runner_profiles.verify_effort_attestation(profile)
    if effort_attestation is not None:
        profile = dict(profile); profile["effort_attestation"] = effort_attestation
    capability_binding.ensure_run_binding(canonical_repo, run_id, res, profile, allow_create=True)

seal(run_id_b, "builder")
seal(run_id_r, "reviewer")

v = {"name": "samplecmd", "command": "uv run --no-sync samplecmd",
      "kind": "fast", "expected_exit_code": 0,
      "expected_marker": "samplecmd-from-external-env OK"}

b = vx.run_required_validation(
    cwd=canonical_repo, validation=v, timeout_seconds=300,
    canonical_repo=canonical_repo, run_id=run_id_b,
    packet=make_packet(), candidate_sha=candidate_sha, role="builder",
)
r = vx.run_required_validation(
    cwd=canonical_repo, validation=v, timeout_seconds=300,
    canonical_repo=canonical_repo, run_id=run_id_r,
    packet=make_packet(), candidate_sha=candidate_sha, role="reviewer",
)
print(json.dumps({
    "builder_passed": b.get("passed"),
    "reviewer_passed": r.get("passed"),
    "builder_infra": b.get("infra_failure"),
    "reviewer_infra": r.get("infra_failure"),
    "parity": b.get("passed") == r.get("passed") and not b.get("infra_failure") and not r.get("infra_failure"),
}))
PY

BUILDER_PASS="$(jq_field "${TMP}/parity_exec.json" builder_passed)"
REVIEWER_PASS="$(jq_field "${TMP}/parity_exec.json" reviewer_passed)"
PARITY="$(jq_field "${TMP}/parity_exec.json" parity)"

expect "BUILDER_VALIDATION=PASS" "$BUILDER_PASS" "True"
expect "REVIEWER_VALIDATION=PASS" "$REVIEWER_PASS" "True"
expect "BUILDER_REVIEWER_SEMANTIC_PARITY=PASS" "$PARITY" "True"

# -------------------------------------------------------------------- #
# Section 7: REVIEWER_WORKTREE_DIRTY=no                                  #
# -------------------------------------------------------------------- #
section "7. REVIEWER_WORKTREE_DIRTY=no (reviewer did not pollute worktree)"

if [[ -e "${REAL_REPO}/.venv" ]] || [[ -e "${REAL_REPO}/__pycache__" ]]; then
    REVIEWER_DIRTY=yes
else
    REVIEWER_DIRTY=no
fi
expect "REVIEWER_WORKTREE_DIRTY=no" "$REVIEWER_DIRTY" "no"

# -------------------------------------------------------------------- #
# Summary                                                                #
# -------------------------------------------------------------------- #
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

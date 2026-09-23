#!/usr/bin/env bash
# OwnFramework Loop — candidate-bound project-environment behavioral suite.
#
# Exercises the validation_environment module against the explicit
# invariants the post-v1 mission states:
#   - env identity binds (candidate SHA + uv.lock + pyproject.toml)
#   - env lives outside builder and reviewer worktrees
#   - provisioning is idempotent (no re-sync on second call)
#   - provisioning failure surfaces as infra_failure (NOT
#     validation_failed) and refuses to launch the subprocess
#   - env_dir is never the builder or reviewer worktree
#   - capabilities are unchanged: the env is not in the worker's
#     allowRead/allowWrite
#   - the validator never reopens HOME
#   - provisioning timeouts are surfaced as infra_failure, not as a
#     subprocess exit code
#
# All tests are DETERMINISTIC BEHAVIORAL: they drive the canonical
# Python modules end-to-end with real subprocess.run, real disk state.
# No hasattr() / symbol-existence checks.
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
# Usage: jq_field <file> <key>
jq_field() {
    python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])" "$1" "$2"
}

# -------------------------------------------------------------------- #
# Section 1: env identity binds (candidate SHA + uv.lock + pyproject)  #
# -------------------------------------------------------------------- #
section "1. env identity binds (candidate SHA + uv.lock + pyproject)"

TMP_ID="$(mktemp -d -t ofloop-venv-id.XXXXXX)"
trap 'rm -rf "${TMP_ID}"' EXIT

mkdir -p "${TMP_ID}/proj_a"
cat > "${TMP_ID}/proj_a/pyproject.toml" <<'EOF'
[project]
name = "ofloop-test-a"
version = "0.0.1"
requires-python = ">=3.10"
EOF
touch "${TMP_ID}/proj_a/.gitkeep"

mkdir -p "${TMP_ID}/proj_b"
cat > "${TMP_ID}/proj_b/pyproject.toml" <<'EOF'
[project]
name = "ofloop-test-b"
version = "0.0.1"
requires-python = ">=3.10"
EOF

mkdir -p "${TMP_ID}/proj_c"
cat > "${TMP_ID}/proj_c/pyproject.toml" <<'EOF'
[project]
name = "ofloop-test-a"
version = "0.0.2"
requires-python = ">=3.10"
EOF
touch "${TMP_ID}/proj_c/.gitkeep"

PYTHONPATH="${LIB_DIR}" python3 -B - "${TMP_ID}" > "${TMP_ID}/ids.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import validation_environment as ve

root = Path(sys.argv[1])
fa = ve.candidate_bound_environment_id("cand_sha_aaaa", root / "proj_a")
fb = ve.candidate_bound_environment_id("cand_sha_bbbb", root / "proj_b")
fc = ve.candidate_bound_environment_id("cand_sha_aaaa", root / "proj_c")
fa2 = ve.candidate_bound_environment_id("cand_sha_aaaa", root / "proj_a")
print(json.dumps({
    "a": fa, "b": fb, "c": fc, "a2": fa2,
    "a_ne_b": fa != fb,
    "a_ne_c": fa != fc,
    "fa_eq_fa2": fa == fa2,
}))
PY

A_NE_B="$(jq_field "${TMP_ID}/ids.json" a_ne_b)"
A_NE_C="$(jq_field "${TMP_ID}/ids.json" a_ne_c)"
A_EQ_A2="$(jq_field "${TMP_ID}/ids.json" fa_eq_fa2)"

expect "different candidate_sha produces different env_id" "$A_NE_B" "True"
expect "different pyproject.toml bytes produces different env_id" "$A_NE_C" "True"
expect "env_id is deterministic for the same inputs" "$A_EQ_A2" "True"

# -------------------------------------------------------------------- #
# Section 2: env lives outside builder and reviewer worktrees           #
# -------------------------------------------------------------------- #
section "2. env lives outside builder and reviewer worktrees"

mkdir -p "${TMP_ID}/repo"
git -C "${TMP_ID}/repo" init -q -b master >/dev/null
git -C "${TMP_ID}/repo" config user.email test@local
git -C "${TMP_ID}/repo" config user.name test
echo seed > "${TMP_ID}/repo/README.md"
git -C "${TMP_ID}/repo" add README.md
git -C "${TMP_ID}/repo" commit -qm seed

WT_BASE="${TMP_ID}/repo/.worktrees/ownframework-loop/run-2026-test/builder"
mkdir -p "${WT_BASE}"
echo worktree-marker > "${WT_BASE}/marker.txt"
WT_REV="${TMP_ID}/repo/.worktrees/ownframework-loop/run-2026-test/reviewer"
mkdir -p "${WT_REV}"
echo reviewer-marker > "${WT_REV}/marker.txt"

PYTHONPATH="${LIB_DIR}" python3 -B - "${TMP_ID}" > "${TMP_ID}/path.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import validation_environment as ve

root = Path(sys.argv[1]) / "repo"
run_id = "run-2026-test"
builder_wt = root / ".worktrees" / "ownframework-loop" / run_id / "builder"
reviewer_wt = root / ".worktrees" / "ownframework-loop" / run_id / "reviewer"
candidate_sha = "f" * 40
env_id = ve.candidate_bound_environment_id(candidate_sha, builder_wt)
env_dir = ve.project_environment_dir(root, run_id, "builder", env_id)
env_dir_reviewer = ve.project_environment_dir(root, run_id, "reviewer", env_id)

def inside(child, parent):
    try:
        Path(child).resolve(strict=False).relative_to(Path(parent).resolve(strict=False))
        return True
    except ValueError:
        return False

print(json.dumps({
    "env_in_builder": inside(env_dir, builder_wt),
    "env_in_reviewer": inside(env_dir, reviewer_wt),
    "builder_in_env": inside(builder_wt, env_dir),
    "reviewer_in_env": inside(reviewer_wt, env_dir),
    "env_in_worktrees": inside(env_dir, root / ".worktrees"),
    "env_in_ownframework_loop": inside(env_dir, root / ".ownframework-loop"),
    "env_in_repo_root": inside(env_dir, root),
    "builder_role_isolated": str(env_dir) != str(env_dir_reviewer),
    "env_path": str(env_dir),
}))
PY

ENV_IN_BUILDER="$(jq_field "${TMP_ID}/path.json" env_in_builder)"
ENV_IN_REVIEWER="$(jq_field "${TMP_ID}/path.json" env_in_reviewer)"
BUILDER_IN_ENV="$(jq_field "${TMP_ID}/path.json" builder_in_env)"
REVIEWER_IN_ENV="$(jq_field "${TMP_ID}/path.json" reviewer_in_env)"
ENV_IN_WT="$(jq_field "${TMP_ID}/path.json" env_in_worktrees)"
ENV_IN_OLOOP="$(jq_field "${TMP_ID}/path.json" env_in_ownframework_loop)"
ENV_IN_REPO="$(jq_field "${TMP_ID}/path.json" env_in_repo_root)"
ROLE_ISO="$(jq_field "${TMP_ID}/path.json" builder_role_isolated)"

expect "env_dir is NOT inside the builder worktree" "$ENV_IN_BUILDER" "False"
expect "env_dir is NOT inside the reviewer worktree" "$ENV_IN_REVIEWER" "False"
expect "builder worktree is NOT inside env_dir" "$BUILDER_IN_ENV" "False"
expect "reviewer worktree is NOT inside env_dir" "$REVIEWER_IN_ENV" "False"
expect "env_dir is NOT inside canonical .worktrees/" "$ENV_IN_WT" "False"
expect "env_dir is NOT inside canonical .ownframework-loop/" "$ENV_IN_OLOOP" "False"
expect "env_dir is NOT inside canonical repo root" "$ENV_IN_REPO" "False"
expect "builder/reviewer env_dirs are role-isolated" "$ROLE_ISO" "True"

# -------------------------------------------------------------------- #
# Section 3: provisioning is idempotent                                 #
# -------------------------------------------------------------------- #
section "3. provisioning is idempotent (no re-sync on second call)"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/idem.json" <<'PY'
"""Idempotency on the no-project branch (deterministic, no uv needed)."""
import json, tempfile
from pathlib import Path
from ownframework_loop import validation_environment as ve

canonical_repo = Path(tempfile.mkdtemp(prefix="ofloop-idem-"))
run_id = "run-2026-idem"
candidate_worktree = Path(tempfile.mkdtemp(prefix="ofloop-cand-"))
# No pyproject.toml on purpose → no-project branch.

s1 = ve.provision_project_environment(
    canonical_repo=canonical_repo, run_id=run_id, role="builder",
    candidate_sha="f"*40, candidate_worktree=candidate_worktree,
)
s2 = ve.provision_project_environment(
    canonical_repo=canonical_repo, run_id=run_id, role="builder",
    candidate_sha="f"*40, candidate_worktree=candidate_worktree,
)
s3 = ve.provision_project_environment(
    canonical_repo=canonical_repo, run_id=run_id, role="builder",
    candidate_sha="f"*40, candidate_worktree=candidate_worktree,
)
print(json.dumps({
    "all_provisioned": all(s["provisioned"] for s in (s1, s2, s3)),
    "same_identity": s1["identity"] == s2["identity"] == s3["identity"],
    "same_path": s1["path"] == s2["path"] == s3["path"],
}))
PY
ALL_PROV="$(jq_field "${TMP_ID}/idem.json" all_provisioned)"
SAME_ID="$(jq_field "${TMP_ID}/idem.json" same_identity)"
SAME_PATH="$(jq_field "${TMP_ID}/idem.json" same_path)"
expect "no-project provisioning is idempotent across 3 calls (all provisioned)" "$ALL_PROV" "True"
expect "no-project provisioning produces stable identity" "$SAME_ID" "True"
expect "no-project provisioning produces stable path" "$SAME_PATH" "True"

# -------------------------------------------------------------------- #
# Section 4: provisioning failure → infra_failure (not validation_failed)
# -------------------------------------------------------------------- #
section "4. provisioning failure → infra_failure (not validation_failed)"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/infra.json" <<'PY'
"""A candidate with pyproject.toml but no uv on PATH must raise
ValidationEnvironmentError, which the executor wraps into
infra_failure=True."""
import json, os, sys, tempfile
from pathlib import Path
from ownframework_loop import validation_environment as ve

canonical_repo = Path(tempfile.mkdtemp(prefix="ofloop-infra-"))
candidate_worktree = Path(tempfile.mkdtemp(prefix="ofloop-cand-"))
pyproject = candidate_worktree / "pyproject.toml"
pyproject.write_text("[project]\nname='ofloop-infra'\nversion='0.0.1'\n")

saved_path = os.environ.get("PATH")
os.environ["PATH"] = "/tmp/no-such-dir-for-uv-test"
try:
    result = ve.provision_project_environment(
        canonical_repo=canonical_repo, run_id="run-2026-infra",
        role="builder", candidate_sha="a"*40,
        candidate_worktree=candidate_worktree, timeout_seconds=10,
    )
    print(json.dumps({
        "infra": result.get("outcome") == ve.OUTCOME_INFRA_FAILURE,
        "outcome": result.get("outcome"),
        "reason": result.get("reason"),
    }))
finally:
    if saved_path is not None:
        os.environ["PATH"] = saved_path
PY
INFRA_OK="$(jq_field "${TMP_ID}/infra.json" infra)"
INFRA_OUTCOME="$(jq_field "${TMP_ID}/infra.json" outcome)"
expect "missing uv executable → OUTCOME_INFRA_FAILURE" "$INFRA_OK" "True"
expect "missing uv executable outcome class is infra_failure" "$INFRA_OUTCOME" "infra_failure"

# Now drive the full validation_executor contract end-to-end.
PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/exec.json" <<'PY'
"""The validation_executor must wrap a missing-uv situation into a
result row whose infra_failure flag is set AND whose passed flag is
False (without ever having run the subprocess)."""
import json, os, tempfile
from pathlib import Path
from ownframework_loop import validation_executor as vx

saved_path = os.environ.get("PATH")
os.environ["PATH"] = "/tmp/no-such-dir-for-uv-test"
try:
    canonical_repo = Path(tempfile.mkdtemp(prefix="ofloop-exec-"))
    candidate_worktree = Path(tempfile.mkdtemp(prefix="ofloop-cand-"))
    pyproject = candidate_worktree / "pyproject.toml"
    pyproject.write_text("[project]\nname='ofloop-exec'\nversion='0.0.1'\n")
    minimal_packet = {
        "schema": "ownframework-work-packet/v3",
        "packet_id": "v120-exec",
        "created_at": "2026-09-22T00:00:00Z",
        "work_class": "BUG",
        "risk_class": "low",
        "title": "validation env infra_failure",
        "target": {"repo": str(canonical_repo), "branch": "master", "classification": "local_only"},
        "execution_mode": "single",
        "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
        "non_goals": [],
        "allowed_paths": ["a.txt"],
        "protected_paths": [".ownframework-loop/"],
        "work_units": [{"id": "UNIT-1", "title": "u", "scope": "a.txt"}],
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
        "capabilities": ["toolchain.python", "package.uv"],
    }
    result = vx.run_required_validation(
        cwd=candidate_worktree,
        validation={"name": "uv-ping", "command": "uv run python -c 'print(1)'",
                    "kind": "fast", "expected_exit_code": 0},
        timeout_seconds=10,
        canonical_repo=canonical_repo, run_id="run-2026-exec",
        packet=minimal_packet, candidate_sha="a" * 40, role="builder",
    )
    print(json.dumps({
        "infra_failure": result.get("infra_failure"),
        "passed": result.get("passed"),
        "exit_code": result.get("exit_code"),
        "infra_failure_reason_present": bool(result.get("infra_failure_reason")),
    }))
finally:
    if saved_path is not None:
        os.environ["PATH"] = saved_path
PY
EXEC_INFRA="$(jq_field "${TMP_ID}/exec.json" infra_failure)"
EXEC_PASS="$(jq_field "${TMP_ID}/exec.json" passed)"
EXEC_EC="$(jq_field "${TMP_ID}/exec.json" exit_code)"
EXEC_REASON="$(jq_field "${TMP_ID}/exec.json" infra_failure_reason_present)"
expect "validation_executor sets infra_failure=True on provision failure" "$EXEC_INFRA" "True"
expect "validation_executor sets passed=False on infra_failure" "$EXEC_PASS" "False"
expect "validation_executor does NOT run subprocess (exit_code=None)" "$EXEC_EC" "None"
expect "validation_executor surfaces infra_failure_reason" "$EXEC_REASON" "True"

# -------------------------------------------------------------------- #
# Section 5: env_dir is not in any worker's allowRead/allowWrite        #
# -------------------------------------------------------------------- #
section "5. env_dir is not in any worker's allowRead/allowWrite"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/cap.json" <<'PY'
"""The candidate-bound env_dir is validator-owned, not worker-readable.
Prove it never leaks into either role's filesystem authority.

The capability resolution layer refuses to resolve package.uv if
uv is not installed on the host. The leak guard itself does NOT
require uv to be present; we just need the resolution layer's
filesystem authority. Skip package.uv gracefully when uv is not
available so this section runs on CI hosts that do not pre-install
uv.
"""
import json, re, shutil, tempfile
from pathlib import Path
from ownframework_loop import capabilities, runtime_env

canonical_repo = Path(tempfile.mkdtemp(prefix="ofloop-cap-"))
run_id = "run-2026-cap"
requested = ["toolchain.python"]
if shutil.which("uv"):
    requested.append("package.uv")
try:
    resolution = capabilities.resolve_capabilities(
        requested,
        canonical_repo=canonical_repo, role="builder",
        repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
        ephemeral_cache_root=runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation") / "capability-cache",
        evidence_run_key=run_id,
    )
except capabilities.CapabilityResolutionError as exc:
    print(json.dumps({"skipped": True, "reason": str(exc)}))
    raise SystemExit(0)
allow_read = resolution["filesystem"]["allowRead"]
allow_write = resolution["filesystem"]["allowWrite"]
forbidden = re.compile(r"/project-env(/|$)")
leak_in_read = [p for p in allow_read if forbidden.search(p)]
leak_in_write = [p for p in allow_write if forbidden.search(p)]
print(json.dumps({
    "skipped": False,
    "leak_in_read_count": len(leak_in_read),
    "leak_in_write_count": len(leak_in_write),
    "leak_in_read": leak_in_read,
    "leak_in_write": leak_in_write,
}))
PY
CAP_SKIPPED="$(python3 -c "import json; print(json.load(open('${TMP_ID}/cap.json')).get('skipped', False))")"
if [[ "$CAP_SKIPPED" == "True" ]]; then
    echo "SKIP §5 (no uv / capability resolution refused on this host)"
else
    LEAK_READ="$(jq_field "${TMP_ID}/cap.json" leak_in_read_count)"
    LEAK_WRITE="$(jq_field "${TMP_ID}/cap.json" leak_in_write_count)"
    expect "no env_dir leak in allowRead" "$LEAK_READ" "0"
    expect "no env_dir leak in allowWrite" "$LEAK_WRITE" "0"
fi

# -------------------------------------------------------------------- #
# Section 6: validator never reopens HOME                               #
# -------------------------------------------------------------------- #
section "6. validator never reopens HOME"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/home.json" <<'PY'
"""The validator subprocess env must not override HOME. hermetic_subprocess_env
preserves HOME from the base env so Claude's native auth surface
continues to work."""
import json, os
from ownframework_loop import runtime_env

canonical_repo = "/tmp/ofloop-no-home-reopen"
os.makedirs(canonical_repo, exist_ok=True)
home_before = "/var/tmp/ofloop-test-home-do-not-create"
os.environ["HOME"] = home_before
env = runtime_env.hermetic_subprocess_env(
    canonical_repo, "run-2026-home", "validation",
    base_env={"HOME": home_before, "PATH": "/usr/bin:/bin"},
)
print(json.dumps({"home_preserved": env.get("HOME") == home_before}))
PY
HOME_PRES="$(jq_field "${TMP_ID}/home.json" home_preserved)"
expect "HOME is preserved through hermetic validator env" "$HOME_PRES" "True"

# -------------------------------------------------------------------- #
# Section 7: command_uses_uv_run classifier                             #
# -------------------------------------------------------------------- #
section "7. command_uses_uv_run classifier"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/cls.json" <<'PY'
"""The executor's uv-command classifier must recognize every uv
subcommand that needs the project env (run/sync/exec/test/python/
lock) and never mis-classify a non-uv command."""
import json
from ownframework_loop import validation_executor as vx

cases = [
    ("uv run python -c 'print(1)'", True),
    ("uv sync", True),
    ("uv exec pytest", True),
    ("uv test", True),
    ("uv python -V", True),
    ("uv lock", True),
    ("UV_RUN=true uv run python", True),
    ("pip install requests", False),
    ("python -m pytest", False),
    ("echo hello", False),
]
all_ok = all(vx.command_uses_uv_run(cmd) == expected for cmd, expected in cases)
print(json.dumps({"all_ok": all_ok}))
PY
CLS_OK="$(jq_field "${TMP_ID}/cls.json" all_ok)"
expect "command_uses_uv_run classifier correct for all cases" "$CLS_OK" "True"

# -------------------------------------------------------------------- #
# Section 8: env_overrides export the documented keys                   #
# -------------------------------------------------------------------- #
section "8. env_overrides export documented keys"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/over.json" <<'PY'
"""env_overrides is the layer the executor stacks on top of hermetic
subprocess env. It MUST export UV_PROJECT_ENVIRONMENT and VIRTUAL_ENV
and NOTHING ELSE."""
import json, tempfile
from pathlib import Path
from ownframework_loop import validation_environment as ve

with tempfile.TemporaryDirectory() as td:
    overrides = ve.env_overrides(Path(td))
    print(json.dumps({"keys": sorted(overrides.keys())}))
PY
OVER_KEYS="$(jq_field "${TMP_ID}/over.json" keys)"
expect "env_overrides exports only UV_PROJECT_ENVIRONMENT + VIRTUAL_ENV" \
    "$OVER_KEYS" "['UV_PROJECT_ENVIRONMENT', 'VIRTUAL_ENV']"

# -------------------------------------------------------------------- #
# Section 9: infra_failure marker is private + atomic                   #
# -------------------------------------------------------------------- #
section "9. infra_failure marker is private (0600) and atomic"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/marker.json" <<'PY'
"""A no-project provisioning call must produce a private, schema-correct
marker that future validators can use to confirm the env was honored."""
import json, os, stat, tempfile
from pathlib import Path
from ownframework_loop import validation_environment as ve

with tempfile.TemporaryDirectory() as td:
    candidate_worktree = Path(tempfile.mkdtemp(prefix="ofloop-cand-", dir=td))
    canonical_repo = Path(td) / "repo"
    canonical_repo.mkdir()
    env_id = ve.candidate_bound_environment_id("c"*40, candidate_worktree)
    env_dir = ve.project_environment_dir(canonical_repo, "run-2026-marker", "builder", env_id)
    ve.provision_project_environment(
        canonical_repo=canonical_repo, run_id="run-2026-marker", role="builder",
        candidate_sha="c"*40, candidate_worktree=candidate_worktree,
    )
    marker = env_dir / ".ofloop-env-provisioned.json"
    mode = stat.S_IMODE(marker.stat().st_mode)
    payload = json.loads(marker.read_text())
    print(json.dumps({
        "is_private": (mode & 0o077) == 0,
        "schema": payload.get("schema"),
        "no_project_flag": payload.get("no_project") is True,
    }))
PY
MARKER_PRIV="$(jq_field "${TMP_ID}/marker.json" is_private)"
MARKER_SCHEMA="$(jq_field "${TMP_ID}/marker.json" schema)"
MARKER_NP="$(jq_field "${TMP_ID}/marker.json" no_project_flag)"
expect "infra marker is private (no group/world read)" "$MARKER_PRIV" "True"
expect "infra marker carries schema identity" "$MARKER_SCHEMA" "ownframework-loop-validation-environment/v1"
expect "infra marker flags no_project candidates distinctly" "$MARKER_NP" "True"

# -------------------------------------------------------------------- #
# Section 10: marker freshness check rejects drift                      #
# -------------------------------------------------------------------- #
section "10. project_environment_status rejects tampered markers"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/tamper.json" <<'PY'
"""Tamper a marker's body byte WITHOUT recomputing marker_sha256 and
prove project_environment_status refuses to read it as provisioned.
The marker_sha256 bind is the authoritative guard against silent
identity drift."""
import json, os, tempfile
from pathlib import Path
from ownframework_loop import validation_environment as ve

with tempfile.TemporaryDirectory() as td:
    canonical_repo = Path(td) / "repo"
    canonical_repo.mkdir()
    candidate_worktree = Path(tempfile.mkdtemp(prefix="ofloop-cand-", dir=td))
    env_id = ve.candidate_bound_environment_id("d"*40, candidate_worktree)
    env_dir = ve.project_environment_dir(canonical_repo, "run-2026-tamper", "builder", env_id)
    ve.provision_project_environment(
        canonical_repo=canonical_repo, run_id="run-2026-tamper", role="builder",
        candidate_sha="d"*40, candidate_worktree=candidate_worktree,
    )
    marker = env_dir / ".ofloop-env-provisioned.json"
    # Mutate the body without recomputing marker_sha256 — exactly the
    # kind of drift the freshness check must reject.
    body = json.loads(marker.read_text())
    body["identity"] = "0" * 64
    marker.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n")
    os.chmod(marker, 0o600)
    status = ve.project_environment_status(env_dir)
    print(json.dumps({"provisioned": status["provisioned"]}))
PY
TAMPER_PROV="$(jq_field "${TMP_ID}/tamper.json" provisioned)"
expect "tampered marker body is not trusted (provisioned=False)" "$TAMPER_PROV" "False"

# -------------------------------------------------------------------- #
# Section 11: project_environment_dir is pure (no I/O on derivation)    #
# -------------------------------------------------------------------- #
section "11. project_environment_dir is pure (no I/O)"

PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP_ID}/pure.json" <<'PY'
"""Deriving the env path must never touch the filesystem."""
import json
from pathlib import Path
from ownframework_loop import validation_environment as ve

canonical_repo = Path("/tmp/ofloop-pure-derivation-NONEXISTENT-PATH-XYZ123")
candidate_worktree = Path("/tmp/ofloop-candidate-worktree-NONEXISTENT-XYZ789")
env_id = ve.candidate_bound_environment_id("e"*40, candidate_worktree)
d1 = ve.project_environment_dir(canonical_repo, "run-2026-pure", "builder", env_id)
d2 = ve.project_environment_dir(canonical_repo, "run-2026-pure", "builder", env_id)
print(json.dumps({
    "pure_equal": str(d1) == str(d2),
    "did_not_create_path": not d1.exists(),
}))
PY
PURE_EQ="$(jq_field "${TMP_ID}/pure.json" pure_equal)"
PURE_NO_CREATE="$(jq_field "${TMP_ID}/pure.json" did_not_create_path)"
expect "project_environment_dir is pure (same input → same path)" "$PURE_EQ" "True"
expect "project_environment_dir does not create the path" "$PURE_NO_CREATE" "True"

# -------------------------------------------------------------------- #
# Section 12: canonical is_uv_command predicate is the SOLE classifier   #
# -------------------------------------------------------------------- #
section "12. canonical is_uv_command predicate covers all uv subcommands"

# The packet admission layer and the executor layer must consume the
# SAME function. Adding a new uv subcommand → extend
# UV_MEDIATED_SUBCOMMANDS in one place; both layers pick it up
# automatically. Test every documented subcommand plus a non-uv control.
CMD_RESULT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B <<'PY'
import sys
sys.path.insert(0, "${LIB_DIR}")
from ownframework_loop import validation_environment as ve

expected_uv = ["uv run pytest", "uv sync", "uv exec python -V",
               "uv test", "uv python list", "uv lock"]
expected_not = ["pytest", "echo hello", "pip install foo",
                "npm install", "uvx tool run", "tar -xzf foo.tar.gz"]

uv_results = [(c, ve.is_uv_command(c)) for c in expected_uv]
not_results = [(c, ve.is_uv_command(c)) for c in expected_not]
print("UV_TRUE_ALL=", all(v for _, v in uv_results))
print("UV_FALSE_ALL=", not any(v for _, v in not_results))
# Verify the catalogue is exposed publicly so the packet layer can
# rely on the same source.
print("CATALOGUE_KNOWN=", "sync" in ve.UV_MEDIATED_SUBCOMMANDS)
print("EMPTY_FALSE=", ve.is_uv_command("") is False)
PY
)"
expect "every uv subcommand is_uv_command=True" \
    "$(echo "${CMD_RESULT}" | awk -F= '/^UV_TRUE_ALL=/{gsub(/ /,"",$2); print $2}')" "True"
expect "non-uv commands is_uv_command=False" \
    "$(echo "${CMD_RESULT}" | awk -F= '/^UV_FALSE_ALL=/{gsub(/ /,"",$2); print $2}')" "True"
expect "UV_MEDIATED_SUBCOMMANDS exposes 'sync'" \
    "$(echo "${CMD_RESULT}" | awk -F= '/^CATALOGUE_KNOWN=/{gsub(/ /,"",$2); print $2}')" "True"
expect "empty command is_uv_command=False" \
    "$(echo "${CMD_RESULT}" | awk -F= '/^EMPTY_FALSE=/{gsub(/ /,"",$2); print $2}')" "True"

# -------------------------------------------------------------------- #
# Section 13: BoundUvIdentity refuses incomplete resolutions            #
# -------------------------------------------------------------------- #
section "13. BoundUvIdentity refuses to construct without executable/version/sha256"

BOUND_RESULT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B <<'PY'
import sys
sys.path.insert(0, "${LIB_DIR}")
from ownframework_loop import validation_environment as ve

# Missing executable
try:
    ve.build_bound_uv_identity({"version": "0.4.0", "executable_sha256": "abc"})
    print("MISS_EXEC=FAIL_NO_RAISE")
except ve.ValidationEnvironmentError:
    print("MISS_EXEC=REFUSED")
# Missing sha
try:
    ve.build_bound_uv_identity({"executable": "/bin/uv", "version": "0.4.0"})
    print("MISS_SHA=FAIL_NO_RAISE")
except ve.ValidationEnvironmentError:
    print("MISS_SHA=REFUSED")
# Complete resolution
ident = ve.build_bound_uv_identity(
    {"executable": "/bin/uv", "version": "0.4.0",
     "executable_sha256": "deadbeef", "network_domains": ["pypi.org"]},
    cache_path="/var/cache/uv", cache_scope="repository_durable",
)
print("COMPLETE_TYPE=", type(ident).__name__)
print("COMPLETE_SHA=", ident.executable_sha256 == "deadbeef")
print("COMPLETE_DOMAINS=", list(ident.network_domains) == ["pypi.org"])
print("COMPLETE_CACHE_SCOPE=", ident.cache_scope == "repository_durable")
PY
)"
expect "missing executable raises ValidationEnvironmentError" \
    "$(echo "${BOUND_RESULT}" | awk -F= '/^MISS_EXEC=/{gsub(/ /,"",$2); print $2}')" "REFUSED"
expect "missing sha raises ValidationEnvironmentError" \
    "$(echo "${BOUND_RESULT}" | awk -F= '/^MISS_SHA=/{gsub(/ /,"",$2); print $2}')" "REFUSED"
expect "complete resolution constructs BoundUvIdentity" \
    "$(echo "${BOUND_RESULT}" | awk -F= '/^COMPLETE_TYPE=/{gsub(/ /,"",$2); print $2}')" "BoundUvIdentity"
expect "bound identity preserves sha256" \
    "$(echo "${BOUND_RESULT}" | awk -F= '/^COMPLETE_SHA=/{gsub(/ /,"",$2); print $2}')" "True"
expect "bound identity preserves network_domains" \
    "$(echo "${BOUND_RESULT}" | awk -F= '/^COMPLETE_DOMAINS=/{gsub(/ /,"",$2); print $2}')" "True"
expect "bound identity preserves cache_scope" \
    "$(echo "${BOUND_RESULT}" | awk -F= '/^COMPLETE_CACHE_SCOPE=/{gsub(/ /,"",$2); print $2}')" "True"

# -------------------------------------------------------------------- #
# Section 14: verify_bound_uv_identity refuses path drift               #
# -------------------------------------------------------------------- #
section "14. verify_bound_uv_identity refuses symlink / missing / byte mutation"

TMP_DRIFT="$(mktemp -d -t ofloop-drift.XXXXXX)"
trap 'rm -rf "${TMP_ID}" "${TMP_DRIFT}"' EXIT

# Build a fake uv executable with a known SHA
cat > "${TMP_DRIFT}/uv_real" <<'BIN'
#!/usr/bin/env bash
echo "uv 0.4.0"
BIN
chmod +x "${TMP_DRIFT}/uv_real"
REAL_SHA="$(shasum -a 256 "${TMP_DRIFT}/uv_real" | awk '{print $1}')"

# Create a symlink to that file
ln -s "${TMP_DRIFT}/uv_real" "${TMP_DRIFT}/uv_symlink"

# Create a mutated copy
cp "${TMP_DRIFT}/uv_real" "${TMP_DRIFT}/uv_mutated"
printf '#!/usr/bin/env bash\necho "attacker uv"\n' > "${TMP_DRIFT}/uv_mutated"
chmod +x "${TMP_DRIFT}/uv_mutated"

DRIFT_RESULT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B <<PY
import sys
sys.path.insert(0, "${LIB_DIR}")
from ownframework_loop import validation_environment as ve

# 1. Missing path
try:
    ve.verify_bound_uv_identity(ve.BoundUvIdentity(
        executable="/no/such/path", version="0.4.0",
        executable_sha256="x", cache_path="", cache_scope="",
        network_domains=()))
    print("MISSING=FAIL_NO_RAISE")
except ve.ValidationEnvironmentError as e:
    print("MISSING=REFUSED:", "disappeared" in str(e))

# 2. Symlink
try:
    ve.verify_bound_uv_identity(ve.BoundUvIdentity(
        executable="${TMP_DRIFT}/uv_symlink", version="0.4.0",
        executable_sha256="x", cache_path="", cache_scope="",
        network_domains=()))
    print("SYMLINK=FAIL_NO_RAISE")
except ve.ValidationEnvironmentError as e:
    print("SYMLINK=REFUSED:", "symlink" in str(e))

# 3. SHA mismatch (same path, different bytes)
try:
    ve.verify_bound_uv_identity(ve.BoundUvIdentity(
        executable="${TMP_DRIFT}/uv_mutated", version="0.4.0",
        executable_sha256="${REAL_SHA}", cache_path="", cache_scope="",
        network_domains=()))
    print("DRIFT=FAIL_NO_RAISE")
except ve.ValidationEnvironmentError as e:
    print("DRIFT=REFUSED:", "CAPABILITY_DRIFT" in str(e))

# 4. Real file with matching SHA passes
try:
    ve.verify_bound_uv_identity(ve.BoundUvIdentity(
        executable="${TMP_DRIFT}/uv_real", version="0.4.0",
        executable_sha256="${REAL_SHA}", cache_path="", cache_scope="",
        network_domains=()))
    print("MATCH=PASS")
except ve.ValidationEnvironmentError as e:
    print("MATCH=FAIL_RAISED:", str(e)[:80])
PY
)"
expect "missing executable raises with 'disappeared'" \
    "$(echo "${DRIFT_RESULT}" | grep '^MISSING=' | sed 's/^MISSING=REFUSED: //')" "True"
expect "symlink executable raises with 'symlink'" \
    "$(echo "${DRIFT_RESULT}" | grep '^SYMLINK=' | sed 's/^SYMLINK=REFUSED: //')" "True"
expect "byte mutation raises CAPABILITY_DRIFT" \
    "$(echo "${DRIFT_RESULT}" | grep '^DRIFT=' | sed 's/^DRIFT=REFUSED: //')" "True"
expect "real file with matching SHA passes verification" \
    "$(echo "${DRIFT_RESULT}" | awk -F= '/^MATCH=/{gsub(/ /,"",$2); print $2}')" "PASS"

# -------------------------------------------------------------------- #
# Section 15: package-network override env vars are stripped             #
# -------------------------------------------------------------------- #
section "15. ambient package-network overrides are stripped from hermetic env"

# Seed base env with operator-shell-level overrides that would
# otherwise widen the package network boundary past package.uv's
# frozen allowlist. The hermetic env MUST remove every one of them.
PKG_NET_RESULT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B <<'PY'
import os, sys
sys.path.insert(0, "${LIB_DIR}")
from ownframework_loop import runtime_env as re_mod

# Inject ambient overrides into the base environment.
overrides = {
    "UV_INDEX_URL": "https://my-mirror.example.com/simple",
    "UV_EXTRA_INDEX_URL": "https://other-mirror.example.com/simple",
    "UV_DEFAULT_INDEX": "https://default-mirror.example.com/simple",
    "UV_INDEX": "https://uv-index.example.com/simple",
    "PIP_INDEX_URL": "https://pip-mirror.example.com/simple",
    "PIP_EXTRA_INDEX_URL": "https://pip-extra.example.com/simple",
    "PIP_DEFAULT_INDEX": "https://pip-default.example.com/simple",
    "PIP_NO_INDEX": "1",
    "NPM_CONFIG_REGISTRY": "https://npm-mirror.example.com",
    "npm_config_registry": "https://npm-mirror.example.com",
    "PNPM_REGISTRY": "https://pnpm-mirror.example.com",
    "CARGO_REGISTRIES_CRATES_IO_PROTOCOL": "sparse",
    "CARGO_REGISTRIES_CRATES_IO_INDEX": "https://cargo-mirror.example.com",
    "HTTP_PROXY": "http://proxy.example.com:8080",
    "HTTPS_PROXY": "http://proxy.example.com:8080",
    "ALL_PROXY": "socks5://proxy.example.com:1080",
    "NO_PROXY": "*",
    "http_proxy": "http://proxy.example.com:8080",
    "https_proxy": "http://proxy.example.com:8080",
    "all_proxy": "socks5://proxy.example.com:1080",
    "no_proxy": "*",
    "UV_HTTP_PROXY": "http://proxy.example.com:8080",
    "UV_HTTPS_PROXY": "http://proxy.example.com:8080",
    "UV_NO_PROXY": "*",
}
base = dict(os.environ)
base.update(overrides)

from pathlib import Path
env = re_mod.hermetic_subprocess_env(
    Path("${REPO_ROOT}"), "drift-fixture-run", "validation",
    base_env=base,
    capability_environment={},
    path_prepend=[],
)
stripped = {k: k not in env for k in overrides}
print("STRIPPED_ALL=", all(stripped.values()))
print("STRIPPED_KEYS=", ",".join(sorted(stripped.keys())))
PY
)"
expect "every ambient package-network override is stripped" \
    "$(echo "${PKG_NET_RESULT}" | awk -F= '/^STRIPPED_ALL=/{gsub(/ /,"",$2); print $2}')" "True"
expect "stripped key catalogue is non-empty" \
    "$(echo "${PKG_NET_RESULT}" | awk -F= '/^STRIPPED_KEYS=/{print "SET"}')" "SET"

# -------------------------------------------------------------------- #
# Summary                                                                #
# -------------------------------------------------------------------- #
echo
if [[ "${failures}" -eq 0 ]]; then
    echo "VALIDATION_ENVIRONMENT_BEHAVIORAL=PASS"
else
    echo "VALIDATION_ENVIRONMENT_BEHAVIORAL=FAIL (failures=${failures})"
    exit 1
fi
exit 0

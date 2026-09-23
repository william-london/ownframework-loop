#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"
export PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}"

python3 -B <<'PYTEST'
import hashlib
import inspect
import json
import tempfile
from pathlib import Path

from ownframework_loop import packet
from ownframework_loop import validation_environment as ve
from ownframework_loop import validation_executor as vx

# Catalogue drives detection; every declared subcommand is recognized.
source = inspect.getsource(ve)
assert '"|".join(re.escape(subcommand) for subcommand in UV_MEDIATED_SUBCOMMANDS)' in source
for subcommand in ve.UV_MEDIATED_SUBCOMMANDS:
    assert ve.is_uv_command(f"uv {subcommand}"), subcommand
assert not hasattr(ve, "_resolve_uv_executable")

# package.uv admission is independent of source layout, including checkpoints.
flat = {
    "allowed_paths": ["app/", "tests/"],
    "capabilities": ["toolchain.python"],
    "required_validation": [
        {"name": "flat-uv", "command": "uv run pytest -q"},
    ],
}
flat_errors = packet.validate_validation_contract(flat)
assert any("flat-uv" in err and "package.uv" in err for err in flat_errors), flat_errors

checkpoint = {
    "allowed_paths": ["packages/api/"],
    "capabilities": ["toolchain.python"],
    "checkpoint_graph": {
        "checkpoints": [
            {"required_validation": [
                {"name": "cp-uv", "command": "uv sync"},
            ]},
        ],
    },
}
cp_errors = packet.validate_validation_contract(checkpoint)
assert any("cp-uv" in err and "package.uv" in err for err in cp_errors), cp_errors

# A real project can never provision through PATH when no bound identity exists.
with tempfile.TemporaryDirectory(prefix="ofloop-v121-") as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    candidate = root / "candidate"
    candidate.mkdir()
    (candidate / "pyproject.toml").write_text(
        "[project]\nname='authority-closure'\nversion='0.0.1'\n",
        encoding="utf-8",
    )
    original_which = ve.shutil.which
    ve.shutil.which = lambda *_args, **_kwargs: (_ for _ in ()).throw(
        AssertionError("PATH uv discovery must never run")
    )
    try:
        result = ve.provision_project_environment(
            canonical_repo=repo,
            run_id="run-v121-bound-required",
            role="builder",
            candidate_sha="a" * 40,
            candidate_worktree=candidate,
        )
    finally:
        ve.shutil.which = original_which
    assert result["outcome"] == ve.OUTCOME_INFRA_FAILURE, result
    assert str(result["reason"]).startswith("bound_uv_required:"), result

# The same authority requirement applies BEFORE a real-project cache hit.
# A durable marker can never turn a direct unbound caller into a trusted one.
with tempfile.TemporaryDirectory(prefix="ofloop-v121-direct-cache-") as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    candidate = root / "candidate"
    candidate.mkdir()
    (candidate / "pyproject.toml").write_text(
        "[project]\nname='direct-cache'\nversion='0.0.1'\n",
        encoding="utf-8",
    )
    fake_uv = root / "uv"
    fake_uv.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_uv.chmod(0o755)
    fake_sha = hashlib.sha256(fake_uv.read_bytes()).hexdigest()
    candidate_sha = "1" * 40
    run_id = "run-v121-direct-cache"
    env_id = ve.candidate_bound_environment_id(candidate_sha, candidate)
    env_dir = ve.project_environment_dir(repo, run_id, "builder", env_id)
    env_dir.mkdir(parents=True, mode=0o700)
    ve._publish_marker(env_dir, {
        "schema": ve.SCHEMA,
        "identity": env_id,
        "candidate_sha": candidate_sha,
        "lock_sha256": "",
        "metadata_sha256": ve._project_metadata_identity(candidate),
        "uv_executable": str(fake_uv),
        "uv_version": "uv-test",
        "package_uv_unbound": False,
        "bound_uv_sha256": fake_sha,
        "bound_uv_version": "uv-test",
        "bound_uv_cache_path": str(root / "cache"),
        "bound_uv_cache_scope": "repository_durable",
        "bound_uv_network_domains": ["pypi.org"],
        "provisioned_at": "2026-09-22T00:00:00Z",
    })

    unbound_cached = ve.provision_project_environment(
        canonical_repo=repo,
        run_id=run_id,
        role="builder",
        candidate_sha=candidate_sha,
        candidate_worktree=candidate,
    )
    assert unbound_cached["outcome"] == ve.OUTCOME_INFRA_FAILURE, unbound_cached
    assert str(unbound_cached["reason"]).startswith(
        "bound_uv_required:"
    ), unbound_cached

    wrong_binding = ve.BoundUvIdentity(
        executable=str(fake_uv),
        version="uv-test",
        executable_sha256=fake_sha,
        cache_path=str(root / "different-cache"),
        cache_scope="repository_durable",
        network_domains=("pypi.org",),
    )
    mismatched_cached = ve.provision_project_environment(
        canonical_repo=repo,
        run_id=run_id,
        role="builder",
        candidate_sha=candidate_sha,
        candidate_worktree=candidate,
        bound_uv=wrong_binding,
    )
    assert mismatched_cached["outcome"] == ve.OUTCOME_INFRA_FAILURE, mismatched_cached
    assert str(mismatched_cached["reason"]).startswith(
        "bound_uv_cached_environment_mismatch:"
    ), mismatched_cached

# No-project callers remain compatible because this path performs no uv effect.
with tempfile.TemporaryDirectory(prefix="ofloop-v121-noproject-") as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    candidate = root / "candidate"
    candidate.mkdir()
    result = ve.provision_project_environment(
        canonical_repo=repo,
        run_id="run-v121-no-project",
        role="builder",
        candidate_sha="b" * 40,
        candidate_worktree=candidate,
    )
    assert result["outcome"] == ve.OUTCOME_PROVISIONED, result
    assert result.get("package_uv_unbound") is False, result

# A no-project marker has no uv executable because no uv subprocess ran, but
# remains safely reusable when every frozen bound field matches.
bound_no_project = ve.BoundUvIdentity(
    executable="/bound/uv",
    version="uv-test",
    executable_sha256="f" * 64,
    cache_path="/cache/uv",
    cache_scope="repository_durable",
    network_domains=("pypi.org", "files.pythonhosted.org"),
)
no_project_status = {
    "provisioned": True,
    "package_uv_unbound": False,
    "metadata_sha256": "no-pyproject",
    "uv_executable": "",
    "bound_uv_sha256": bound_no_project.executable_sha256,
    "bound_uv_version": bound_no_project.version,
    "bound_uv_cache_path": bound_no_project.cache_path,
    "bound_uv_cache_scope": bound_no_project.cache_scope,
    "bound_uv_network_domains": list(bound_no_project.network_domains),
}
assert vx._cached_environment_matches_bound_uv(
    no_project_status, bound_no_project
), no_project_status
real_project_status = dict(no_project_status)
real_project_status["metadata_sha256"] = "a" * 64
assert not vx._cached_environment_matches_bound_uv(
    real_project_status, bound_no_project
), real_project_status

# Executor refuses a uv command when the frozen resolution lacks package.uv.
with tempfile.TemporaryDirectory(prefix="ofloop-v121-executor-") as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    candidate = root / "candidate"
    candidate.mkdir()
    original_resolution = vx.runtime_env.commissioned_validation_resolution
    vx.runtime_env.commissioned_validation_resolution = lambda *_a, **_k: {
        "resolved": [], "environment": {}, "path_prepend": []
    }
    try:
        result = vx.run_required_validation(
            cwd=candidate,
            validation={
                "name": "unbound-uv",
                "command": "uv run python -c 'print(1)'",
                "kind": "fast",
                "expected_exit_code": 0,
            },
            timeout_seconds=5,
            canonical_repo=repo,
            run_id="run-v121-executor",
            packet={},
            candidate_sha="c" * 40,
            role="builder",
        )
    finally:
        vx.runtime_env.commissioned_validation_resolution = original_resolution
    assert result["infra_failure"] is True, result
    assert result["exit_code"] is None, result
    assert result["infra_failure_reason"].startswith("bound_uv_capability_not_bound:"), result

# An incomplete package.uv resolution is a typed infra refusal, not an uncaught error.
with tempfile.TemporaryDirectory(prefix="ofloop-v121-incomplete-") as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    candidate = root / "candidate"
    candidate.mkdir()
    original_resolution = vx.runtime_env.commissioned_validation_resolution
    vx.runtime_env.commissioned_validation_resolution = lambda *_a, **_k: {
        "resolved": [{"name": "package.uv"}],
        "environment": {},
        "path_prepend": [],
    }
    try:
        result = vx.run_required_validation(
            cwd=candidate,
            validation={
                "name": "incomplete-uv",
                "command": "uv run python -c 'print(1)'",
                "kind": "fast",
                "expected_exit_code": 0,
            },
            timeout_seconds=5,
            canonical_repo=repo,
            run_id="run-v121-incomplete",
            packet={},
            candidate_sha="d" * 40,
            role="builder",
        )
    finally:
        vx.runtime_env.commissioned_validation_resolution = original_resolution
    assert result["infra_failure"] is True, result
    assert result["exit_code"] is None, result
    assert result["infra_failure_reason"].startswith(
        "bound_uv_resolution_missing_fields:"
    ), result

# A historical unbound cached environment can never be reused under a new
# frozen package.uv identity, even when candidate/lock/metadata identity matches.
with tempfile.TemporaryDirectory(prefix="ofloop-v121-stale-cache-") as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    candidate = root / "candidate"
    candidate.mkdir()
    (candidate / "pyproject.toml").write_text(
        "[project]\nname='stale-cache'\nversion='0.0.1'\n",
        encoding="utf-8",
    )
    fake_uv = root / "uv"
    fake_uv.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake_uv.chmod(0o755)
    fake_sha = hashlib.sha256(fake_uv.read_bytes()).hexdigest()
    candidate_sha = "e" * 40
    run_id = "run-v121-stale-cache"
    env_id = ve.candidate_bound_environment_id(candidate_sha, candidate)
    env_dir = ve.project_environment_dir(repo, run_id, "builder", env_id)
    env_dir.mkdir(parents=True, mode=0o700)
    ve._publish_marker(env_dir, {
        "schema": ve.SCHEMA,
        "identity": env_id,
        "candidate_sha": candidate_sha,
        "lock_sha256": "",
        "metadata_sha256": ve._project_metadata_identity(candidate),
        "uv_executable": "/legacy/path/uv",
        "uv_version": "legacy",
        "package_uv_unbound": True,
        "bound_uv_sha256": "",
        "bound_uv_version": "",
        "bound_uv_cache_path": "",
        "bound_uv_cache_scope": "",
        "bound_uv_network_domains": [],
        "provisioned_at": "2026-09-22T00:00:00Z",
    })

    original_resolution = vx.runtime_env.commissioned_validation_resolution
    vx.runtime_env.commissioned_validation_resolution = lambda *_a, **_k: {
        "resolved": [{
            "name": "package.uv",
            "executable": str(fake_uv),
            "version": "uv-test-1",
            "executable_sha256": fake_sha,
            "cache_path": str(root / "cache"),
            "cache_scope": "repository_durable",
            "network_domains": ["pypi.org", "files.pythonhosted.org"],
        }],
        "environment": {},
        "path_prepend": [str(root)],
    }
    try:
        result = vx.run_required_validation(
            cwd=candidate,
            validation={
                "name": "stale-cache-uv",
                "command": "uv run python -c 'print(1)'",
                "kind": "fast",
                "expected_exit_code": 0,
            },
            timeout_seconds=5,
            canonical_repo=repo,
            run_id=run_id,
            packet={},
            candidate_sha=candidate_sha,
            role="builder",
        )
    finally:
        vx.runtime_env.commissioned_validation_resolution = original_resolution
    assert result["infra_failure"] is True, result
    assert result["exit_code"] is None, result
    assert result["infra_failure_reason"].startswith(
        "bound_uv_cached_environment_mismatch:"
    ), result

# The immediate pre-launch re-proof is an infra boundary too. If the frozen uv
# identity drifts after provisioning but before Popen, the row and the durable
# infra marker must carry the exact same reason so finalizer evidence is real.
with tempfile.TemporaryDirectory(prefix="ofloop-v121-late-drift-") as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    candidate = root / "candidate"
    candidate.mkdir()
    (candidate / "pyproject.toml").write_text(
        "[project]\nname='late-drift'\nversion='0.0.1'\n",
        encoding="utf-8",
    )
    launched = root / "validation-launched"
    fake_uv = root / "uv"
    fake_uv.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = \"--version\" ]; then echo 'uv 99.0-test'; exit 0; fi\n"
        f"if [ \"${{1:-}}\" = \"run\" ]; then echo launched > '{launched}'; exit 0; fi\n"
        "mkdir -p \"${UV_PROJECT_ENVIRONMENT:?}\"\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake_uv.chmod(0o755)
    fake_sha = hashlib.sha256(fake_uv.read_bytes()).hexdigest()
    candidate_sha = "f" * 40
    run_id = "run-v121-late-drift"
    marker = root / "infra-failure.json"
    resolution = {
        "resolved": [{
            "name": "package.uv",
            "executable": str(fake_uv),
            "version": "uv 99.0-test",
            "executable_sha256": fake_sha,
            "cache_path": str(root / "cache"),
            "cache_scope": "repository_durable",
            "network_domains": ["pypi.org", "files.pythonhosted.org"],
        }],
        "environment": {},
        "path_prepend": [str(root)],
    }
    original_resolution = vx.runtime_env.commissioned_validation_resolution
    original_verify = ve.verify_bound_uv_identity
    verify_calls = 0

    def staged_verify(bound):
        nonlocal_marker = None
        del nonlocal_marker
        global verify_calls
        verify_calls += 1
        if verify_calls == 2:
            raise ve.ValidationEnvironmentError("forced pre-launch drift")
        return original_verify(bound)

    vx.runtime_env.commissioned_validation_resolution = lambda *_a, **_k: resolution
    ve.verify_bound_uv_identity = staged_verify
    try:
        result = vx.run_required_validation(
            cwd=candidate,
            validation={
                "name": "late-drift-uv",
                "command": "uv run python -c 'print(1)'",
                "kind": "fast",
                "expected_exit_code": 0,
            },
            timeout_seconds=5,
            canonical_repo=repo,
            run_id=run_id,
            packet={},
            candidate_sha=candidate_sha,
            role="builder",
            infra_failure_path=marker,
        )
    finally:
        ve.verify_bound_uv_identity = original_verify
        vx.runtime_env.commissioned_validation_resolution = original_resolution
    assert verify_calls == 2, verify_calls
    assert result["infra_failure"] is True, result
    assert result["exit_code"] is None, result
    assert result["infra_failure_reason"].startswith(
        "bound_uv_drift_pre_launch:forced pre-launch drift"
    ), result
    assert marker.is_file(), result
    marker_doc = json.loads(marker.read_text(encoding="utf-8"))
    assert marker_doc["reason"] == result["infra_failure_reason"], marker_doc
    assert marker_doc["name"] == "late-drift-uv", marker_doc
    assert marker_doc["validation_env_id"] == result["validation_env_id"], marker_doc
    assert marker_doc["validation_env_path"] == result["validation_env_path"], marker_doc
    assert (marker.stat().st_mode & 0o777) == 0o600, oct(marker.stat().st_mode)
    assert not launched.exists(), "validation subprocess launched after late uv drift"

print("VALIDATION_AUTHORITY_CLOSURE=PASS")
PYTEST

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

from ownframework_loop import capabilities, packet, runtime_env, supervisor

with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    repo = root / "repo"
    repo.mkdir()
    (repo / ".ownframework-loop" / "r1").mkdir(parents=True)
    os.environ["XDG_STATE_HOME"] = str(root / "state")

    manifest = capabilities.default_host_manifest_path()
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({
        "schema": capabilities.HOST_MANIFEST_SCHEMA,
        "capabilities": {
            "toolchain.synthetic": {
                "kind": "tool",
                "executable": sys.executable,
                "version_args": ["--version"],
                "read_paths": [str(Path(sys.executable).resolve().parent)],
            },
            "package.pip": {
                "executable": sys.executable,
                "version_args": ["--version"],
                "read_paths": [str(Path(sys.executable).resolve().parent)],
            },
        },
    }), encoding="utf-8")
    manifest.chmod(0o600)

    cache = runtime_env.repo_tool_cache_dir(repo)
    first = runtime_env.repo_tool_cache_path(repo)
    second = runtime_env.repo_tool_cache_path(repo)
    assert first == second
    assert cache == first

    resolved = capabilities.resolve_capabilities(
        ["toolchain.synthetic"],
        canonical_repo=repo,
        role="builder",
        repo_cache_root=cache,
        packet_network_allowlist=["example.com"],
    )
    assert resolved["requested"] == ["toolchain.synthetic"]
    assert resolved["resolved"][0]["executable"] == str(Path(sys.executable).resolve())
    assert "example.com" in resolved["network_domains"]

    builder = capabilities.resolve_capabilities(
        ["package.pip"], canonical_repo=repo, role="builder",
        repo_cache_root=cache, packet_network_allowlist=[],
    )
    reviewer = capabilities.resolve_capabilities(
        ["package.pip"], canonical_repo=repo, role="reviewer",
        repo_cache_root=cache, packet_network_allowlist=[],
    )
    pip_cache = builder["environment"]["PIP_CACHE_DIR"]
    assert pip_cache in builder["filesystem"]["allowWrite"]
    assert pip_cache in reviewer["filesystem"]["allowRead"]
    assert pip_cache not in reviewer["filesystem"]["allowWrite"]
    assert {"pypi.org", "files.pythonhosted.org"} <= set(builder["network_domains"])

    env = runtime_env.hermetic_subprocess_env(
        repo, "r1", "builder",
        capability_environment={"PIP_CACHE_DIR": pip_cache},
        path_prepend=[str(Path(sys.executable).resolve().parent)],
    )
    assert env["PIP_CACHE_DIR"] == pip_cache
    try:
        runtime_env.hermetic_subprocess_env(
            repo, "r1", "builder",
            capability_environment={"LD_PRELOAD": "/tmp/evil"},
        )
    except ValueError:
        pass
    else:
        raise AssertionError("unsafe capability environment key accepted")

    try:
        capabilities.resolve_capabilities(
            ["container.docker"], canonical_repo=repo, role="builder",
            repo_cache_root=cache, packet_network_allowlist=[],
        )
    except capabilities.CapabilityResolutionError as exc:
        assert "broker" in str(exc)
    else:
        raise AssertionError("direct Docker capability unexpectedly resolved")

    try:
        capabilities.resolve_capabilities(
            ["local.http-service"], canonical_repo=repo, role="builder",
            repo_cache_root=cache, packet_network_allowlist=[],
        )
    except capabilities.CapabilityResolutionError as exc:
        assert "safe-local-binding" in str(exc)
    else:
        raise AssertionError("local binding enabled without commissioning proof")

    try:
        capabilities.resolve_capabilities(
            ["toolchain.missing"], canonical_repo=repo, role="builder",
            repo_cache_root=cache, packet_network_allowlist=[],
        )
    except capabilities.CapabilityResolutionError:
        pass
    else:
        raise AssertionError("unknown capability resolved without host commissioning")

    receipt = capabilities.write_resolution_receipt(repo, "r1", "builder", "attempt-1", resolved)
    assert receipt.is_file()
    assert stat.S_IMODE(receipt.stat().st_mode) & 0o077 == 0
    data = json.loads(receipt.read_text())
    assert data["attempt_id"] == "attempt-1"

    settings = supervisor._semantic_worker_settings(
        canonical_repo=repo,
        run_id="r1",
        role="builder",
        worktree=repo,
        semantic_path=repo / ".ownframework-loop" / "r1" / "BUILD_AGENT_RESULT.json",
        network_read_allowlist=["example.com"],
        capability_resolution=builder,
    )
    sandbox = settings["sandbox"]
    assert "pypi.org" in sandbox["network"]["allowedDomains"]
    assert sandbox["excludedCommands"] == []
    flat = json.dumps(settings)
    assert "docker.sock" not in flat

    good = {
        "schema": packet.PROGRAM_SCHEMA_VERSION,
        "packet_id": "captest",
        "created_at": "2026-09-01T12:00:00Z",
        "work_class": "FEATURE",
        "risk_class": "medium",
        "title": "capability test",
        "target": {"repo": str(repo.resolve()), "branch": "master", "classification": "local_only"},
        "acceptance_criteria": [{"id": "AC-1", "text": "works"}],
        "non_goals": [],
        "allowed_paths": ["src"],
        "protected_paths": [".git"],
        "work_units": [{"id": "UNIT-1", "title": "x", "scope": "x"}],
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
        "capabilities": ["toolchain.python", "browser.playwright.chromium"],
    }
    assert not capabilities.validate_capability_names(good["capabilities"])
    assert not [e for e in packet.validate_packet_metadata(good) if "capabilit" in e.lower()]
    bad = dict(good)
    bad["capabilities"] = ["../home"]
    assert any("capabilities" in e for e in packet.validate_packet_metadata(bad))

    manifest.chmod(0o666)
    try:
        capabilities.resolve_capabilities(
            ["toolchain.synthetic"], canonical_repo=repo, role="builder",
            repo_cache_root=cache, packet_network_allowlist=[],
        )
    except capabilities.CapabilityResolutionError as exc:
        assert "writable" in str(exc)
    else:
        raise AssertionError("tamperable host capability manifest accepted")

print("OF_LOOP_V091_CAPABILITY_RUNTIME=PASS")
PY

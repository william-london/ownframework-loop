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

from ownframework_loop import capabilities, guards, packet, runtime_env, supervisor

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
    assert len(resolved["resolved"][0]["executable_sha256"]) == 64

    inventory = capabilities.probe_host_capabilities()
    assert inventory["schema"] == "ownframework-loop-host-capability-inventory/v1"
    assert len(inventory["runtime_fingerprint"]) == 64
    by_name = {item["name"]: item for item in inventory["capabilities"]}
    assert by_name["toolchain.python"]["available"]
    assert by_name["browser.playwright.chromium"]["available"]
    assert not by_name["container.docker"]["available"]
    assert "example.com" in resolved["network_domains"]

    builder = capabilities.resolve_capabilities(
        ["package.pip"], canonical_repo=repo, role="builder",
        repo_cache_root=cache, packet_network_allowlist=[],
    )
    reviewer_ephemeral = runtime_env.runtime_cache_dir(repo, "r1", "reviewer") / "capability-cache"
    reviewer = capabilities.resolve_capabilities(
        ["package.pip"], canonical_repo=repo, role="reviewer",
        repo_cache_root=cache, ephemeral_cache_root=reviewer_ephemeral,
        packet_network_allowlist=[],
    )
    pip_cache = builder["environment"]["PIP_CACHE_DIR"]
    reviewer_pip_cache = reviewer["environment"]["PIP_CACHE_DIR"]
    assert pip_cache in builder["filesystem"]["allowWrite"]
    assert reviewer_pip_cache != pip_cache
    assert reviewer_pip_cache in reviewer["filesystem"]["allowRead"]
    assert reviewer_pip_cache in reviewer["filesystem"]["allowWrite"]
    assert builder["resolved"][0]["cache_scope"] == "repository_durable"
    assert reviewer["resolved"][0]["cache_scope"] == "pass_ephemeral"
    assert {"pypi.org", "files.pythonhosted.org"} <= set(builder["network_domains"])

    env = runtime_env.hermetic_subprocess_env(
        repo, "r1", "builder",
        capability_environment={"PIP_CACHE_DIR": pip_cache},
        path_prepend=[str(Path(sys.executable).resolve().parent)],
    )
    assert env["PIP_CACHE_DIR"] == pip_cache
    poisoned_base = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", str(root)),
        "DOCKER_HOST": "unix:///tmp/docker.sock",
        "DOCKER_CONTEXT": "desktop-linux",
        "KUBECONFIG": "/tmp/kubeconfig",
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
    }
    scrubbed = runtime_env.hermetic_subprocess_env(
        repo, "r1", "builder", base_env=poisoned_base
    )
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "KUBECONFIG", "SSH_AUTH_SOCK"):
        assert key not in scrubbed
    try:
        runtime_env.hermetic_subprocess_env(
            repo, "r1", "builder",
            capability_environment={"LD_PRELOAD": "/tmp/evil"},
        )
    except ValueError:
        pass
    else:
        raise AssertionError("unsafe capability environment key accepted")

    no_docker = guards.classify_bash_command_with_env(
        "docker compose up -d",
        {
            "OFLOOP_SEMANTIC_CONTEXT": "1",
            "OFLOOP_RUN_ID": "r1",
            "OFLOOP_ROLE": "builder",
            "OFLOOP_CANONICAL_REPO": str(repo.resolve()),
            "OFLOOP_PRIVILEGED_CAPABILITIES": "",
        },
    )
    assert no_docker["severity"] == "forbidden"
    broker_docker = guards.classify_bash_command_with_env(
        "docker compose up -d",
        {
            "OFLOOP_SEMANTIC_CONTEXT": "1",
            "OFLOOP_RUN_ID": "r1",
            "OFLOOP_ROLE": "builder",
            "OFLOOP_CANONICAL_REPO": str(repo.resolve()),
            "OFLOOP_PRIVILEGED_CAPABILITIES": "container.docker",
        },
    )
    assert broker_docker["severity"] == "allowed"

    try:
        capabilities.resolve_capabilities(
            ["container.docker"], canonical_repo=repo, role="builder",
            repo_cache_root=cache, packet_network_allowlist=[],
        )
    except capabilities.CapabilityResolutionError as exc:
        assert "broker" in str(exc)
    else:
        raise AssertionError("direct Docker capability unexpectedly resolved")

    manifest.write_text(json.dumps({
        "schema": capabilities.HOST_MANIFEST_SCHEMA,
        "capabilities": {
            "local.http-service": {
                "provider": "claude_native_safe_local_binding",
                "proof": "stale-proof",
            }
        },
    }), encoding="utf-8")
    manifest.chmod(0o600)
    try:
        capabilities.resolve_capabilities(
            ["local.http-service"], canonical_repo=repo, role="builder",
            repo_cache_root=cache, packet_network_allowlist=[],
        )
    except capabilities.CapabilityResolutionError as exc:
        assert "safe-local-binding" in str(exc)
    else:
        raise AssertionError("local binding enabled without commissioning proof")

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
    assert "/var/run/docker.sock" in sandbox["filesystem"]["denyRead"]
    assert "/run/containerd/containerd.sock" in sandbox["filesystem"]["denyRead"]
    assert "docker.sock" not in json.dumps(sandbox["filesystem"]["allowRead"])

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

    browser = capabilities.resolve_capabilities(
        ["browser.playwright.chromium"],
        canonical_repo=repo,
        role="builder",
        repo_cache_root=cache,
        packet_network_allowlist=[],
    )
    assert browser["resolved"][0]["executable"] is None
    assert "storage.googleapis.com" in browser["network_domains"]

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

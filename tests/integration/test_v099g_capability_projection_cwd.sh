#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1

python3 -B - <<'PY'
import hashlib
import json
import os
import tempfile
from pathlib import Path

from ownframework_loop import capabilities, capability_binding, runner_profiles, runtime_env


with tempfile.TemporaryDirectory(prefix="ofloop-v099g-cwd-") as td:
    root = Path(td)
    repo = root / "canonical-repo"
    service_cwd = root / "service-cwd"
    repo.mkdir()
    service_cwd.mkdir()
    (repo / "package.json").write_text('{"packageManager":"pnpm@9.0.0"}\n', encoding="utf-8")

    tool = root / "cwd-sensitive-tool"
    tool.write_text(
        "#!/bin/sh\n"
        "if [ -f package.json ]; then echo canonical-version; else echo ambient-version; fi\n",
        encoding="utf-8",
    )
    tool.chmod(0o700)
    manifest = root / "host-capability-manifest.json"
    manifest.write_text(
        json.dumps({
            "schema": capabilities.HOST_MANIFEST_SCHEMA,
            "capabilities": {
                "toolchain.synthetic": {
                    "kind": "tool",
                    "executable": str(tool),
                    "version_args": [],
                    "network_domains": [],
                }
            },
        }),
        encoding="utf-8",
    )
    manifest.chmod(0o600)

    run_id = "run-cwd-projection"
    (repo / ".ownframework-loop" / run_id).mkdir(parents=True)
    profile = runner_profiles.resolve_profile("default", provider="claude-code")
    cache = runtime_env.repo_tool_cache_dir(repo)
    requested = ["toolchain.synthetic"]

    def resolve_from(cwd: Path, role: str):
        os.chdir(cwd)
        return capabilities.resolve_capabilities(
            requested,
            canonical_repo=repo,
            role=role,
            repo_cache_root=cache,
            ephemeral_cache_root=(
                runtime_env.runtime_cache_dir(repo, run_id, role) / "capability-cache"
            ),
            packet_network_allowlist=[],
            manifest_path=manifest,
        )

    # Model the supported migration writer from the repository CWD and the
    # commissioned worker from its service CWD. Their stable projections must
    # be identical even though the executable reports CWD-sensitive metadata.
    migration_resolution = resolve_from(repo, "reviewer")
    worker_resolution = resolve_from(service_cwd, "builder")
    migration_projection = capability_binding.stable_projection(
        migration_resolution, profile
    )
    worker_projection = capability_binding.stable_projection(worker_resolution, profile)
    assert migration_projection == worker_projection, (
        migration_projection,
        worker_projection,
    )
    assert migration_projection["capabilities"][0]["version"] == "canonical-version"

    binding = capability_binding.ensure_run_binding(
        repo, run_id, migration_resolution, profile, allow_create=True
    )
    assert capability_binding.verify_run_binding(
        repo, run_id, worker_resolution, profile
    )["binding_sha256"] == binding["binding_sha256"]

    # Builder/reviewer cache policy may differ, but public authority must not.
    reviewer_projection = capability_binding.stable_projection(
        resolve_from(service_cwd, "reviewer"), profile
    )
    assert reviewer_projection == worker_projection

print("OF_LOOP_V099G_CAPABILITY_PROJECTION_CWD=PASS")
PY

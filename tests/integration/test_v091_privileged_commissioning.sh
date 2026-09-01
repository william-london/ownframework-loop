#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
python3 - <<'PY'
import json, os, tempfile
from pathlib import Path
from ownframework_loop import capabilities, commissioning, runtime_env

with tempfile.TemporaryDirectory() as td:
    root=Path(td); repo=root/"repo"; repo.mkdir()
    os.environ["XDG_STATE_HOME"]=str(root/"state")
    cache=runtime_env.repo_tool_cache_dir(repo)
    broker_dir=root/"broker"; broker_dir.mkdir()
    docker=broker_dir/"docker"
    docker.write_text("#!/bin/sh\nif [ \"$1\" = --version ]; then echo broker-v1; fi\n")
    docker.chmod(0o700)
    canary=root/"canary"
    canary.write_text("""#!/usr/bin/env python3
import json,sys
_,flag,name,fingerprint,kind,revision=sys.argv
provider="broker" if name=="container.docker" else "claude_native_safe_local_binding"
print(json.dumps({
 "schema":"ownframework-loop-privileged-canary/v1","ok":True,
 "capability":name,"capability_contract_revision":revision,
 "semantic_runtime_fingerprint":fingerprint,"provider":provider,
 "canary_kind":kind,"canary_version":1
}))
""")
    canary.chmod(0o700)
    manifest=capabilities.default_host_manifest_path(); manifest.parent.mkdir(parents=True, exist_ok=True)

    def write_manifest(capability):
        entry={"provider":"broker","broker_executable":str(docker),"version_args":["--version"],"canary_executable":str(canary)}
        if capability=="local.http-service":
            entry={"provider":"claude_native_safe_local_binding","canary_executable":str(canary)}
        manifest.write_text(json.dumps({
          "schema":capabilities.HOST_MANIFEST_SCHEMA,
          "capabilities":{capability:entry}
        }))
        manifest.chmod(0o600)

    write_manifest("container.docker")
    # Bare declaration/fingerprint is insufficient: canary evidence is mandatory.
    try:
        capabilities.resolve_capabilities(["container.docker"],canonical_repo=repo,role="builder",repo_cache_root=cache)
    except capabilities.CapabilityResolutionError as exc:
        assert "canary-proven" in str(exc)
    else: raise AssertionError("uncanaried Docker resolved")

    docker_evidence=commissioning.commission_capability("container.docker")
    docker_resolution=capabilities.resolve_capabilities(
        ["container.docker"],canonical_repo=repo,role="builder",repo_cache_root=cache
    )
    item=docker_resolution["resolved"][0]
    assert item["commissioning_evidence_sha256"]==docker_evidence["evidence_sha256"]
    assert item["commissioning_canary_kind"]=="docker-broker-local-control"

    # Provider binary drift invalidates canary evidence.
    docker.write_text("#!/bin/sh\necho changed\n"); docker.chmod(0o700)
    try:
        capabilities.resolve_capabilities(["container.docker"],canonical_repo=repo,role="builder",repo_cache_root=cache)
    except capabilities.CapabilityResolutionError as exc:
        assert "drift" in str(exc)
    else: raise AssertionError("Docker provider drift accepted")
    docker.write_text("#!/bin/sh\nif [ \"$1\" = --version ]; then echo broker-v1; fi\n"); docker.chmod(0o700)

    # Local HTTP authority also requires an actually executed canary.
    write_manifest("local.http-service")
    try:
        capabilities.resolve_capabilities(["local.http-service"],canonical_repo=repo,role="builder",repo_cache_root=cache)
    except capabilities.CapabilityResolutionError: pass
    else: raise AssertionError("uncanaried local binding resolved")
    local_evidence=commissioning.commission_capability("local.http-service")
    local=capabilities.resolve_capabilities(
        ["local.http-service"],canonical_repo=repo,role="builder",repo_cache_root=cache
    )
    assert local["sandbox_network"]["allowLocalBinding"] is True
    assert local["resolved"][0]["commissioning_evidence_sha256"]==local_evidence["evidence_sha256"]

print("OF_LOOP_V091_PRIVILEGED_COMMISSIONING=PASS")
PY

#!/usr/bin/env bash
# Regression: deterministic validation must resolve research.public with the
# same per-run evidence identity that was sealed for semantic workers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP_ROOT="$(mktemp -d -t ofloop-validation-binding.XXXXXX)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${TMP_ROOT}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

from ownframework_loop import capability_binding, capabilities, runner_profiles, runtime_env

root = Path(sys.argv[1])
repo = root / "repo"
repo.mkdir()
run_id = "run-20260922T110000Z-aabbccdd"
evidence_dir = runtime_env.research_evidence_dir(run_id)

profile = {
    "name": "primary",
    "provider": "claude-code",
    "model": "MiniMax-M3",
    "effort": "high",
    "identity_sha256": "1" * 64,
    "effort_attestation": {"attestation_sha256": "2" * 64},
}
resolution = {
    "requested": ["research.public"],
    "resolved": [{
        "name": "research.public",
        "kind": "read-only-network",
        "privileged": True,
        "provider": "core_research_broker",
        "executable": str(root / "broker"),
        "version": "0.1.0-dev",
        "executable_sha256": "3" * 64,
        "commissioning_evidence_sha256": "4" * 64,
        "commissioning_canary_kind": "core-research-broker-boundary",
        "network_domains": [],
    }],
    "capability_contract_revision": "host-capability-contract/v2",
    "host_manifest_sha256": "5" * 64,
    "semantic_runtime_fingerprint": "6" * 64,
    "platform_identity": {"platform": "test", "machine": "test"},
    "network_domains": [],
    "sandbox_network": {},
    "stable_filesystem": {"allowRead": [str(evidence_dir)], "allowWrite": []},
    "environment": {"OFLOOP_RESEARCH_EVIDENCE_DIR": str(evidence_dir)},
    "path_prepend": [],
}

projection = capability_binding.stable_projection(resolution, profile)
binding = {
    "schema": capability_binding.SCHEMA,
    "run_id": run_id,
    "projection": projection,
    "binding_sha256": hashlib.sha256(capability_binding._canonical(projection)).hexdigest(),
}
binding_path = capability_binding.binding_path(repo, run_id)
binding_path.parent.mkdir(parents=True)
binding_path.write_text(json.dumps(binding), encoding="utf-8")

seen = {}
original_resolve = capabilities.resolve_capabilities
original_integrity = capabilities.verify_resolution_integrity
original_profile = runner_profiles.resolve_profile
original_verify = runner_profiles.verify_profile_integrity
original_attest = runner_profiles.verify_effort_attestation

def resolve(*args, **kwargs):
    seen["evidence_run_key"] = kwargs.get("evidence_run_key")
    return resolution

capabilities.resolve_capabilities = resolve
capabilities.verify_resolution_integrity = lambda value: None
runner_profiles.resolve_profile = lambda *args, **kwargs: profile
runner_profiles.verify_profile_integrity = lambda value: None
runner_profiles.verify_effort_attestation = lambda value: profile["effort_attestation"]
try:
    runtime_env.commissioned_validation_env(repo, run_id, {"network_read_allowlist": []})
finally:
    capabilities.resolve_capabilities = original_resolve
    capabilities.verify_resolution_integrity = original_integrity
    runner_profiles.resolve_profile = original_profile
    runner_profiles.verify_profile_integrity = original_verify
    runner_profiles.verify_effort_attestation = original_attest

assert seen["evidence_run_key"] == run_id, seen
print("PASS validation resolves research.public with the sealed run evidence key")
PY

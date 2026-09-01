#!/usr/bin/env bash
# Final source-authority regressions (version-neutral).
#
# Focused negative/drift/fail-closed proofs for the closing authority sweep:
#   1. Strict runner-profile truth: singular effective model only when
#      provable; strict model requests fail closed on substitution or on
#      unprovable quality; effort-strict profiles require a commissioned
#      effort attestation (privacy/digest/binding enforced) before any call.
#   2. Commissioning failures normalize through the commissioning error
#      contract: canary timeout and launch failure fail closed with zero
#      evidence written.
#   3. Browser runtime proof: private, freshness-bound to the current
#      platform/runtime and the exact browser asset bytes; automatically
#      stale on asset/fingerprint drift, symlinked or non-private proofs
#      refused. Resolution wires ONE shared immutable asset root read-only
#      for both roles (no per-role browser re-download, reviewer writes stay
#      ephemeral) and distinguishes provisionable from runtime-proven.
#
# No model is called; no physical browser is launched.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"

# ---------- 1. strict runner-profile truth ----------
python3 - <<'PY'
import json, os, sys, tempfile
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import runner_profiles, supervisor

# The truth gate itself: substitution, unprovable quality, and non-strict.
assert supervisor._strict_profile_model_violation(
    "claude-x", result_ok=True, effective_model="claude-y"
) == "runner_profile_model_substitution"
assert supervisor._strict_profile_model_violation(
    "claude-x", result_ok=True, effective_model="claude-x"
) == ""
assert supervisor._strict_profile_model_violation(
    "claude-x", result_ok=True, effective_model=""
) == "runner_profile_quality_unproven"
assert supervisor._strict_profile_model_violation(
    "", result_ok=True, effective_model=""
) == ""
assert supervisor._strict_profile_model_violation(
    "claude-x", result_ok=False, effective_model="claude-y"
) == ""

with tempfile.TemporaryDirectory() as td:
    os.environ["XDG_STATE_HOME"] = str(Path(td) / "state")
    manifest = runner_profiles.default_manifest_path()
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({
        "schema": runner_profiles.MANIFEST_SCHEMA,
        "profiles": {
            "stricty": {"provider": "claude-code", "model": "claude-sonnet-4-6", "effort": "high"},
            "plain": {"provider": "claude-code"},
        },
    }))
    manifest.chmod(0o600)
    stricty = runner_profiles.resolve_profile("stricty", provider="claude-code")
    plain = runner_profiles.resolve_profile("plain", provider="claude-code")
    # Moving aliases cannot masquerade as immutable strict model identity.
    bad_manifest = json.loads(manifest.read_text())
    bad_manifest["profiles"]["alias"] = {"provider": "claude-code", "model": "sonnet"}
    manifest.write_text(json.dumps(bad_manifest)); manifest.chmod(0o600)
    try:
        runner_profiles.resolve_profile("alias", provider="claude-code")
        raise SystemExit("moving strict model alias accepted")
    except runner_profiles.RunnerProfileError:
        pass
    # restore the manifest used by the already-resolved profile integrity checks
    del bad_manifest["profiles"]["alias"]
    manifest.write_text(json.dumps(bad_manifest)); manifest.chmod(0o600)
    assert runner_profiles.public_summary(stricty)["strict_quality"] is True
    assert runner_profiles.public_summary(plain)["strict_quality"] is False

    # Non-strict profiles need no attestation.
    runner_profiles.verify_effort_attestation(plain)
    # Strict effort without commissioning fails closed before any model call.
    try:
        runner_profiles.verify_effort_attestation(stricty)
        raise SystemExit("unattested strict effort accepted")
    except runner_profiles.RunnerProfileError as exc:
        assert "attestation" in str(exc)
    # Operator commissions the attestation; then it verifies.
    runner_profiles.write_effort_attestation(
        name="stricty", provider="claude-code", model="claude-sonnet-4-6", effort="high"
    )
    att_identity = runner_profiles.verify_effort_attestation(stricty)
    assert att_identity and att_identity["attestation_sha256"]
    stricty_bound = dict(stricty)
    stricty_bound["effort_attestation"] = att_identity
    assert runner_profiles.public_summary(stricty_bound)["effort_attestation_sha256"]
    p = runner_profiles.effort_attestation_path("stricty")
    # Attestation is runtime-fresh: changing Claude/runtime identity stales it.
    from ownframework_loop import capabilities
    real_fp = capabilities.semantic_runtime_fingerprint
    capabilities.semantic_runtime_fingerprint = lambda: "f" * 64
    try:
        try:
            runner_profiles.verify_effort_attestation(stricty)
            raise SystemExit("stale runtime effort attestation accepted")
        except runner_profiles.RunnerProfileError as exc:
            assert "runtime" in str(exc) or "fingerprint" in str(exc)
    finally:
        capabilities.semantic_runtime_fingerprint = real_fp
    runner_profiles.verify_effort_attestation(stricty)
    assert p.is_file() and not p.is_symlink()
    assert (p.stat().st_mode & 0o077) == 0
    # A tampered attestation digest fails closed.
    doc = json.loads(p.read_text())
    doc["effort"] = "max"
    p.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    try:
        runner_profiles.verify_effort_attestation(stricty)
        raise SystemExit("tampered effort attestation accepted")
    except runner_profiles.RunnerProfileError:
        pass
    # Rewrite valid but for the WRONG effort: binding mismatch refused.
    runner_profiles.write_effort_attestation(
        name="stricty", provider="claude-code", model="claude-sonnet-4-6", effort="max"
    )
    try:
        runner_profiles.verify_effort_attestation(stricty)
        raise SystemExit("wrong-effort attestation accepted")
    except runner_profiles.RunnerProfileError:
        pass
    runner_profiles.write_effort_attestation(
        name="stricty", provider="claude-code", model="sonnet", effort="high"
    )
    # A symlinked attestation is refused.
    real = p.read_text()
    target = p.with_name("effort-attestation-target.json")
    target.write_text(real)
    os.chmod(target, 0o600)
    p.unlink()
    os.symlink(target, p)
    try:
        runner_profiles.verify_effort_attestation(stricty)
        raise SystemExit("symlinked effort attestation accepted")
    except runner_profiles.RunnerProfileError:
        pass
print("1 strict runner-profile truth ok")
PY
pass "strict profiles fail closed: substitution, unproven quality, unattested effort"

# ---------- 2. commissioning failure normalization ----------
python3 - <<'PY'
import json, os, sys, tempfile
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import capabilities, commissioning

with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    os.environ["XDG_STATE_HOME"] = str(root / "state")
    manifest = capabilities.default_host_manifest_path()
    manifest.parent.mkdir(parents=True, exist_ok=True)

    hanging = root / "canary-hang"
    hanging.write_text("#!/bin/sh\nsleep 5\n")
    hanging.chmod(0o700)
    unlaunchable = root / "canary-unlaunchable"
    unlaunchable.write_text("#!/nonexistent/ofloop-interp\necho hi\n")
    unlaunchable.chmod(0o700)

    def write_manifest(canary_path):
        manifest.write_text(json.dumps({
            "schema": capabilities.HOST_MANIFEST_SCHEMA,
            "capabilities": {
                "local.http-service": {
                    "provider": "claude_native_safe_local_binding",
                    "canary_executable": str(canary_path),
                },
            },
        }))
        manifest.chmod(0o600)

    # Canary timeout fails closed through the commissioning error contract.
    write_manifest(hanging)
    try:
        commissioning.commission_capability(
            "local.http-service", timeout_seconds=0.3
        )
        raise SystemExit("hanging canary commissioned")
    except commissioning.CommissioningError as exc:
        assert "timed out" in str(exc), exc
    assert not commissioning.evidence_path("local.http-service").exists()

    # Canary launch failure fails closed through the same contract.
    write_manifest(unlaunchable)
    try:
        commissioning.commission_capability("local.http-service")
        raise SystemExit("unlaunchable canary commissioned")
    except commissioning.CommissioningError as exc:
        assert "launch failed" in str(exc), exc
    assert not commissioning.evidence_path("local.http-service").exists()
print("2 commissioning failure normalization ok")
PY
pass "canary timeout/launch failures fail closed through the commissioning contract"

# ---------- 3. browser proof: private, freshness-bound, shared read-only ----------
python3 - <<'PY'
import hashlib, json, os, sys, tempfile
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB"))
from ownframework_loop import capabilities

with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    os.environ["XDG_STATE_HOME"] = str(root / "state")
    repo = root / "repo"; repo.mkdir()
    (repo / ".ownframework-loop" / "r1").mkdir(parents=True)

    # The shared immutable asset tree the canary would prove.
    asset_root = capabilities.default_browser_asset_dir()
    chromium_dir = asset_root / "chromium-9999"
    chromium_dir.mkdir(parents=True)
    (chromium_dir / "chrome").write_bytes(b"fake-browser-binary")
    (chromium_dir / "manifest.json").write_text("{}")
    os.chmod(asset_root, 0o700)
    merkle = capabilities.browser_asset_merkle_sha256(asset_root)

    proof = capabilities.write_browser_runtime_proof(
        "browser.playwright.chromium",
        asset_root=str(asset_root),
        asset_merkle_sha256=merkle,
        playwright_version="9.9.9",
        browser_version="9999",
    )
    proof_path = Path(proof["proof_path"])
    assert (proof_path.stat().st_mode & 0o077) == 0

    proven, reason = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert proven, reason

    # Asset drift stales the proof automatically (tampered binary byte).
    (chromium_dir / "chrome").write_bytes(b"tampered-browser-binary")
    proven, reason = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert not proven and "asset drift" in reason, (proven, reason)
    (chromium_dir / "chrome").write_bytes(b"fake-browser-binary")
    # New untracked file in the asset tree is also drift.
    extra = chromium_dir / "injected.so"
    extra.write_bytes(b"x")
    proven, reason = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert not proven and "asset drift" in reason, (proven, reason)
    extra.unlink()
    proven, _ = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert proven

    # Runtime-fingerprint drift stales the proof even with intact assets.
    doc = json.loads(proof_path.read_text())
    doc["semantic_runtime_fingerprint"] = "deadbeef" * 8
    body = {k: v for k, v in doc.items() if k != "proof_sha256"}
    doc["proof_sha256"] = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    ).hexdigest()
    proof_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    proven, reason = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert not proven and "runtime fingerprint drift" in reason, (proven, reason)
    # Restore the valid proof.
    fresh = capabilities.write_browser_runtime_proof(
        "browser.playwright.chromium",
        asset_root=str(asset_root),
        asset_merkle_sha256=merkle,
        playwright_version="9.9.9",
        browser_version="9999",
    )

    # A non-private proof is refused.
    os.chmod(proof_path, 0o644)
    proven, reason = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert not proven and "private" in reason, (proven, reason)
    os.chmod(proof_path, 0o600)
    # A symlinked proof is refused.
    real_bytes = proof_path.read_bytes()
    target = proof_path.with_name("proof-target.json")
    target.write_bytes(real_bytes)
    os.chmod(target, 0o600)
    proof_path.unlink()
    os.symlink(target, proof_path)
    proven, reason = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert not proven and "commissioned" in reason, (proven, reason)
    os.unlink(proof_path)
    proof_path.write_bytes(real_bytes)
    os.chmod(proof_path, 0o600)

    # Missing asset root stales the proof.
    moved = root / "assets-moved"
    asset_root.rename(moved)
    proven, reason = capabilities._browser_runtime_proven("browser.playwright.chromium")
    assert not proven and "asset root" in reason, (proven, reason)
    moved.rename(asset_root)

    # Directory symlinks are part of the authority tree and must be refused.
    link_target = root / "link-target"; link_target.mkdir()
    linkdir = chromium_dir / "linked-dir"; os.symlink(link_target, linkdir)
    try:
        capabilities.browser_asset_merkle_sha256(asset_root)
        raise SystemExit("browser directory symlink accepted")
    except capabilities.CapabilityResolutionError:
        pass
    linkdir.unlink()

    # A proof for asset A can never authorize resolution to asset B.
    other_root = root / "other-browser-assets"; other_root.mkdir()
    (other_root / "chrome").write_bytes(b"other")
    try:
        capabilities.resolve_capabilities(
            ["browser.playwright.chromium"],
            canonical_repo=repo, role="builder",
            repo_cache_root=root / "cache-other",
            packet_network_allowlist=[],
            browser_asset_root=other_root,
        )
        raise SystemExit("browser proof A authorized asset B")
    except capabilities.CapabilityResolutionError as exc:
        assert "different asset root" in str(exc) or "not execution-ready" in str(exc), exc

    # Resolution wires ONE shared immutable asset root for BOTH roles:
    # read-only authority, PLAYWRIGHT_BROWSERS_PATH bound to it, never a
    # per-role mutable browser cache, explicit proven/provisionable flags.
    for role in ("builder", "reviewer"):
        res = capabilities.resolve_capabilities(
            ["browser.playwright.chromium"],
            canonical_repo=repo, role=role,
            repo_cache_root=root / f"cache-{role}",
            packet_network_allowlist=[],
        )
        item = res["resolved"][0]
        browser_meta = item.get("browser") or {}
        assert item["cache_scope"] == "commissioned_shared_read_only", item
        assert item["cache_path"] == str(asset_root), item
        assert browser_meta["runtime_proven"] is True, browser_meta
        assert browser_meta["browser_asset_root"] == str(asset_root), browser_meta
        assert browser_meta["browser_asset_merkle_sha256"] == merkle, browser_meta
        assert browser_meta["browser_proof_sha256"], browser_meta
        assert "provisionable" in browser_meta, browser_meta
        assert res["environment"]["PLAYWRIGHT_BROWSERS_PATH"] == str(asset_root)
        assert res["environment"]["PLAYWRIGHT_SKIP_BROWSER_GC"] == "1"
        assert str(asset_root) in res["filesystem"]["allowRead"]
        assert str(asset_root) not in res["filesystem"]["allowWrite"]
        assert str(asset_root) in res["stable_filesystem"]["allowRead"]
    # Browser identity participates in the immutable run binding.
    from ownframework_loop import capability_binding, runner_profiles
    projection = capability_binding.stable_projection(
        res, runner_profiles.resolve_profile("default", provider="claude-code")
    )
    assert projection["capabilities"][0]["browser"]["browser_asset_merkle_sha256"] == merkle
    # Host-manifest trusted asset roots refuse unresolved symlinks.
    manifest = capabilities.default_host_manifest_path()
    manifest.parent.mkdir(parents=True, exist_ok=True)
    real_asset = root / "trusted-real"
    real_asset.mkdir()
    (real_asset / "x").write_text("x")
    linked_asset = root / "trusted-link"
    os.symlink(real_asset, linked_asset)
    manifest.write_text(json.dumps({
        "schema": capabilities.HOST_MANIFEST_SCHEMA,
        "capabilities": {
            "toolchain.synthetic": {
                "kind": "tool",
                "executable": sys.executable,
                "trusted_asset_path": str(linked_asset),
            }
        },
    }))
    manifest.chmod(0o600)
    try:
        capabilities.resolve_capabilities(
            ["toolchain.synthetic"],
            canonical_repo=repo,
            role="builder",
            repo_cache_root=root / "trusted-cache",
            packet_network_allowlist=[],
        )
        raise SystemExit("symlinked trusted asset root accepted")
    except capabilities.CapabilityResolutionError:
        pass
print("3 browser proof freshness + shared read-only wiring ok")
PY
pass "browser proof is private, freshness-bound, auto-stale on drift; assets shared read-only"

echo "OF_LOOP_SOURCE_AUTHORITY_FINAL=PASS"

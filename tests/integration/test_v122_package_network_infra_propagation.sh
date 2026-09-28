#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 -B - "$TMP" "$ROOT_DIR" <<'PY'
import hashlib
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
repo = root / "repo"
repo.mkdir()
run_id = "run-20260927T000000Z-v122-review"
candidate = repo / ".worktrees" / "ownframework-loop" / run_id / "reviewer"
candidate.mkdir(parents=True)
scripts = candidate / "scripts"
scripts.mkdir()
wrapper = scripts / "check.sh"
wrapper.write_text(
    """#!/usr/bin/env bash
set -euo pipefail
if command -v uv >/dev/null 2>&1; then
  if ! (cd apps/api && uv venv .venv >/dev/null 2>&1); then
    :
  fi
  (cd apps/api && uv pip install --python .venv/bin/python -e '.[dev]' --quiet) || true
fi
""",
    encoding="utf-8",
)
wrapper.chmod(0o755)
subprocess.run(["git", "init", "-q", str(candidate)], check=True)
subprocess.run(
    ["git", "-C", str(candidate), "config", "user.name", "Loop test"],
    check=True,
)
subprocess.run(
    ["git", "-C", str(candidate), "config", "user.email", "loop-test@example.invalid"],
    check=True,
)
subprocess.run(["git", "-C", str(candidate), "add", "scripts/check.sh"], check=True)
subprocess.run(
    ["git", "-C", str(candidate), "commit", "-qm", "Add validation wrapper"],
    check=True,
)
candidate_sha = subprocess.check_output(
    ["git", "-C", str(candidate), "rev-parse", "HEAD"], text=True
).strip()

from ownframework_loop import process_runner, review_finalize, runtime_env, validation_environment, validation_evidence, util
from ownframework_loop import validation_executor as vx, validation_network
from ownframework_loop import supervisor_validation_recovery as recovery

assert validation_environment.classify_validation_uv_command(
    "bash scripts/check.sh", cwd=candidate, candidate_sha=candidate_sha
) == "wrapped-uv"
assert validation_environment.classify_uv_shell_script(
    "# uv pip install is only a comment\necho 'ordinary validation'\n"
) == "none"
assert validation_environment.classify_uv_shell_script(
    "echo 'uv pip install'\n"
) == "ambiguous"
original_wrapper = wrapper.read_text(encoding="utf-8")
wrapper.write_text(original_wrapper + "# worktree drift\n", encoding="utf-8")
assert validation_environment.classify_validation_uv_command(
    "bash scripts/check.sh", cwd=candidate, candidate_sha=candidate_sha
) == "ambiguous"
wrapper.write_text(original_wrapper, encoding="utf-8")

# The host-side broker reports only failures after the frozen package-host
# allowlist has admitted a CONNECT. Candidate output and policy denials cannot
# manufacture this event.
events = []
real_getaddrinfo = socket.getaddrinfo

def fail_registry_dns(host, *args, **kwargs):
    if str(host).lower().rstrip(".") == "pypi.org":
        raise socket.gaierror("nodename nor servname provided, or not known")
    return real_getaddrinfo(host, *args, **kwargs)

socket.getaddrinfo = fail_registry_dns
try:
    with validation_network._PackageProxy(["pypi.org"], events.append) as proxy:
        client = socket.create_connection(("127.0.0.1", proxy.port), timeout=3)
        client.sendall(b"CONNECT pypi.org:443 HTTP/1.1\r\nHost: pypi.org:443\r\n\r\n")
        response = client.recv(1024)
        client.close()
        assert response.startswith(b"HTTP/1.1 403"), response
        assert events == [{
            "kind": "dns_resolution_failed",
            "host": "pypi.org",
            "port": 443,
            "broker": "connect_proxy",
        }], events

        denied = socket.create_connection(("127.0.0.1", proxy.port), timeout=3)
        denied.sendall(b"CONNECT attacker.invalid:443 HTTP/1.1\r\nHost: attacker.invalid:443\r\n\r\n")
        assert denied.recv(1024).startswith(b"HTTP/1.1 403")
        denied.close()
        assert len(events) == 1, events
finally:
    socket.getaddrinfo = real_getaddrinfo

print("BROKER_ALLOWED_REGISTRY_DNS_EVENT=PASS")
print("BROKER_POLICY_DENIAL_NOT_INFRA_EVENT=PASS")

# Exercise the actual validation executor boundary with a declared package.uv
# capability and a shell wrapper. The fake host runner injects the same
# structured broker event produced above; stderr deliberately contains the
# historical DNS wording so the test proves classification comes from the
# broker event, not an error-string heuristic.
fake_uv = root / "uv"
fake_uv.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
fake_uv.chmod(0o700)
uv_sha = hashlib.sha256(fake_uv.read_bytes()).hexdigest()
resolution = {"resolved": [{
    "name": "package.uv",
    "executable": str(fake_uv),
    "version": "uv test-fixture",
    "executable_sha256": uv_sha,
    "network_domains": ["pypi.org"],
    "cache_path": "",
    "cache_scope": "fixture",
}]}

originals = []
network_domains_seen = []
resolution_calls = []
snapshot_calls = []

def patch(obj, name, value):
    originals.append((obj, name, getattr(obj, name)))
    setattr(obj, name, value)

mode = {"broker_event": True, "host": "pypi.org"}

def run_wrapper(_argv, **kwargs):
    network_domains_seen.append(tuple(kwargs["package_network_domains"]))
    kwargs["stderr_fh"].write(
        b"Failed to fetch https://pypi.org/simple/ruff/: DNS lookup failed\n"
    )
    if mode["broker_event"]:
        kwargs["package_network_failures"].append({
            "kind": "dns_resolution_failed",
            "host": mode["host"],
            "port": 443,
            "broker": "connect_proxy",
        })
    return process_runner.CommandResult(returncode=1, stdout="", timed_out=False)

try:
    patch(vx.validation_policy, "classify_required_validation", lambda *_a, **_k: {"allowed": True})
    def resolve_uv(*_args, **_kwargs):
        resolution_calls.append(True)
        return resolution
    patch(vx.runtime_env, "commissioned_validation_resolution", resolve_uv)
    patch(vx.runtime_env, "commissioned_validation_env", lambda *_a, **_k: {})
    def snapshot_uv(*_args, **_kwargs):
        snapshot_calls.append(True)
        return fake_uv, root
    patch(vx.validation_environment, "snapshot_bound_uv", snapshot_uv)
    patch(vx.validation_environment, "verify_bound_uv_identity", lambda *_a, **_k: None)
    patch(vx.validation_environment, "_read_bound_executable", lambda *_a, **_k: (fake_uv.read_bytes(), 0o700))
    patch(vx.validation_network, "run_isolated_to_files", run_wrapper)

    validation = {
        "name": "wrapped-uv-validation",
        "command": "bash scripts/check.sh",
        "kind": "fast",
        "expected_exit_code": 0,
    }
    packet = {"capabilities": ["toolchain.python", "package.uv"]}
    infra_path = root / "infra.json"
    result = vx.run_required_validation(
        cwd=candidate,
        validation=validation,
        timeout_seconds=15,
        canonical_repo=repo,
        run_id=run_id,
        packet=packet,
        candidate_sha=candidate_sha,
        role="reviewer",
        infra_failure_path=infra_path,
        checkpoint_id="CP-01",
        pass_number=1,
        validation_index=0,
    )
    assert result["infra_failure"] is True, result
    assert result["passed"] is False, result
    assert result["infra_failure_reason"] == "package_registry_dns_resolution_failed:pypi.org", result
    route = review_finalize._validation_failure_verdict(
        infra_failure_count=int(bool(result["infra_failure"])),
        candidate_invalid_count=int(bool(result["candidate_invalid"])),
        validation_pass=bool(result["passed"]),
    )
    assert route == ("BLOCKED", "infra_failure"), route
    assert route[0] != "CHANGES_REQUESTED", route
    assert resolution_calls == [True], resolution_calls
    assert snapshot_calls == [True], snapshot_calls
    assert network_domains_seen[-1] == ("pypi.org",), network_domains_seen
    marker = __import__("json").loads(infra_path.read_text())
    assert marker["package_network_failures"][0]["host"] == "pypi.org", marker

    first_ref = result["infrastructure_evidence"]
    assert first_ref["schema"] == validation_evidence.SCHEMA, first_ref
    first_evidence_path = util.run_dir(repo, run_id) / first_ref["relative_path"]
    assert first_evidence_path.stat().st_mode & 0o777 == 0o600
    assert hashlib.sha256(first_evidence_path.read_bytes()).hexdigest() == first_ref["sha256"]
    first_identity = validation_evidence.validation_identity(
        canonical_repo=repo,
        run_id=run_id,
        checkpoint_id="CP-01",
        role="reviewer",
        pass_number=1,
        validation_index=0,
        candidate_sha=candidate_sha,
        cwd=candidate,
        validation=validation,
    )
    record, _ = validation_evidence.verify_reference(
        canonical_repo=repo, run_id=run_id, reference=first_ref,
        expected_identity=first_identity,
    )
    assert validation_evidence.proves_registry_dns_failure(
        record=record, allowed_domains={"pypi.org", "files.pythonhosted.org"}
    )

    # Identical cwd+command on a later review pass has a distinct immutable
    # evidence identity even though runtime-cache diagnostics are reused.
    second = vx.run_required_validation(
        cwd=candidate,
        validation=validation,
        timeout_seconds=15,
        canonical_repo=repo,
        run_id=run_id,
        packet=packet,
        candidate_sha=candidate_sha,
        role="reviewer",
        infra_failure_path=infra_path,
        checkpoint_id="CP-01",
        pass_number=2,
        validation_index=0,
    )
    second_ref = second["infrastructure_evidence"]
    assert second_ref["evidence_id"] != first_ref["evidence_id"]
    assert second_ref["relative_path"] != first_ref["relative_path"]
    assert hashlib.sha256(first_evidence_path.read_bytes()).hexdigest() == first_ref["sha256"]
    second_evidence_path = util.run_dir(repo, run_id) / second_ref["relative_path"]
    second_evidence_path.unlink()
    try:
        validation_evidence.verify_reference(
            canonical_repo=repo, run_id=run_id, reference=second_ref,
            expected_identity=validation_evidence.validation_identity(
                canonical_repo=repo, run_id=run_id, checkpoint_id="CP-01",
                role="reviewer", pass_number=2, validation_index=0,
                candidate_sha=candidate_sha, cwd=candidate, validation=validation,
            ),
        )
    except RuntimeError as exc:
        assert "missing" in str(exc) or "redirected" in str(exc), exc
    else:
        raise AssertionError("missing durable validation evidence was accepted")
    duplicate = vx.run_required_validation(
        cwd=candidate,
        validation=validation,
        timeout_seconds=15,
        canonical_repo=repo,
        run_id=run_id,
        packet=packet,
        candidate_sha=candidate_sha,
        role="reviewer",
        infra_failure_path=infra_path,
        checkpoint_id="CP-01",
        pass_number=1,
        validation_index=0,
    )
    assert duplicate["infrastructure_evidence"] == first_ref
    mode["host"] = "files.pythonhosted.org"
    try:
        vx.run_required_validation(
            cwd=candidate, validation=validation, timeout_seconds=15,
            canonical_repo=repo, run_id=run_id, packet=packet,
            candidate_sha=candidate_sha, role="reviewer",
            infra_failure_path=infra_path, checkpoint_id="CP-01",
            pass_number=1, validation_index=0,
        )
    except RuntimeError as exc:
        assert "identity collision" in str(exc), exc
    else:
        raise AssertionError("contradictory same-pass evidence was overwritten")
    mode["host"] = "pypi.org"

    # Deleting the complete ephemeral cache cannot remove recovery authority.
    shutil.rmtree(runtime_env.runtime_cache_dir(repo, run_id, "validation"))
    recovery_binding = recovery._proves_permitted_registry_dns_failure(
        dict(result),
        allowed_domains={"pypi.org", "files.pythonhosted.org"},
        canonical_repo=repo,
        run_id=run_id,
        checkpoint_id="CP-01",
        candidate_sha=candidate_sha,
        review_pass_number=1,
    )
    assert recovery_binding and recovery_binding["sha256"] == first_ref["sha256"]
    assert recovery._proves_permitted_registry_dns_failure(
        dict(result),
        allowed_domains={"registry.npmjs.org"},
        canonical_repo=repo,
        run_id=run_id,
        checkpoint_id="CP-01",
        candidate_sha=candidate_sha,
        review_pass_number=1,
    ) is None
    assert recovery._proves_permitted_registry_dns_failure(
        {**result, "infrastructure_evidence": {**first_ref, "sha256": "0" * 64}},
        allowed_domains={"pypi.org"},
        canonical_repo=repo,
        run_id=run_id,
        checkpoint_id="CP-01",
        candidate_sha=candidate_sha,
        review_pass_number=1,
    ) is None
    assert validation_evidence.event_references([result]) == [{
        "validation_index": 0,
        "evidence_id": first_ref["evidence_id"],
        "sha256": first_ref["sha256"],
    }]

    # Text which resembles DNS trouble is not sufficient without a structured
    # event from the trusted package broker.
    mode["broker_event"] = False
    plain = vx.run_required_validation(
        cwd=candidate,
        validation={**validation, "command": "python -c 'print(1)'"},
        timeout_seconds=15,
        canonical_repo=repo,
        run_id="run-20260927T000001Z-v122-fake-stderr",
        packet=packet,
        candidate_sha=candidate_sha,
        role="reviewer",
        checkpoint_id="CP-01",
        pass_number=1,
        validation_index=0,
    )
    assert plain["infra_failure"] is False, plain
    assert plain["passed"] is False and plain["exit_code"] == 1, plain
    assert "infrastructure_evidence" not in plain, plain
    plain_route = review_finalize._validation_failure_verdict(
        infra_failure_count=int(bool(plain["infra_failure"])),
        candidate_invalid_count=int(bool(plain["candidate_invalid"])),
        validation_pass=bool(plain["passed"]),
    )
    assert plain_route == ("CHANGES_REQUESTED", "validation_failed"), plain_route
    assert len(resolution_calls) == 4, resolution_calls
    assert len(snapshot_calls) == 4, snapshot_calls
    assert network_domains_seen[-1] == (), network_domains_seen
finally:
    for obj, name, original in reversed(originals):
        setattr(obj, name, original)

print("WRAPPED_PACKAGE_FAILURE_TO_INFRA_FAILURE=PASS")
print("CANDIDATE_STDERR_CANNOT_FORGE_INFRA=PASS")
print("DURABLE_REGISTRY_DNS_EVIDENCE_PASS_BOUND=PASS")
print("REPEATED_REVIEW_EVIDENCE_IS_IMMUTABLE=PASS")
print("RUNTIME_CACHE_LOSS_DOES_NOT_REMOVE_RECOVERY_AUTHORITY=PASS")
print("CONTRADICTORY_DURABLE_EVIDENCE_FAILS_CLOSED=PASS")

# Candidate-controlled PYTHONPATH must not be required to import Loop's
# pytest plugin. Caller-provided plugins remain untouched.
loop_plugin = "ownframework_loop._pytest_plugins.of_disable_cache"
base = dict(os.environ)
base["PYTEST_PLUGINS"] = loop_plugin
env = runtime_env.hermetic_subprocess_env(repo, "run-v122-pytest-env", "validation", base_env=base)
assert loop_plugin not in env.get("PYTEST_PLUGINS", ""), env.get("PYTEST_PLUGINS")
base["PYTEST_PLUGINS"] = "pytest_cov.plugin," + loop_plugin
preserved = runtime_env.hermetic_subprocess_env(repo, "run-v122-caller-plugin", "validation", base_env=base)
assert preserved.get("PYTEST_PLUGINS") == "pytest_cov.plugin", preserved.get("PYTEST_PLUGINS")

project = root / "src-layout"
(project / "src" / "samplepkg").mkdir(parents=True)
(project / "tests").mkdir()
(project / "src" / "samplepkg" / "__init__.py").write_text("", encoding="utf-8")
(project / "src" / "samplepkg" / "core.py").write_text("VALUE = 7\n", encoding="utf-8")
env["PYTHONPATH"] = "src"
env.pop("PYTEST_PLUGINS", None)
run = subprocess.run(
    [sys.executable, "-c", "from samplepkg.core import VALUE; assert VALUE == 7"],
    cwd=project,
    env=env,
    capture_output=True,
    text=True,
    timeout=30,
)
assert run.returncode == 0, run.stdout + run.stderr
print("SRC_LAYOUT_IMPORT_WITH_CANDIDATE_PYTHONPATH=PASS")
assert loop_plugin not in preserved.get("PYTEST_PLUGINS", "")
print("LOOP_PYTEST_PLUGIN_NOT_INJECTED=PASS")
PY

echo "VALIDATION_INFRA_PROXY_PROPAGATION=PASS"

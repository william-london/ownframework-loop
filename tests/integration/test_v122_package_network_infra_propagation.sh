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
import socket
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
repo = root / "repo"
repo.mkdir()
candidate = root / "candidate"
candidate.mkdir()
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

from ownframework_loop import process_runner, review_finalize, runtime_env, validation_environment
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

mode = {"broker_event": True}

def run_wrapper(_argv, **kwargs):
    network_domains_seen.append(tuple(kwargs["package_network_domains"]))
    kwargs["stderr_fh"].write(
        b"Failed to fetch https://pypi.org/simple/ruff/: DNS lookup failed\n"
    )
    if mode["broker_event"]:
        kwargs["package_network_failures"].append({
            "kind": "dns_resolution_failed",
            "host": "pypi.org",
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
        run_id="run-v122-infra-event",
        packet=packet,
        candidate_sha=candidate_sha,
        role="reviewer",
        infra_failure_path=infra_path,
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

    # The one-use historical recovery accepts the exact executor-owned
    # diagnostic only when its digest, private path, DNS signature, and host
    # all match the frozen package.uv authority.
    diagnostic_root = root / "validation-diagnostics"
    diagnostic_root.mkdir(mode=0o700)
    os.chmod(diagnostic_root, 0o700)
    diagnostic_path = diagnostic_root / "review.stderr"
    diagnostic_bytes = (
        b"error: Request failed after retries\n"
        b"Failed to fetch: `https://pypi.org/simple/ruff/`\n"
        b"cause: dns error\n"
        b"failed to lookup address information: nodename nor servname provided, or not known\n"
    )
    diagnostic_path.write_bytes(diagnostic_bytes)
    os.chmod(diagnostic_path, 0o600)
    historical_row = {
        "passed": False,
        "infra_failure": False,
        "candidate_invalid": False,
        "stderr_truncated": False,
        "stderr_sha256": hashlib.sha256(diagnostic_bytes).hexdigest(),
        "diagnostic_stderr_path": str(diagnostic_path),
    }
    assert recovery._proves_permitted_registry_dns_failure(
        historical_row,
        allowed_domains={"pypi.org", "files.pythonhosted.org"},
        diagnostic_root=diagnostic_root,
    )
    assert not recovery._proves_permitted_registry_dns_failure(
        historical_row,
        allowed_domains={"registry.npmjs.org"},
        diagnostic_root=diagnostic_root,
    )
    assert not recovery._proves_permitted_registry_dns_failure(
        {**historical_row, "stderr_sha256": "0" * 64},
        allowed_domains={"pypi.org"},
        diagnostic_root=diagnostic_root,
    )

    # Text which resembles DNS trouble is not sufficient without a structured
    # event from the trusted package broker.
    mode["broker_event"] = False
    plain = vx.run_required_validation(
        cwd=candidate,
        validation={**validation, "command": "python -c 'print(1)'"},
        timeout_seconds=15,
        canonical_repo=repo,
        run_id="run-v122-output-is-not-authority",
        packet=packet,
        candidate_sha=candidate_sha,
        role="reviewer",
    )
    assert plain["infra_failure"] is False, plain
    assert plain["passed"] is False and plain["exit_code"] == 1, plain
    plain_route = review_finalize._validation_failure_verdict(
        infra_failure_count=int(bool(plain["infra_failure"])),
        candidate_invalid_count=int(bool(plain["candidate_invalid"])),
        validation_pass=bool(plain["passed"]),
    )
    assert plain_route == ("CHANGES_REQUESTED", "validation_failed"), plain_route
    assert resolution_calls == [True], resolution_calls
    assert snapshot_calls == [True], snapshot_calls
    assert network_domains_seen[-1] == (), network_domains_seen
finally:
    for obj, name, original in reversed(originals):
        setattr(obj, name, original)

print("WRAPPED_PACKAGE_FAILURE_TO_INFRA_FAILURE=PASS")
print("CANDIDATE_STDERR_CANNOT_FORGE_INFRA=PASS")
print("HISTORICAL_REGISTRY_DNS_RECOVERY_EVIDENCE_BOUND=PASS")

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

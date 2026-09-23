"""Claude Code supervisor runner implementation.

This is one provider implementation behind supervisor_runner_registry's generic
contract. It owns Claude-specific invocation, sandbox/settings construction,
provider-version observation, subprocess lifecycle, and failure observation.
It does not own durable retry/quarantine policy.
"""
from __future__ import annotations

import json
import math
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

from . import capabilities as capabilities_mod
from . import capability_binding as capability_binding_mod
from . import dispatch as dispatch_mod
from . import git_checks
from . import process_runner
from . import runner_profiles as runner_profiles_mod
from . import runtime_env
from . import supervisor_accounting as _accounting_mod
from . import supervisor_db as _db_mod
from . import supervisor_prompts as _prompts_mod
from . import supervisor_runner_io as _runner_io_mod
from . import supervisor_runner_registry as _runner_registry_mod

RunnerResult = _runner_registry_mod.RunnerResult
RunnerReadiness = _runner_registry_mod.RunnerReadiness
RUNNER_DIAGNOSTIC_MAX_CHARS = _runner_io_mod.RUNNER_DIAGNOSTIC_MAX_CHARS

CLAUDE_BUILDER_TOOLS = "Read,Edit,Write,NotebookEdit,Bash,Glob,Grep"

CLAUDE_REVIEWER_TOOLS = "Read,Bash,Glob,Grep"

_WORKER_RELEASE_GATE_CODE = r"""
import os
import sys
fd = int(sys.argv[1])
try:
    token = os.read(fd, 1)
finally:
    os.close(fd)
if token != b"1":
    os._exit(125)
argv = sys.argv[2:]
if not argv:
    os._exit(126)
os.execvpe(argv[0], argv, os.environ)
"""

MIN_SECURE_CLAUDE_CODE_VERSION = (2, 1, 248)

class WorkerLaunchError(RuntimeError):
    """The semantic process provably failed before a child existed."""

def _claude_cli_version(executable: str) -> tuple[int, int, int] | None:
    """Return Claude Code semantic version, or None when it cannot be proven."""
    try:
        proc = process_runner.run_bounded_capture(
            [executable, "--version"],
            timeout_seconds=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    match = re.search(r"(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)", proc.stdout or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())

def _validate_claude_extra_args(extra: list[str]) -> None:
    """Semantic-worker invocation has no free-form Claude CLI extension point.

    Claude's CLI surface evolves and includes model fallbacks, custom agents,
    prompt replacement, hooks, cloud execution, worktrees and permission
    controls. A denylist can only lag that authority surface. Model/effort are
    typed runner-profile authority and budgets are supervisor-owned; every
    other semantic invocation flag is core-owned.
    """
    if extra:
        raise RuntimeError(
            "OFLOOP_CLAUDE_EXTRA_ARGS may not override semantic-worker "
            "invocation authority; free-form Claude arguments are disabled"
        )

def _parse_adapter_auth_read_paths() -> list[str]:
    """Resolve exact private credential files an adapter may read.

    The semantic Bash sandbox denies the operator's entire home. A platform
    installer may reopen only a concrete credential FILE (never an auth/config
    directory). Each path must be absolute, existing, owned by the current user,
    and have no group/other permission bits. Malformed/loose entries are dropped
    rather than widening the sandbox.
    """
    raw = os.environ.get("OFLOOP_ADAPTER_AUTH_READ_PATHS", "").strip()
    if not raw:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for entry in raw.split(","):
        candidate = entry.strip()
        if not candidate:
            continue
        p = Path(candidate).expanduser()
        if not p.is_absolute() or p.is_symlink():
            continue
        try:
            resolved_path = p.resolve(strict=True)
            st = resolved_path.stat()
        except (OSError, RuntimeError):
            continue
        resolved = str(resolved_path)
        if resolved in seen:
            continue
        seen.add(resolved)
        if not stat.S_ISREG(st.st_mode):
            continue
        if hasattr(os, "getuid") and st.st_uid != os.getuid():
            continue
        if stat.S_IMODE(st.st_mode) & 0o077:
            continue
        out.append(resolved)
    return out

def _semantic_worker_settings(
    *,
    canonical_repo: Path,
    run_id: str,
    role: str,
    worktree: Path,
    semantic_path: Path,
    network_read_allowlist: list[str] | None = None,
    capability_resolution: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Fail-closed Claude settings for one unattended semantic worker.

    The Bash sandbox is intentionally narrower than the Edit/Write hook
    boundary: builder commands may write the builder worktree; reviewer
    commands may not mutate the exact-SHA reviewer worktree; both roles may
    write only their pass-scoped semantic-result directory and Loop's
    externalized runtime cache outside the worktree.

    --restricted excludes user/project/local settings from the semantic worker.
    Managed policy remains the explicit organization-owned trust boundary;
    Loop supplies the pass-specific sandbox through CLI --settings.
    """
    cache_root = runtime_env.runtime_cache_path(canonical_repo, run_id, role)

    # Restricted mode already confines built-in Read/Edit/Write to the working
    # directories. Bash is explicitly re-enabled for local compilers/tests/git,
    # so give Bash the complementary OS-level read boundary: deny the operator's
    # entire home directory, then re-open only the current pass and trusted Loop
    # runtime surfaces. More-specific allowRead wins over the broad denyRead.
    home = Path.home().expanduser().resolve(strict=False)
    run_evidence_dir = (canonical_repo / ".ownframework-loop" / run_id).resolve(strict=False)
    capability_resolution = capability_resolution or {}
    capability_fs = capability_resolution.get("filesystem") or {}
    capability_allow_read = {
        str(Path(p).expanduser().resolve(strict=False))
        for p in (capability_fs.get("allowRead") or [])
    }
    capability_allow_write = {
        str(Path(p).expanduser().resolve(strict=False))
        for p in (capability_fs.get("allowWrite") or [])
    }
    allow_read = sorted({
        str(worktree.resolve(strict=False)),
        str(semantic_path.parent.resolve(strict=False)),
        str(run_evidence_dir),
        str(cache_root.resolve(strict=False)),
        str((git_checks.git_common_dir(canonical_repo) or (canonical_repo / ".git")).resolve(strict=False)),
        str(_prompts_mod._source_root().resolve(strict=False)),
        *_parse_adapter_auth_read_paths(),
        *capability_allow_read,
    })
    allow_write = sorted({
        str(cache_root.resolve(strict=False)),
        str(semantic_path.parent.resolve(strict=False)),
        *capability_allow_write,
    })
    state_root = _db_mod.default_db_path().parent.expanduser().resolve(strict=False)
    # Raw container-daemon sockets are root-equivalent host authority. Even
    # when a Docker broker capability is commissioned, the semantic worker
    # must not bypass that broker by addressing a conventional daemon socket.
    raw_container_sockets = {
        "/var/run/docker.sock",
        "/run/docker.sock",
        "/var/run/podman/podman.sock",
        "/run/podman/podman.sock",
        "/run/containerd/containerd.sock",
        str(home / ".orbstack" / "run" / "docker.sock"),
        str(home / ".docker" / "run" / "docker.sock"),
        str(home / ".local" / "share" / "containers" / "podman" / "podman.sock"),
    }
    deny_read = sorted({str(home), str(state_root), *raw_container_sockets})
    filesystem: dict[str, Any] = {
        "denyRead": deny_read,
        "allowRead": allow_read,
        "allowWrite": allow_write,
    }
    if role == "reviewer":
        filesystem["denyWrite"] = [str(worktree.resolve(strict=False))]

    # Semantic passes never inherit broad host credentials. Outbound Bash
    # reads are restricted to exact packet-frozen network_read_allowlist hosts
    # (empty by default); these native credential rules keep common non-cloud
    # tokens out of Bash even if
    # they exist in the supervisor's environment; the subprocess scrub env var
    # separately strips Anthropic/cloud-provider credentials.
    credential_vars = [
        "GITHUB_TOKEN", "GH_TOKEN", "NPM_TOKEN", "NODE_AUTH_TOKEN",
        "PYPI_TOKEN", "TWINE_PASSWORD", "DOCKER_AUTH_CONFIG",
    ]
    effective_network_domains = sorted(
        set(network_read_allowlist or [])
        | set(capability_resolution.get("network_domains") or [])
    )
    capability_sandbox_network = capability_resolution.get("sandbox_network") or {}
    sandbox_network: dict[str, Any] = {
        "allowedDomains": effective_network_domains,
        "strictAllowlist": True,
    }
    if capability_sandbox_network.get("allowLocalBinding") is True:
        sandbox_network["allowLocalBinding"] = True

    return {
        "autoMemoryEnabled": False,
        "sandbox": {
            "enabled": True,
            "failIfUnavailable": True,
            "autoAllowBashIfSandboxed": True,
            "allowUnsandboxedCommands": False,
            "excludedCommands": [],
            "filesystem": filesystem,
            "network": sandbox_network,
            "credentials": {
                "envVars": [
                    {"name": name, "mode": "deny"} for name in credential_vars
                ],
            },
        },
    }

def _terminate_group(proc: subprocess.Popen[str], grace_seconds: float = 3.0) -> None:
    """Terminate the entire semantic-worker group even after leader exit."""
    process_runner.terminate_process_group(proc, grace_seconds=grace_seconds)

class ClaudeCodeRunner:
    """One fresh non-interactive Claude Code process per semantic pass."""

    runner_id = "claude-code"
    requires_capability_receipt = True
    # Only runners that actually implement the persist-before-exec release
    # handshake may claim gate-v1 recovery semantics.
    launch_gate_version = 1

    def preflight(self) -> RunnerReadiness:
        """Check executable availability without starting a semantic attempt."""
        pinned = os.environ.get("OFLOOP_CLAUDE_BIN", "").strip()
        if pinned:
            p = Path(pinned).expanduser().resolve(strict=False)
            if not (p.is_file() and os.access(p, os.X_OK)):
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="pinned_runner_unavailable",
                    detail=f"commissioned Claude binary unavailable: {p}",
                    retry_after_seconds=0.0,
                )
            version = _claude_cli_version(str(p))
            if version is None:
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="runner_version_unproven",
                    detail="commissioned Claude Code version could not be proven",
                    retry_after_seconds=0.0,
                )
            if version < MIN_SECURE_CLAUDE_CODE_VERSION:
                return RunnerReadiness(
                    False,
                    classification="configuration",
                    reason="runner_secure_sandbox_version_too_old",
                    detail=(
                        "Claude Code "
                        + ".".join(str(x) for x in version)
                        + " is older than the required secure unattended-worker baseline "
                        + ".".join(str(x) for x in MIN_SECURE_CLAUDE_CODE_VERSION)
                    ),
                    retry_after_seconds=0.0,
                )
            return RunnerReadiness(True)

        discovered = shutil.which("claude")
        if discovered:
            p = Path(discovered).expanduser().resolve(strict=False)
            if p.is_file() and os.access(p, os.X_OK):
                version = _claude_cli_version(str(p))
                if version is None:
                    return RunnerReadiness(
                        False,
                        classification="configuration",
                        reason="runner_version_unproven",
                        detail="discovered Claude Code version could not be proven",
                        retry_after_seconds=0.0,
                    )
                if version < MIN_SECURE_CLAUDE_CODE_VERSION:
                    return RunnerReadiness(
                        False,
                        classification="configuration",
                        reason="runner_secure_sandbox_version_too_old",
                        detail=(
                            "Claude Code "
                            + ".".join(str(x) for x in version)
                            + " is older than the required secure unattended-worker baseline "
                            + ".".join(str(x) for x in MIN_SECURE_CLAUDE_CODE_VERSION)
                        ),
                        retry_after_seconds=0.0,
                    )
                return RunnerReadiness(True)

        return RunnerReadiness(
            False,
            classification="environment_wait",
            reason="runner_not_discoverable",
            detail="Claude CLI not currently discoverable on service PATH",
            retry_after_seconds=30.0,
        )

    def run(
        self,
        work_order: dict[str, Any],
        *,
        timeout_seconds: int = 3600,
        on_start=None,
        durable_files: tuple[Path, Path] | None = None,
    ) -> RunnerResult:
        role = str(work_order.get("role") or "")
        if role not in {"builder", "reviewer"}:
            raise RuntimeError(f"unsupported work-order role: {role!r}")
        worktree = Path(str(work_order.get("worktree") or "")).resolve(strict=False)
        if not worktree.is_dir():
            raise RuntimeError(f"prepared worktree missing: {worktree}")

        role_contract = _prompts_mod._load_role_prompt(role)
        canonical_repo = Path(
            str(work_order.get("canonical_repo") or "")
        ).resolve(strict=False)
        semantic_path = Path(
            str(work_order.get("semantic_path") or "")
        ).resolve(strict=False)
        attempt_id = str(work_order.get("attempt_id") or "")
        if not attempt_id:
            raise capabilities_mod.CapabilityResolutionError(
                "semantic work order missing durable attempt identity"
            )
        capability_resolution = capabilities_mod.resolve_capabilities(
            [str(item) for item in (work_order.get("capabilities") or [])],
            canonical_repo=canonical_repo,
            role=role,
            repo_cache_root=runtime_env.repo_tool_cache_dir(canonical_repo),
            ephemeral_cache_root=(
                runtime_env.runtime_cache_dir(
                    canonical_repo,
                    str(work_order.get("run_id") or ""),
                    role,
                ) / "capability-cache"
            ),
            packet_network_allowlist=[
                str(item) for item in (work_order.get("network_read_allowlist") or [])
            ],
            evidence_run_key=str(work_order.get("run_id") or "") or None,
        )
        runner_profile = runner_profiles_mod.resolve_profile(
            str(work_order.get("runner_profile") or "default"),
            provider=self.runner_id,
        )
        runner_profiles_mod.verify_profile_integrity(runner_profile)
        effort_attestation = runner_profiles_mod.verify_effort_attestation(
            runner_profile
        )
        if effort_attestation is not None:
            runner_profile = dict(runner_profile)
            runner_profile["effort_attestation"] = effort_attestation
        run_binding = capability_binding_mod.ensure_run_binding(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            capability_resolution,
            runner_profile,
            allow_create=bool(work_order.get("allow_capability_binding_create", True)),
        )
        capability_receipt = capabilities_mod.write_resolution_receipt(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            role,
            attempt_id,
            capability_resolution,
            run_binding=run_binding,
            runner_profile=runner_profile,
        )
        effective_work_order = dict(work_order)
        effective_work_order["capability_resolution"] = capabilities_mod.public_summary(
            capability_resolution
        )
        effective_work_order["capability_receipt"] = str(capability_receipt)
        effective_work_order["capability_binding_sha256"] = run_binding["binding_sha256"]
        effective_work_order["runner_profile_resolution"] = runner_profiles_mod.public_summary(
            runner_profile
        )
        payload = json.dumps(effective_work_order, indent=2, sort_keys=True)
        prompt = (
            role_contract
            + "\n\n# SUPERVISOR WORK ORDER\n"
            + "You are running as one fresh unattended semantic pass. "
              "The deterministic core already claimed and prepared the pass. "
              "Do not call claim, prepare, finalize, push, merge, deploy, or create remotes. "
              "Use the exact paths and identities below. Complete the source work (builder) "
              "or exact-SHA assessment (reviewer). The supplied semantic artifact may sit "
              "outside restricted built-in file-tool scope; write that artifact with sandboxed "
              "Bash when needed. Do not widen access. Protected paths in the sealed work order "
              "are immutable; a broad allowed parent never overrides a protected child. "
              "Then stop.\n\n"
            + payload
        )
        provenance_path = _prompts_mod._write_semantic_prompt_provenance(
            work_order=work_order,
            effective_work_order=effective_work_order,
            prompt=prompt,
            role_contract=role_contract,
        )
        effective_work_order["semantic_prompt_provenance"] = str(provenance_path)

        claude_bin = os.environ.get("OFLOOP_CLAUDE_BIN", "claude")
        pass_budget_raw = work_order.get("max_budget_usd")
        pass_budget: float | None = None
        if pass_budget_raw is not None:
            try:
                pass_budget = float(pass_budget_raw)
            except (TypeError, ValueError) as exc:
                raise capabilities_mod.CapabilityResolutionError(
                    "invalid supervisor per-pass model budget"
                ) from exc
            if not math.isfinite(pass_budget) or pass_budget <= 0:
                raise capabilities_mod.CapabilityResolutionError(
                    "supervisor per-pass model budget must be finite and positive"
                )
        extra = shlex.split(os.environ.get("OFLOOP_CLAUDE_EXTRA_ARGS", ""))
        _validate_claude_extra_args(extra)
        # Tool availability is product authority, not an environment-tunable
        # convenience. Reviewers structurally lack Edit/Write/NotebookEdit.
        allowed_tools = (
            CLAUDE_BUILDER_TOOLS if role == "builder" else CLAUDE_REVIEWER_TOOLS
        )
        secure_settings = _semantic_worker_settings(
            canonical_repo=canonical_repo,
            run_id=str(work_order.get("run_id") or ""),
            role=role,
            worktree=worktree,
            semantic_path=semantic_path,
            network_read_allowlist=[
                str(item) for item in (work_order.get("network_read_allowlist") or [])
            ],
            capability_resolution=capability_resolution,
        )
        # --restricted is the native shared-machine isolation boundary.
        # dontAsk + explicit --allowedTools means there are no human permission
        # prompts: capabilities inside the sealed set run, everything else is
        # denied. The Bash sandbox auto-allows contained commands.
        #
        # Pipe the prompt via stdin. Passing it as an argv string lets Claude
        # CLI mis-parse leading `---` (YAML frontmatter in the role file) as
        # an unknown option. stdin is the supported, robust path.
        cmd = [
            claude_bin,
            "-p",
            "--output-format",
            "json",
            "--restricted",
            "--permission-mode",
            "dontAsk",
            "--no-chrome",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config",
            # Claude 2.1.251+ rejects the bare ``{}`` form: ``--strict-mcp-config``
            # requires a ``mcpServers`` record. Declare an explicitly empty
            # one to keep the inherited-MCP surface empty without tripping
            # Claude's MCP-config validator.
            json.dumps({"mcpServers": {}}, separators=(",", ":"), sort_keys=True),
            "--plugin-dir",
            str(_prompts_mod._source_root()),
            *(
                ["--model", str(runner_profile["model"])]
                if runner_profile.get("model") else []
            ),
            *(
                ["--effort", str(runner_profile["effort"])]
                if runner_profile.get("effort") else []
            ),
            *(
                ["--max-budget-usd", f"{pass_budget:.12g}"]
                if pass_budget is not None else []
            ),
            *extra,
            "--settings",
            json.dumps(secure_settings, separators=(",", ":"), sort_keys=True),
            "--tools",
            allowed_tools,
            "--allowedTools",
            allowed_tools,
        ]
        if durable_files is not None:
            out_path, err_path = durable_files
            _db_mod._ensure_private_dir(out_path.parent)
            stdout_fh = out_path.open("w", encoding="utf-8")
            stderr_fh = err_path.open("w", encoding="utf-8")
            _db_mod._ensure_private_file_mode(out_path)
            _db_mod._ensure_private_file_mode(err_path)
        else:
            stdout_fh = subprocess.PIPE
            stderr_fh = subprocess.PIPE

        worker_env = runtime_env.hermetic_subprocess_env(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            role,
            capability_environment=dict(capability_resolution.get("environment") or {}),
            path_prepend=list(capability_resolution.get("path_prepend") or []),
        )
        # Claude-native subprocess scrub: keep model authentication available to
        # the Claude process itself while stripping Anthropic/cloud credentials
        # from Bash children. This also forces filesystem isolation to remain on.
        worker_env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
        privileged_names = sorted(
            str(item.get("name"))
            for item in (capability_resolution.get("resolved") or [])
            if isinstance(item, dict) and item.get("privileged") is True
        )
        worker_env["OFLOOP_PRIVILEGED_CAPABILITIES"] = ",".join(privileged_names)
        docker_brokers = [
            str(item.get("executable"))
            for item in (capability_resolution.get("resolved") or [])
            if isinstance(item, dict) and item.get("name") == "container.docker"
        ]
        worker_env["OFLOOP_CONTAINER_BROKER_EXECUTABLE"] = (
            docker_brokers[0] if len(docker_brokers) == 1 else ""
        )

        # Do not expose ~/.gitconfig merely so an unattended builder can commit.
        # Give semantic Git a deterministic bot identity and disable terminal
        # credential prompting/global config discovery.
        worker_env["GIT_CONFIG_GLOBAL"] = os.devnull
        worker_env["GIT_CONFIG_NOSYSTEM"] = "1"
        worker_env["GIT_TERMINAL_PROMPT"] = "0"
        worker_env["GIT_AUTHOR_NAME"] = "OwnFramework Loop"
        worker_env["GIT_AUTHOR_EMAIL"] = "loop@localhost"
        worker_env["GIT_COMMITTER_NAME"] = "OwnFramework Loop"
        worker_env["GIT_COMMITTER_EMAIL"] = "loop@localhost"

        # Authority-bearing host/profile bytes are rechecked immediately before
        # child creation. The child is still held behind the durable release
        # gate, so any drift here produces zero model calls.
        capabilities_mod.verify_resolution_integrity(capability_resolution)
        runner_profiles_mod.verify_profile_integrity(runner_profile)
        current_effort_attestation = runner_profiles_mod.verify_effort_attestation(
            runner_profile
        )
        if current_effort_attestation != runner_profile.get("effort_attestation"):
            raise runner_profiles_mod.RunnerProfileError(
                "runner effort attestation changed after run binding"
            )
        capability_binding_mod.verify_run_binding(
            canonical_repo,
            str(work_order.get("run_id") or ""),
            capability_resolution,
            runner_profile,
        )

        release_r, release_w = os.pipe()
        os.set_inheritable(release_r, True)
        gated_cmd = [
            sys.executable, "-c", _WORKER_RELEASE_GATE_CODE,
            str(release_r), *cmd,
        ]
        try:
            proc = subprocess.Popen(
                gated_cmd,
                cwd=str(worktree),
                stdin=subprocess.PIPE,
                stdout=stdout_fh,
                stderr=stderr_fh,
                text=True,
                start_new_session=True,
                env=worker_env,
                pass_fds=(release_r,),
            )
        except OSError as exc:
            try:
                os.close(release_r)
            except OSError:
                pass
            try:
                os.close(release_w)
            except OSError:
                pass
            if durable_files is not None:
                stdout_fh.close()  # type: ignore[union-attr]
                stderr_fh.close()  # type: ignore[union-attr]
            raise WorkerLaunchError(
                f"semantic worker launch failed before child creation: {exc}"
            ) from exc
        finally:
            try:
                os.close(release_r)
            except OSError:
                pass

        # The child is alive but cannot exec the semantic provider until exact
        # ownership is durably published by on_start. Any ordinary exception
        # before the release byte is written is therefore provably pre-provider,
        # even if PID publication already committed.
        try:
            if on_start is not None:
                on_start(int(proc.pid), role)
            os.write(release_w, b"1")
        except BaseException as exc:
            try:
                os.close(release_w)
            except OSError:
                pass
            _terminate_group(proc)
            if durable_files is not None:
                stdout_fh.close()  # type: ignore[union-attr]
                stderr_fh.close()  # type: ignore[union-attr]
            if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                raise
            if isinstance(exc, WorkerLaunchError):
                raise
            raise WorkerLaunchError(
                "semantic worker failed before provider release: "
                f"{type(exc).__name__}: {exc}"
            ) from exc
        finally:
            try:
                os.close(release_w)
            except OSError:
                pass

        timed_out = False
        # Use communicate(input=prompt) to feed stdin in a portable way
        # across Python 3.12+. The previous manual stdin.write()+close()
        # pattern was not portable: on some CPython 3.12 builds
        # communicate() reliably raised ValueError after manual stdin
        # close due to tightened pipe-close ordering.
        try:
            stdout_data, stderr_data = proc.communicate(
                input=prompt, timeout=int(timeout_seconds)
            )
        except subprocess.TimeoutExpired:
            timed_out = True
            _terminate_group(proc)
            stdout_data, stderr_data = proc.communicate()
        except BaseException:
            _terminate_group(proc)
            if durable_files is not None:
                stdout_fh.close()  # type: ignore[union-attr]
                stderr_fh.close()  # type: ignore[union-attr]
            raise

        lifecycle_leak = False
        if not timed_out and process_runner.process_group_exists(proc.pid):
            lifecycle_leak = True
            _terminate_group(proc)

        if durable_files is not None:
            # Close our handles; the child holds its own dup until exit.
            try:
                stdout_fh.close()  # type: ignore[union-attr]
            except Exception:
                pass
            try:
                stderr_fh.close()  # type: ignore[union-attr]
            except Exception:
                pass
            out_path, err_path = durable_files
            envelope_error = ""
            try:
                # The complete durable provider envelope is authoritative for
                # parsing and usage extraction, but commissioned unattended
                # execution must not read an unbounded file into supervisor
                # memory. The ceiling remains far above the diagnostic limit.
                stdout_data = _runner_io_mod._read_durable_provider_envelope(out_path)
            except ValueError as exc:
                stdout_data = ""
                envelope_error = str(exc)
            except Exception:
                stdout_data = ""
                envelope_error = "claude provider envelope could not be read"
            try:
                stderr_data = _runner_io_mod._read_durable_diagnostic_tail(err_path)
            except Exception:
                stderr_data = ""

        if lifecycle_leak:
            if durable_files is not None and envelope_error:
                stderr_data = (stderr_data or "") + "\n" + envelope_error
            return RunnerResult(
                ok=False,
                returncode=process_runner.PROCESS_GROUP_LEAK_RC,
                cost_usd=0.0,
                stdout=(stdout_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                stderr=((stderr_data or "") + "\n" + process_runner.PROCESS_GROUP_LEAK_MARKER)[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                pid=int(proc.pid),
                cost_known=False,
                tokens_known=False,
            )

        if timed_out:
            if durable_files is not None and envelope_error:
                stderr_data = (stderr_data or "") + "\n" + envelope_error
            return RunnerResult(
                ok=False,
                returncode=124,
                cost_usd=0.0,
                stdout=(stdout_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                stderr=((stderr_data or "") + "\nclaude runner timed out")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                pid=int(proc.pid),
                cost_known=False,
            )

        if durable_files is not None and envelope_error:
            return RunnerResult(
                ok=False,
                returncode=int(proc.returncode or 0),
                cost_usd=0.0,
                stdout="",
                stderr=((stderr_data or "") + "\n" + envelope_error)[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
                pid=int(proc.pid),
                cost_known=False,
                tokens_known=False,
            )

        cost = 0.0
        cost_known = False
        input_tokens = 0
        output_tokens = 0
        cache_read_tokens = 0
        cache_creation_tokens = 0
        tokens_known = False
        effective_model = ""
        model_usage_json = ""
        parsed: dict[str, Any] | None = None
        try:
            data = json.loads(stdout_data or "")
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict):
            parsed = data
            # The EFFECTIVE model the provider PROVABLY reported (distinct
            # from the requested profile model); empty when not provable.
            effective_model = _accounting_mod.extract_effective_model(data)
            # The FULL provider-reported usage is preserved regardless.
            model_usage_json = _accounting_mod.extract_model_usage_json(data)
            # Telemetry extraction degrades independently: a malformed cost
            # or usage value must demote that TELEMETRY to unknown, never
            # discard the semantic result envelope itself (which would turn
            # a completed pass into a duplicate model call).
            if "total_cost_usd" in data:
                try:
                    candidate_cost = float(data.get("total_cost_usd"))
                except (TypeError, ValueError):
                    candidate_cost = None
                if (
                    candidate_cost is not None
                    and math.isfinite(candidate_cost)
                    and candidate_cost >= 0
                ):
                    cost = candidate_cost
                    cost_known = True
            usage = data.get("usage")
            if isinstance(usage, dict):
                token_keys = (
                    ("input_tokens", "input_tokens"),
                    ("output_tokens", "output_tokens"),
                    ("cache_read_tokens", "cache_read_input_tokens"),
                    ("cache_creation_tokens", "cache_creation_input_tokens"),
                )
                values: dict[str, int] = {}
                usage_valid = False
                usage_malformed = False
                for target, source in token_keys:
                    if source not in usage:
                        values[target] = 0
                        continue
                    try:
                        candidate = int(usage.get(source) or 0)
                    except (TypeError, ValueError):
                        usage_malformed = True
                        break
                    if candidate < 0:
                        usage_malformed = True
                        break
                    values[target] = candidate
                    usage_valid = True
                if usage_valid and not usage_malformed:
                    input_tokens = values["input_tokens"]
                    output_tokens = values["output_tokens"]
                    cache_read_tokens = values["cache_read_tokens"]
                    cache_creation_tokens = values["cache_creation_tokens"]
                    tokens_known = True

        # Treat Claude as success when its structured JSON output says
        # is_error is false AND there is a substantive result. Claude CLI
        # may exit non-zero for warnings (e.g. unrecognized model warnings)
        # while still producing a valid result envelope. The semantic
        # completion check + deterministic finalizer are the real authority.
        claude_ok = False
        if parsed is not None:
            if parsed.get("is_error") is False:
                claude_ok = True
            elif "is_error" not in parsed and (
                parsed.get("result") or parsed.get("subtype") == "success"
            ):
                claude_ok = True

        return RunnerResult(
            ok=bool(claude_ok and (parsed is not None)),
            returncode=int(proc.returncode or 0),
            cost_usd=cost,
            stdout=(stdout_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
            stderr=(stderr_data or "")[-RUNNER_DIAGNOSTIC_MAX_CHARS:],
            pid=int(proc.pid),
            cost_known=cost_known,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_read_tokens=cache_read_tokens,
            cache_creation_tokens=cache_creation_tokens,
            tokens_known=tokens_known,
            effective_model=effective_model,
            model_usage_json=model_usage_json,
        )

@_runner_registry_mod.register_runner
class _RegisteredClaudeCodeRunner(ClaudeCodeRunner):
    runner_id = "claude-code"

def _classify_runner_failure(result: RunnerResult) -> tuple[str, str]:
    """Classify operational runner failure without interpreting engineering truth.

    Classification only selects retry/quarantine policy. It can never alter
    packet authority, candidate identity, checkpoint state, or review verdict.
    """
    text = f"{result.stderr}\n{result.stdout}".lower()
    if result.returncode == 124 or "runner timed out" in text:
        return "timeout", "runner_timeout"

    budget_markers = (
        "max budget", "max_budget_usd", "budget limit",
        "budget exceeded", "maximum budget", "reached the budget",
    )
    if any(marker in text for marker in budget_markers):
        return "usage_ceiling", "pass_budget_exhausted"

    configuration_markers = (
        "not authenticated",
        "authentication failed",
        "invalid api key",
        "invalid_api_key",
        "unauthorized",
        "forbidden",
        "login required",
        "command not found",
        "no such file or directory",
    )
    if result.returncode in {126, 127} or any(
        marker in text for marker in configuration_markers
    ):
        return "configuration", "runner_configuration_failure"

    transient_markers = (
        "rate limit",
        "rate-limit",
        "too many requests",
        "429",
        "overloaded",
        "capacity",
        "temporarily unavailable",
        "service unavailable",
        "bad gateway",
        "gateway timeout",
        "502",
        "503",
        "504",
        "connection reset",
        "connection refused",
        "network error",
        "network unavailable",
        "econnreset",
        "etimedout",
        "upstream",
    )
    if any(marker in text for marker in transient_markers):
        return "transient", "runner_transient_failure"
    return "runner", "runner_unclassified_failure"

def _classify_exception(exc: BaseException) -> tuple[str, str]:
    if isinstance(exc, WorkerLaunchError):
        return "configuration", "worker_launch_failed"
    if isinstance(exc, capability_binding_mod.CapabilityBindingError):
        return "configuration", "capability_binding_failed"
    if isinstance(exc, runner_profiles_mod.RunnerProfileError):
        return "configuration", "runner_profile_resolution_failed"
    if isinstance(exc, capabilities_mod.CapabilityResolutionError):
        return "configuration", "capability_resolution_failed"
    if isinstance(exc, dispatch_mod.SemanticResultIncomplete):
        if exc.retryable:
            return "runner", "semantic_result_incomplete"
        return "invariant", "semantic_result_not_finalizable"
    if isinstance(exc, dispatch_mod.DispatchError):
        return "invariant", "dispatch_refused"
    if isinstance(exc, (FileNotFoundError, PermissionError)):
        return "configuration", type(exc).__name__
    if isinstance(exc, (TimeoutError, ConnectionError)):
        return "transient", type(exc).__name__
    message = str(exc).lower()
    if (
        "not registered" in message
        or "runner prompt missing" in message
        or "prepared worktree missing" in message
    ):
        return "configuration", type(exc).__name__
    return "supervisor", type(exc).__name__

__all__ = [
    "WorkerLaunchError",
    "ClaudeCodeRunner",
    "_RegisteredClaudeCodeRunner",
    "_claude_cli_version",
    "_validate_claude_extra_args",
    "_parse_adapter_auth_read_paths",
    "_semantic_worker_settings",
    "_terminate_group",
    "_classify_runner_failure",
    "_classify_exception",
]

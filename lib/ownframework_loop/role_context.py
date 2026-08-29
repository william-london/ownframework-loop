"""v0.6.1 explicit execution-context contract.

Replaces the v0.5-era heuristic that an interactive Claude session inside
a repository containing `.ownframework-loop/` is a semantic worker. The
heuristic over-scoped ordinary operator-authorized interactive engineering
sessions, blocking `git push origin master` (and other source-promotion
commands) merely because the repository happened to own an old run
directory.

The explicit contract: a bash invocation is provably inside an
OwnFramework Loop semantic lane iff EITHER:

  (a) the parent process set the canonical environment markers:
        OFLOOP_SEMANTIC_CONTEXT=1
        OFLOOP_RUN_ID=<exact>
        OFLOOP_ROLE=builder|reviewer
        OFLOOP_CANONICAL_REPO=<resolved repo path>

      The Loop supervisor sets these when launching a ClaudeCodeRunner
      subprocess. They cannot be smuggled because the hook validates the
      canonical_repo against the cwd's git toplevel before honoring the
      contract.

  OR

  (b) the canonical repo root contains a marker file at
      `.ownframework-loop/_semantic_context` whose JSON payload names the
      exact ``role``, ``run_id``, and ``canonical_repo``. Foreground
      `/of-loop:build` and `/of-loop:review` skills (and any future
      supported foreground builder/reviewer lane) call
      ``enter_semantic_role`` on entry and ``exit_semantic_role`` on exit.

Outside both provenances, the bash guard is a no-op for this invocation
and ordinary Claude/native permission policy applies.

The contract never grants external-action authority. Both builder and
reviewer lanes are FORBIDDEN from:

  * any external-action pattern (git push, git push --no-verify, git
    merge, git reset --hard, git clean -fd, git remote add, docker
    compose up, etc.) — see ``guards.FORBIDDEN_PATTERNS``;

  * any command outside the reviewer allowlist (reviewer only) — see
    ``guards.REVIEWER_ALLOWLIST_PATTERNS``.

The contract never weakens semantic-worker restrictions. There is no
model-controllable bypass.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

SCHEMA = "of-loop/semantic-context/v1"
VALID_ROLES = ("builder", "reviewer")

_RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


class RoleContextError(ValueError):
    """Deterministic refusal for a malformed role context."""


def _validate_run_id(run_id: str) -> None:
    if not isinstance(run_id, str) or not _RUN_ID_PATTERN.match(run_id or ""):
        raise RoleContextError(f"invalid run_id: {run_id!r}")


def _validate_role(role: str) -> None:
    if role not in VALID_ROLES:
        raise RoleContextError(
            f"invalid role {role!r}; must be one of {list(VALID_ROLES)}"
        )


def _validate_canonical_repo(canonical_repo: str) -> str:
    if not isinstance(canonical_repo, str) or not canonical_repo.strip():
        raise RoleContextError("canonical_repo must be a non-empty string")
    resolved = Path(canonical_repo).expanduser().resolve(strict=False)
    if not resolved.is_dir():
        raise RoleContextError(f"canonical_repo is not a directory: {resolved}")
    return str(resolved)


def build_context(
    *,
    run_id: str,
    role: str,
    canonical_repo: str | Path,
) -> dict[str, str]:
    """Return a normalized role context dict (run_id, role, canonical_repo).

    Raises RoleContextError on malformed input.
    """
    _validate_run_id(run_id)
    _validate_role(role)
    resolved_repo = _validate_canonical_repo(str(canonical_repo))
    return {
        "schema": SCHEMA,
        "run_id": run_id,
        "role": role,
        "canonical_repo": resolved_repo,
    }


def enter_semantic_role(
    *,
    canonical_repo: str | Path,
    run_id: str,
    role: str,
) -> dict[str, str]:
    """Write the marker file establishing semantic-worker context.

    The marker file is the foreground-lane source of truth (the
    supervisor uses env vars instead, see ``apply_context_to_env``).
    Returns the normalized context dict.
    """
    ctx = build_context(
        run_id=run_id, role=role, canonical_repo=canonical_repo
    )
    repo = Path(ctx["canonical_repo"])
    state_dir = repo / ".ownframework-loop"
    state_dir.mkdir(parents=True, exist_ok=True)
    marker = state_dir / "_semantic_context"
    # Atomic write: write to .tmp then replace, so a concurrent reader
    # never sees a half-written file.
    tmp = marker.with_suffix(".tmp")
    tmp.write_text(json.dumps(ctx, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, marker)
    return ctx


def exit_semantic_role(*, canonical_repo: str | Path) -> bool:
    """Remove the marker file. Returns True iff the marker was removed.

    Does not raise if the marker is absent.
    """
    repo = Path(canonical_repo).expanduser().resolve(strict=False)
    marker = repo / ".ownframework-loop" / "_semantic_context"
    if not marker.exists() and not marker.is_symlink():
        return False
    try:
        marker.unlink()
        return True
    except OSError:
        return False


def read_marker(canonical_repo: str | Path) -> dict[str, str] | None:
    """Read the marker file at ``canonical_repo/.ownframework-loop/_semantic_context``.

    Returns None when absent or unparseable. Validates the JSON payload.
    """
    repo = Path(canonical_repo).expanduser().resolve(strict=False)
    marker = repo / ".ownframework-loop" / "_semantic_context"
    try:
        raw = marker.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    try:
        # Re-validate every field through the same entry point as
        # build_context. A marker written by an old or tampered build
        # that bypassed validation cannot be promoted to live context.
        return build_context(
            run_id=str(data.get("run_id") or ""),
            role=str(data.get("role") or ""),
            canonical_repo=str(data.get("canonical_repo") or ""),
        )
    except RoleContextError:
        return None


def read_env(env: dict[str, str] | None = None) -> dict[str, str] | None:
    """Read semantic context from environment variables.

    Returns None if OFLOOP_SEMANTIC_CONTEXT is not exactly "1". Validates
    the other variables via ``build_context``. A partial env (e.g. context
    flag set without role/run_id) is treated as malformed: returns None
    AND ``read_env_invalid_partial`` would be ``True`` for callers that
    need to distinguish.
    """
    e = env if env is not None else os.environ
    if str(e.get("OFLOOP_SEMANTIC_CONTEXT") or "") != "1":
        return None
    try:
        return build_context(
            run_id=str(e.get("OFLOOP_RUN_ID") or ""),
            role=str(e.get("OFLOOP_ROLE") or ""),
            canonical_repo=str(e.get("OFLOOP_CANONICAL_REPO") or ""),
        )
    except RoleContextError:
        return None


def is_env_partial(env: dict[str, str] | None = None) -> bool:
    """True iff OFLOOP_SEMANTIC_CONTEXT=1 is set but at least one other
    required variable is missing or malformed. The hook should fail
    closed on partial context (treat as no context, but log a warning so
    operators notice misconfigured supervisors).
    """
    e = env if env is not None else os.environ
    if str(e.get("OFLOOP_SEMANTIC_CONTEXT") or "") != "1":
        return False
    return read_env(env) is None


def apply_context_to_env(
    env: dict[str, str],
    ctx: dict[str, str],
) -> dict[str, str]:
    """Mutate ``env`` in place to carry semantic-context markers. Returns
    ``env`` for chaining. Idempotent: setting twice yields the same dict.
    """
    env["OFLOOP_SEMANTIC_CONTEXT"] = "1"
    env["OFLOOP_RUN_ID"] = str(ctx["run_id"])
    env["OFLOOP_ROLE"] = str(ctx["role"])
    env["OFLOOP_CANONICAL_REPO"] = str(ctx["canonical_repo"])
    return env


def _git_common_dir(path: Path) -> Path | None:
    """Return the canonical Git common-dir for a main or linked worktree."""
    import subprocess as _sp
    try:
        r = _sp.run(
            ["git", "-C", str(path), "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, check=False, timeout=5,
        )
    except (OSError, _sp.TimeoutExpired):
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    common = Path(r.stdout.strip())
    if not common.is_absolute():
        common = path / common
    try:
        return common.resolve(strict=False)
    except OSError:
        return None


def context_canonical_repo_matches(
    ctx: dict[str, str], cwd: str | Path
) -> bool:
    """True iff cwd belongs to the exact Git repository declared by context.

    Main checkouts and linked builder/reviewer worktrees have different
    toplevel directories. Git common-dir identity is the correct
    anti-smuggling proof across those worktrees.
    """
    if not ctx.get("canonical_repo"):
        return False
    try:
        cwd_path = Path(cwd).expanduser().resolve(strict=False)
        ctx_repo = Path(ctx["canonical_repo"]).expanduser().resolve(strict=False)
    except OSError:
        return False
    if not ctx_repo.is_dir() or not cwd_path.exists():
        return False
    cwd_common = _git_common_dir(cwd_path)
    repo_common = _git_common_dir(ctx_repo)
    return cwd_common is not None and repo_common is not None and cwd_common == repo_common


__all__ = [
    "SCHEMA",
    "VALID_ROLES",
    "RoleContextError",
    "build_context",
    "enter_semantic_role",
    "exit_semantic_role",
    "read_marker",
    "read_env",
    "is_env_partial",
    "apply_context_to_env",
    "context_canonical_repo_matches",
]

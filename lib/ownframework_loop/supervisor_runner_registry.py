"""Supervisor semantic-runner registry.

Owns:
  * RunnerResult and RunnerReadiness dataclasses;
  * the runner registry (vendor-neutral provider registration);
  * ``register_runner`` decorator;
  * ``registered_runner_ids`` / ``_runner`` / ``_runner_preflight``
    lookup helpers.

What stays in ``supervisor.py``:
  * The ``ClaudeCodeRunner`` class itself (and its ~600-line
    ``run`` method).  The runner class is tightly bound to many
    supervisor internals (capability resolution, runner profiles,
    capability binding, runtime_env, worktree helpers, durable
    provider-envelope parsing, release-gate bytecode, subprocess
    lifecycle).  Extracting the class without those would require
    moving the dependency surface too — deferred to the next
    consolidation mission.
  * The runner failure classification
    (``_classify_runner_failure``, ``_classify_exception``,
    ``_apply_failure_policy``).  These couple the runner result to
    supervisor retry / quarantine policy and the durable state
    schema; they belong with the recovery + claims owners.

This module is the thin seam where a NEW provider integration
would land.  It exposes:

  * a stable ``RunnerResult`` / ``RunnerReadiness`` contract;
  * a stable ``register_runner(cls)`` registration API;
  * stable lookup helpers.

Adding a new provider requires only subclassing
``ClaudeCodeRunner`` (or duck-typed class) and calling
``register_runner``.  The dispatch / supervisor FSM never needs
to change.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any


# Runner result + readiness contract.
# Dataclass field comments are part of the public runner contract.

@dataclass
class RunnerResult:
    ok: bool
    returncode: int
    cost_usd: float
    stdout: str
    stderr: str
    pid: int | None = None
    cost_known: bool = True
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_creation_tokens: int = 0
    tokens_known: bool = False
    # The model the provider ACTUALLY billed/reported, when the envelope
    # PROVES a singular model. This is the EFFECTIVE model and may differ from
    # the profile's REQUESTED model (e.g. a substitution/downgrade); it is
    # recorded so the two are never conflated. Empty when not provable.
    effective_model: str = ""
    # Canonical JSON of the FULL provider-reported modelUsage. Preserved even
    # when a singular effective model is not provable (multi-model mixes).
    model_usage_json: str = ""


@dataclass(frozen=True)
class RunnerReadiness:
    ready: bool
    classification: str = "ready"
    reason: str = "ready"
    detail: str = ""
    retry_after_seconds: float = 30.0


# Vendor-neutral runner registry.  A new provider only needs to register a
# subclass of ClaudeCodeRunner (or a duck-typed class with ``runner_id``
# + ``run()``).  Adding a runner MUST NOT require any change to
# dispatch / supervisor FSM.
_RUNNER_REGISTRY: dict[str, Any] = {}


def register_runner(cls: type) -> type:
    """Register a runner class.  Returns ``cls`` so callers can chain."""
    rid = getattr(cls, "runner_id", None)
    if not rid or not isinstance(rid, str):
        raise RuntimeError(f"runner {cls!r} missing string runner_id")
    _RUNNER_REGISTRY[rid] = cls()
    return cls


def registered_runner_ids() -> tuple[str, ...]:
    """Return the exact live supervisor runner IDs registered in this runtime."""
    return tuple(sorted(_RUNNER_REGISTRY))


def get_runner(name: str):
    """Return the registered runner instance for ``name``.

    Raises ``RuntimeError`` if the runner is not registered.  The
    supervisor facade's ``_runner`` is a thin delegate to this.
    """
    if name not in _RUNNER_REGISTRY:
        raise RuntimeError(
            f"runner {name!r} is not registered; live implementations: "
            + ", ".join(registered_runner_ids())
        )
    return _RUNNER_REGISTRY[name]


def runner_preflight(name: str) -> RunnerReadiness:
    """Run the named runner's ``preflight`` (if any) and return a
    ``RunnerReadiness``.

    A runner without ``preflight`` returns ``RunnerReadiness(True)``.
    The supervisor facade's ``_runner_preflight`` is a thin delegate.
    """
    runner = get_runner(name)
    probe = getattr(runner, "preflight", None)
    if probe is None:
        return RunnerReadiness(True)
    result = probe()
    if isinstance(result, RunnerReadiness):
        return result
    raise RuntimeError(
        f"runner {name!r} returned invalid preflight result: {type(result).__name__}"
    )

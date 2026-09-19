"""Supervisor runner I/O — provider-output / durable envelope plumbing.

Canonical owner of the supervisor's bounded runner-output
primitives.  These read durable provider envelopes / diagnostic
tails from disk with deterministic size ceilings and never touch
the supervisor FSM, the DB, or the hold lifecycle.

  * ``_read_durable_provider_envelope`` — read a provider's
    durable JSON envelope (cost / token / model telemetry) up
    to ``CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES``.
  * ``_read_durable_diagnostic_tail`` — read the last
    ``RUNNER_DIAGNOSTIC_MAX_CHARS`` bytes of a runner's
    diagnostic log.

Both primitives are used by:

  * ``supervisor_accounting`` (cost / token / model observation)
    — via ``_read_envelope_payload``.
  * ``supervisor.run_one`` / ``ClaudeCodeRunner.run`` — to read
    the worker's stdout/stderr for the failure-classification
    cascade and the durable-envelope boundary check.

Dependency direction: this module imports nothing from
``supervisor.py``.  ``supervisor.py`` re-exports the canonical
symbols here for backward compatibility so existing callers
(``supervisor._read_durable_provider_envelope``) keep working.
"""
from __future__ import annotations

import os
from pathlib import Path


# Size ceilings.  Canonical owners are THIS module;
# ``supervisor.py`` re-exports for backward compatibility.
CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES = 8 * 1024 * 1024
RUNNER_DIAGNOSTIC_MAX_CHARS = 65536


def _read_durable_provider_envelope(path: Path) -> str:
    """Read a durable provider envelope with a deterministic size ceiling.

    Raises ``ValueError`` if the file exceeds the bounded byte
    budget so a runaway worker cannot inflate accounting memory
    by writing a multi-gigabyte envelope.
    """
    size = path.stat().st_size
    if size > CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES:
        raise ValueError(
            "claude provider envelope exceeds deterministic ceiling "
            f"({size} > {CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES} bytes)"
        )
    return path.read_text(encoding="utf-8", errors="replace")


def _read_durable_diagnostic_tail(path: Path) -> str:
    """Read the bounded tail of a runner's diagnostic log.

    Returns up to ``RUNNER_DIAGNOSTIC_MAX_CHARS`` bytes from the
    end of the file.  Used by the failure-classification cascade
    to extract the last diagnostic line without loading an
    unbounded log into memory.
    """
    with path.open("rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - RUNNER_DIAGNOSTIC_MAX_CHARS), os.SEEK_SET)
        data = fh.read(RUNNER_DIAGNOSTIC_MAX_CHARS)
    return data.decode("utf-8", errors="replace")[-RUNNER_DIAGNOSTIC_MAX_CHARS:]


__all__ = [
    "CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES",
    "RUNNER_DIAGNOSTIC_MAX_CHARS",
    "_read_durable_provider_envelope",
    "_read_durable_diagnostic_tail",
]

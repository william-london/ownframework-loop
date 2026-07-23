"""Integrity helpers — SHA-based detection of direct file tampering.

The V1 model is:
- Every CLI transition writes STATE.json atomically (under flock) AND
  appends an event to EVENTS.log that records the SHA-256 of the new
  STATE.json bytes.
- Before any CLI operation on STATE.json, we recompute its SHA-256 and
  compare to the SHA recorded in the last event. If they differ, the
  file was edited externally and we raise `TamperingDetected`.

This isolates the "direct edit of STATE.json" attack: the CLI never
trusts the on-disk file as-is; it validates it against the event chain.

For receipts/verdicts, the same hash is recorded in EVENTS.log when the
artifact is written. A pre-write check against the run-level event chain
flags tampering.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from .util import read_json


class TamperingDetected(RuntimeError):
    """Raised when a state/receipt/verdict file does not match its
    recorded SHA-256 in EVENTS.log."""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def read_event_chain(path: Path) -> list[dict[str, Any]]:
    """Read the JSON-Lines event chain. Returns [] on missing file.

    Skips malformed lines (does not raise). Bad lines are recorded as
    separate events when the file is rewritten.
    """
    if not path.exists():
        return []
    out: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            import json
            out.append(json.loads(line))
        except Exception:
            continue
    return out


def last_recorded_state_sha(events_log: Path) -> str | None:
    """Return the most recent state_sha256 recorded in EVENTS.log."""
    events = read_event_chain(events_log)
    for ev in reversed(events):
        sha = ev.get("state_sha256")
        if sha:
            return sha
    return None


def verify_state_sha(state_path: Path, events_log: Path) -> tuple[bool, str]:
    """Verify STATE.json matches the last recorded SHA in EVENTS.log.

    Returns (ok, message). If no event has yet recorded a SHA, the
    function returns (True, "no prior sha recorded"). A mismatch is
    reported as (False, "<reason>"). An empty/missing state file returns
    (True, "no state to verify").
    """
    if not state_path.exists():
        return True, "no state to verify"
    if not events_log.exists():
        return True, "no event chain yet"
    expected = last_recorded_state_sha(events_log)
    if expected is None:
        return True, "no prior sha recorded"
    try:
        actual = sha256_file(state_path)
    except OSError:
        return True, "cannot read state"
    if actual != expected:
        return False, f"state sha mismatch: recorded={expected[:12]}, actual={actual[:12]}"
    return True, "ok"


def record_state_sha(events_log: Path, state_path: Path) -> str | None:
    """Hash a state file at the moment of recording so it can be
    verified before the next transition.

    Returns the recorded SHA-256, or None if the file does not exist.
    """
    if not state_path.exists():
        return None
    return sha256_file(state_path)


def record_artifact_sha(events_log: Path, artifact_path: Path) -> str | None:
    """Hash an artifact (receipt/verdict) at the moment of recording."""
    if not artifact_path.exists():
        return None
    return sha256_file(artifact_path)


def last_recorded_artifact_sha(events_log: Path, artifact_name: str) -> str | None:
    """Return the most recent artifact_sha recorded in EVENTS.log
    for the named artifact (BUILD_RECEIPT.json or REVIEW_VERDICT.json)."""
    events = read_event_chain(events_log)
    key = f"{artifact_name}_sha256"
    for ev in reversed(events):
        sha = ev.get(key)
        if sha:
            return sha
    return None


def verify_artifact_sha(artifact_path: Path, events_log: Path, artifact_name: str) -> tuple[bool, str]:
    """Verify an artifact matches the SHA-256 recorded in EVENTS.log."""
    if not artifact_path.exists():
        return True, "no artifact to verify"
    if not events_log.exists():
        return True, "no event chain yet"
    expected = last_recorded_artifact_sha(events_log, artifact_name)
    if expected is None:
        return True, "no prior sha recorded"
    try:
        actual = sha256_file(artifact_path)
    except OSError:
        return True, "cannot read artifact"
    if actual != expected:
        return False, f"{artifact_name} sha mismatch: recorded={expected[:12]}, actual={actual[:12]}"
    return True, "ok"

"""Integrity helpers — SHA-based detection of direct file tampering.

V2 model
========

Every authoritative artifact has its SHA-256 recorded in EVENTS.log at
the moment it is written. Before any transition, the finalizer
recomputes the artifact hashes and refuses if any are inconsistent.

Authoritative artifacts:

  - WORK_PACKET.md              (packet_sha256)
  - APPROVAL.json               (approval_sha256)
  - STATE.json                  (state_sha256)
  - BUILD_AGENT_RESULT.json     (build_agent_result_sha256, optional)
  - BUILD_RECEIPT.json          (build_receipt_sha256)
  - REVIEW_AGENT_ASSESSMENT.json (review_agent_assessment_sha256, optional)
  - REVIEW_VERDICT.json         (review_verdict_sha256)
  - EVENTS.log                  (event_chain_hash)

Every CLI write appends an event (after the file rename) containing the
artifact hash. The event chain itself is sha256-chained: each event
includes the hash of the chain tail. Verifying the chain is a linear
scan over EVENTS.log.

Direct edits to any of the above are detected (on the next CLI read) by
re-hashing the file and comparing against the recorded hash. The CLI
refuses to transition and emits ``OF_LOOP_STATE_INTEGRITY_FAILURE``.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .util import read_json


class TamperingDetected(RuntimeError):
    """Raised when a state/receipt/verdict file does not match its
    recorded SHA-256 in EVENTS.log."""


# Authoritative artifact names that must match an event-chain hash.
AUTHORITATIVE_ARTIFACTS: tuple[str, ...] = (
    "WORK_PACKET.md",
    "APPROVAL.json",
    "STATE.json",
    "BUILD_AGENT_RESULT.json",
    "BUILD_RECEIPT.json",
    "REVIEW_AGENT_ASSESSMENT.json",
    "REVIEW_VERDICT.json",
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_event_chain(path: Path) -> list[dict[str, Any]]:
    """Read the JSON-Lines event chain. Returns [] on missing file."""
    if not path.exists():
        return []
    out: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
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


def last_recorded_for(events_log: Path, key: str) -> str | None:
    """Return the most recent value for `key` in EVENTS.log."""
    events = read_event_chain(events_log)
    for ev in reversed(events):
        v = ev.get(key)
        if v:
            return str(v)
    return None


def get_event_chain_hash(events_log: Path) -> str | None:
    """Return the most recent event_chain_sha256 recorded in EVENTS.log."""
    return last_recorded_for(events_log, "event_chain_sha256")


def compute_event_chain_hash(events_log: Path) -> str:
    """SHA-256 over the JSON-Lines tail of EVENTS.log.

    Each event is serialized using the canonical formatter (sort_keys=True,
    separators=(",", ":")), matching the on-disk format written by
    state.append_event. Events are joined by "\n" and the SHA covers the
    UTF-8 bytes of the joined payload.
    """
    events = read_event_chain(events_log)
    if not events:
        return hashlib.sha256(b"").hexdigest()
    payload = "\n".join(canonical_json_dumps(ev) for ev in events)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def canonical_json_dumps(obj: Any) -> str:
    """Canonical JSON serialization for all hash-bearing artifacts.

    Used by:
      - state.append_event (EVENTS.log line bytes)
      - integrity.compute_event_chain_hash (recomputation for verification)
      - integrity.verify_state_sha (state SHA embedded in events)
      - integrity.verify_artifact_sha (artifact SHA embedded in events)

    Constraints:
      - UTF-8 bytes
      - sort_keys=True (deterministic key ordering)
      - separators=(",", ":") (compact, no whitespace)
      - ensure_ascii=False would emit non-ASCII as Unicode escapes; we
        default to ensure_ascii=True so the byte stream is portable.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def verify_state_sha(state_path: Path, events_log: Path) -> tuple[bool, str]:
    """Verify STATE.json matches the last recorded SHA in EVENTS.log."""
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
    if not state_path.exists():
        return None
    return sha256_file(state_path)


def record_artifact_sha(events_log: Path, artifact_path: Path) -> str | None:
    if not artifact_path.exists():
        return None
    return sha256_file(artifact_path)


def last_recorded_artifact_sha(events_log: Path, artifact_name: str) -> str | None:
    key = f"{artifact_name}_sha256"
    return last_recorded_for(events_log, key)


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


def verify_all_artifacts(
    artifacts: dict[str, Path],
    events_log: Path,
) -> tuple[bool, list[str]]:
    """Verify every authoritative artifact in `artifacts` against the event chain.

    `artifacts` maps artifact name -> path. Names must be members of
    AUTHORITATIVE_ARTIFACTS. Missing paths are skipped (treated as
    informational, not failures).
    """
    failures: list[str] = []
    for name in AUTHORITATIVE_ARTIFACTS:
        if name not in artifacts:
            continue
        path = artifacts[name]
        if not path.exists():
            continue
        ok, msg = verify_artifact_sha(path, events_log, name)
        if not ok:
            failures.append(f"{name}: {msg}")
    # Cross-check the event chain tail.
    chain_hash_recorded = get_event_chain_hash(events_log)
    if chain_hash_recorded is not None:
        chain_hash_actual = compute_event_chain_hash(events_log)
        if chain_hash_recorded != chain_hash_actual:
            failures.append("event_chain_hash_mismatch")
    return (not failures), failures


def build_artifact_inventory(
    canonical_repo: Path,
    run_id: str,
) -> dict[str, Path]:
    """Return the authoritative artifact inventory for one run."""
    from . import util
    run_d = util.run_dir(canonical_repo, run_id)
    return {
        "WORK_PACKET.md": run_d / "WORK_PACKET.md",
        "APPROVAL.json": run_d / "APPROVAL.json",
        "STATE.json": run_d / "STATE.json",
        "BUILD_AGENT_RESULT.json": run_d / "BUILD_AGENT_RESULT.json",
        "BUILD_RECEIPT.json": run_d / "BUILD_RECEIPT.json",
        "REVIEW_AGENT_ASSESSMENT.json": run_d / "REVIEW_AGENT_ASSESSMENT.json",
        "REVIEW_VERDICT.json": run_d / "REVIEW_VERDICT.json",
    }


def assert_artifacts_intact(
    canonical_repo: Path,
    run_id: str,
) -> tuple[bool, list[str]]:
    """Convenience: verify the run's authoritative artifacts."""
    inventory = build_artifact_inventory(canonical_repo, run_id)
    from . import util
    return verify_all_artifacts(inventory, util.run_dir(canonical_repo, run_id) / "EVENTS.log")

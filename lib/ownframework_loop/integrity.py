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

Direct edits OR deletion of any artifact whose digest has already been
recorded are detected on the next verified read/transition. An artifact
that has genuinely never been recorded may still be absent; optional
artifacts therefore remain optional until first publication.
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


class StateTorn(TamperingDetected):
    """STATE.json is torn / truncated; recoverable from pending journal.

    Inherits from TamperingDetected so existing narrow catches (which all
    assume the integrity module's generic exception) still match. Callers
    that want to attempt journal recovery should catch StateTorn first.
    """


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
    """Read the JSON-Lines event chain with STRICT parsing.

    Returns [] on missing file.

    Strict semantics:
      - empty / whitespace-only line  -> skipped silently
      - non-empty parseable JSON line -> appended
      - non-empty malformed line      -> raises TamperingDetected
    """
    if path.is_symlink():
        raise TamperingDetected("event chain must not be a symlink")
    if not path.exists():
        return []
    if not path.is_file():
        raise TamperingDetected("event chain must be a regular file")
    out: list[dict[str, Any]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise TamperingDetected(
                f"event chain contains malformed non-empty line at row "
                f"{len(out) + 1}: {exc}"
            ) from exc
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
    """Iteratively recompute the SHA-256 event chain hash."""
    events = read_event_chain(events_log)
    chain = ""
    for ev in events:
        stripped = {k: v for k, v in ev.items() if k != "event_chain_sha256"}
        payload = canonical_json_dumps(stripped).encode("utf-8")
        h = hashlib.sha256()
        h.update(chain.encode("utf-8"))
        h.update(payload)
        chain = h.hexdigest()
    return chain


def canonical_json_dumps(obj: Any) -> str:
    """Canonical JSON serialization for all hash-bearing artifacts."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def verify_state_sha(state_path: Path, events_log: Path) -> tuple[bool, str]:
    """Verify STATE.json against the most recent recorded state SHA.

    Absence is benign only before EVENTS has ever recorded a state digest.
    Once a digest exists, deletion is an integrity failure exactly like byte
    mutation: the authoritative state can no longer be proven.
    """
    if state_path.is_symlink():
        return False, "state must not be a symlink"
    if events_log.is_symlink():
        return False, "event chain must not be a symlink"
    if not events_log.exists():
        if not state_path.exists():
            return True, "no state or event chain yet"
        return True, "no event chain yet"

    expected = last_recorded_state_sha(events_log)
    if expected is None:
        if not state_path.exists():
            return True, "no state or recorded sha yet"
        return True, "no prior sha recorded"

    if not state_path.exists():
        return False, f"state missing but recorded sha exists: recorded={expected[:12]}"

    try:
        actual = sha256_file(state_path)
    except OSError as exc:
        return False, f"state unreadable: {exc}"
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


def verify_artifact_sha(
    artifact_path: Path,
    events_log: Path,
    artifact_name: str,
) -> tuple[bool, str]:
    """Verify an artifact against its most recent recorded SHA.

    Optional artifacts remain optional until a digest is recorded. After first
    publication, disappearance is tampering/unprovable authority and fails
    closed rather than collapsing back to the pre-publication state.
    """
    if artifact_path.is_symlink():
        return False, f"{artifact_name} must not be a symlink"
    if events_log.is_symlink():
        return False, "event chain must not be a symlink"
    if not events_log.exists():
        if not artifact_path.exists():
            return True, "no artifact or event chain yet"
        return True, "no event chain yet"

    expected = last_recorded_artifact_sha(events_log, artifact_name)
    if expected is None:
        if not artifact_path.exists():
            return True, "artifact never recorded"
        return True, "no prior sha recorded"

    if not artifact_path.exists():
        return False, (
            f"{artifact_name} missing but recorded sha exists: "
            f"recorded={expected[:12]}"
        )

    try:
        actual = sha256_file(artifact_path)
    except OSError as exc:
        return False, f"{artifact_name} unreadable: {exc}"
    if actual != expected:
        return False, (
            f"{artifact_name} sha mismatch: "
            f"recorded={expected[:12]}, actual={actual[:12]}"
        )
    return True, "ok"


def verify_all_artifacts(
    artifacts: dict[str, Path],
    events_log: Path,
) -> tuple[bool, list[str]]:
    """Verify every supplied authoritative artifact against the event chain.

    Missing paths are still checked because absence is meaningful after an
    artifact digest has been recorded. An optional artifact with no historical
    digest remains benign.
    """
    failures: list[str] = []
    for name in AUTHORITATIVE_ARTIFACTS:
        if name not in artifacts:
            continue
        ok, msg = verify_artifact_sha(artifacts[name], events_log, name)
        if not ok:
            failures.append(f"{name}: {msg}")

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
    return verify_all_artifacts(
        inventory,
        util.run_dir(canonical_repo, run_id) / "EVENTS.log",
    )

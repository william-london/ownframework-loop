"""Integrity helpers — SHA-based detection of direct file tampering.

Every authoritative artifact is bound into EVENTS.log once published. Before
an authoritative read/transition, recorded bytes are re-proven. Absence is
benign only before first publication; mutation, deletion, or filesystem
redirection after a digest has been recorded fails closed.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


class TamperingDetected(RuntimeError):
    """Raised when authoritative bytes cannot be proven against EVENTS.log."""


class StateTorn(TamperingDetected):
    """STATE.json is torn / truncated; recoverable from a proven journal."""


AUTHORITATIVE_ARTIFACTS: tuple[str, ...] = (
    "WORK_PACKET.md",
    "APPROVAL.json",
    "STATE.json",
    "BUILD_AGENT_RESULT.json",
    "BUILD_RECEIPT.json",
    "REVIEW_AGENT_ASSESSMENT.json",
    "REVIEW_VERDICT.json",
)

# Canonical EVENTS.log fields for non-STATE authoritative artifacts. STATE has
# a dedicated state_sha256 field because every event already binds current
# state. Keeping this map here prevents writer/verifier key drift.
ARTIFACT_EVENT_KEYS: dict[str, str] = {
    "WORK_PACKET.md": "packet_sha256",
    "APPROVAL.json": "approval_sha256",
    "BUILD_AGENT_RESULT.json": "build_agent_result_sha256",
    "BUILD_RECEIPT.json": "build_receipt_sha256",
    "REVIEW_AGENT_ASSESSMENT.json": "review_agent_assessment_sha256",
    "REVIEW_VERDICT.json": "review_verdict_sha256",
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _authority_path_exists(path: Path, *, label: str) -> bool:
    """Return existence while refusing filesystem redirection/non-file authority."""
    if path.is_symlink():
        raise TamperingDetected(f"{label} must not be a symlink")
    if not path.exists():
        return False
    if not path.is_file():
        raise TamperingDetected(f"{label} must be a regular file")
    return True


def read_event_chain(path: Path) -> list[dict[str, Any]]:
    """Read strict JSON-Lines event history; malformed/redirection fails closed."""
    if not _authority_path_exists(path, label="event chain"):
        return []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise TamperingDetected(f"event chain unreadable: {exc}") from exc
    out: list[dict[str, Any]] = []
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise TamperingDetected(
                f"event chain contains malformed non-empty line at row "
                f"{len(out) + 1}: {exc}"
            ) from exc
        if not isinstance(value, dict):
            raise TamperingDetected(
                f"event chain row {len(out) + 1} is not a JSON object"
            )
        out.append(value)
    return out


def last_recorded_state_sha(events_log: Path) -> str | None:
    events = read_event_chain(events_log)
    for ev in reversed(events):
        sha = ev.get("state_sha256")
        if sha:
            return str(sha)
    return None


def last_recorded_for(events_log: Path, key: str) -> str | None:
    events = read_event_chain(events_log)
    for ev in reversed(events):
        value = ev.get(key)
        if value:
            return str(value)
    return None


def get_event_chain_hash(events_log: Path) -> str | None:
    return last_recorded_for(events_log, "event_chain_sha256")


def compute_event_chain_hash(events_log: Path) -> str:
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
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def artifact_event_hashes(run_directory: Path) -> dict[str, str]:
    """Snapshot every currently published non-STATE authority artifact."""
    out: dict[str, str] = {}
    for artifact_name, event_key in ARTIFACT_EVENT_KEYS.items():
        path = Path(run_directory) / artifact_name
        if not _authority_path_exists(path, label=artifact_name):
            continue
        try:
            out[event_key] = sha256_file(path)
        except OSError as exc:
            raise TamperingDetected(f"{artifact_name} unreadable: {exc}") from exc
    return out


def verify_state_sha(state_path: Path, events_log: Path) -> tuple[bool, str]:
    """Verify STATE.json against the most recent recorded state SHA."""
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
    if not state_path.is_file():
        return False, "state must be a regular file"
    try:
        actual = sha256_file(state_path)
    except OSError as exc:
        return False, f"state unreadable: {exc}"
    if actual != expected:
        return False, f"state sha mismatch: recorded={expected[:12]}, actual={actual[:12]}"
    return True, "ok"


def record_state_sha(events_log: Path, state_path: Path) -> str | None:
    if not _authority_path_exists(state_path, label="state"):
        return None
    return sha256_file(state_path)


def record_artifact_sha(events_log: Path, artifact_path: Path) -> str | None:
    if not _authority_path_exists(artifact_path, label=artifact_path.name):
        return None
    return sha256_file(artifact_path)


def last_recorded_artifact_sha(events_log: Path, artifact_name: str) -> str | None:
    key = ARTIFACT_EVENT_KEYS.get(artifact_name)
    if key is None:
        if artifact_name == "STATE.json":
            return last_recorded_state_sha(events_log)
        raise ValueError(f"unknown authoritative artifact: {artifact_name}")
    return last_recorded_for(events_log, key)


def verify_artifact_sha(
    artifact_path: Path,
    events_log: Path,
    artifact_name: str,
) -> tuple[bool, str]:
    """Verify one artifact against its most recent canonical event binding."""
    if artifact_name == "STATE.json":
        return verify_state_sha(artifact_path, events_log)
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
    if not artifact_path.is_file():
        return False, f"{artifact_name} must be a regular file"
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
    inventory = build_artifact_inventory(canonical_repo, run_id)
    from . import util
    return verify_all_artifacts(
        inventory,
        util.run_dir(canonical_repo, run_id) / "EVENTS.log",
    )


__all__ = [
    "ARTIFACT_EVENT_KEYS",
    "AUTHORITATIVE_ARTIFACTS",
    "StateTorn",
    "TamperingDetected",
    "artifact_event_hashes",
    "assert_artifacts_intact",
    "build_artifact_inventory",
    "canonical_json_dumps",
    "compute_event_chain_hash",
    "get_event_chain_hash",
    "last_recorded_artifact_sha",
    "last_recorded_for",
    "last_recorded_state_sha",
    "read_event_chain",
    "record_artifact_sha",
    "record_state_sha",
    "sha256_file",
    "sha256_text",
    "verify_all_artifacts",
    "verify_artifact_sha",
    "verify_state_sha",
]

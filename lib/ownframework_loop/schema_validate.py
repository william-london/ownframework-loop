"""Real schema validation against the JSON schema files.

Loads the JSON schemas from the schemas/ directory and validates authoritative
artifacts against them. Returns a list of validation errors (empty if valid).

Schemas validated:
  - WORK_PACKET.md metadata         (work-packet.schema.json or work-packet-v3.schema.json)
  - APPROVAL.json                   (approval.schema.json)
  - STATE.json                      (state.schema.json or state-v2.schema.json)
  - BUILD_RECEIPT.json              (build-receipt.schema.json)
  - REVIEW_VERDICT.json             (review-verdict.schema.json)

Uses the `jsonschema` library. If jsonschema is unavailable, falls back to
returning a single error: "jsonschema library not installed".

This module is the deterministic finalizer's authoritative validation path.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

try:
    import jsonschema
except Exception:
    jsonschema = None  # type: ignore


SCHEMA_DIR = Path(__file__).resolve().parent.parent.parent / "schemas"


def _load_schema(name: str) -> dict[str, Any] | None:
    path = SCHEMA_DIR / name
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def _select_packet_schema(meta: dict[str, Any]) -> dict[str, Any] | None:
    """Pick the right packet schema for the metadata's schema field."""
    v = meta.get("schema", "")
    if v == "ownframework-work-packet/v3":
        return _load_schema("work-packet-v3.schema.json")
    return _load_schema("work-packet.schema.json")


def _select_state_schema(state: dict[str, Any]) -> dict[str, Any] | None:
    v = state.get("schema", "")
    if v == "ownframework-loop-state/v2":
        return _load_schema("state-v2.schema.json")
    return _load_schema("state.schema.json")


def validate_packet(meta: dict[str, Any]) -> list[str]:
    if jsonschema is None:
        return ["jsonschema library not installed"]
    schema = _select_packet_schema(meta)
    if schema is None:
        return ["packet schema file not loadable"]
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'.'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(meta)]


def validate_approval(doc: dict[str, Any]) -> list[str]:
    if jsonschema is None:
        return ["jsonschema library not installed"]
    schema = _load_schema("approval.schema.json")
    if schema is None:
        return ["approval schema file not loadable"]
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'.'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(doc)]


def validate_state(state: dict[str, Any]) -> list[str]:
    if jsonschema is None:
        return ["jsonschema library not installed"]
    schema = _select_state_schema(state)
    if schema is None:
        return ["state schema file not loadable"]
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'.'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(state)]


def validate_receipt(doc: dict[str, Any]) -> list[str]:
    if jsonschema is None:
        return ["jsonschema library not installed"]
    schema = _load_schema("build-receipt.schema.json")
    if schema is None:
        return ["build-receipt schema file not loadable"]
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'.'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(doc)]


def validate_verdict(doc: dict[str, Any]) -> list[str]:
    if jsonschema is None:
        return ["jsonschema library not installed"]
    schema = _load_schema("review-verdict.schema.json")
    if schema is None:
        return ["review-verdict schema file not loadable"]
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'.'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(doc)]


def validate_all_for_run(canonical_repo: Path, run_id: str) -> dict[str, list[str]]:
    """Validate every authoritative artifact for a run."""
    from . import util
    rd = util.run_dir(canonical_repo, run_id)
    results: dict[str, list[str]] = {}

    packet_path = rd / "WORK_PACKET.md"
    if packet_path.exists():
        from . import packet as packet_mod
        try:
            meta, _ = packet_mod.parse_packet_file(packet_path)
            results["WORK_PACKET.md"] = validate_packet(meta)
        except Exception as e:
            results["WORK_PACKET.md"] = [f"parse_error: {e}"]

    ap = rd / "APPROVAL.json"
    if ap.exists():
        try:
            results["APPROVAL.json"] = validate_approval(json.loads(ap.read_text(encoding="utf-8")))
        except Exception as e:
            results["APPROVAL.json"] = [f"parse_error: {e}"]

    sp = rd / "STATE.json"
    if sp.exists():
        try:
            results["STATE.json"] = validate_state(json.loads(sp.read_text(encoding="utf-8")))
        except Exception as e:
            results["STATE.json"] = [f"parse_error: {e}"]

    br = rd / "BUILD_RECEIPT.json"
    if br.exists():
        try:
            results["BUILD_RECEIPT.json"] = validate_receipt(json.loads(br.read_text(encoding="utf-8")))
        except Exception as e:
            results["BUILD_RECEIPT.json"] = [f"parse_error: {e}"]

    rv = rd / "REVIEW_VERDICT.json"
    if rv.exists():
        try:
            results["REVIEW_VERDICT.json"] = validate_verdict(json.loads(rv.read_text(encoding="utf-8")))
        except Exception as e:
            results["REVIEW_VERDICT.json"] = [f"parse_error: {e}"]

    return results


__all__ = [
    "validate_packet",
    "validate_approval",
    "validate_state",
    "validate_receipt",
    "validate_verdict",
    "validate_all_for_run",
]

"""Current machine-contract validation helpers.

The checked-in JSON schemas are public machine-readable contracts for the
artifacts listed in CURRENT_SCHEMA_FILES. This module is used by validation,
canonical contract tests, and external tooling.

It is intentionally NOT a hidden runtime authority path: build/review
finalizers enforce deterministic invariants directly and do not call this
module. Keeping that distinction explicit prevents a dormant validator from
being mistaken for behavioral proof.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    import jsonschema
except Exception:
    jsonschema = None  # type: ignore

SCHEMA_DIR = Path(__file__).resolve().parent.parent.parent / "schemas"
CURRENT_SCHEMA_FILES = (
    "approval.schema.json",
    "build-receipt.schema.json",
    "review-verdict.schema.json",
    "state.schema.json",
    "state-v2.schema.json",
    "work-packet.schema.json",
    "work-packet-v3.schema.json",
)

def _load_schema(name: str) -> dict[str, Any] | None:
    path = SCHEMA_DIR / name
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None

def _select_packet_schema(meta: dict[str, Any]) -> dict[str, Any] | None:
    return _load_schema("work-packet-v3.schema.json" if meta.get("schema") == "ownframework-work-packet/v3" else "work-packet.schema.json")

def _select_state_schema(state: dict[str, Any]) -> dict[str, Any] | None:
    return _load_schema("state-v2.schema.json" if state.get("schema") == "ownframework-loop-state/v2" else "state.schema.json")

def _type_ok(value: Any, wanted: str) -> bool:
    return {
        "object": isinstance(value, dict), "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool), "null": value is None,
    }.get(wanted, True)

def _fallback_validate(value: Any, schema: dict[str, Any], path: str = "") -> list[str]:
    """Validate the Draft-07 subset used by the current repository schemas."""
    errors: list[str] = []
    label = path or "$"
    if "anyOf" in schema:
        branches = [_fallback_validate(value, branch, path) for branch in schema["anyOf"]]
        if not any(not branch_errors for branch_errors in branches):
            errors.append(f"{label}: value does not satisfy anyOf")
        return errors
    if "oneOf" in schema:
        valid = sum(1 for branch in schema["oneOf"] if not _fallback_validate(value, branch, path))
        if valid != 1:
            errors.append(f"{label}: value must satisfy exactly one oneOf branch")
        return errors
    wanted = schema.get("type")
    if wanted is not None:
        wanted_types = [wanted] if isinstance(wanted, str) else list(wanted)
        if not any(_type_ok(value, item) for item in wanted_types):
            errors.append(f"{label}: expected type {wanted_types}, got {type(value).__name__}")
            return errors
    if "const" in schema and value != schema["const"]:
        errors.append(f"{label}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{label}: value {value!r} not in enum")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < int(schema["minLength"]): errors.append(f"{label}: string shorter than minLength")
        if "maxLength" in schema and len(value) > int(schema["maxLength"]): errors.append(f"{label}: string longer than maxLength")
        pattern = schema.get("pattern")
        if pattern and re.search(pattern, value) is None: errors.append(f"{label}: string does not match pattern {pattern!r}")
        if schema.get("format") == "date-time" and value:
            try: datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError: errors.append(f"{label}: invalid date-time")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]: errors.append(f"{label}: value below minimum")
        if "maximum" in schema and value > schema["maximum"]: errors.append(f"{label}: value above maximum")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < int(schema["minItems"]): errors.append(f"{label}: array shorter than minItems")
        if "maxItems" in schema and len(value) > int(schema["maxItems"]): errors.append(f"{label}: array longer than maxItems")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in value]
            if len(encoded) != len(set(encoded)): errors.append(f"{label}: array items are not unique")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for idx, item in enumerate(value): errors.extend(_fallback_validate(item, item_schema, f"{label}.{idx}"))
    if isinstance(value, dict):
        properties = schema.get("properties") or {}
        for name in schema.get("required") or []:
            if name not in value: errors.append(f"{label}: missing required property {name!r}")
        if schema.get("additionalProperties") is False:
            for name in sorted(set(value) - set(properties)): errors.append(f"{label}: additional property {name!r} is not allowed")
        for name, child in properties.items():
            if name in value and isinstance(child, dict): errors.extend(_fallback_validate(value[name], child, f"{label}.{name}"))
    return errors

def _validate(doc: Any, schema: dict[str, Any] | None, missing: str) -> list[str]:
    if schema is None: return [missing]
    if jsonschema is not None:
        cls = jsonschema.validators.validator_for(schema)
        cls.check_schema(schema)
        validator = cls(schema)
        return [f"{'.'.join(map(str, e.path)) or '$'}: {e.message}" for e in validator.iter_errors(doc)]
    return _fallback_validate(doc, schema)

def validate_packet(meta: dict[str, Any]) -> list[str]:
    return _validate(meta, _select_packet_schema(meta), "packet schema file not loadable")
def validate_approval(doc: dict[str, Any]) -> list[str]:
    return _validate(doc, _load_schema("approval.schema.json"), "approval schema file not loadable")
def validate_state(state: dict[str, Any]) -> list[str]:
    return _validate(state, _select_state_schema(state), "state schema file not loadable")
def validate_receipt(doc: dict[str, Any]) -> list[str]:
    return _validate(doc, _load_schema("build-receipt.schema.json"), "build receipt schema file not loadable")
def validate_verdict(doc: dict[str, Any]) -> list[str]:
    return _validate(doc, _load_schema("review-verdict.schema.json"), "review verdict schema file not loadable")

def validate_all_for_run(canonical_repo: Path, run_id: str) -> dict[str, list[str]]:
    """Validate every current schema-bearing artifact present for one run."""
    from . import util
    rd = util.run_dir(canonical_repo, run_id)
    results: dict[str, list[str]] = {}
    packet_path = rd / "WORK_PACKET.md"
    if packet_path.exists():
        from . import packet as packet_mod
        try:
            meta, _ = packet_mod.parse_packet_file(packet_path)
            results["WORK_PACKET.md"] = validate_packet(meta)
        except Exception as exc:
            results["WORK_PACKET.md"] = [f"parse_error: {exc}"]
    for name, validator in (
        ("APPROVAL.json", validate_approval), ("STATE.json", validate_state),
        ("BUILD_RECEIPT.json", validate_receipt), ("REVIEW_VERDICT.json", validate_verdict),
    ):
        path = rd / name
        if not path.exists(): continue
        try: results[name] = validator(json.loads(path.read_text(encoding="utf-8")))
        except Exception as exc: results[name] = [f"parse_error: {exc}"]
    return results

__all__ = ["CURRENT_SCHEMA_FILES","validate_packet","validate_approval","validate_state","validate_receipt","validate_verdict","validate_all_for_run"]

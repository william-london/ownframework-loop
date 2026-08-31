"""Deterministic machine-contract validation for authoritative artifacts.

The checked-in JSON schemas are the structural authority for the current
protocol artifacts listed in CURRENT_SCHEMA_FILES. Runtime admission/finalizer
paths call this module before applying higher-level deterministic invariants.

Authority split:
  * checked-in schemas + this repository-owned Draft-07 subset validator:
    structural JSON validity;
  * deterministic Python protocol:
    lifecycle identity, exact SHA binding, budgets, scope, state transitions,
    execution seals, PROGRAM semantics, recovery, and authority restrictions.

Runtime behavior never depends on an ambient optional jsonschema package.
The supported schema-keyword set is explicit and regression-tested so adding an
unsupported keyword fails closed instead of being silently ignored.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

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

_ANNOTATION_KEYWORDS = frozenset(
    {"$schema", "$id", "title", "description", "default"}
)
_VALIDATION_KEYWORDS = frozenset(
    {
        "type", "const", "enum", "format", "pattern", "minLength", "maxLength",
        "minimum", "maximum", "minItems", "maxItems", "uniqueItems", "items",
        "properties", "required", "additionalProperties", "anyOf", "oneOf",
    }
)
SUPPORTED_SCHEMA_KEYWORDS = _ANNOTATION_KEYWORDS | _VALIDATION_KEYWORDS
_SUPPORTED_TYPES = frozenset(
    {"object", "array", "string", "integer", "number", "boolean", "null"}
)
_SUPPORTED_FORMATS = frozenset({"date-time"})
_RFC3339_DATETIME_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"
    r"(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)


def _load_schema(name: str) -> dict[str, Any] | None:
    path = SCHEMA_DIR / name
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    return value if isinstance(value, dict) else None


def _select_packet_schema(meta: dict[str, Any]) -> dict[str, Any] | None:
    if meta.get("schema") == "ownframework-work-packet/v3":
        return _load_schema("work-packet-v3.schema.json")
    return _load_schema("work-packet.schema.json")


def _select_state_schema(state: dict[str, Any]) -> dict[str, Any] | None:
    if state.get("schema") == "ownframework-loop-state/v2":
        return _load_schema("state-v2.schema.json")
    return _load_schema("state.schema.json")


def _type_ok(value: Any, wanted: str) -> bool:
    checks = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }
    return bool(checks.get(wanted, False))


def _schema_keyword_errors(schema: Any, path: str = "$") -> list[str]:
    """Return unsupported/ill-defined schema-keyword errors recursively."""
    if not isinstance(schema, dict):
        return [f"{path}: schema node must be an object"]

    errors: list[str] = []
    for key in schema:
        if key not in SUPPORTED_SCHEMA_KEYWORDS:
            errors.append(f"{path}: unsupported schema keyword {key!r}")

    wanted = schema.get("type")
    if wanted is not None:
        values = [wanted] if isinstance(wanted, str) else wanted
        if not isinstance(values, list) or not values:
            errors.append(f"{path}: type must be a string or non-empty array")
        else:
            for item in values:
                if item not in _SUPPORTED_TYPES:
                    errors.append(f"{path}: unsupported schema type {item!r}")

    fmt = schema.get("format")
    if fmt is not None and fmt not in _SUPPORTED_FORMATS:
        errors.append(f"{path}: unsupported schema format {fmt!r}")

    props = schema.get("properties")
    if props is not None:
        if not isinstance(props, dict):
            errors.append(f"{path}.properties: must be an object")
        else:
            for name, child in props.items():
                errors.extend(_schema_keyword_errors(child, f"{path}.properties.{name}"))

    items = schema.get("items")
    if items is not None:
        if not isinstance(items, dict):
            errors.append(f"{path}.items: only a single object schema is supported")
        else:
            errors.extend(_schema_keyword_errors(items, f"{path}.items"))

    for keyword in ("anyOf", "oneOf"):
        branches = schema.get(keyword)
        if branches is None:
            continue
        if not isinstance(branches, list) or not branches:
            errors.append(f"{path}.{keyword}: must be a non-empty array")
            continue
        for idx, branch in enumerate(branches):
            errors.extend(_schema_keyword_errors(branch, f"{path}.{keyword}[{idx}]"))

    additional = schema.get("additionalProperties")
    if isinstance(additional, dict):
        errors.extend(
            _schema_keyword_errors(additional, f"{path}.additionalProperties")
        )
    elif additional is not None and not isinstance(additional, bool):
        errors.append(f"{path}.additionalProperties: must be boolean or object")
    return errors


def schema_keyword_coverage_errors() -> list[str]:
    """Prove every checked-in current schema stays inside the owned subset."""
    errors: list[str] = []
    for name in CURRENT_SCHEMA_FILES:
        schema = _load_schema(name)
        if schema is None:
            errors.append(f"{name}: schema file not loadable")
            continue
        errors.extend(f"{name}: {err}" for err in _schema_keyword_errors(schema))
    return errors


def _valid_datetime(value: str) -> bool:
    if _RFC3339_DATETIME_RE.fullmatch(value) is None:
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def _fallback_validate(
    value: Any,
    schema: dict[str, Any],
    path: str = "",
) -> list[str]:
    """Validate the exact Draft-07 subset used by the current schemas."""
    errors: list[str] = []
    label = path or "$"

    if "anyOf" in schema:
        branches = [
            _fallback_validate(value, branch, path)
            for branch in schema["anyOf"]
        ]
        if not any(not branch_errors for branch_errors in branches):
            errors.append(f"{label}: value does not satisfy anyOf")

    if "oneOf" in schema:
        valid = sum(
            1
            for branch in schema["oneOf"]
            if not _fallback_validate(value, branch, path)
        )
        if valid != 1:
            errors.append(f"{label}: value must satisfy exactly one oneOf branch")

    wanted = schema.get("type")
    if wanted is not None:
        wanted_types = [wanted] if isinstance(wanted, str) else list(wanted)
        if not any(_type_ok(value, item) for item in wanted_types):
            errors.append(
                f"{label}: expected type {wanted_types}, got {type(value).__name__}"
            )
            return errors

    if "const" in schema and value != schema["const"]:
        errors.append(f"{label}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{label}: value {value!r} not in enum")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < int(schema["minLength"]):
            errors.append(f"{label}: string shorter than minLength")
        if "maxLength" in schema and len(value) > int(schema["maxLength"]):
            errors.append(f"{label}: string longer than maxLength")
        pattern = schema.get("pattern")
        if pattern and re.search(pattern, value) is None:
            errors.append(f"{label}: string does not match pattern {pattern!r}")
        if schema.get("format") == "date-time" and not _valid_datetime(value):
            errors.append(f"{label}: invalid date-time")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{label}: value below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{label}: value above maximum")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < int(schema["minItems"]):
            errors.append(f"{label}: array shorter than minItems")
        if "maxItems" in schema and len(value) > int(schema["maxItems"]):
            errors.append(f"{label}: array longer than maxItems")
        if schema.get("uniqueItems"):
            encoded = [
                json.dumps(item, sort_keys=True, separators=(",", ":"))
                for item in value
            ]
            if len(encoded) != len(set(encoded)):
                errors.append(f"{label}: array items are not unique")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for idx, item in enumerate(value):
                errors.extend(
                    _fallback_validate(item, item_schema, f"{label}.{idx}")
                )

    if isinstance(value, dict):
        properties = schema.get("properties") or {}
        for name in schema.get("required") or []:
            if name not in value:
                errors.append(f"{label}: missing required property {name!r}")

        extras = sorted(set(value) - set(properties))
        additional = schema.get("additionalProperties", True)
        if additional is False:
            for name in extras:
                errors.append(
                    f"{label}: additional property {name!r} is not allowed"
                )
        elif isinstance(additional, dict):
            for name in extras:
                errors.extend(
                    _fallback_validate(
                        value[name],
                        additional,
                        f"{label}.{name}",
                    )
                )

        for name, child in properties.items():
            if name in value and isinstance(child, dict):
                errors.extend(
                    _fallback_validate(value[name], child, f"{label}.{name}")
                )
    return errors


def _validate(
    doc: Any,
    schema: dict[str, Any] | None,
    missing: str,
) -> list[str]:
    if schema is None:
        return [missing]
    coverage = _schema_keyword_errors(schema)
    if coverage:
        return ["schema definition invalid: " + err for err in coverage]
    return _fallback_validate(doc, schema)


def validate_packet(meta: dict[str, Any]) -> list[str]:
    return _validate(
        meta,
        _select_packet_schema(meta),
        "packet schema file not loadable",
    )


def validate_approval(doc: dict[str, Any]) -> list[str]:
    return _validate(
        doc,
        _load_schema("approval.schema.json"),
        "approval schema file not loadable",
    )


def validate_state(state: dict[str, Any]) -> list[str]:
    return _validate(
        state,
        _select_state_schema(state),
        "state schema file not loadable",
    )


def validate_receipt(doc: dict[str, Any]) -> list[str]:
    return _validate(
        doc,
        _load_schema("build-receipt.schema.json"),
        "build receipt schema file not loadable",
    )


def validate_verdict(doc: dict[str, Any]) -> list[str]:
    return _validate(
        doc,
        _load_schema("review-verdict.schema.json"),
        "review verdict schema file not loadable",
    )


def validate_all_for_run(
    canonical_repo: Path,
    run_id: str,
) -> dict[str, list[str]]:
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
        ("APPROVAL.json", validate_approval),
        ("STATE.json", validate_state),
        ("BUILD_RECEIPT.json", validate_receipt),
        ("REVIEW_VERDICT.json", validate_verdict),
    ):
        path = rd / name
        if not path.exists():
            continue
        try:
            results[name] = validator(
                json.loads(path.read_text(encoding="utf-8"))
            )
        except Exception as exc:
            results[name] = [f"parse_error: {exc}"]
    return results


__all__ = [
    "CURRENT_SCHEMA_FILES",
    "SUPPORTED_SCHEMA_KEYWORDS",
    "schema_keyword_coverage_errors",
    "validate_packet",
    "validate_approval",
    "validate_state",
    "validate_receipt",
    "validate_verdict",
    "validate_all_for_run",
]

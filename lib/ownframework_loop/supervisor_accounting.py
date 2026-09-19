"""Supervisor accounting — cost / token / model telemetry observation.

Owns:
  * Cost extraction from a durable provider envelope file
    (total_cost_usd).
  * Token usage extraction from a durable provider envelope file
    (input_tokens, output_tokens, cache_read_tokens,
    cache_creation_tokens).
  * Effective-model extraction from a provider envelope (the
    model the provider ACTUALLY billed/reported, distinct from
    the runner profile's REQUESTED model).
  * Full modelUsage JSON extraction (preserved when a singular
    effective model is not provable).
  * Strict-profile-model violation truth gate.

What stays in ``supervisor.py``:
  * The actual durable provider envelope reader
    (``_read_durable_provider_envelope``) — that helper
    enforces the file-size ceiling and is owned by the
    supervisor's subprocess-output authority.
  * The accounting *recording* into the durable DB
    (``_account_attempt_cost``, ``_publish_semantic_acceptance``)
    — those couple the parsed observation to the durable state
    schema + retry policy.  They belong with the attempts /
    recovery owners.

This module is observation-only.  PROGRAM authority decides
whether spend is permitted (entitlement); this module decides how
much was spent (observation).
"""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any


# Maximum effective-model length we accept from a provider envelope.
# Mirrors the legacy 256-char ceiling historically applied in
# supervisor.py; kept here so callers do not need to know the
# historical reason for the cap.
EFFECTIVE_MODEL_MAX_LEN = 256


def _read_envelope_payload(path: str | None) -> dict[str, Any] | None:
    """Read a provider envelope file and parse its JSON payload.

    Returns the parsed dict, or None if the file is missing /
    unreadable / not a JSON object.  Failures are silent: cost
    extraction must NEVER crash a caller over an unreadable
    envelope.
    """
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    try:
        # The provider envelope is a JSON envelope; the durable file
        # may contain a leading diagnostic tail.  We delegate to
        # ``supervisor_runner_io._read_durable_provider_envelope``
        # for the bounded size + UTF-8 read.  Imported here as a
        # lazy import so this module's import surface stays free of
        # supervisor / supervisor_runner_io top-level imports
        # (avoiding cycles).  supervisor_runner_io is the canonical
        # provider-output primitive; we no longer reach upward to
        # ``supervisor``.
        from . import supervisor_runner_io as _runner_io_mod
        envelope_text = _runner_io_mod._read_durable_provider_envelope(p)
        payload = json.loads(envelope_text)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def parse_cost_from_durable_stdout(path: str | None) -> float | None:
    """Recover provider-reported total cost from one durable envelope.

    Returns the cost in USD when the envelope proves a finite,
    non-negative ``total_cost_usd``.  Returns ``None`` when the
    envelope is missing, unreadable, or has no provable cost.
    """
    payload = _read_envelope_payload(path)
    if not isinstance(payload, dict) or "total_cost_usd" not in payload:
        return None
    try:
        value = float(payload.get("total_cost_usd"))
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) and value >= 0 else None


def parse_token_usage_from_durable_stdout(path: str | None) -> dict[str, int] | None:
    """Recover provider-reported token usage from one durable JSON envelope.

    Token telemetry is operational evidence, not engineering
    truth. Unknown token usage is tolerated unless the operator
    explicitly enabled a token ceiling for the job.

    Returns a dict with keys ``input_tokens``, ``output_tokens``,
    ``cache_read_tokens``, ``cache_creation_tokens`` (all int) when
    at least one token field is provable.  Returns ``None`` when
    the envelope is missing, unreadable, has no usage block, or
    has invalid (negative / non-integer) token values.
    """
    payload = _read_envelope_payload(path)
    if not isinstance(payload, dict):
        return None
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        return None

    keys = {
        "input_tokens": "input_tokens",
        "output_tokens": "output_tokens",
        "cache_read_tokens": "cache_read_input_tokens",
        "cache_creation_tokens": "cache_creation_input_tokens",
    }
    recovered: dict[str, int] = {}
    observed = False
    for out_key, source_key in keys.items():
        if source_key not in usage:
            recovered[out_key] = 0
            continue
        try:
            value = int(usage.get(source_key) or 0)
        except (TypeError, ValueError):
            return None
        if value < 0:
            return None
        recovered[out_key] = value
        observed = True
    return recovered if observed else None


def _durable_envelope_payload(path: str | None) -> dict[str, Any] | None:
    """Parse a durable envelope file.  Exposed for callers that want
    the full payload rather than one specific field."""
    return _read_envelope_payload(path)


def extract_effective_model_from_durable_stdout(path: str | None) -> str:
    """Recover the provider-reported effective model from one durable envelope."""
    return extract_effective_model(_durable_envelope_payload(path))


def extract_model_usage_json_from_durable_stdout(path: str | None) -> str:
    """Recover the FULL provider-reported model usage from one durable envelope."""
    return extract_model_usage_json(_durable_envelope_payload(path))


def extract_effective_model(payload: dict[str, Any] | None) -> str:
    """Return the model the provider provably reported, or "" when unprovable.

    The EFFECTIVE model is read from the provider envelope ONLY
    when it is provable: an explicit ``model`` field, or a
    ``modelUsage`` with exactly one model.  When several models
    appear in usage the singular effective model is NOT inferred
    (guessing would certify one provider-reported mix as a single
    model).  Empty string means "not provable from this envelope";
    the FULL provider-reported usage is preserved separately by
    ``extract_model_usage_json``.  The effective model is always
    distinguished from the runner profile's REQUESTED model so a
    substitution/downgrade is never silently certified as the
    requested profile.
    """
    if not isinstance(payload, dict):
        return ""
    model = payload.get("model")
    if isinstance(model, str) and model:
        return model[:EFFECTIVE_MODEL_MAX_LEN]
    usage = payload.get("modelUsage")
    if isinstance(usage, dict) and len(usage) == 1:
        return str(next(iter(usage.keys())))[:EFFECTIVE_MODEL_MAX_LEN]
    return ""


def extract_model_usage_json(payload: dict[str, Any] | None) -> str:
    """Return the canonical JSON of the FULL provider-reported modelUsage.

    Preserved even when a singular effective model is not provable
    (multi-model mixes).  Empty string when no usage block exists.
    """
    if not isinstance(payload, dict):
        return ""
    usage = payload.get("modelUsage")
    if not usage:
        return ""
    try:
        return json.dumps(usage, indent=2, sort_keys=True)
    except (TypeError, ValueError):
        return ""


def strict_profile_model_violation(
    requested_model: str, *, result_ok: bool, effective_model: str
) -> str:
    """Truth gate for quality-strict runner profiles (no inference, no mercy).

    Returns the violation reason, or "" when the attempt may be
    certified at the requested quality:

      * a non-strict request (no explicit model) certifies anything;
      * a strict request certifies ONLY a provably identical
        effective model;
      * a provably different effective model is a substitution;
      * an unprovable effective model under a strict request fails
        closed — absence of proof is never certified as the
        requested profile.
    """
    if not result_ok or not requested_model:
        return ""
    if effective_model and effective_model != requested_model:
        return "runner_profile_model_substitution"
    if not effective_model:
        return "runner_profile_quality_unproven"
    return ""

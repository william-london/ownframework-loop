"""Trusted named semantic-runner profiles.

Repositories request a profile name only. Profiles live in core defaults or an
operator-owned manifest and may express semantic-quality knobs (model/effort),
never sandbox, tools, MCP, cwd, plugin, browser, session, or external authority.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import stat
from typing import Any

SCHEMA = "ownframework-loop-runner-profile/v1"
MANIFEST_SCHEMA = "ownframework-loop-runner-profiles/v1"
CONTRACT_REVISION = "runner-profile-contract/v1"
PROFILE_NAME_RE = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$")
_ALLOWED_EFFORT = frozenset({"low", "medium", "high", "xhigh", "max"})
_MOVING_MODEL_ALIASES = frozenset({
    "default", "best", "sonnet", "opus", "haiku",
    "sonnet[1m]", "opus[1m]", "opusplan",
})


class RunnerProfileError(RuntimeError):
    pass


def _canonical(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def default_manifest_path() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(root).expanduser() if root else Path.home() / ".local" / "state"
    return base / "ownframework-loop" / "runner-profiles.json"


def validate_profile_name(value: Any) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, str) or not PROFILE_NAME_RE.fullmatch(value):
        return ["runner_profile must be a canonical profile name"]
    return []


def _load_manifest(path: Path | None = None) -> tuple[dict[str, Any], str | None, str | None]:
    raw_path = (path or default_manifest_path()).expanduser()
    # Refuse a symlinked authority manifest on the UNRESOLVED path. The previous
    # resolve()-then-is_symlink() ordering followed the link first, so the
    # check ran against the target and could never fire.
    if raw_path.is_symlink():
        raise RunnerProfileError("runner-profile manifest must not be a symlink")
    p = raw_path.resolve(strict=False)
    if not p.exists():
        return {}, None, None
    st = p.stat()
    if not stat.S_ISREG(st.st_mode):
        raise RunnerProfileError("runner-profile manifest must be a regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise RunnerProfileError("runner-profile manifest must be owned by supervisor user")
    if st.st_mode & 0o022:
        raise RunnerProfileError("runner-profile manifest must not be group/world writable")
    raw = p.read_bytes()
    try:
        doc = json.loads(raw.decode())
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RunnerProfileError(f"runner-profile manifest invalid JSON: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("schema") != MANIFEST_SCHEMA:
        raise RunnerProfileError(f"runner-profile manifest schema must be {MANIFEST_SCHEMA!r}")
    if set(doc) - {"schema", "profiles"}:
        raise RunnerProfileError("runner-profile manifest has unsupported top-level keys")
    profiles = doc.get("profiles")
    if not isinstance(profiles, dict):
        raise RunnerProfileError("runner-profile manifest profiles must be an object")
    return profiles, str(p), hashlib.sha256(raw).hexdigest()


def _validated(name: str, raw: dict[str, Any], provider: str) -> dict[str, Any]:
    unknown = sorted(set(raw) - {"provider", "model", "effort"})
    if unknown:
        raise RunnerProfileError(f"runner profile {name!r} has unsupported keys: {unknown}")
    target = raw.get("provider", provider)
    if target != provider:
        raise RunnerProfileError(f"runner profile {name!r} targets {target!r}, not {provider!r}")
    model = raw.get("model")
    if model is not None and (
        not isinstance(model, str) or not model or len(model) > 128
        or model.startswith("-")
        or any(ch.isspace() or ord(ch) < 32 for ch in model)
    ):
        raise RunnerProfileError(f"runner profile {name!r} has invalid model")
    if isinstance(model, str) and (
        model in _MOVING_MODEL_ALIASES or model.endswith("[1m]")
    ):
        raise RunnerProfileError(
            f"runner profile {name!r} explicit model must be a pinned provider "
            "model identity, not a moving Claude alias/context selector"
        )
    effort = raw.get("effort")
    if effort is not None and effort not in _ALLOWED_EFFORT:
        raise RunnerProfileError(
            f"runner profile {name!r} effort must be one of {sorted(_ALLOWED_EFFORT)}"
        )
    stable = {
        "contract_revision": CONTRACT_REVISION,
        "name": name, "provider": provider, "model": model, "effort": effort,
    }
    stable["identity_sha256"] = hashlib.sha256(_canonical(stable)).hexdigest()
    return stable


def resolve_profile(
    requested: str | None, *, provider: str, manifest_path: Path | None = None
) -> dict[str, Any]:
    name = str(requested or "default")
    errors = validate_profile_name(name)
    if errors:
        raise RunnerProfileError("; ".join(errors))
    profiles, source, source_sha = _load_manifest(manifest_path)
    if name == "default":
        raw: dict[str, Any] = {}
        source = None
        source_sha = None
    else:
        value = profiles.get(name)
        if not isinstance(value, dict):
            raise RunnerProfileError(f"runner profile {name!r} is not commissioned")
        raw = value
    return {
        "schema": SCHEMA,
        **_validated(name, raw, provider),
        "source_manifest_path": source,
        "source_manifest_sha256": source_sha,
    }


def verify_profile_integrity(profile: dict[str, Any]) -> None:
    current = resolve_profile(
        str(profile.get("name") or ""),
        provider=str(profile.get("provider") or ""),
        manifest_path=Path(str(profile["source_manifest_path"]))
        if profile.get("source_manifest_path") else None,
    )
    if current.get("identity_sha256") != profile.get("identity_sha256"):
        raise RunnerProfileError("runner profile changed after resolution")


# ---------------------------------------------------------------------------
# Strict-quality commissioning.
#
# A profile that requests an explicit `effort` demands a quality the provider
# envelope cannot prove empirically (unlike `model`, which the envelope can
# reveal). Such a profile is therefore only runnable when an operator has
# COMMISSIONED an effort attestation binding exactly that profile/provider/
# model/effort. Without it the profile fails closed BEFORE any model call —
# a silent quality substitution is never certified as the requested profile.
# ---------------------------------------------------------------------------

EFFORT_ATTESTATION_SCHEMA = "ownframework-loop-runner-effort-attestation/v2"


def effort_attestation_path(name: str) -> Path:
    from . import commissioning as commissioning_mod
    return commissioning_mod.default_evidence_dir() / (
        f"runner_profile_{name}_effort_attestation.json"
    )


def write_effort_attestation(
    *,
    name: str,
    provider: str = "claude-code",
    model: str | None = None,
    effort: str | None = None,
    actor: str = "operator",
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    """Commission one strict-effort profile for the CURRENT Claude runtime."""
    from . import capabilities as _cap_mod, util as _util_mod
    profile = resolve_profile(name, provider=provider, manifest_path=manifest_path)
    profile_effort = profile.get("effort")
    if profile_effort is None:
        raise RunnerProfileError(
            f"runner profile {name!r} has no explicit effort to attest"
        )
    if model is not None and str(model or "") != str(profile.get("model") or ""):
        raise RunnerProfileError("effort attestation model does not match resolved profile")
    if effort is not None and effort != profile_effort:
        raise RunnerProfileError("effort attestation effort does not match resolved profile")
    body = {
        "schema": EFFORT_ATTESTATION_SCHEMA,
        "profile": name,
        "provider": provider,
        "model": str(profile.get("model") or ""),
        "effort": str(profile_effort),
        "profile_identity_sha256": str(profile.get("identity_sha256") or ""),
        "semantic_runtime_fingerprint": _cap_mod.semantic_runtime_fingerprint(),
        "attested_actor": actor,
        "attested_at": _util_mod.utc_now_iso(),
    }
    body["attestation_sha256"] = hashlib.sha256(_canonical(body)).hexdigest()
    path = effort_attestation_path(name)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return {**body, "attestation_path": str(path)}


def verify_effort_attestation(profile: dict[str, Any]) -> dict[str, Any] | None:
    """Fail closed unless current runtime/profile identity matches attestation.

    Returns the stable attestation identity to freeze into the run binding and
    attempt receipt. Profiles without explicit effort return None.
    """
    effort = profile.get("effort")
    if effort is None:
        return None
    from . import capabilities as _cap_mod
    name = str(profile.get("name") or "")
    path = effort_attestation_path(name)
    if path.is_symlink() or not path.is_file():
        raise RunnerProfileError(
            f"runner profile {name!r} requests effort {effort!r} but no "
            "commissioned effort attestation exists; refusing before provider call"
        )
    st = path.stat()
    if not stat.S_ISREG(st.st_mode):
        raise RunnerProfileError("effort attestation must be a regular file")
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        raise RunnerProfileError("effort attestation must be owned by supervisor user")
    if st.st_mode & 0o077:
        raise RunnerProfileError("effort attestation must be private")
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RunnerProfileError(f"effort attestation unreadable: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("schema") != EFFORT_ATTESTATION_SCHEMA:
        raise RunnerProfileError("effort attestation schema mismatch")
    claimed = doc.get("attestation_sha256")
    body = {k: v for k, v in doc.items() if k != "attestation_sha256"}
    if not claimed or hashlib.sha256(_canonical(body)).hexdigest() != claimed:
        raise RunnerProfileError("effort attestation digest mismatch")
    checks = {
        "profile": name,
        "provider": profile.get("provider"),
        "model": str(profile.get("model") or ""),
        "effort": effort,
        "profile_identity_sha256": profile.get("identity_sha256"),
        "semantic_runtime_fingerprint": _cap_mod.semantic_runtime_fingerprint(),
    }
    for key, expected in checks.items():
        if doc.get(key) != expected:
            raise RunnerProfileError(f"effort attestation stale or mismatched: {key}")
    return {
        "schema": EFFORT_ATTESTATION_SCHEMA,
        "attestation_sha256": str(claimed),
        "profile_identity_sha256": str(profile.get("identity_sha256") or ""),
        "semantic_runtime_fingerprint": str(
            doc.get("semantic_runtime_fingerprint") or ""
        ),
    }

def public_summary(profile: dict[str, Any]) -> dict[str, Any]:
    out = {k: profile.get(k) for k in (
        "schema", "name", "provider", "model", "effort", "identity_sha256"
    )}
    # Truthful strictness marker: a profile requesting an explicit model or
    # effort is quality-strict and is fail-closed enforced (model proven from
    # the provider envelope; effort requires a commissioned attestation).
    out["strict_quality"] = bool(
        profile.get("model") is not None or profile.get("effort") is not None
    )
    attestation = profile.get("effort_attestation")
    if isinstance(attestation, dict):
        out["effort_attestation_sha256"] = attestation.get("attestation_sha256")
    return out


__all__ = [
    "CONTRACT_REVISION", "EFFORT_ATTESTATION_SCHEMA", "MANIFEST_SCHEMA",
    "PROFILE_NAME_RE", "RunnerProfileError", "SCHEMA", "default_manifest_path",
    "effort_attestation_path", "public_summary", "resolve_profile",
    "validate_profile_name", "verify_effort_attestation",
    "verify_profile_integrity", "write_effort_attestation",
]

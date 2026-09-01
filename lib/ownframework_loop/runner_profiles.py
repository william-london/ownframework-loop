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

EFFORT_ATTESTATION_SCHEMA = "ownframework-loop-runner-effort-attestation/v1"


def effort_attestation_path(name: str) -> Path:
    from . import commissioning as commissioning_mod
    return commissioning_mod.default_evidence_dir() / (
        f"runner_profile_{name}_effort_attestation.json"
    )


def write_effort_attestation(
    *, name: str, provider: str, model: str | None, effort: str, actor: str = "operator"
) -> dict[str, Any]:
    """Operator commissioning artifact for one strict-effort runner profile.

    Private (0600/0700) and digest-bound; verified field-by-field before any
    provider call for a strict profile.
    """
    from . import util as _util_mod
    errors = validate_profile_name(name)
    if errors:
        raise RunnerProfileError("; ".join(errors))
    if effort not in _ALLOWED_EFFORT:
        raise RunnerProfileError(
            f"effort attestation effort must be one of {sorted(_ALLOWED_EFFORT)}"
        )
    if not provider:
        raise RunnerProfileError("effort attestation requires a provider")
    body = {
        "schema": EFFORT_ATTESTATION_SCHEMA,
        "profile": name,
        "provider": provider,
        "model": str(model or ""),
        "effort": effort,
        "attested_actor": actor,
        "attested_at": _util_mod.utc_now_iso(),
    }
    body["attestation_sha256"] = hashlib.sha256(_canonical(body)).hexdigest()
    path = effort_attestation_path(name)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return {**body, "attestation_path": str(path)}


def verify_effort_attestation(profile: dict[str, Any]) -> None:
    """Fail closed unless a commissioned attestation proves the strict effort.

    Profiles without an explicit `effort` are not effort-strict and pass.
    Anything else — missing file, symlink, non-private/non-regular file,
    schema/digest/field mismatch — refuses before any model call.
    """
    effort = profile.get("effort")
    if effort is None:
        return
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
    if doc.get("profile") != name or doc.get("provider") != profile.get("provider"):
        raise RunnerProfileError("effort attestation does not bind this profile/provider")
    if doc.get("effort") != effort:
        raise RunnerProfileError(
            f"effort attestation binds {doc.get('effort')!r}, not requested {effort!r}"
        )
    if doc.get("model") != str(profile.get("model") or ""):
        raise RunnerProfileError("effort attestation does not bind this model")


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
    return out


__all__ = [
    "CONTRACT_REVISION", "EFFORT_ATTESTATION_SCHEMA", "MANIFEST_SCHEMA",
    "PROFILE_NAME_RE", "RunnerProfileError", "SCHEMA", "default_manifest_path",
    "effort_attestation_path", "public_summary", "resolve_profile",
    "validate_profile_name", "verify_effort_attestation",
    "verify_profile_integrity", "write_effort_attestation",
]

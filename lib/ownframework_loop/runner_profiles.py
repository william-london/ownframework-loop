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


def public_summary(profile: dict[str, Any]) -> dict[str, Any]:
    return {k: profile.get(k) for k in (
        "schema", "name", "provider", "model", "effort", "identity_sha256"
    )}


__all__ = [
    "CONTRACT_REVISION", "MANIFEST_SCHEMA", "PROFILE_NAME_RE",
    "RunnerProfileError", "SCHEMA", "default_manifest_path", "public_summary",
    "resolve_profile", "validate_profile_name", "verify_profile_integrity",
]

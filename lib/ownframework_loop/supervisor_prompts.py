"""Supervisor prompt construction and provenance authority."""
from __future__ import annotations

import hashlib
import json
import os
import stat
from pathlib import Path
from typing import Any

from . import state as state_mod
from . import util

def _source_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent

def _load_role_prompt(role: str) -> str:
    name = "of-builder.md" if role == "builder" else "of-reviewer.md"
    path = _source_root() / "agents" / name
    if not path.is_file():
        raise RuntimeError(f"runner prompt missing: {path}")
    return path.read_text(encoding="utf-8")

def _write_semantic_prompt_provenance(
    *,
    work_order: dict[str, Any],
    effective_work_order: dict[str, Any],
    prompt: str,
    role_contract: str,
) -> Path:
    """Persist the exact semantic envelope before provider launch.

    Only the sealed work order and public capability summaries are recorded;
    process environment, credentials, and provider output are intentionally
    excluded.  The prompt bytes are stored so a retry or adjudication can
    prove exactly what the provider received.
    """
    repo = Path(str(work_order.get("canonical_repo") or "")).resolve(strict=False)
    run_id = str(work_order.get("run_id") or "")
    attempt_id = str(work_order.get("attempt_id") or "")
    role = str(work_order.get("role") or "")
    if not attempt_id or role not in {"builder", "reviewer"}:
        raise RuntimeError("semantic provenance requires attempt identity and role")
    # Work orders are core-owned JSON.  These are the only fields written;
    # notably no shell environment, access token, or provider credential is
    # copied into the durable artifact.
    safe_order = json.loads(json.dumps(effective_work_order, sort_keys=True))
    for forbidden in ("env", "environment", "token", "credential", "secret", "api_key", "authorization"):
        safe_order.pop(forbidden, None)
    payload = {
        "schema": "ownframework-loop-semantic-prompt-provenance/v1",
        "run_id": run_id,
        "attempt_id": attempt_id,
        "role": role,
        "decision": str(work_order.get("decision") or ""),
        "checkpoint_id": str(work_order.get("checkpoint_id") or ""),
        "work_unit_id": str(work_order.get("work_unit_id") or ""),
        "candidate_sha": str(work_order.get("candidate_sha") or ""),
        "packet_sha256": str(work_order.get("packet_sha256") or ""),
        "approval_sha256": str(work_order.get("approval_sha256") or ""),
        "work_order": safe_order,
        "prompt": prompt,
        "prompt_sha256": util.sha256_bytes(prompt.encode("utf-8")),
        "role_contract_sha256": util.sha256_bytes(role_contract.encode("utf-8")),
        "recorded_at": util.utc_now_iso(),
    }
    target_dir = state_mod.run_dir(repo, run_id) / "semantic-provenance"
    target_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(target_dir, 0o700)
    target = target_dir / f"{attempt_id}-{role}.json"
    if target.exists():
        prior = util.read_private_json(target, default=None)
        if not isinstance(prior, dict) or prior.get("prompt_sha256") != payload["prompt_sha256"]:
            raise RuntimeError("semantic prompt provenance collision")
        return target
    util.atomic_write_json(target, payload, mode=0o600)
    if stat.S_IMODE(target.stat().st_mode) != 0o600:
        raise RuntimeError("semantic prompt provenance mode proof failed")
    return target

__all__ = [
    "_source_root",
    "_load_role_prompt",
    "_write_semantic_prompt_provenance",
]

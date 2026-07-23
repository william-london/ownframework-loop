"""Work packet parsing, validation, hashing, and approval binding."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

from .util import sha256_text, utc_now_iso, ensure_mode


SCHEMA_VERSION = "ownframework-work-packet/v1"

WORK_CLASSES = {
    "NEW_REPOSITORY", "FEATURE", "BUG", "DEBUG", "HARDENING",
    "REFACTOR", "TESTING", "DOCUMENTATION", "CI_REPAIR",
    "TRACKED_CONTRACT", "RUNTIME_CANDIDATE", "RESEARCH_SPIKE",
}

RISK_CLASSES = {"low", "medium", "high"}

REQUIRED_FIELDS = (
    "schema", "packet_id", "created_at", "work_class", "risk_class",
    "title", "target", "acceptance_criteria", "non_goals",
    "allowed_paths", "protected_paths", "work_units",
    "merge_authority", "deploy_authority", "push_authority",
    "external_action_authority",
)


def parse_packet_file(path: Path) -> tuple[dict[str, Any], str]:
    """Parse a WORK_PACKET.md file. Returns (metadata_dict, raw_text).

    The packet has a JSON metadata block enclosed in fenced code blocks
    (```json ... ```), followed by readable Markdown. The first JSON block
    is authoritative. Pure stdlib — no YAML dependency.
    """
    text = path.read_text(encoding="utf-8")
    meta = _extract_metadata_block(text)
    return meta, text


def _extract_metadata_block(text: str) -> dict[str, Any]:
    """Extract the first ```json ... ``` fenced block."""
    pattern = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)
    match = pattern.search(text)
    if not match:
        raise ValueError("WORK_PACKET.md missing ```json metadata block")
    try:
        return json.loads(match.group(1))
    except json.JSONDecodeError as e:
        raise ValueError(f"WORK_PACKET.md metadata is not valid JSON: {e}") from e


def validate_packet_metadata(meta: dict[str, Any]) -> list[str]:
    """Return list of validation errors (empty if valid)."""
    errors: list[str] = []
    for f in REQUIRED_FIELDS:
        if f not in meta:
            errors.append(f"missing required field: {f}")
    if meta.get("schema") != SCHEMA_VERSION:
        errors.append(f"schema must be {SCHEMA_VERSION}")
    wc = meta.get("work_class")
    if wc not in WORK_CLASSES:
        errors.append(f"invalid work_class: {wc}")
    rc = meta.get("risk_class")
    if rc not in RISK_CLASSES:
        errors.append(f"invalid risk_class: {rc}")
    tgt = meta.get("target")
    if isinstance(tgt, dict):
        repo = tgt.get("repo")
        if not isinstance(repo, str) or not Path(repo).is_absolute():
            errors.append("target.repo must be absolute path")
        for k in ("branch", "classification"):
            if k not in tgt:
                errors.append(f"target.{k} missing")
        cls = tgt.get("classification")
        if cls not in ("local_only", "github_private", "github_public"):
            errors.append(f"invalid target.classification: {cls}")
    else:
        errors.append("target must be an object")
    if not isinstance(meta.get("acceptance_criteria"), list) or not meta["acceptance_criteria"]:
        errors.append("acceptance_criteria must be a non-empty array")
    if not isinstance(meta.get("work_units"), list) or not meta["work_units"]:
        errors.append("work_units must be a non-empty array")
    if not isinstance(meta.get("allowed_paths"), list) or not meta["allowed_paths"]:
        errors.append("allowed_paths must be a non-empty array")
    if not isinstance(meta.get("protected_paths"), list) or not meta["protected_paths"]:
        errors.append("protected_paths must be a non-empty array")
    for auth in ("merge_authority", "deploy_authority", "push_authority", "external_action_authority"):
        v = meta.get(auth)
        if v not in ("human_only", "delegated", "none"):
            errors.append(f"{auth} must be human_only|delegated|none, got: {v}")
    return errors


def is_approved(meta: dict[str, Any]) -> bool:
    """Return True if the packet has been approved."""
    if meta.get("human_approved") is True:
        return True
    if meta.get("approved_packet_sha256") and meta.get("approved_at"):
        return True
    return False


def packet_file_sha256(path: Path) -> str:
    """SHA-256 of the raw packet bytes."""
    return sha256_text(path.read_text(encoding="utf-8"))


def packet_metadata_sha256(meta: dict[str, Any]) -> str:
    """SHA-256 of the deterministic metadata serialization."""
    return sha256_text(json.dumps(meta, indent=2, sort_keys=True))


def apply_approval(meta: dict[str, Any], *, packet_sha256: str, actor: str) -> dict[str, Any]:
    """Return a copy of meta with approval fields stamped. Does not write."""
    new = dict(meta)
    new["human_approved"] = True
    new["approved_at"] = utc_now_iso()
    new["approved_actor"] = actor
    new["approved_packet_sha256"] = packet_sha256
    return new


def write_approved_packet(path: Path, meta: dict[str, Any], body_text: str) -> None:
    """Rewrite the packet file with the updated metadata block + body."""
    fence_open = "```json\n"
    fence_close = "\n```"
    body_without_meta = _strip_first_metadata_block(body_text)
    payload = fence_open + json.dumps(meta, indent=2, sort_keys=True) + fence_close + "\n" + body_without_meta
    path.write_text(payload, encoding="utf-8")
    ensure_mode(path, 0o600)


def _strip_first_metadata_block(text: str) -> str:
    pattern = re.compile(r"```json\s*\n.*?\n```\n?", re.DOTALL)
    return pattern.sub("", text, count=1)


def paths_within_packet(packet: dict[str, Any]) -> set[str]:
    """Return the union of allowed + protected paths (for fast membership)."""
    s = set()
    for p in packet.get("allowed_paths", []):
        s.add(p.rstrip("/") + "/")
        s.add(p)
    for p in packet.get("protected_paths", []):
        s.add(p.rstrip("/") + "/")
        s.add(p)
    return s


def _normalize_path_for_compare(p: str) -> str:
    """Normalize a path for membership comparison.

    Strips a single leading `./`, then a single leading `/`. Does NOT
    strip arbitrary leading dots — `.claude/` is meaningful.
    """
    s = p
    if s.startswith("./"):
        s = s[2:]
    if s.startswith("/"):
        s = s[1:]
    return s


def is_protected_path(packet: dict[str, Any], file_path: str) -> bool:
    """Return True if file_path is in the packet's protected_paths."""
    pp = [_normalize_path_for_compare(p).rstrip("/") for p in packet.get("protected_paths", [])]
    fp = _normalize_path_for_compare(file_path)
    for p in pp:
        if p == "":
            continue
        if fp == p or fp.startswith(p + "/"):
            return True
    return False


def is_allowed_path(packet: dict[str, Any], file_path: str) -> bool:
    """Return True if file_path is within the packet's allowed_paths."""
    ap = [_normalize_path_for_compare(p).rstrip("/") for p in packet.get("allowed_paths", [])]
    fp = _normalize_path_for_compare(file_path)
    for p in ap:
        if p == "":
            continue
        if fp == p or fp.startswith(p + "/"):
            return True
    return False

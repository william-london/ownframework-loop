"""REVIEW_AGENT_ASSESSMENT.json skeleton scaffolding.

v0.4.2: the deterministic review finalizer (review_finalize.py) refuses
any assessment whose top-level shape does not match the schema contract.
Previous live failures (v0.4.1 commissioning) saw the reviewer agent
emit the verdict under a wrong field name (`verdict_recommendation`)
with the wrong case (`approved`). This module makes the contract
unambiguous: a single template ships with the source tree, and a single
helper writes a per-run skeleton pre-populated with the exact run id,
candidate SHA, packet SHA, and approval SHA.

The reviewer agent's responsibility is to:
  1. Run `ofloop review assessment <repo> <run-id>` to materialize a
     skeleton at the run scratch path.
  2. Fill in only the values that are runtime-dependent:
     acceptance_results, non_goal_results, findings, validation_results,
     recommended_verdict, evidence strings, timestamp.
  3. NOT rename any top-level key, NOT change the verdict casing, NOT
     introduce new top-level keys.

If a runtime value would force a top-level rename, the reviewer agent
must STOP and report the contract drift — the deterministic finalizer
will still refuse.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from . import approval as approval_mod
from . import git_checks, packet as packet_mod, state as state_mod, util


SCHEMA_AGENT_ASSESSMENT = "ownframework-loop-review-agent-assessment/v1"
ASSESSMENT_TEMPLATE_NAME = "REVIEW_AGENT_ASSESSMENT.template.json"

# Top-level keys the reviewer agent is expected to fill in (everything
# else is pre-populated by the skeleton helper).
FILLABLE_KEYS: frozenset[str] = frozenset(
    {
        "validation_results",
        "acceptance_results",
        "non_goal_results",
        "findings",
        "recommended_verdict",
        "escalation_recommended",
        "escalation_reason",
        "timestamp",
    }
)

# Verdict enum — exact uppercase required.
ALLOWED_RECOMMENDED_VERDICTS: frozenset[str] = frozenset(
    {
        "APPROVED",
        "CHANGES_REQUESTED",
        "BLOCKED",
        "HUMAN_REVIEW_REQUIRED",
        "STALE_CANDIDATE",
    }
)


def template_path(source_root: Path) -> Path:
    """Return the absolute path of the bundled assessment template."""
    return source_root / "templates" / ASSESSMENT_TEMPLATE_NAME


def assessment_path(canonical_repo: Path, run_id: str) -> Path:
    """Return the current claimed review pass's semantic-assessment path.

    v0.4.5: pass-scoped scratch prevents a later checkpoint from reusing a
    prior review's filled assessment while preserving same-pass crash resume.
    """
    state = state_mod.load_verified(canonical_repo, run_id)
    pass_number = int((state or {}).get("review_pass_count") or 0)
    if pass_number < 1:
        raise RuntimeError(
            "review_pass_count=0; claim the review pass before materializing the assessment"
        )
    return (
        state_mod.run_dir(canonical_repo, run_id)
        / "scratch" / "reviewer" / f"pass-{pass_number:04d}"
        / "REVIEW_AGENT_ASSESSMENT.json"
    )


def _find_source_root(start: Path) -> Path | None:
    """Walk upward from `start` looking for the source tree root marker.

    The source root contains `templates/REVIEW_AGENT_ASSESSMENT.template.json`
    and `lib/ownframework_loop/`. We accept either as the marker. This
    works for both the source checkout and the installed cache
    (`~/.claude/plugins/cache/ownframework/of-loop/<version>/`).
    """
    p = start.resolve()
    for candidate in (p, *p.parents):
        if (candidate / "templates" / ASSESSMENT_TEMPLATE_NAME).is_file():
            return candidate
    return None


def _resolve_candidate_sha(canonical_repo: Path, run_id: str) -> str:
    """Read BUILD_RECEIPT.json.candidate_sha for the run, raising if absent.

    Reviewers must always scaffold from the build receipt's recorded
    candidate SHA — never from a freshly-resolved HEAD. If the receipt
    is missing, the helper raises so the agent does not write a skeleton
    pinned to the wrong SHA.
    """
    receipt = state_mod.run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"
    if not receipt.exists():
        raise RuntimeError(
            f"BUILD_RECEIPT.json missing for run {run_id}; cannot scaffold assessment"
        )
    try:
        data = json.loads(receipt.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise RuntimeError(f"BUILD_RECEIPT.json malformed: {e}") from e
    sha = data.get("candidate_sha")
    if not sha or not isinstance(sha, str):
        raise RuntimeError(
            f"BUILD_RECEIPT.json missing candidate_sha for run {run_id}"
        )
    return sha


def _resolve_build_receipt_sha256(canonical_repo: Path, run_id: str) -> str:
    receipt = state_mod.run_dir(canonical_repo, run_id) / "BUILD_RECEIPT.json"
    if not receipt.exists():
        raise RuntimeError(
            f"BUILD_RECEIPT.json missing for run {run_id}; cannot bind assessment"
        )
    return util.sha256_file(receipt)


def _resolve_approval_sha256(canonical_repo: Path, run_id: str) -> str:
    """Read APPROVAL.json and return its deterministic artifact SHA-256."""
    approval_doc = approval_mod.load_approval(canonical_repo, run_id)
    if not approval_doc:
        raise RuntimeError(
            f"APPROVAL.json missing for run {run_id}; cannot scaffold assessment"
        )
    return approval_mod.approval_artifact_sha256(approval_doc)


def _resolve_packet_sha256(canonical_repo: Path, run_id: str) -> str:
    """Recompute the packet SHA from the current on-disk bytes."""
    packet_p = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not packet_p.exists():
        raise RuntimeError(
            f"WORK_PACKET.md missing for run {run_id}; cannot scaffold assessment"
        )
    return util.sha256_text(packet_p.read_text(encoding="utf-8"))


def _resolve_run_id(canonical_repo: Path, run_id: str | None) -> str:
    """Resolve the run id from an explicit arg or the single active run."""
    if run_id:
        return run_id
    rd = canonical_repo / ".ownframework-loop"
    # Enumerate the state root directly; run_dir intentionally rejects an
    # empty run id to protect the run namespace.
    if not rd.is_dir():
        raise RuntimeError(f"no .ownframework-loop directory under {canonical_repo}")
    runs = sorted(p.name for p in rd.iterdir() if p.is_dir() and p.name.startswith("run-"))
    if not runs:
        raise RuntimeError(
            f"no run-* directories under {canonical_repo}/.ownframework-loop"
        )
    if len(runs) > 1:
        raise RuntimeError(
            f"multiple active runs in {canonical_repo}/.ownframework-loop; "
            f"pass --run-id explicitly: {', '.join(runs)}"
        )
    return runs[0]


def build_skeleton(
    canonical_repo: Path,
    run_id: str,
    *,
    source_root: Path | None = None,
) -> dict[str, Any]:
    """Return a fully-shaped skeleton dict ready to be JSON-dumped.

    The skeleton has every required top-level key present, the verdict set
    to the placeholder string "APPROVED" (uppercase), and the run-scoped
    fields pre-populated. Empty list fields are real `[]` not `null` so
    the finalizer's isinstance(... list) check passes.
    """
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    if not git_checks.is_git_repo(canonical_repo):
        raise RuntimeError(f"canonical repo is not a git repository: {canonical_repo}")
    run_id = _resolve_run_id(canonical_repo, run_id)
    candidate_sha = _resolve_candidate_sha(canonical_repo, run_id)
    packet_sha = _resolve_packet_sha256(canonical_repo, run_id)
    approval_sha = _resolve_approval_sha256(canonical_repo, run_id)
    build_receipt_sha = _resolve_build_receipt_sha256(canonical_repo, run_id)
    reviewer_wt = (
        canonical_repo / ".worktrees" / "ownframework-loop" / run_id / "reviewer"
    )

    src_root = source_root or _find_source_root(Path(__file__).parent)
    if src_root is None:
        raise RuntimeError(
            "could not locate source root for REVIEW_AGENT_ASSESSMENT.template.json; "
            "pass source_root explicitly"
        )
    tpl = json.loads(template_path(src_root).read_text(encoding="utf-8"))

    # Strip the comment keys (anything starting with "_") and the schema
    # marker fields the reviewer should not have to touch.
    clean: dict[str, Any] = {
        k: v for k, v in tpl.items() if not k.startswith("_")
    }

    # Substitute the runtime-known fields.
    clean["schema"] = SCHEMA_AGENT_ASSESSMENT
    clean["run_id"] = run_id
    clean["candidate_sha_claimed"] = candidate_sha
    clean["reviewer_worktree"] = str(reviewer_wt)
    clean["reviewer_head_before"] = candidate_sha
    clean["reviewer_head_after"] = candidate_sha
    clean["packet_sha256_recomputed"] = packet_sha
    clean["approval_sha256"] = approval_sha
    clean["build_receipt_sha256"] = build_receipt_sha
    clean["reviewer_identity"] = "of-reviewer"
    clean["escalation_recommended"] = False
    clean["escalation_reason"] = None
    clean["timestamp"] = util.utc_now_iso()

    # Ensure list fields are lists (never None).
    for lk in ("validation_results", "acceptance_results",
               "non_goal_results", "findings",
               "scope_findings", "protected_findings", "secret_findings"):
        if not isinstance(clean.get(lk), list):
            clean[lk] = []

    return clean


def write_skeleton(
    canonical_repo: Path,
    run_id: str | None,
    *,
    source_root: Path | None = None,
    overwrite: bool = False,
) -> Path:
    """Write the skeleton to the per-run scratch path. Idempotent unless overwrite=True."""
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    target = assessment_path(canonical_repo, run_id or "")
    if target.exists() and not overwrite:
        return target
    skel = build_skeleton(canonical_repo, run_id, source_root=source_root)
    target.parent.mkdir(parents=True, exist_ok=True)
    util.atomic_write_json(target, skel, mode=0o600)
    return target
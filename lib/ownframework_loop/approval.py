"""External APPROVAL.json — separate, deterministic, terminal-bound approval.

The approval artifact is *separate* from the packet bytes it authenticates:

- WORK_PACKET.md is the mission contract; its bytes are immutable after
  approval.
- APPROVAL.json is the human authorization record; it carries the SHA-256
  of the exact packet bytes, plus the canonical repo, baseline branch, and
  baseline SHA that bind the approval to one specific execution context.
- The CLI refuses to construct APPROVAL.json without a genuine terminal
  interaction (a typed confirmation token derived from the packet hash).
- Interactive TTY confirmation is an operator-intent mechanism. It is not,
  by itself, an OS-level identity boundary against arbitrary code running as
  the same user. Hardened agent adapters must separately block agent invocation
  of the approval command while preserving the human-operated terminal path.

The build and review finalizers always re-validate APPROVAL.json against
the current WORK_PACKET.md before any state transition. A single byte
change in the packet file invalidates approval and re-routes the run back
to AWAITING_APPROVAL.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

from . import branch_resolver, git_checks, packet as packet_mod, util


SCHEMA_VERSION = "ownframework-loop-approval/v1"

# Approval artifacts are created only through the interactive TTY confirmation
# path. The TTY check establishes an interactive operator surface; hardened host
# adapters are responsible for preventing an agent tool call from invoking that
# human-only command. There is no non-interactive core override.
# v0.5.0: build_start is the normal auto-seal method;
# tty_confirmation remains for legacy / optional strict pre-seal.
ALLOWED_APPROVAL_METHODS = {"tty_confirmation", "build_start"}

CONFIRMATION_PREFIX = "CONFIRM-OF-LOOP"


def approval_path(canonical_repo: Path, run_id: str) -> Path:
    """Return the canonical path of the approval artifact."""
    return util.run_dir(canonical_repo, run_id) / "APPROVAL.json"


def load_approval(canonical_repo: Path, run_id: str) -> dict[str, Any] | None:
    """Load the approval artifact if present. Returns None on missing."""
    value = util.read_private_json(approval_path(canonical_repo, run_id), default=None)
    return value if isinstance(value, dict) else None


def approval_artifact_sha256(approval: dict[str, Any]) -> str:
    """Deterministic SHA-256 over the artifact's canonical JSON bytes.

    This is the SHA recorded in EVENTS.log so tampering with the artifact
    is detectable on the next read.
    """
    canonical = json.dumps(approval, indent=2, sort_keys=True)
    return util.sha256_text(canonical)


def derive_confirmation_token(packet_sha256: str) -> str:
    """Return the short human-typeable confirmation token for a packet.

    The token is a deterministic short suffix of the packet SHA plus a
    fixed prefix. The operator must type it back exactly to confirm.
    """
    clean = re.sub(r"[^a-f0-9]", "", packet_sha256.lower())
    return f"{CONFIRMATION_PREFIX}-{clean[:8]}"


def _tty_device_path(fd: int) -> str | None:
    """Return the device path of `fd` if it is a TTY, else None.

    Uses os.ttyname() which fails with OSError (ENOTTY) for pipes and
    regular files. The returned path is checked against supported interactive
    terminal device families on macOS/BSD and Linux.
    """
    try:
        return os.ttyname(fd)
    except (OSError, AttributeError):
        return None


def _is_canonical_tty_device(path: str | None) -> bool:
    """Return True iff `path` resolves to a canonical /dev/tty* device.

    Accepts literal /dev/tty, macOS/BSD /dev/ttysN, Linux /dev/ttyN,
    and the standard Linux pseudo-terminal family /dev/pts/N.
    """
    if not path:
        return False
    p = Path(path).resolve(strict=False)
    s = str(p)
    if s == "/dev/tty":
        return True
    # BSD/macOS pattern: /dev/ttysNNN
    if re.fullmatch(r"/dev/ttys\d{1,3}", s):
        return True
    # Linux virtual console pattern: /dev/ttyNN.
    if re.fullmatch(r"/dev/tty\d{1,3}", s):
        return True
    # Linux interactive pseudo-terminal pattern used by SSH, terminal
    # emulators, containers, and GitHub-hosted runner PTY tests.
    if re.fullmatch(r"/dev/pts/\d+", s):
        return True
    return False


def _is_interactive_tty() -> bool:
    """Return True iff stdin and stdout are supported interactive TTY devices.

    This rejects pipes/files and accepts normal macOS/BSD and Linux terminal
    device families. It establishes the interactive approval surface but does
    not claim that an arbitrary same-user process cannot allocate a PTY. Host
    adapter hardening must separately prevent agent invocation of the human-only
    approval command.
    """
    try:
        in_ok = sys.stdin.isatty()
        out_ok = sys.stdout.isatty()
    except (AttributeError, ValueError):
        return False
    if not (in_ok and out_ok):
        return False
    in_dev = _tty_device_path(sys.stdin.fileno())
    out_dev = _tty_device_path(sys.stdout.fileno())
    if in_dev is None or out_dev is None:
        return False
    return _is_canonical_tty_device(in_dev) and _is_canonical_tty_device(out_dev)


def _read_tty_confirmation(prompt: str, expected_token: str, *, max_attempts: int = 3) -> bool:
    """Prompt the operator on a TTY and confirm the typed token.

    Must be called from a real TTY — `_is_interactive_tty()` is enforced
    by the caller. The token is read once and compared byte-for-byte.
    The token length is bounded (`max_attempts`) to avoid runaway prompts.
    """
    if not _is_interactive_tty():
        return False
    for _ in range(max_attempts):
        try:
            sys.stdout.write(prompt)
            sys.stdout.flush()
        except OSError:
            return False
        try:
            typed = sys.stdin.readline()
        except (OSError, ValueError):
            return False
        typed = typed.strip()
        if typed == expected_token:
            return True
        try:
            sys.stdout.write("  token did not match — try again\n")
            sys.stdout.flush()
        except OSError:
            return False
    return False


def validate_approval_shape(approval: dict[str, Any]) -> list[str]:
    """Return a list of human descriptions for schema violations.

    Implemented inline (no jsonschema dependency) so the runtime stays
    stdlib-only.
    """
    errors: list[str] = []
    required = (
        "schema", "run_id", "packet_sha256", "approved_at", "approved_actor",
        "canonical_repo", "baseline_branch", "baseline_sha", "packet_schema",
        "approval_method", "confirmation_token",
    )
    for f in required:
        if f not in approval:
            errors.append(f"missing required field: {f}")
    if approval.get("schema") != SCHEMA_VERSION:
        errors.append(f"schema must be {SCHEMA_VERSION}")
    sha = approval.get("packet_sha256") or ""
    if not re.fullmatch(r"[a-f0-9]{64}", sha):
        errors.append("packet_sha256 must be 64 lowercase hex")
    bsha = approval.get("baseline_sha") or ""
    if not re.fullmatch(r"[a-f0-9]{7,64}", bsha):
        errors.append("baseline_sha must be 7-64 hex")
    am = approval.get("approval_method")
    if am not in ALLOWED_APPROVAL_METHODS:
        errors.append(f"approval_method must be one of {sorted(ALLOWED_APPROVAL_METHODS)}")
    if not approval.get("approved_actor"):
        errors.append("approved_actor must be non-empty")
    if not approval.get("canonical_repo"):
        errors.append("canonical_repo must be non-empty")
    if not approval.get("baseline_branch"):
        errors.append("baseline_branch must be non-empty")
    return errors


def _resolve_baseline_sha(canonical_repo: Path, expected_branch: str) -> str | None:
    """Resolve the exact local baseline branch ref independent of checkout."""
    if not git_checks.is_git_repo(canonical_repo):
        return None
    return git_checks.branch_head(canonical_repo, expected_branch)


def validate_approval_binding(
    *,
    canonical_repo: Path,
    run_id: str,
    approval: dict[str, Any] | None,
    packet: dict[str, Any],
    packet_path: Path,
) -> tuple[bool, str]:
    """Verify that an approval (if present) still binds to current state.

    Returns (ok, message). When ok=True, the run is authorized to proceed.
    When ok=False, the message describes the failure and the caller must
    transition the run back to AWAITING_APPROVAL.

    Checks performed:
      - approval exists and parses
      - approval schema is current
      - approval.run_id matches the active run
      - approval.packet_sha256 equals SHA-256 over current packet bytes
      - approval.canonical_repo resolves to the supplied canonical_repo
      - approval.baseline_branch matches the packet's target.branch
      - approval.baseline_sha equals the current HEAD of the canonical branch
      - approval.confirmation_token matches the deterministic token
    """
    if approval is None:
        return False, "no approval artifact"
    errors = validate_approval_shape(approval)
    if errors:
        return False, "approval shape invalid: " + "; ".join(errors)
    if approval["run_id"] != run_id:
        return False, "approval run_id mismatch"
    expected_packet_sha = util.sha256_text(packet_path.read_text(encoding="utf-8"))
    if approval["packet_sha256"] != expected_packet_sha:
        return False, (
            f"packet SHA drifted: approval={approval['packet_sha256'][:12]} "
            f"current={expected_packet_sha[:12]}"
        )
    expected_repo = str(canonical_repo.resolve(strict=False))
    packet_repo = str(((packet.get("target") or {}).get("repo") or "")).strip()
    if not packet_repo:
        return False, "packet target.repo missing"
    if Path(packet_repo).expanduser().resolve(strict=False) != Path(expected_repo).resolve(strict=False):
        return False, "packet target.repo does not match canonical repo"
    if approval["canonical_repo"].rstrip("/") != expected_repo.rstrip("/"):
        # Allow legacy slashes-only normalization.
        if Path(approval["canonical_repo"]).resolve(strict=False) != Path(expected_repo).resolve(strict=False):
            return False, "approval canonical_repo mismatch"
    expected_branch = (packet.get("target") or {}).get("branch") or ""
    if not expected_branch:
        return False, "packet target.branch missing"
    if approval["baseline_branch"] != expected_branch:
        return False, (
            f"approval baseline_branch={approval['baseline_branch']!r} "
            f"!= packet target.branch={expected_branch!r}"
        )
    current_head = git_checks.branch_head(canonical_repo, expected_branch)
    if current_head is None:
        return False, "baseline branch ref is missing or not resolvable"
    # Audit v0.3.0: full SHA equality (not 7-char prefix match). A 7-char
    # prefix is ambiguous (birthday collision ~1/2^28) and asymmetric
    # (current_head could equal just the prefix substring). Full equality
    # is the only way to bind an approval to a specific historical commit.
    if current_head != approval["baseline_sha"]:
        return False, (
            f"baseline branch ref {current_head} does not match "
            f"approval baseline_sha {approval['baseline_sha']}"
        )
    try:
        expected_candidate_branch = branch_resolver.resolve_candidate_branch(
            canonical_repo, run_id, packet=packet,
        )
    except Exception as exc:
        return False, f"candidate branch could not be derived: {exc}"
    if approval.get("candidate_branch") != expected_candidate_branch:
        return False, (
            f"approval candidate_branch={approval.get('candidate_branch')!r} != "
            f"packet/run-derived candidate_branch={expected_candidate_branch!r}"
        )

    # Verify the confirmation token matches the deterministic token.
    expected_token = derive_confirmation_token(approval["packet_sha256"])
    if approval["confirmation_token"] != expected_token:
        return False, "approval confirmation_token does not match derived token"
    return True, "ok"


def request_human_approval(
    *,
    canonical_repo: Path,
    run_id: str,
    packet_path: Path,
    actor: str | None = None,
    operator_note: str | None = None,
) -> dict[str, Any]:
    """Construct and atomically write APPROVAL.json after TTY confirmation.

    There is no non-interactive core override. The function requires:
      1. A supported interactive TTY on both stdin and stdout.
      2. A typed confirmation token matching the deterministic derivation from
         the packet SHA. Hardened adapters additionally block agent invocation
         of this human-operated command.

    Either check failing raises RuntimeError and writes no file. The
    approval_method recorded is always "tty_confirmation".

    Returns the approval document on success. Raises RuntimeError on refusal.
    """
    if not _is_interactive_tty():
        raise RuntimeError(
            "OF_LOOP_APPROVAL_TTY_REQUIRED: refusing to approve without a "
            "live terminal. Run 'ofloop spec approve <repo> <run-id>' from "
            "an interactive terminal."
        )
    meta, _ = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_for_approval(meta)
    if errors:
        raise RuntimeError("packet invalid: " + "; ".join(errors))
    if not git_checks.is_git_repo(canonical_repo):
        raise RuntimeError("canonical repo is not a git repository")
    target_repo = str(((meta.get("target") or {}).get("repo") or "")).strip()
    if (
        not target_repo
        or Path(target_repo).expanduser().resolve(strict=False)
        != canonical_repo.resolve(strict=False)
    ):
        raise RuntimeError("packet target.repo does not match canonical repository")
    packet_sha = util.sha256_text(packet_path.read_text(encoding="utf-8"))
    target_branch = (meta.get("target") or {}).get("branch")
    if not target_branch:
        raise RuntimeError("packet target.branch missing")
    baseline_sha = git_checks.branch_head(canonical_repo, target_branch)
    if not baseline_sha:
        raise RuntimeError(
            f"packet target branch {target_branch!r} is missing or not resolvable"
        )
    canonical_repo_str = str(canonical_repo.resolve(strict=False))
    # v0.4.3: freeze the candidate branch in APPROVAL.json so every
    # later consumer (program init, build prepare, build finalize,
    # review finalize, receipts) reads the SAME value from a single
    # authoritative source. Priority: packet-declared prefix, else the
    # deterministic default factory/candidate/<run-id>.
    candidate_branch = branch_resolver.resolve_candidate_branch(
        canonical_repo, run_id, packet=meta,
    )
    if not isinstance(candidate_branch, str) or not candidate_branch.strip():
        raise RuntimeError("could not resolve candidate_branch for run {run_id}")

    token = derive_confirmation_token(packet_sha)
    prompt_lines = [
        "",
        "  OwnFramework Loop — packet approval",
        f"  run_id              : {run_id}",
        f"  canonical_repo      : {canonical_repo_str}",
        f"  baseline_branch     : {target_branch}",
        f"  baseline_sha        : {baseline_sha[:12]}",
        f"  packet_sha256       : {packet_sha[:12]}",
        f"  work_class          : {meta.get('work_class')}",
        f"  risk_class          : {meta.get('risk_class')}",
        f"  authority_class     : {meta.get('authority_class')}",
        f"  title               : {meta.get('title')}",
        f"  files_budget        : {((meta.get('risk_budget') or {}) .get('max_files_changed'))}",
        f"  diff_lines_budget   : {((meta.get('risk_budget') or {}) .get('max_diff_lines'))}",
        f"  sensitive_paths     : {meta.get('sensitive_paths') or []}",
        f"  elevated_paths      : {meta.get('elevated_allowed_paths') or []}",
        f"  candidate_branch    : {candidate_branch}",
        "",
        f"  Type this token to approve: {token}",
        "",
    ]
    sys.stdout.write("\n".join(prompt_lines))
    sys.stdout.flush()
    if not _read_tty_confirmation("  token> ", token):
        raise RuntimeError(
            "OF_LOOP_APPROVAL_TOKEN_MISMATCH: typed token did not match "
            "the deterministic confirmation token."
        )

    approval = {
        "schema": SCHEMA_VERSION,
        "run_id": run_id,
        "packet_sha256": packet_sha,
        "approved_at": util.utc_now_iso(),
        "approved_actor": actor,
        "canonical_repo": canonical_repo_str,
        "baseline_branch": target_branch,
        "baseline_sha": baseline_sha,
        "packet_schema": meta.get("schema") or "",
        "approval_method": "tty_confirmation",
        "confirmation_token": token,
        "operator_note": operator_note,
        "packet_work_class": meta.get("work_class"),
        "packet_risk_class": meta.get("risk_class"),
        "packet_title": meta.get("title"),
        "sensitive_paths_in_scope": list(meta.get("sensitive_paths") or []),
        "elevated_paths_in_scope": list(meta.get("elevated_allowed_paths") or []),
        "candidate_branch": candidate_branch,
    }
    util.atomic_write_json(approval_path(canonical_repo, run_id), approval, mode=0o600)
    return approval


def approval_required_methods_match(approval: dict[str, Any]) -> bool:
    """Return True iff the approval's method is one of the allowed set."""
    return approval.get("approval_method") in ALLOWED_APPROVAL_METHODS


def model_can_self_approve() -> bool:
    """Always returns False.

    This is the protocol declaration exposed to tests and docs: adapters
    must not grant model approval authority. The core requires interactive TTY
    confirmation; hardened adapters additionally block agent invocation of the
    approval command.
    """
    return False


def is_legacy_packet_approval(packet: dict[str, Any]) -> bool:
    """Return True iff the packet still carries legacy V1 approval fields.

    V1 packets stored approval fields inside the packet metadata block
    (`human_approved`, `approved_packet_sha256`, etc.). V2 packets must
    not — approval is a separate artifact. Existing V1 runs must be
    re-approved under the V2 model.
    """
    legacy_keys = {"human_approved", "approved_packet_sha256", "approved_at", "approved_actor"}
    return any(k in packet for k in legacy_keys)

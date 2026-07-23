"""Command-line interface for OwnFramework Loop V1.

Thin wrapper around the Python library. Used by skills, agents, hooks, tests,
and installers. Stable, JSON-friendly output.

Usage:

  ofloop spec new <repo> <mission>
  ofloop spec status <repo> <run-id>
  ofloop spec approve <repo> <run-id> [--actor <name>]
  ofloop spec amend <repo> <run-id> <requested change>
  ofloop spec stop <repo> <run-id> [--reason <reason>]
  ofloop spec abandon <repo> <run-id>

  ofloop build claim <repo> <run-id> [--actor <name>]
  ofloop build transition <repo> <run-id> --to <state> [--reason <r>] [--actor <name>]
  ofloop build write-receipt <repo> <run-id> <receipt.json>
  ofloop build marker <repo> <run-id>

  ofloop review write-verdict <repo> <run-id> <verdict.json>
  ofloop review marker <repo> <run-id>

  ofloop doctor <repo> [--run-id <id>]
  ofloop new-repo <root> <project-name> [--init-baseline]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import uuid
from pathlib import Path
from typing import Any

from . import (
    git_checks, guards, packet as packet_mod, receipts, scheduling,
    state as state_mod, transitions, util, verdicts, worktrees,
)


SCHEMA_PACKET = "ownframework-work-packet/v1"
SCHEMA_STATE = "ownframework-loop-state/v1"


# --- helpers ---------------------------------------------------------------

def _emit(payload: dict[str, Any], *, exit_code: int = 0) -> None:
    """Write a structured JSON response to stdout and exit."""
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True, default=str))
    sys.stdout.write("\n")
    sys.stdout.flush()
    if exit_code != 0:
        sys.exit(exit_code)


def _emit_error(message: str, *, exit_code: int = 1, **extras: Any) -> None:
    payload = {"ok": False, "error": message}
    payload.update(extras)
    _emit(payload, exit_code=exit_code)


def _repo_path(arg: str) -> Path:
    p = Path(arg).expanduser().resolve(strict=False)
    if not p.exists() or not p.is_dir():
        _emit_error(f"repository path does not exist: {arg}", exit_code=2)
    return p


def _require_packet(canonical_repo: Path, run_id: str) -> dict[str, Any]:
    path = state_mod.run_dir(canonical_repo, run_id) / "WORK_PACKET.md"
    if not path.exists():
        _emit_error(f"WORK_PACKET.md missing for run {run_id}", exit_code=2)
    meta, _ = packet_mod.parse_packet_file(path)
    errors = packet_mod.validate_packet_metadata(meta)
    if errors:
        _emit_error("packet validation failed", exit_code=2, errors=errors)
    return meta


# --- spec subcommands ------------------------------------------------------

def cmd_spec_new(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    run_id = state_mod.run_dir(repo, f"run-{util.utc_now_compact()}-{uuid.uuid4().hex[:8]}").name
    state_mod.run_dir(repo, run_id).mkdir(parents=True, exist_ok=True)
    initial = state_mod.initial_state(run_id)
    state_mod.save(repo, run_id, initial)
    state_mod.append_event(
        repo, run_id,
        event_type="run_created",
        old_state=None, new_state="AWAITING_APPROVAL",
        actor="spec",
        reason=args.mission[:200] if args.mission else None,
    )
    _emit({
        "ok": True,
        "run_id": run_id,
        "state": "AWAITING_APPROVAL",
        "next_step": f"draft packet at {state_mod.run_dir(repo, run_id) / 'WORK_PACKET.md'}, then run: ofloop spec approve {repo} {run_id}",
    })


def cmd_spec_status(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    s = state_mod.load(repo, args.run_id)
    if s is None:
        _emit_error(f"run not found: {args.run_id}", exit_code=2)
    packet_path = state_mod.run_dir(repo, args.run_id) / "WORK_PACKET.md"
    packet = None
    if packet_path.exists():
        try:
            meta, _ = packet_mod.parse_packet_file(packet_path)
            packet = {
                "title": meta.get("title"),
                "work_class": meta.get("work_class"),
                "risk_class": meta.get("risk_class"),
                "human_approved": meta.get("human_approved", False),
                "packet_sha256": util.sha256_text(packet_path.read_text(encoding="utf-8")),
            }
        except Exception as e:
            packet = {"error": str(e)}
    receipt = receipts.load_receipt(repo, args.run_id)
    verdict = verdicts.load_verdict(repo, args.run_id)
    stop = state_mod.is_stop_requested(repo, args.run_id)
    _emit({
        "ok": True,
        "run_id": args.run_id,
        "state": s.get("state"),
        "transitions_count": s.get("transitions_count"),
        "build_pass_count": s.get("build_pass_count"),
        "review_pass_count": s.get("review_pass_count"),
        "repair_round": s.get("repair_round"),
        "no_progress_streak": s.get("no_progress_streak"),
        "last_actor": s.get("last_actor"),
        "last_candidate_sha": s.get("last_candidate_sha"),
        "stop_requested": stop,
        "packet": packet,
        "has_receipt": receipt is not None,
        "has_verdict": verdict is not None,
        "last_verdict": (verdict.get("verdict") if verdict else None),
    })


def cmd_spec_approve(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    packet_path = state_mod.run_dir(repo, args.run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        _emit_error("WORK_PACKET.md missing", exit_code=2)
    meta, body = packet_mod.parse_packet_file(packet_path)
    errors = packet_mod.validate_packet_metadata(meta)
    if errors:
        _emit_error("packet invalid", exit_code=2, errors=errors)
    packet_sha = util.sha256_text(packet_path.read_text(encoding="utf-8"))
    actor = args.actor or "william"
    updated = packet_mod.apply_approval(meta, packet_sha256=packet_sha, actor=actor)
    packet_mod.write_approved_packet(packet_path, updated, body)
    new_sha = util.sha256_text(packet_path.read_text(encoding="utf-8"))
    state_mod.append_event(
        repo, args.run_id,
        event_type="packet_approved",
        old_state=state_mod.load(repo, args.run_id).get("state"),
        new_state=None,
        actor=actor,
        reason=f"packet_sha256={packet_sha}",
        extras={"approved_packet_sha256": packet_sha, "packet_sha256_after_rewrite": new_sha},
    )
    # Transition AWAITING_APPROVAL -> READY_TO_BUILD
    cur = state_mod.load(repo, args.run_id)
    if cur.get("state") == "AWAITING_APPROVAL":
        state_mod.transition(
            repo, args.run_id,
            to_state="READY_TO_BUILD",
            actor=actor,
            reason=f"packet approved (sha={packet_sha[:12]})",
        )
    _emit({
        "ok": True,
        "run_id": args.run_id,
        "approved": True,
        "packet_sha256": packet_sha,
        "state": "READY_TO_BUILD",
    })


def cmd_spec_amend(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    packet_path = state_mod.run_dir(repo, args.run_id) / "WORK_PACKET.md"
    if not packet_path.exists():
        _emit_error("WORK_PACKET.md missing", exit_code=2)
    state_mod.append_event(
        repo, args.run_id,
        event_type="packet_amend_requested",
        old_state=None, new_state=None,
        actor="human",
        reason=args.change[:500],
    )
    _emit({"ok": True, "run_id": args.run_id, "amend_request_recorded": True})


def cmd_spec_stop(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    state_mod.request_stop(repo, args.run_id, reason=args.reason, actor="human")
    cur = state_mod.load(repo, args.run_id)
    if cur and cur.get("state") not in ("APPROVED", "BLOCKED", "STOPPED"):
        state_mod.transition(
            repo, args.run_id, to_state="STOPPED",
            actor="human", reason=args.reason or "human stop",
        )
    _emit({"ok": True, "run_id": args.run_id, "stopped": True})


def cmd_spec_abandon(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    state_mod.request_stop(repo, args.run_id, reason="abandoned", actor="human")
    cur = state_mod.load(repo, args.run_id)
    if cur and cur.get("state") not in ("STOPPED",):
        state_mod.transition(
            repo, args.run_id, to_state="STOPPED",
            actor="human", reason="abandoned",
        )
    _emit({"ok": True, "run_id": args.run_id, "abandoned": True})


# --- build subcommands -----------------------------------------------------

def cmd_build_claim(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    meta = _require_packet(repo, args.run_id)
    if not packet_mod.is_approved(meta):
        _emit_error("packet is not approved", exit_code=2)
    cur = state_mod.load(repo, args.run_id)
    if cur.get("state") not in ("READY_TO_BUILD",):
        _emit_error(f"cannot claim in state {cur.get('state')!r}", exit_code=2)
    state_mod.transition(
        repo, args.run_id, to_state="BUILDING",
        actor=args.actor or "of-builder",
        reason="claim build pass",
    )
    state_mod.increment_counter(repo, args.run_id, counter="build_pass_count", actor="of-builder")
    state_mod.append_event(
        repo, args.run_id,
        event_type="build_claimed",
        old_state="READY_TO_BUILD", new_state="BUILDING",
        actor=args.actor or "of-builder",
    )
    _emit({"ok": True, "run_id": args.run_id, "state": "BUILDING"})


def cmd_build_transition(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    state_mod.transition(
        repo, args.run_id, to_state=args.to,
        actor=args.actor or "of-builder",
        reason=args.reason or "",
    )
    if args.to == "CHANGES_REQUESTED":
        # Increment repair round on every CHANGES_REQUESTED.
        cur = state_mod.load(repo, args.run_id)
        cur["repair_round"] = int(cur.get("repair_round", 0)) + 1
        cur["no_progress_streak"] = 0
        state_mod.save(repo, args.run_id, cur)
        state_mod.append_event(
            repo, args.run_id, event_type="repair_round_incremented",
            old_state=None, new_state=None,
            actor=args.actor or "of-builder",
            extras={"repair_round": cur["repair_round"]},
        )
    _emit({"ok": True, "run_id": args.run_id, "state": args.to})


def cmd_build_write_receipt(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    receipt = json.loads(Path(args.receipt).read_text(encoding="utf-8"))
    if receipt.get("run_id") != args.run_id:
        _emit_error("receipt run_id mismatch", exit_code=2)
    cur = state_mod.load(repo, args.run_id)
    receipt["builder_worktree"] = str(util.builder_worktree(repo, args.run_id))
    receipts.write_receipt(repo, args.run_id, receipt)
    state_mod.append_event(
        repo, args.run_id, event_type="receipt_written",
        old_state=cur.get("state"), new_state=None,
        actor="of-builder",
        commit_sha=receipt.get("candidate_sha"),
        extras={"files_changed": receipt.get("files_changed"),
                "added_lines": receipt.get("added_lines"),
                "removed_lines": receipt.get("removed_lines")},
    )
    if receipt.get("next_state") and receipt["next_state"] != cur.get("state"):
        state_mod.transition(
            repo, args.run_id, to_state=receipt["next_state"],
            actor="of-builder",
            reason="receipt next_state",
            commit_sha=receipt.get("candidate_sha"),
        )
    _emit({"ok": True, "run_id": args.run_id, "next_state": receipt.get("next_state"),
           "candidate_sha": receipt.get("candidate_sha")})


def cmd_build_marker(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    cur = state_mod.load(repo, args.run_id)
    state = cur.get("state")
    action, delay = scheduling.recommend_next_delay_minutes(role="builder", state=state)
    marker = scheduling.builder_marker(
        run_id=args.run_id,
        state=state,
        action=action,
        next_delay_minutes=delay,
        reason="builder pass complete",
    )
    sys.stdout.write(marker)
    sys.stdout.flush()


# --- review subcommands ----------------------------------------------------

def cmd_review_write_verdict(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    verdict = json.loads(Path(args.verdict).read_text(encoding="utf-8"))
    if verdict.get("run_id") != args.run_id:
        _emit_error("verdict run_id mismatch", exit_code=2)
    receipt = receipts.load_receipt(repo, args.run_id)
    if receipt is None:
        _emit_error("no build receipt to review", exit_code=2)
    if verdict.get("candidate_sha_reviewed") != receipt.get("candidate_sha"):
        # Force STALE_CANDIDATE.
        verdict["verdict"] = "STALE_CANDIDATE"
        verdict["recommended_next_state"] = "READY_FOR_REVIEW"
        verdict["stale_sha_check"] = {
            "sha_match": False,
            "receipt_match": False,
            "packet_hash_match": False,
        }
    cur = state_mod.load(repo, args.run_id)
    if cur.get("state") != "REVIEWING":
        state_mod.transition(
            repo, args.run_id, to_state="REVIEWING",
            actor="of-reviewer", reason="claim review pass",
        )
    state_mod.increment_counter(repo, args.run_id, counter="review_pass_count", actor="of-reviewer")
    verdicts.write_verdict(repo, args.run_id, verdict)
    state_mod.append_event(
        repo, args.run_id, event_type="verdict_written",
        old_state=None, new_state=None,
        actor="of-reviewer",
        commit_sha=verdict.get("candidate_sha_reviewed"),
        extras={"verdict": verdict.get("verdict"),
                "findings_count": len(verdict.get("findings", [])),
                "must_fix": sum(1 for f in verdict.get("findings", []) if f.get("classification") == "must_fix")},
    )
    nxt = verdict.get("recommended_next_state") or "BLOCKED"
    if transitions.is_valid("REVIEWING", nxt):
        state_mod.transition(
            repo, args.run_id, to_state=nxt,
            actor="of-reviewer",
            reason=f"verdict={verdict.get('verdict')}",
            commit_sha=verdict.get("candidate_sha_reviewed"),
        )
        if nxt == "CHANGES_REQUESTED":
            cur = state_mod.load(repo, args.run_id)
            cur["repair_round"] = int(cur.get("repair_round", 0)) + 1
            cur["no_progress_streak"] = 0
            state_mod.save(repo, args.run_id, cur)
    _emit({"ok": True, "run_id": args.run_id, "verdict": verdict.get("verdict"),
           "next_state": nxt})


def cmd_review_marker(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    cur = state_mod.load(repo, args.run_id)
    state = cur.get("state")
    action, delay = scheduling.recommend_next_delay_minutes(role="reviewer", state=state)
    marker = scheduling.reviewer_marker(
        run_id=args.run_id,
        state=state,
        action=action,
        next_delay_minutes=delay,
        reason="reviewer pass complete",
    )
    sys.stdout.write(marker)
    sys.stdout.flush()


# --- doctor / new-repo -----------------------------------------------------

def cmd_doctor(args: argparse.Namespace) -> None:
    repo = _repo_path(args.repo)
    if not git_checks.is_git_repo(repo):
        _emit({"ok": False, "is_git_repo": False})
        return
    info = {
        "ok": True,
        "repo": str(repo),
        "is_git_repo": True,
        "toplevel": str(git_checks.git_toplevel(repo)),
        "current_branch": git_checks.current_branch(repo),
        "current_head": git_checks.current_head(repo),
        "remote_count": git_checks.remote_count(repo),
        "remotes": git_checks.remotes(repo),
        "is_dirty": git_checks.is_dirty(repo),
    }
    if args.run_id:
        run_dir = state_mod.run_dir(repo, args.run_id)
        info["run_dir"] = str(run_dir)
        info["run_dir_exists"] = run_dir.exists()
        if run_dir.exists():
            info["state"] = state_mod.load(repo, args.run_id)
            packet_path = run_dir / "WORK_PACKET.md"
            info["packet_exists"] = packet_path.exists()
            if packet_path.exists():
                info["packet_sha256"] = util.sha256_text(packet_path.read_text(encoding="utf-8"))
            info["has_receipt"] = (run_dir / "BUILD_RECEIPT.json").exists()
            info["has_verdict"] = (run_dir / "REVIEW_VERDICT.json").exists()
            info["stop_requested"] = state_mod.is_stop_requested(repo, args.run_id)
    _emit(info)


def cmd_new_repo(args: argparse.Namespace) -> None:
    root = Path(args.root).expanduser().resolve(strict=False)
    target = root / args.project_name
    if target.exists() and any(target.iterdir()):
        _emit_error(f"target not empty: {target}", exit_code=2)
    target.mkdir(parents=True, exist_ok=True)
    import subprocess
    subprocess.run(["git", "init", "-b", "master", str(target)], check=True)
    rc = git_checks.remote_count(target)
    if rc > 0:
        _emit_error(f"newly created repo has remotes (should be zero)", exit_code=2)
    if args.init_baseline:
        # Make an initial empty commit so worktrees can branch off it.
        subprocess.run(["git", "-C", str(target), "config", "user.email", "william@ownframework.local"], check=False)
        subprocess.run(["git", "-C", str(target), "config", "user.name", "William"], check=False)
        readme = target / "README.md"
        readme.write_text(
            f"# {args.project_name}\n\nMinimal bootstrap baseline created by OwnFramework Loop.\n",
            encoding="utf-8",
        )
        gitignore = target / ".gitignore"
        gitignore.write_text(".ownframework-loop/\n.worktrees/ownframework-loop/\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(target), "add", "README.md", ".gitignore"], check=True)
        subprocess.run(["git", "-C", str(target), "commit", "-m", "loop-v1: minimal bootstrap baseline"], check=True)
    _emit({
        "ok": True,
        "target": str(target),
        "branch": "master",
        "remote_count": git_checks.remote_count(target),
        "baseline_initialized": bool(args.init_baseline),
    })


# --- argument parser -------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ofloop", description="OwnFramework Loop CLI")
    sub = p.add_subparsers(dest="command", required=True)

    # spec
    spec = sub.add_parser("spec", help="spec subcommands")
    spec_sub = spec.add_subparsers(dest="spec_cmd", required=True)
    s_new = spec_sub.add_parser("new", help="create a new run")
    s_new.add_argument("repo")
    s_new.add_argument("mission", nargs="?")
    s_new.set_defaults(func=cmd_spec_new)
    s_status = spec_sub.add_parser("status", help="show run status")
    s_status.add_argument("repo")
    s_status.add_argument("run_id")
    s_status.set_defaults(func=cmd_spec_status)
    s_app = spec_sub.add_parser("approve", help="approve the work packet")
    s_app.add_argument("repo")
    s_app.add_argument("run_id")
    s_app.add_argument("--actor", default="william")
    s_app.set_defaults(func=cmd_spec_approve)
    s_amd = spec_sub.add_parser("amend", help="amend an existing packet")
    s_amd.add_argument("repo")
    s_amd.add_argument("run_id")
    s_amd.add_argument("change")
    s_amd.set_defaults(func=cmd_spec_amend)
    s_stop = spec_sub.add_parser("stop", help="stop a run")
    s_stop.add_argument("repo")
    s_stop.add_argument("run_id")
    s_stop.add_argument("--reason", default="")
    s_stop.set_defaults(func=cmd_spec_stop)
    s_aban = spec_sub.add_parser("abandon", help="abandon a run")
    s_aban.add_argument("repo")
    s_aban.add_argument("run_id")
    s_aban.set_defaults(func=cmd_spec_abandon)

    # build
    bld = sub.add_parser("build", help="build subcommands")
    bld_sub = bld.add_subparsers(dest="build_cmd", required=True)
    b_claim = bld_sub.add_parser("claim", help="claim a build pass")
    b_claim.add_argument("repo")
    b_claim.add_argument("run_id")
    b_claim.add_argument("--actor", default="of-builder")
    b_claim.set_defaults(func=cmd_build_claim)
    b_trans = bld_sub.add_parser("transition", help="transition state")
    b_trans.add_argument("repo")
    b_trans.add_argument("run_id")
    b_trans.add_argument("--to", required=True)
    b_trans.add_argument("--reason", default="")
    b_trans.add_argument("--actor", default="of-builder")
    b_trans.set_defaults(func=cmd_build_transition)
    b_rec = bld_sub.add_parser("write-receipt", help="write a build receipt")
    b_rec.add_argument("repo")
    b_rec.add_argument("run_id")
    b_rec.add_argument("receipt")
    b_rec.set_defaults(func=cmd_build_write_receipt)
    b_mk = bld_sub.add_parser("marker", help="emit builder marker")
    b_mk.add_argument("repo")
    b_mk.add_argument("run_id")
    b_mk.set_defaults(func=cmd_build_marker)

    # review
    rev = sub.add_parser("review", help="review subcommands")
    rev_sub = rev.add_subparsers(dest="review_cmd", required=True)
    r_wv = rev_sub.add_parser("write-verdict", help="write a review verdict")
    r_wv.add_argument("repo")
    r_wv.add_argument("run_id")
    r_wv.add_argument("verdict")
    r_wv.set_defaults(func=cmd_review_write_verdict)
    r_mk = rev_sub.add_parser("marker", help="emit reviewer marker")
    r_mk.add_argument("repo")
    r_mk.add_argument("run_id")
    r_mk.set_defaults(func=cmd_review_marker)

    # doctor
    doc = sub.add_parser("doctor", help="inspect repo + run")
    doc.add_argument("repo")
    doc.add_argument("--run-id", default=None)
    doc.set_defaults(func=cmd_doctor)

    # new-repo
    nr = sub.add_parser("new-repo", help="initialize a local-only repo")
    nr.add_argument("root")
    nr.add_argument("project_name")
    nr.add_argument("--init-baseline", action="store_true")
    nr.set_defaults(func=cmd_new_repo)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except transitions.InvalidTransitionError as e:
        _emit_error(f"invalid transition: {e}", exit_code=3)
    except FileNotFoundError as e:
        _emit_error(f"file not found: {e}", exit_code=2)
    except Exception as e:
        _emit_error(str(e), exit_code=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())

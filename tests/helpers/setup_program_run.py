#!/usr/bin/env python3
"""Create a deterministic PROGRAM-mode run for integration tests.

Usage:
  setup_program_run.py REPO RUN_ID CP_COUNT CUM_BUILD CUM_REVIEW CUM_REPAIR CP_BUILD CP_REVIEW CP_REPAIR

The helper intentionally allows cumulative ceilings lower than the sum of per-checkpoint
ceilings so claim-accounting tests can prove both boundaries independently.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

from ownframework_loop import approval, program, state as state_mod


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def main(argv: list[str]) -> int:
    if len(argv) != 9:
        raise SystemExit(
            "usage: setup_program_run.py REPO RUN_ID CP_COUNT CUM_BUILD CUM_REVIEW "
            "CUM_REPAIR CP_BUILD CP_REVIEW CP_REPAIR"
        )

    repo = Path(argv[0]).resolve()
    run_id = argv[1]
    cp_count, cum_build, cum_review, cum_repair, cp_build, cp_review, cp_repair = map(int, argv[2:])
    if cp_count < 1:
        raise SystemExit("CP_COUNT must be >= 1")

    branch = git(repo, "branch", "--show-current") or "main"
    baseline = git(repo, "rev-parse", "HEAD")
    run_dir = repo / ".ownframework-loop" / run_id
    run_dir.mkdir(parents=True, exist_ok=False)

    checkpoints = []
    execution_order = []
    for index in range(1, cp_count + 1):
        cp_id = f"CP-{index}"
        execution_order.append(cp_id)
        checkpoints.append(
            {
                "id": cp_id,
                "title": f"checkpoint {index}",
                "scope": f"test checkpoint {index}",
                "depends_on": [] if index == 1 else [f"CP-{index - 1}"],
                "risk_budget": {
                    "max_build_passes": cp_build,
                    "max_review_passes": cp_review,
                    "max_repair_rounds": cp_repair,
                },
            }
        )

    packet = {
        "schema": "ownframework-work-packet/v3",
        "packet_id": f"packet-{run_id}",
        "created_at": "2026-07-31T00:00:00Z",
        "work_class": "FEATURE",
        "risk_class": "low",
        "title": "program claim fixture",
        "target": {"repo": str(repo), "branch": branch, "classification": "local_only"},
        "execution_mode": "program",
        "checkpoint_graph": {
            "execution_order": execution_order,
            "checkpoints": checkpoints,
        },
        "promotion_policy": "human_gate",
        "acceptance_criteria": [{"id": "AC-1", "text": "fixture remains valid"}],
        "non_goals": [],
        "allowed_paths": ["src/"],
        "protected_paths": [".ownframework-loop/"],
        "work_units": [{"id": "UNIT-1", "title": "fixture", "scope": "fixture"}],
        "merge_authority": "human_only",
        "deploy_authority": "human_only",
        "push_authority": "human_only",
        "external_action_authority": "none",
        "risk_budget": {
            "max_files_changed": 100,
            "max_diff_lines": 5000,
            "max_repair_rounds": max(cum_repair, cp_repair),
        },
    }

    packet_path = run_dir / "WORK_PACKET.md"
    packet_path.write_text("```json\n" + json.dumps(packet, indent=2) + "\n```\nprogram claim fixture\n")

    state_mod.save(repo, run_id, state_mod.initial_state(run_id))

    packet_sha = hashlib.sha256(packet_path.read_bytes()).hexdigest()
    approval_doc = {
        "schema": "ownframework-loop-approval/v1",
        "run_id": run_id,
        "packet_sha256": packet_sha,
        "approved_at": "2026-07-31T00:00:00Z",
        "approved_actor": "test",
        "canonical_repo": str(repo.resolve(strict=False)),
        "baseline_branch": branch,
        "baseline_sha": baseline,
        "packet_schema": "ownframework-work-packet/v3",
        "approval_method": "tty_confirmation",
        "confirmation_token": approval.derive_confirmation_token(packet_sha),
    }
    (run_dir / "APPROVAL.json").write_text(json.dumps(approval_doc, indent=2, sort_keys=True))
    state_mod.transition(repo, run_id, to_state="READY_TO_BUILD", actor="test", reason="approved fixture")

    current = state_mod.load(repo, run_id)
    current["schema"] = state_mod.PROGRAM_STATE_SCHEMA_VERSION
    current["program"] = program.materialise_initial_program_state(
        packet,
        baseline_sha=baseline,
        candidate_branch=f"factory/candidate/{run_id}",
    )
    current["program"]["cumulative_ceilings"].update(
        {
            "max_build_passes": cum_build,
            "max_review_passes": cum_review,
            "max_repair_rounds": cum_repair,
        }
    )
    # save() is creation-only; fixture materialization of the PROGRAM object
    # on an existing run uses the TEST-ONLY crash-state seed seam, which
    # commits through the same flock + STATE_TXN machinery as real owners.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from state_seed import seed_state

    seed_state(repo, run_id, current, reason="fixture PROGRAM materialization")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

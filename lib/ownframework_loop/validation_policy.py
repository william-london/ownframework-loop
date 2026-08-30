"""Authority policy for deterministic packet-declared validation commands.

Validation executes outside Claude hook dispatch, so it must enforce both the
structural Bash guard and the external-action authority contract itself.
"""
from __future__ import annotations

from typing import Any

from . import external_action, guards


def classify_required_validation(command: str, *, run_id: str) -> dict[str, Any]:
    cmd = str(command or "").strip()
    if not cmd:
        return {
            "allowed": False,
            "reason": "empty required_validation command",
            "structural": None,
            "external_decision": "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN",
        }

    structural = guards.classify_bash_command(cmd)
    if structural.get("severity") == "forbidden":
        return {
            "allowed": False,
            "reason": "; ".join(structural.get("forbidden") or ["forbidden command"]),
            "structural": structural,
            "external_decision": None,
        }

    external = external_action.classify_tool_call(
        tool_name="Bash",
        tool_input={"command": cmd},
        active_run=run_id,
    )
    if external.startswith("BLOCK:"):
        lines = external.splitlines()
        return {
            "allowed": False,
            "reason": lines[1] if len(lines) > 1 else lines[0],
            "structural": structural,
            "external_decision": external,
        }

    return {
        "allowed": True,
        "reason": "",
        "structural": structural,
        "external_decision": external,
    }


__all__ = ["classify_required_validation"]

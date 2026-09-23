"""Authority policy for deterministic packet-declared validation commands.

Validation executes outside Claude hook dispatch, so it must enforce both the
structural Bash guard and the external-action authority contract itself.
"""
from __future__ import annotations

import re
from typing import Any

from . import external_action, guards


# Required validation is intentionally a foreground contract. The executor
# bounds each admitted command in a fresh process group, but a command that
# creates a new session/service can escape that lifecycle boundary entirely.
# Refuse the common shell-level detachment primitives instead of recording a
# validation as finished while an independently scheduled effect may continue.
_DETACH_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"(?:^|[;&|\n])\s*(?:\S*/)?setsid(?:\s|$)"),
     "setsid is prohibited in required_validation"),
    (re.compile(r"(?:^|[;&|\n])\s*(?:\S*/)?nohup(?:\s|$)"),
     "nohup is prohibited in required_validation"),
    (re.compile(r"(?:^|[;&|\n])\s*(?:\S*/)?daemonize(?:\s|$)"),
     "daemonize is prohibited in required_validation"),
    (re.compile(r"(?:^|[;&|\n])\s*disown(?:\s|$)"),
     "disown is prohibited in required_validation"),
    (re.compile(r"(?:^|[;&|\n])\s*(?:\S*/)?systemd-run(?:\s|$)"),
     "systemd-run is prohibited in required_validation"),
    (re.compile(r"\blaunchctl\s+(?:bootstrap|kickstart|start|submit)\b"),
     "launchctl service creation/start is prohibited in required_validation"),
)


def classify_required_validation(command: str, *, run_id: str) -> dict[str, Any]:
    cmd = str(command or "").strip()
    if not cmd:
        return {
            "allowed": False,
            "reason": "empty required_validation command",
            "structural": None,
            "external_decision": "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN",
        }

    for pattern, reason in _DETACH_PATTERNS:
        if pattern.search(cmd):
            return {
                "allowed": False,
                "reason": reason,
                "structural": None,
                "external_decision": "BLOCK:OF_LOOP_VALIDATION_DETACH",
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

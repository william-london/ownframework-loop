"""Agent adapter registry for OwnFramework Loop.

Adapters describe host integration capabilities. They do not own protocol state or transitions.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class AdapterCapabilities:
    adapter_id: str
    display_name: str
    maturity: str
    agent_family: str
    skills_supported: bool
    interactive_spec: bool
    builder_supported: bool
    reviewer_supported: bool
    native_hooks: bool
    native_subagents: bool
    session_looping: bool
    hard_command_interception: bool
    installation_mode: str
    protocol_compatible: bool
    hardened: bool
    live_verified: bool

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


_ADAPTERS = (
    AdapterCapabilities(
        adapter_id="claude-code",
        display_name="Claude Code",
        maturity="stable",
        agent_family="anthropic-claude-code",
        skills_supported=True,
        interactive_spec=True,
        builder_supported=True,
        reviewer_supported=True,
        native_hooks=True,
        native_subagents=True,
        session_looping=True,
        hard_command_interception=True,
        installation_mode="claude-plugin",
        protocol_compatible=True,
        hardened=True,
        live_verified=True,
    ),
    AdapterCapabilities(
        adapter_id="codex",
        display_name="Codex",
        maturity="experimental",
        agent_family="openai-codex",
        skills_supported=True,
        interactive_spec=True,
        builder_supported=True,
        reviewer_supported=True,
        native_hooks=False,
        native_subagents=False,
        session_looping=False,
        hard_command_interception=False,
        installation_mode="agent-skills",
        protocol_compatible=True,
        hardened=False,
        live_verified=False,
    ),
)


def list_adapters() -> tuple[AdapterCapabilities, ...]:
    return _ADAPTERS


def get_adapter(adapter_id: str) -> AdapterCapabilities:
    for adapter in _ADAPTERS:
        if adapter.adapter_id == adapter_id:
            return adapter
    raise KeyError(adapter_id)


def adapter_skill_paths(repo_root: Path, adapter_id: str) -> tuple[Path, ...]:
    if adapter_id == "claude-code":
        return tuple(repo_root / "skills" / name / "SKILL.md" for name in ("spec", "build", "review"))
    if adapter_id == "codex":
        return tuple(repo_root / ".agents" / "skills" / name / "SKILL.md" for name in ("of-loop-spec", "of-loop-build", "of-loop-review", "of-loop-status"))
    raise KeyError(adapter_id)


def doctor_adapter(repo_root: Path, adapter_id: str) -> list[str]:
    adapter = get_adapter(adapter_id)
    failures: list[str] = []
    for path in adapter_skill_paths(repo_root, adapter_id):
        if not path.is_file():
            failures.append(f"missing skill: {path.relative_to(repo_root)}")
    if adapter_id == "claude-code":
        for rel in (".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json"):
            if not (repo_root / rel).is_file():
                failures.append(f"missing Claude adapter file: {rel}")
    if adapter_id == "codex" and not (repo_root / "AGENTS.md").is_file():
        failures.append("missing repository AGENTS.md")
    if not adapter.protocol_compatible:
        failures.append("adapter is not protocol compatible")
    return failures

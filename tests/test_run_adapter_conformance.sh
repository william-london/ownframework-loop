#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
from pathlib import Path
from ownframework_loop.adapters import doctor_adapter, get_adapter, list_adapters

root = Path.cwd()
adapters = {a.adapter_id: a for a in list_adapters()}
assert set(adapters) == {"claude-code", "generic-cli", "codex"}

assert adapters["claude-code"].maturity == "stable"
assert adapters["claude-code"].protocol_compatible is True
assert adapters["claude-code"].hardened is True
assert adapters["claude-code"].live_verified is True
assert adapters["claude-code"].supervisor_runner_supported is True

assert adapters["generic-cli"].maturity == "portable"
assert adapters["generic-cli"].agent_family == "vendor-neutral"
assert adapters["generic-cli"].protocol_compatible is True
assert adapters["generic-cli"].hardened is False
assert adapters["generic-cli"].live_verified is False
assert adapters["generic-cli"].supervisor_runner_supported is False
assert adapters["generic-cli"].native_hooks is False
assert adapters["generic-cli"].native_subagents is False
assert adapters["generic-cli"].session_looping is False

assert adapters["codex"].maturity == "experimental"
assert adapters["codex"].protocol_compatible is True
assert adapters["codex"].hardened is False
assert adapters["codex"].live_verified is False
assert adapters["codex"].supervisor_runner_supported is False

for adapter_id in ("claude-code", "generic-cli", "codex"):
    failures = doctor_adapter(root, adapter_id)
    assert failures == [], (adapter_id, failures)

# Adapter metadata ↔ durable supervisor registry drift-proof: every adapter
# claiming `supervisor_runner_supported` MUST correspond to a runner actually
# registered with the durable supervisor, and every registered durable
# supervisor runner MUST have adapter metadata declaring that support. These
# two authorities cannot silently drift apart.
from ownframework_loop import supervisor as _sup
registered = set(_sup.registered_runner_ids())
claimed = {a.adapter_id for a in adapters.values() if a.supervisor_runner_supported}
assert registered == claimed, (
    f"runner-registry vs adapter-metadata drift: "
    f"registered={sorted(registered)} claimed={sorted(claimed)}"
)

from ownframework_loop import guards
for command in (
    "ofloop spec approve /tmp/repo run-1",
    "./bin/ofloop spec approve /tmp/repo run-1",
    "python3 bin/ofloop spec approve /tmp/repo run-1",
    "python3 -m ownframework_loop.cli spec approve /tmp/repo run-1",
):
    result = guards.classify_bash_command(command)
    assert result["severity"] == "forbidden", (command, result)

# B-SPEC-VALIDATION-SCOPE (pre-v1 final deterministic closure): validation
# chronology for arbitrary shell commands is semantic and therefore belongs at
# the SPEC-authoring boundary, not in a fake deterministic shell-semantic
# analyzer. Pin both shipped SPEC adapters to the same fail-before-enqueue
# contract so future adapter drift cannot silently re-admit the Taskbox class:
# a top-level validation is global from CP-1, and a known later-only gate must
# remain checkpoint-local. The heading assertion keeps this rule inside the
# complete PROGRAM readiness/pre-enqueue checklist rather than as detached
# documentation.
spec_contracts = (
    root / "skills/spec/SKILL.md",
    root / ".agents/skills/of-loop-spec/SKILL.md",
)
for spec_path in spec_contracts:
    text = spec_path.read_text(encoding="utf-8")
    normalized_text = " ".join(text.split())
    required = (
        "Before a v3 or v4 PROGRAM is considered ready:",
        "top-level `required_validation` is a global gate",
        "MUST be satisfiable from the first checkpoint onward",
        "belongs in that checkpoint's",
        "never place a known later-only gate in the top-level list",
        "src/` package layout must not use a plain",
        "deterministic packet preflight must reject an obvious contradiction",
        "do not narrow ordinary repository write authority merely",
        "including packaging, tests, configuration, documentation, and build metadata when relevant",
        "artificial path minimization that prevents legitimate engineering is itself a packet defect.",
        "For a normal PROGRAM using a high-effort profile, use at least 3600 seconds by",
        "Do not use a short wall-clock ceiling as a proxy for controlling spend",
        "leaving cost and tokens honestly unknown",
        "Cost controls are a separate authority and remain off unless explicitly requested",
    )
    missing = [fragment for fragment in required if " ".join(fragment.split()) not in normalized_text]
    assert not missing, (
        f"{spec_path}: PROGRAM validation-scope contract drift: missing={missing}"
    )

# v1.1.2 SPEC doctrine parity (post-HVAC audit). The two shipped SPEC adapters
# (the Claude adapter and the portable host-neutral mirror) had drifted on
# normative capability-inference and PROGRAM-lifetime authority: the portable
# copy had dropped the local-service/container inference rule, the
# "rendered or generated artifacts" and "generated documents / reports" rules,
# the explicit prohibition on automatically adding a browser/Docker capability,
# the fail-honestly-before-launch rule, and the whole-lifetime sizing rule.
# Two divergent copies of one contract is a latent correctness hazard: an
# operator on a non-Claude host was authoring packets from weaker doctrine.
#
# `skills/spec/SKILL.md` is the CANONICAL SPEC doctrine owner (see
# docs/architecture/AGENT_SKILLS.md). The portable mirror
# `.agents/skills/of-loop-spec/SKILL.md` may differ ONLY in host-integration
# wording (which runner is named, which foreground debug commands exist).
# These fragments are deliberately chosen from the shared normative core, so
# host wording stays free to differ while doctrine cannot drift apart.
spec_capability_doctrine = (
    root / "skills/spec/SKILL.md",
    root / ".agents/skills/of-loop-spec/SKILL.md",
)
for spec_path in spec_capability_doctrine:
    normalized_text = " ".join(spec_path.read_text(encoding="utf-8").split())
    required_capability = (
        # PROGRAM lifetime authority
        "Whole-program lifetime includes the final whole-product review",
        "The capability envelope must be sized for the complete lifecycle",
        "reason about what the final reviewer will materially need to prove",
        # per-deliverable inference rules
        "CLI / package / library work",
        "rendered or generated artifacts",
        "generated documents / reports",
        "local-service topology",
        "a company or product's current public presence",
        "`browser.playwright.chromium`",
        "`local.http-service`",
        # the prohibition that keeps product-type rules out of the core
        "Do NOT automatically add a browser",
        "it must not encode product-type rules into deterministic Python",
        # irreversible-binding consequences
        "the SPEC adapter must fail honestly before launch",
        "sized across the whole PROGRAM lifetime (every checkpoint + `PROGRAM_FINAL`)",
    )
    missing_capability = [
        fragment for fragment in required_capability
        if " ".join(fragment.split()) not in normalized_text
    ]
    assert not missing_capability, (
        f"{spec_path}: SPEC capability-inference doctrine drift: "
        f"missing={missing_capability}"
    )
print("SPEC_DOCTRINE_PARITY=PASS")

# v1.1.2 reviewer/builder network-authority documentation accuracy (post-HVAC
# audit). Both shipped role contracts asserted `allowedDomains: []` as an
# unconditional property of the worker sandbox. That is wrong whenever the
# packet freezes a `network_read_allowlist` or a resolved capability
# contributes narrow domains (package registries, browser provisioning
# hosts): the effective set is their union, computed in
# supervisor_runner._semantic_worker_settings. The architecture ADR
# (docs/architecture/RESEARCH_AUTHORITY.md) already stated the union rule
# correctly; the role contracts were the outliers, and they understate the
# reviewer's own authority.
#
# Pin the corrected invariant to the SOURCE, so the prose cannot drift from
# the code again: strictAllowlist is hardcoded true, and the effective set is
# the union of the packet list with resolved capability domains. The role
# contracts must state that rule and must not re-assert the empty-allowlist
# claim as unconditional. research.public must still be described as
# contributing no Bash network authority (capabilities.py declares an empty
# domain set for it).
runner_src = (root / "lib" / "ownframework_loop" / "supervisor_runner.py").read_text()
assert '"strictAllowlist": True' in runner_src, \
    "supervisor_runner no longer hardcodes strictAllowlist=True; role docs must be revisited"
assert "set(network_read_allowlist or [])" in runner_src and \
    "capability_resolution.get(\"network_domains\")" in runner_src, \
    "effective allowlist is no longer the documented packet/capability union"
cap_src = (root / "lib" / "ownframework_loop" / "capabilities.py").read_text()
assert '"research.public", "read-only-network"' in cap_src, \
    "research.public capability definition moved; role docs must be revisited"

for role_path in (root / "agents" / "of-reviewer.md", root / "agents" / "of-builder.md"):
    role_text = " ".join(role_path.read_text(encoding="utf-8").split())
    assert "`allowedDomains: []`" not in role_text, (
        f"{role_path}: re-asserted the unconditional empty-allowlist claim; "
        "the effective set is the packet/capability union"
    )
    assert "network_read_allowlist" in role_text, \
        f"{role_path}: must name the packet network_read_allowlist as an allowlist source"
    assert "strictAllowlist" in role_text, \
        f"{role_path}: must keep stating that strictAllowlist always holds"
    assert "no Bash network authority" in role_text, \
        f"{role_path}: must state that research.public adds no Bash network authority"
print("ROLE_NETWORK_AUTHORITY_DOC=PASS")
PY

if grep -RInE '^\s*(from|import)\s+(anthropic|claude|openai|codex)(\.|\s|$)' lib/ownframework_loop --include='*.py'; then
  echo 'ADAPTER_CONFORMANCE=FAIL: vendor import found in deterministic core' >&2
  exit 1
fi

for skill in skills/spec/SKILL.md skills/build/SKILL.md skills/review/SKILL.md; do
  test -f "$skill"
done
for skill in .agents/skills/of-loop-{spec,build,review,status}/SKILL.md; do
  test -f "$skill"
done

test -f adapters/generic-cli/README.md
test -f docs/architecture/PORTABILITY_MODEL.md

printf 'ADAPTER_CONFORMANCE=PASS\n'
printf 'CLAUDE_ADAPTER=stable\n'
printf 'GENERIC_CLI_ADAPTER=portable\n'
printf 'GENERIC_CLI_PROTOCOL_COMPATIBLE=yes\n'
printf 'CODEX_ADAPTER=experimental_static_contract\n'
printf 'CODEX_LIVE_VERIFIED=no\n'

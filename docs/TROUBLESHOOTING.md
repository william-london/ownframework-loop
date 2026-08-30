# Troubleshooting

Troubleshoot the layer that actually owns the failure: core, durable service,
or optional host adapter.

## Core is not installed

```bash
command -v ofloop
bash install.sh
bash validate.sh --installed
```

Bare `validate.sh --installed` resolves the managed vendor-neutral core from
the active `ofloop` launcher. It does not query an agent/plugin registry.

## Claude adapter is missing

The Claude adapter is optional:

```bash
bash install-adapter.sh claude-code
claude plugin list
```

Reload/restart Claude if its plugin inventory has not refreshed.

Do not use a Claude plugin cache path as the OwnFramework Loop core runtime.

## Codex skills are missing

```bash
bash install-adapter.sh codex
```

Codex remains experimental until live lifecycle evidence upgrades that adapter.

## Durable supervisor is not running

Commission:

```bash
bash install-supervisor.sh
```

Inspect:

```bash
ofloop supervisor status <repo> <run-id>
```

macOS uses launchd. Linux uses systemd-user.

## Linux commissioning refuses sandbox prerequisites

The current Claude runner needs Claude Code 2.1.248+, `bubblewrap`, and
`socat`.

If bubblewrap exists but cannot run, inspect Linux unprivileged user-namespace
policy. Ubuntu 24.04+ may require the AppArmor profile documented by Claude
Code for `bwrap`.

Do not bypass the sandbox to make unattended execution start.

## Claude version is refused

```bash
claude --version
```

The commissioned minimum is 2.1.248. This is a lower bound, not an exact pin;
newer compatible releases are valid.

## Runtime refresh is refused

A normal core reinstall refuses when unfinished supervisor jobs depend on
another runtime generation or live semantic work exists.

Inspect:

```bash
ofloop supervisor status <repo> <run-id>
```

Do not turn migration/active-work overrides into routine upgrade flags.
Finish/retire the enrollment through supported lifecycle semantics.

## Packet validation fails

Use the installed core:

```bash
python3 -B - <<'PY'
from pathlib import Path
from ownframework_loop import packet
meta, _ = packet.parse_packet_file(Path("WORK_PACKET.md"))
print(packet.validate_packet_metadata(meta))
PY
```

When invoking Python directly, ensure the installed core `lib` is on
`PYTHONPATH`; normally use the `ofloop` CLI instead.

Never repair validation by editing STATE.json directly.

## A dependency download is denied

Outbound semantic Bash is limited to the frozen packet
`network_read_allowlist`.

If a required exact host was omitted, that is a SPEC/bootstrap defect. Stop the
run and mint a corrected packet rather than asking for a runtime permission
exception or routing around the sandbox.

## Reviewer cannot resolve the candidate SHA

```bash
git -C <repo> cat-file -e <candidate_sha>
```

The deterministic review preparation must pin the exact candidate from the
authoritative build receipt. Missing/drifted identity is not reviewer
discretion.

## Dirty baseline

```bash
git -C <repo> status --porcelain
```

Unattributed canonical checkout changes are not silently reset/stashed/cleaned
by Loop.

## Wrong repository/classification

```bash
ofloop doctor <repo>
```

Repository classification is bound at SPEC time. A local-only packet cannot
silently become a remote-backed project after minting.

## State/event integrity refusal

Do not edit STATE.json, EVENTS.log, or STATE_TXN.json manually.

The core automatically completes only a proven write-ahead transaction. Any
unexplained mismatch remains a tampering/integrity refusal.

## Claude hook blocks a benign foreground command

Hooks are Claude-adapter defense in depth. Confirm the foreground session is
using the intended run/repo context and reproduce through the deterministic
core where possible.

The commissioned supervisor also has a native OS sandbox; do not weaken the
sandbox because a hook is inconvenient.

## Release gate failure

`release_gate.sh` and the canonical suite cover core, platform, security, and
adapter contracts. Read the exact failing test. Distinguish a stale test from a
product defect; never weaken authority merely to make CI green.

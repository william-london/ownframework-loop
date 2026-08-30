#!/usr/bin/env bash
# v0.8.4 night-shift hardening regression:
# - RETIRED enrollments are non-runtime-dependent across managed install/uninstall.
# - unattended Claude workers use an actual tool availability allowlist.
# - Bash runs under a fail-closed OS sandbox with strict network allowlist.
# - target project/local settings cannot widen the worker sandbox.
# - authority-bearing extra args are refused.
# - too-old Claude Code fails readiness before any semantic attempt.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

grep -Fq "status NOT IN ('DONE','RETIRED')" "$ROOT_DIR/install.sh" \
  || fail "managed install must exclude RETIRED from runtime dependencies"
grep -Fq "status NOT IN ('DONE','RETIRED')" "$ROOT_DIR/uninstall.sh" \
  || fail "managed uninstall must exclude RETIRED from runtime dependencies"
pass "managed install/uninstall agree that DONE + RETIRED are non-runtime-dependent"

TMP="$(mktemp -d -t ofloop_v084_worker.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

python3 -B - "$TMP" <<'PY'
import json
import os
import pathlib
import stat
import sys

from ownframework_loop import runtime_env, supervisor

root = pathlib.Path(sys.argv[1])
repo = root / "repo"
worktree = repo / ".worktrees" / "ownframework-loop" / "run-secure" / "builder"
semantic = repo / ".ownframework-loop" / "run-secure" / "scratch" / "builder" / "pass-0001" / "BUILD_AGENT_RESULT.json"
worktree.mkdir(parents=True)
semantic.parent.mkdir(parents=True)
semantic.write_text("{}", encoding="utf-8")

captured = {}
class FakePopen:
    def __init__(self, cmd, **kw):
        captured["cmd"] = list(cmd)
        captured["env"] = dict(kw.get("env") or {})
        raise SystemExit(0)

real_popen = supervisor.subprocess.Popen
supervisor.subprocess.Popen = FakePopen
os.environ["OFLOOP_CLAUDE_BIN"] = "/bin/sh"
try:
    order = {
        "schema": supervisor.dispatch_mod.SCHEMA,
        "decision": "BUILD",
        "role": "builder",
        "run_id": "run-secure",
        "state": "BUILDING",
        "canonical_repo": str(repo),
        "worktree": str(worktree),
        "semantic_path": str(semantic),
    }
    try:
        supervisor.ClaudeCodeRunner().run(order, timeout_seconds=1)
    except SystemExit:
        pass
finally:
    supervisor.subprocess.Popen = real_popen
    os.environ.pop("OFLOOP_CLAUDE_BIN", None)

cmd = captured["cmd"]
assert "--tools" in cmd, cmd
assert "--allowedTools" in cmd, cmd
assert cmd[cmd.index("--tools") + 1] == supervisor.DEFAULT_CLAUDE_ALLOWED_TOOLS
assert cmd[cmd.index("--allowedTools") + 1] == supervisor.DEFAULT_CLAUDE_ALLOWED_TOOLS
assert "--setting-sources" in cmd, cmd
assert cmd[cmd.index("--setting-sources") + 1] == "user", cmd
settings = json.loads(cmd[cmd.index("--settings") + 1])
sb = settings["sandbox"]
assert sb["enabled"] is True
assert sb["failIfUnavailable"] is True
assert sb["allowUnsandboxedCommands"] is False
assert sb["excludedCommands"] == []
assert sb["network"]["strictAllowlist"] is True
assert sb["network"]["allowedDomains"] == []
allow = set(sb["filesystem"]["allowWrite"])
assert str(semantic.parent.resolve()) in allow, allow
expected_cache = str(
    runtime_env.runtime_cache_path(repo, "run-secure", "builder").resolve()
)
assert expected_cache in allow, allow

# Reviewer sandbox also makes exact-SHA worktree read-only to Bash.
review_wt = repo / ".worktrees" / "ownframework-loop" / "run-secure" / "reviewer"
review_sem = repo / ".ownframework-loop" / "run-secure" / "scratch" / "reviewer" / "pass-0001" / "REVIEW_ASSESSMENT.json"
review_wt.mkdir(parents=True)
review_sem.parent.mkdir(parents=True)
review_settings = supervisor._semantic_worker_settings(
    canonical_repo=repo,
    run_id="run-secure",
    role="reviewer",
    worktree=review_wt,
    semantic_path=review_sem,
)
assert review_settings["sandbox"]["filesystem"]["denyWrite"] == [str(review_wt.resolve())]

# Operator convenience args may not override any authority-bearing worker flag.
os.environ["OFLOOP_CLAUDE_EXTRA_ARGS"] = "--settings '{}'"
try:
    try:
        supervisor.ClaudeCodeRunner().run(order, timeout_seconds=1)
    except RuntimeError as exc:
        assert "may not override semantic-worker authority" in str(exc), exc
    else:
        raise AssertionError("authority-bearing OFLOOP_CLAUDE_EXTRA_ARGS was accepted")
finally:
    os.environ.pop("OFLOOP_CLAUDE_EXTRA_ARGS", None)

# Readiness proves the Claude version that implements setting-source sandbox
# exclusion. Old or unparseable versions fail closed before a semantic attempt.
fake = root / "claude"
fake.write_text("#!/bin/sh\necho '2.1.245 (Claude Code)'\n", encoding="utf-8")
fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
os.environ["OFLOOP_CLAUDE_BIN"] = str(fake)
old = supervisor.ClaudeCodeRunner().preflight()
assert old.ready is False, old
assert old.classification == "configuration", old
assert old.reason == "runner_secure_sandbox_version_too_old", old

fake.write_text("#!/bin/sh\necho '2.1.246 (Claude Code)'\n", encoding="utf-8")
ready = supervisor.ClaudeCodeRunner().preflight()
assert ready.ready is True, ready
os.environ.pop("OFLOOP_CLAUDE_BIN", None)

print("V084_NIGHTSHIFT_WORKER_BOUNDARY=PASS")
PY

pass "semantic worker tool/sandbox/settings/version boundary"
echo "V084_NIGHTSHIFT_WORKER_BOUNDARY=PASS"

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
# Historical env tuning must not widen the product-owned sealed tool surface.
os.environ["OFLOOP_CLAUDE_ALLOWED_TOOLS"] = (
    "Read,Edit,Write,NotebookEdit,Bash,Glob,Grep,WebSearch,WebFetch,Agent,Task,Skill"
)
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
    os.environ.pop("OFLOOP_CLAUDE_ALLOWED_TOOLS", None)

cmd = captured["cmd"]
assert "--restricted" in cmd, cmd
assert cmd[cmd.index("--permission-mode") + 1] == "dontAsk", cmd
assert "--tools" in cmd, cmd
assert "--allowedTools" in cmd, cmd
assert cmd[cmd.index("--tools") + 1] == supervisor.CLAUDE_BUILDER_TOOLS
assert cmd[cmd.index("--allowedTools") + 1] == supervisor.CLAUDE_BUILDER_TOOLS
toolset = set(supervisor.CLAUDE_BUILDER_TOOLS.split(","))
assert toolset == {"Read","Edit","Write","NotebookEdit","Bash","Glob","Grep"}, toolset
assert not toolset.intersection({"WebSearch","WebFetch","Agent","Task","Skill"}), toolset
assert "--strict-mcp-config" in cmd, cmd
assert cmd[cmd.index("--mcp-config") + 1] == "{}", cmd
assert "--no-chrome" in cmd, cmd
assert "--no-session-persistence" in cmd, cmd
assert "--setting-sources" not in cmd, cmd
settings = json.loads(cmd[cmd.index("--settings") + 1])
sb = settings["sandbox"]
assert sb["enabled"] is True
assert sb["failIfUnavailable"] is True
assert sb["autoAllowBashIfSandboxed"] is True
assert sb["allowUnsandboxedCommands"] is False
assert sb["excludedCommands"] == []
assert sb["network"]["strictAllowlist"] is True
assert sb["network"]["allowedDomains"] == []
fs = sb["filesystem"]
allow_write = set(fs["allowWrite"])
allow_read = set(fs["allowRead"])
assert fs["denyRead"] == [str(pathlib.Path.home().resolve())], fs
assert str(worktree.resolve()) in allow_read, allow_read
assert str(semantic.parent.resolve()) in allow_read, allow_read
assert str((repo / ".git").resolve()) in allow_read, allow_read
assert str(semantic.parent.resolve()) in allow_write, allow_write
expected_cache = str(
    runtime_env.runtime_cache_path(repo, "run-secure", "builder").resolve()
)
assert expected_cache in allow_read, allow_read
assert expected_cache in allow_write, allow_write
cred_names = {item["name"] for item in sb["credentials"]["envVars"]}
assert {"GITHUB_TOKEN","GH_TOKEN","NPM_TOKEN","NODE_AUTH_TOKEN","PYPI_TOKEN","TWINE_PASSWORD","DOCKER_AUTH_CONFIG"} <= cred_names
assert captured["env"]["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1"

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

# Reviewer invocation structurally lacks source-editing tools while retaining
# sandboxed Bash for validation and its one semantic assessment artifact.
captured.clear()
supervisor.subprocess.Popen = FakePopen
os.environ["OFLOOP_CLAUDE_BIN"] = "/bin/sh"
try:
    review_order = dict(order)
    review_order.update({
        "role": "reviewer",
        "state": "REVIEWING",
        "worktree": str(review_wt),
        "semantic_path": str(review_sem),
    })
    try:
        supervisor.ClaudeCodeRunner().run(review_order, timeout_seconds=1)
    except SystemExit:
        pass
finally:
    supervisor.subprocess.Popen = real_popen
    os.environ.pop("OFLOOP_CLAUDE_BIN", None)
review_cmd = captured["cmd"]
assert review_cmd[review_cmd.index("--tools") + 1] == supervisor.CLAUDE_REVIEWER_TOOLS
assert review_cmd[review_cmd.index("--allowedTools") + 1] == supervisor.CLAUDE_REVIEWER_TOOLS
review_tools = set(supervisor.CLAUDE_REVIEWER_TOOLS.split(","))
assert review_tools == {"Read","Bash","Glob","Grep"}, review_tools
assert not review_tools.intersection({"Edit","Write","NotebookEdit"}), review_tools
assert captured["env"]["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1"

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

# Readiness proves the Claude-native --restricted shared-machine baseline.
# Old or unparseable versions fail closed before a semantic attempt.
fake = root / "claude"
fake.write_text("#!/bin/sh\necho '2.1.247 (Claude Code)'\n", encoding="utf-8")
fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
os.environ["OFLOOP_CLAUDE_BIN"] = str(fake)
old = supervisor.ClaudeCodeRunner().preflight()
assert old.ready is False, old
assert old.classification == "configuration", old
assert old.reason == "runner_secure_sandbox_version_too_old", old

fake.write_text("#!/bin/sh\necho '2.1.248 (Claude Code)'\n", encoding="utf-8")
ready = supervisor.ClaudeCodeRunner().preflight()
assert ready.ready is True, ready
os.environ.pop("OFLOOP_CLAUDE_BIN", None)

# A QUARANTINED enrollment with unresolved semantic-attempt evidence is not
# historical yet, even when the job-level PID is empty/dead.
retire_repo = root / "retire-repo"
retire_repo.mkdir()
retire_db = root / "retire.sqlite3"
enrolled = supervisor.enqueue(
    canonical_repo=retire_repo,
    run_id="run-retire-attempt",
    db_path=retire_db,
    runtime_generation="ofloop-0.8.4@test",
)
assert enrolled["status"] == "QUEUED", enrolled
with supervisor._connect(retire_db) as conn:
    job_id = int(conn.execute(
        "SELECT id FROM jobs WHERE run_id='run-retire-attempt'"
    ).fetchone()["id"])
    conn.execute(
        "UPDATE jobs SET status='QUARANTINED',worker_pid=NULL,"
        "worker_started_at=NULL,worker_role=NULL WHERE id=?",
        (job_id,),
    )
    conn.execute(
        """INSERT INTO semantic_attempts
           (attempt_id,job_id,role,status,started_at,stdout_path,stderr_path)
           VALUES ('attempt-ambiguous',?,'builder','RESERVED',1.0,'/tmp/o','/tmp/e')""",
        (job_id,),
    )
refused = supervisor.retire(
    canonical_repo=retire_repo,
    run_id="run-retire-attempt",
    db_path=retire_db,
)
assert refused.get("retired") is False, refused
assert refused.get("reason") == "retire_refuses_unresolved_semantic_attempt", refused
assert refused["status"] == "QUARANTINED", refused
with supervisor._connect(retire_db) as conn:
    conn.execute(
        "UPDATE semantic_attempts SET status='COMPLETED',completed_at=2.0,"
        "returncode=0,cost_accounted=1 WHERE attempt_id='attempt-ambiguous'"
    )
retired = supervisor.retire(
    canonical_repo=retire_repo,
    run_id="run-retire-attempt",
    db_path=retire_db,
)
assert retired.get("retired") is True, retired
assert retired["runtime_generation_preserved"] == "ofloop-0.8.4@test", retired

print("V084_NIGHTSHIFT_WORKER_BOUNDARY=PASS")
PY

pass "semantic worker tool/sandbox/settings/version boundary"
echo "V084_NIGHTSHIFT_WORKER_BOUNDARY=PASS"

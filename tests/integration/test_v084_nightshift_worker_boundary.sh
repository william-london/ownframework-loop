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

grep -Fq "WHERE status NOT IN ('DONE','RETIRED')" "$ROOT_DIR/scripts/probe-supervisor-runtime-dependencies.py" \
  || fail "shared runtime dependency probe must exclude DONE + RETIRED"
grep -Fq 'probe-supervisor-runtime-dependencies.py' "$ROOT_DIR/install.sh" \
  || fail "core installer must use shared runtime dependency probe"
grep -Fq 'probe-supervisor-runtime-dependencies.py' "$ROOT_DIR/install-supervisor-macos.sh" \
  || fail "macOS supervisor installer must use shared runtime dependency probe"
grep -Fq 'probe-supervisor-runtime-dependencies.py' "$ROOT_DIR/install-supervisor-linux.sh" \
  || fail "Linux supervisor installer must use shared runtime dependency probe"
pass "core + platform installers share one DONE/RETIRED runtime-dependency contract"

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
# Claude 2.1.251+ requires ``--mcp-config`` to declare a ``mcpServers``
# record (the bare ``{}`` form is rejected). Verify the architecturally
# required empty ``mcpServers`` is the actual emitted value.
mcp_config = cmd[cmd.index("--mcp-config") + 1]
mcp_payload = json.loads(mcp_config)
assert mcp_payload == {"mcpServers": {}}, mcp_payload
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
assert str((repo / ".ownframework-loop" / "run-secure").resolve()) in allow_read, allow_read
assert str((repo / ".git").resolve()) in allow_read, allow_read
assert str(semantic.parent.resolve()) in allow_write, allow_write
expected_cache = str(
    runtime_env.runtime_cache_path(repo, "run-secure", "builder").resolve()
)
assert expected_cache in allow_read, allow_read
assert expected_cache in allow_write, allow_write
# Operator-supplied adapter auth-read paths bypass denyRead: [home]
# so a commissioned adapter (Claude) can reach its own auth state.
# Empty / unset env var = no extra paths; non-empty + existing absolute
# path = added; non-existent / relative paths silently dropped (the
# core never invents adapter-specific paths).
fake_claude_home = root / "claude-home"
fake_claude_home.mkdir()
os.environ["OFLOOP_ADAPTER_AUTH_READ_PATHS"] = str(fake_claude_home)
auth_settings = supervisor._semantic_worker_settings(
    canonical_repo=repo,
    run_id="run-secure",
    role="builder",
    worktree=worktree,
    semantic_path=semantic,
)
auth_allow_read = set(auth_settings["sandbox"]["filesystem"]["allowRead"])
assert str(fake_claude_home.resolve()) in auth_allow_read, auth_allow_read
# Non-existent and relative paths are silently dropped.
missing = root / "missing-claude-home"
os.environ["OFLOOP_ADAPTER_AUTH_READ_PATHS"] = (
    f"{missing},relative/path,{fake_claude_home}"
)
mixed_settings = supervisor._semantic_worker_settings(
    canonical_repo=repo,
    run_id="run-secure",
    role="builder",
    worktree=worktree,
    semantic_path=semantic,
)
mixed_allow_read = set(mixed_settings["sandbox"]["filesystem"]["allowRead"])
assert str(fake_claude_home.resolve()) in mixed_allow_read, mixed_allow_read
assert str(missing.resolve()) not in mixed_allow_read, mixed_allow_read
assert "relative/path" not in mixed_allow_read, mixed_allow_read
del os.environ["OFLOOP_ADAPTER_AUTH_READ_PATHS"]
empty_settings = supervisor._semantic_worker_settings(
    canonical_repo=repo,
    run_id="run-secure",
    role="builder",
    worktree=worktree,
    semantic_path=semantic,
)
empty_allow_read = set(empty_settings["sandbox"]["filesystem"]["allowRead"])
assert str(fake_claude_home.resolve()) not in empty_allow_read, empty_allow_read
cred_names = {item["name"] for item in sb["credentials"]["envVars"]}
assert {"GITHUB_TOKEN","GH_TOKEN","NPM_TOKEN","NODE_AUTH_TOKEN","PYPI_TOKEN","TWINE_PASSWORD","DOCKER_AUTH_CONFIG"} <= cred_names
assert captured["env"]["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1"
assert captured["env"]["GIT_CONFIG_GLOBAL"] == os.devnull
assert captured["env"]["GIT_CONFIG_NOSYSTEM"] == "1"
assert captured["env"]["GIT_TERMINAL_PROMPT"] == "0"
assert captured["env"]["GIT_AUTHOR_NAME"] == "OwnFramework Loop"
assert captured["env"]["GIT_AUTHOR_EMAIL"] == "loop@localhost"
assert captured["env"]["GIT_COMMITTER_NAME"] == "OwnFramework Loop"
assert captured["env"]["GIT_COMMITTER_EMAIL"] == "loop@localhost"

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

# DONE runtime cache is disposable; QUARANTINED cache is recovery material.
gc_repo = root / "gc-repo"
gc_repo.mkdir()
gc_db = root / "gc.sqlite3"
done_run = "run-gc-done"
quarantine_run = "run-gc-quarantine"
for rid in (done_run, quarantine_run):
    enq = supervisor.enqueue(
        canonical_repo=gc_repo,
        run_id=rid,
        db_path=gc_db,
        runtime_generation="ofloop-0.8.4@test",
    )
    assert enq["status"] == "QUEUED", enq
with supervisor._connect(gc_db) as conn:
    conn.execute("UPDATE jobs SET status='DONE' WHERE run_id=?", (done_run,))
    conn.execute("UPDATE jobs SET status='QUARANTINED' WHERE run_id=?", (quarantine_run,))
done_cache = runtime_env.runtime_cache_dir(gc_repo, done_run, "builder")
(done_cache / "junk.txt").write_text("ephemeral", encoding="utf-8")
quarantine_cache = runtime_env.runtime_cache_dir(gc_repo, quarantine_run, "builder")
(quarantine_cache / "keep.txt").write_text("resumable", encoding="utf-8")
gc_results = supervisor._cleanup_done_runtime_caches(gc_db)
assert any(item["removed"] for item in gc_results), gc_results
assert not supervisor._runtime_cache_run_root(gc_repo, done_run).exists()
assert supervisor._runtime_cache_run_root(gc_repo, quarantine_run).exists()

# Retired parser/module surfaces are actually absent, not runnable warning stubs.
source_root = pathlib.Path(supervisor.__file__).resolve().parents[2]
cli_source = (source_root / "lib" / "ownframework_loop" / "cli.py").read_text(encoding="utf-8")
assert "cmd_loop_run" not in cli_source
assert "cmd_build_write_receipt" not in cli_source
assert "cmd_review_write_verdict" not in cli_source
assert "add_parser('loop'" not in cli_source
assert 'add_parser("write-receipt"' not in cli_source
assert 'add_parser("write-verdict"' not in cli_source
assert not (source_root / "lib" / "ownframework_loop" / "orchestrator.py").exists()
assert not (source_root / "rollback.sh").exists()

print("V084_NIGHTSHIFT_WORKER_BOUNDARY=PASS")
PY

pass "semantic worker tool/sandbox/settings/version boundary"
echo "V084_NIGHTSHIFT_WORKER_BOUNDARY=PASS"

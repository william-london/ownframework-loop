#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import json, signal, subprocess, sys
from pathlib import Path
from ownframework_loop import process_runner, supervisor, supervisor_runner
root=Path(sys.argv[1])
p=root/"cost.json"
p.write_text(json.dumps({"total_cost_usd":1.25}))
assert supervisor._parse_cost_from_durable_stdout(str(p)) == 1.25
p.write_text('{"total_cost_usd": NaN}')
assert supervisor._parse_cost_from_durable_stdout(str(p)) is None
p.write_text('{"result":"ok"}')
assert supervisor._parse_cost_from_durable_stdout(str(p)) is None

db=root/"s.sqlite"
conn=supervisor._connect(db)
conn.execute("INSERT INTO jobs(repo,run_id,runner,status,created_at,updated_at) VALUES(?,?,?,?,?,?)",
             (str(root),"run-cost-proof","claude-code","RUNNING",1.0,1.0))
job_id=conn.execute("SELECT id FROM jobs").fetchone()[0]
conn.execute("INSERT INTO semantic_attempts(attempt_id,job_id,role,status,started_at,stdout_path,stderr_path) VALUES(?,?,?,?,?,?,?)",
             ("a1",job_id,"builder","RUNNING",1.0,str(p),str(p)))
conn.commit()
try:
    supervisor._account_attempt_cost(conn,job_id=job_id,attempt_id="a1",cost_usd=float("nan"))
except RuntimeError:
    pass
else:
    raise SystemExit("non-finite model cost was accounted")
conn.close()

# Process-group termination is lifecycle behavior, not a function-name grep.
# Force the graceful wait to expire and prove TERM -> KILL -> reap ordering.
class FakeProc:
    pid = 424242
    returncode = None
    def __init__(self):
        self.wait_calls = 0
        self.wait_timeouts = []
    def poll(self):
        return self.returncode
    def wait(self, timeout=None):
        self.wait_calls += 1
        self.wait_timeouts.append(timeout)
        if self.wait_calls == 1:
            raise subprocess.TimeoutExpired(cmd="fake-semantic-worker", timeout=timeout)
        self.returncode = -signal.SIGKILL
        return self.returncode

fake = FakeProc()
signals = []
orig_killpg = supervisor_runner.os.killpg
orig_group_exists = process_runner.process_group_exists
try:
    def fake_killpg(pid, sig):
        signals.append((pid, sig))
        if sig == signal.SIGKILL:
            fake.returncode = -signal.SIGKILL

    supervisor_runner.os.killpg = fake_killpg
    process_runner.process_group_exists = lambda _pgid: fake.returncode is None
    supervisor_runner._terminate_group(fake, grace_seconds=0.01)
finally:
    supervisor_runner.os.killpg = orig_killpg
    process_runner.process_group_exists = orig_group_exists
assert signals == [(fake.pid, signal.SIGTERM), (fake.pid, signal.SIGKILL)], signals
assert fake.wait_calls >= 1, fake.wait_calls
assert all(timeout is not None for timeout in getattr(fake, "wait_timeouts", []))
PY

# A valid Claude result may exceed diagnostic retention. The runner must parse
# the complete durable envelope and bound only the returned diagnostics.
LARGE_FAKE="$TMP/large-claude"
cat > "$LARGE_FAKE" <<'PY'
#!/usr/bin/env python3
import json
import sys

payload = {
    "is_error": False,
    "subtype": "success",
    "result": "ok-" + ("x" * 70000),
    "total_cost_usd": 1.25,
    "usage": {
        "input_tokens": 123,
        "output_tokens": 456,
        "cache_read_input_tokens": 789,
        "cache_creation_input_tokens": 10,
    },
}
sys.stdout.write(json.dumps(payload) + "\n")
sys.stderr.write("diagnostic-" + ("e" * 70000) + "\n")
PY
chmod +x "$LARGE_FAKE"
LARGE_RESULT="$(OFLOOP_CLAUDE_BIN="$LARGE_FAKE" python3 - "$TMP" <<'PY'
import json
import sys
from pathlib import Path
from ownframework_loop import supervisor

root = Path(sys.argv[1])
repo = root / "large-repo"
worktree = root / "large-worktree"
repo.mkdir()
worktree.mkdir()
out = root / "large.out"
err = root / "large.err"
result = supervisor.ClaudeCodeRunner().run(
    {
        "schema": supervisor.SCHEMA,
        "decision": "BUILD",
        "role": "builder",
        "run_id": "run-large-durable-output",
        "state": "BUILDING",
        "replayed": False,
        "canonical_repo": str(repo),
        "worktree": str(worktree),
        "semantic_path": str(worktree / "result.json"),
        "network_read_allowlist": [],
        "attempt_id": "attempt-large-durable-output",
    },
    timeout_seconds=30,
    durable_files=(out, err),
)
full_text = out.read_text(encoding="utf-8")
full = json.loads(full_text)
assert len(full_text) > 65536
assert full["is_error"] is False
assert full["subtype"] == "success"
assert full["result"].startswith("ok-")
assert result.ok is True
assert result.cost_known is True
assert result.cost_usd == 1.25
assert result.tokens_known is True
assert result.input_tokens == 123
assert result.output_tokens == 456
assert result.cache_read_tokens == 789
assert result.cache_creation_tokens == 10
assert len(result.stdout) <= 65536
assert len(result.stderr) <= 65536
print("LARGE_DURABLE_STDOUT_FULL_JSON_PARSE=PASS")
print("LARGE_DURABLE_STDOUT_RUNNER_OK=PASS")
print("LARGE_DURABLE_STDOUT_COST_KNOWN=PASS")
print("LARGE_DURABLE_STDOUT_TOKEN_USAGE_KNOWN=PASS")
print("LARGE_DURABLE_STDOUT_DIAGNOSTIC_BOUND_PRESERVED=PASS")
PY
)"
printf '%s\n' "$LARGE_RESULT"

# Provider process exit 0 is not semantic success by itself. An invalid
# structured envelope must still return ok=False even though the executable
# exits successfully.
ZERO_EXIT_FAKE="$TMP/zero-exit-invalid-envelope"
cat > "$ZERO_EXIT_FAKE" <<'PY'
#!/usr/bin/env python3
print("not-a-structured-provider-envelope")
PY
chmod +x "$ZERO_EXIT_FAKE"
ZERO_EXIT_RESULT="$(OFLOOP_CLAUDE_BIN="$ZERO_EXIT_FAKE" python3 - "$TMP" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor

root = Path(sys.argv[1])
repo = root / "zero-exit-repo"
worktree = root / "zero-exit-worktree"
repo.mkdir()
worktree.mkdir()
out = root / "zero-exit.out"
err = root / "zero-exit.err"
result = supervisor.ClaudeCodeRunner().run(
    {
        "schema": supervisor.SCHEMA,
        "decision": "BUILD",
        "role": "builder",
        "run_id": "run-zero-exit-invalid-envelope",
        "state": "BUILDING",
        "replayed": False,
        "canonical_repo": str(repo),
        "worktree": str(worktree),
        "semantic_path": str(worktree / "result.json"),
        "network_read_allowlist": [],
        "attempt_id": "attempt-zero-exit-invalid-envelope",
    },
    timeout_seconds=30,
    durable_files=(out, err),
)
assert result.returncode == 0, result
assert result.ok is False, result
assert result.cost_known is False, result
assert result.tokens_known is False, result
print("ZERO_EXIT_INVALID_SEMANTIC_ENVELOPE_REFUSED=PASS")
PY
)"
printf '%s\n' "$ZERO_EXIT_RESULT"

# A durable provider envelope above the explicit unattended-runtime ceiling
# must fail closed before the supervisor reads it into memory. The ceiling is
# intentionally orders of magnitude above the historical 64 KiB diagnostic
# limit, so this does not regress legitimate large Claude JSON.
OVERSIZE_FAKE="$TMP/oversize-claude"
cat > "$OVERSIZE_FAKE" <<'PY'
#!/usr/bin/env python3
import json
import sys

payload = {
    "is_error": False,
    "subtype": "success",
    "result": "x" * ((8 * 1024 * 1024) + 4096),
    "total_cost_usd": 7.5,
    "usage": {"input_tokens": 10, "output_tokens": 20},
}
sys.stdout.write(json.dumps(payload) + "\n")
PY
chmod +x "$OVERSIZE_FAKE"
OVERSIZE_RESULT="$(OFLOOP_CLAUDE_BIN="$OVERSIZE_FAKE" python3 - "$TMP" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor

root = Path(sys.argv[1])
repo = root / "oversize-repo"
worktree = root / "oversize-worktree"
repo.mkdir()
worktree.mkdir()
out = root / "oversize.out"
err = root / "oversize.err"
result = supervisor.ClaudeCodeRunner().run(
    {
        "schema": supervisor.SCHEMA,
        "decision": "BUILD",
        "role": "builder",
        "run_id": "run-oversize-durable-output",
        "state": "BUILDING",
        "replayed": False,
        "canonical_repo": str(repo),
        "worktree": str(worktree),
        "semantic_path": str(worktree / "result.json"),
        "network_read_allowlist": [],
        "attempt_id": "attempt-oversize-durable-output",
    },
    timeout_seconds=30,
    durable_files=(out, err),
)
assert out.stat().st_size > supervisor.CLAUDE_PROVIDER_ENVELOPE_MAX_BYTES
assert result.ok is False
assert result.cost_known is False
assert result.tokens_known is False
assert "provider envelope exceeds deterministic ceiling" in result.stderr
assert len(result.stderr) <= supervisor.RUNNER_DIAGNOSTIC_MAX_CHARS
assert supervisor._parse_cost_from_durable_stdout(str(out)) is None
assert supervisor._parse_token_usage_from_durable_stdout(str(out)) is None
print("OVERSIZE_DURABLE_STDOUT_FAILS_CLOSED=PASS")
print("PROVIDER_ENVELOPE_MEMORY_BOUND=PASS")
print("RECOVERY_ENVELOPE_MEMORY_BOUND=PASS")
PY
)"
printf '%s\n' "$OVERSIZE_RESULT"

echo "V061_RUNNER_COST_PROOF=PASS"

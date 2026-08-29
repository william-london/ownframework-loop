#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, subprocess, sys, time
from pathlib import Path
from ownframework_loop import program, runtime_env, supervisor

root=Path(sys.argv[1])

# Runtime cache namespaces for paths that collided under the historical lossy
# slash-stripping slug must now differ.
a=root/"a"/"b"; b=root/"ab"; a.mkdir(parents=True); b.mkdir(parents=True)
os.environ["XDG_STATE_HOME"]=str(root/"state")
ca=runtime_env.runtime_cache_dir(a,"run-cache","builder")
cb=runtime_env.runtime_cache_dir(b,"run-cache","builder")
assert ca != cb, (ca,cb)

# Supervisor external boundaries reject unsafe run ids before DB/log path use.
for rid in ("../../outside","run-a/b","run-../escape"):
    try:
        supervisor.enqueue(canonical_repo=root,run_id=rid,db_path=root/"unsafe.sqlite3")
    except ValueError:
        pass
    else:
        raise SystemExit(f"unsafe supervisor run id accepted: {rid}")

# Current process start-time probe should resolve plausibly on supported
# Linux/macOS platforms. This exercises the Linux /proc field index and the
# macOS etime parser through the real host path.
start=supervisor._read_pid_start_time(os.getpid())
assert start is not None, sys.platform
assert abs(time.time()-start) < 120, (sys.platform,start,time.time())

# Binary files still consume the unique-changed-file program ceiling.
repo=root/"binary-repo"; repo.mkdir()
subprocess.run(["git","init","-q",str(repo)],check=True)
subprocess.run(["git","-C",str(repo),"config","user.email","test@example.invalid"],check=True)
subprocess.run(["git","-C",str(repo),"config","user.name","Test"],check=True)
(repo/"bin.dat").write_bytes(b"\x00A\x00B")
subprocess.run(["git","-C",str(repo),"add","bin.dat"],check=True)
subprocess.run(["git","-C",str(repo),"commit","-qm","base"],check=True)
base=subprocess.check_output(["git","-C",str(repo),"rev-parse","HEAD"],text=True).strip()
(repo/"bin.dat").write_bytes(b"\x00C\x00D")
subprocess.run(["git","-C",str(repo),"add","bin.dat"],check=True)
subprocess.run(["git","-C",str(repo),"commit","-qm","candidate"],check=True)
cand=subprocess.check_output(["git","-C",str(repo),"rev-parse","HEAD"],text=True).strip()
acct=program.source_tree_accounting(canonical_repo=repo,baseline_sha=base,candidate_sha=cand)
assert acct["files_changed_unique"] == 1, acct
PY

# Guard normalizer errors must not be swallowed into raw-command fallback.
if grep -A22 'Apply the same layered normalizations' "$ROOT_DIR/lib/ownframework_loop/guards.py" | grep -Fq 'except Exception'; then
  echo "FAIL: semantic Bash normalization still fails open"
  exit 1
fi

# PostToolUse must not attach an interactive session to an arbitrary historical
# run merely because .ownframework-loop exists.
REPO="$TMP/post-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name Test
touch "$REPO/file"; git -C "$REPO" add file; git -C "$REPO" commit -qm init
mkdir -p "$REPO/.ownframework-loop/run-history" "$REPO/.ownframework-loop/run-active"

SECRET='sk-AAAAAAAAAAAAAAAAAAAAAAAA'
PAYLOAD="$(python3 - "$REPO" "$SECRET" <<'PY'
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_output":sys.argv[2]}))
PY
)"
printf '%s' "$PAYLOAD" | CLAUDE_PLUGIN_ROOT="$ROOT_DIR" "$ROOT_DIR/hooks/post_bash_secret_scan.sh"
[[ ! -e "$REPO/.ownframework-loop/run-history/EVENTS.log" ]] || {
  echo "FAIL: interactive post-hook mutated historical run"; exit 1;
}
[[ ! -e "$REPO/.ownframework-loop/run-active/EVENTS.log" ]] || {
  echo "FAIL: interactive post-hook mutated arbitrary run"; exit 1;
}

# Exact semantic env targets only its declared run.
printf '%s' "$PAYLOAD" | \
  OFLOOP_SEMANTIC_CONTEXT=1 \
  OFLOOP_RUN_ID=run-active \
  OFLOOP_ROLE=builder \
  OFLOOP_CANONICAL_REPO="$REPO" \
  CLAUDE_PLUGIN_ROOT="$ROOT_DIR" \
  "$ROOT_DIR/hooks/post_bash_secret_scan.sh"
[[ -s "$REPO/.ownframework-loop/run-active/EVENTS.log" ]] || {
  echo "FAIL: semantic post-hook did not record exact active run"; exit 1;
}
[[ ! -e "$REPO/.ownframework-loop/run-history/EVENTS.log" ]] || {
  echo "FAIL: semantic post-hook touched wrong run"; exit 1;
}

echo "V061_RUNTIME_TAIL_HARDENING=PASS"

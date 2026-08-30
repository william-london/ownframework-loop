#!/usr/bin/env bash
# v0.8.2 production hardening.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
cd "$ROOT_DIR"

TMP="$(mktemp -d -t ofloop_v082_prod.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

python3 -B - "$TMP" <<'PY'
import subprocess, sys
from pathlib import Path
from ownframework_loop.runtime_identity import runtime_generation_for_root

tmp=Path(sys.argv[1])
a=tmp/"payload-a"; b=tmp/"payload-b"
for root in (a,b):
    (root/"lib").mkdir(parents=True)
    (root/"bin").mkdir()
    (root/"lib"/"x.py").write_text("VALUE=1\n")
    (root/"bin"/"ofloop").write_text("#!/bin/sh\necho ok\n")
    (root/"bin"/"ofloop").chmod(0o755)
    (root/"link-lib").symlink_to("lib", target_is_directory=True)

ga=runtime_generation_for_root(a,"9.9.9")
gb=runtime_generation_for_root(b,"9.9.9")
assert ga == gb, (ga,gb)
assert "@payload-" in ga and len(ga.rsplit("-",1)[-1]) == 64, ga
(b/"lib"/"x.py").write_text("VALUE=2\n")
assert runtime_generation_for_root(b,"9.9.9") != ga
(a/"link-lib").unlink(); (a/"link-lib").symlink_to("bin", target_is_directory=True)
assert runtime_generation_for_root(a,"9.9.9") != ga

g=tmp/"git-runtime"; g.mkdir()
subprocess.run(["git","-C",str(g),"init","-b","master"],check=True,stdout=subprocess.DEVNULL)
subprocess.run(["git","-C",str(g),"config","user.email","t@t"],check=True)
subprocess.run(["git","-C",str(g),"config","user.name","t"],check=True)
(g/"runtime.py").write_text("A=1\n")
subprocess.run(["git","-C",str(g),"add","runtime.py"],check=True)
subprocess.run(["git","-C",str(g),"commit","-m","init"],check=True,stdout=subprocess.DEVNULL)
head=subprocess.check_output(["git","-C",str(g),"rev-parse","HEAD"],text=True).strip()
clean=runtime_generation_for_root(g,"9.9.9")
assert clean == f"ofloop-9.9.9@git-{head}", clean
(g/"runtime.py").write_text("A=2\n")
dirty=runtime_generation_for_root(g,"9.9.9")
assert "@dirty-" in dirty and dirty != clean

# A payload nested under some unrelated parent Git checkout is still a payload,
# not that parent's runtime generation.
nested=g/"nested-payload"; nested.mkdir()
(nested/"runtime.txt").write_text("payload\n")
nested_gen=runtime_generation_for_root(nested,"9.9.9")
assert "@payload-" in nested_gen, nested_gen
print("RUNTIME_BYTE_IDENTITY=OK")
PY
pass "T1 runtime generation binds actual payload and dirty-source bytes"

python3 -B - "$TMP" <<'PY'
import sqlite3, sys
from pathlib import Path
from ownframework_loop import supervisor
tmp=Path(sys.argv[1]); db=tmp/"readonly.sqlite3"; repo=tmp/"readonly-repo"; repo.mkdir()
c=sqlite3.connect(str(db))
c.execute("CREATE TABLE jobs (id INTEGER PRIMARY KEY, repo TEXT NOT NULL, run_id TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
c.execute("INSERT INTO jobs VALUES (1, ?, 'run-ro', 'QUEUED', 1, 1)",(str(repo.resolve()),))
c.execute("PRAGMA user_version=1"); c.commit()
before_cols=[r[1] for r in c.execute("PRAGMA table_info(jobs)")]
before_ver=c.execute("PRAGMA user_version").fetchone()[0]; c.close()
out=supervisor.status(canonical_repo=repo, run_id="run-ro", db_path=db)
assert out["ok"], out
c=sqlite3.connect(str(db))
after_cols=[r[1] for r in c.execute("PRAGMA table_info(jobs)")]
after_ver=c.execute("PRAGMA user_version").fetchone()[0]; c.close()
assert after_cols == before_cols
assert after_ver == before_ver == 1
print("STATUS_READ_ONLY=OK")
PY
pass "T2 supervisor status cannot migrate an observed legacy ledger"

python3 -B - "$TMP" <<'PY'
from pathlib import Path
import sys
from ownframework_loop import supervisor
tmp=Path(sys.argv[1]); db=tmp/"gen-unavailable.sqlite3"; repo=tmp/"gen-unavailable"; repo.mkdir()
supervisor.enqueue(canonical_repo=repo, run_id="run-generation-proof", db_path=db, runtime_generation="ofloop-known@git-deadbeef")
def boom():
    raise RuntimeError("identity unavailable")
supervisor._current_runtime_generation=boom
out=supervisor.run_one(db_path=db)
assert out["action"] == "QUARANTINED", out
assert out["reason"] == "runtime_generation_unavailable", out
PY
pass "T3 runtime identity proof failure quarantines before semantic dispatch"

python3 -B - "$TMP" <<'PY'
import sqlite3, sys
from pathlib import Path
from ownframework_loop import supervisor
tmp=Path(sys.argv[1]); db=tmp/"reenqueue.sqlite3"; repo=tmp/"reenqueue-repo"; repo.mkdir()
supervisor.enqueue(canonical_repo=repo, run_id="run-live", db_path=db, runtime_generation="ofloop-old@git-a", max_wall_seconds=600)
c=sqlite3.connect(str(db)); c.execute("UPDATE jobs SET status='RUNNING', worker_pid=12345 WHERE run_id='run-live'"); c.commit(); c.close()
out=supervisor.enqueue(canonical_repo=repo, run_id="run-live", db_path=db, runtime_generation="ofloop-new@git-b", max_wall_seconds=0)
assert out["ok"] is False and out["reason"] == "cannot_change_runtime_generation_while_running", out
c=sqlite3.connect(str(db)); row=c.execute("SELECT runtime_generation,max_wall_seconds,worker_pid FROM jobs WHERE run_id='run-live'").fetchone(); c.close()
assert row == ("ofloop-old@git-a",600,12345), row

# Re-enqueue under the SAME generation is an explicit operator configuration
# update and may widen/narrow ceilings without rewriting worker ownership.
out2=supervisor.enqueue(canonical_repo=repo, run_id="run-live", db_path=db, runtime_generation="ofloop-old@git-a", max_wall_seconds=900)
assert out2["ok"] is True and out2["status"] == "RUNNING", out2
assert out2["runtime_generation"] == "ofloop-old@git-a", out2
assert out2["max_wall_seconds"] == 900 and out2["worker_pid"] == 12345, out2
PY
pass "T4 RUNNING re-enqueue preserves generation/ownership; same-generation ceiling updates remain explicit operator actions"

python3 -B - "$TMP" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import runtime_env
tmp=Path(sys.argv[1]); repo=tmp/"env-repo"; repo.mkdir()
base={"PATH":"/usr/bin:/bin","PYTEST_ADDOPTS":"-q --maxfail=2","PYTEST_PLUGINS":"custom.plugin"}
env=runtime_env.hermetic_subprocess_env(repo,"run-env","validation",base_env=base)
assert env["PYTEST_ADDOPTS"].startswith("-q --maxfail=2 ")
assert "-p no:cacheprovider" in env["PYTEST_ADDOPTS"]
assert "custom.plugin" in env["PYTEST_PLUGINS"]
p=runtime_env.runtime_cache_path(repo,"run-pure","validation")
assert not p.exists()
runtime_env.runtime_cache_dir(repo,"run-pure","validation")
assert p.is_dir()
PY
pass "T5 hermetic validation preserves project pytest semantics"

WR="$TMP/write-repo"
git -C "$TMP" init -q -b master write-repo
git -C "$WR" config user.email t@t
git -C "$WR" config user.name t
echo seed > "$WR/README.md"
git -C "$WR" add README.md
git -C "$WR" commit -q -m init
RUNA="run-20260830T000000Z-aaaa1111"
RUNB="run-20260830T000000Z-bbbb2222"
mkdir -p "$WR/.ownframework-loop/$RUNA" "$WR/.ownframework-loop/$RUNB"
mkdir -p "$WR/.worktrees/ownframework-loop/$RUNA/builder" "$WR/.worktrees/ownframework-loop/$RUNB/builder"

invoke_write() {
  local tool="$1" key="$2" target="$3"
  python3 - "$tool" "$key" "$target" "$WR" <<'PY' |
import json,sys
tool,key,target,cwd=sys.argv[1:]
i={} if not key else {key:target}
print(json.dumps({"tool_name":tool,"tool_input":i,"cwd":cwd}))
PY
  env OFLOOP_SEMANTIC_CONTEXT=1 OFLOOP_RUN_ID="$RUNA" OFLOOP_ROLE=builder       OFLOOP_CANONICAL_REPO="$WR" CLAUDE_PLUGIN_ROOT="$ROOT_DIR"       bash "$ROOT_DIR/hooks/block_protected_paths.sh" 2>/dev/null || true
}
OUT="$(invoke_write Write file_path "$WR/.worktrees/ownframework-loop/$RUNB/builder/x.py")"
assert_contains "$OUT" "CROSS_RUN_WRITE" "T6 cross-run builder Write refused"
OUT="$(invoke_write NotebookEdit notebook_path "$WR/.worktrees/ownframework-loop/$RUNB/builder/a.ipynb")"
assert_contains "$OUT" "CROSS_RUN_WRITE" "T6 NotebookEdit notebook_path governed"
OUT="$(invoke_write Write "" "")"
assert_contains "$OUT" "PROTECTED_PATH" "T6 missing active write path fails closed"
OUT="$(invoke_write Write file_path "$WR/.worktrees/ownframework-loop/$RUNA/builder/x.py")"
[[ -z "$OUT" ]] || fail "T6 own builder worktree write should be allowed: $OUT"
pass "T6 write hook binds exact active run and NotebookEdit path"

EMPTY_OUT="$(python3 - "$WR" <<'PY' |
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":""},"cwd":sys.argv[1]}))
PY
  env OFLOOP_SEMANTIC_CONTEXT=1 OFLOOP_RUN_ID="$RUNA" OFLOOP_ROLE=builder       OFLOOP_CANONICAL_REPO="$WR" CLAUDE_PLUGIN_ROOT="$ROOT_DIR"       bash "$ROOT_DIR/hooks/block_dangerous_bash.sh" 2>/dev/null || true)"
assert_contains "$EMPTY_OUT" "OF_LOOP_BASH_FORBIDDEN" "T7 active empty Bash fails closed"

SHIMS="$TMP/shims"; mkdir -p "$SHIMS"
cat > "$SHIMS/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$SHIMS/launchctl" <<'SH'
#!/bin/bash
case "$1" in
  bootout|enable) exit 0 ;;
  bootstrap)
    n=0; [[ -f "$LC_COUNT" ]] && n="$(cat "$LC_COUNT")"
    n=$((n+1)); echo "$n" > "$LC_COUNT"
    [[ "$n" -eq 1 ]] && exit 44
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$SHIMS/uname" "$SHIMS/launchctl"
IHOME="$TMP/install-home"; IXDG="$TMP/install-xdg"; mkdir -p "$IHOME/Library/LaunchAgents" "$IXDG/ownframework-loop"
IPLIST="$IHOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
IPROV="$IXDG/ownframework-loop/runtime-provenance.json"
printf 'OLD-PLIST\n' > "$IPLIST"; printf 'OLD-PROVENANCE\n' > "$IPROV"
# T8 models an already-commissioned supervisor whose replacement reaches the
# launchctl bootstrap/rollback path. Under the current fail-closed runtime
# dependency contract, a commissioned service without its supervisor ledger is
# intentionally unverifiable and must refuse earlier. Create an intact empty
# ledger so this fixture represents a legitimate commissioned system with no
# unfinished runtime dependencies.
PYTHONPATH="$ROOT_DIR/lib" python3 -B - "$IXDG/ownframework-loop/supervisor.sqlite3" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import supervisor
with supervisor._connect(Path(sys.argv[1])):
    pass
PY
set +e
IOUT="$(HOME="$IHOME" XDG_STATE_HOME="$IXDG" PATH="$SHIMS:$PATH" LC_COUNT="$TMP/lc-count" \
  OFLOOP_BIN="$ROOT_DIR/bin/ofloop" \
  bash "$ROOT_DIR/install-supervisor-macos.sh" 2>&1)"
IRC=$?
set -e
[[ "$IRC" -eq 14 ]] || fail "T8 expected bootstrap refusal rc14, got rc=$IRC out=$IOUT"
assert_contains "$IOUT" "rollback=restored_previous_service" "T8 previous supervisor restored"
[[ "$(cat "$IPLIST")" == "OLD-PLIST" ]] || fail "T8 plist rollback failed"
[[ "$(cat "$IPROV")" == "OLD-PROVENANCE" ]] || fail "T8 provenance rollback failed"
pass "T8 supervisor replacement rolls back on bootstrap failure"

# T8b proves commissioned macOS auth/model material is NOT embedded in the
# launchd plist/provenance and instead lives in one private service-env file.
# macOS OAuth credentials are Keychain-backed, so ~/.claude is not reopened.
if [[ "$(uname -s)" != "Darwin" ]]; then
  pass "T8b private service auth material (skipped on non-Darwin)"
else
S2SHIMS="$TMP/s2-shims"; mkdir -p "$S2SHIMS"
cat > "$S2SHIMS/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$S2SHIMS/launchctl" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$S2SHIMS/uname" "$S2SHIMS/launchctl"
S2HOME="$TMP/s2-home"; S2XDG="$TMP/s2-xdg"
rm -rf "$S2HOME" "$S2XDG"
mkdir -p "$S2HOME/Library/LaunchAgents" "$S2XDG/ownframework-loop"
S2PLIST="$S2HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
S2PROV="$S2XDG/ownframework-loop/runtime-provenance.json"
S2SERVICE_ENV="$S2XDG/ownframework-loop/service-env.json"
S2FAKECLAUDE="$TMP/fake-claude-2.1.251"
cat > "$S2FAKECLAUDE" <<'SH'
#!/bin/sh
echo "2.1.251 (Claude Code)"
SH
chmod +x "$S2FAKECLAUDE"
mkdir -p "$S2HOME/.claude"
HOME="$S2HOME" XDG_STATE_HOME="$S2XDG" PATH="$S2SHIMS:$PATH" \
  OFLOOP_BIN="$ROOT_DIR/bin/ofloop" \
  CLAUDE_BIN="$S2FAKECLAUDE" \
  ANTHROPIC_AUTH_TOKEN="sk-test-auth-token-capture" \
  ANTHROPIC_BASE_URL="https://api.example.invalid/anthropic" \
  ANTHROPIC_MODEL="claude-test-model" \
  bash "$ROOT_DIR/install-supervisor-macos.sh" >/dev/null 2>&1 \
  || fail "T8b macOS supervisor install failed"
[[ -f "$S2PLIST" ]] || fail "T8b plist not written"
[[ -f "$S2PROV" ]] || fail "T8b provenance not written"
[[ -f "$S2SERVICE_ENV" ]] || fail "T8b private service-env not written"

PLIST_ENV="$(python3 -c "import plistlib,sys; d=plistlib.load(open(sys.argv[1],'rb')); print('\n'.join(f'{k}={v}' for k,v in d.get('EnvironmentVariables',{}).items()))" "$S2PLIST" 2>/dev/null || true)"
assert_contains "$PLIST_ENV" "OFLOOP_SERVICE_ENV_FILE=$S2SERVICE_ENV" "T8b plist points at private service env"
if printf '%s' "$PLIST_ENV" | grep -Eq 'ANTHROPIC_(AUTH_TOKEN|API_KEY|BASE_URL|MODEL)'; then
  fail "T8b plist leaked provider auth/model material: $PLIST_ENV"
fi
if printf '%s' "$PLIST_ENV" | grep -Fq "OFLOOP_ADAPTER_AUTH_READ_PATHS"; then
  fail "T8b macOS plist reopened adapter auth filesystem path"
fi

python3 -B - "$S2SERVICE_ENV" "$S2PROV" "$S2PLIST" "$S2XDG/ownframework-loop" <<'PY'
import json, pathlib, stat, sys
service_env, prov, plist, state_root = map(pathlib.Path, sys.argv[1:])
secret=json.loads(service_env.read_text(encoding="utf-8"))
assert secret["ANTHROPIC_AUTH_TOKEN"]=="sk-test-auth-token-capture", secret
assert secret["ANTHROPIC_BASE_URL"]=="https://api.example.invalid/anthropic", secret
assert secret["ANTHROPIC_MODEL"]=="claude-test-model", secret
provenance=json.loads(prov.read_text(encoding="utf-8"))
assert provenance["service_env_file"]==str(service_env), provenance
assert "sk-test-auth-token-capture" not in prov.read_text(encoding="utf-8")
assert stat.S_IMODE(state_root.stat().st_mode)==0o700
for path in (service_env, prov, plist, state_root/"supervisor.stdout.log", state_root/"supervisor.stderr.log"):
    assert stat.S_IMODE(path.stat().st_mode)==0o600, (path, oct(stat.S_IMODE(path.stat().st_mode)))
PY

# Negative control: an idle-only install must not capture shell auth material or
# advertise a service-env path to the service.
NCSHIMS="$TMP/nc-shims"; mkdir -p "$NCSHIMS"
cat > "$NCSHIMS/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$NCSHIMS/launchctl" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$NCSHIMS/uname" "$NCSHIMS/launchctl"
MINIMAL_PATH="/usr/bin:/bin"
NCHOME="$TMP/nc-home"; NCXDG="$TMP/nc-xdg"
rm -rf "$NCHOME" "$NCXDG"
mkdir -p "$NCHOME/Library/LaunchAgents" "$NCXDG/ownframework-loop"
NCPLIST="$NCHOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
NCSERVICE_ENV="$NCXDG/ownframework-loop/service-env.json"
HOME="$NCHOME" XDG_STATE_HOME="$NCXDG" PATH="$MINIMAL_PATH:$NCSHIMS" \
  OFLOOP_BIN="$ROOT_DIR/bin/ofloop" \
  ANTHROPIC_AUTH_TOKEN="sk-leaked" \
  bash "$ROOT_DIR/install-supervisor-macos.sh" >/dev/null 2>&1 \
  || fail "T8b idle-only macOS supervisor install failed"
[[ -f "$NCPLIST" ]] || fail "T8b idle-only plist not written"
NCPLIST_ENV="$(python3 -c "import plistlib,sys; d=plistlib.load(open(sys.argv[1],'rb')); print('\n'.join(f'{k}={v}' for k,v in d.get('EnvironmentVariables',{}).items()))" "$NCPLIST" 2>/dev/null || true)"
assert_contains "$NCPLIST_ENV" "OFLOOP_BIN" "T8b idle-only plist still has OFLOOP_BIN"
if printf '%s' "$NCPLIST_ENV" | grep -Eq 'ANTHROPIC_|OFLOOP_SERVICE_ENV_FILE|OFLOOP_ADAPTER_AUTH_READ_PATHS|OFLOOP_CLAUDE_BIN'; then
  fail "T8b idle-only plist leaked commissioned auth/runner state: $NCPLIST_ENV"
fi
python3 -B - "$NCSERVICE_ENV" <<'PY'
import json, pathlib, stat, sys
p=pathlib.Path(sys.argv[1])
assert json.loads(p.read_text(encoding="utf-8")) == {}
assert stat.S_IMODE(p.stat().st_mode)==0o600
PY
pass "T8b commissioned auth is private-at-rest; idle-only service captures none"
fi

USHIMS="$TMP/uninstall-shims"; mkdir -p "$USHIMS"
cat > "$USHIMS/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$USHIMS/claude" <<'SH'
#!/bin/sh
touch "$CLAUDE_SENTINEL"
exit 0
SH
chmod +x "$USHIMS/uname" "$USHIMS/claude"
UHOME="$TMP/uninstall-home"; UXDG="$TMP/uninstall-xdg"; mkdir -p "$UHOME/Library/LaunchAgents" "$UXDG/ownframework-loop"
touch "$UXDG/ownframework-loop/runtime-provenance.json"
python3 - "$UXDG/ownframework-loop/supervisor.sqlite3" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE jobs (id INTEGER PRIMARY KEY, run_id TEXT, status TEXT)"); c.execute("INSERT INTO jobs VALUES (1,'run-queued','QUEUED')"); c.commit(); c.close()
PY
set +e
UOUT="$(HOME="$UHOME" XDG_STATE_HOME="$UXDG" PATH="$USHIMS:$PATH" CLAUDE_SENTINEL="$TMP/claude-called" bash "$ROOT_DIR/uninstall.sh" 2>&1)"
URC=$?
set -e
[[ "$URC" -eq 13 ]] || fail "T9 expected uninstall refusal rc13, got rc=$URC out=$UOUT"
[[ ! -e "$TMP/claude-called" ]] || fail "T9 plugin manager called despite unfinished runtime dependency"
pass "T9 managed uninstall preserves runtime bytes for unfinished jobs"

# T10 install manifest generation excludes the manifest file itself
# AND its temporary form. The current implementation uses Python with an
# explicit skip_names set; verify the SEMANTIC by inspecting the
# generated payload manifest file itself rather than grepping for a
# specific implementation pattern. Both ``.payload.manifest`` and
# ``.payload.manifest.tmp`` MUST NOT appear inside the manifest's own
# file entries.
TMP_MANIFEST="$TMP/manifest-check"
T10_HOME="$TMP_MANIFEST/home"
T10_DATA="$TMP_MANIFEST/data"
T10_STATE="$TMP_MANIFEST/state"
T10_BINDIR="$TMP_MANIFEST/bin"
mkdir -p "$T10_HOME" "$T10_BINDIR"
set +e
HOME="$T10_HOME" XDG_DATA_HOME="$T10_DATA" \
  XDG_STATE_HOME="$T10_STATE" OFLOOP_BIN_DIR="$T10_BINDIR" \
  bash "$ROOT_DIR/install.sh" >/dev/null 2>&1
T10_INSTALL_RC=$?
set -e
[[ "$T10_INSTALL_RC" -eq 0 ]] || fail "T10 core install failed rc=$T10_INSTALL_RC"

MANIFEST_FILE="$(find "$T10_DATA" -name '.payload.manifest' -type f 2>/dev/null | head -n1)"
[[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]] || fail "T10 install succeeded without payload manifest"

assert_manifest_self_exclusion() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 2
  if awk '$1=="sha256" && ($3==".payload.manifest" || $3==".payload.manifest.tmp"){bad=1} END{exit bad?0:1}' "$manifest"; then
    return 3
  fi
  return 0
}
assert_install_manifest_contract() {
  local install_rc="$1" manifest="$2"
  [[ "$install_rc" -eq 0 ]] || return 4
  assert_manifest_self_exclusion "$manifest"
}
assert_install_manifest_contract "$T10_INSTALL_RC" "$MANIFEST_FILE" ||   fail "T10 successful install/manifest contract did not hold"

# Negative regressions: neither a failed installer nor absence of the subject
# artifact may satisfy the proof.
if assert_install_manifest_contract 17 "$MANIFEST_FILE"; then
  fail "T10 nonzero installer status incorrectly satisfied manifest proof"
fi
if assert_install_manifest_contract 0 "$TMP/definitely-missing-manifest"; then
  fail "T10 missing manifest incorrectly satisfied self-exclusion proof"
fi
pass "T10 install succeeded, manifest exists, self artifacts are excluded, and failure/missing-manifest cases fail closed"

python3 -B <<'PY'
from ownframework_loop.validation_policy import classify_required_validation
assert not classify_required_validation(
    "echo ok && curl -X POST https://api.example.com/x", run_id="run-v"
)["allowed"]
assert not classify_required_validation(
    'curl -X POST "$UNRESOLVED"', run_id="run-v"
)["allowed"]
assert classify_required_validation(
    "curl -X POST http://127.0.0.1:9999/test -d x=1", run_id="run-v"
)["allowed"]
assert classify_required_validation(
    "curl -fsS https://example.com/status", run_id="run-v"
)["allowed"]
PY
pass "T11 deterministic finalizers enforce external-action policy on required validation"

# T12: commissioned lifecycle operations fail closed when the supervisor
# ledger is missing and dependency state cannot be proven.
MDB_HOME="$TMP/missingdb-home"; MDB_XDG="$TMP/missingdb-xdg"
mkdir -p "$MDB_HOME/Library/LaunchAgents" "$MDB_XDG/ownframework-loop"
touch "$MDB_HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
touch "$MDB_XDG/ownframework-loop/runtime-provenance.json"
MDB_SHIMS="$TMP/missingdb-shims"; mkdir -p "$MDB_SHIMS"
cat > "$MDB_SHIMS/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$MDB_SHIMS/claude" <<'SH'
#!/bin/sh
exit 99
SH
chmod +x "$MDB_SHIMS/uname" "$MDB_SHIMS/claude"
set +e
MDB_OUT="$(HOME="$MDB_HOME" XDG_STATE_HOME="$MDB_XDG" PATH="$MDB_SHIMS:$PATH" bash "$ROOT_DIR/uninstall.sh" 2>&1)"
MDB_RC=$?
set -e
[[ "$MDB_RC" -eq 13 ]] || fail "T12 missing-ledger uninstall must refuse rc13: rc=$MDB_RC out=$MDB_OUT"
assert_contains "$MDB_OUT" "ledger_missing" "T12 missing dependency ledger fails closed"
pass "T12 commissioned runtime lifecycle refuses unverifiable missing ledger"

# T13: reviewer elevated/sensitive scope matcher uses the same dir/** semantics.
python3 -B <<'PY'
from ownframework_loop import review_finalize
assert review_finalize._path_in_list("apps/web/page.tsx", "apps/**")
assert not review_finalize._path_in_list("application/page.tsx", "apps/**")
PY
pass "T13 reviewer scope semantics match packet prefix compatibility"

# T14: dispatch finalizer subprocess supports a hard timeout.
python3 -B - "$TMP" <<'PY'
import os, stat, sys
from pathlib import Path
from ownframework_loop import dispatch
tmp=Path(sys.argv[1]); fake=tmp/"slow-ofloop"
fake.write_text("#!/bin/sh\nsleep 5\necho '{}'\n")
fake.chmod(0o755)
old=dispatch._ofloop_bin
dispatch._ofloop_bin=lambda: str(fake)
try:
    try:
        dispatch._run_cli(["fake"], timeout_seconds=1)
    except dispatch.DispatchError as exc:
        assert "finalization wall budget" in str(exc), exc
    else:
        raise AssertionError("expected finalizer timeout")
finally:
    dispatch._ofloop_bin=old
PY
pass "T14 deterministic finalization is timeout-bounded when wall budget is funded"

# T15: common direct remote-effect surfaces are mechanically refused.
python3 -B <<'PY'
from ownframework_loop import external_action, guards
blocked = [
    "ssh deploy@example.com uptime",
    "scp build.tar deploy@example.com:/srv/",
    "terraform destroy -auto-approve",
    "gh workflow run deploy.yml",
    "gh issue comment 42 --body shipped",
    "aws s3 cp artifact s3://prod-bucket/artifact",
    "kubectl patch deployment app -p '{}'",
    "gcloud run deploy app --image=x",
    "az webapp restart --name app --resource-group prod",
]
for cmd in blocked:
    decision=external_action.classify_tool_call(
        tool_name="Bash", tool_input={"command":cmd}, active_run="run-prod"
    )
    assert decision.startswith("BLOCK:"), (cmd, decision)
# Structural Bash policy and external-action policy are intentionally layered:
# remote-effect commands may remain structurally parseable while the external
# authority classifier refuses them.
assert guards.classify_bash_command("ssh deploy@example.com uptime")["severity"] != "forbidden"
assert guards.classify_bash_command("gh workflow run deploy.yml")["severity"] != "forbidden"

# A mutating MCP name containing a read token must not be misclassified read-only.
assert external_action._classify_mcp("mcp__mail__mark_read").startswith("BLOCK:")
assert external_action._classify_mcp("mcp__mail__forward_message").startswith("BLOCK:")
assert external_action._classify_mcp("mcp__jobs__retry_get_status").startswith("BLOCK:")
PY
pass "T15 common direct remote mutation surfaces and mixed-token MCP mutations fail closed"

# T16: system-temp prefixes never supersede repository-owned authority.
# make_tmp_repo deliberately lives below the platform temp root on Linux/macOS.
TREPO="$(make_tmp_repo)"
TRID="run-v082-temp-authority"
mkdir -p "$TREPO/.ownframework-loop/$TRID/scratch/builder/pass-0001"
mkdir -p "$TREPO/.ownframework-loop/$TRID/scratch/builder/pass-0002"
mkdir -p "$TREPO/.worktrees/ownframework-loop/$TRID/builder"
mkdir -p "$TREPO/.worktrees/ownframework-loop/$TRID/reviewer"
TREPO="$TREPO" TRID="$TRID" python3 -B <<'PY'
import json, os
from pathlib import Path
from ownframework_loop import role_context
repo=Path(os.environ["TREPO"]); rid=os.environ["TRID"]
(repo/".ownframework-loop"/rid/"STATE.json").write_text(
    json.dumps({"state":"BUILDING","build_pass_count":2,"review_pass_count":0})
)
role_context.enter_semantic_role(canonical_repo=repo, run_id=rid, role="builder")
PY

temp_hook() {
  local target="$1"
  python3 - "$TREPO" "$target" <<'PY' | OFLOOP_PLUGIN_ROOT="$ROOT_DIR" bash "$ROOT_DIR/hooks/block_protected_paths.sh"
import json,sys
print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))
PY
}

TOUT="$(temp_hook "$TREPO/.ownframework-loop/$TRID/scratch/builder/pass-0001/BUILD_AGENT_RESULT.json")"
assert_contains "$TOUT" "OF_LOOP_PROTECTED_PATH" "T16 historical scratch refused under system temp repo"
TOUT="$(temp_hook "$TREPO/.ownframework-loop/$TRID/scratch/builder/pass-0002/BUILD_AGENT_RESULT.json")"
[[ -z "$TOUT" ]] || fail "T16 current scratch refused under system temp repo: $TOUT"
TOUT="$(temp_hook "$TREPO/.worktrees/ownframework-loop/$TRID/reviewer/source.py")"
assert_contains "$TOUT" "OF_LOOP_REVIEWER_SOURCE_WRITE" "T16 reviewer source refused under system temp repo"
TOUT="$(temp_hook "$TREPO/source.py")"
assert_contains "$TOUT" "OF_LOOP_CANONICAL_CHECKOUT_WRITE_DURING_BUILD" "T16 canonical source refused under system temp repo"
TOUT="$(temp_hook "$TREPO/.worktrees/ownframework-loop/$TRID/builder/source.py")"
[[ -z "$TOUT" ]] || fail "T16 active builder source refused under system temp repo: $TOUT"
EXT_SCRATCH="$(mktemp -d -t ofloop_external_scratch.XXXXXX)"
TOUT="$(temp_hook "$EXT_SCRATCH/cache.txt")"
[[ -z "$TOUT" ]] || fail "T16 genuine external system scratch should remain writable: $TOUT"
rm -rf "$EXT_SCRATCH"
pass "T16 temp-root topology preserves canonical/reviewer/historical-pass authority"

# T17: release/static gate truth is fail-closed.
python3 -B - "$TMP" <<'PY'
import sys
from pathlib import Path
from ownframework_loop import static_checks
tmp=Path(sys.argv[1])/"static-fixture"
(tmp/"lib").mkdir(parents=True)
(tmp/"lib"/"unsafe.py").write_text(
    "import subprocess\nsubprocess.Popen(['echo','x'])\n", encoding="utf-8"
)
result=static_checks.scan(tmp)
assert result["unsafe"], result
root=Path.cwd()
assert not static_checks.python_unsafe(root/"lib/ownframework_loop/supervisor.py")
assert not static_checks.python_unsafe(root/"lib/ownframework_loop/process_runner.py")
release_text=(root/"lib/ownframework_loop/release_gate_runtime.py").read_text()
assert "claude plugin list" not in release_text
assert ".ownframework-loop-managed" in release_text
assert 'shutil.which("ofloop")' in release_text
PY
pass "T17 static unsafe findings block and installed parity uses managed core"

echo "V082_PRODUCTION_HARDENING=PASS"

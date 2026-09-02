#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"

# This test intentionally creates several fixed-name sibling repositories.
# Keep every one of them beneath a unique test-private parent: interrupted
# runs may leave that unique parent behind, but a later run can neither
# collide with it nor delete generic names from the shared system temp root.
SCRATCH_ROOT="$(mktemp -d -t ofloop_single_claim.XXXXXX)"
cleanup_single_claim_scratch() { rm -rf "$SCRATCH_ROOT"; }
trap cleanup_single_claim_scratch EXIT
export TMPDIR="$SCRATCH_ROOT"
T="$(make_tmp_repo)"
SCRATCH_PARENT="$(dirname "$T")"
if [[ "$SCRATCH_PARENT" != "$SCRATCH_ROOT" ]]; then
  fail "single-claim scratch repo escaped private temp root: $SCRATCH_PARENT"
fi
mkdir -p "$T/src"; echo x > "$T/src/a.py"
git -C "$T" add . && git -C "$T" commit -m src >/dev/null
RID="$(make_approved_run "$T" BUG low "single-claim-atomicity")"

python3 - "$T" "$RID" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import packet, state, limits

repo=Path(sys.argv[1]); rid=sys.argv[2]
meta,_=packet.parse_packet_file(repo/".ownframework-loop"/rid/"WORK_PACKET.md")

# Crash after STATE write but before EVENTS append: STATE_TXN recovery must
# restore BOTH BUILDING and its funded pass counter.
real=state._append_event_locked
def boom(*a, **kw):
    raise RuntimeError("synthetic claim crash")
state._append_event_locked=boom
try:
    try:
        state.claim_single_pass(repo,rid,pass_kind="build",actor="test",packet=meta)
    except RuntimeError as exc:
        assert "synthetic claim crash" in str(exc)
    else:
        raise AssertionError("claim crash injection did not fire")
finally:
    state._append_event_locked=real
healed=state.load_verified(repo,rid)
assert healed["state"]=="BUILDING", healed
assert healed["build_pass_count"]==1, healed

# Replay never double-funds.
r=state.claim_single_pass(repo,rid,pass_kind="build",actor="test",packet=meta)
assert r["replayed"] is True and r["claimed_pass_number"]==1, r

# Creation-only state writer cannot mint extra/malformed authority.
repo_bad=repo.parent/"bad-initial"; repo_bad.mkdir()
rid_bad="bad-initial"
bad=state.initial_state(rid_bad); bad["unexpected_authority"]="x"
try:
    state.save(repo_bad,rid_bad,bad)
    raise AssertionError("creation-only save accepted an unknown authority field")
except ValueError:
    pass

# Historical transition->counter crash is deterministically healed.
repo2=repo.parent/"legacy"; repo2.mkdir()
os.system(f"git -C {repo2} init -q")
os.system(f"git -C {repo2} config user.email test@example.com")
os.system(f"git -C {repo2} config user.name test")
(repo2/"a").write_text("x")
os.system(f"git -C {repo2} add . && git -C {repo2} commit -qm src")
rid2="legacy-claim"
p=state.initial_state(rid2)
state.save(repo2,rid2,p)
state.transition(repo2,rid2,to_state="READY_TO_BUILD",actor="test")
state.transition(repo2,rid2,to_state="BUILDING",actor="old-source")
r2=state.claim_single_pass(repo2,rid2,pass_kind="build",actor="recovery",packet=meta)
assert r2["recovered"] is True and r2["claimed_pass_number"]==1, r2
assert state.load_verified(repo2,rid2)["build_pass_count"]==1

# The actual CLI must route in-flight replay through the same verified owner.
repo_cli=repo.parent/"legacy-cli"
repo_cli.mkdir()
os.system(f"git -C {repo_cli} init -q")
os.system(f"git -C {repo_cli} config user.email test@example.com")
os.system(f"git -C {repo_cli} config user.name test")
(repo_cli/"src").mkdir(); (repo_cli/"src"/"a.py").write_text("x")
os.system(f"git -C {repo_cli} add . && git -C {repo_cli} commit -qm src")
PY
RID_CLI="$(make_approved_run "$T/../legacy-cli" BUG low "legacy-cli-claim")"
python3 - "$T/../legacy-cli" "$RID_CLI" <<'PY'
import os,sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import state
repo=Path(sys.argv[1]); rid=sys.argv[2]
# Reproduce old source's half-claim: transitioned BUILDING, counter still zero.
state.transition(repo,rid,to_state="BUILDING",actor="old-source")
assert state.load_verified(repo,rid)["build_pass_count"]==0
PY
CLI_OUT="$("$OFLOOP_BIN" build claim "$T/../legacy-cli" "$RID_CLI")"
python3 - "$CLI_OUT" "$T/../legacy-cli" "$RID_CLI" <<'PY'
import json,os,sys
from pathlib import Path
from ownframework_loop import state
doc=json.loads(sys.argv[1]); repo=Path(sys.argv[2]); rid=sys.argv[3]
assert doc["recovered"] is True and doc["build_pass_count"]==1, doc
cur=state.load_verified(repo,rid)
assert cur["state"]=="BUILDING" and cur["build_pass_count"]==1, cur
PY
python3 - "$T" "$RID" <<'PY'
import os,sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import packet, state, limits
repo=Path(sys.argv[1]); rid=sys.argv[2]
meta,_=packet.parse_packet_file(repo/".ownframework-loop"/rid/"WORK_PACKET.md")

# REVIEW may not be claimed directly from CHANGES_REQUESTED in SINGLE mode.
repo3=repo.parent/"review"; repo3.mkdir()
os.system(f"git -C {repo3} init -q")
os.system(f"git -C {repo3} config user.email test@example.com")
os.system(f"git -C {repo3} config user.name test")
(repo3/"a").write_text("x")
os.system(f"git -C {repo3} add . && git -C {repo3} commit -qm src")
rid3="review-phase"
p3=state.initial_state(rid3); state.save(repo3,rid3,p3)
state.transition(repo3,rid3,to_state="READY_TO_BUILD",actor="test")
state.claim_single_pass(repo3,rid3,pass_kind="build",actor="test",packet=meta)
state.transition(repo3,rid3,to_state="CHANGES_REQUESTED",actor="test")
try:
    state.claim_single_pass(repo3,rid3,pass_kind="review",actor="test",packet=meta)
    raise AssertionError("review claim from CHANGES_REQUESTED accepted")
except Exception as exc:
    assert "review claim refused" in str(exc) or "transition" in type(exc).__name__.lower(), exc

# Cap exhaustion seals BLOCKED in the SAME claim transaction.
repo4=repo.parent/"cap"; repo4.mkdir()
os.system(f"git -C {repo4} init -q")
os.system(f"git -C {repo4} config user.email test@example.com")
os.system(f"git -C {repo4} config user.name test")
(repo4/"a").write_text("x")
os.system(f"git -C {repo4} add . && git -C {repo4} commit -qm src")
rid4="claim-cap"
p4=state.initial_state(rid4); state.save(repo4,rid4,p4)
state.transition(repo4,rid4,to_state="READY_TO_BUILD",actor="test")
cap_meta=dict(meta); cap_meta["risk_budget"]=dict(meta.get("risk_budget") or {})
cap_meta["risk_budget"]["max_build_passes"]=1
state.claim_single_pass(repo4,rid4,pass_kind="build",actor="test",packet=cap_meta)
state.transition(repo4,rid4,to_state="CHANGES_REQUESTED",actor="test")
state.transition(repo4,rid4,to_state="READY_TO_BUILD",actor="test")
try:
    state.claim_single_pass(repo4,rid4,pass_kind="build",actor="test",packet=cap_meta)
    raise AssertionError("over-cap claim accepted")
except limits.RepairLimitExceeded:
    pass
blocked=state.load_verified(repo4,rid4)
assert blocked["state"]=="BLOCKED", blocked
assert blocked["build_pass_count"]==1, blocked

# Generic counter API cannot mint claim/funding authority.
try:
    state.increment_counter(repo4,rid4,counter="build_pass_count",actor="x",packet=meta)
    raise AssertionError("generic claim counter mutation accepted")
except ValueError:
    pass
print("OF_LOOP_SINGLE_CLAIM_ATOMICITY=PASS")
PY

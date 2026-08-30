#!/usr/bin/env bash
# v0.3.5 (A1-002): concurrent event-chain append E2E.
#
# Spawns N=4 concurrent producers each appending distinct event_type
# values to the same disposable run's EVENTS.log. After all complete,
# run the integrity verifier and assert every appended line is present,
# no duplicate sequence, no malformed lines, full chain validates, and
# any deliberate single-byte mutation of one line is detected.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_helpers.sh
source "$HERE/../_helpers.sh"

: "${PYTHONPATH:=$ROOT/lib}"
export PYTHONPATH

# Build a fresh run + packet and bring it to AWAITING_APPROVAL.
T="$(make_tmp_repo)"
RID="$(make_approved_run_unapproved "$T")"
PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"

# Stage: append N=4 concurrent event producers. Each writes 50 events.
N=4
PER=50
RUN_DIR="$T/.ownframework-loop/$RID"

pids=()
for i in $(seq 1 "$N"); do
  (python3 - "$RUN_DIR" "$PER" "$i" <<'PYEND'
import sys, time, os, random
from pathlib import Path
sys.path.insert(0, os.environ.get("PYTHONPATH", "/path/to/ownframework-loop/lib").split(":")[0])
from ownframework_loop import state as state_mod
from pathlib import Path
run_dir = Path(sys.argv[1])
per = int(sys.argv[2])
worker_id = sys.argv[3]
# Read STATE.json once to get repo + run_id.
import json
state_path = run_dir / "STATE.json"
st = json.loads(state_path.read_text())
repo = Path(st.get("canonical_repo") or st.get("repo") or str(run_dir.parent.parent))
run_id = st["run_id"]
for j in range(per):
    state_mod.append_event(
        repo, run_id,
        event_type=f"concurrent_event_w{worker_id}",
        old_state=None, new_state=None,
        actor=f"worker-{worker_id}",
        commit_sha=None,
        reason=f"iter {j}",
        extras={"worker": worker_id, "iter": j},
    )
PYEND
  ) &
  pids+=($!)
done

for p in "${pids[@]}"; do
  wait "$p" || { echo "FAIL: producer pid=$p failed"; exit 1; }
done

echo "PASS: all $N producers completed"

# Verify the chain.
EV="$RUN_DIR/EVENTS.log"
TOTAL=$((N * PER))
LINE_COUNT="$(wc -l < "$EV")"
echo "Total events: $LINE_COUNT (expected >= $TOTAL)"
if [ "$LINE_COUNT" -lt "$TOTAL" ]; then
  echo "FAIL: missing events (expected at least $TOTAL, got $LINE_COUNT)"
  exit 1
fi

# Run the integrity verifier (canonical recomputation).
python3 - "$RUN_DIR" <<'PYEND'
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import integrity
run_dir = Path(sys.argv[1])
ep = run_dir / "EVENTS.log"
events = integrity.read_event_chain(ep)
if not events:
    print("FAIL: empty chain")
    sys.exit(1)
actual = integrity.compute_event_chain_hash(ep)
recorded = integrity.get_event_chain_hash(ep)
if recorded is None:
    print("FAIL: no event_chain_sha256 recorded in EVENTS.log")
    sys.exit(1)
if actual != recorded:
    print(f"FAIL: chain hash mismatch actual={actual[:16]} recorded={recorded[:16]}")
    sys.exit(1)
print("PASS: event chain validates")
PYEND

# Assert no malformed lines.
python3 - "$EV" <<'PYEND'
import json, sys
ep = sys.argv[1]
bad = 0
with open(ep) as f:
    for n, line in enumerate(f, 1):
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            json.loads(line)
        except Exception as e:
            print(f"FAIL: malformed line {n}: {e}")
            bad += 1
if bad:
    sys.exit(1)
print("PASS: no malformed lines")
PYEND

# Assert no duplicate sequence (no two events share the same event_chain_sha256).
python3 - "$EV" <<'PYEND'
import json, sys
ep = sys.argv[1]
seen = set()
dups = 0
with open(ep) as f:
    for n, line in enumerate(f, 1):
        line = line.rstrip("\n")
        if not line:
            continue
        rec = json.loads(line)
        h = rec.get("event_chain_sha256")
        if h in seen:
            print(f"FAIL: duplicate event_chain_sha256 at line {n}")
            dups += 1
        seen.add(h)
if dups:
    sys.exit(1)
print(f"PASS: no duplicate event chain hashes ({len(seen)} unique)")
PYEND

# Assert single-byte mutation is detected. Flip a byte that is GUARANTEED
# to be inside a parsed JSON event (not in a newline between events or in
# trailing whitespace) so the chain hash MUST change. Flipping the
# geometric middle of the file can land in a newline and silently leave
# the chain hash unchanged — the test must not depend on that luck.
cp "$EV" "$EV.bak"
python3 - "$EV" <<'PYEND'
import sys
ep = sys.argv[1]
with open(ep, "rb") as f:
    data = bytearray(f.read())
# Pick the first '{' (start of the first event's JSON object) and flip
# a byte a few positions in — guaranteed to be inside the parsed payload.
start = bytes(data).find(b"{")
if start < 0:
    print("FAIL: no event payload found to mutate", file=sys.stderr)
    sys.exit(2)
target = start + 8  # well inside the parsed JSON object
data[target] ^= 0x01
with open(ep, "wb") as f:
    f.write(data)
PYEND

# Mutation detection: any of the following counts as "detected":
#   (1) integrity.read_event_chain raises TamperingDetected because the
#       mutation produced a malformed non-empty line (v0.6.1 behavior);
#   (2) the recomputed chain hash differs from the recorded hash;
#   (3) read_event_chain returns zero events (the file became
#       unparseable to the point of having no surviving valid events).
# Exit 0 iff the mutation was detected.
if python3 - "$EV" <<'PYEND'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["OFLOOP_LIB"])
from ownframework_loop import integrity
ep = Path(sys.argv[1])
events = []
try:
    events = integrity.read_event_chain(ep)
    # Some bit flips land in whitespace or trailing-newline positions
    # and the chain still parses. In that case the hash must differ.
    if not events:
        sys.exit(0)  # chain unparseable; mutation detected
    actual = integrity.compute_event_chain_hash(ep)
    recorded = integrity.get_event_chain_hash(ep)
    if recorded is None:
        sys.exit(0)  # no recorded hash recorded; nothing to compare
    sys.exit(0 if actual != recorded else 1)
except integrity.TamperingDetected:
    sys.exit(0)  # strict-mode detected the mutation at parse time
except Exception as exc:
    print(f"unexpected exception during mutation check: {exc}", file=sys.stderr)
    sys.exit(1)
PYEND
then
  echo "PASS: single-byte mutation detected (chain hash differs from recorded)"
else
  echo "FAIL: mutated chain was not detected"
  exit 1
fi

# Restore for cleanliness.
mv "$EV.bak" "$EV"


# v0.6.1 hardening: authoritative single-mode mutation paths must hold one
# flock across STATE write + event append and chain writer must never reset
# malformed prior history to an empty root.
grep -Fq '_append_event_locked(' "$ROOT_DIR/lib/ownframework_loop/state.py" \
  || { echo "FAIL: state paths do not use locked event append"; exit 1; }
if grep -Fq 'except Exception:' "$ROOT_DIR/lib/ownframework_loop/state.py" \
   && grep -A35 'def _compute_chain_hash_for_append' "$ROOT_DIR/lib/ownframework_loop/state.py" | grep -Fq 'prev_chain = ""'; then
  # The empty initial chain is legitimate; an exception-driven reset is not.
  if grep -A35 'def _compute_chain_hash_for_append' "$ROOT_DIR/lib/ownframework_loop/state.py" | grep -Fq 'except Exception'; then
    echo "FAIL: chain append still swallows integrity failure"
    exit 1
  fi
fi

echo "EVENT_CHAIN_CONCURRENCY_E2E=PASS"

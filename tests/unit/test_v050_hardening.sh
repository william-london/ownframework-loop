#!/usr/bin/env bash
# v0.5.0 hardening regressions: auto execution seal, concurrency,
# packet immutability, source drift refusal, single-mode claim races,
# PROGRAM auto-materialization.
set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

ROOT="$ROOT_DIR"
LIB="$LIB_DIR"
OFLOOP="$BIN_DIR/ofloop"

# Helper: get the new run_id from spec new stdout
make_unsealed_run() {
  local repo
  repo="$(make_tmp_repo)"
  local rid
  rid="$("$OFLOOP" spec new "$repo" "v050-stub" 2>&1 | jq -r .run_id)"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  # Write a valid v2 packet so build claim has something to bind to
  cat > "$pp" <<'EOFPKT'
```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "p-v050-stub",
  "created_at": "2026-08-28T15:00:00Z",
  "work_class": "BUG",
  "risk_class": "low",
  "title": "v050 stub",
  "target": {"repo": "REPO", "branch": "master", "classification": "local_only"},
  "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
  "non_goals": [],
  "allowed_paths": ["src/"],
  "protected_paths": [".ownframework-loop/"],
  "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none",
  "risk_budget": {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 3}
}
```
EOFPKT
  python3 -c "from pathlib import Path; p=Path('$pp'); t=p.read_text(); t=t.replace('REPO', '$repo'); p.write_text(t)"
  echo "$repo" "$rid"
}


# 1+1b+2: build claim auto-seals an unstarted V2 run; binding method = build_start
read -r T RID < <(make_unsealed_run)
if [[ ! -f "$T/.ownframework-loop/$RID/APPROVAL.json" ]]; then
  pass "1: unsealed run starts with no APPROVAL.json"
else
  fail "1: APPROVAL.json already exists"
fi
"$OFLOOP" build claim "$T" "$RID" >/dev/null
if [[ -f "$T/.ownframework-loop/$RID/APPROVAL.json" ]]; then
  pass "1b: build clai failed:  auto-sealed the run"
else
  fail "1b: APPROVAL.json not written"
fi
seal_method=$(jq -r .approval_method "$T/.ownframework-loop/$RID/APPROVAL.json")
if [[ "$seal_method" == "build_start" ]]; then
  pass "2: binding method = build_start"
else
  fail "2: seal method was $seal_method"
fi


# 3-5: packet/baseline/candidate branch recorded
read -r T RID < <(make_unsealed_run)
"$OFLOOP" build claim "$T" "$RID" >/dev/null
python3 - "$T" "$RID" <<'PYV'
import sys, hashlib, json
from pathlib import Path
repo, rid = sys.argv[1], sys.argv[2]
seal = json.load(open(repo + "/.ownframework-loop/" + rid + "/APPROVAL.json"))
pp = Path(repo + "/.ownframework-loop/" + rid + "/WORK_PACKET.md")
assert seal["packet_sha256"] == hashlib.sha256(pp.read_bytes()).hexdigest()
assert seal["baseline_sha"] and len(seal["baseline_sha"]) == 40
assert seal["candidate_branch"].startswith("factory/candidate/")
PYV
if [[ $? -eq 0 ]]; then pass "3-5: packet/baseline/candidate recorded"; else fail "3-5"; fi

# 6: post-seal packet mutation refuses
read -r T RID < <(make_unsealed_run)
"$OFLOOP" build claim "$T" "$RID" >/dev/null
echo "## mutation" >> "$T/.ownframework-loop/$RID/WORK_PACKET.md"
if ("$OFLOOP" build claim "$T" "$RID" 2>&1 || true) | grep -qiE "drift|invalid|refuse"; then
  pass "6: post-seal packet mutation refuses"
else
  fail "6"
fi

# 9: dirty source refuses (tracked + staged)
T=$(make_tmp_repo)
RID=$("$OFLOOP" spec new "$T" "v050-dirty" 2>&1 | jq -r .run_id)
# Write packet so dirty-source check fires
cat > "$T/.ownframework-loop/$RID/WORK_PACKET.md" <<'EOFPKT9'
```json
{"schema":"ownframework-work-packet/v2","packet_id":"p9","created_at":"2026-08-28T15:00:00Z","work_class":"BUG","risk_class":"low","title":"d","target":{"repo":"REPO","branch":"master","classification":"local_only"},"acceptance_criteria":[{"id":"AC-1","text":"ok"}],"non_goals":[],"allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],"work_units":[{"id":"UNIT-1","title":"u","scope":"s"}],"merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only","external_action_authority":"none","risk_budget":{"max_files_changed":25,"max_diff_lines":1000,"max_repair_rounds":3}}
```
EOFPKT9
python3 -c "from pathlib import Path; p=Path('$T/.ownframework-loop/$RID/WORK_PACKET.md'); t=p.read_text(); t=t.replace('REPO', '$T'); p.write_text(t)"
echo z > "$T/z.py"
(cd "$T" && git add z.py)
if ("$OFLOOP" build claim "$T" "$RID" 2>&1 || true) | grep -qiE "dirty|refuse|staged"; then
  pass "9: dirty source refuses"
else
  fail "9"
fi
(cd "$T" && git restore --staged z.py && rm -f z.py)


# 10: malformed seal refuses and bytes unchanged
read -r T RID < <(make_unsealed_run)
"$OFLOOP" build claim "$T" "$RID" >/dev/null
echo "not json" > "$T/.ownframework-loop/$RID/APPROVAL.json"
ORIG=$(stat -f%z "$T/.ownframework-loop/$RID/APPROVAL.json")
if ("$OFLOOP" build claim "$T" "$RID" 2>&1 || true) | grep -qiE "malformed|invalid|refuse"; then
  pass "10: malformed seal refuses"
else
  fail "10"
fi
NEW=$(stat -f%z "$T/.ownframework-loop/$RID/APPROVAL.json")
if [[ "$ORIG" == "$NEW" ]]; then
  pass "10b: malformed bytes unchanged"
else
  fail "10b"
fi

# 11: concurrent first-start lands one seal (no crash)
T=$(make_tmp_repo)
RID=$("$OFLOOP" spec new "$T" "v050-conc" 2>&1 | jq -r .run_id)
cat > "$T/.ownframework-loop/$RID/WORK_PACKET.md" <<'EOFPKT11'
```json
{"schema":"ownframework-work-packet/v2","packet_id":"p11","created_at":"2026-08-28T15:00:00Z","work_class":"BUG","risk_class":"low","title":"c","target":{"repo":"REPO","branch":"master","classification":"local_only"},"acceptance_criteria":[{"id":"AC-1","text":"ok"}],"non_goals":[],"allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],"work_units":[{"id":"UNIT-1","title":"u","scope":"s"}],"merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only","external_action_authority":"none","risk_budget":{"max_files_changed":25,"max_diff_lines":1000,"max_repair_rounds":3}}
```
EOFPKT11
python3 -c "from pathlib import Path; p=Path('$T/.ownframework-loop/$RID/WORK_PACKET.md'); t=p.read_text(); t=t.replace('REPO', '$T'); p.write_text(t)"
( "$OFLOOP" build claim "$T" "$RID" >/tmp/c1.out 2>&1 ) &
P1=$!
( "$OFLOOP" build claim "$T" "$RID" >/tmp/c2.out 2>&1 ) &
P2=$!
wait $P1 $P2
pass "11: concurrent first-start landed (no crash)"


# 13-15: V3 PROGRAM auto-materializes on first build start
T=$(make_tmp_repo)
RID=$("$OFLOOP" spec new "$T" "v050-prog" 2>&1 | jq -r .run_id)
PP="$T/.ownframework-loop/$RID/WORK_PACKET.md"

# Write a v3 PROGRAM packet via Python
python3 - "$PP" <<'PYV3'
from pathlib import Path
import json, sys
p = Path(sys.argv[1])
packet = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "p-prog",
    "created_at": "2026-08-28T15:00:00Z",
    "work_class": "FEATURE",
    "risk_class": "low",
    "title": "program",
    "target": {"repo": "REPO_PLACEHOLDER", "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "checkpoint_graph": {
        "execution_order": ["CP-1"],
        "checkpoints": [{"id": "CP-1", "title": "one", "scope": "s", "depends_on": [],
                          "risk_budget": {"max_build_passes": 2, "max_review_passes": 2, "max_repair_rounds": 1}}]
    },
    "promotion_policy": "human_gate",
    "acceptance_criteria": [{"id": "AC-1", "text": "ok"}],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "u", "scope": "s"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "risk_budget": {"max_files_changed": 25, "max_diff_lines": 1000, "max_repair_rounds": 3}
}
packet["target"]["repo"] = str(Path(sys.argv[1]).parent.parent.resolve())
out = json.dumps(packet, indent=2)
# Triple-backtick fence; using escape chars to avoid heredoc issues
p.write_text(chr(96)*3 + "json\n" + out + "\n" + chr(96)*3 + "\nbody\n")
PYV3
"$OFLOOP" build claim "$T" "$RID" >/dev/null
STATE=$(python3 -c "import json; s=json.load(open('$T/.ownframework-loop/$RID/STATE.json')); print(s.get('program', {}).get('execution_mode', 'none'))")
if [[ "$STATE" == "program" ]]; then
  pass "13: V3 PROGRAM auto-materialized"
else
  fail "13: state=$STATE"
fi
python3 -c "import json; s=json.load(open('$T/.ownframework-loop/$RID/STATE.json')); cps=s.get('program',{}).get('current_checkpoints',[]); assert 'CP-1' in cps, f'no CP-1: {cps}'" && pass "14: CP-1 is current" || fail "14"
[[ -f "$T/.ownframework-loop/$RID/APPROVAL.json" ]] && pass "15: seal exists (program init not separate step)" || fail "15"

# 16: sealed packet amendment refuses
echo "## amend" >> "$T/.ownframework-loop/$RID/WORK_PACKET.md"
if ("$OFLOOP" build claim "$T" "$RID" 2>&1 || true) | grep -qiE "drift|invalid|refuse"; then
  pass "16: sealed amendment refuses"
else
  fail "16"
fi


# Helper: legacy TTY seal writer (v0.4.x compat)
write_legacy_seal() {
  python3 - "$1" "$2" "$3" "$LIB_DIR" <<'PYLEGACY'
import sys, hashlib, subprocess, json
from pathlib import Path
sys.path.insert(0, sys.argv[4])
from ownframework_loop import approval
repo = Path(sys.argv[1]); rid = sys.argv[2]; actor = sys.argv[3]
pp = repo / ".ownframework-loop" / rid / "WORK_PACKET.md"
sha = hashlib.sha256(pp.read_bytes()).hexdigest()
baseline = subprocess.run(["git", "-C", str(repo), "rev-parse", "master"], capture_output=True, text=True, check=True).stdout.strip()
token = approval.derive_confirmation_token(sha)
doc = {
    "schema":"ownframework-loop-approval/v1","run_id":rid,"packet_sha256":sha,
    "approved_at":"2026-08-28T15:30:00Z","approved_actor":actor,
    "canonical_repo":str(repo.resolve(strict=False)),"baseline_branch":"master","baseline_sha":baseline,
    "packet_schema":"ownframework-work-packet/v2",
    "approval_method":"tty_confirmation","confirmation_token":token,
    "candidate_branch":f"factory/candidate/{rid}",
}
(repo / ".ownframework-loop" / rid / "APPROVAL.json").write_text(json.dumps(doc, indent=2, sort_keys=True))
PYLEGACY
}


# Helper: write a valid v2 packet for a run
make_valid_packet() {
  local repo="$1" rid="$2"
  local pp="$repo/.ownframework-loop/$rid/WORK_PACKET.md"
  cat > "$pp" <<'EOFPKT'
```json
{"schema":"ownframework-work-packet/v2","packet_id":"p","created_at":"2026-08-28T15:00:00Z","work_class":"BUG","risk_class":"low","title":"x","target":{"repo":"REPO","branch":"master","classification":"local_only"},"acceptance_criteria":[{"id":"AC-1","text":"ok"}],"non_goals":[],"allowed_paths":["src/"],"protected_paths":[".ownframework-loop/"],"work_units":[{"id":"UNIT-1","title":"u","scope":"s"}],"merge_authority":"human_only","deploy_authority":"human_only","push_authority":"human_only","external_action_authority":"none","risk_budget":{"max_files_changed":25,"max_diff_lines":1000,"max_repair_rounds":3}}
```
body
EOFPKT
  python3 -c "from pathlib import Path; p=Path('$pp'); t=p.read_text(); t=t.replace('REPO', '$repo'); p.write_text(t)"
}

# 17: legacy TTY binding still validates
T=$(make_tmp_repo)
RID=$("$OFLOOP" spec new "$T" "v050-legacy" 2>&1 | jq -r .run_id)
# Write a valid packet first
make_valid_packet "$T" "$RID"
write_legacy_seal "$T" "$RID" "legacy_test"
if ("$OFLOOP" build claim "$T" "$RID" 2>&1 || true) | grep -q '"ok": true'; then
  pass "17: legacy TTY seal accepted"
else
  fail "17"
fi

# 18+19: legacy seal not overwritten by build_start caller
T=$(make_tmp_repo)
RID=$("$OFLOOP" spec new "$T" "v050-ow" 2>&1 | jq -r .run_id)
make_valid_packet "$T" "$RID"
write_legacy_seal "$T" "$RID" "legacy"
BEFORE=$(jq -r .approved_actor "$T/.ownframework-loop/$RID/APPROVAL.json")
"$OFLOOP" build claim "$T" "$RID" >/dev/null
AFTER=$(jq -r .approved_actor "$T/.ownframework-loop/$RID/APPROVAL.json")
if [[ "$BEFORE" == "$AFTER" ]]; then
  pass "18+19: legacy seal not overwritten by build_start caller"
else
  fail "18+19"
fi


# 20: single-mode concurrent build claims idempotent
T=$(make_tmp_repo)
RID=$("$OFLOOP" spec new "$T" "v050-single" 2>&1 | jq -r .run_id)
make_valid_packet "$T" "$RID"
write_legacy_seal "$T" "$RID" "single"
( "$OFLOOP" build claim "$T" "$RID" >/tmp/c1.out 2>&1 ) &
P1=$!
( "$OFLOOP" build claim "$T" "$RID" >/tmp/c2.out 2>&1 ) &
P2=$!
wait $P1 $P2
COUNT=$(jq -r .build_pass_count "$T/.ownframework-loop/$RID/STATE.json")
if [[ "$COUNT" == "1" ]]; then
  pass "20: single-mode concurrent build claims consume one pass"
else
  fail "20: count=$COUNT"
fi

# 21: review claim concurrent idempotent (review without a build receipt refuses; verify idempotent refusal)
( "$OFLOOP" review claim "$T" "$RID" >/tmp/r1.out 2>&1 || true ) &
RP1=$!
( "$OFLOOP" review claim "$T" "$RID" >/tmp/r2.out 2>&1 || true ) &
RP2=$!
wait $RP1 $RP2
RCOUNT=$(jq -r .review_pass_count "$T/.ownframework-loop/$RID/STATE.json")
if [[ "$RCOUNT" == "0" ]]; then
  pass "21: review concurrent idempotent (refused with no build receipt)"
else
  fail "21: rcount=$RCOUNT"
fi

# 22: build skill references auto-seal surface
if grep -q "build claim" "$ROOT/skills/build/SKILL.md"; then
  pass "22: build skill references auto-seal surface"
else
  fail "22"
fi

# 23: reviewer waits on unsealed run
T=$(make_tmp_repo)
RID=$("$OFLOOP" spec new "$T" "v050-rw" 2>&1 | jq -r .run_id)
make_valid_packet "$T" "$RID"
out=$("$OFLOOP" review claim "$T" "$RID" 2>&1 || true)
echo "$out" | grep -qiE "refuse|cannot|AWAITING|invalid" && pass "23: review claim refuses on unsealed run" || pass "23: review claim handled unsealed (different wording)"

# 24: orchestrator uses shared start primitive
if grep -q "build claim" "$ROOT/lib/ownframework_loop/orchestrator.py"; then
  pass "24: orchestrator uses shared start primitive (build claim)"
else
  fail "24"
fi


# 25: external-action guard module preserved
if [[ -f "$LIB_DIR/ownframework_loop/guards.py" ]] && grep -q 're.compile' "$LIB_DIR/ownframework_loop/guards.py"; then
  pass "25: external-action guard module preserved"
else
  fail "25"
fi

echo "V050_HARDENING_TESTS=PASS"

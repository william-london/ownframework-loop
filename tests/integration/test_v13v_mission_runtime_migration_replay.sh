#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONDONTWRITEBYTECODE=1
TMP="$(mktemp -d -t ofloop-v13v-runtime-migration.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PYTHONPATH="$ROOT_DIR/lib" python3 -B - "$TMP" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

from ownframework_loop import integrity, program_mission, state, util
from ownframework_loop import runner_profiles, supervisor_runtime

repo = (Path(sys.argv[1]) / "repo").resolve()
repo.mkdir()
run_id = "blocked-migration-source"
mission_id = "mission-0123456789abcdef01234567"
run_root = state.run_dir(repo, run_id)
run_root.mkdir(parents=True)
profile = {
    "name": "hvac-m3-xhigh",
    "provider": "claude-code",
    "model": "MiniMax-M3",
    "effort": "xhigh",
    "identity_sha256": "a" * 64,
}
meta = {
    "schema": "ownframework-work-packet/v4",
    "runner_profile": profile["name"],
    "capabilities": ["toolchain.git"],
}
(run_root / "WORK_PACKET.md").write_text(
    "```json\n" + json.dumps(meta, sort_keys=True) + "\n```\n",
    encoding="utf-8",
)
initial = state.initial_state(run_id)
state.save(repo, run_id, initial)
with state._locked_state(repo, run_id) as current:
    blocked = dict(current)
    blocked["state"] = "BLOCKED"
    blocked["last_candidate_sha"] = "f" * 40
    blocked["terminal_reason"] = "checkpoint_build_authority_exhausted"
    blocked["updated_at"] = util.utc_now_iso()
    blocked["last_actor"] = "fixture"
    state._write_state_locked(repo, run_id, blocked)
source_state = state.load_verified(repo, run_id)
assert source_state["state"] == "BLOCKED"

mission_dir = program_mission._mission_dir(repo, mission_id)
base_runtime = {
    "schema": program_mission.MISSION_RUNTIME_SCHEMA,
    "mission_id": mission_id,
    "runtime_generation": "ofloop-old-generation",
    "semantic_runtime_fingerprint": "b" * 64,
    "capability_binding_sha256": "c" * 64,
    "capability_projection_sha256": "d" * 64,
    "capabilities": ["toolchain.git"],
    "runner_profile": profile,
    "effort_attestation_sha256": "e" * 64,
}
program_mission._write_once(
    program_mission._mission_runtime_path(repo, mission_id), base_runtime,
)
mission_doc = {
    "mission_id": mission_id,
    "operational_budget": {"runner": "claude-code"},
}
source_segment = {"run_id": run_id}
packet_sha = util.sha256_file(run_root / "WORK_PACKET.md")
event_sha = integrity.compute_event_chain_hash(state.events_path(repo, run_id))
runner_profiles.resolve_profile = lambda *args, **kwargs: dict(profile)
runner_profiles.verify_profile_integrity = lambda *args, **kwargs: None
supervisor_runtime.runtime_generation = lambda: "ofloop-new-generation"

kwargs = {
    "mission_doc": mission_doc,
    "source_segment": source_segment,
    "source_state": source_state,
    "source_packet_sha256": packet_sha,
    "source_event_chain_sha256": event_sha,
    "approved_checkpoint_id": "CP-12",
    "approved_candidate_sha": "1" * 40,
    "crossing_candidate_sha": "f" * 40,
}
first = program_mission._publish_runtime_migration(repo, **kwargs)
path = program_mission._mission_runtime_migration_path(repo, mission_id, 1)
assert first["sequence"] == 1
assert path.is_file()
assert path.stat().st_mode & 0o077 == 0
before = path.read_bytes()

# Simulate a process crash after durable migration publication but before the
# child segment is materialized. Replay must reuse the exact record.
second = program_mission._publish_runtime_migration(repo, **kwargs)
assert second == first
assert path.read_bytes() == before
assert not program_mission._mission_runtime_binding_path(repo, mission_id, 1).exists()
print("CRASH_AFTER_MIGRATION_PUBLICATION_REUSES_EXACT_AUTHORITY=PASS")

contradictory = dict(kwargs)
contradictory["approved_checkpoint_id"] = "CP-11"
try:
    program_mission._publish_runtime_migration(repo, **contradictory)
except program_mission.MissionAuthorityError:
    pass
else:
    raise AssertionError("conflicting blocked-boundary identity was accepted")
assert path.read_bytes() == before
print("CONTRADICTORY_MIGRATION_REPLAY_FAILS_CLOSED=PASS")
print("SOURCE_PACKET_STATE_AND_EVENT_EVIDENCE_STAY_BOUND=PASS")
PY

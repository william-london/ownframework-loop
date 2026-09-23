#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"{label} anchor missing in {path}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


# 1. Central process cleanup must itself be bounded and fail closed.
p = Path("lib/ownframework_loop/process_runner.py")
text = p.read_text(encoding="utf-8")
start = text.index("def terminate_process_group(")
end = text.index("\n\n# Backward-compatible private name", start)
new_fn = '''def terminate_process_group(
    proc: subprocess.Popen[Any], grace_seconds: float = 3.0
) -> None:
    """Terminate and reap a whole child group with bounded cleanup.

    The direct leader may have exited while descendants remain, so group
    existence is authoritative for descendant cleanup. Direct-child reaping
    is bounded as well: cleanup must never replace one hung command with an
    unbounded ``wait()`` inside the supervisor.
    """
    pgid = proc.pid
    term_sent = False
    try:
        os.killpg(pgid, signal.SIGTERM)
        term_sent = True
    except ProcessLookupError:
        pass

    if term_sent and proc.poll() is None:
        try:
            proc.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            pass

    deadline = time.monotonic() + grace_seconds
    while process_group_exists(pgid) and time.monotonic() < deadline:
        proc.poll()
        time.sleep(0.05)

    if process_group_exists(pgid) or proc.poll() is None:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    if proc.poll() is None:
        proc.wait(timeout=grace_seconds)

    deadline = time.monotonic() + grace_seconds
    while process_group_exists(pgid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_group_exists(pgid):
        raise ProcessGroupLeakError(getattr(proc, "args", ["<unknown>"]))
'''
text = text[:start] + new_fn + text[end:]
p.write_text(text, encoding="utf-8")

replace_once(
    "tests/integration/test_v061_runner_cost_proof.sh",
    '''fake = FakeProc()
signals = []
orig_killpg = supervisor_runner.os.killpg
try:
    supervisor_runner.os.killpg = lambda pid, sig: signals.append((pid, sig))
    supervisor_runner._terminate_group(fake, grace_seconds=0.01)
finally:
    supervisor_runner.os.killpg = orig_killpg
assert signals == [(fake.pid, signal.SIGTERM), (fake.pid, signal.SIGKILL)], signals
assert fake.wait_calls == 2, fake.wait_calls
''',
    '''fake = FakeProc()
signals = []
orig_killpg = supervisor_runner.os.killpg
orig_group_exists = supervisor_runner.process_runner.process_group_exists
try:
    supervisor_runner.os.killpg = lambda pid, sig: signals.append((pid, sig))
    supervisor_runner.process_runner.process_group_exists = (
        lambda _pgid: fake.returncode is None
    )
    supervisor_runner._terminate_group(fake, grace_seconds=0.01)
finally:
    supervisor_runner.os.killpg = orig_killpg
    supervisor_runner.process_runner.process_group_exists = orig_group_exists
assert signals == [(fake.pid, signal.SIGTERM), (fake.pid, signal.SIGKILL)], signals
assert fake.wait_calls == 2, fake.wait_calls
''',
    "runner cleanup behavioral proof",
)

# 2. Approval artifact hashes are core-owned.
p = Path("lib/ownframework_loop/cli.py")
text = p.read_text(encoding="utf-8")
if "    approval_sha = approval.approval_artifact_sha256(approval_doc)\n" in text:
    text = text.replace(
        "    approval_sha = approval.approval_artifact_sha256(approval_doc)\n", "", 1
    )
if '            "approval_sha256": approval_sha,\n' not in text:
    raise SystemExit("approval reserved-hash caller anchor missing")
text = text.replace('            "approval_sha256": approval_sha,\n', "", 1)
p.write_text(text, encoding="utf-8")

# 3. Structural timeout regression follows the canonical bounded runner.
replace_once(
    "tests/integration/test_v10d_pre1_adversarial_fixes.sh",
    '''# _run_cli forwards timeout_seconds to subprocess.run
src = inspect.getsource(dispatch._run_cli)
assert 'timeout=' in src, 'A001: _run_cli must forward timeout to subprocess.run'
assert 'timeout_seconds' in src, 'A001: _run_cli must consult timeout_seconds'
''',
    '''# _run_cli forwards timeout_seconds to the bounded process runner
src = inspect.getsource(dispatch._run_cli)
assert 'process_runner.run_bounded_capture' in src, 'A001: _run_cli must use bounded process authority'
assert 'timeout_seconds=' in src, 'A001: _run_cli must forward timeout_seconds to bounded runner'
''',
    "v10d timeout ownership",
)

# 4. Authenticate every event link and refuse STATE without history.
p = Path("lib/ownframework_loop/integrity.py")
text = p.read_text(encoding="utf-8")
marker = "\n\ndef canonical_json_dumps(obj: Any) -> str:\n"
if "def verify_event_chain(" not in text:
    if marker not in text:
        raise SystemExit("integrity verify-event insertion anchor missing")
    fn = '''

def verify_event_chain(events_log: Path) -> tuple[bool, str]:
    """Verify every stored chain link and return the proven tail."""
    events = read_event_chain(events_log)
    chain = ""
    for idx, ev in enumerate(events, start=1):
        recorded = ev.get("event_chain_sha256")
        if (
            not isinstance(recorded, str)
            or len(recorded) != 64
            or any(ch not in "0123456789abcdef" for ch in recorded)
        ):
            return False, f"event {idx} has invalid event_chain_sha256"
        stripped = {k: v for k, v in ev.items() if k != "event_chain_sha256"}
        payload = canonical_json_dumps(stripped).encode("utf-8")
        h = hashlib.sha256()
        h.update(chain.encode("utf-8"))
        h.update(payload)
        expected = h.hexdigest()
        if recorded != expected:
            return False, f"event chain mismatch at row {idx}"
        chain = expected
    return True, chain
'''
    text = text.replace(marker, fn + marker, 1)
old = '''    if not events_log.exists():
        if not state_path.exists():
            return True, "no state or event chain yet"
        return True, "no event chain yet"

    expected = last_recorded_state_sha(events_log)
    if expected is None:
        if not state_path.exists():
            return True, "no state or recorded sha yet"
        return True, "no prior sha recorded"
'''
new = '''    if not events_log.exists():
        if not state_path.exists():
            return True, "no state or event chain yet"
        return False, "state exists but event chain is missing"

    expected = last_recorded_state_sha(events_log)
    if expected is None:
        if not state_path.exists():
            return True, "no state or recorded sha yet"
        return False, "state exists but event chain has no recorded sha"
'''
if old not in text:
    raise SystemExit("state missing-chain trust anchor missing")
text = text.replace(old, new, 1)
old = '''    chain_hash_recorded = get_event_chain_hash(events_log)
    if chain_hash_recorded is not None:
        chain_hash_actual = compute_event_chain_hash(events_log)
        if chain_hash_recorded != chain_hash_actual:
            failures.append("event_chain_hash_mismatch")
'''
new = '''    if events_log.exists():
        chain_ok, _tail = verify_event_chain(events_log)
        if not chain_ok:
            failures.append("event_chain_hash_mismatch")
'''
if old not in text:
    raise SystemExit("verify_all_artifacts chain anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

# 5. State read/mutation/recovery use the per-row verifier and prevent generic
# events from rebinding changed authoritative evidence.
p = Path("lib/ownframework_loop/state.py")
text = p.read_text(encoding="utf-8")
replace_pairs = [
    (
        '''    events = integrity.read_event_chain(ep) if ep.exists() else []
    recorded_chain = integrity.get_event_chain_hash(ep) or ""
    actual_chain = integrity.compute_event_chain_hash(ep) if events else ""
    if recorded_chain != actual_chain:
        raise integrity.TamperingDetected(
            "event chain integrity mismatch while recovering state transaction"
        )
''',
        '''    events = integrity.read_event_chain(ep) if ep.exists() else []
    chain_ok, recorded_chain = (
        integrity.verify_event_chain(ep) if ep.exists() else (True, "")
    )
    if not chain_ok:
        raise integrity.TamperingDetected(
            "event chain integrity mismatch while recovering state transaction"
        )
''',
    ),
    (
        '''        if ep.exists():
            events = integrity.read_event_chain(ep)
            if events:
                recorded = integrity.get_event_chain_hash(ep)
                actual = integrity.compute_event_chain_hash(ep)
                if not recorded or recorded != actual:
                    raise integrity.TamperingDetected(
                        "event chain integrity mismatch while loading authoritative state"
                    )
''',
        '''        if ep.exists():
            chain_ok, _tail = integrity.verify_event_chain(ep)
            if not chain_ok:
                raise integrity.TamperingDetected(
                    "event chain integrity mismatch while loading authoritative state"
                )
''',
    ),
    (
        '''    if ep.exists():
        events = integrity.read_event_chain(ep)
        if events:
            recorded = integrity.get_event_chain_hash(ep)
            actual = integrity.compute_event_chain_hash(ep)
            if not recorded or recorded != actual:
                raise integrity.TamperingDetected(
                    "event chain integrity mismatch before state mutation"
                )
''',
        '''    if ep.exists():
        chain_ok, _tail = integrity.verify_event_chain(ep)
        if not chain_ok:
            raise integrity.TamperingDetected(
                "event chain integrity mismatch before state mutation"
            )
''',
    ),
]
for old, new in replace_pairs:
    if old not in text:
        raise SystemExit("state chain verification anchor missing")
    text = text.replace(old, new, 1)
insertion = '''
_ARTIFACT_REBIND_EVENTS = {
    "packet_approved": frozenset({"WORK_PACKET.md", "APPROVAL.json"}),
    "build_finalized": frozenset({"BUILD_AGENT_RESULT.json", "BUILD_RECEIPT.json"}),
    "review_finalized": frozenset({"REVIEW_AGENT_ASSESSMENT.json", "REVIEW_VERDICT.json"}),
}
'''
anchor = '_EVENT_CALLER_RESERVED_FIELDS = _EVENT_AUTHORITATIVE_FIELDS | {"state_txn_id"}\n'
if "_ARTIFACT_REBIND_EVENTS" not in text:
    if anchor not in text:
        raise SystemExit("artifact rebind insertion anchor missing")
    text = text.replace(anchor, anchor + insertion, 1)
old = '''    # Core-owned publication binding: every event snapshots every currently
    # present authoritative artifact. Callers cannot spoof these keys because
    # they are part of _EVENT_AUTHORITATIVE_FIELDS above.
    record.update(integrity.artifact_event_hashes(run_dir(canonical_repo, run_id)))
'''
new = '''    # Core-owned publication binding. Generic events cannot bless changed
    # evidence; only the publication owner for an artifact class can rebind it.
    current_artifacts = integrity.artifact_event_hashes(run_dir(canonical_repo, run_id))
    allowed_rebinds = _ARTIFACT_REBIND_EVENTS.get(event_type, frozenset())
    for artifact_name, event_key in integrity.ARTIFACT_EVENT_KEYS.items():
        digest = current_artifacts.get(event_key)
        if not digest:
            continue
        prior = integrity.last_recorded_artifact_sha(ep, artifact_name) if ep.exists() else None
        if prior is None or prior == digest or artifact_name in allowed_rebinds:
            record[event_key] = digest
'''
if old not in text:
    raise SystemExit("generic artifact autosnapshot anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

# 6. Required validation delegates process lifecycle to the canonical runner.
p = Path("lib/ownframework_loop/validation_executor.py")
text = p.read_text(encoding="utf-8")
helper_start = text.find("def _terminate_validation_group(")
if helper_start >= 0:
    helper_end = text.index("\n\ndef command_uses_uv_run", helper_start)
    text = text[:helper_start] + text[helper_end + 2 :]
old = '''        process = subprocess.Popen(
            ["/bin/sh", "-c", command],
            cwd=str(cwd),
            stdout=stdout_fh,
            stderr=stderr_fh,
            env=env,
            start_new_session=True,
        )
        try:
            returncode = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            _terminate_validation_group(process)
            returncode = 124
        except BaseException:
            _terminate_validation_group(process)
            raise
        else:
            if process_runner.process_group_exists(process.pid):
                _terminate_validation_group(process)
                returncode = process_runner.PROCESS_GROUP_LEAK_RC
                stderr_fh.write(
                    ("\n" + process_runner.PROCESS_GROUP_LEAK_MARKER + "\n").encode("utf-8")
                )
                stderr_fh.flush()
'''
new = '''        outcome = process_runner.run_bounded_to_files(
            ["/bin/sh", "-c", command],
            cwd=cwd,
            timeout_seconds=float(timeout_seconds),
            stdout_fh=stdout_fh,
            stderr_fh=stderr_fh,
            env=env,
        )
        returncode = int(outcome.returncode)
        timed_out = bool(outcome.timed_out)
'''
if old not in text:
    raise SystemExit("validation executor lifecycle anchor missing")
text = text.replace(old, new, 1)
if "subprocess." in text:
    raise SystemExit("validation_executor still owns raw subprocess lifecycle")
text = text.replace("import subprocess\n", "", 1)
p.write_text(text, encoding="utf-8")

replace_once(
    "tests/unit/test_final_hardening_process_and_lock.sh",
    '''    allowed_popen = {
        "process_runner.py",
        "validation_environment.py",
        "validation_executor.py",
        "supervisor_runner.py",
    }
''',
    '''    allowed_popen = {
        "process_runner.py",
        "supervisor_runner.py",
    }
''',
    "raw Popen ownership allow-list",
)

# 7. Regression proofs for chain reset, link tampering, and evidence laundering.
p = Path("tests/integration/test_v061_evidence_fail_closed.sh")
text = p.read_text(encoding="utf-8")
anchor = "# Symlinked authority is filesystem redirection, not evidence.\n"
block = '''# Existing STATE can never fall back to first-run authority by deleting or
# truncating its event history.
repo3 = root / "event-reset-repo"
repo3.mkdir()
run3 = "run-event-reset"
state.run_dir(repo3, run3).mkdir(parents=True)
state.save(repo3, run3, state.initial_state(run3))
events3 = state.events_path(repo3, run3)
original_events = events3.read_bytes()
events3.unlink()
try:
    state.load_verified(repo3, run3)
except integrity.TamperingDetected as exc:
    assert "event chain is missing" in str(exc), exc
else:
    raise SystemExit("deleted EVENTS.log reset STATE authority")
events3.write_bytes(original_events)
events3.write_text("", encoding="utf-8")
try:
    state.load_verified(repo3, run3)
except integrity.TamperingDetected as exc:
    assert "no recorded sha" in str(exc), exc
else:
    raise SystemExit("empty EVENTS.log reset STATE authority")
events3.write_bytes(original_events)

rows = [json.loads(line) for line in events3.read_text(encoding="utf-8").splitlines() if line.strip()]
assert rows
rows[0]["event_chain_sha256"] = "f" * 64
events3.write_text("\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n", encoding="utf-8")
try:
    state.load_verified(repo3, run3)
except integrity.TamperingDetected as exc:
    assert "event chain integrity mismatch" in str(exc), exc
else:
    raise SystemExit("intermediate event_chain_sha256 tamper was accepted")

artifact2 = state.run_dir(repo2, run2) / "BUILD_RECEIPT.json"
artifact2.write_text('{"generation":1}\n', encoding="utf-8")
state.append_event(repo2, run2, event_type="build_finalized", old_state=None, new_state=None, actor="test")
first_digest = integrity.sha256_file(artifact2)
assert integrity.last_recorded_artifact_sha(events, "BUILD_RECEIPT.json") == first_digest
artifact2.write_text('{"generation":"tampered"}\n', encoding="utf-8")
state.append_event(repo2, run2, event_type="diagnostic", old_state=None, new_state=None, actor="test")
assert integrity.last_recorded_artifact_sha(events, "BUILD_RECEIPT.json") == first_digest
ok, failures = integrity.verify_all_artifacts({"BUILD_RECEIPT.json": artifact2}, events)
assert not ok and any("sha mismatch" in row for row in failures), failures
artifact2.write_text('{"generation":2}\n', encoding="utf-8")
state.append_event(repo2, run2, event_type="build_finalized", old_state=None, new_state=None, actor="test")
second_digest = integrity.sha256_file(artifact2)
assert second_digest != first_digest
assert integrity.last_recorded_artifact_sha(events, "BUILD_RECEIPT.json") == second_digest
ok, failures = integrity.verify_all_artifacts({"BUILD_RECEIPT.json": artifact2}, events)
assert ok and not failures, failures

'''
if anchor not in text:
    raise SystemExit("evidence regression insertion anchor missing")
p.write_text(text.replace(anchor, block + anchor, 1), encoding="utf-8")

# 8. Legacy tests that synthesize protocol states must use the canonical
# test-only transaction/event seeder. Deliberate later corruption remains direct.
replace_once(
    "tests/unit/test_v045_hardening.sh",
    '''import json, os
from pathlib import Path
from ownframework_loop import branch_resolver
repo=Path(os.environ["BREPO"]); rid=os.environ["BRID"]
state={"program":{"source_sha_provenance":{"candidate_branch":"factory/candidate/from-program"}}}
(repo/".ownframework-loop"/rid/"STATE.json").write_text(json.dumps(state))
assert branch_resolver.resolve_candidate_branch(repo,rid)=="factory/candidate/from-program"
''',
    '''import json, os, sys
from pathlib import Path
from ownframework_loop import branch_resolver
sys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))
from state_seed import seed_state
repo=Path(os.environ["BREPO"]); rid=os.environ["BRID"]
state={"program":{"source_sha_provenance":{"candidate_branch":"factory/candidate/from-program"}}}
seed_state(repo, rid, state, reason="fixture PROGRAM provenance state")
assert branch_resolver.resolve_candidate_branch(repo,rid)=="factory/candidate/from-program"
''',
    "v045 provenance fixture",
)
replace_once(
    "tests/unit/test_v045_hardening.sh",
    '''import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB", ""))
repo=Path(os.environ["HREPO"]); rid=os.environ["HRID"]
(repo/".ownframework-loop"/rid/"STATE.json").write_text(json.dumps({"state":"BUILDING","build_pass_count":2,"review_pass_count":0}))
# v0.7.0: the write guard is scoped by the explicit execution-context
''',
    '''import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ.get("OFLOOP_LIB", ""))
sys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))
from state_seed import seed_state
repo=Path(os.environ["HREPO"]); rid=os.environ["HRID"]
seed_state(repo, rid, {"state":"BUILDING","build_pass_count":2,"review_pass_count":0}, reason="fixture current-pass hook state")
# v0.7.0: the write guard is scoped by the explicit execution-context
''',
    "v045 hook fixture",
)

p = Path("tests/integration/test_repair_round_budget.sh")
text = p.read_text(encoding="utf-8")
old = "import json, subprocess, tempfile\nfrom ownframework_loop import program as program_mod, packet as packet_mod, state as state_mod\n"
new = "import json, subprocess, tempfile\nsys.path.insert(0, str(root / 'tests' / 'helpers'))\nfrom state_seed import seed_state\nfrom ownframework_loop import program as program_mod, packet as packet_mod, state as state_mod\n"
if old not in text:
    raise SystemExit("repair-budget import anchor missing")
text = text.replace(old, new, 1)
text = text.replace('(run_dir / "EVENTS.log").touch()\n', "", 1)
old = 'state_path = run_dir / "STATE.json"\nstate_path.write_text(json.dumps(state_doc, indent=2, sort_keys=True))\n'
new = 'state_path = run_dir / "STATE.json"\nseed_state(repo, run_id, state_doc, reason="fixture repair-budget state")\n'
if old not in text:
    raise SystemExit("repair-budget state anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

for path, run_id, old_state, label in [
    ("tests/integration/test_v061_supervisor_operator_safety.sh", "run-safe", '{"state":"BUILDING","build_pass_count":1}', "operator safety"),
    ("tests/integration/test_v061_supervisor_attempt_ledger.sh", "run-cost", '{"state":"BUILDING"}', "attempt ledger"),
    ("tests/integration/test_v061_supervisor_retry_usage_policy.sh", "run-policy", '{"state": "BUILDING"}', "retry usage policy"),
]:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    if "from ownframework_loop import supervisor\n" not in text:
        raise SystemExit(f"{label} supervisor import anchor missing")
    text = text.replace(
        "from ownframework_loop import supervisor\n",
        'from ownframework_loop import supervisor, state as state_mod\nimport os\nsys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))\nfrom state_seed import seed_state\n',
        1,
    )
    if run_id == "run-safe":
        old = '''(repo/".ownframework-loop"/"run-safe"/"STATE.json").write_text(
    json.dumps({"state":"BUILDING","build_pass_count":1}), encoding="utf-8")
'''
    elif run_id == "run-cost":
        old = '(rd/"STATE.json").write_text(json.dumps({"state":"BUILDING"}),encoding="utf-8")\n'
    else:
        old = '(rd / "STATE.json").write_text(json.dumps({"state": "BUILDING"}), encoding="utf-8")\n'
    new = f'seed = state_mod.initial_state("{run_id}")\nseed.update({old_state})\nseed_state(repo, "{run_id}", seed, reason="fixture {label} state")\n'
    if old not in text:
        raise SystemExit(f"{label} state anchor missing")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")

p = Path("tests/integration/test_v061_supervisor_autonomy_friction.sh")
text = p.read_text(encoding="utf-8")
old = "from ownframework_loop import supervisor\n"
new = 'from ownframework_loop import supervisor, state as state_mod\nsys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))\nfrom state_seed import seed_state\n'
if old not in text:
    raise SystemExit("autonomy fixture import anchor missing")
text = text.replace(old, new, 1)
old = '(rd / "STATE.json").write_text(json.dumps({"state": "BUILDING"}), encoding="utf-8")\n'
new = 'seed = state_mod.initial_state("run-auto")\nseed["state"] = "BUILDING"\nseed_state(repo, "run-auto", seed, reason="fixture autonomy state")\n'
if old not in text:
    raise SystemExit("autonomy fixture state anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

p = Path("tests/integration/test_v072_execution_closure.sh")
text = p.read_text(encoding="utf-8")
old = "from ownframework_loop import supervisor\n\nroot = Path(sys.argv[2])\n"
new = 'from ownframework_loop import supervisor, state as state_mod\nsys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))\nfrom state_seed import seed_state\n\nroot = Path(sys.argv[2])\n'
if old not in text:
    raise SystemExit("v072 wall import anchor missing")
text = text.replace(old, new, 1)
old = '(rd / "STATE.json").write_text(json.dumps({"state": "BUILDING"}), encoding="utf-8")\n'
new = 'seed = state_mod.initial_state("run-wall")\nseed["state"] = "BUILDING"\nseed_state(repo, "run-wall", seed, reason="fixture wall-budget state")\n'
if old not in text:
    raise SystemExit("v072 wall state anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

p = Path("tests/integration/test_v083_supervisor_retire.sh")
text = p.read_text(encoding="utf-8")
old = "from ownframework_loop import supervisor\n"
new = 'from ownframework_loop import supervisor, state as state_mod\nsys.path.insert(0, str(src / "tests" / "helpers"))\nfrom state_seed import seed_state\n'
if old not in text:
    raise SystemExit("v083 fixture import anchor missing")
text = text.replace(old, new, 1)
old = '''    run_dir.joinpath("STATE.json").write_text(
        json.dumps({"state": "BUILDING", "label": label}), encoding="utf-8"
    )
'''
new = '''    seed = state_mod.initial_state(effective_run_id)
    seed["state"] = "BUILDING"
    seed["label"] = label
    seed_state(r, effective_run_id, seed, reason="fixture supervisor-retire state")
'''
if old not in text:
    raise SystemExit("v083 fixture state anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

p = Path("tests/integration/test_v091_terminal_source_closure.sh")
text = p.read_text(encoding="utf-8")
old = "from _test_support import write_minimal_valid_packet  # noqa: E402\n"
new = 'from _test_support import write_minimal_valid_packet  # noqa: E402\n_sys.path.insert(0, str(Path.cwd() / "tests" / "helpers"))\nfrom state_seed import seed_state  # noqa: E402\n'
if old not in text:
    raise SystemExit("v091 terminal helper import anchor missing")
text = text.replace(old, new, 1)
old = '''    # Test-only seed seam: write STATE.json directly so the review finalizer
    # has a valid protocol state to read last_candidate_sha from. This is a
    # single-purpose test fixture, not a production mutation path.
    import os as _os_seed
    tmp_state = state_path.with_suffix(".json.tmp")
    tmp_state.write_text(json.dumps(initial_state, sort_keys=True, indent=2), encoding="utf-8")
    _os_seed.replace(tmp_state, state_path)
'''
new = '''    # Seed through the test-only durable transaction/event owner so this
    # fixture exercises replay identity rather than bypassing state provenance.
    seed_state(p7, rid7, initial_state, reason="fixture review acceptance state")
'''
if old not in text:
    raise SystemExit("v091 terminal initial-state anchor missing")
text = text.replace(old, new, 1)
old = '''    tmp_state2 = state_path.with_suffix(".json.tmp")
    tmp_state2.write_text(json.dumps(mutated_state, sort_keys=True, indent=2), encoding="utf-8")
    _os_seed.replace(tmp_state2, state_path)
'''
new = '    seed_state(p7, rid7, mutated_state, reason="fixture candidate identity mutation")\n'
if old not in text:
    raise SystemExit("v091 terminal mutation anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

p = Path("tests/integration/test_v099d_blocked_repair_context_propagated.sh")
text = p.read_text(encoding="utf-8")
old = '''import json, sys
from pathlib import Path
repo, rid = sys.argv[1], sys.argv[2]
rd = Path(repo) / '.ownframework-loop' / rid
'''
new = '''import json, os, sys
from pathlib import Path
sys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))
from state_seed import seed_state
repo, rid = sys.argv[1], sys.argv[2]
rd = Path(repo) / '.ownframework-loop' / rid
'''
if old not in text:
    raise SystemExit("v099d state helper import anchor missing")
text = text.replace(old, new, 1)
old = '''(rd / 'STATE.json').write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
# Ensure no EVENTS.log so integrity verification does not cross-check.
ep = rd / 'EVENTS.log'
if ep.exists():
    ep.unlink()
'''
new = 'seed_state(Path(repo), rid, state, reason="fixture BLOCKED continuation state")\n'
if old not in text:
    raise SystemExit("v099d raw state anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

p = Path("tests/integration/test_v10e_pre1_behavioral_proofs.sh")
text = p.read_text(encoding="utf-8")
old = "import sqlite3\nimport subprocess\n"
new = "import sqlite3\nimport subprocess\nimport sys\n"
if old not in text:
    raise SystemExit("v10e sys import anchor missing")
text = text.replace(old, new, 1)
old = "import ownframework_loop.packet as packet_mod\n\nfailures = []\n"
new = 'import ownframework_loop.packet as packet_mod\n\nsys.path.insert(0, str(Path(os.environ["OFLOOP_ROOT"]) / "tests" / "helpers"))\nfrom state_seed import seed_state\n\nfailures = []\n'
if old not in text:
    raise SystemExit("v10e state seed import anchor missing")
text = text.replace(old, new, 1)
old = '''(run_dir / "STATE.json").write_text(json.dumps({
    "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
    "run_id": "a001-r", "state": "READY_TO_BUILD",
    "transitions_count": 1, "build_pass_count": 0, "review_pass_count": 0,
    "repair_round": 0, "no_progress_streak": 0, "identical_finding_streak": 0,
    "started_at": "t", "updated_at": "t", "last_actor": "x",
    "last_candidate_sha": None, "terminal_reason": None,
    "state_history": [], "spec_baseline_branch": "master",
    "spec_baseline_sha": "0"*40,
    "program": {
        "current_checkpoints": ["cp-1"], "finalized_checkpoints": [],
        "cumulative_counters": {"build_pass_count": 0, "review_pass_count": 0,
                                 "repair_round_count": 0},
        "cumulative_ceilings": {"max_build_passes": 4, "max_review_passes": 4,
                                 "max_repair_rounds": 4},
        "checkpoints": [
            {"id": "cp-1", "build_pass_count": 0, "review_pass_count": 0,
             "repair_round_count": 0, "terminal_state": None},
        ],
        "review_scope": "checkpoint",
        "checkpoint_graph_sha256": "graph-sha",
    },
}))
(run_dir / "EVENTS.log").write_text("")
'''
new = '''seed_state(repo, "a001-r", {
    "schema": state_mod.PROGRAM_STATE_SCHEMA_VERSION,
    "run_id": "a001-r", "state": "READY_TO_BUILD",
    "transitions_count": 1, "build_pass_count": 0, "review_pass_count": 0,
    "repair_round": 0, "no_progress_streak": 0, "identical_finding_streak": 0,
    "started_at": "t", "updated_at": "t", "last_actor": "x",
    "last_candidate_sha": None, "terminal_reason": None,
    "state_history": [], "spec_baseline_branch": "master",
    "spec_baseline_sha": "0"*40,
    "program": {
        "current_checkpoints": ["cp-1"], "finalized_checkpoints": [],
        "cumulative_counters": {"build_pass_count": 0, "review_pass_count": 0,
                                 "repair_round_count": 0},
        "cumulative_ceilings": {"max_build_passes": 4, "max_review_passes": 4,
                                 "max_repair_rounds": 4},
        "checkpoints": [
            {"id": "cp-1", "build_pass_count": 0, "review_pass_count": 0,
             "repair_round_count": 0, "terminal_state": None},
        ],
        "review_scope": "checkpoint",
        "checkpoint_graph_sha256": "graph-sha",
    },
}, reason="fixture A001 program state")
'''
if old not in text:
    raise SystemExit("v10e A001 raw state anchor missing")
text = text.replace(old, new, 1)
old = '''def write_f002_state_all(state):
    (f002_run_dir / "STATE.json").write_text(json.dumps(state))
'''
new = '''def write_f002_state_all(state):
    seed_state(f002_repo, "x", state, reason="fixture F002 all-finalized state")
'''
if old not in text:
    raise SystemExit("v10e F002 writer anchor missing")
text = text.replace(old, new, 1)
old = '''(f002_run_dir_c2 / "EVENTS.log").write_text("")
state_c2 = make_state_doc(current_cp_id="cp-blocked", other_finalized_ids=[])
(f002_run_dir_c2 / "STATE.json").write_text(json.dumps(state_c2))
'''
new = '''state_c2 = make_state_doc(current_cp_id="cp-blocked", other_finalized_ids=[])
seed_state(f002_repo_c2, "x", state_c2, reason="fixture F002 unfinished state")
'''
if old not in text:
    raise SystemExit("v10e F002 c2 raw state anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")

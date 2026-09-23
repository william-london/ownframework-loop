from __future__ import annotations

from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str, label: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    write(path, text.replace(old, new, 1))


# ---------------------------------------------------------------------------
# 1. Central process cleanup: bounded reap + surviving-group refusal.
# ---------------------------------------------------------------------------
p = "lib/ownframework_loop/process_runner.py"
text = read(p)
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
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    if proc.poll() is None:
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
write(p, text)

# ---------------------------------------------------------------------------
# 2. Approval digest is core-owned publication evidence, never caller extras.
# ---------------------------------------------------------------------------
p = "lib/ownframework_loop/cli.py"
text = read(p)
text = text.replace(
    '    approval_sha = approval.approval_artifact_sha256(approval_doc)\n',
    "",
    1,
)
old = '            "approval_sha256": approval_sha,\n'
if old not in text:
    raise SystemExit("approval reserved-hash caller anchor missing")
text = text.replace(old, "", 1)
write(p, text)

# ---------------------------------------------------------------------------
# 3. Per-row event-chain authentication and marker-aware chain requirement.
# ---------------------------------------------------------------------------
p = "lib/ownframework_loop/integrity.py"
text = read(p)
marker = "\n\ndef canonical_json_dumps(obj: Any) -> str:\n"
if "def verify_event_chain(" not in text:
    if marker not in text:
        raise SystemExit("integrity verifier insertion anchor missing")
    fn = '''

def verify_event_chain(events_log: Path) -> tuple[bool, str]:
    """Authenticate every stored event-chain link and return its proven tail."""
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
new = '''    state_doc = read_json(state_path, default=None) if state_path.exists() else None
    chain_required = bool(
        isinstance(state_doc, dict) and state_doc.get("event_chain_required") is True
    )
    if not events_log.exists():
        if not state_path.exists():
            return True, "no state or event chain yet"
        if chain_required:
            return False, "event-chain-bound state exists but event chain is missing"
        return True, "legacy state has no event chain"

    expected = last_recorded_state_sha(events_log)
    if expected is None:
        if not state_path.exists():
            return True, "no state or recorded sha yet"
        if chain_required:
            return False, "event-chain-bound state has no recorded sha"
        return True, "legacy state has no prior sha recorded"
'''
if old not in text:
    raise SystemExit("state chain requirement anchor missing")
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
    raise SystemExit("artifact chain verification anchor missing")
text = text.replace(old, new, 1)
write(p, text)

# ---------------------------------------------------------------------------
# 4. State owns chain-required marker, per-row verification and typed artifact
#    publication. Generic events cannot first-bind or rebind evidence.
# ---------------------------------------------------------------------------
p = "lib/ownframework_loop/state.py"
text = read(p)
owner_anchor = '    "program",\n    "spec_baseline_branch", "spec_baseline_sha", "spec_snapshot_at",\n})\n'
owner_new = '    "program",\n    "spec_baseline_branch", "spec_baseline_sha", "spec_snapshot_at",\n    "event_chain_required",\n})\n'
if owner_anchor not in text:
    raise SystemExit("state owner field anchor missing")
text = text.replace(owner_anchor, owner_new, 1)

reserved_anchor = '_EVENT_CALLER_RESERVED_FIELDS = _EVENT_AUTHORITATIVE_FIELDS | {"state_txn_id"}\n'
policy = '''
_ARTIFACT_REBIND_EVENTS = {
    "packet_approved": frozenset({"WORK_PACKET.md", "APPROVAL.json"}),
    "execution_sealed": frozenset({"WORK_PACKET.md", "APPROVAL.json"}),
    "build_finalized": frozenset({"BUILD_AGENT_RESULT.json", "BUILD_RECEIPT.json"}),
    "review_finalized": frozenset({"REVIEW_AGENT_ASSESSMENT.json", "REVIEW_VERDICT.json"}),
}
'''
if "_ARTIFACT_REBIND_EVENTS" not in text:
    if reserved_anchor not in text:
        raise SystemExit("artifact publication policy anchor missing")
    text = text.replace(reserved_anchor, reserved_anchor + policy, 1)

old = '''    events = integrity.read_event_chain(ep) if ep.exists() else []
    recorded_chain = integrity.get_event_chain_hash(ep) or ""
    actual_chain = integrity.compute_event_chain_hash(ep) if events else ""
    if recorded_chain != actual_chain:
        raise integrity.TamperingDetected(
            "event chain integrity mismatch while recovering state transaction"
        )
'''
new = '''    events = integrity.read_event_chain(ep) if ep.exists() else []
    chain_ok, recorded_chain = (
        integrity.verify_event_chain(ep) if ep.exists() else (True, "")
    )
    if not chain_ok:
        raise integrity.TamperingDetected(
            "event chain integrity mismatch while recovering state transaction"
        )
'''
if old not in text:
    raise SystemExit("state recovery chain anchor missing")
text = text.replace(old, new, 1)

old = '''        if ep.exists():
            events = integrity.read_event_chain(ep)
            if events:
                recorded = integrity.get_event_chain_hash(ep)
                actual = integrity.compute_event_chain_hash(ep)
                if not recorded or recorded != actual:
                    raise integrity.TamperingDetected(
                        "event chain integrity mismatch while loading authoritative state"
                    )
'''
new = '''        if ep.exists():
            chain_ok, _tail = integrity.verify_event_chain(ep)
            if not chain_ok:
                raise integrity.TamperingDetected(
                    "event chain integrity mismatch while loading authoritative state"
                )
'''
if old not in text:
    raise SystemExit("state load chain anchor missing")
text = text.replace(old, new, 1)

old = '''    if ep.exists():
        events = integrity.read_event_chain(ep)
        if events:
            recorded = integrity.get_event_chain_hash(ep)
            actual = integrity.compute_event_chain_hash(ep)
            if not recorded or recorded != actual:
                raise integrity.TamperingDetected(
                    "event chain integrity mismatch before state mutation"
                )
'''
new = '''    if ep.exists():
        chain_ok, _tail = integrity.verify_event_chain(ep)
        if not chain_ok:
            raise integrity.TamperingDetected(
                "event chain integrity mismatch before state mutation"
            )
'''
if old not in text:
    raise SystemExit("state mutation chain anchor missing")
text = text.replace(old, new, 1)

old = '''        _commit_state_event_locked(
            canonical_repo,
            run_id,
            payload,
            event_type="state_saved",
'''
new = '''        stored = dict(payload)
        stored["event_chain_required"] = True
        _commit_state_event_locked(
            canonical_repo,
            run_id,
            stored,
            event_type="state_saved",
'''
if old not in text:
    raise SystemExit("state.save publication anchor missing")
text = text.replace(old, new, 1)

old = '''    # Core-owned publication binding: every event snapshots every currently
    # present authoritative artifact. Callers cannot spoof these keys because
    # they are part of _EVENT_AUTHORITATIVE_FIELDS above.
    record.update(integrity.artifact_event_hashes(run_dir(canonical_repo, run_id)))
'''
new = '''    # Core-owned publication binding. Evidence can first-bind or rebind only
    # at its typed publication event. Other events may repeat an unchanged
    # digest but can never bless injected or modified bytes.
    current_artifacts = integrity.artifact_event_hashes(
        run_dir(canonical_repo, run_id)
    )
    allowed_rebinds = _ARTIFACT_REBIND_EVENTS.get(event_type, frozenset())
    for artifact_name, event_key in integrity.ARTIFACT_EVENT_KEYS.items():
        digest = current_artifacts.get(event_key)
        if not digest:
            continue
        prior = (
            integrity.last_recorded_artifact_sha(ep, artifact_name)
            if ep.exists() else None
        )
        if prior == digest or artifact_name in allowed_rebinds:
            record[event_key] = digest
'''
if old not in text:
    raise SystemExit("artifact autosnapshot anchor missing")
text = text.replace(old, new, 1)
write(p, text)

# ---------------------------------------------------------------------------
# 5. Auto-seal publishes packet+approval evidence explicitly before activation.
# ---------------------------------------------------------------------------
p = "lib/ownframework_loop/execution_start.py"
text = read(p)
old = '''                util.atomic_write_json(seal_path, seal, mode=0o600)
                _ensure_program_for_sealed(canonical_repo, run_id, packet, seal)
'''
new = '''                util.atomic_write_json(seal_path, seal, mode=0o600)
                state_mod.append_event(
                    canonical_repo,
                    run_id,
                    event_type="execution_sealed",
                    old_state=prior_state.get("state"),
                    new_state=prior_state.get("state"),
                    actor=actor or "operator",
                    reason="execution authority sealed at first start",
                )
                _ensure_program_for_sealed(canonical_repo, run_id, packet, seal)
'''
if old not in text:
    raise SystemExit("auto-seal publication anchor missing")
text = text.replace(old, new, 1)
write(p, text)

# ---------------------------------------------------------------------------
# 6. Validation uses the one streamed bounded-process owner.
# ---------------------------------------------------------------------------
p = "lib/ownframework_loop/validation_executor.py"
text = read(p)
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
                    ("\\n" + process_runner.PROCESS_GROUP_LEAK_MARKER + "\\n").encode("utf-8")
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
write(p, text)

# ---------------------------------------------------------------------------
# 7. Regression contracts follow current owners.
# ---------------------------------------------------------------------------
p = "tests/integration/test_v061_runner_cost_proof.sh"
text = read(p)
old = '''fake = FakeProc()
signals = []
orig_killpg = supervisor_runner.os.killpg
try:
    supervisor_runner.os.killpg = lambda pid, sig: signals.append((pid, sig))
    supervisor_runner._terminate_group(fake, grace_seconds=0.01)
finally:
    supervisor_runner.os.killpg = orig_killpg
assert signals == [(fake.pid, signal.SIGTERM), (fake.pid, signal.SIGKILL)], signals
assert fake.wait_calls == 2, fake.wait_calls
'''
new = '''fake = FakeProc()
signals = []
orig_killpg = supervisor_runner.process_runner.os.killpg
orig_group_exists = supervisor_runner.process_runner.process_group_exists
try:
    supervisor_runner.process_runner.os.killpg = lambda pid, sig: signals.append((pid, sig))
    supervisor_runner.process_runner.process_group_exists = lambda _pgid: fake.returncode is None
    supervisor_runner._terminate_group(fake, grace_seconds=0.01)
finally:
    supervisor_runner.process_runner.os.killpg = orig_killpg
    supervisor_runner.process_runner.process_group_exists = orig_group_exists
assert signals == [(fake.pid, signal.SIGTERM), (fake.pid, signal.SIGKILL)], signals
assert fake.wait_calls == 2, fake.wait_calls
'''
if old not in text:
    raise SystemExit("runner cost regression anchor missing")
write(p, text.replace(old, new, 1))

p = "tests/integration/test_v10d_pre1_adversarial_fixes.sh"
text = read(p)
text = text.replace(
    "# _run_cli forwards timeout_seconds to subprocess.run\n",
    "# _run_cli forwards timeout_seconds to the bounded process runner\n",
    1,
)
old = '''assert 'timeout=' in src, 'A001: _run_cli must forward timeout to subprocess.run'
assert 'timeout_seconds' in src, 'A001: _run_cli must consult timeout_seconds'
'''
new = '''assert 'process_runner.run_bounded_capture' in src, 'A001: _run_cli must use bounded process authority'
assert 'timeout_seconds=' in src, 'A001: _run_cli must forward timeout_seconds to bounded runner'
'''
if old not in text:
    raise SystemExit("v10d bounded runner regression anchor missing")
write(p, text.replace(old, new, 1))

p = "tests/unit/test_final_hardening_process_and_lock.sh"
text = read(p)
old = '''    allowed_popen = {
        "process_runner.py",
        "validation_environment.py",
        "validation_executor.py",
        "supervisor_runner.py",
    }
'''
new = '''    allowed_popen = {
        "process_runner.py",
        "supervisor_runner.py",
    }
'''
if old not in text:
    raise SystemExit("raw Popen allow-list anchor missing")
write(p, text.replace(old, new, 1))

# Evidence regressions: chain loss applies to new event-bound states; legacy
# direct state files remain readable for compatibility.
p = "tests/integration/test_v061_evidence_fail_closed.sh"
text = read(p)
anchor = "# Symlinked authority is filesystem redirection, not evidence.\n"
if anchor not in text:
    raise SystemExit("evidence regression insertion anchor missing")
block = '''# Newly persisted production state is permanently event-chain-bound. Legacy
# direct fixtures without the marker remain compatible, but deleting/truncating
# the chain of a state.save() state cannot reset authority.
repo3 = root / "event-reset-repo"
repo3.mkdir()
run3 = "run-event-reset"
state.run_dir(repo3, run3).mkdir(parents=True)
state.save(repo3, run3, state.initial_state(run3))
bound = state.load_verified(repo3, run3)
assert bound.get("event_chain_required") is True, bound
events3 = state.events_path(repo3, run3)
original_events = events3.read_bytes()
events3.unlink()
try:
    state.load_verified(repo3, run3)
except integrity.TamperingDetected as exc:
    assert "event chain is missing" in str(exc), exc
else:
    raise SystemExit("deleted EVENTS.log reset bound STATE authority")
events3.write_bytes(original_events)
events3.write_text("", encoding="utf-8")
try:
    state.load_verified(repo3, run3)
except integrity.TamperingDetected as exc:
    assert "no recorded sha" in str(exc), exc
else:
    raise SystemExit("empty EVENTS.log reset bound STATE authority")
events3.write_bytes(original_events)

# Every stored link is authenticated, not only the final row.
rows = [json.loads(line) for line in events3.read_text(encoding="utf-8").splitlines() if line.strip()]
assert rows
rows[0]["event_chain_sha256"] = "f" * 64
events3.write_text("\\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\\n", encoding="utf-8")
try:
    state.load_verified(repo3, run3)
except integrity.TamperingDetected as exc:
    assert "event chain integrity mismatch" in str(exc), exc
else:
    raise SystemExit("intermediate event-chain digest tamper was accepted")

# Generic events cannot first-bind injected evidence or rebind modified evidence.
artifact2 = state.run_dir(repo2, run2) / "BUILD_RECEIPT.json"
artifact2.write_text('{"generation":1}\\n', encoding="utf-8")
state.append_event(repo2, run2, event_type="diagnostic", old_state=None, new_state=None, actor="test")
assert integrity.last_recorded_artifact_sha(events, "BUILD_RECEIPT.json") is None
state.append_event(repo2, run2, event_type="build_finalized", old_state=None, new_state=None, actor="test")
first_digest = integrity.sha256_file(artifact2)
assert integrity.last_recorded_artifact_sha(events, "BUILD_RECEIPT.json") == first_digest
artifact2.write_text('{"generation":"tampered"}\\n', encoding="utf-8")
state.append_event(repo2, run2, event_type="diagnostic", old_state=None, new_state=None, actor="test")
assert integrity.last_recorded_artifact_sha(events, "BUILD_RECEIPT.json") == first_digest
ok, failures = integrity.verify_all_artifacts({"BUILD_RECEIPT.json": artifact2}, events)
assert not ok and any("sha mismatch" in row for row in failures), failures
artifact2.write_text('{"generation":2}\\n', encoding="utf-8")
state.append_event(repo2, run2, event_type="build_finalized", old_state=None, new_state=None, actor="test")
second_digest = integrity.sha256_file(artifact2)
assert second_digest != first_digest
assert integrity.last_recorded_artifact_sha(events, "BUILD_RECEIPT.json") == second_digest
ok, failures = integrity.verify_all_artifacts({"BUILD_RECEIPT.json": artifact2}, events)
assert ok and not failures, failures

'''
write(p, text.replace(anchor, block + anchor, 1))

print("FINAL_AUTHORITY_CLOSURE_V2_TRANSFORM=PASS")

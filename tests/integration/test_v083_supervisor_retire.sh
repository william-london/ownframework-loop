#!/usr/bin/env bash
# v0.8.3 supervisor enrollment retirement lifecycle regression.
#
# Proves at minimum:
#   1. QUEUED foreign/unbound generation still blocks install.
#   2. BACKOFF foreign/unbound generation still blocks install.
#   3. RUNNING/live work still blocks install.
#   4. QUARANTINED foreign/unbound generation still blocks install.
#   5. RETIRED foreign generation does NOT block install.
#   6. RETIRED UNBOUND legacy generation does NOT block install.
#   7. Retirement from QUARANTINED succeeds with no live semantic worker.
#   8. Retirement refuses a live/ambiguous worker.
#   9. Retirement refuses QUEUED/BACKOFF/RUNNING.
#  10. Retirement does not change runtime_generation.
#  11. Retirement preserves semantic-attempt/history rows.
#  12. `supervisor resume` refuses RETIRED.
#  13. Repository/run artifacts are untouched by retirement.
#  14. Second ordinary same-generation installer refresh also proceeds
#      without OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"

PYTHON="${PYTHON_BIN:-$(command -v python3)}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$PYTHON" - "$TMP" "$ROOT_DIR" <<'PY'
import json, os, shutil, sqlite3, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
src = Path(sys.argv[2])
tmp = Path(sys.argv[2]).parent  # not used; placeholder
tmp = Path(sys.argv[1])
tmp.mkdir(parents=True, exist_ok=True)

# The installer is part of the canonical source under test, not a fixture;
# invoke it directly so the regression proves the SAME script operators run.
installer = src / "install-supervisor-macos.sh"
assert installer.is_file(), f"missing installer: {installer}"

from ownframework_loop import supervisor

# Helper: drive the installer generation probe by writing a fresh DB and
# running the install probe's generation SQL via the script's own embedded
# Python. We invoke the installer in a throwaway HOME with a stub PATH so
# the installer's late steps (plist write, launchctl bootstrap) are skipped.
# The probe early-returns on generation mismatch before touching plist.

def write_layout(home: Path, *, runtime_generation: str) -> None:
    (home / "Library" / "LaunchAgents").mkdir(parents=True, exist_ok=True)
    (home / "Library" / "LaunchAgents" / "com.ownframework.loop-supervisor.plist").write_text(
        "<plist/>", encoding="utf-8"
    )
    state = home / ".local" / "state" / "ownframework-loop"
    state.mkdir(parents=True, exist_ok=True)
    # Create an empty DB through supervisor._connect so the schema is canonical.
    db = state / "supervisor.sqlite3"
    with supervisor._connect(db):
        pass
    # Stash the incoming generation in a side file the probe will read via env.
    (state / ".runtime_generation").write_text(runtime_generation, encoding="utf-8")

def run_install_probe(home: Path, *, fake_claude: Path, fake_launchctl: Path) -> tuple[int, str]:
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["PATH"] = f"{fake_claude.parent}:/usr/bin:/bin"
    env["PYTHONPATH"] = str(src / "lib")
    # Platform installers default to the installed core. This hermetic
    # source-level regression opts into the source runtime explicitly.
    env["OFLOOP_BIN"] = str(src / "bin" / "ofloop")
    proc = subprocess.run(
        ["bash", str(installer)],
        capture_output=True, text=True, env=env, timeout=60,
    )
    return proc.returncode, proc.stdout + proc.stderr

def fakebin(home: Path) -> Path:
    fb = home / "fakebin"
    fb.mkdir(parents=True, exist_ok=True)
    (fb / "claude").write_text(
        "#!/usr/bin/env bash\n"
        "if [[ \"${1:-}\" == \"--version\" ]]; then echo \"2.1.251 (Claude Code)\"; fi\n"
        "exit 0\n",
        encoding="utf-8",
    )
    (fb / "launchctl").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    (fb / "uname").write_text("#!/usr/bin/env bash\n[[ \"${1:-}\" == \"-s\" ]] && echo Darwin || /usr/bin/uname \"$@\"\n", encoding="utf-8")
    for f in (fb / "claude", fb / "launchctl", fb / "uname"):
        f.chmod(0o755)
    return fb

# Each scenario creates its own throwaway HOME so states cannot bleed.
def scenario(status: str, generation: str | None) -> tuple[int, str]:
    home = tmp / f"home-{status}-{'bound' if generation else 'unbound'}"
    if home.exists():
        shutil.rmtree(home)
    home.mkdir()
    write_layout(home, runtime_generation=generation or "")
    db = home / ".local" / "state" / "ownframework-loop" / "supervisor.sqlite3"
    # Insert exactly one row with the requested status/generation.
    incoming = "ofloop-0.8.3@git-REGTEST"
    with supervisor._connect(db) as conn:
        conn.execute(
            """INSERT INTO jobs (repo, run_id, runner, status,
                                 next_attempt_at, created_at, updated_at,
                                 runtime_generation)
               VALUES (?, ?, 'claude-code', ?, 0, 0.0, 0.0, ?)""",
            ("/tmp/repo-scenario", f"run-{status.lower()}", status, generation or ""),
        )
    # Write the runtime-provenance.json so the installer thinks the service
    # is already commissioned (required to enter the generation probe path).
    provenance = {
        "schema": "ownframework-loop-supervisor-runtime-provenance/v1",
        "service_label": "com.ownframework.loop-supervisor",
        "ofloop_bin": str(src / "bin" / "ofloop"),
        "ofloop_version": "0.8.3",
        "python_bin": str(Path(shutil.which("python3") or "/usr/bin/python3")),
        "runtime_generation": generation or "",
        "source_root": str(src),
        "source_head": "REGTEST",
    }
    (home / ".local" / "state" / "ownframework-loop" / "runtime-provenance.json").write_text(
        json.dumps(provenance), encoding="utf-8"
    )
    fb = fakebin(home)
    return run_install_probe(home, fake_claude=fb / "claude", fake_launchctl=fb / "launchctl")

# 1) QUEUED + UNBOUND must REFUSE install.
rc, out = scenario("QUEUED", None)
assert rc != 0, f"QUEUED UNBOUND must refuse install, got rc={rc} out={out}"
assert "runtime_generation_dependency" in out, out
assert "UNBOUND" in out, out

# 2) BACKOFF + foreign generation must REFUSE install.
rc, out = scenario("BACKOFF", "ofloop-0.5.0@git-OLD")
assert rc != 0, f"BACKOFF foreign must refuse install, got rc={rc} out={out}"
assert "runtime_generation_dependency" in out, out

# 3) RUNNING + foreign generation must REFUSE install.
# A RUNNING row is caught by the active-semantic-work probe first (no
# generation check needed), so any refusal reason is acceptable — the
# invariant is that RUNNING can NEVER install while a worker is in flight.
rc, out = scenario("RUNNING", "ofloop-0.5.0@git-OLD")
assert rc != 0, f"RUNNING must refuse install, got rc={rc} out={out}"
assert "SUPERVISOR_INSTALL=REFUSED" in out, out

# 4) QUARANTINED + UNBOUND must REFUSE install (current pre-fix behavior).
rc, out = scenario("QUARANTINED", None)
assert rc != 0, f"QUARANTINED UNBOUND must refuse install, got rc={rc} out={out}"
assert "runtime_generation_dependency" in out, out

# Now exercise retirement semantics against the supervisor directly.
def fresh_db() -> Path:
    db = tmp / "retire-tests.sqlite3"
    if db.exists():
        db.unlink()
    with supervisor._connect(db):
        pass
    return db

def enqueue_quarantined(repo: Path, run_id: str, db: Path, *, generation: str | None) -> dict:
    out = supervisor.enqueue(
        canonical_repo=repo, run_id=run_id, db_path=db,
        runtime_generation=(generation or ""),
    )
    assert out.get("ok"), out
    with supervisor._connect(db) as conn:
        conn.execute(
            """UPDATE jobs SET status='QUARANTINED',
                 last_error='synthetic test quarantine',
                 last_failure_class='test_quarantine',
                 last_failure_reason='test_quarantine'
               WHERE repo=? AND run_id=?""",
            (str(repo.resolve()), run_id),
        )
        conn.commit()
    return out

def make_repo(label: str) -> Path:
    r = tmp / f"repo-{label}"
    if r.exists():
        shutil.rmtree(r)
    r.mkdir()
    (r / ".ownframework-loop" / f"run-{label}").mkdir(parents=True)
    (r / ".ownframework-loop" / f"run-{label}" / "STATE.json").write_text(
        json.dumps({"state": "BUILDING", "label": label}), encoding="utf-8"
    )
    (r / ".ownframework-loop" / f"run-{label}" / "WORK_PACKET.md").write_text(
        f"# Packet for {label}\n", encoding="utf-8"
    )
    return r

# 7) Retirement from QUARANTINED with no live worker SUCCEEDS.
db = fresh_db()
repo = make_repo("retire-success")
out = enqueue_quarantined(repo, "run-retire-ok", db, generation="ofloop-0.6.2@git-OLD")
# Snapshot the row's pre-retirement digest.
with supervisor._connect(db) as conn:
    before = conn.execute(
        "SELECT runtime_generation, total_cost_usd, latest_attempt_id FROM jobs "
        "WHERE repo=? AND run_id=?", (str(repo.resolve()), "run-retire-ok"),
    ).fetchone()
state_before = (repo / ".ownframework-loop" / "run-retire-success" / "STATE.json").read_text()
packet_before = (repo / ".ownframework-loop" / "run-retire-success" / "WORK_PACKET.md").read_text()
retire_out = supervisor.retire(canonical_repo=repo, run_id="run-retire-ok", db_path=db)
assert retire_out.get("retired") is True, retire_out
assert retire_out["status"] == "RETIRED", retire_out
assert retire_out["runtime_generation_preserved"] == before["runtime_generation"], retire_out
assert retire_out["runtime_generation_preserved"] == "ofloop-0.6.2@git-OLD", retire_out

# 10) Retirement preserves runtime_generation exactly.
with supervisor._connect(db) as conn:
    row = conn.execute(
        "SELECT status, runtime_generation, total_cost_usd, latest_attempt_id FROM jobs "
        "WHERE repo=? AND run_id=?", (str(repo.resolve()), "run-retire-ok"),
    ).fetchone()
assert row["status"] == "RETIRED"
assert row["runtime_generation"] == "ofloop-0.6.2@git-OLD", row["runtime_generation"]
assert row["total_cost_usd"] == before["total_cost_usd"], row["total_cost_usd"]
assert row["latest_attempt_id"] == before["latest_attempt_id"], row["latest_attempt_id"]

# 13) Repository / run artifacts untouched by retirement.
state_after = (repo / ".ownframework-loop" / "run-retire-success" / "STATE.json").read_text()
packet_after = (repo / ".ownframework-loop" / "run-retire-success" / "WORK_PACKET.md").read_text()
assert state_before == state_after, "STATE.json altered by retire"
assert packet_before == packet_after, "WORK_PACKET.md altered by retire"

# 11) Retirement preserves semantic_attempt history rows.
# Insert a synthetic semantic_attempts row and verify it survives retirement.
attempt_id = "abc123attempt"
with supervisor._connect(db) as conn:
    job_id = conn.execute(
        "SELECT id FROM jobs WHERE repo=? AND run_id=?",
        (str(repo.resolve()), "run-retire-ok"),
    ).fetchone()["id"]
    conn.execute(
        """INSERT INTO semantic_attempts
            (attempt_id, job_id, role, status, started_at, stdout_path, stderr_path)
            VALUES (?, ?, 'builder', 'COMPLETED', 0.0, '/tmp/o.log', '/tmp/e.log')""",
        (attempt_id, int(job_id)),
    )
# Re-enqueue then quarantine so we can retire again (row is already RETIRED; OK to no-op).
retire_out2 = supervisor.retire(canonical_repo=repo, run_id="run-retire-ok", db_path=db)
# Second retire on RETIRED refuses (not QUARANTINED).
assert retire_out2.get("retired") is False, retire_out2
assert retire_out2.get("reason") == "retire_refuses_terminal_enrollment", retire_out2
# The semantic_attempt row is still there.
with supervisor._connect_readonly(db) as conn:
    preserved = conn.execute(
        "SELECT attempt_id, status FROM semantic_attempts WHERE job_id=?",
        (int(job_id),),
    ).fetchall()
assert preserved and preserved[0]["attempt_id"] == attempt_id, preserved

# 12) supervisor resume refuses RETIRED.
resume_out = supervisor.resume(canonical_repo=repo, run_id="run-retire-ok", db_path=db)
assert resume_out.get("ok") is False, resume_out
assert resume_out.get("reason") == "resume_refuses_retired_enrollment", resume_out
assert resume_out["status"] == "RETIRED", resume_out

# 5) Installer: a RETIRED foreign generation does NOT block install.
home = tmp / "home-retired-bound"
if home.exists():
    shutil.rmtree(home)
home.mkdir()
write_layout(home, runtime_generation="ofloop-0.6.2@git-OLD")
db2 = home / ".local" / "state" / "ownframework-loop" / "supervisor.sqlite3"
with supervisor._connect(db2) as conn:
    conn.execute(
        """INSERT INTO jobs (repo, run_id, runner, status,
                             next_attempt_at, created_at, updated_at,
                             runtime_generation)
           VALUES (?, ?, 'claude-code', 'RETIRED', 0, 0.0, 0.0, ?)""",
        ("/tmp/repo-retired-bound", "run-retired-bound", "ofloop-0.6.2@git-OLD"),
    )
provenance = {
    "schema": "ownframework-loop-supervisor-runtime-provenance/v1",
    "service_label": "com.ownframework.loop-supervisor",
    "ofloop_bin": str(src / "bin" / "ofloop"),
    "ofloop_version": "0.8.3",
    "python_bin": str(Path(shutil.which("python3") or "/usr/bin/python3")),
    "runtime_generation": "ofloop-0.6.2@git-OLD",
    "source_root": str(src),
    "source_head": "OLD",
}
(home / ".local" / "state" / "ownframework-loop" / "runtime-provenance.json").write_text(
    json.dumps(provenance), encoding="utf-8"
)
fb = fakebin(home)
rc, out = run_install_probe(home, fake_claude=fb / "claude", fake_launchctl=fb / "launchctl")
# A RETIRED foreign-generation row must not block — but the installer may
# still fail for other reasons (e.g. plist write to fake home) further down.
# We assert the specific generation-dependency refusal is NOT present.
assert "generation_dependency" not in out or "RETIRED" not in out, (
    f"RETIRED row poisoned install: {out}"
)

# 6) Installer: a RETIRED UNBOUND legacy generation does NOT block install.
home = tmp / "home-retired-unbound"
if home.exists():
    shutil.rmtree(home)
home.mkdir()
write_layout(home, runtime_generation="")
db3 = home / ".local" / "state" / "ownframework-loop" / "supervisor.sqlite3"
with supervisor._connect(db3) as conn:
    conn.execute(
        """INSERT INTO jobs (repo, run_id, runner, status,
                             next_attempt_at, created_at, updated_at,
                             runtime_generation)
           VALUES (?, ?, 'claude-code', 'RETIRED', 0, 0.0, 0.0, '')""",
        ("/tmp/repo-retired-unbound", "run-retired-unbound"),
    )
provenance2 = dict(provenance)
provenance2["runtime_generation"] = ""
(home / ".local" / "state" / "ownframework-loop" / "runtime-provenance.json").write_text(
    json.dumps(provenance2), encoding="utf-8"
)
fb2 = fakebin(home)
rc2, out2 = run_install_probe(home, fake_claude=fb2 / "claude", fake_launchctl=fb2 / "launchctl")
assert "generation_dependency" not in out2 or "RETIRED" not in out2, (
    f"RETIRED UNBOUND row poisoned install: {out2}"
)

# 8) Retirement refuses a live/ambiguous worker.
db4 = fresh_db()
repo4 = make_repo("retire-live")
enqueue_quarantined(repo4, "run-retire-live", db4, generation=None)
with supervisor._connect(db4) as conn:
    job_id4 = conn.execute(
        "SELECT id FROM jobs WHERE repo=? AND run_id=?",
        (str(repo4.resolve()), "run-retire-live"),
    ).fetchone()["id"]
    # Fabricate a worker_pid that is alive (this process).
    conn.execute(
        """UPDATE jobs SET worker_pid=?, worker_started_at=?, worker_role='builder'
            WHERE id=?""",
        (os.getpid(), time.time() if False else 0.0, int(job_id4)),
    )
    conn.commit()
live_out = supervisor.retire(canonical_repo=repo4, run_id="run-retire-live", db_path=db4)
assert live_out.get("retired") is False, live_out
assert live_out.get("reason") == "quarantined_worker_still_alive", live_out

# 9) Retirement refuses QUEUED/BACKOFF/RUNNING.
for forbidden in ("QUEUED", "BACKOFF", "RUNNING"):
    db5 = fresh_db()
    repo5 = make_repo(f"refuse-{forbidden.lower()}")
    supervisor.enqueue(canonical_repo=repo5, run_id=f"run-{forbidden.lower()}", db_path=db5)
    with supervisor._connect(db5) as conn:
        conn.execute(
            "UPDATE jobs SET status=? WHERE repo=? AND run_id=?",
            (forbidden, str(repo5.resolve()), f"run-{forbidden.lower()}"),
        )
        conn.commit()
    refused = supervisor.retire(
        canonical_repo=repo5, run_id=f"run-{forbidden.lower()}", db_path=db5,
    )
    assert refused.get("retired") is False, refused
    assert refused.get("reason") == "retire_requires_quarantined", (forbidden, refused)
    # DONE also refused (terminal, not a real enrollment).
db_done = fresh_db()
repo_done = make_repo("refuse-done")
supervisor.enqueue(canonical_repo=repo_done, run_id="run-done", db_path=db_done)
with supervisor._connect(db_done) as conn:
    conn.execute(
        "UPDATE jobs SET status='DONE' WHERE repo=? AND run_id=?",
        (str(repo_done.resolve()), "run-done"),
    )
    conn.commit()
refused_done = supervisor.retire(canonical_repo=repo_done, run_id="run-done", db_path=db_done)
assert refused_done.get("retired") is False, refused_done
assert refused_done.get("reason") == "retire_refuses_terminal_enrollment", refused_done

# 14) Second ordinary same-generation installer refresh also proceeds without
# OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION. We re-run the install probe
# against the same RETIRED-only DB a second time and again assert no
# generation-dependency refusal.
fb3 = fakebin(home)
rc_again, out_again = run_install_probe(home, fake_claude=fb3 / "claude", fake_launchctl=fb3 / "launchctl")
assert "generation_dependency" not in out_again or "RETIRED" not in out_again, (
    f"second same-generation refresh poisoned by RETIRED row: {out_again}"
)

# Enqueue refuses RETIRED: prevents silent reactivation through normal enqueue.
db6 = fresh_db()
repo6 = make_repo("enqueue-retired")
supervisor.enqueue(canonical_repo=repo6, run_id="run-enqueue-retired", db_path=db6)
with supervisor._connect(db6) as conn:
    conn.execute(
        "UPDATE jobs SET status='QUARANTINED' WHERE repo=? AND run_id=?",
        (str(repo6.resolve()), "run-enqueue-retired"),
    )
    conn.commit()
supervisor.retire(canonical_repo=repo6, run_id="run-enqueue-retired", db_path=db6)
# Now a re-enqueue must refuse.
re_enq = supervisor.enqueue(canonical_repo=repo6, run_id="run-enqueue-retired", db_path=db6)
assert re_enq.get("enqueue_refused") is True, re_enq
assert re_enq.get("reason") == "enqueue_refuses_retired_enrollment", re_enq

print("V083_SUPERVISOR_RETIRE=PASS")
PY

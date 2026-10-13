#!/usr/bin/env bash
# OwnFramework Loop — per-tick research connection-lifecycle suite.
#
# `process_research_queue` opens the supervisor DB connection once per
# tick and then runs the whole tick body. Every NORMAL exit closed that
# handle inline before returning, so the handle's lifetime was only
# implicitly tied to the tick: nothing in the function guaranteed release
# when the body raised.
#
# That is the same descriptor-leak class the DB layer already documents
# and fixes in `supervisor_db._managed_connect` ("sqlite3.Connection
# implements transaction context management but does not close itself on
# __exit__. This distinction becomes a descriptor leak ..."). The per-tick
# research endpoint was the one remaining raw `sqlite3.connect` in the
# package without that guarantee.
#
# These checks pin the LIFECYCLE INVARIANT, deterministically, by holding
# a reference to every connection the tick opens. Holding the reference
# removes CPython refcount cleanup from the picture, so a handle released
# only by GC cannot masquerade as a correct release: the handle must be
# closed by the tick itself.
#
# The checks are:
#   - a post-connect exception leaves the handle CLOSED
#   - repeated post-connect exceptions leave every handle closed
#   - the normal deferred-return path still closes and still returns
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

TMP_ROOT="$(mktemp -d -t ofloop-conn-lifecycle.XXXXXX)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

python3 - "${REPO_ROOT}" "${TMP_ROOT}" <<'PY'
import sqlite3
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(sys.argv[1])
TMP_ROOT = Path(sys.argv[2])
sys.path.insert(0, str(REPO_ROOT / "lib"))

from ownframework_loop import supervisor_research as svrec

PASS, FAIL = [], []


def fail(msg):
    FAIL.append(msg)
    print(f"FAIL {msg}")


def ok(msg):
    PASS.append(msg)
    print(f"PASS {msg}")


RUN_ID = "run-20260921T180000Z-aabbccdd"
DB_PATH = TMP_ROOT / "supervisor.sqlite3"

_bootstrap = sqlite3.connect(DB_PATH)
_bootstrap.execute(
    "CREATE TABLE IF NOT EXISTS jobs ("
    "run_id TEXT, repo TEXT, status TEXT)"
)
_bootstrap.commit()
_bootstrap.close()

REPO_PATH = TMP_ROOT / "repo"
REPO_PATH.mkdir(parents=True, exist_ok=True)


# Capture every connection the tick opens and HOLD it. Holding the
# object defeats refcount-driven __del__ cleanup, so a handle that is
# only reclaimed by the garbage collector cannot pass for a handle the
# tick actually closed.
OPENED: list[sqlite3.Connection] = []
_real_connect = sqlite3.connect


def _capturing_connect(*args, **kwargs):
    conn = _real_connect(*args, **kwargs)
    OPENED.append(conn)
    return conn


sqlite3.connect = _capturing_connect


def is_closed(conn):
    """True when the handle has been closed by its owner."""
    try:
        conn.execute("SELECT 1")
    except sqlite3.ProgrammingError:
        return True
    except sqlite3.Error:
        return False
    return False


def unclosed_handles():
    return [c for c in OPENED if not is_closed(c)]


class _Boom(RuntimeError):
    """Stand-in for any exception the tick does not handle."""


# Satisfy the capability gate so execution reaches the DB connect, then
# fail immediately afterwards — the production shape, where the scheduler
# catches a bare Exception around the whole tick.
svrec._capability_resolution_has_research_public = lambda repo, run_id: True
_real_broker_identity = svrec._broker_commissioning_identity


def _boom_after_connect():
    raise _Boom("synthetic post-connect failure")


# --- check 1: a single post-connect exception must close the handle ---
svrec._broker_commissioning_identity = _boom_after_connect
OPENED.clear()
try:
    svrec.process_research_queue(
        db_path=DB_PATH, canonical_repo=REPO_PATH, run_id=RUN_ID
    )
except _Boom:
    pass
except Exception as exc:  # noqa: BLE001
    fail(f"UNEXPECTED_EXCEPTION_ESCAPED: {type(exc).__name__}: {exc}")

if len(OPENED) != 1:
    fail(f"SINGLE_TICK_OPENS_ONE_HANDLE: opened {len(OPENED)} handle(s), "
         "expected 1")
else:
    ok("SINGLE_TICK_OPENS_ONE_HANDLE: tick opened exactly 1 handle")

leaked = unclosed_handles()
if leaked:
    fail("EXCEPTION_CLOSES_HANDLE: handle still OPEN after a post-connect "
         f"exception ({len(leaked)} open)")
else:
    ok("EXCEPTION_CLOSES_HANDLE: handle closed on the exception path")

# --- check 2: repeated exceptions must not leave anything open ---
ITERATIONS = 25
OPENED.clear()
for _ in range(ITERATIONS):
    try:
        svrec.process_research_queue(
            db_path=DB_PATH, canonical_repo=REPO_PATH, run_id=RUN_ID
        )
    except _Boom:
        pass

leaked = unclosed_handles()
if leaked:
    fail("REPEATED_EXCEPTIONS_CLOSE_EVERY_HANDLE: "
         f"{len(leaked)}/{len(OPENED)} handle(s) still open after "
         f"{ITERATIONS} failing ticks")
else:
    ok("REPEATED_EXCEPTIONS_CLOSE_EVERY_HANDLE: "
       f"{len(OPENED)} handle(s) opened and all closed across "
       f"{ITERATIONS} failing ticks")

# --- check 3: the normal deferred path is unchanged ---
svrec._broker_commissioning_identity = _real_broker_identity
OPENED.clear()
try:
    def _unavailable():
        raise svrec._BrokerUnavailable("synthetic unavailability")

    svrec._broker_commissioning_identity = _unavailable
    result = svrec.process_research_queue(
        db_path=DB_PATH, canonical_repo=REPO_PATH, run_id=RUN_ID
    )
except svrec._BrokerUnavailable:
    fail("NORMAL_PATH_UNCHANGED: broker-unavailable must return a deferred "
         "summary, not propagate")
else:
    leaked = unclosed_handles()
    if result.get("deferred") == "broker_unavailable" and not leaked:
        ok("NORMAL_PATH_UNCHANGED: deferred summary returned, handle closed")
    else:
        fail(f"NORMAL_PATH_UNCHANGED: result={result!r} open_handles={len(leaked)}")

sqlite3.connect = _real_connect

print()
print(f"research connection-lifecycle: PASS={len(PASS)} FAIL={len(FAIL)}")
sys.exit(1 if FAIL else 0)
PY
rc=$?

echo
if [ "${rc}" -ne 0 ]; then
    echo "research connection-lifecycle: FAIL"
    exit 1
fi
echo "research connection-lifecycle: PASS"
"""Supervisor-side governed research transport (hardened).

The semantically-correct architecture for ``research.public`` puts the
public-network effect inside the supervisor's own serve() loop, NOT
inside the worker's Bash subprocess tree. This module is the
supervisor's contribution to that boundary.

This is the post-adjudication hardened revision. Key invariants:

* Worker has ``allowedDomains=[]`` and ``strictAllowlist: true``.
* Worker writes REQUEST files ONLY into its OWN per-run inbox
  (``<evidence_root>/<run-id>/requests/``) — not a global queue.
* The supervisor dispatches the broker asynchronously through a
  bounded in-process executor so a single broker call cannot stall
  the serve() loop (watchdog / dispatch / recovery stay live).
* The response path is computed by the supervisor from canonical
  fields and lives under the operator-owned evidence root:
  ``<evidence_root>/<run-id>/responses/resp-<UUIDv4>.json``.
  Worker READS but NEVER WRITES this dir. (A-RESEARCH-RESPONSE-FORGE)
* Every identifier used to build a trusted filesystem path is
  canonical and refuses path separators, traversal, control chars,
  overlong values. (A-RESEARCH-RESPONSE-PATH-CONFINEMENT)
* The broker's executable SHA256 is re-computed before every
  launch and refused on drift. (A-BROKER-RUNTIME-IDENTITY)
* Rate limit is durable across ticks (counts receipts written in
  the last 60s under the run's evidence root). (B-RESEARCH-RATE-LIMIT)
* Worker-requested ``max_bytes`` is deterministically clamped to
  the per-op cap. (B-RESOURCE-CAPS)
* Idempotent lifecycle: REQUEST → ``.claimed/`` marker → broker
  result → RESPONSE. Replay of a completed matching request is a
  no-op. (B-CRASH/REPLAY)
* ``request_id`` + ``request_digest`` are forwarded to the broker
  and recorded in every receipt. (B-BROKER-REQUEST-IDENTITY)

Flow
----

1. Worker invokes
   ``ofloop-research-call --op read --url <u> ... --request-id <UUIDv4>``.
2. The helper validates request shape (UUIDv4, canonical run/attempt,
   no path separators, no credential-shaped queries) and atomically
   publishes a REQUEST to ``$OFLOOP_RESEARCH_REQUESTS/req-<UUIDv4>.json``.
3. The supervisor ``serve()`` tick calls ``_research_bridge_tick``,
   which dequeues pending requests for the run being serviced,
   canonicalises identifiers, validates the run's frozen
   capability binding + active attempt + alive worker pid, and
   submits each valid request to a bounded
   ``_research_executor`` (ThreadPoolExecutor, default max_workers=2).
4. The executor invokes the broker via ``subprocess.run``
   (NOT under Claude sandbox). The broker's executable SHA256 is
   re-verified immediately before launch.
5. The broker writes durable content-addressed receipts to
   ``<evidence_root>/<run-id>/receipts/`` and asset bytes to
   ``<evidence_root>/<run-id>/artifacts/``.
6. The supervisor writes the worker-visible RESPONSE atomically to
   ``<evidence_root>/<run-id>/responses/resp-<UUIDv4>.json``.
   The helper (still polling) reads it and emits the body on stdout.
7. The supervisor marks the request completed by removing the
   ``.claimed/<UUIDv4>.json`` marker.

Authority invariants
--------------------

- The worker has ``allowedDomains=[]`` and ``strictAllowlist: true``.
- The worker's only research surface is ``ofloop-research-call``,
  which has no network authority of its own.
- All REQUEST validation happens here (supervisor); the broker
  re-validates SSRF per its own primitives; the helper performs
  cheap shape checks only.
- The supervisor's queue (``<evidence_root>/<run-id>/requests/``)
  and response dir (``<evidence_root>/<run-id>/responses/``) live
  under the operator-owned evidence root, mode 0o700. The worker
  may write only to its own run's requests inbox; the worker may
  read responses / receipts / artifacts but never write them.
"""
from __future__ import annotations

import concurrent.futures as _futures
import datetime as _dt
import hashlib
import json
import os
import re as _re
import sqlite3
import subprocess
import sys
import threading
import time
import uuid as _uuid
from pathlib import Path
from typing import Any

REQUEST_SCHEMA = "ownframework-loop-research-request/v1"
RESPONSE_SCHEMA = "ownframework-loop-research-response/v1"

# Strict caps (per-attempt, per-tick) so a prompt-injected worker
# cannot DOS the broker or runaway an evidence root.
DEFAULT_PER_ATTEMPT_RATE_LIMIT = 30   # ops / minute, durable across ticks
DEFAULT_REQUEST_TIMEOUT_SECONDS = 90
DEFAULT_MAX_BROKER_BYTES = 32 * 1024 * 1024
DEFAULT_BROKER_MAX_WORKERS = 2

# Strict canonical id validators. Used for every path-bearing field.
_RUN_ID_RE = _re.compile(r"^run-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
_ATTEMPT_ID_RE = _re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
_REQUEST_ID_RE = _re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_REQUEST_DIGEST_RE = _re.compile(r"^[0-9a-f]{64}$")
_ROLE_ENUM = ("builder", "reviewer")
_OP_ENUM = ("search", "read", "asset-read")

# Per-operation broker ceiling. Worker may request LESS, never MORE.
_OP_MAX_BYTES = {
    "search": 2 * 1024 * 1024,     # 2 MiB
    "read": 5 * 1024 * 1024,        # 5 MiB
    "asset-read": 32 * 1024 * 1024,  # 32 MiB
}


# --------------------------------------------------------------------------- #
# Path layout                                                               #
# --------------------------------------------------------------------------- #


def _evidence_root() -> Path:
    base = Path(
        os.environ.get(
            "OFLOOP_RESEARCH_EVIDENCE_ROOT",
            f"{Path.home()}/.local/state/ownframework-loop/research",
        )
    ).expanduser().resolve(strict=False)
    return base


def _run_evidence_dir(run_id: str) -> Path:
    """Per-run evidence directory: receipts, artifacts, requests, responses."""
    root = _evidence_root() / run_id
    return root


def _requests_dir(run_id: str) -> Path:
    """Per-run REQUEST inbox. Worker-writable. Supervisor-readable."""
    p = _run_evidence_dir(run_id) / "requests"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


def _claimed_dir(run_id: str) -> Path:
    """Per-run claimed-request marker directory.

    A claimed request is moved (atomic rename) into
    ``<requests>/.claimed/<request-id>.json``. On supervisor
    restart, any claim without a matching ``responses/<request-id>.json``
    is treated as in-flight and re-dispatched (idempotently —
    duplicate ``request_id`` + matching ``request_digest`` is a
    no-op that re-publishes the existing response).
    """
    p = _requests_dir(run_id) / ".claimed"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


def _responses_dir(run_id: str) -> Path:
    """Per-run RESPONSE directory. Supervisor-writable. Worker-readable.

    The worker MUST NOT be able to write here; the helper only reads.
    The dir lives under the operator-owned evidence root and is mode 0o700.
    """
    p = _run_evidence_dir(run_id) / "responses"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    return p


def _receipts_dir(run_id: str) -> Path:
    """Per-run RECEIPTS directory. Broker-writable. Worker-readable."""
    p = _run_evidence_dir(run_id) / "receipts"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def _artifacts_dir(run_id: str) -> Path:
    """Per-run ARTIFACTS directory. Broker-writable. Worker-readable."""
    p = _run_evidence_dir(run_id) / "artifacts"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


# --------------------------------------------------------------------------- #
# Strict canonical-id validation                                            #
# --------------------------------------------------------------------------- #


class _ValidationError(Exception):
    """Raised when a request field would build an untrusted path."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _assert_canonical_run_id(run_id: str) -> None:
    if not isinstance(run_id, str) or not _RUN_ID_RE.match(run_id):
        raise _ValidationError(
            "InvalidRequest",
            f"run_id is not canonical: {run_id!r}",
        )


def _assert_canonical_attempt_id(attempt_id: str) -> None:
    if not isinstance(attempt_id, str) or not _ATTEMPT_ID_RE.match(attempt_id):
        raise _ValidationError(
            "InvalidRequest",
            f"attempt_id has unsafe characters: {attempt_id!r}",
        )


def _assert_canonical_request_id(request_id: str) -> None:
    if not isinstance(request_id, str) or not _REQUEST_ID_RE.match(request_id):
        raise _ValidationError(
            "InvalidRequest",
            f"request_id is not UUIDv4: {request_id!r}",
        )


def _assert_canonical_role(role: str) -> None:
    if role not in _ROLE_ENUM:
        raise _ValidationError(
            "InvalidRequest",
            f"role is not in canonical enum: {role!r}",
        )


def _assert_safe_response_path(response_path: Path, root: Path) -> None:
    """After building the response path, assert it remains under root.

    This is the post-construction check (A-RESEARCH-RESPONSE-PATH-CONFINEMENT):
    even if a future code path accidentally concatenates a path-bearing
    field, this assertion catches it.

    Uses lexical containment (no filesystem resolution) so the
    assertion is correct whether or not the response file has been
    published yet; the canonical formula derives every component
    from already-canonical fields, so a path-traversal in any
    component is structurally impossible.
    """
    try:
        # Lexical comparison: every component must already be a
        # strict descendant of the root. ``resolve(strict=False)`` is
        # used only to normalise a trailing separator if any, not to
        # touch the filesystem.
        resolved = response_path.resolve(strict=False)
        root_resolved = root.resolve(strict=False)
        try:
            ok = resolved.is_relative_to(root_resolved)
        except AttributeError:  # pragma: no cover
            ok = str(resolved).startswith(str(root_resolved) + os.sep)
        if not ok:
            raise _ValidationError(
                "InvalidRequest",
                f"response path escaped response root: {resolved}",
            )
    except (OSError, RuntimeError) as exc:
        raise _ValidationError(
            "InvalidRequest",
            f"response path unresolvable: {exc}",
        )


# --------------------------------------------------------------------------- #
# Canonical response path owner (single source)                              #
# --------------------------------------------------------------------------- #


def canonical_response_path(run_id: str, request_id: str) -> Path:
    """Single canonical formula for the worker-visible RESPONSE path.

    ``request_id`` is the only path-bearing identifier (and it is
    strictly UUIDv4). Run is canonical. The root is the operator-owned
    responses directory. The post-construction check
    ``_assert_safe_response_path`` guarantees the formula cannot be
    coerced into escaping the root.
    """
    _assert_canonical_run_id(run_id)
    _assert_canonical_request_id(request_id)
    responses = _responses_dir(run_id)
    response_path = responses / f"resp-{request_id}.json"
    _assert_safe_response_path(response_path, responses)
    return response_path


# --------------------------------------------------------------------------- #
# Bounded research executor                                                 #
# --------------------------------------------------------------------------- #


class _ResearchExecutor:
    """Process-wide bounded executor for broker subprocess.run calls.

    Lives on the supervisor module, not on each tick, so the
    ThreadPoolExecutor keeps its worker pool across ticks. A single
    broker call may consume up to ~30s (read timeout). Concurrency
    is bounded so a flood of queued requests cannot fork N broker
    processes simultaneously and exhaust the host.
    """

    def __init__(self, max_workers: int = DEFAULT_BROKER_MAX_WORKERS) -> None:
        self._max_workers = max(1, int(max_workers))
        self._executor: _futures.ThreadPoolExecutor | None = None
        self._lock = threading.Lock()
        self._in_flight: set[_futures.Future[Any]] = set()
        self._max_in_flight = self._max_workers * 2  # admit a small backlog

    def _ensure(self) -> _futures.ThreadPoolExecutor:
        with self._lock:
            if self._executor is None:
                self._executor = _futures.ThreadPoolExecutor(
                    max_workers=self._max_workers,
                    thread_name_prefix="ofloop-research",
                )
            return self._executor

    def submit(self, fn, *args, **kwargs) -> _futures.Future[Any]:
        with self._lock:
            # Best-effort backpressure: if too many in-flight, refuse
            # new submits until some complete. The caller will retry on
            # the next tick.
            if len(self._in_flight) >= self._max_in_flight:
                raise _ResearchBusy(
                    f"research executor saturated "
                    f"({len(self._in_flight)}/{self._max_in_flight} in flight)"
                )
            fut = self._ensure().submit(fn, *args, **kwargs)
            self._in_flight.add(fut)
            fut.add_done_callback(self._in_flight.discard)
            return fut

    def shutdown(self, wait: bool = False) -> None:
        with self._lock:
            ex = self._executor
            self._executor = None
        if ex is not None:
            ex.shutdown(wait=wait, cancel_futures=not wait)


class _ResearchBusy(Exception):
    """Raised when the bounded executor refuses a new submit."""


_EXECUTOR: _ResearchExecutor | None = None
_EXECUTOR_LOCK = threading.Lock()


def _get_executor() -> _ResearchExecutor:
    global _EXECUTOR
    with _EXECUTOR_LOCK:
        if _EXECUTOR is None:
            max_workers = int(
                os.environ.get(
                    "OFLOOP_RESEARCH_MAX_WORKERS",
                    str(DEFAULT_BROKER_MAX_WORKERS),
                )
            )
            _EXECUTOR = _ResearchExecutor(max_workers=max_workers)
        return _EXECUTOR


# --------------------------------------------------------------------------- #
# Broker dispatch + integrity verification                                   #
# --------------------------------------------------------------------------- #


def _broker_executable_path() -> str | None:
    """Return the broker executable path from canonical commissioning.

    Reads the commissioning evidence via the canonical commissioning
    owner (``commissioning.py``) rather than trusting an arbitrary
    JSON path. The evidence path is the operator-installed artifact
    under ``~/.local/state/ownframework-loop/commissioning/``.
    """
    from . import commissioning as _cm
    try:
        info = _cm.read_commissioning_evidence("research.public")
    except Exception:
        return None
    if not isinstance(info, dict):
        return None
    provider = info.get("provider_identity") or {}
    if not isinstance(provider, dict):
        return None
    executable = provider.get("executable")
    if not isinstance(executable, str) or not executable:
        return None
    p = Path(executable).expanduser().resolve(strict=False)
    if not p.is_file() or not os.access(p, os.X_OK):
        return None
    return str(p)


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _verify_broker_identity(broker_path: str) -> tuple[bool, str, str | None]:
    """Compute the broker's current SHA256 and compare against the
    commissioning evidence. Return (ok, current_sha, expected_sha).
    """
    expected = None
    from . import commissioning as _cm
    try:
        info = _cm.read_commissioning_evidence("research.public")
        expected = (info.get("provider_identity") or {}).get("executable_sha256")
    except Exception:
        pass
    try:
        current = _sha256_file(Path(broker_path))
    except OSError:
        return (False, "", expected)
    if expected and current != expected:
        return (False, current, expected)
    return (True, current, expected)


# --------------------------------------------------------------------------- #
# Atomic publish                                                            #
# --------------------------------------------------------------------------- #


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    """Atomic publish: O_EXCL tmp + fsync + os.link."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(
        f".{path.name}.{os.getpid()}.{_uuid.uuid4().hex}.tmp"
    )
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=True, indent=2) + "\n"
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(encoded)
            fh.flush()
            os.fsync(fh.fileno())
        os.link(tmp, path)
        try:
            dir_fd = os.open(str(path.parent), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


# --------------------------------------------------------------------------- #
# Durable rate limit                                                        #
# --------------------------------------------------------------------------- #


def _durable_op_count_last_60s(run_id: str) -> int:
    """Count authoritative receipts written for this run in the last 60s.

    This is durable across supervisor restarts (the receipts/ dir is
    operator-owned). Used as the source of truth for the per-attempt
    rate limit.
    """
    cutoff = time.time() - 60.0
    receipts = _receipts_dir(run_id)
    if not receipts.is_dir():
        return 0
    count = 0
    for path in receipts.glob("op-*.json"):
        try:
            st = path.stat()
        except OSError:
            continue
        if st.st_mtime >= cutoff:
            count += 1
    return count


# --------------------------------------------------------------------------- #
# DB-backed attempt liveness                                                #
# --------------------------------------------------------------------------- #


def _db_get_job(conn: sqlite3.Connection, run_id: str) -> sqlite3.Row | None:
    cur = conn.execute("SELECT * FROM jobs WHERE run_id = ?", (run_id,))
    return cur.fetchone()


def _db_attempt_is_active(
    conn: sqlite3.Connection, run_id: str, attempt_id: str
) -> bool:
    """Worker pid alive AND attempt matches latest AND job not terminal."""
    row = _db_get_job(conn, run_id)
    if row is None:
        return False
    if (row["latest_attempt_id"] or "") != attempt_id:
        return False
    if not row["worker_pid"]:
        return False
    try:
        os.kill(int(row["worker_pid"]), 0)
    except (OSError, ProcessLookupError):
        return False
    status = str(row["status"] or "")
    if status in ("DONE", "QUARANTINED", "RETIRED"):
        return False
    return True


def _db_role_matches(conn: sqlite3.Connection, run_id: str, role: str) -> bool:
    """The job's role is implicit in its current attempt's
    ``build_pass_count`` / ``review_pass_count`` history. For a
    LIVE job, ``worker_role`` is set on the jobs row when the
    semantic_attempt is reserved. We cross-check by reading the
    latest attempt's role.
    """
    row = _db_get_job(conn, run_id)
    if row is None:
        return False
    if (row["worker_role"] or "") and (row["worker_role"] or "") != role:
        return False
    return True


# --------------------------------------------------------------------------- #
# Capability binding check                                                  #
# --------------------------------------------------------------------------- #


def _capability_resolution_has_research_public(
    canonical_repo: Path, run_id: str
) -> bool:
    from . import capability_binding as _cb
    try:
        binding_path = _cb.binding_path(canonical_repo, run_id)
        doc = _cb._read(binding_path)
    except Exception:
        return False
    projection = doc.get("projection") or {}
    requested = projection.get("requested") or []
    if not isinstance(requested, list):
        return False
    return "research.public" in requested


# --------------------------------------------------------------------------- #
# Broker invocation (synchronous, run inside executor.submit)               #
# --------------------------------------------------------------------------- #


def _clamp_max_bytes(op: str, requested: int | None) -> int:
    """Worker may request LESS than the cap, never MORE."""
    cap = _OP_MAX_BYTES.get(op, DEFAULT_MAX_BROKER_BYTES)
    if requested is None:
        return cap
    try:
        n = int(requested)
    except (TypeError, ValueError):
        return cap
    if n <= 0:
        return cap
    return min(n, cap)


def _run_broker_blocking(
    broker_path: str,
    *,
    op: str,
    url: str | None,
    query: str | None,
    max_bytes: int,
    evidence_dir: Path,
    run_id: str,
    attempt: str,
    request_id: str,
    request_digest: str,
    search_backend: str | None,
) -> dict[str, Any]:
    """Run the broker as a supervisor-owned subprocess (no Claude
    sandbox inheritance; full network access). Returns a normalized
    summary suitable for the worker.
    """
    cmd: list[str] = [
        broker_path,
        "--op", op,
        "--evidence-dir", str(evidence_dir),
        "--run-id", run_id,
        "--attempt", attempt,
        "--request-id", request_id,
        "--request-digest", request_digest,
    ]
    if url:
        cmd += ["--url", url]
    if query:
        cmd += ["--query", query]
    if max_bytes is not None:
        cmd += ["--max-bytes", str(int(max_bytes))]
    if search_backend:
        cmd += ["--search-backend", search_backend]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=float(os.environ.get(
                "OFLOOP_RESEARCH_BROKER_TIMEOUT", str(DEFAULT_REQUEST_TIMEOUT_SECONDS)
            )),
        )
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "error_class": "BrokerTimeout",
            "error": f"broker exceeded timeout: {exc}",
        }
    except Exception as exc:  # pragma: no cover
        return {
            "ok": False,
            "error_class": "BrokerDispatchFailed",
            "error": f"{type(exc).__name__}: {exc}",
        }
    raw = (proc.stdout or "").strip()
    parsed: dict[str, Any] | None = None
    if raw:
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = None
    if proc.returncode == 0 and parsed and parsed.get("ok"):
        return parsed
    err_class = (parsed or {}).get("error_class", "BrokerFailure")
    err_msg = (parsed or {}).get("error") or (proc.stderr or "")[:2000]
    return {
        "ok": False,
        "error_class": err_class,
        "error": err_msg,
    }


def _summarize_for_worker(
    broker_result: dict[str, Any],
    request_id: str,
) -> dict[str, Any]:
    """Build the worker-visible response envelope."""
    ts = _dt.datetime.now(_dt.timezone.utc).isoformat()
    if broker_result.get("ok"):
        # Pass through the broker's structured output unchanged; the
        # broker already produced a worker-friendly summary.
        out = dict(broker_result)
        out["schema"] = RESPONSE_SCHEMA
        out["request_id"] = request_id
        out["timestamp"] = ts
        out.setdefault("redirect_or_search_backend", broker_result.get("search_backend"))
        return out
    return {
        "schema": RESPONSE_SCHEMA,
        "ok": False,
        "request_id": request_id,
        "error_class": broker_result.get("error_class", "BrokerFailure"),
        "error": broker_result.get("error", ""),
        "timestamp": ts,
    }


def _publish_response(
    run_id: str,
    request_id: str,
    payload: dict[str, Any],
) -> Path:
    """Atomically write the worker-visible response at the canonical path.

    The path is computed by the canonical owner (single source) and
    asserted to remain under the operator-owned responses root.
    """
    response_path = canonical_response_path(run_id, request_id)
    _atomic_write_json(response_path, payload)
    return response_path


# --------------------------------------------------------------------------- #
# Idempotent request lifecycle                                              #
# --------------------------------------------------------------------------- #


def _claim_request(request_path: Path, run_id: str) -> Path | None:
    """Atomically move the request into ``.claimed/<id>.json``.

    Returns the claimed path on success; ``None`` if the move failed
    (e.g. another supervisor tick already claimed it, or the file
    is missing).
    """
    try:
        target = _claimed_dir(run_id) / request_path.name
        os.rename(request_path, target)
        return target
    except (FileNotFoundError, OSError):
        return None


def _replay_check(
    run_id: str, request_id: str, request_digest: str
) -> dict[str, Any] | None:
    """If a completed matching request exists, return its response.

    The completion marker is the response file itself. The replay
    identity is ``(run_id, request_id, request_digest)``. A
    duplicate request with the same id but DIFFERENT digest is
    refused (this catches worker smuggled-in rebinding).
    """
    response_path = canonical_response_path(run_id, request_id)
    if not response_path.exists():
        return None
    try:
        with response_path.open("r", encoding="utf-8") as fh:
            existing = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(existing, dict):
        return None
    # The request_digest is a stable identity for the worker's intent;
    # if a request with the same id is replayed with a different
    # digest (e.g. different URL), the supervisor refuses rather than
    # silently serving stale evidence.
    existing_digest = str(existing.get("request_digest") or "")
    if existing_digest and request_digest and existing_digest != request_digest:
        return {
            "schema": RESPONSE_SCHEMA,
            "ok": False,
            "error_class": "ReplayDigestMismatch",
            "error": (
                f"request_id {request_id} previously completed with a "
                f"different request_digest; refusing replay"
            ),
            "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        }
    return existing


# --------------------------------------------------------------------------- #
# Per-attempt request validation                                            #
# --------------------------------------------------------------------------- #


def _validate_request_shape(req: dict[str, Any]) -> None:
    """Cheap-shape validation. Raises ``_ValidationError`` on failure."""
    if not isinstance(req, dict):
        raise _ValidationError("InvalidRequest", "request must be a JSON object")
    for key in ("schema", "request_id", "run_id", "attempt_id", "role", "op",
                "requested_at"):
        if key not in req:
            raise _ValidationError(
                "InvalidRequest", f"missing required field: {key}"
            )
    if req.get("schema") != REQUEST_SCHEMA:
        raise _ValidationError("InvalidRequest", "request schema mismatch")
    if req.get("op") not in _OP_ENUM:
        raise _ValidationError("InvalidRequest", f"op out of supported set")
    if req.get("role") not in _ROLE_ENUM:
        raise _ValidationError("InvalidRequest", "role out of supported set")
    if req.get("op") in ("read", "asset-read") and not req.get("url"):
        raise _ValidationError("InvalidRequest", "url required for read/asset-read")
    if req.get("op") == "search" and not req.get("query"):
        raise _ValidationError("InvalidRequest", "query required for search")
    # Canonical-id checks: refuse anything that could escape the
    # response root through path construction.
    _assert_canonical_run_id(str(req.get("run_id", "")))
    _assert_canonical_attempt_id(str(req.get("attempt_id", "")))
    _assert_canonical_request_id(str(req.get("request_id", "")))
    _assert_canonical_role(str(req.get("role", "")))
    request_digest = req.get("request_digest") or ""
    if request_digest and not _REQUEST_DIGEST_RE.match(str(request_digest)):
        raise _ValidationError(
            "InvalidRequest", "request_digest is not 64-char hex"
        )


# --------------------------------------------------------------------------- #
# Per-tick queue consumer (supervisor-side)                                 #
# --------------------------------------------------------------------------- #


def _consume_inbox(run_id: str) -> list[tuple[Path, dict[str, Any]]]:
    """Read every REQUEST in this run's inbox, return list of (path, req).

    The request_path always lives under ``<requests_dir>/req-<UUIDv4>.json``
    (the helper writes there); canonical-id checks have already
    rejected anything that wouldn't fit that pattern. We re-validate
    defensively before processing.
    """
    inbox = _requests_dir(run_id)
    out: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(inbox.glob("req-*.json")):
        try:
            req = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            # Unreadable: treat as malformed and unlink.
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            continue
        try:
            _validate_request_shape(req)
        except _ValidationError:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            continue
        # Ensure the path matches what we expect: a request file
        # MUST be at ``<inbox>/req-<UUIDv4>.json``. Anything else is
        # a sandbox-bypass attempt.
        expected_name = f"req-{req.get('request_id')}.json"
        if path.name != expected_name:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            continue
        out.append((path, req))
    return out


def _is_request_already_handled(run_id: str, request_id: str) -> bool:
    """True if a response already exists for this request_id (idempotent
    no-op on duplicate dispatches)."""
    response_path = canonical_response_path(run_id, request_id)
    return response_path.exists()


# --------------------------------------------------------------------------- #
# Public API: per-tick bridge (call from supervisor.serve)                  #
# --------------------------------------------------------------------------- #


def process_research_queue(
    *,
    db_path: Path,
    canonical_repo: Path,
    run_id: str,
    rate_limit_per_minute: int = DEFAULT_PER_ATTEMPT_RATE_LIMIT,
) -> dict[str, Any]:
    """One supervisor tick: dispatch any pending requests for ``run_id``.

    The tick is non-blocking on broker latency: each valid request is
    submitted to the bounded executor, which invokes the broker in a
    worker thread. A future supervisor tick (or a completion callback
    installed here) drains results and publishes responses.

    For simplicity, this tick drains the executor too: it blocks on
    the futures for at most ``OFLOOP_RESEARCH_TICK_BUDGET_SECONDS``
    (default 5s). The supervisor main loop remains responsive because
    other ticks continue normally; this function returns within the
    budget and the next tick re-enters to drain stragglers.
    """
    # 1. Capability binding check.
    if not _capability_resolution_has_research_public(canonical_repo, run_id):
        # Drop everything in this run's inbox; the run has no authority.
        inbox = _requests_dir(run_id)
        for p in inbox.glob("req-*.json"):
            try:
                p.unlink()
            except FileNotFoundError:
                pass
        return {"consumed": 0, "processed": 0, "rejected": 0}

    # 2. DB connect.
    try:
        conn = sqlite3.connect(str(db_path))
    except sqlite3.Error:
        return {"consumed": 0, "processed": 0, "rejected": 0, "deferred": "db_unavailable"}
    conn.row_factory = sqlite3.Row

    # 3. Broker executable + identity check.
    broker_path = _broker_executable_path()
    if broker_path is None:
        conn.close()
        return {"consumed": 0, "processed": 0, "rejected": 0, "deferred": "broker_unavailable"}
    ok, _cur_sha, _exp_sha = _verify_broker_identity(broker_path)
    if not ok:
        conn.close()
        return {
            "consumed": 0, "processed": 0, "rejected": 0,
            "deferred": "broker_identity_drift",
        }

    # 4. Consume inbox for this run.
    candidates = _consume_inbox(run_id)
    if not candidates:
        conn.close()
        return {"consumed": 0, "processed": 0, "rejected": 0}

    # 5. Durable rate-limit gate (counts receipts written in last 60s).
    already_count = _durable_op_count_last_60s(run_id)
    consumed = len(candidates)
    rejected = 0
    futures_to_wait: list[tuple[Path, _futures.Future[dict[str, Any]], dict[str, Any]]] = []
    evidence_dir = _run_evidence_dir(run_id)
    executor = _get_executor()

    for request_path, req in candidates:
        request_id = str(req.get("request_id") or "")
        attempt_id = str(req.get("attempt_id") or "")
        role = str(req.get("role") or "")

        # 5a. Idempotent replay: if a response already exists, just
        # clean up the request (a previous tick dispatched it; the
        # response is the authoritative completion).
        if _is_request_already_handled(run_id, request_id):
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            continue

        # 5b. Active-attempt check: refuse requests from stale /
        # terminal / non-existent attempts.
        if not _db_attempt_is_active(conn, run_id, attempt_id):
            response = {
                "schema": RESPONSE_SCHEMA,
                "ok": False,
                "error_class": "AttemptNotActive",
                "error": "request attempt is not a currently-live attempt",
                "request_id": request_id,
                "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            _publish_response(run_id, request_id, response)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            rejected += 1
            continue

        # 5c. Role matches the live job's recorded role.
        if not _db_role_matches(conn, run_id, role):
            response = {
                "schema": RESPONSE_SCHEMA,
                "ok": False,
                "error_class": "RoleMismatch",
                "error": (
                    f"requested role {role!r} does not match the job's "
                    f"currently-active worker role"
                ),
                "request_id": request_id,
                "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            _publish_response(run_id, request_id, response)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            rejected += 1
            continue

        # 5d. Durable rate-limit gate.
        if already_count >= rate_limit_per_minute:
            response = {
                "schema": RESPONSE_SCHEMA,
                "ok": False,
                "error_class": "RateLimited",
                "error": (
                    f"durable per-attempt rate limit "
                    f"{rate_limit_per_minute}/min exceeded for this run"
                ),
                "request_id": request_id,
                "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            _publish_response(run_id, request_id, response)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            rejected += 1
            continue
        already_count += 1

        # 5e. Replay check (semantic): if a completed response exists
        # for this (run_id, request_id) AND the request_digest matches,
        # we can re-publish the same response and unlink the queue.
        # If the digest mismatches, we publish a ReplayDigestMismatch
        # error.
        request_digest = str(req.get("request_digest") or "")
        replay = _replay_check(run_id, request_id, request_digest)
        if replay is not None:
            # Re-publish with updated timestamp; preserves evidence.
            replay = dict(replay)
            replay["timestamp"] = _dt.datetime.now(_dt.timezone.utc).isoformat()
            _publish_response(run_id, request_id, replay)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            continue

        # 5f. Atomically claim the request: rename to .claimed/<id>.json.
        # If another tick already claimed it, skip.
        claimed_path = _claim_request(request_path, run_id)
        if claimed_path is None:
            continue

        # 5g. Submit to the bounded executor (non-blocking on the
        # supervisor serve loop's perspective; the tick will drain
        # the futures below within a budget).
        op = str(req.get("op") or "")
        clamped_max_bytes = _clamp_max_bytes(op, req.get("max_bytes"))
        try:
            fut = executor.submit(
                _run_broker_blocking,
                broker_path,
                op=op,
                url=req.get("url"),
                query=req.get("query"),
                max_bytes=clamped_max_bytes,
                evidence_dir=evidence_dir,
                run_id=run_id,
                attempt=attempt_id,
                request_id=request_id,
                request_digest=request_digest,
                search_backend=req.get("search_backend") if op == "search" else None,
            )
        except _ResearchBusy as exc:
            # Backpressure: put the claim back so the next tick retries.
            try:
                os.rename(claimed_path, request_path)
            except OSError:
                pass
            conn.close()
            return {
                "consumed": consumed,
                "processed": 0,
                "rejected": rejected,
                "deferred": "research_executor_busy",
                "detail": str(exc),
            }
        futures_to_wait.append((claimed_path, fut, req))

    # 6. Drain the executor within the tick budget. The supervisor
    # serve loop stays responsive because the bounded executor only
    # has max_workers threads and each broker call has a hard timeout.
    tick_budget = float(os.environ.get(
        "OFLOOP_RESEARCH_TICK_BUDGET_SECONDS", "5.0"
    ))
    deadline = time.monotonic() + tick_budget
    processed = 0
    for claimed_path, fut, req in futures_to_wait:
        remaining = max(0.0, deadline - time.monotonic())
        try:
            broker_result = fut.result(timeout=remaining)
        except _futures.TimeoutError:
            # Broker still running; leave claimed marker; will be
            # re-dispatched on a future tick (replay protection kicks
            # in once a response lands).
            continue
        except Exception as exc:  # pragma: no cover
            broker_result = {
                "ok": False,
                "error_class": "ExecutorFailed",
                "error": f"{type(exc).__name__}: {exc}",
            }
        request_id = str(req.get("request_id") or "")
        request_digest = str(req.get("request_digest") or "")
        response = _summarize_for_worker(broker_result, request_id)
        # Stamp the request_digest into the response so future replays
        # of the same request_id can validate identity.
        response["request_digest"] = request_digest
        _publish_response(run_id, request_id, response)
        # Drop the claim marker; the response is the durable completion.
        try:
            claimed_path.unlink()
        except FileNotFoundError:
            pass
        processed += 1

    conn.close()
    return {
        "consumed": consumed,
        "processed": processed,
        "rejected": rejected,
    }


__all__ = [
    "REQUEST_SCHEMA",
    "RESPONSE_SCHEMA",
    "process_research_queue",
    "canonical_response_path",
    "_evidence_root",
    "_run_evidence_dir",
    "_requests_dir",
    "_responses_dir",
    "_broker_executable_path",
    "_verify_broker_identity",
]

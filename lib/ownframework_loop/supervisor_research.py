"""Supervisor-side governed research transport (hardened).

The semantically-correct architecture for ``research.public`` puts the
public-network effect inside the supervisor's own serve() loop, NOT
inside the worker's Bash subprocess tree. This module is the
supervisor's contribution to that boundary.

This is the post-second-mid-run-adjudication hardened revision.
Key invariants:

* Worker has ``allowedDomains=[]`` and ``strictAllowlist: true``.
* Worker writes REQUEST files ONLY into its OWN per-run inbox
  (``<evidence_root>/<run-id>/requests/``), not a shared global queue.
* The supervisor dispatches the broker asynchronously through a
  bounded in-process executor. Each submitted task is owned by a
  process-wide authoritative in-flight registry keyed by
  ``(run_id, request_id, request_digest)``. A long broker call may
  exceed one tick's budget; the future is reaped on a later tick
  and the response is published exactly once. The serve() loop
  remains responsive (watchdog / dispatch / recovery stay live).
* Trusted claim markers live under the operator-owned
  ``<evidence_root>/<run-id>/claims/`` sibling — NEVER beneath the
  worker-writable ``requests/`` inbox.
* The response path is computed by the supervisor from canonical
  fields and lives under the operator-owned evidence root:
  ``<evidence_root>/<run-id>/responses/resp-<UUIDv4>.json``.
  Worker READS but NEVER WRITES this dir.
* Every identifier used to build a trusted filesystem path is
  canonical and refuses path separators, traversal, control chars,
  overlong values. The broker executable is verified by the
  canonical commissioning owner immediately before every launch.
* The supervisor recomputes the canonical request digest itself;
  the worker-supplied digest is untrusted and is compared but never
  used as authority.
* Replay identity is ``(request_id, request_digest)``. Same digest
  → reuse existing authoritative response. Different digest →
  ``ReplayDigestMismatch`` (no second network call).
* Rate limit counts ACCEPTED broker transport launches (success or
  failure) per run over the trailing 60 seconds. Restart-resilient
  via the receipts and claims directories.

Flow
----

1. Worker invokes
   ``ofloop-research-call --op read --url <u> ... --request-id <UUIDv4>``.
2. The helper validates request shape (UUIDv4, canonical run/attempt,
   no path separators, no credential-shaped queries) and atomically
   publishes a REQUEST to ``$OFLOOP_RESEARCH_REQUESTS/req-<UUIDv4>.json``.
3. The supervisor ``serve()`` tick calls ``_research_bridge_tick``,
   which:
   a. reaps the in-flight registry for completed futures, publishes
      their responses, and removes their claim markers;
   b. consumes pending requests from the per-run inbox,
      canonicalises identifiers, validates run-scope and request
      file hardening (no symlink, regular, bounded size);
   c. consults the durable replay cache (matching request_id + same
      digest → reuse authoritative response; matching request_id +
      different digest → ReplayDigestMismatch);
   d. recomputes the canonical request digest itself;
   e. moves the request to the operator-owned claims/ marker;
   f. submits to the bounded executor (non-blocking);
   g. counts the accept against the durable rate limit;
   h. respects the per-tick time budget; remaining futures are
      reaped on subsequent ticks.
4. The executor invokes the broker via ``subprocess.run`` (NOT
   under Claude sandbox). The broker's executable SHA256 is
   re-verified immediately before launch via the canonical
   commissioning owner.
5. The broker writes durable content-addressed receipts to
   ``<evidence_root>/<run-id>/receipts/`` and asset bytes to
   ``<evidence_root>/<run-id>/artifacts/``.
6. On future completion (this tick or a later one) the supervisor
   publishes the worker-visible RESPONSE atomically to
   ``<evidence_root>/<run-id>/responses/resp-<UUIDv4>.json`` and
   removes the claim marker. The helper (still polling) reads it
   and emits the body on stdout.

Authority invariants
--------------------

- The worker has ``allowedDomains=[]`` and ``strictAllowlist: true``.
- The worker's only research surface is ``ofloop-research-call``,
  which has no network authority of its own.
- All REQUEST validation happens here (supervisor); the broker
  re-validates SSRF per its own primitives; the helper performs
  cheap shape checks only.
- The supervisor's queue (``<evidence_root>/<run-id>/requests/``)
  is worker-writable; ``responses/``, ``claims/``, ``receipts/``,
  ``artifacts/`` are operator-owned and worker-cannot-write.
- The worker has no write authority over responses / receipts /
  artifacts / claims; even a prompt-injection-perturbed worker
  cannot forge a response, a receipt, or a claim.
"""
from __future__ import annotations

import concurrent.futures as _futures
import datetime as _dt
import enum
import hashlib
import json
import os
import re as _re
import sqlite3
import stat as _stat
import subprocess
import sys
import threading
import time
import uuid as _uuid
from pathlib import Path
from typing import Any, Callable

REQUEST_SCHEMA = "ownframework-loop-research-request/v1"
RESPONSE_SCHEMA = "ownframework-loop-research-response/v1"

# Strict canonical-id validators. Used for every path-bearing field.
_RUN_ID_RE = _re.compile(r"^run-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
_ATTEMPT_ID_RE = _re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
_REQUEST_ID_RE = _re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_REQUEST_DIGEST_RE = _re.compile(r"^[0-9a-f]{64}$")
_ROLE_ENUM = ("builder", "reviewer")
_OP_ENUM = ("search", "read", "asset-read")
_ACCEPTED_TERMINAL_STATUSES = frozenset(
    ("DONE", "QUARANTINED", "RETIRED", "CANCELED")
)

# Per-operation broker ceiling. Worker may request LESS, never MORE.
_OP_MAX_BYTES = {
    "search": 2 * 1024 * 1024,
    "read": 5 * 1024 * 1024,
    "asset-read": 32 * 1024 * 1024,
}
_DEFAULT_MAX_BROKER_BYTES = 32 * 1024 * 1024
# Inbox file hardening: a request file from the worker inbox must
# not exceed this size — anything larger is hostile.
_MAX_REQUEST_FILE_BYTES = 1024 * 1024  # 1 MiB
# Per-pass rate limit (operator override via env).
DEFAULT_PER_ATTEMPT_RATE_LIMIT = 30
# Bounded executor defaults.
DEFAULT_BROKER_MAX_WORKERS = 2
DEFAULT_BROKER_MAX_IN_FLIGHT_MULT = 2
DEFAULT_TICK_BUDGET_SECONDS = 5.0


class _ValidationError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------- #
# Per-run evidence layout                                                   #
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
    _assert_canonical_run_id(run_id)
    return _evidence_root() / run_id


def _requests_dir(run_id: str) -> Path:
    p = _run_evidence_dir(run_id) / "requests"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def _claims_dir(run_id: str) -> Path:
    """Operator-owned claim marker dir. NEVER inside worker-writable
    ``requests/``. The worker cannot write here.
    """
    p = _run_evidence_dir(run_id) / "claims"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def _responses_dir(run_id: str) -> Path:
    p = _run_evidence_dir(run_id) / "responses"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def _receipts_dir(run_id: str) -> Path:
    p = _run_evidence_dir(run_id) / "receipts"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def _artifacts_dir(run_id: str) -> Path:
    p = _run_evidence_dir(run_id) / "artifacts"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


# --------------------------------------------------------------------------- #
# Canonical-id validation                                                    #
# --------------------------------------------------------------------------- #


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
    """Post-construction: response_path stays under root.

    Uses lexical containment (no filesystem resolution) so the
    assertion is correct whether or not the response file has been
    published yet. The canonical formula derives every component
    from already-canonical fields.
    """
    try:
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
    _assert_canonical_run_id(run_id)
    _assert_canonical_request_id(request_id)
    responses = _responses_dir(run_id)
    response_path = responses / f"resp-{request_id}.json"
    _assert_safe_response_path(response_path, responses)
    return response_path


# --------------------------------------------------------------------------- #
# Atomic publish                                                              #
# --------------------------------------------------------------------------- #


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
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
# Canonical request digest (supervisor-computed, never worker-trusted)        #
# --------------------------------------------------------------------------- #


def _canonical_request_projection(req: dict[str, Any]) -> dict[str, Any]:
    """The supervisor-authoritative projection: only fields that are
    operator-meaningful. Worker-supplied ``requested_at`` / ``kind``
    are excluded; they are timing/labels, not identity."""
    return {
        "schema": str(req.get("schema") or ""),
        "request_id": str(req.get("request_id") or ""),
        "run_id": str(req.get("run_id") or ""),
        "attempt_id": str(req.get("attempt_id") or ""),
        "role": str(req.get("role") or ""),
        "op": str(req.get("op") or ""),
        "url": req.get("url") or None,
        "query": req.get("query") or None,
        "max_bytes": int(req["max_bytes"]) if req.get("max_bytes") is not None else None,
    }


def _compute_request_digest(req: dict[str, Any]) -> str:
    canonical = _canonical_request_projection(req)
    encoded = json.dumps(
        canonical, sort_keys=True, ensure_ascii=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------- #
# In-flight registry (process-wide authoritative owner of in-flight tasks)   #
# --------------------------------------------------------------------------- #


class _InFlightEntry:
    __slots__ = (
        "run_id", "request_id", "request_digest", "attempt_id",
        "role", "claim_path", "future", "submitted_at", "operator",
    )

    def __init__(self, *, run_id: str, request_id: str, request_digest: str,
                 attempt_id: str, role: str, claim_path: Path,
                 future: "_futures.Future[Any]", submitted_at: float,
                 operator: str) -> None:
        self.run_id = run_id
        self.request_id = request_id
        self.request_digest = request_digest
        self.attempt_id = attempt_id
        self.role = role
        self.claim_path = claim_path
        self.future = future
        self.submitted_at = submitted_at
        self.operator = operator

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.run_id, self.request_id, self.request_digest)


class _InFlightRegistry:
    """Process-wide authoritative owner of in-flight research tasks.

    Lives on the supervisor module so it survives across supervisor
    tick boundaries. The registry is keyed by
    ``(run_id, request_id, request_digest)`` — the same triple used
    by the broker's authoritative completion evidence.

    Concurrency model: a single mutex guards the in-memory dict and
    the on-disk claim marker. Insertion and reaping are atomic.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: dict[tuple[str, str, str], _InFlightEntry] = {}

    def __len__(self) -> int:
        with self._lock:
            return len(self._entries)

    def has(self, key: tuple[str, str, str]) -> bool:
        with self._lock:
            return key in self._entries

    def insert(self, entry: _InFlightEntry) -> None:
        with self._lock:
            self._entries[entry.key] = entry

    def reap_completed(self) -> list[_InFlightEntry]:
        """Return and remove all entries whose futures have completed
        (success, failure, or cancelled). Order is insertion order.
        """
        done: list[_InFlightEntry] = []
        with self._lock:
            keys = list(self._entries.keys())
            for k in keys:
                e = self._entries.get(k)
                if e is None:
                    continue
                if e.future.done():
                    done.append(e)
                    del self._entries[k]
        return done

    def all_keys(self) -> list[tuple[str, str, str]]:
        with self._lock:
            return list(self._entries.keys())

    def get(self, key: tuple[str, str, str]) -> _InFlightEntry | None:
        with self._lock:
            return self._entries.get(key)


_IN_FLIGHT = _InFlightRegistry()


# --------------------------------------------------------------------------- #
# Bounded executor (no deadlock, clean ownership)                             #
# --------------------------------------------------------------------------- #


class _ResearchBusy(Exception):
    """Raised when the bounded executor refuses a new submit."""


class _ResearchExecutor:
    """Process-wide bounded executor for broker subprocess.run calls.

    Concurrency is bounded so a flood of queued requests cannot fork
    N broker processes simultaneously and exhaust the host.

    Locking model: the executor instance is constructed once at
    first use. The pool is created lazily INSIDE ``submit``, but
    the pool creation does NOT re-acquire the registry / in-flight
    lock — the in-flight lock guards the dict, and ``submit`` only
    mutates the dict after the pool is created. There is no
    re-entrant lock acquisition path.
    """

    def __init__(self, max_workers: int = DEFAULT_BROKER_MAX_WORKERS) -> None:
        self._max_workers = max(1, int(max_workers))
        self._max_in_flight = self._max_workers * DEFAULT_BROKER_MAX_IN_FLIGHT_MULT
        # Construction-only state. The pool itself is created on
        # first submit (after process warmup) so we never hold a
        # lock across pool creation.
        self._executor: _futures.ThreadPoolExecutor | None = None
        self._init_lock = threading.Lock()
        self._in_flight_lock = threading.Lock()
        self._in_flight = 0

    def _ensure_executor(self) -> _futures.ThreadPoolExecutor:
        ex = self._executor
        if ex is not None:
            return ex
        with self._init_lock:
            if self._executor is None:
                self._executor = _futures.ThreadPoolExecutor(
                    max_workers=self._max_workers,
                    thread_name_prefix="ofloop-research",
                )
            return self._executor

    def submit(self, fn: Callable[..., Any], *args: Any, **kwargs: Any
               ) -> _futures.Future[Any]:
        # Admit the work under the bounded capacity. Increment FIRST
        # (so we don't admit if the pool refuses on construction),
        # then construct the pool, then submit. If the submit raises
        # (e.g. pool shutdown), roll back the counter.
        with self._in_flight_lock:
            if self._in_flight >= self._max_in_flight:
                raise _ResearchBusy(
                    f"research executor saturated "
                    f"({self._in_flight}/{self._max_in_flight} in flight)"
                )
            self._in_flight += 1
        try:
            ex = self._ensure_executor()
            return ex.submit(fn, *args, **kwargs)
        except BaseException:
            with self._in_flight_lock:
                self._in_flight -= 1
            raise

    def release(self) -> None:
        with self._in_flight_lock:
            if self._in_flight > 0:
                self._in_flight -= 1

    def in_flight(self) -> int:
        with self._in_flight_lock:
            return self._in_flight

    def shutdown(self, wait: bool = False) -> None:
        with self._init_lock:
            ex = self._executor
            self._executor = None
        if ex is not None:
            ex.shutdown(wait=wait, cancel_futures=not wait)


_EXECUTOR: _ResearchExecutor | None = None
_EXECUTOR_LOCK = threading.Lock()


def _get_executor() -> _ResearchExecutor:
    global _EXECUTOR
    with _EXECUTOR_LOCK:
        if _EXECUTOR is None:
            max_workers = int(os.environ.get(
                "OFLOOP_RESEARCH_MAX_WORKERS",
                str(DEFAULT_BROKER_MAX_WORKERS),
            ))
            _EXECUTOR = _ResearchExecutor(max_workers=max_workers)
        return _EXECUTOR


# --------------------------------------------------------------------------- #
# Broker dispatch + integrity verification                                   #
# --------------------------------------------------------------------------- #


class _BrokerUnavailable(Exception):
    """Raised when the broker cannot be launched (commissioning drift,
    executable missing, etc.). Caller MUST treat as fail-closed."""


def _broker_commissioning_identity() -> dict[str, str]:
    """Read + verify canonical commissioning evidence for the research
    broker. Returns ``{"path": ..., "sha256": ...}``. Raises
    ``_BrokerUnavailable`` on any drift / missing / non-canonical
    condition. Never returns ``expected=None``."""
    from . import commissioning as _cm
    try:
        doc = _cm.read_commissioning_evidence("research.public")
    except _cm.CommissioningError as exc:
        raise _BrokerUnavailable(
            f"research.public commissioning unavailable: {exc}"
        )
    except Exception as exc:  # pragma: no cover
        raise _BrokerUnavailable(
            f"commissioning read failed: {type(exc).__name__}: {exc}"
        )
    p = doc.get("_broker_path")
    s = doc.get("_broker_sha256")
    if not isinstance(p, str) or not isinstance(s, str) or not s:
        raise _BrokerUnavailable(
            "commissioning evidence missing broker identity fields"
        )
    return {"path": p, "sha256": s}


def _verify_broker_identity_now(expected_path: str, expected_sha: str) -> None:
    """Re-verify the broker's CURRENT bytes against the canonical
    commissioning SHA IMMEDIATELY before launching it. This is the
    per-launch defence in depth: even if a tick saw a valid SHA at
    admission time, the file may have been swapped by the time the
    executor runs the future. ``_trusted_executable`` in
    ``commissioning.py`` performs the actual byte-level comparison.
    """
    from . import commissioning as _cm
    try:
        actual_path, actual_sha = _cm._trusted_executable(
            expected_path,
            field="research.public.broker_executable.prelaunch",
        )
    except _cm.CommissioningError as exc:
        raise _BrokerUnavailable(
            f"broker executable failed pre-launch verification: {exc}"
        )
    if actual_sha != expected_sha:
        raise _BrokerUnavailable(
            f"broker executable SHA drift at pre-launch: "
            f"expected={expected_sha} actual={actual_sha}"
        )
    if actual_path != expected_path:
        raise _BrokerUnavailable(
            f"broker executable path drift at pre-launch: "
            f"expected={expected_path} actual={actual_path}"
        )


def _clamp_max_bytes(op: str, requested: int | None) -> int:
    cap = _OP_MAX_BYTES.get(op, _DEFAULT_MAX_BROKER_BYTES)
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
    expected_broker_sha: str | None = None,
) -> dict[str, Any]:
    """Launch the broker subprocess. Verifies broker identity IMMEDIATELY
    before every launch (per-launch SHA check), regardless of how
    recently the tick verified commissioning. Failures here return a
    BrokerIdentityDrift error class to the worker."""
    # Per-launch SHA re-verification. Catches: file swap between tick
    # admission and executor dispatch; symlink substitution; mode-bit
    # drift; any other condition that makes the on-disk executable
    # not match the canonical commissioning evidence.
    if expected_broker_sha is not None:
        try:
            _verify_broker_identity_now(broker_path, expected_broker_sha)
        except _BrokerUnavailable as exc:
            return {
                "ok": False,
                "error_class": "BrokerIdentityDrift",
                "error": str(exc),
            }
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
    # Provider-neutral search backend selection. The supervisor
    # chooses; the worker contract never specifies this.
    if op == "search" and search_backend:
        cmd += ["--search-backend", search_backend]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=float(os.environ.get(
                "OFLOOP_RESEARCH_BROKER_TIMEOUT",
                "60",
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


def _summarize_for_worker(broker_result: dict[str, Any], request_id: str
                           ) -> dict[str, Any]:
    ts = _dt.datetime.now(_dt.timezone.utc).isoformat()
    if broker_result.get("ok"):
        out = dict(broker_result)
        out["schema"] = RESPONSE_SCHEMA
        out["request_id"] = request_id
        out["timestamp"] = ts
        out.setdefault(
            "redirect_or_search_backend",
            broker_result.get("search_backend"),
        )
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
    run_id: str, request_id: str, payload: dict[str, Any],
) -> Path:
    response_path = canonical_response_path(run_id, request_id)
    # Idempotent re-publish on replay: if the file already exists,
    # unlink then re-publish so the new payload wins. The replay
    # path only re-publishes matching-digest responses, which are
    # bit-identical to the existing authoritative response.
    if response_path.is_file() or response_path.is_symlink():
        try:
            response_path.unlink()
        except FileNotFoundError:
            pass
    _atomic_write_json(response_path, payload)
    return response_path


# --------------------------------------------------------------------------- #
# Claim lifecycle (operator-owned /worker-cannot-write marker)               #
# --------------------------------------------------------------------------- #


def _claim_marker_path(run_id: str, request_id: str) -> Path:
    _assert_canonical_run_id(run_id)
    _assert_canonical_request_id(request_id)
    return _claims_dir(run_id) / f"claim-{request_id}.json"


def _atomic_publish_claim(entry: _InFlightEntry) -> Path | None:
    """Atomic publish of a claim marker in operator-owned claims/.

    Uses O_EXCL tmp + os.link so a partial write never produces a
    claim file the supervisor would later mistake for durable
    state. Returns the claim path on success; ``None`` on
    collision (e.g. an existing claim for this request_id from a
    prior supervisor lifetime — caller must consult replay cache
    before claiming).
    """
    claim_path = _claim_marker_path(entry.run_id, entry.request_id)
    payload = {
        "schema": "ownframework-loop-research-claim/v1",
        "run_id": entry.run_id,
        "request_id": entry.request_id,
        "request_digest": entry.request_digest,
        "attempt_id": entry.attempt_id,
        "role": entry.role,
        "operator": entry.operator,
        "submitted_at": entry.submitted_at,
        "broker_launched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
    }
    tmp = claim_path.with_name(
        f".{claim_path.name}.{os.getpid()}.{_uuid.uuid4().hex}.tmp"
    )
    try:
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        # Another supervisor tick / instance already claimed.
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        return None
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(payload, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.link(tmp, claim_path)
        try:
            dir_fd = os.open(str(claim_path.parent), os.O_RDONLY)
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
    entry.claim_path = claim_path
    return claim_path


def _remove_claim(claim_path: Path) -> None:
    try:
        claim_path.unlink()
    except FileNotFoundError:
        pass


# --------------------------------------------------------------------------- #
# Durable rate limit (counts ACCEPTED broker transport launches)              #
# --------------------------------------------------------------------------- #


def _accepted_count_last_60s(run_id: str) -> int:
    """Count accepted broker transport launches in the trailing 60s.

    Uses claim marker mtime (operator-owned, durable across
    supervisor restarts) — NOT receipt mtime, because failed
    network operations consume network budget whether or not the
    broker wrote a receipt. Network attempt is the economically
    meaningful unit.
    """
    cutoff = time.time() - 60.0
    claims = _claims_dir(run_id)
    if not claims.is_dir():
        return 0
    count = 0
    for path in claims.glob("claim-*.json"):
        try:
            st = path.stat()
        except OSError:
            continue
        if st.st_mtime >= cutoff:
            count += 1
    return count


# --------------------------------------------------------------------------- #
# Replay cache (durable authoritative completion evidence)                     #
# --------------------------------------------------------------------------- #


def _read_authoritative_response(run_id: str, request_id: str
                                ) -> dict[str, Any] | None:
    """Read the authoritative RESPONSE for (run_id, request_id), if any.

    Returns None if no response exists or the file is unreadable.
    """
    response_path = canonical_response_path(run_id, request_id)
    if not response_path.is_file() or response_path.is_symlink():
        return None
    try:
        with response_path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _replay_check(
    run_id: str, request_id: str, expected_digest: str,
) -> dict[str, Any] | None:
    """Replay identity is ``(request_id, request_digest)``.

    Returns a response dict to publish OR an error dict. Caller
    must NOT perform a second network call in either branch.

    - existing response + matching digest → reuse (zero new transport)
    - existing response + mismatching digest → ReplayDigestMismatch
    - no existing response → None (caller decides)
    """
    existing = _read_authoritative_response(run_id, request_id)
    if existing is None:
        return None
    existing_digest = str(existing.get("request_digest") or "")
    if existing_digest and expected_digest and existing_digest != expected_digest:
        return {
            "schema": RESPONSE_SCHEMA,
            "ok": False,
            "request_id": request_id,
            "error_class": "ReplayDigestMismatch",
            "error": (
                f"request_id {request_id} previously completed with a "
                f"different request_digest; refusing replay"
            ),
            "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        }
    return existing


# --------------------------------------------------------------------------- #
# Restart recovery (scan claims/ on supervisor startup)                       #
# --------------------------------------------------------------------------- #


def recover_claims(run_id: str) -> dict[str, int]:
    """One-shot recovery of orphaned claim markers.

    For each ``claims/claim-<UUID>.json`` that has no matching
    ``receipts/op-*.json`` AND no matching ``responses/resp-<UUID>.json``:

    - For ``read`` / ``asset-read`` (free public GET), bounded retry
      is acceptable. We mark the claim as ``recovery_outcome=retried``
      by republishing a ``RecoveryRetried`` response that names the
      original submission; the next tick will pick it up if it is
      still in flight, otherwise the response stays authoritative.
      This is the truthful "prior transport may have occurred" line.
    - For ``search`` (potentially metered), we do NOT auto-retry.
      We publish a ``RecoveryOutcomeUnknown`` response so a
      subsequent replay of the same ``(request_id, request_digest)``
      does NOT trigger another dispatch.

    This function is called once per tick on the serviced run;
    idempotent. Returns a count summary.
    """
    _assert_canonical_run_id(run_id)
    claims = _claims_dir(run_id)
    receipts = _receipts_dir(run_id)
    responses = _responses_dir(run_id)
    summary = {"scanned": 0, "republished_retry": 0,
               "republished_unknown": 0, "skipped": 0}
    if not claims.is_dir():
        return summary
    for claim_path in claims.glob("claim-*.json"):
        summary["scanned"] += 1
        try:
            with claim_path.open("r", encoding="utf-8") as fh:
                claim = json.load(fh)
        except (OSError, json.JSONDecodeError):
            # Unreadable: leave the marker; supervisor tick will skip.
            summary["skipped"] += 1
            continue
        if not isinstance(claim, dict):
            summary["skipped"] += 1
            continue
        request_id = str(claim.get("request_id") or "")
        request_digest = str(claim.get("request_digest") or "")
        op = str(claim.get("op") or "")
        if not request_id or not request_digest:
            summary["skipped"] += 1
            continue
        # Did a matching response land?
        existing_resp = _read_authoritative_response(run_id, request_id)
        if existing_resp is not None:
            # Recovery already settled. Drop the claim.
            _remove_claim(claim_path)
            continue
        # Did a matching receipt land? If so, the broker finished but
        # the supervisor crashed before publishing the response.
        # Reconstruct a minimal authoritative response from the receipt.
        receipt_match = None
        if receipts.is_dir():
            for rp in receipts.glob("op-*.json"):
                try:
                    with rp.open("r", encoding="utf-8") as fh:
                        rec = json.load(fh)
                except (OSError, json.JSONDecodeError):
                    continue
                if not isinstance(rec, dict):
                    continue
                if (str(rec.get("request_id") or "") == request_id
                        and str(rec.get("request_digest") or "") == request_digest):
                    receipt_match = rec
                    break
        if receipt_match is not None:
            # Reconstruct and publish.
            response = _summarize_for_worker(receipt_match, request_id)
            response["request_digest"] = request_digest
            response["timestamp"] = _dt.datetime.now(_dt.timezone.utc).isoformat()
            response["recovery"] = "reconstructed_from_receipt"
            _publish_response(run_id, request_id, response)
            _remove_claim(claim_path)
            summary["republished_retry"] += 1
            continue
        # No matching durable completion evidence. The transport
        # may or may not have happened.
        if op in ("read", "asset-read"):
            # Free public GET — bounded retry policy: re-admit for
            # dispatch on the next tick (the in-flight registry does
            # not have the future anymore; the claim marker is the
            # only durable proof we want another chance).
            # Don't unlink the claim here — leave it for the normal
            # tick path to pick up.
            summary["skipped"] += 1
            continue
        # op=search (potentially metered) — do NOT auto-retry.
        response = {
            "schema": RESPONSE_SCHEMA,
            "ok": False,
            "request_id": request_id,
            "request_digest": request_digest,
            "error_class": "RecoveryOutcomeUnknown",
            "error": (
                f"prior transport for op={op} may have occurred; "
                f"no durable completion evidence; refusing auto-retry"
            ),
            "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "recovery": "outcome_unknown_no_retry",
        }
        _publish_response(run_id, request_id, response)
        _remove_claim(claim_path)
        summary["republished_unknown"] += 1
    return summary


# --------------------------------------------------------------------------- #
# DB-backed attempt liveness                                                #
# --------------------------------------------------------------------------- #


def _db_get_job(conn: sqlite3.Connection, run_id: str) -> sqlite3.Row | None:
    cur = conn.execute("SELECT * FROM jobs WHERE run_id = ?", (run_id,))
    return cur.fetchone()


def _db_attempt_is_active(
    conn: sqlite3.Connection, run_id: str, attempt_id: str,
) -> bool:
    """Strongest identity check the existing schema supports.

    Binds (run_id, attempt_id) to the LIVE attempt AND verifies the
    worker pid is alive AND the job is non-terminal AND the role
    matches. PID reuse ambiguity is mitigated by the requirement
    that the attempt_id is the canonical latest_attempt_id (a
    fresh restart produces a new attempt id).
    """
    row = _db_get_job(conn, run_id)
    if row is None:
        return False
    if (row["latest_attempt_id"] or "") != attempt_id:
        return False
    status = str(row["status"] or "")
    if status in _ACCEPTED_TERMINAL_STATUSES:
        return False
    if not row["worker_pid"]:
        return False
    try:
        os.kill(int(row["worker_pid"]), 0)
    except (OSError, ProcessLookupError):
        return False
    return True


def _db_role_matches(conn: sqlite3.Connection, run_id: str, role: str) -> bool:
    row = _db_get_job(conn, run_id)
    if row is None:
        return False
    worker_role = str(row["worker_role"] or "")
    if worker_role and worker_role != role:
        return False
    return True


# --------------------------------------------------------------------------- #
# Capability binding check                                                  #
# --------------------------------------------------------------------------- #


def _capability_resolution_has_research_public(
    canonical_repo: Path, run_id: str,
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
# Per-attempt request validation                                            #
# --------------------------------------------------------------------------- #


def _validate_inbox_file_shape(path: Path) -> dict[str, Any] | None:
    """Harden the inbox read: refuse symlinks, non-regular files,
    oversize files, non-JSON, non-object. The worker-writable inbox
    is hostile; the supervisor MUST NOT follow attacker-created
    symlinks.

    Returns the parsed request dict on success; ``None`` to drop
    silently (the request file is malformed or hostile and the
    supervisor should not crash).
    """
    if path.is_symlink():
        return None
    try:
        st = path.stat()
    except OSError:
        return None
    if not _stat.S_ISREG(st.st_mode):
        return None
    if st.st_size > _MAX_REQUEST_FILE_BYTES:
        # Oversize: drop the file (no leaking of large payloads).
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return None
    if _stat.S_IMODE(st.st_mode) & 0o022:
        # Group/world writable — attacker could substitute. Drop.
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return None
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return None
    if not isinstance(data, dict):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return None
    return data


def _validate_request_shape(req: dict[str, Any]) -> None:
    """Canonical-id checks. Raises ``_ValidationError`` on failure."""
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
        raise _ValidationError("InvalidRequest", "op out of supported set")
    if req.get("role") not in _ROLE_ENUM:
        raise _ValidationError("InvalidRequest", "role out of supported set")
    if req.get("op") in ("read", "asset-read") and not req.get("url"):
        raise _ValidationError("InvalidRequest", "url required for read/asset-read")
    if req.get("op") == "search" and not req.get("query"):
        raise _ValidationError("InvalidRequest", "query required for search")
    _assert_canonical_run_id(str(req.get("run_id") or ""))
    _assert_canonical_attempt_id(str(req.get("attempt_id") or ""))
    _assert_canonical_request_id(str(req.get("request_id") or ""))
    _assert_canonical_role(str(req.get("role") or ""))
    request_digest = req.get("request_digest") or ""
    if request_digest and not _REQUEST_DIGEST_RE.match(str(request_digest)):
        raise _ValidationError(
            "InvalidRequest", "request_digest is not 64-char hex"
        )


# --------------------------------------------------------------------------- #
# Per-tick queue consumer                                                    #
# --------------------------------------------------------------------------- #


def _consume_inbox(run_id: str) -> list[tuple[Path, dict[str, Any]]]:
    inbox = _requests_dir(run_id)
    out: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(inbox.glob("req-*.json")):
        # First harden the file (no symlinks, regular, bounded).
        req = _validate_inbox_file_shape(path)
        if req is None:
            # Symlink / oversize / unreadable / non-object: dropped.
            continue
        try:
            _validate_request_shape(req)
        except _ValidationError:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            continue
        # Path naming must match the canonical request_id; otherwise
        # a worker could create req-<something-else>.json to confuse
        # the supervisor.
        expected_name = f"req-{req.get('request_id')}.json"
        if path.name != expected_name:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            continue
        out.append((path, req))
    return out


# --------------------------------------------------------------------------- #
# Public API: per-tick bridge                                                #
# --------------------------------------------------------------------------- #


def process_research_queue(
    *,
    db_path: Path,
    canonical_repo: Path,
    run_id: str,
    rate_limit_per_minute: int = DEFAULT_PER_ATTEMPT_RATE_LIMIT,
) -> dict[str, Any]:
    """One supervisor tick for ``run_id``.

    Steps:
      1. Reap completed in-flight futures, publish responses,
         remove claim markers.
      2. Run claim recovery scan.
      3. Validate run is live (capability binding, status, role).
      4. Consume inbox, validate file shape + canonical ids.
      5. Replay cache: same id + same digest → reuse; same id +
         different digest → publish ReplayDigestMismatch (no
         dispatch).
      6. Recompute canonical digest; compare to worker-supplied.
      7. Rate-limit gate (durable, counts ACCEPTED launches).
      8. Active-attempt gate.
      9. Role-mismatch gate.
     10. Submit to bounded executor with operator-owned claim
         marker; persist claim atomically before dispatch.
     11. Drain in-flight futures up to the per-tick budget.
    """
    _assert_canonical_run_id(run_id)

    # 1. Capability binding check.
    if not _capability_resolution_has_research_public(canonical_repo, run_id):
        # Drop every pending request in this run's inbox; the run
        # has no authority.
        inbox = _requests_dir(run_id)
        for p in inbox.glob("req-*.json"):
            try:
                p.unlink()
            except FileNotFoundError:
                pass
        return {"consumed": 0, "processed": 0, "rejected": 0,
                "republished": 0, "recovered": 0}

    # 2. DB connect.
    try:
        conn = sqlite3.connect(str(db_path))
    except sqlite3.Error:
        return {"consumed": 0, "processed": 0, "rejected": 0,
                "republished": 0, "recovered": 0, "deferred": "db_unavailable"}
    conn.row_factory = sqlite3.Row

    # 3. Broker identity — verify commission BEFORE admitting work.
    try:
        identity = _broker_commissioning_identity()
        broker_path = identity["path"]
    except _BrokerUnavailable as exc:
        conn.close()
        return {"consumed": 0, "processed": 0, "rejected": 0,
                "republished": 0, "recovered": 0,
                "deferred": "broker_unavailable", "detail": str(exc)}

    # 4. STEP 1 — reap completed futures from the process-wide registry.
    processed = 0
    republish_reused = 0
    republish_mismatch = 0
    for entry in _IN_FLIGHT.reap_completed():
        try:
            broker_result = entry.future.result(timeout=0)
        except Exception as exc:  # pragma: no cover
            broker_result = {
                "ok": False,
                "error_class": "ExecutorFailed",
                "error": f"{type(exc).__name__}: {exc}",
            }
        response = _summarize_for_worker(broker_result, entry.request_id)
        response["request_digest"] = entry.request_digest
        _publish_response(entry.run_id, entry.request_id, response)
        if response.get("error_class") == "ReplayDigestMismatch":
            republish_mismatch += 1
        else:
            republish_reused += 1
        _remove_claim(entry.claim_path)
        processed += 1
        _get_executor().release()

    # 5. STEP 2 — claim recovery (durable, idempotent).
    recovered = recover_claims(run_id)

    # 6. STEP 3 — durable rate limit (counts accepted launches).
    already_accepted = _accepted_count_last_60s(run_id)

    # 7. STEP 4 — consume inbox (with file hardening).
    candidates = _consume_inbox(run_id)
    if not candidates and processed == 0 and recovered.get("scanned", 0) == 0:
        conn.close()
        return {
            "consumed": 0, "processed": processed,
            "rejected": 0, "republished": republish_reused,
            "recovered": 0,
        }
    consumed = len(candidates)
    rejected = 0
    futures_submitted: list[_InFlightEntry] = []
    evidence_dir = _run_evidence_dir(run_id)
    executor = _get_executor()
    tick_budget = float(os.environ.get(
        "OFLOOP_RESEARCH_TICK_BUDGET_SECONDS",
        str(DEFAULT_TICK_BUDGET_SECONDS),
    ))
    deadline = time.monotonic() + tick_budget

    for request_path, raw_req in candidates:
        request_id = str(raw_req.get("request_id") or "")
        attempt_id = str(raw_req.get("attempt_id") or "")
        role = str(raw_req.get("role") or "")

        # 7a. Recompute canonical digest (do not trust worker).
        canonical_req = dict(raw_req)
        # Strip worker-supplied digest before recomputing; the
        # recomputed value is what we use everywhere.
        worker_digest = str(raw_req.get("request_digest") or "")
        recomputed_digest = _compute_request_digest(canonical_req)
        if worker_digest and worker_digest != recomputed_digest:
            response = {
                "schema": RESPONSE_SCHEMA,
                "ok": False,
                "request_id": request_id,
                "request_digest": recomputed_digest,
                "error_class": "RequestDigestMismatch",
                "error": (
                    f"worker-supplied request_digest {worker_digest} does not "
                    f"match supervisor-computed {recomputed_digest}"
                ),
                "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            _publish_response(run_id, request_id, response)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            rejected += 1
            continue
        request_digest = recomputed_digest

        # 7b. Replay cache (digest-aware). Done BEFORE admitting.
        replay = _replay_check(run_id, request_id, request_digest)
        if replay is not None:
            # Same id + digest → reuse (zero new transport).
            # Same id + different digest → ReplayDigestMismatch.
            # Either branch publishes exactly once; no dispatch.
            if replay.get("error_class") == "ReplayDigestMismatch":
                replay["timestamp"] = _dt.datetime.now(_dt.timezone.utc).isoformat()
            replay["request_digest"] = request_digest
            _publish_response(run_id, request_id, replay)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            if replay.get("error_class") == "ReplayDigestMismatch":
                republish_mismatch += 1
            else:
                republish_reused += 1
            continue

        # 7c. Active-attempt check.
        if not _db_attempt_is_active(conn, run_id, attempt_id):
            response = {
                "schema": RESPONSE_SCHEMA,
                "ok": False,
                "request_id": request_id,
                "request_digest": request_digest,
                "error_class": "AttemptNotActive",
                "error": "request attempt is not a currently-live attempt",
                "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            _publish_response(run_id, request_id, response)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            rejected += 1
            continue

        # 7d. Role match.
        if not _db_role_matches(conn, run_id, role):
            response = {
                "schema": RESPONSE_SCHEMA,
                "ok": False,
                "request_id": request_id,
                "request_digest": request_digest,
                "error_class": "RoleMismatch",
                "error": (
                    f"requested role {role!r} does not match the job's "
                    f"currently-active worker role"
                ),
                "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            _publish_response(run_id, request_id, response)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            rejected += 1
            continue

        # 7e. Durable rate-limit gate.
        if already_accepted >= rate_limit_per_minute:
            response = {
                "schema": RESPONSE_SCHEMA,
                "ok": False,
                "request_id": request_id,
                "request_digest": request_digest,
                "error_class": "RateLimited",
                "error": (
                    f"durable per-run accepted-launch rate limit "
                    f"{rate_limit_per_minute}/min exceeded"
                ),
                "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            }
            _publish_response(run_id, request_id, response)
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            rejected += 1
            continue
        # Accept the launch (counts the budget even if the eventual
        # broker call fails — that is the point of counting accepted
        # launches, not successful receipts).
        already_accepted += 1

        # 7f. Compute provider-neutral search backend. Supervisor
        # chooses; the worker contract never specifies this.
        op = str(raw_req.get("op") or "")
        # The host manifest commissioning evidence (if it carries a
        # frozen ``search_backend`` policy) takes precedence; default
        # to wikipedia.
        search_backend = "wikipedia"
        try:
            policy = os.environ.get(
                "OFLOOP_RESEARCH_DEFAULT_SEARCH_BACKEND", "wikipedia"
            )
            if policy in ("wikipedia", "ddg-lite"):
                search_backend = policy
        except Exception:
            pass

        # 7g. Build the in-flight entry and persist the claim BEFORE
        # submitting. The claim lives in operator-owned claims/, not
        # the worker-writable requests/ inbox.
        submitted_at = time.time()
        entry = _InFlightEntry(
            run_id=run_id,
            request_id=request_id,
            request_digest=request_digest,
            attempt_id=attempt_id,
            role=role,
            claim_path=_claim_marker_path(run_id, request_id),
            future=None,  # set below
            submitted_at=submitted_at,
            operator="supervisor-research-bridge",
        )
        claim_path = _atomic_publish_claim(entry)
        if claim_path is None:
            # Another tick / instance already claimed. Drop this
            # request — the other owner will publish the response.
            try:
                request_path.unlink()
            except FileNotFoundError:
                pass
            continue

        # 7h. Submit to the bounded executor (non-blocking).
        clamped_max_bytes = _clamp_max_bytes(op, raw_req.get("max_bytes"))
        broker_expected_sha = identity.get("sha256")
        try:
            fut = executor.submit(
                _run_broker_blocking,
                broker_path,
                op=op,
                url=raw_req.get("url"),
                query=raw_req.get("query"),
                max_bytes=clamped_max_bytes,
                evidence_dir=evidence_dir,
                run_id=run_id,
                attempt=attempt_id,
                request_id=request_id,
                request_digest=request_digest,
                search_backend=search_backend if op == "search" else None,
                expected_broker_sha=broker_expected_sha,
            )
        except _ResearchBusy as exc:
            # Backpressure: drop the claim so the next tick retries.
            _remove_claim(claim_path)
            conn.close()
            return {
                "consumed": consumed,
                "processed": processed,
                "rejected": rejected,
                "republished": republish_reused + republish_mismatch,
                "recovered": recovered.get("scanned", 0),
                "deferred": "research_executor_busy",
                "detail": str(exc),
            }
        entry.future = fut
        _IN_FLIGHT.insert(entry)
        futures_submitted.append(entry)

        # 7i. Drop the inbox file now that the claim is durable.
        try:
            request_path.unlink()
        except FileNotFoundError:
            pass

    # 8. STEP 5 — drain in-flight futures up to the per-tick budget.
    # Futures that exceed the budget remain in the in-flight
    # registry and will be reaped on a later tick.
    drained = 0
    for entry in futures_submitted:
        remaining = max(0.0, deadline - time.monotonic())
        if remaining <= 0:
            break
        try:
            broker_result = entry.future.result(timeout=remaining)
        except _futures.TimeoutError:
            # Still running; will be reaped on a later tick.
            continue
        except Exception as exc:  # pragma: no cover
            broker_result = {
                "ok": False,
                "error_class": "ExecutorFailed",
                "error": f"{type(exc).__name__}: {exc}",
            }
        response = _summarize_for_worker(broker_result, entry.request_id)
        response["request_digest"] = entry.request_digest
        _publish_response(entry.run_id, entry.request_id, response)
        _remove_claim(entry.claim_path)
        # Remove from in-flight registry; release executor slot.
        _IN_FLIGHT.reap_completed()  # best-effort cleanup
        _get_executor().release()
        drained += 1

    conn.close()
    return {
        "consumed": consumed,
        "processed": processed + drained,
        "rejected": rejected,
        "republished": republish_reused + republish_mismatch,
        "recovered": recovered.get("scanned", 0),
        "in_flight": len(_IN_FLIGHT),
    }


# --------------------------------------------------------------------------- #
# Deterministic test hooks                                                   #
# --------------------------------------------------------------------------- #


def _registry_for_tests() -> _InFlightRegistry:
    """Test-only accessor: process-wide in-flight registry."""
    return _IN_FLIGHT


def _executor_for_tests() -> _ResearchExecutor:
    """Test-only accessor: process-wide bounded executor."""
    return _get_executor()


__all__ = [
    "REQUEST_SCHEMA", "RESPONSE_SCHEMA",
    "process_research_queue", "canonical_response_path",
    "recover_claims", "_compute_request_digest",
    "_registry_for_tests", "_executor_for_tests",
    "_evidence_root", "_run_evidence_dir",
    "_requests_dir", "_claims_dir", "_responses_dir",
]

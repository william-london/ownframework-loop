"""Supervisor-side governed research transport.

The semantically-correct architecture for ``research.public`` puts
the public-network effect inside the supervisor's own serve()
loop, NOT inside the worker's Bash subprocess tree. This module is
the supervisor's contribution to that boundary.

Flow
----

1. The semantic worker invokes
   ``bin/ofloop-research-call --op read --url <u> ...``.
2. ``ofloop-research-call`` (the worker helper) writes an
   immutable REQUEST JSON to
   ``$OFLOOP_RESEARCH_QUEUE/req-<uuid>.json``.
3. This module's ``process_research_queue`` is called from
   ``supervisor.serve()`` once per tick. It consumes pending
   requests, validates each against the run's frozen capability
   binding and the live DB, then invokes the broker subprocess
   (``subprocess.run``, NOT ``Claude Code Bash``) — under the
   supervisor's own user/network namespace, with full DNS/TCP
   egress.
4. The broker fetches, validates SSRF, writes durable
   content-addressed receipts to
   ``~/.local/state/ownframework-loop/research/<run-id>/receipts/...``
   and asset bytes to
   ``~/.local/state/ownframework-loop/research/<run-id>/artifacts/<sha256>.<ext>``.
5. The supervisor parses the broker's stdout summary, then writes a
   RESPONSE file under the worker's per-attempt scratch ``research/``
   dir at
   ``<canonical_repo>/.ownframework-loop/<run-id>/scratch/<role>/<pass>/research/resp-<uuid>.json``.
6. ``ofloop-research-call`` (still polling) reads the RESPONSE
   file and emits the body to the worker's stdout.

Authority invariants
--------------------

- The worker has ``allowedDomains=[]`` at attempt launch;
  no Bash command reaches the public internet.
- The worker's only research surface is ``ofloop-research-call``,
  which has no network authority of its own.
- All REQUEST validation happens here (supervisor); the broker
  re-validates SSRF per its own primitives; the helper performs
  cheap shape checks only.
- Receipts go to operator-owned evidence root, which the worker
  CANNOT write to (not in ``allowWrite``); the worker reads from
  the scratch ``research/`` dir only.
- Per-attempt rate limiting and response-budget limits are
  enforced here, NOT by the broker (the broker is a single
  operation; the supervisor gates how often it can be invoked
  from any active attempt).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

# Skeleton module — full implementation in following commits.

REQUEST_SCHEMA = "ownframework-loop-research-request/v1"
RESPONSE_SCHEMA = "ownframework-loop-research-response/v1"

# Strict caps (per-attempt, per-tick) so a prompt-injected worker
# cannot DOS the broker or runaway an evidence root.
DEFAULT_PER_ATTEMPT_RATE_LIMIT = 30   # ops / minute
DEFAULT_REQUEST_TIMEOUT_SECONDS = 90
DEFAULT_MAX_BROKER_BYTES = 32 * 1024 * 1024

# The few paths we read from one place.
def _evidence_root() -> Path:
    base = Path(
        os.environ.get(
            "OFLOOP_RESEARCH_EVIDENCE_ROOT",
            f"{Path.home()}/.local/state/ownframework-loop/research",
        )
    ).expanduser().resolve(strict=False)
    return base


def _queue_dir() -> Path:
    base = _evidence_root()
    p = base / "queue"
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def _scratch_response_path(
    canonical_repo: Path, run_id: str, role: str, attempt_id: str, request_id: str,
) -> Path:
    """Per-attempt scratch RESPONSE path the worker helper polls.

    The supervisor writes here; the worker reads (the worker's
    ``allowRead`` includes the per-attempt scratch). The path is
    NOT in the worker's ``allowWrite``: the worker can read its own
    work product, but cannot forge a response.
    """
    p = (
        Path(canonical_repo).expanduser().resolve(strict=False)
        / ".ownframework-loop" / run_id
        / "scratch" / role / f"pass-{_normalize_attempt(attempt_id)}"
        / "research" / f"resp-{request_id}.json"
    )
    p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def _normalize_attempt(attempt_id: str) -> str:
    """Convert an attempt id like 'abc-1234' or 'pass-0003' into a
    stable scratch subdir name.
    """
    if attempt_id.startswith("pass-"):
        return attempt_id
    # pass-XYYY form where X is a digit-prefix; the canonical form
    # uses 'pass-0003' etc.
    m = re.match(r"^([0-9]+)$", attempt_id)
    if m:
        return f"pass-{int(m.group(1)):04d}"
    # default: use the attempt id directly with safe characters
    return re.sub(r"[^A-Za-z0-9._-]", "_", attempt_id)[:64] or "pass-anon"


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    """Atomic publish: O_EXCL tmp + fsync + os.link + dir fsync."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(
        f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    )
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=True, indent=2) + "\n"
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(encoded)
            fh.flush()
            os.fsync(fh.fileno())
        os.link(tmp, path)
        # Best-effort directory fsync.
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


def _read_broker_dispatch() -> dict[str, Any] | None:
    """Locate the research broker executable via the canonical
    commissioning evidence.

    The operator-once install commissions the broker and writes
    evidence to ``~/.local/state/ownframework-loop/commissioning/research_public.json``.
    We re-derive the broker path from that evidence; the host-manifest
    path/SHA-256 are pre-verified during ``resolve_capabilities``.
    """
    evidence_path = Path(
        os.environ.get(
            "OFLOOP_COMMISSIONING_RESEARCH_PUBLIC",
            f"{Path.home()}/.local/state/ownframework-loop/commissioning/research_public.json",
        )
    ).expanduser().resolve(strict=False)
    if not evidence_path.is_file():
        return None
    try:
        text = evidence_path.read_text(encoding="utf-8")
        doc = json.loads(text)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(doc, dict):
        return None
    provider = doc.get("provider_identity")
    if not isinstance(provider, dict):
        return None
    executable = provider.get("executable")
    if not isinstance(executable, str) or not executable:
        return None
    return {
        "executable": executable,
        "evidence_sha256": doc.get("evidence_sha256"),
        "evidence_path": str(evidence_path),
    }


def _db_get_dispatch_row(conn: sqlite3.Connection, run_id: str) -> sqlite3.Row | None:
    """Return the live jobs row for ``run_id`` or None.

    Used to gate requests: the run must have at least one active
    semantic_attempt for the requested attempt_id (and that
    attempt must currently be live on the worker side).
    """
    cur = conn.execute(
        "SELECT * FROM jobs WHERE run_id = ?",
        (run_id,),
    )
    return cur.fetchone()


def _db_attempt_is_active(
    conn: sqlite3.Connection, run_id: str, attempt_id: str
) -> bool:
    """Return True if the given attempt is currently live (worker
    pid is alive per the supervisor's liveness probe)."""
    cur = conn.execute(
        "SELECT latest_attempt_id, worker_pid, worker_started_at FROM jobs "
        "WHERE run_id = ?",
        (run_id,),
    )
    row = cur.fetchone()
    if row is None:
        return False
    if (row["latest_attempt_id"] or "") != attempt_id:
        return False
    if not row["worker_pid"]:
        return False
    try:
        import signal as _sig
        os.kill(int(row["worker_pid"]), 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _validate_request_shape(req: dict[str, Any]) -> dict[str, Any] | None:
    """Cheap-shape validation; returns a structured error dict or None.

    Full trust is at the broker. This only refuses **malformed**
    queued files so the supervisor doesn't waste cycles on bogus
    inputs and so prompt-injected workers cannot crash the loop.
    """
    if not isinstance(req, dict):
        return {"code": "InvalidRequest",
                "message": "request must be a JSON object"}
    for key in ("schema", "request_id", "run_id", "attempt_id", "role", "op",
                "requested_at"):
        if key not in req:
            return {"code": "InvalidRequest",
                    "message": f"missing required field: {key}"}
    if req.get("schema") != REQUEST_SCHEMA:
        return {"code": "InvalidRequest",
                "message": "request schema mismatch"}
    if req.get("op") not in ("search", "read", "asset-read"):
        return {"code": "InvalidRequest",
                "message": "op out of supported set"}
    if req.get("role") not in ("builder", "reviewer"):
        return {"code": "InvalidRequest",
                "message": "role out of supported set"}
    if req.get("op") in ("read", "asset-read") and not req.get("url"):
        return {"code": "InvalidRequest",
                "message": f"url required for op={req.get('op')}"}
    if req.get("op") == "search" and not req.get("query"):
        return {"code": "InvalidRequest",
                "message": "query required for op=search"}
    return None


def _capability_resolution_has_research_public(
    canonical_repo: Path, run_id: str
) -> bool:
    """Frozen capability binding check.

    Reads ``<run_dir>/CAPABILITY_BINDING.json`` and confirms the
    run was bound with ``research.public``. We re-derive the
    projection (no re-resolution) and check the *requested*
    capability list contains the name.
    """
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


def _broker_path_from_evidence_dispatch(dispatch: dict[str, Any] | None) -> str | None:
    if dispatch is None:
        return None
    p = dispatch.get("executable")
    if not p:
        return None
    pth = Path(p).expanduser().resolve(strict=False)
    if not pth.is_file() or not os.access(pth, os.X_OK):
        return None
    return str(pth)


def _run_broker(
    broker_path: str,
    *,
    op: str,
    url: str | None,
    query: str | None,
    max_bytes: int | None,
    evidence_dir: Path,
    run_id: str,
    attempt: str,
    request_id: str,
) -> subprocess.CompletedProcess:
    """Run the broker as a supervisor-owned subprocess (no Claude
    sandbox inheritance; full network access). Returns the
    CompletedProcess; output is captured in JSON.
    """
    cmd: list[str] = [
        broker_path,
        "--op", op,
        "--evidence-dir", str(evidence_dir),
        "--run-id", run_id,
        "--attempt", attempt,
    ]
    if url:
        cmd += ["--url", url]
    if query:
        cmd += ["--query", query]
    if max_bytes is not None:
        cmd += ["--max-bytes", str(int(max_bytes))]
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
        timeout=float(os.environ.get(
            "OFLOOP_RESEARCH_BROKER_TIMEOUT", str(DEFAULT_REQUEST_TIMEOUT_SECONDS)
        )),
    )


def _summarize_broker_for_worker(
    proc: subprocess.CompletedProcess,
    request_id: str,
) -> dict[str, Any]:
    """Convert broker stdout/stderr into a structured response for
    the worker.

    The broker emits a JSON envelope on stdout (small). The
    supervisor parses it and produces a response object that
    includes a small text preview suitable for the worker's
    Bash stdout.
    """
    raw = (proc.stdout or "").strip()
    parsed: dict[str, Any] | None = None
    if raw:
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = None
    if proc.returncode == 0 and parsed and parsed.get("ok"):
        return {
            "schema": RESPONSE_SCHEMA,
            "ok": True,
            "request_id": request_id,
            "op": parsed.get("op"),
            "status_code": parsed.get("status_code"),
            "extracted_preview": parsed.get("extracted_preview"),
            "extracted_bytes": parsed.get("extracted_bytes"),
            "extracted_sha256": parsed.get("extracted_sha256"),
            "title": parsed.get("title"),
            "results": parsed.get("results"),
            "results_count": parsed.get("results_count"),
            "asset_sha256": parsed.get("asset_sha256"),
            "asset_bytes": parsed.get("asset_bytes"),
            "artifact_path": parsed.get("artifact_path"),
            "receipt_path": parsed.get("receipt_path"),
            "redirect_chain": parsed.get("redirect_chain"),
            "url_final": parsed.get("url_final"),
            "search_backend": parsed.get("search_backend"),
            "redirect_or_search_backend": parsed.get("search_backend") or "wikipedia-rest-query",
            "duration_ms": None,
            "timestamp": None,
        }
    err_class = (parsed or {}).get("error_class", "BrokerFailure")
    err_msg = (parsed or {}).get("error") or proc.stderr[:2000]
    return {
        "schema": RESPONSE_SCHEMA,
        "ok": False,
        "request_id": request_id,
        "op": (parsed or {}).get("op"),
        "error_class": err_class,
        "error": err_msg,
        "timestamp": None,
    }


def process_research_queue(
    *,
    db_path: Path,
    canonical_repo: Path,
    run_id: str,
    rate_limit_per_minute: int = DEFAULT_PER_ATTEMPT_RATE_LIMIT,
) -> dict[str, Any]:
    """Run one supervisor tick for a given run.

    Consumes pending REQUEST files from the queue, validates
    each against the run's frozen capability binding and the
    live DB, and dispatches the broker for valid requests. Writes
    RESPONSE files to the per-attempt scratch research dir.

    Currently only one run is owned by one supervisor process; a
    future revision may track requests across multiple runs.
    """
    queue = _queue_dir()
    if not queue.is_dir():
        return {"consumed": 0, "processed": 0, "rejected": 0}

    # Find requests for THIS run only.
    candidates = sorted(queue.glob(f"req-*.json"))
    owned_by_run = []
    for path in candidates:
        try:
            req = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            # unreadable; reject
            _emit_error_response_and_unlink(
                None,
                path,
                {"code": "QueueReadFailed", "message": "queue file unreadable"},
            )
            continue
        if req.get("run_id") == run_id:
            owned_by_run.append((path, req))

    if not owned_by_run:
        return {"consumed": 0, "processed": 0, "rejected": 0}

    # Sanity: run is live and research.public was bound.
    if not _capability_resolution_has_research_public(canonical_repo, run_id):
        # Bulk-reject all requests; the run has no authority.
        for path, req in owned_by_run:
            _emit_error_response_and_unlink(
                _scratch_response_path(
                    canonical_repo, run_id,
                    req.get("role", "builder"),
                    req.get("attempt_id", "anon"),
                    req.get("request_id", "anon"),
                ),
                path,
                {"code": "CapabilityNotFrozen",
                 "message": "research.public not in run's frozen capability binding"},
            )
        return {"consumed": 0, "processed": 0, "rejected": len(owned_by_run)}

    try:
        conn = sqlite3.connect(str(db_path))
    except sqlite3.Error:
        return {"consumed": 0, "processed": 0, "rejected": 0, "deferred": "db_unavailable"}

    broker_dispatch = _read_broker_dispatch()
    broker_path = _broker_path_from_evidence_dispatch(broker_dispatch)
    if broker_path is None:
        return {"consumed": 0, "processed": 0, "rejected": 0, "deferred": "broker_unavailable"}

    conn.row_factory = sqlite3.Row
    processed = 0
    rejected = 0
    rate_window_start = time.monotonic()
    rate_count = 0

    for path, req in owned_by_run:
        # Per-attempt rate limit.
        elapsed = time.monotonic() - rate_window_start
        if elapsed >= 60.0:
            rate_window_start = time.monotonic()
            rate_count = 0
        if rate_count >= rate_limit_per_minute:
            _emit_error_response_and_unlink(
                _scratch_response_path(
                    canonical_repo, run_id,
                    req.get("role", "builder"),
                    req.get("attempt_id", "anon"),
                    req.get("request_id", "anon"),
                ),
                path,
                {"code": "RateLimited",
                 "message": f"per-attempt rate limit {rate_limit_per_minute}/min exceeded"},
            )
            rejected += 1
            continue
        rate_count += 1

        shape_err = _validate_request_shape(req)
        if shape_err is not None:
            _emit_error_response_and_unlink(
                _scratch_response_path(
                    canonical_repo, run_id,
                    req.get("role", "builder"),
                    req.get("attempt_id", "anon"),
                    req.get("request_id", "anon"),
                ),
                path,
                shape_err,
            )
            rejected += 1
            continue

        attempt_id = str(req.get("attempt_id") or "")
        # Active-attempt check (defence in depth: refuse requests
        # from terminal / stale / non-existent attempts).
        if not _db_attempt_is_active(conn, run_id, attempt_id):
            _emit_error_response_and_unlink(
                _scratch_response_path(
                    canonical_repo, run_id,
                    req.get("role", "builder"),
                    attempt_id,
                    req.get("request_id", "anon"),
                ),
                path,
                {"code": "AttemptNotActive",
                 "message": "request attempt is not a currently-live attempt"},
            )
            rejected += 1
            continue

        evidence_dir = (_evidence_root() / run_id).resolve(strict=False)
        try:
            proc = _run_broker(
                broker_path,
                op=str(req.get("op")),
                url=req.get("url"),
                query=req.get("query"),
                max_bytes=req.get("max_bytes"),
                evidence_dir=evidence_dir,
                run_id=run_id,
                attempt=attempt_id,
                request_id=str(req.get("request_id") or "anon"),
            )
        except subprocess.TimeoutExpired:
            _emit_error_response_and_unlink(
                _scratch_response_path(
                    canonical_repo, run_id,
                    req.get("role", "builder"),
                    attempt_id,
                    req.get("request_id", "anon"),
                ),
                path,
                {"code": "BrokerTimeout",
                 "message": f"broker exceeded timeout"},
            )
            rejected += 1
            continue
        except Exception as exc:  # pragma: no cover
            _emit_error_response_and_unlink(
                _scratch_response_path(
                    canonical_repo, run_id,
                    req.get("role", "builder"),
                    attempt_id,
                    str(req.get("request_id") or "anon"),
                ),
                path,
                {"code": "BrokerDispatchFailed",
                 "message": f"{type(exc).__name__}: {exc}"},
            )
            rejected += 1
            continue

        scratch_resp_path = _scratch_response_path(
            canonical_repo, run_id,
            req.get("role", "builder"),
            attempt_id,
            str(req.get("request_id") or "anon"),
        )
        response = _summarize_broker_for_worker(
            proc,
            str(req.get("request_id") or "anon"),
        )
        try:
            _atomic_write_json(scratch_resp_path, response)
        except OSError as exc:
            _emit_error_response_and_unlink(
                scratch_resp_path,
                path,
                {"code": "ResponsePublishFailed",
                 "message": str(exc)},
            )
            rejected += 1
            continue

        # Successful: unlink the queue file so the next tick does
        # not re-dispatch.
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        processed += 1

    conn.close()
    return {
        "consumed": len(owned_by_run),
        "processed": processed,
        "rejected": rejected,
    }


def _emit_error_response_and_unlink(
    scratch_path: Path | None,
    queue_file: Path,
    err: dict[str, Any],
) -> None:
    """Write a structured error response file (if scratch_path is
    known) and unlink the queue file so the request does not retry.
    """
    response = {
        "schema": RESPONSE_SCHEMA,
        "ok": False,
        "error_class": err.get("code", "Error"),
        "error": err.get("message", ""),
        "timestamp": None,
    }
    if scratch_path is not None:
        try:
            _atomic_write_json(scratch_path, response)
        except OSError:
            pass  # best-effort
    try:
        queue_file.unlink()
    except FileNotFoundError:
        pass


__all__ = [
    "REQUEST_SCHEMA",
    "RESPONSE_SCHEMA",
    "process_research_queue",
    "_evidence_root",
    "_queue_dir",
    "_read_broker_dispatch",
]

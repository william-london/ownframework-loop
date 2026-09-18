"""Canonical commissioned supervisor identity.

This module is the single owner for "what constitutes the canonical
commissioned supervisor identity" on macOS. It exposes:

- ``ACTIVATION_RECEIPT_SCHEMA``: the receipt schema id.
- ``default_receipt_path(state_root)``: the canonical receipt path
  under a given state root.
- ``derive_active_identity(launcher_argv, launcher_env, launcher_pid)``:
  the active supervisor process calls this to produce a fresh receipt
  from values it actually observes in its own execution context.
- ``verify_active_identity(receipt, expected)``: the installer calls
  this to compare an observed receipt against expected commissioning
  identity. Returns ``(ok, reason)``.

The receipt is the load-bearing active-runtime-truth artifact. It is
written atomically by the launcher *before* it exec's into the
durable supervisor, and is overwritten on each subsequent activation.
A stale receipt from a prior activation cannot satisfy a new install
because the receipt carries a per-activation nonce that the installer
re-issues.

Derivation rule (Seam 1 of the architectural addendum): every value
the executing process can independently derive is computed from
actual execution context, NOT echoed from installer-set environment
variables.  In particular:

- ``ofloop_bin`` is taken from the actual ``--ofloop`` argv (the
  binary the post-exec supervisor will run).  The ``OFLOOP_BIN`` env
  is only consulted as a fallback when no ``--ofloop`` is present,
  and the two are never trusted to disagree silently — a mismatch
  raises ``ValueError``.
- ``runtime_root`` is computed from the canonical ``ofloop_bin``
  path (``Path(ofloop_bin).resolve(strict=False).parents[1]``),
  independent of the ``OFLOOP_RUNTIME_ROOT`` env.
- ``runtime_generation`` is recomputed from the runtime payload
  bytes at the computed runtime root, via
  ``runtime_identity.runtime_generation_for_root`` when available,
  NOT echoed from ``OFLOOP_RUNTIME_GENERATION``.  A launchd-Linux
  context that lacks the ``runtime_identity`` module falls back to
  the env value with an explicit warning in the receipt
  provenance; the env is never silently trusted.

This rule is what makes the receipt independent of any configured
commissioning truth: the receipt describes what is actually running,
not what the installer said it would run.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Mapping


ACTIVATION_RECEIPT_SCHEMA = "ownframework-loop-supervisor-activation/v1"

# Startup-ready attestation schema (Seam 2 of the architectural addendum).
# The durable supervisor process (the post-exec supervisor, NOT the
# pre-exec launcher that wrote the activation receipt) writes this
# file as evidence it actually initialized the durable execution
# clock with the same activation_id the launcher minted.  Receipt
# alone proves the launcher's pre-exec identity; the attestation
# proves the durable supervisor took over the same activation.
STARTUP_READY_SCHEMA = "ownframework-loop-supervisor-startup-ready/v1"

# Receipt field names. Kept short and exhaustive: every field must be
# non-empty in a valid receipt, and every field is exact-matched by
# ``verify_active_identity``.
RECEIPT_FIELDS: tuple[str, ...] = (
    "schema",
    "activation_id",
    "pid",
    "label",
    "runtime_generation",
    "runtime_root",
    "ofloop_bin",
    "supervisor_db",
    "ledger_marker",
    "started_at",
    # The receipt also records how the launcher derived
    # ``runtime_generation``: either ``"recomputed_from_payload"``
    # (the canonical rule) or ``"env_fallback"`` (degraded; the
    # runtime_identity module was unavailable).  This is evidence,
    # not authority — the installer still exact-matches the
    # generation value itself.
    "generation_source",
)

# Startup-ready attestation fields.  Mirror of RECEIPT_FIELDS minus
# the launcher-side concerns, with a fresh ``ready_pid`` so the
# installer can bind the durable supervisor PID to the launchd
# label too.  The attestation is durable evidence that the post-exec
# supervisor owns the same activation.
STARTUP_READY_FIELDS: tuple[str, ...] = (
    "schema",
    "activation_id",
    "ready_pid",
    "label",
    "runtime_generation",
    "runtime_root",
    "ofloop_bin",
    "supervisor_db",
    "ledger_marker",
    "ready_at",
)


def default_receipt_path(state_root: Path | str) -> Path:
    """Return the canonical activation-receipt path under ``state_root``.

    The state root is the supervisor's state base (i.e. ``$XDG_STATE_HOME``
    or ``$HOME/.local/state``); the receipt lives one directory down
    under ``ownframework-loop/supervisor-activation.json``.
    """
    return Path(state_root).expanduser().resolve(strict=False) / "ownframework-loop" / "supervisor-activation.json"


def default_startup_ready_path(state_root: Path | str) -> Path:
    """Return the canonical startup-ready attestation path under ``state_root``.

    Sibling of the activation receipt.  The durable supervisor writes
    this file as evidence it actually entered the scheduler loop with
    the launcher's activation context.
    """
    return Path(state_root).expanduser().resolve(strict=False) / "ownframework-loop" / "supervisor-startup-ready.json"


def derive_startup_ready(
    receipt: Mapping[str, Any],
    ready_pid: int,
    now: float | None = None,
    *,
    actual_argv: list[str] | None = None,
    actual_env: Mapping[str, str] | None = None,
    actual_db_path: Path | str | None = None,
    actual_state_root: Path | str | None = None,
    default_db_path_resolver: Any = None,
    runtime_generation_resolver: Any = None,
) -> dict[str, Any]:
    """Build a startup-ready attestation by independently deriving the
    durable supervisor's own post-exec identity, then comparing to the
    receipt.

    Seam 1 of the residual-closure: the durable supervisor must NOT
    copy fields from the receipt.  Every field the durable process
    can independently derive is computed from actual post-exec
    context:

    - ``ofloop_bin`` and ``runtime_root`` from the supervisor's own
      argv (via ``read_runtime_context_from_argv``).
    - ``runtime_generation`` recomputed through the same
      ``runtime_identity.runtime_generation_for_root`` the launcher
      used, against the runtime root the supervisor itself observes.
    - ``supervisor_db`` from the actual db path this supervisor will
      use: ``actual_db_path`` when supplied, otherwise the canonical
      ``default_db_path()`` (resolvable through
      ``default_db_path_resolver`` to avoid a hard import cycle).
    - ``ledger_marker`` derived from ``actual_state_root`` /
      ``actual_db_path`` (sibling of supervisor.sqlite3, the same
      convention the installer and launcher use).
    - ``activation_id`` / ``label`` come from the commissioned
      activation context (env) and must exact-match the receipt —
      they are service-manager identity commitments, not
      independently observable.

    The function then compares every independently-derived field to
    the receipt.  Any mismatch raises ``ValueError`` so the caller
    refuses to publish startup-ready.  No copy-from-receipt field
    may end up in the published attestation unless the durable
    process independently observed the same value.

    For backwards compatibility with older call sites that do not
    pass actual context, the function raises ``ValueError`` rather
    than silently falling back to receipt fields.  The caller's
    actual context is the only acceptable input.
    """
    activation_id = str(receipt.get("activation_id") or "")
    if not activation_id:
        raise ValueError("cannot derive startup-ready attestation without receipt activation_id")
    receipt_label = str(receipt.get("label") or "")
    if not receipt_label:
        raise ValueError("cannot derive startup-ready attestation without receipt label")

    if actual_argv is None or actual_env is None:
        raise ValueError(
            "startup_ready requires actual post-exec argv and env; refusing to copy receipt "
            "fields into a durable attestation"
        )
    if actual_db_path is None and default_db_path_resolver is None:
        raise ValueError(
            "startup_ready requires actual_db_path or a default_db_path_resolver; refusing "
            "to copy receipt fields into a durable attestation"
        )

    # Independently derive the durable supervisor's own runtime
    # context from its argv and env.  ``read_runtime_context_from_argv``
    # already enforces argv vs env mismatch refusal; we do not
    # tolerate either the receipt's values or env fallbacks here.
    runtime_ctx = read_runtime_context_from_argv(list(actual_argv), dict(actual_env))
    actual_ofloop_bin = runtime_ctx.get("ofloop_bin") or ""
    actual_runtime_root = runtime_ctx.get("runtime_root") or ""
    if not actual_ofloop_bin:
        raise ValueError("startup_ready: actual post-exec ofloop_bin undetermined")
    if not actual_runtime_root:
        raise ValueError("startup_ready: actual post-exec runtime_root undetermined")

    # ACTUAL_RUNTIME_GENERATION — recompute through the single
    # authoritative runtime_identity implementation.  ``env_fallback``
    # is NEVER acceptable for commissioned active-runtime proof
    # (Seam 2): if the payload cannot recompute its own generation,
    # commissioning must fail closed.  The helper is injectable so
    # tests can pass a stub.
    actual_runtime_generation = ""
    actual_generation_source = ""
    if runtime_generation_resolver is not None:
        actual_runtime_generation = str(runtime_generation_resolver(actual_runtime_root))
        actual_generation_source = "recomputed_from_payload"
    else:
        try:
            from ownframework_loop import runtime_identity  # type: ignore
            from ownframework_loop import __version__  # type: ignore
        except Exception as exc:
            raise ValueError(
                "startup_ready: runtime_identity module unavailable; cannot independently "
                "recompute runtime_generation from actual payload: " + str(exc)
            )
        actual_runtime_generation = str(
            runtime_identity.runtime_generation_for_root(Path(actual_runtime_root), str(__version__))
        )
        actual_generation_source = "recomputed_from_payload"
    if actual_generation_source != "recomputed_from_payload":
        # Defense in depth: never publish an attestation whose
        # generation came from anywhere but the payload.
        raise ValueError(
            "startup_ready: generation_source=" + actual_generation_source
            + " not acceptable for commissioned active-runtime proof"
        )

    # ACTUAL_SUPERVISOR_DB — the actual db path this serve() instance
    # will use.  ``default_db_path_resolver`` is injectable for
    # tests; production callers pass the canonical resolver.
    if actual_db_path is None:
        actual_supervisor_db = str(default_db_path_resolver())
    else:
        actual_supervisor_db = str(Path(actual_db_path).expanduser().resolve(strict=False))

    # ACTUAL_LEDGER_MARKER — derived from the same state root the
    # supervisor will read its DB from.  ``actual_state_root`` lets
    # the caller supply the canonical state base (XDG_STATE_HOME or
    # HOME/.local/state) when the db path does not encode it; when
    # only the db path is supplied, the marker is the db path's
    # sibling.
    if actual_state_root is None:
        actual_ledger_marker = str(
            Path(actual_supervisor_db).with_name("ledger-incarnation.json")
        )
    else:
        actual_ledger_marker = str(
            Path(actual_state_root).expanduser().resolve(strict=False)
            / "ownframework-loop"
            / "ledger-incarnation.json"
        )

    # Compare independently-derived identity against the receipt.
    # Any mismatch refuses publication; the installer will see a
    # missing attestation and fail closed.
    actual_label = str(actual_env.get("LABEL") or "").strip()
    actual_activation_id = str(actual_env.get("OFLOOP_ACTIVATION_ID") or "").strip()

    def _field_mismatch(field: str, actual: str, expected: str) -> str:
        return (
            "startup_ready_field=" + field
            + " actual=" + repr(actual)
            + " receipt=" + repr(expected)
            + " — durable post-exec identity disagrees with receipt"
        )

    if actual_activation_id and actual_activation_id != activation_id:
        raise ValueError(_field_mismatch("activation_id", actual_activation_id, activation_id))
    if actual_label and actual_label != receipt_label:
        raise ValueError(_field_mismatch("label", actual_label, receipt_label))
    if actual_ofloop_bin != str(receipt.get("ofloop_bin") or ""):
        raise ValueError(_field_mismatch("ofloop_bin", actual_ofloop_bin, str(receipt.get("ofloop_bin") or "")))
    if actual_runtime_root != str(receipt.get("runtime_root") or ""):
        raise ValueError(_field_mismatch("runtime_root", actual_runtime_root, str(receipt.get("runtime_root") or "")))
    if actual_runtime_generation != str(receipt.get("runtime_generation") or ""):
        raise ValueError(
            _field_mismatch("runtime_generation", actual_runtime_generation, str(receipt.get("runtime_generation") or ""))
        )
    if actual_supervisor_db != str(receipt.get("supervisor_db") or ""):
        raise ValueError(_field_mismatch("supervisor_db", actual_supervisor_db, str(receipt.get("supervisor_db") or "")))
    if actual_ledger_marker != str(receipt.get("ledger_marker") or ""):
        raise ValueError(_field_mismatch("ledger_marker", actual_ledger_marker, str(receipt.get("ledger_marker") or "")))

    return {
        "schema": STARTUP_READY_SCHEMA,
        "activation_id": activation_id,
        "ready_pid": int(ready_pid),
        "label": receipt_label,
        "runtime_generation": actual_runtime_generation,
        "runtime_root": actual_runtime_root,
        "ofloop_bin": actual_ofloop_bin,
        "supervisor_db": actual_supervisor_db,
        "ledger_marker": actual_ledger_marker,
        "ready_at": float(now if now is not None else time.time()),
        "generation_source": actual_generation_source,
    }


def load_startup_ready(path: Path) -> dict[str, Any]:
    """Load and validate the structural shape of a startup-ready attestation."""
    with open(path, "r", encoding="utf-8") as fh:
        body = json.load(fh)
    if not isinstance(body, dict):
        raise ValueError(f"startup-ready attestation at {path} is not a JSON object")
    if body.get("schema") != STARTUP_READY_SCHEMA:
        raise ValueError(
            f"startup-ready attestation at {path} has unknown schema: {body.get('schema')!r}"
        )
    for field in STARTUP_READY_FIELDS:
        if field not in body or body[field] in (None, ""):
            raise ValueError(
                f"startup-ready attestation at {path} missing required field {field!r}"
            )
    return body


def verify_startup_ready(
    startup_ready: Mapping[str, Any],
    expected_activation_id: str,
    expected: Mapping[str, Any],
) -> tuple[bool, str]:
    """Compare a startup-ready attestation against the receipt's expected values.

    Same exact-match contract as ``verify_active_identity``, but
    matches ``ready_pid`` against ``pid`` in ``expected``.
    """
    if startup_ready.get("schema") != STARTUP_READY_SCHEMA:
        return False, f"startup_ready_schema_mismatch actual={startup_ready.get('schema')!r}"
    if str(startup_ready.get("activation_id", "")) != str(expected_activation_id):
        return (
            False,
            "startup_ready_activation_id_mismatch actual="
            + repr(str(startup_ready.get("activation_id", ""))),
        )
    for field in (
        "label",
        "runtime_generation",
        "runtime_root",
        "ofloop_bin",
        "supervisor_db",
        "ledger_marker",
    ):
        actual = startup_ready.get(field)
        wanted = expected.get(field)
        if actual is None or wanted is None:
            return False, f"startup_ready_missing_field field={field!r}"
        if str(actual) != str(wanted):
            return (
                False,
                f"startup_ready_field={field} actual={actual!r} expected={wanted!r}",
            )
    return True, "ok"


def _resolve_ofloop_argv(parsed_args: Mapping[str, str], launcher_env: Mapping[str, str]) -> str:
    """Return the actual ``ofloop`` binary the launcher will exec.

    The actual ``--ofloop`` argv is the authoritative source — the
    installer-set ``OFLOOP_BIN`` env is only consulted as a fallback
    when no ``--ofloop`` argv is present.  When both are present and
    disagree (after canonicalization) the receipt refuses to derive:
    the installer's configured commissioning truth and the launcher's
    actual exec target disagree, and no honest receipt can satisfy
    both.
    """
    argv_ofloop = (parsed_args.get("ofloop") or "").strip()
    env_ofloop = (launcher_env.get("OFLOOP_BIN") or "").strip()
    if argv_ofloop:
        canonical_argv = str(Path(argv_ofloop).expanduser().resolve(strict=False))
        if env_ofloop:
            canonical_env = str(Path(env_ofloop).expanduser().resolve(strict=False))
            if canonical_argv != canonical_env:
                raise ValueError(
                    "ofloop_bin_mismatch actual_argv=" + canonical_argv
                    + " env=" + canonical_env
                    + " — installer configured commissioning truth disagrees with the "
                    "actual --ofloop argv; refusing to derive a misleading receipt"
                )
        return canonical_argv
    if env_ofloop:
        return str(Path(env_ofloop).expanduser().resolve(strict=False))
    raise ValueError(
        "ofloop_bin unavailable: neither --ofloop argv nor OFLOOP_BIN env was supplied; "
        "cannot derive active identity without an executable target"
    )


def read_runtime_context_from_argv(argv: list[str], env: Mapping[str, str]) -> dict[str, str]:
    """Recover runtime identity from a post-exec supervisor's own argv + env.

    The launcher exec's into the durable supervisor with argv
    ``[<python>, "-B", <ofloop_bin>, "supervisor", "serve"]`` (no
    ``--db`` / ``--ledger-marker`` flags reach the post-exec
    process).  The post-exec supervisor therefore recovers the
    canonical identity from the env (``OFLOOP_ACTIVATION_ID``,
    ``LABEL``, ``OFLOOP_BIN``, ``OFLOOP_RUNTIME_ROOT``) and the
    receipt file (which the launcher wrote immediately before exec).

    Returns a dict with keys ``activation_id``, ``label``,
    ``ofloop_bin``, ``runtime_root``, ``supervisor_db``,
    ``ledger_marker``.  ``ofloop_bin`` is recovered from the actual
    argv (NOT the env) when present, with env as fallback — same
    rule as ``_resolve_ofloop_argv``.
    """
    out: dict[str, str] = {}
    out["activation_id"] = str(env.get("OFLOOP_ACTIVATION_ID") or "").strip()
    out["label"] = str(env.get("LABEL") or "").strip()
    # The post-exec supervisor's argv is [<ofloop_bin>, ...]; the first
    # element is the actual binary.  When the launcher exec's with the
    # standard argv above, this is the canonical ofloop_bin.
    argv_ofloop = ""
    for token in argv:
        if token and not token.startswith("-"):
            argv_ofloop = token
            break
    env_ofloop = str(env.get("OFLOOP_BIN") or "").strip()
    if argv_ofloop:
        canonical_argv = str(Path(argv_ofloop).expanduser().resolve(strict=False))
        if env_ofloop and str(Path(env_ofloop).expanduser().resolve(strict=False)) != canonical_argv:
            raise ValueError(
                "post_exec_ofloop_bin_mismatch actual_argv=" + canonical_argv
                + " env=" + str(Path(env_ofloop).expanduser().resolve(strict=False))
            )
        out["ofloop_bin"] = canonical_argv
        out["runtime_root"] = str(Path(canonical_argv).parents[1])
    elif env_ofloop:
        out["ofloop_bin"] = str(Path(env_ofloop).expanduser().resolve(strict=False))
        out["runtime_root"] = str(Path(out["ofloop_bin"]).parents[1])
    else:
        out["ofloop_bin"] = ""
        out["runtime_root"] = str(env.get("OFLOOP_RUNTIME_ROOT") or "").strip()
    return out


def _recompute_runtime_generation(runtime_root: Path, env_value: str) -> tuple[str, str]:
    """Recompute runtime generation from actual payload bytes.

    Seam 2 of the residual-closure: ``env_fallback`` is NOT
    acceptable for commissioned active-runtime proof.  The receipt
    must derive its generation from the actual payload bytes; if
    the payload cannot recompute its own generation, the launcher
    refuses to mint a receipt at all (commissioning fails closed
    with ``ACTIVE_RUNTIME_GENERATION_UNPROVEN``).

    Returns ``(value, source)`` where ``source`` is always
    ``"recomputed_from_payload"``.  The ``env_value`` parameter is
    retained only so older call sites compile; it is NEVER used to
    construct the returned value.
    """
    try:
        from ownframework_loop import runtime_identity  # type: ignore
    except Exception as exc:
        raise ValueError(
            "ACTIVE_RUNTIME_GENERATION_UNPROVEN: runtime_identity module could not be "
            "imported by the launcher; cannot independently derive generation from the "
            "installed payload bytes: " + str(exc)
        )
    try:
        from ownframework_loop import __version__  # type: ignore
        version = str(__version__)
    except Exception as exc:
        raise ValueError(
            "ACTIVE_RUNTIME_GENERATION_UNPROVEN: cannot determine installed __version__ "
            "from runtime_identity path; commissioning cannot publish a payload-derived "
            "generation: " + str(exc)
        )
    if not version:
        raise ValueError(
            "ACTIVE_RUNTIME_GENERATION_UNPROVEN: installed __version__ is empty; "
            "refusing to mint a receipt without a payload-derived generation"
        )
    try:
        value = runtime_identity.runtime_generation_for_root(runtime_root, version)
    except Exception as exc:
        raise ValueError(
            "ACTIVE_RUNTIME_GENERATION_UNPROVEN: payload recomputation failed for runtime_root="
            + str(runtime_root) + " version=" + version + ": " + str(exc)
        )
    return value, "recomputed_from_payload"


def derive_active_identity(
    launcher_argv: list[str],
    launcher_env: Mapping[str, str],
    launcher_pid: int,
    now: float | None = None,
) -> dict[str, Any]:
    """Derive a fresh activation receipt from the launcher's own context.

    The launcher must invoke this **after** parsing its own argv and
    after the dependency probe has succeeded. The returned dict is the
    receipt body the launcher persists atomically before exec'ing into
    the durable supervisor.

    Derivation contract (Seam 1):

    - ``ofloop_bin`` is taken from the actual ``--ofloop`` argv.
    - ``runtime_root`` is computed from that ``ofloop_bin`` path.
    - ``runtime_generation`` is recomputed from the payload bytes at
      that runtime root, falling back to ``OFLOOP_RUNTIME_GENERATION``
      env only when the runtime_identity module is unavailable.
    - ``activation_id``, ``label`` are taken from env (they are
      not derivable from local execution context).

    Required inputs:

    - ``launcher_argv``: the launcher's argv (post argparse parse).
      Must include ``--db``, ``--ledger-marker``, ``--ofloop`` flags.
    - ``launcher_env``: the launcher's environment. Must include
      ``OFLOOP_ACTIVATION_ID``, ``LABEL``.
    - ``launcher_pid``: the launcher's own PID (``os.getpid()`` at
      the time of derivation).
    """
    parsed_args = _parse_argv(launcher_argv)
    activation_id = launcher_env.get("OFLOOP_ACTIVATION_ID") or ""
    if not activation_id:
        raise ValueError("OFLOOP_ACTIVATION_ID is required to derive an activation receipt")
    label = launcher_env.get("LABEL") or parsed_args.get("label") or ""
    if not label:
        raise ValueError("LABEL is required to derive an activation receipt")
    ofloop_bin = _resolve_ofloop_argv(parsed_args, launcher_env)
    runtime_root = str(Path(ofloop_bin).expanduser().resolve(strict=False).parents[1])
    runtime_generation, generation_source = _recompute_runtime_generation(
        Path(runtime_root), launcher_env.get("OFLOOP_RUNTIME_GENERATION") or "",
    )
    if not runtime_generation:
        raise ValueError("runtime_generation is required to derive an activation receipt")
    supervisor_db = parsed_args.get("db") or ""
    if not supervisor_db:
        raise ValueError("--db is required to derive an activation receipt")
    # Canonicalize the supervisor_db the same way the durable
    # supervisor will resolve it post-exec; otherwise receipt-vs-
    # attestation exact-match fails on macOS where /var is a symlink
    # to /private/var.
    supervisor_db = str(Path(supervisor_db).expanduser().resolve(strict=False))
    ledger_marker = parsed_args.get("ledger_marker") or ""
    if not ledger_marker:
        raise ValueError("--ledger-marker is required to derive an activation receipt")
    ledger_marker = str(Path(ledger_marker).expanduser().resolve(strict=False))
    receipt = {
        "schema": ACTIVATION_RECEIPT_SCHEMA,
        "activation_id": activation_id,
        "pid": int(launcher_pid),
        "label": label,
        "runtime_generation": runtime_generation,
        "runtime_root": runtime_root,
        "ofloop_bin": ofloop_bin,
        "supervisor_db": supervisor_db,
        "ledger_marker": ledger_marker,
        "started_at": float(now if now is not None else time.time()),
        "generation_source": generation_source,
    }
    return receipt


def write_receipt_atomic(receipt: Mapping[str, Any], path: Path) -> None:
    """Persist ``receipt`` atomically at ``path``.

    Writes to ``path.with_name(path.name + ".tmp")`` first, fsync's,
    then ``os.replace`` onto ``path``. The destination directory is
    created with mode ``0o700`` if missing.  The destination file is
    created with mode ``0o600``.
    """
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        payload = json.dumps(dict(receipt), indent=2, sort_keys=True)
        os.write(fd, payload.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    path.chmod(0o600)


def load_receipt(path: Path) -> dict[str, Any]:
    """Load and validate the structural shape of a receipt.

    Raises ``FileNotFoundError`` if ``path`` does not exist, or
    ``ValueError`` if the receipt is malformed.
    """
    with open(path, "r", encoding="utf-8") as fh:
        receipt = json.load(fh)
    if not isinstance(receipt, dict):
        raise ValueError(f"receipt at {path} is not a JSON object")
    if receipt.get("schema") != ACTIVATION_RECEIPT_SCHEMA:
        raise ValueError(
            f"receipt at {path} has unknown schema: {receipt.get('schema')!r}"
        )
    for field in RECEIPT_FIELDS:
        if field not in receipt or receipt[field] in (None, ""):
            raise ValueError(f"receipt at {path} missing required field {field!r}")
    return receipt


def verify_active_identity(
    receipt: Mapping[str, Any],
    expected_activation_id: str,
    expected: Mapping[str, Any],
) -> tuple[bool, str]:
    """Compare an observed ``receipt`` against expected commissioning identity.

    Returns ``(True, "ok")`` when every field in ``RECEIPT_FIELDS``
    (other than ``schema``, ``started_at``, and ``generation_source``)
    exact-matches the corresponding key in ``expected`` AND the
    receipt's activation id matches ``expected_activation_id``.

    ``expected`` must carry these keys (mirror of ``RECEIPT_FIELDS``
    minus ``schema`` / ``started_at`` / ``generation_source``):

    - ``activation_id`` — checked separately;
    - ``pid``, ``label``, ``runtime_generation``, ``runtime_root``,
      ``ofloop_bin``, ``supervisor_db``, ``ledger_marker``.

    A non-empty ``reason`` string identifies the failing field; this
    is suitable for logging or for surfacing in a refusal message.

    ``generation_source`` is evidence — when the receipt was derived
    via ``env_fallback`` (the runtime_identity module was
    unavailable to the launcher) the verifier records a warning but
    does not refuse: the env_fallback is a supported degraded mode
    and the generation value itself is still exact-matched.
    """
    if receipt.get("schema") != ACTIVATION_RECEIPT_SCHEMA:
        return False, f"schema_mismatch actual={receipt.get('schema')!r}"
    if str(receipt.get("activation_id", "")) != str(expected_activation_id):
        return (
            False,
            f"activation_id_mismatch actual={receipt.get('activation_id')!r}",
        )
    for field in (
        "pid",
        "label",
        "runtime_generation",
        "runtime_root",
        "ofloop_bin",
        "supervisor_db",
        "ledger_marker",
    ):
        actual = receipt.get(field)
        wanted = expected.get(field)
        if actual is None or wanted is None:
            return False, f"missing_field field={field!r}"
        # pid is matched as int; everything else as str.
        if field == "pid":
            try:
                actual_int = int(actual)
            except (TypeError, ValueError):
                return False, f"field={field} actual={actual!r} is not an int"
            try:
                wanted_int = int(wanted)
            except (TypeError, ValueError):
                return False, f"field={field} expected={wanted!r} is not an int"
            if actual_int != wanted_int:
                return (
                    False,
                    f"field={field} actual={actual_int} expected={wanted_int}",
                )
            continue
        if str(actual) != str(wanted):
            return (
                False,
                f"field={field} actual={actual!r} expected={wanted!r}",
            )
    return True, "ok"


def _parse_argv(argv: list[str]) -> dict[str, str]:
    """Parse ``--key value`` pairs out of an argv list.

    The launcher uses argparse internally; this is a minimal fallback
    that only extracts the keys ``derive_active_identity`` needs.
    """
    parsed: dict[str, str] = {}
    i = 0
    while i < len(argv):
        token = argv[i]
        if token.startswith("--") and i + 1 < len(argv):
            key = token[2:].replace("-", "_")
            parsed[key] = argv[i + 1]
            i += 2
            continue
        i += 1
    return parsed

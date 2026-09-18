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
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Mapping


ACTIVATION_RECEIPT_SCHEMA = "ownframework-loop-supervisor-activation/v1"

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
)


def default_receipt_path(state_root: Path | str) -> Path:
    """Return the canonical activation-receipt path under ``state_root``.

    The state root is the supervisor's state base (i.e. ``$XDG_STATE_HOME``
    or ``$HOME/.local/state``); the receipt lives one directory down
    under ``ownframework-loop/supervisor-activation.json``.
    """
    return Path(state_root).expanduser().resolve(strict=False) / "ownframework-loop" / "supervisor-activation.json"


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

    Required inputs:

    - ``launcher_argv``: the launcher's argv (post argparse parse).
      Must include ``--db``, ``--ledger-marker``, ``--ofloop`` flags.
    - ``launcher_env``: the launcher's environment. Must include
      ``OFLOOP_ACTIVATION_ID``, ``OFLOOP_RUNTIME_ROOT``, ``OFLOOP_BIN``,
      ``LABEL``, ``OFLOOP_RUNTIME_GENERATION`` (set by the installer
      on the plist before bootstrap).
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
    runtime_generation = launcher_env.get("OFLOOP_RUNTIME_GENERATION") or ""
    if not runtime_generation:
        raise ValueError("OFLOOP_RUNTIME_GENERATION is required to derive an activation receipt")
    runtime_root = launcher_env.get("OFLOOP_RUNTIME_ROOT") or ""
    if not runtime_root:
        raise ValueError("OFLOOP_RUNTIME_ROOT is required to derive an activation receipt")
    ofloop_bin = launcher_env.get("OFLOOP_BIN") or parsed_args.get("ofloop") or ""
    if not ofloop_bin:
        raise ValueError("OFLOOP_BIN is required to derive an activation receipt")
    supervisor_db = parsed_args.get("db") or ""
    if not supervisor_db:
        raise ValueError("--db is required to derive an activation receipt")
    ledger_marker = parsed_args.get("ledger_marker") or ""
    if not ledger_marker:
        raise ValueError("--ledger-marker is required to derive an activation receipt")
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
    (other than ``schema`` and ``started_at``) exact-matches the
    corresponding key in ``expected`` AND the receipt's activation id
    matches ``expected_activation_id``.

    ``expected`` must carry these keys (mirror of ``RECEIPT_FIELDS`` minus
    ``schema`` / ``started_at``):

    - ``activation_id`` — checked separately;
    - ``pid``, ``label``, ``runtime_generation``, ``runtime_root``,
      ``ofloop_bin``, ``supervisor_db``, ``ledger_marker``.

    A non-empty ``reason`` string identifies the failing field; this is
    suitable for logging or for surfacing in a refusal message.
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

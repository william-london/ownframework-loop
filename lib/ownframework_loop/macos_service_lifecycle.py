"""Canonical macOS launchd service-lifecycle primitive.

Seam 4 + Seam 6 of the residual-closure: every macOS lifecycle owner
(normal replacement, pending-transaction recovery, activation-failure
cleanup, uninstall) shares ONE small primitive for canonical-label
authority.

The primitive exposes three operations:

- ``probe_canonical_label(label, domain)``: returns ``True`` when
  ``launchctl print "$domain/$label"`` exits 0 (the label is loaded).

- ``remove_canonical_label(label, domain, plist)``: tries the
  appropriate launchctl removal forms (``bootout "$domain" "$plist"``
  and ``bootout "$domain/$label"``) and returns.  It does NOT prove
  absence — ``prove_canonical_label_absent`` is the load-bearing
  authority.

- ``prove_canonical_label_absent(label, domain)``: returns ``True``
  when ``launchctl print "$domain/$label"`` exits nonzero (the
  canonical label is genuinely unloaded under the canonical domain).
  A successful bootout return code is necessary but not sufficient —
  this is the postcondition every lifecycle owner must verify.

The primitive does NOT depend on the loaded service's plist origin: a
stale fixture from a different plist path is still under the canonical
label and is removed the same way.  This closes the historical
plist-origin assumption that allowed stale same-label registrations
to persist across installs.

This module is macOS-scoped.  Linux systemd code paths are not
touched.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from typing import Sequence


def _launchctl() -> str:
    """Return the path to launchctl, preferring the real binary on PATH.

    Tests that want to exercise this primitive without touching the
    real launchd domain prepend a shim directory to PATH; this
    function resolves ``launchctl`` at call time so the shim wins.
    """
    found = shutil.which("launchctl")
    if found:
        return found
    raise FileNotFoundError("launchctl binary not found on PATH")


def _run(args: Sequence[str]) -> tuple[int, str, str]:
    """Run a launchctl invocation, capturing stdout/stderr and exit code.

    Returns ``(returncode, stdout, stderr)``.  Uses
    ``subprocess.run`` with ``check=False`` so callers decide what
    the postcondition means.  The caller never interprets
    ``returncode != 0`` as a hard failure — the load-bearing
    authority is the canonical ``probe_canonical_label`` exit code,
    not the bootout return code.
    """
    proc = subprocess.run(
        list(args),
        check=False,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def probe_canonical_label(label: str, domain: str) -> bool:
    """Return ``True`` when the canonical label is loaded under ``domain``.

    Implementation: ``launchctl print "$domain/$label"`` exits 0 when
    the label is loaded and nonzero when it is not (real launchd
    returns "Could not find service" on stderr when the label is
    absent).  The print body's textual content is irrelevant to the
    authority surface; only the exit code matters.
    """
    rc, _out, _err = _run([_launchctl(), "print", f"{domain}/{label}"])
    return rc == 0


def remove_canonical_label(label: str, domain: str, plist: str | None = None) -> None:
    """Try to unload the canonical label.  Does NOT prove absence.

    Tries ``bootout "$domain" "$plist"`` first when ``plist`` is
    provided (a plist-target bootout is well-defined when the loaded
    service originated from that plist).  Then tries
    ``bootout "$domain/$label"`` (label-target bootout).  Either
    failure is non-fatal at this level: the load-bearing authority
    is the canonical re-probe in ``prove_canonical_label_absent``,
    which is what guarantees the label is genuinely gone before any
    subsequent bootstrap.

    The launchd manager may return rc=0 from a bootout that found no
    job to unload (an already-absent label).  That is the reason the
    postcondition lives in a separate function.
    """
    if plist:
        _run([_launchctl(), "bootout", domain, plist])
    _run([_launchctl(), "bootout", f"{domain}/{label}"])


def prove_canonical_label_absent(label: str, domain: str) -> bool:
    """Return ``True`` only when ``launchctl print "$domain/$label"`` exits nonzero.

    This is the load-bearing postcondition for every macOS lifecycle
    owner: a successful bootout return code is necessary but never
    sufficient.  Real launchd may return rc=0 from a bootout that
    found no job to unload, and a residual-loaded label under a
    different plist origin is the documented stale-fixture condition
    this primitive exists to detect.
    """
    rc, _out, _err = _run([_launchctl(), "print", f"{domain}/{label}"])
    return rc != 0


def remove_and_prove_absent(label: str, domain: str, plist: str | None = None) -> bool:
    """Convenience: remove the canonical label and prove absence.

    Returns ``True`` only when the canonical label is genuinely
    unloaded after the removal attempt.  Lifecycle owners that want
    fail-closed behaviour should treat a ``False`` return as
    REFUSED.

    This is the single primitive that closes the historical
    plist-origin assumption: regardless of which plist the stale
    service came from, the canonical-label authority surface is
    the same ``gui/$UID/com.ownframework.loop-supervisor`` label,
    and the postcondition is the same proof of absence.
    """
    remove_canonical_label(label, domain, plist)
    return prove_canonical_label_absent(label, domain)

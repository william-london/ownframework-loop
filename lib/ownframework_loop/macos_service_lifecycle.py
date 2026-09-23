"""Canonical macOS launchd service-lifecycle primitive.

Every macOS lifecycle owner (normal replacement, pending-transaction recovery,
activation-failure cleanup, uninstall) shares this primitive for canonical-label
authority. Absence is proven only from launchd's explicit missing-service
response; arbitrary command failure is never collapsed to "service absent".
"""
from __future__ import annotations

import shutil
import subprocess
from typing import Sequence


_LAUNCHCTL_TIMEOUT_SECONDS = 10.0
_MISSING_SERVICE_MARKERS = (
    "could not find service",
    "service not found",
)


class LaunchctlProbeError(RuntimeError):
    """launchctl could not prove loaded-or-absent state."""


def _launchctl() -> str:
    """Return the path to launchctl, preferring the real binary on PATH.

    Tests that want to exercise this primitive without touching the real
    launchd domain prepend a shim directory to PATH; resolution happens at
    call time so the shim wins.
    """
    found = shutil.which("launchctl")
    if found:
        return found
    raise FileNotFoundError("launchctl binary not found on PATH")


def _run(args: Sequence[str]) -> tuple[int, str, str]:
    """Run launchctl with a bounded foreground lifetime.

    Timeout/launch failure propagates. Callers must never manufacture an
    absence proof from a transport failure.
    """
    proc = subprocess.run(
        list(args),
        check=False,
        capture_output=True,
        text=True,
        timeout=_LAUNCHCTL_TIMEOUT_SECONDS,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _explicitly_absent(returncode: int, stdout: str, stderr: str) -> bool:
    if returncode == 0:
        return False
    text = f"{stdout}\n{stderr}".lower()
    return any(marker in text for marker in _MISSING_SERVICE_MARKERS)


def _probe(label: str, domain: str) -> tuple[bool, bool]:
    """Return ``(loaded, absent)`` or raise when launchd state is ambiguous."""
    rc, out, err = _run([_launchctl(), "print", f"{domain}/{label}"])
    if rc == 0:
        return True, False
    if _explicitly_absent(rc, out, err):
        return False, True
    detail = (err or out or "no diagnostic output").strip()[-1000:]
    raise LaunchctlProbeError(
        f"launchctl print could not prove state for {domain}/{label}: "
        f"rc={rc}; {detail}"
    )


def probe_canonical_label(label: str, domain: str) -> bool:
    """Return True when loaded, False only on explicit launchd absence.

    Permission errors, malformed domains, timeouts and manager failures raise
    rather than masquerading as an unloaded service.
    """
    loaded, _absent = _probe(label, domain)
    return loaded


def remove_canonical_label(label: str, domain: str, plist: str | None = None) -> None:
    """Try to unload the canonical label. Does not itself prove absence."""
    if plist:
        _run([_launchctl(), "bootout", domain, plist])
    _run([_launchctl(), "bootout", f"{domain}/{label}"])


def prove_canonical_label_absent(label: str, domain: str) -> bool:
    """Return True only from launchd's explicit missing-service response.

    A generic non-zero return code is ambiguous and therefore raises
    ``LaunchctlProbeError`` instead of becoming authority for absence.
    """
    loaded, absent = _probe(label, domain)
    if loaded:
        return False
    return absent


def remove_and_prove_absent(label: str, domain: str, plist: str | None = None) -> bool:
    """Remove the canonical label and prove its absence fail-closed."""
    remove_canonical_label(label, domain, plist)
    return prove_canonical_label_absent(label, domain)


__all__ = [
    "LaunchctlProbeError",
    "probe_canonical_label",
    "remove_canonical_label",
    "prove_canonical_label_absent",
    "remove_and_prove_absent",
]

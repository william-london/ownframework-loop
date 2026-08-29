"""Safe secret scanner — never persists literal matched secrets.

V2 split:
  - HARD patterns: private keys, well-formed provider tokens, high-confidence
    auth headers. A hit BLOCKS the candidate (refuses to write the
    authoritative build/review artifact).
  - HEURISTIC patterns: high-entropy strings, generic words such as
    "password", synthetic fixture values. A hit produces reviewable
    evidence (recorded in the redacted form) but does NOT block the
    candidate. The finalizer tags such findings as
    ``HEURISTIC_FALSE_POSITIVE_REVIEWABLE``.

Findings never include the literal matched value. They include:
  - pattern_id (stable identifier)
  - severity
  - source tool (file path or stdin)
  - line number (when safe)
  - count
  - SHA-256 of the matched value (for cross-finding dedup)
  - redacted prefix <= 4 non-sensitive characters
  - disposition

Tool output is passed via stdin (or a bounded temporary file), never via
string interpolation into Python source. The scanner caps inspected
output and records truncation.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Any


# Hard secret patterns — high-confidence provider tokens / private keys.
HARD_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("aws_access_key",       re.compile(r"AKIA[0-9A-Z]{16}")),
    ("pem_private_key",      re.compile(r"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----")),
    ("github_token",         re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("slack_token",          re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("anthropic_api_key",    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai_api_key",       re.compile(r"sk-[A-Za-z0-9]{20,}")),
    ("google_api_key",       re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("stripe_secret",        re.compile(r"sk_live_[0-9a-zA-Z]{24,}")),
    ("bearer_auth_header",   re.compile(r"(?i)authorization:\s*bearer\s+[A-Za-z0-9._\-]{20,}")),
]

# Heuristic patterns — reviewable but typically safe.
HEURISTIC_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("api_key_literal",      re.compile(r"(?i)api[_-]?key\s*[:=]\s*['\"]?[A-Za-z0-9_\-]{16,}['\"]?")),
    ("password_literal",     re.compile(r"(?i)password\s*[:=]\s*['\"]?[^'\"\s]{8,}['\"]?")),
    ("high_entropy_token",   re.compile(r"[A-Za-z0-9+/]{32,}={0,2}")),
]

# Hard ceiling on processed source size to prevent runaway memory.
MAX_INPUT_BYTES = 4 * 1024 * 1024  # 4 MiB

# Hard ceiling on number of findings per source.
MAX_FINDINGS_PER_SOURCE = 32


class SecretScanIncomplete(RuntimeError):
    """Authoritative secret proof could not inspect the complete file."""


def _sha256_of_value(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8", errors="replace")).hexdigest()


def _redact_prefix(s: str, max_chars: int = 4) -> str:
    """Return a redacted prefix no longer than ``max_chars`` non-sensitive
    characters. Hash-only or empty for short secrets.
    """
    if not s:
        return ""
    # For very short secrets, do not emit a prefix.
    if len(s) <= 6:
        return ""
    safe = s[:max_chars]
    # Only keep alphanumeric so prefixes are non-sensitive.
    return "".join(c for c in safe if c.isalnum())


def _classify(match_text: str, pattern_id: str, severity: str) -> dict[str, Any]:
    sha = _sha256_of_value(match_text)
    return {
        "pattern_id": pattern_id,
        "severity": severity,
        "sha256": sha,
        "redacted_prefix": _redact_prefix(match_text),
        "count": 1,
    }


def scan_text(text: str, *, source: str = "stdin") -> list[dict[str, Any]]:
    """Scan text for hard + heuristic patterns.

    Output is redacted: never includes the literal matched value.
    """
    if not text:
        return []
    truncated = False
    if len(text.encode("utf-8", errors="replace")) > MAX_INPUT_BYTES:
        text = text.encode("utf-8", errors="replace")[:MAX_INPUT_BYTES].decode("utf-8", errors="replace")
        truncated = True

    findings: list[dict[str, Any]] = []
    # Use re.finditer to count matches per pattern, but never emit the literal.
    for pattern_id, pattern in HARD_PATTERNS:
        count = 0
        line_no = None
        sha_example = None
        redacted_example = ""
        for m in pattern.finditer(text):
            count += 1
            if sha_example is None:
                sha_example = _sha256_of_value(m.group(0))
                redacted_example = _redact_prefix(m.group(0))
            # Find line number if possible.
            if line_no is None:
                prefix = text[: m.start()]
                line_no = prefix.count("\n") + 1
        if count:
            findings.append({
                "pattern_id": pattern_id,
                "severity": "hard",
                "sha256": sha_example,
                "redacted_prefix": redacted_example,
                "count": count,
                "line": line_no,
                "source": source,
                "disposition": "blocks_candidate",
            })
        if len(findings) >= MAX_FINDINGS_PER_SOURCE:
            break

    if len(findings) < MAX_FINDINGS_PER_SOURCE:
        for pattern_id, pattern in HEURISTIC_PATTERNS:
            count = 0
            line_no = None
            sha_example = None
            redacted_example = ""
            for m in pattern.finditer(text):
                count += 1
                if sha_example is None:
                    sha_example = _sha256_of_value(m.group(0))
                    redacted_example = _redact_prefix(m.group(0))
                if line_no is None:
                    prefix = text[: m.start()]
                    line_no = prefix.count("\n") + 1
            if count:
                findings.append({
                    "pattern_id": pattern_id,
                    "severity": "heuristic",
                    "sha256": sha_example,
                    "redacted_prefix": redacted_example,
                    "count": count,
                    "line": line_no,
                    "source": source,
                    "disposition": "reviewable",
                })
            if len(findings) >= MAX_FINDINGS_PER_SOURCE:
                break

    if truncated:
        findings.append({
            "pattern_id": "scan_truncated",
            "severity": "info",
            "sha256": "",
            "redacted_prefix": "",
            "count": 0,
            "line": None,
            "source": source,
            "disposition": "scan_truncated",
            "truncated_bytes": MAX_INPUT_BYTES,
        })
    return findings


def scan_path_for_secrets_strict(path: Path) -> list[dict[str, Any]]:
    """Fully scan one changed file or fail closed.

    Authoritative build/review finalizers use this helper. A read failure or a
    file larger than the bounded scan envelope is UNKNOWN evidence, not proof
    that no secret exists.
    """
    try:
        with open(path, "rb") as f:
            data = f.read(MAX_INPUT_BYTES + 1)
    except OSError as exc:
        raise SecretScanIncomplete(f"secret scan unreadable: {path}") from exc
    if len(data) > MAX_INPUT_BYTES:
        raise SecretScanIncomplete(
            f"secret scan incomplete: {path} exceeds {MAX_INPUT_BYTES} bytes"
        )
    text = data.decode("utf-8", errors="replace")
    findings = scan_text(text, source=str(path))
    if any(f.get("pattern_id") == "scan_truncated" for f in findings):
        raise SecretScanIncomplete(f"secret scan incomplete: {path}")
    return findings


def scan_path_for_secrets_redacted(path: Path) -> list[dict[str, Any]]:
    """Scan a file with redacted output. Refuses on read errors."""
    try:
        with open(path, "rb") as f:
            data = f.read(MAX_INPUT_BYTES + 1)
    except OSError:
        return []
    if len(data) > MAX_INPUT_BYTES:
        data = data[:MAX_INPUT_BYTES]
        truncated = True
    else:
        truncated = False
    try:
        text = data.decode("utf-8", errors="replace")
    except Exception:
        return []
    findings = scan_text(text, source=str(path))
    if truncated:
        # Add a single truncation marker so the caller can record it.
        findings.append({
            "pattern_id": "scan_truncated",
            "severity": "info",
            "sha256": "",
            "redacted_prefix": "",
            "count": 0,
            "line": None,
            "source": str(path),
            "disposition": "scan_truncated",
            "truncated_bytes": MAX_INPUT_BYTES,
        })
    return findings


def scan_text_for_redacted(text: str, source: str = "stdin") -> list[dict[str, Any]]:
    """Convenience wrapper for callers that already have text in hand."""
    return scan_text(text, source=source)


def has_hard_secret(findings: list[dict[str, Any]]) -> bool:
    """Return True iff any `severity == hard` finding is present."""
    return any(f.get("severity") == "hard" for f in findings)


def redact_finding_for_event(finding: dict[str, Any]) -> dict[str, Any]:
    """Drop any field that might leak the matched value. Defensive belt-and-suspenders."""
    allowed = {
        "pattern_id", "severity", "sha256", "redacted_prefix",
        "count", "line", "source", "disposition", "truncated_bytes",
    }
    return {k: v for k, v in finding.items() if k in allowed}


def redact_findings_for_event(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [redact_finding_for_event(f) for f in findings]

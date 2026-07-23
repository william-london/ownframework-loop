"""Deterministic guardrails — bash command classification, path checks, secret scan.

Design contract (V1, post-audit):
- The textual classifier is one layer of defense; the post-pass review pass is
  the ultimate authority. The classifier is *not* a complete shell parser.
- Hermes is recognized only as an executable identity (path component) when
  invoked as the `hermes` CLI itself. The bare word "hermes" in argv,
  filesystem paths under `~/.hermes/`, `grep hermes ...`, etc., are allowed.
- See `docs/SECURITY_MODEL.md` for the full layered model.
"""

from __future__ import annotations

import re
import shlex
from pathlib import Path
from typing import Any


# Bash command tokens that must NEVER be issued by an OwnFramework Loop pass.
# Each entry: (compiled regex, human description). Match anywhere in the argv
# of any segment of the command chain.
#
# Note on intent: every regex here targets an executable identity or a specific
# subcommand form. Do NOT add bare-keyword blocks (e.g. `\bhermes\b` was a
# prompt-injection/UX hazard; paths under `~/.hermes/`, grep searches, and
# docs that mention Hermes are legitimate).
FORBIDDEN_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # git push (any variant)
    (re.compile(r"\bgit\s+push\b"), "git push is prohibited"),
    (re.compile(r"\bgit\s+push\s+--force\b"), "force push is prohibited"),
    (re.compile(r"\bgit\s+push\s+-f\b"), "force push is prohibited"),
    (re.compile(r"\bgit\s+push\s+--force-with-lease\b"), "force push is prohibited"),
    (re.compile(r"\bgit\s+push\s+--no-verify\b"), "git push --no-verify is prohibited"),
    # git merge (any form)
    (re.compile(r"\bgit\s+merge\b"), "git merge is prohibited"),
    (re.compile(r"\bgit\s+merge\s+--no-ff\b"), "merge commit is prohibited"),
    # git reset / clean / branch destructive
    (re.compile(r"\bgit\s+reset\s+--hard\b"), "git reset --hard is prohibited"),
    (re.compile(r"\bgit\s+clean\s+-?fdx?\b"), "git clean with force/clean-untracked is prohibited"),
    (re.compile(r"\bgit\s+branch\s+-D\b"), "git branch -D is prohibited"),
    (re.compile(r"\bgit\s+branch\s+-d\b"), "git branch -d is prohibited"),
    (re.compile(r"\bgit\s+worktree\s+prune\b"), "broad git worktree prune is prohibited"),
    # git remote mutations
    (re.compile(r"\bgit\s+remote\s+add\b"), "remote creation is prohibited"),
    (re.compile(r"\bgit\s+remote\s+set-url\b"), "remote modification is prohibited"),
    (re.compile(r"\bgit\s+remote\s+remove\b"), "remote deletion is prohibited"),
    # system / container mutations on production
    (re.compile(r"\bsystemctl\s+(start|stop|restart|reload)\b"), "systemctl is prohibited"),
    (re.compile(r"\bdocker\s+compose\s+(up|down|restart)\b"), "production docker mutation is prohibited"),
    # remote shell to protected production hosts
    (re.compile(r"\bssh\s+horus\b"), "ssh to production is prohibited"),
    (re.compile(r"\bssh\s+firelove\b"), "ssh to production is prohibited"),
    # Hermes executable identity — when invoked via its CLI binary. Path
    # references like `~/.hermes/` and grep/docs mentioning Hermes are fine.
    # Matches: `hermes`, `/usr/bin/hermes`, `./hermes`, but NOT `cat hermes.txt`.
    (re.compile(r"(^|[\s;|&`\"'\\(])(?:\./|/usr/(?:bin|local/bin)/)?hermes(?:\s|$|&|;|\||`)"),
     "hermes CLI invocation is prohibited"),
    # Codex CLI — out of scope for the supervised local-only V1 pilot.
    (re.compile(r"(^|[\s;|&`\"'\\(])(?:\./|/usr/(?:bin|local/bin)/)?codex(?:\s|$|&|;|\||`)"),
     "codex invocation is out of scope for V1"),
]


# Bash command tokens that are allowed for the reviewer (read-only inspection
# plus the per-packet validation commands and the deterministic checkers).
REVIEWER_ALLOWLIST_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"^\s*git\s+status\b"),
    re.compile(r"^\s*git\s+log\b"),
    re.compile(r"^\s*git\s+show\b"),
    re.compile(r"^\s*git\s+diff\b"),
    re.compile(r"^\s*git\s+rev-parse\b"),
    re.compile(r"^\s*git\s+branch\b(?!.*-[dD])"),
    re.compile(r"^\s*git\s+worktree\s+list\b"),
    re.compile(r"^\s*git\s+cat-file\b"),
    re.compile(r"^\s*git\s+ls-files\b"),
    re.compile(r"^\s*git\s+ls-tree\b"),
    re.compile(r"^\s*cat\b"),
    re.compile(r"^\s*head\b"),
    re.compile(r"^\s*tail\b"),
    re.compile(r"^\s*ls\b"),
    re.compile(r"^\s*find\b"),
    re.compile(r"^\s*grep\b"),
    re.compile(r"^\s*rg\b"),
    re.compile(r"^\s*wc\b"),
    re.compile(r"^\s*shasum\b"),
    re.compile(r"^\s*sha256sum\b"),
    re.compile(r"^\s*python3?\b"),
    re.compile(r"^\s*jq\b"),
    re.compile(r"^\s*echo\b"),
    re.compile(r"^\s*printf\b"),
    re.compile(r"^\s*date\b"),
    re.compile(r"^\s*pwd\b"),
    re.compile(r"^\s*env\b"),
]


SECRET_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key"),
    (re.compile(r"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"), "PEM private key"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}"), "GitHub token"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"), "Slack token"),
    (re.compile(r"(?i)api[_-]?key\s*[:=]\s*['\"]?[A-Za-z0-9_\-]{16,}['\"]?"), "API key literal"),
    (re.compile(r"(?i)password\s*[:=]\s*['\"]?[^'\"\s]{8,}['\"]?"), "password literal"),
]


def classify_bash_command(command: str) -> dict[str, Any]:
    """Return a classification dict for a Bash command.

    Always returns:
      { 'command': str,
        'segments': [str],
        'forbidden': [str],
        'severity': 'allowed'|'warn'|'forbidden' }

    Splits the command on common shell-chain operators before classifying each
    segment, so `git status && git push` is detected as forbidden.

    Note: textual classification is ONE LAYER of defense. Forms that
    cannot be safely interpreted pre-execution (multiline heredocs, eval
    indirection, Python subprocess), defer to the post-pass verification
    layer and the sandbox boundary.
    """
    segments = _split_command_chain(command)
    forbidden: list[str] = []
    for seg in segments:
        for pattern, desc in FORBIDDEN_PATTERNS:
            if pattern.search(seg):
                forbidden.append(f"{desc}: {seg.strip()}")
    severity = "forbidden" if forbidden else "allowed"
    return {
        "command": command,
        "segments": segments,
        "forbidden": forbidden,
        "severity": severity,
    }


def _split_command_chain(command: str) -> list[str]:
    """Split a shell command into segments separated by &&, ||, ;, |.

    Naive but adequate — we are matching dangerous tokens, not parsing shell.

    Returns [] for multiline commands so the caller can defer to the
    post-pass verification layer instead of crashing the classifier.
    """
    if "\n" in command or "\r" in command:
        # Multiline/heredoc input: text classifier can't safely parse this.
        # The post-pass verification must catch any prohibited operation.
        return []

    parts: list[str] = []
    buf: list[str] = []
    i = 0
    n = len(command)
    in_single = False
    in_double = False
    in_backtick = False
    while i < n:
        ch = command[i]
        if ch == "\\" and i + 1 < n:
            buf.append(ch)
            buf.append(command[i + 1])
            i += 2
            continue
        if not in_double and not in_backtick and ch == "'":
            in_single = not in_single
            buf.append(ch)
            i += 1
            continue
        if not in_single and not in_backtick and ch == '"':
            in_double = not in_double
            buf.append(ch)
            i += 1
            continue
        if not in_single and not in_double and ch == "`":
            in_backtick = not in_backtick
            buf.append(ch)
            i += 1
            continue
        if not in_single and not in_double and not in_backtick and ch in "&|;":
            # Look for && or || as a single token; otherwise treat as separator.
            if ch in "&|" and i + 1 < n and command[i + 1] == ch:
                parts.append("".join(buf).strip())
                buf = []
                i += 2
                continue
            parts.append("".join(buf).strip())
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    last = "".join(buf).strip()
    if last:
        parts.append(last)
    return [p for p in parts if p]


def is_reviewer_allowed(command: str) -> bool:
    """Return True iff every segment of the command matches an allowed pattern."""
    segments = _split_command_chain(command)
    if not segments:
        # Multiline/unparseable: do not pretend it is allowed.
        return False
    for seg in segments:
        if not any(p.search(seg) for p in REVIEWER_ALLOWLIST_PATTERNS):
            return False
    return True


def scan_text_for_secrets(text: str) -> list[dict[str, str]]:
    """Return a list of {pattern, match, line} for any detected secret."""
    findings: list[dict[str, str]] = []
    for i, line in enumerate(text.splitlines(), start=1):
        for pattern, desc in SECRET_PATTERNS:
            m = pattern.search(line)
            if m:
                findings.append({"pattern": desc, "match": m.group(0), "line": str(i)})
    return findings


def scan_path_for_secrets(path: Path) -> list[dict[str, str]]:
    """Scan a file for secrets. Returns [] on read errors."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return scan_text_for_secrets(text)


def classify_for_executable_identity(command: str) -> list[str]:
    """Classify by executable identity — matches only when the literal CLI is
    on the argv (e.g. `hermes cron`, `/usr/local/bin/hermes run`, not
    `cat ~/.hermes/STATE.json`).

    Returns a list of human descriptions for any prohibited executable
    identity found. Used by post-pass verification (which can run on parsed
    argv) and not by the textual hook (which cannot reliably parse argv).
    """
    findings: list[str] = []
    tokens = shlex.split(command)
    for tok in tokens:
        # Strip a leading env-var assignment segment if any.
        base = tok.rsplit("/", 1)[-1]
        if base in ("hermes",):
            findings.append(f"hermes CLI invocation: {tok}")
        elif base in ("codex",):
            findings.append(f"codex CLI invocation: {tok}")
    return findings


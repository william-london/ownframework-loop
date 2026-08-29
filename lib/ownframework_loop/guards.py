"""Deterministic guardrails — bash command classification, path checks, secret scan.

Design contract (V1, post-audit):
- The textual classifier is one layer of defense; the post-pass review pass is
  the ultimate authority. The classifier is *not* a complete shell parser.
- Operator-installed executable identities are recognized only as the FIRST
  WORD of a shell segment (i.e. as the executable to invoke). The bare
  word in argv (e.g. `grep pattern`), filesystem paths under `~/.<name>/`,
  and docs that mention such tools are allowed.
- The guarded list of recognized executables is operator-overridable via
  the ``OFLOOP_RECOGNIZED_EXECUTABLES`` env var. The default is empty.
- See `docs/SECURITY_MODEL.md` for the full layered model.
"""

from __future__ import annotations

import os
import re
import shlex
from pathlib import Path
from typing import Any


# Bash command tokens that must NEVER be issued by an OwnFramework Loop pass.
# Each entry: (compiled regex, human description). Match anywhere in the argv
# of any segment of the command chain.
#
# Note on intent: every regex here targets an executable identity or a specific
# subcommand form. Do NOT add bare-keyword blocks (a bare-name block is a
# prompt-injection/UX hazard; paths under `~/.<name>/`, grep searches, and
# docs that mention the tool are legitimate).
#
# The shell-quote-insensitive patterns (e.g. for `git "push"`, `git 'push'`)
# normalize the command by stripping inline quotes before matching. This
# catches the most common form of arg-quoting bypass without parsing full
# shell; fuller forms (eval, Python subprocess) defer to NATIVE_PERMISSION
# + POST_PASS verification.
def _norm(s: str) -> str:
    """Strip inline single/double quotes for tolerant command matching."""
    return s.replace('"', '').replace("'", '')

FORBIDDEN_PATTERNS: list[tuple[re.Pattern[str], str, str]] = [
    # git push (any variant) — match plain and quote-insensitive forms.
    (re.compile(r"\bgit\s+push\b"), "git push is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+(?:-[A-Za-z]+\s+)*(?:\S+\s+)*push\b"), "git push (with options/args) is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+push\s+--force\b"), "force push is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+push\s+-f\b"), "force push is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+push\s+--force-with-lease\b"), "force push is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+push\s+--no-verify\b"), "git push --no-verify is prohibited", "subcommand"),
    # git merge (any form)
    (re.compile(r"\bgit\s+merge\b"), "git merge is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+merge\s+--no-ff\b"), "merge commit is prohibited", "subcommand"),
    # git reset / clean / branch destructive
    (re.compile(r"\bgit\s+reset\s+--hard\b"), "git reset --hard is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+clean\s+-?fdx?\b"), "git clean with force/clean-untracked is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+branch\s+-D\b"), "git branch -D is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+branch\s+-d\b"), "git branch -d is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+worktree\s+prune\b"), "broad git worktree prune is prohibited", "subcommand"),
    # git remote mutations
    (re.compile(r"\bgit\s+remote\s+add\b"), "remote creation is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+remote\s+set-url\b"), "remote modification is prohibited", "subcommand"),
    (re.compile(r"\bgit\s+remote\s+remove\b"), "remote deletion is prohibited", "subcommand"),
    # Human approval is intentionally outside the Claude agent tool surface.
    (re.compile(r"\b(?:\S*/)?ofloop\s+spec\s+approve\b"), "agent invocation of human approval is prohibited", "subcommand"),
    (re.compile(r"\bownframework_loop(?:\.cli)?\b.*\bspec\s+approve\b"), "agent invocation of human approval is prohibited", "subcommand"),
    # system / container mutations on production
    (re.compile(r"\bsystemctl\s+(start|stop|restart|reload)\b"), "systemctl is prohibited", "subcommand"),
    (re.compile(r"\bdocker\s+compose\s+(up|down|restart)\b"), "production docker mutation is prohibited", "subcommand"),
    # remote shell to operator-configured protected production hosts.
    # Targets are loaded from $OFLOOP_BLOCKED_SSH_TARGETS (whitespace- or
    # comma-separated). Empty/unset means no ssh-target blocks (universal
    # engine policy does NOT enumerate specific deployment identifiers).

]


def _load_operator_configured_ssh_blocks() -> list[tuple[re.Pattern[str], str, str]]:
    """Build ssh-target forbidden patterns from operator configuration.

    Honors $OFLOOP_BLOCKED_SSH_TARGETS as whitespace- or comma-separated
    target names. Unset/empty returns an empty list — no universal block.
    """
    import os as _os
    raw = _os.environ.get("OFLOOP_BLOCKED_SSH_TARGETS", "").strip()
    if not raw:
        return []
    targets = re.split(r"[\s,]+", raw)
    out: list[tuple[re.Pattern[str], str, str]] = []
    for t in targets:
        t = t.strip()
        if not t:
            continue
        # Escape any regex metacharacters in operator-supplied target names.
        esc = re.escape(t)
        out.append((re.compile(rf"\bssh\s+{esc}\b"),
                    f"ssh to operator-configured protected target '{t}' is prohibited",
                    "subcommand"))
    return out


# Append operator-configured ssh-target blocks at import time.
FORBIDDEN_PATTERNS.extend(_load_operator_configured_ssh_blocks())


def _load_operator_configured_executable_blocks() -> list[tuple[re.Pattern[str], str, str]]:
    """Build executable-identity forbidden patterns from operator configuration.

    Honors $OFLOOP_RECOGNIZED_AND_BLOCKED_EXECUTABLES as whitespace- or
    comma-separated names. Each name is matched only as the FIRST WORD of a
    shell segment (i.e. as the executable to invoke); filesystem paths
    (`~/.<name>/`, `<name>.txt`), grep searches, and docs mentions are
    legitimate and must not be blocked. Empty/unset means no executable
    blocks (universal engine policy does NOT enumerate specific operator
    tools).
    """
    import os as _os
    raw = _os.environ.get("OFLOOP_RECOGNIZED_AND_BLOCKED_EXECUTABLES", "").strip()
    if not raw:
        return []
    names = re.split(r"[\s,]+", raw)
    out: list[tuple[re.Pattern[str], str, str]] = []
    for name in names:
        name = name.strip()
        if not name:
            continue
        esc = re.escape(name)
        # Match only when the name is the first word of a shell segment.
        # The leading \A matches start-of-string; the [^;&|\s] group excludes
        # trailing args/flags. We use a non-greedy shell-segment start.
        out.append((re.compile(rf"(?:^|[;&|\n])\s*{esc}(?:\s|$)"),
                    f"operator-configured executable identity '{name}' invocation is prohibited",
                    "executable_identity"))
    return out


# Append operator-configured executable-identity blocks at import time.
FORBIDDEN_PATTERNS.extend(_load_operator_configured_executable_blocks())



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


def classify_bash_command(
    command: str,
    *,
    role: str | None = None,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Return a classification dict for a Bash command.

    Always returns:
      { 'command': str,
        'segments': [str],
        'forbidden': [str],
        'severity': 'allowed'|'warn'|'forbidden' }

    Splits the command on common shell-chain operators before classifying each
    segment, so `git status && git push` is detected as forbidden.

    Role semantics (v0.6.1):
      * role=None (default): structural classification only. External-
        action patterns in FORBIDDEN_PATTERNS are still detected, so a
        caller that wants "this command is forbidden" semantics can use
        the result without further role plumbing. This matches the
        historical hook behavior.
      * role="builder": same as role=None, plus the result carries
        ``role_constraints="builder"`` for callers that want to
        distinguish builder-context refusals from generic ones.
      * role="reviewer": everything in role=None is still forbidden,
        AND any segment that fails ``is_reviewer_allowed()`` is added
        to ``forbidden`` with a clear "reviewer read-only" reason.
        Reviewer lanes cannot mutate, install, or call anything outside
        the read-only allowlist.

    Note: textual classification is ONE LAYER of defense. Forms that
    cannot be safely interpreted pre-execution (multiline heredocs, eval
    indirection, Python subprocess), defer to the post-pass verification
    layer and the sandbox boundary.

    V2.0.1: applies layered normalizations to close known audit
    evasion forms (Python subprocess argv literals, variable
    assembly, hyphenated wrapper executable identity) before
    matching against forbidden patterns.
    """
    # Apply the same layered normalizations as external_action to close
    # the known audit evasion forms (Python subprocess, variable
    # assembly, hyphenated wrapper executable identity).
    try:
        from .external_action import (
            _normalize_hyphenated_executable,
            _normalize_python_argv,
            _normalize_variable_assignment,
        )
        # Strip backslash escapes (they appear when shell passes nested quotes).
        cmd_norm = command.replace("\\", "")
        cmd_norm = _normalize_python_argv(cmd_norm)
        cmd_norm = _normalize_variable_assignment(cmd_norm)
        cmd_norm = _normalize_hyphenated_executable(cmd_norm)
    except Exception:
        cmd_norm = command

    # Use the normalized command for splitting AND matching. This is
    # what closes the variable-assembly and python-subprocess evasion
    # forms. The original command is retained for diagnostics.
    segments = _split_command_chain(cmd_norm)
    if not segments:
        # Multiline/unparseable: fall back to the original.
        segments = _split_command_chain(command)
    forbidden: list[str] = []
    for seg in segments:
        first_word = _first_executable_word(seg)
        candidates = [seg, _norm(seg)]
        for pattern, desc, kind in FORBIDDEN_PATTERNS:
            if kind == "executable_identity":
                # Match ONLY against the first executable word. The compiled
                # pattern itself encodes the operator-supplied name (regex-
                # escaped), so filesystem paths (`~/.<name>/`, `<name>.txt`)
                # and grep/docs mentions are legitimate.
                if first_word is None:
                    continue
                norm_first = _norm(first_word)
                base = norm_first.rsplit("/", 1)[-1]
                if pattern.search(base) or pattern.search(norm_first):
                    forbidden.append(f"{desc}: {seg.strip()}")
                    break
                continue
            # Subcommand-shape patterns (git push, ssh <operator-blocked-target>, …) — match
            # the whole segment with permissive quote-stripping.
            for cand in candidates:
                if pattern.search(cand):
                    forbidden.append(f"{desc}: {seg.strip()}")
                    break
            else:
                continue
            break
    severity = "forbidden" if forbidden else "allowed"

    # v0.6.1 role-aware constraints: when role="reviewer", every segment
    # must additionally match the read-only allowlist. Builder (and None)
    # lanes get no extra constraint beyond FORBIDDEN_PATTERNS — the
    # semantic contract is that builders may mutate source but never
    # invoke external actions.
    role_constraints = None
    if role == "reviewer":
        role_constraints = "reviewer"
        for seg in segments:
            if is_reviewer_allowed(seg):
                continue
            forbidden.append(f"reviewer read-only lane: {seg.strip()}")

    severity = "forbidden" if forbidden else "allowed"
    return {
        "command": command,
        "segments": segments,
        "forbidden": forbidden,
        "severity": severity,
        "role": role,
        "role_constraints": role_constraints,
    }


def classify_bash_command_with_env(
    command: str,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Classify a bash command, deriving role from explicit env markers.

    Reads ``OFLOOP_SEMANTIC_CONTEXT``, ``OFLOOP_RUN_ID``, ``OFLOOP_ROLE``,
    and ``OFLOOP_CANONICAL_REPO`` from ``env`` (defaults to ``os.environ``).
    When ``OFLOOP_SEMANTIC_CONTEXT != "1"`` the role is ``None`` and the
    classifier returns structural findings only — callers that want the
    "no semantic context, no role enforcement" no-op semantics should
    check the env first and skip this function entirely.

    A partial env (context flag set without the other required vars) is
    treated as ``role=None`` and the partial status is surfaced in the
    result as ``partial_env=True`` so the caller can log the misconfigured
    supervisor and decide whether to fail closed.
    """
    e = env if env is not None else os.environ
    role: str | None = None
    partial_env = False
    if str(e.get("OFLOOP_SEMANTIC_CONTEXT") or "") == "1":
        env_role = str(e.get("OFLOOP_ROLE") or "")
        if env_role in ("builder", "reviewer"):
            role = env_role
        else:
            # OFLOOP_SEMANTIC_CONTEXT=1 with no/invalid role: refuse
            # the role upgrade (still call classify_bash_command with
            # role=None) but flag the partial state so callers can fail
            # closed.
            partial_env = True
    result = classify_bash_command(command, role=role)
    result["partial_env"] = partial_env
    return result


def _split_command_chain(command: str) -> list[str]:
    """Split a shell command into segments separated by &&, ||, ;, |, and newlines.

    Naive but adequate — we are matching dangerous tokens, not parsing shell.

    v0.3.5 (A3-001): multiline commands are no longer returned as [].
    Instead, each line is split on shell-chain operators and the union
    of all segments is returned. This closes the bypass where a
    forbidden action was hidden on a non-first line of a multiline
    command (e.g. `echo harmless\\ngit push origin master`).
    """
    if "\n" not in command and "\r" not in command:
        return _split_single_line(command)

    # Multiline: split on newlines, classify each line independently,
    # union the segments. Skip empty lines and pure-comment lines.
    parts: list[str] = []
    for raw_line in re.split(r"[\r\n]+", command):
        line = raw_line.strip()
        if not line:
            continue
        # Strip leading shell comment markers (a line starting with #)
        # but keep mid-line #s (used by git refspec). Comment-only lines
        # are skipped entirely.
        if line.startswith("#"):
            continue
        parts.extend(_split_single_line(line))
    return parts


def _split_single_line(command: str) -> list[str]:
    """Split a single-line command on &&, ||, ;, |."""
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


def _first_executable_word(segment: str) -> str | None:
    """Return the first non-assignment word of a shell segment.

    Strips leading `FOO=bar` environment-style assignments and any
    `command`/`builtin`/`env`/`nice`/`time` prefixes, returning the
    would-be executable path or bare command name. Returns None if the
    segment has no executable word (e.g. assignment-only).
    """
    if not segment:
        return None
    # Use shlex to split tokens correctly handling quotes.
    try:
        tokens = shlex.split(segment)
    except ValueError:
        tokens = segment.split()
    prefixes = {"command", "builtin", "env", "nice", "time", "stdbuf"}
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        # Skip env-var assignments like FOO=bar.
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
            i += 1
            continue
        # Skip recognized prefix commands.
        base = tok.rsplit("/", 1)[-1]
        if base in prefixes:
            i += 1
            continue
        return tok
    return None


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
    on the argv (e.g. `<name> subcommand`, `/usr/local/bin/<name> run`, not
    `cat ~/.<name>/STATE.json`).

    Returns a list of human descriptions for any prohibited executable
    identity found. The list is operator-configurable via
    $OFLOOP_HIGH_RISK_EXECUTABLES (whitespace- or comma-separated). Empty
    default means no universal list of flagged CLIs.

    Used by post-pass verification (which can run on parsed argv) and not
    by the textual hook (which cannot reliably parse argv).
    """
    import os as _os_cf
    flagged = set(re.split(r"[\s,]+", _os_cf.environ.get("OFLOOP_HIGH_RISK_EXECUTABLES", "").strip()))
    findings: list[str] = []
    if not flagged:
        return findings
    tokens = shlex.split(command)
    for tok in tokens:
        # Strip a leading env-var assignment segment if any.
        base = tok.rsplit("/", 1)[-1]
        if base in flagged:
            findings.append(f"flagged executable identity {base!r} invocation: {tok}")
    return findings

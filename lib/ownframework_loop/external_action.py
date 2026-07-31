"""External-action policy module.

OwnFramework Loop V2 allows broad engineering tools (read, write within
authority, shell, web search) but blocks external-side-effect tools
during an active run. The policy is implemented in one module so the
hooks and the orchestrator can share one set of rules.

Classification:

  ALLOW                         — ordinary engineering tool
  ALLOW_WITH_DIAGNOSTIC         — read-only tool, log a redacted diagnostic
  BLOCK:<code>                  — refused with reason code

Block codes:

  OF_LOOP_EXTERNAL_EMAIL        — sending email, SMS, DM
  OF_LOOP_EXTERNAL_CALENDAR     — calendar mutations
  OF_LOOP_EXTERNAL_PAYMENT      — money, refunds, billing
  OF_LOOP_EXTERNAL_PUBLISH      — public content
  OF_LOOP_EXTERNAL_PR           — create / merge / push PR
  OF_LOOP_EXTERNAL_REMOTE       — git remote mutation
  OF_LOOP_EXTERNAL_DEPLOY       — production deploy / rollout
  OF_LOOP_EXTERNAL_PROD_MUTATION — destructive cloud/prod mutation
  OF_LOOP_EXTERNAL_CUSTOMER     — customer-system mutation
  OF_LOOP_EXTERNAL_UNKNOWN      — unknown tool with plausible external side effect
"""

from __future__ import annotations

import re
from typing import Any


# Tool names that are everyday engineering tools — always allowed.
_ALLOWED_TOOLS: frozenset[str] = frozenset({
    "Read", "Glob", "Grep", "Bash", "Edit", "Write", "MultiEdit",
    "NotebookEdit", "WebSearch", "WebFetch", "Agent",
    "TodoWrite", "TodoRead", "Task", "TaskOutput", "TaskStop",
    "ScheduleWakeup", "CronCreate", "CronDelete", "CronList",
    "Skill", "EnterPlanMode", "ExitPlanMode", "EnterWorktree",
    "ExitWorktree", "ReportFindings",
})

# Read-only MCP verbs that are explicitly allowed.
_READ_ONLY_MCP_VERBS: tuple[str, ...] = (
    "search", "list", "get", "status", "inspect", "fetch",
    "read", "view", "show", "describe", "lookup", "query",
    "find", "resolve", "check", "head", "tail",
)


# Block patterns for Bash commands that look external.
_BLOCKED_BASH_PATTERNS: list[tuple[re.Pattern[str], str, str]] = [
    (re.compile(r"\bmail\s+"), "OF_LOOP_EXTERNAL_EMAIL", "mail send"),
    (re.compile(r"\bmailx\b"), "OF_LOOP_EXTERNAL_EMAIL", "mailx send"),
    (re.compile(r"\bsendmail\b"), "OF_LOOP_EXTERNAL_EMAIL", "sendmail"),
    (re.compile(r"\bsms\b.*--?send\b"), "OF_LOOP_EXTERNAL_EMAIL", "sms send"),
    (re.compile(r"\bslack\b.*--?send\b"), "OF_LOOP_EXTERNAL_EMAIL", "slack send"),
    (re.compile(r"\bdiscord\b.*--?send\b"), "OF_LOOP_EXTERNAL_EMAIL", "discord send"),
    (re.compile(r"\bgcal\b|\bcalendar\b.*--?create\b"), "OF_LOOP_EXTERNAL_CALENDAR", "calendar create"),
    (re.compile(r"\bcalcli\b"), "OF_LOOP_EXTERNAL_CALENDAR", "calcli"),
    (re.compile(r"\bstripe\b.*--?charge\b"), "OF_LOOP_EXTERNAL_PAYMENT", "stripe charge"),
    (re.compile(r"\bcharge\b.*--?amount\b"), "OF_LOOP_EXTERNAL_PAYMENT", "charge"),
    (re.compile(r"\btwilio\b"), "OF_LOOP_EXTERNAL_EMAIL", "twilio"),
    (re.compile(r"\bgh\s+pr\s+create\b"), "OF_LOOP_EXTERNAL_PR", "gh pr create"),
    (re.compile(r"\bgh\s+pr\s+merge\b"), "OF_LOOP_EXTERNAL_PR", "gh pr merge"),
    (re.compile(r"\bgh\s+release\b"), "OF_LOOP_EXTERNAL_PUBLISH", "gh release"),
    (re.compile(r"\bheroku\b.*--?deploy\b"), "OF_LOOP_EXTERNAL_DEPLOY", "heroku deploy"),
    (re.compile(r"\bvercel\b.*--?deploy\b"), "OF_LOOP_EXTERNAL_DEPLOY", "vercel deploy"),
    (re.compile(r"\bnetlify\b.*--?deploy\b"), "OF_LOOP_EXTERNAL_DEPLOY", "netlify deploy"),
    (re.compile(r"\baws\s+s3\s+(sync|mv|cp)\b.*--?recursive\b"), "OF_LOOP_EXTERNAL_PROD_MUTATION", "aws s3 sync"),
    (re.compile(r"\baws\s+rds\s+(modify|delete|reboot)\b"), "OF_LOOP_EXTERNAL_PROD_MUTATION", "aws rds modify"),
    (re.compile(r"\baws\s+ec2\s+(terminate|stop)\b"), "OF_LOOP_EXTERNAL_PROD_MUTATION", "aws ec2 terminate"),
    (re.compile(r"\baws\s+lambda\s+update-function-code\b"), "OF_LOOP_EXTERNAL_DEPLOY", "aws lambda update"),
    (re.compile(r"\bkubectl\s+(apply|delete|rollout)\b"), "OF_LOOP_EXTERNAL_DEPLOY", "kubectl apply"),
    (re.compile(r"\bknative\b"), "OF_LOOP_EXTERNAL_DEPLOY", "knative"),
    (re.compile(r"\bgcloud\b.*--?deploy\b"), "OF_LOOP_EXTERNAL_DEPLOY", "gcloud deploy"),
    (re.compile(r"\bterraform\s+apply\b"), "OF_LOOP_EXTERNAL_PROD_MUTATION", "terraform apply"),
    (re.compile(r"\bansible-playbook\b"), "OF_LOOP_EXTERNAL_PROD_MUTATION", "ansible"),
    (re.compile(r"\bhelm\s+(install|upgrade)\b"), "OF_LOOP_EXTERNAL_DEPLOY", "helm install"),
    (re.compile(r"\bsupabase\b.*--?deploy\b"), "OF_LOOP_EXTERNAL_DEPLOY", "supabase deploy"),
    (re.compile(r"\bfirebase\b.*--?deploy\b"), "OF_LOOP_EXTERNAL_DEPLOY", "firebase deploy"),
    (re.compile(r"\bgit\s+push\b"), "OF_LOOP_EXTERNAL_PR", "git push"),
    (re.compile(r"\bgit\s+remote\s+add\b"), "OF_LOOP_EXTERNAL_REMOTE", "git remote add"),
    (re.compile(r"\bgit\s+remote\s+set-url\b"), "OF_LOOP_EXTERNAL_REMOTE", "git remote set-url"),
    (re.compile(r"\bgit\s+remote\s+remove\b"), "OF_LOOP_EXTERNAL_REMOTE", "git remote remove"),
]


def _is_mcp_tool(name: str) -> bool:
    """Loose matcher for MCP-shaped tool names (mcp__server__verb)."""
    n = name.lower()
    return n.startswith("mcp__") or "_mcp__" in n or n.startswith("mcp-")


def _mcp_verb(name: str) -> str:
    """Return the trailing verb from an MCP-shaped tool name."""
    n = name.lower()
    # Strip leading mcp prefix and server prefix.
    parts = re.split(r"[_\-]+", n)
    if not parts:
        return ""
    # Drop empty leading parts.
    parts = [p for p in parts if p]
    if not parts:
        return ""
    if parts[0] in ("mcp", "server"):
        return parts[-1] if len(parts) > 1 else ""
    return parts[-1]


def classify_tool_call(*, tool_name: str, tool_input: dict[str, Any], active_run: str) -> str:
    """Classify a tool call from the active-run context.

    Returns "ALLOW", "ALLOW_WITH_DIAGNOSTIC", or "BLOCK:<code>\\n<reason>".
    """
    if not tool_name:
        return "ALLOW_WITH_DIAGNOSTIC"

    if tool_name in _ALLOWED_TOOLS:
        # Bash gets a deeper scan.
        if tool_name == "Bash":
            return _classify_bash(tool_input)
        return "ALLOW"

    # MCP-shaped tools.
    if _is_mcp_tool(tool_name):
        verb = _mcp_verb(tool_name)
        if verb in _READ_ONLY_MCP_VERBS:
            return "ALLOW_WITH_DIAGNOSTIC"
        # Unknown MCP verb: refuse in active run.
        return "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\nunknown MCP tool verb: " + tool_name

    # Unknown tool: refuse during an active run.
    return "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\nunknown tool during active run: " + tool_name


def _classify_bash(tool_input: dict[str, Any]) -> str:
    cmd = (tool_input.get("command") or "").strip()
    if not cmd:
        return "ALLOW"
    # Layered normalization:
    #   1. Strip shell quotes.
    #   2. Normalize Python-subprocess argv literals: ['git','push'] → git push
    #      and {"git":"push"} → git push. Bounded to literal close-brace forms
    #      seen in the audit attack matrix; opaque arbitrary Python code
    #      defers to the post-pass verification layer.
    #   3. Resolve simple shell variable assignment: `X=push; git $X` → `git push`.
    #      Bounded to single-token, no expansion chains.
    #   4. Normalize hyphenated wrapper executable identity: git-remote-add →
    #      git remote add. Bounded to the four forbidden executables in this
    #      module; ordinary hyphenated command names pass through.
    cmd_norm = cmd.replace('"', "").replace("'", "")
    # Strip backslash escapes from the command — they appear when shell
    # passes nested-quote arguments and they would otherwise block argv
    # literal matching for forms like `[\"git\",\"push\"]`.
    cmd_norm = cmd_norm.replace("\\", "")
    cmd_norm = _normalize_python_argv(cmd_norm)
    cmd_norm = _normalize_variable_assignment(cmd_norm)
    cmd_norm = _normalize_hyphenated_executable(cmd_norm)
    # Decompose chains so each segment is classified individually.
    for seg in cmd_norm.split(";"):
        seg = seg.strip()
        if not seg:
            continue
        for pattern, code, desc in _BLOCKED_BASH_PATTERNS:
            if pattern.search(seg):
                return "BLOCK:" + code + "\n" + desc + " refused in active run"
    return "ALLOW"


def _normalize_python_argv(cmd: str) -> str:
    """Replace bounded literal Python argv literals with bare command form.

    Examples:
        ['git','push']           → git push
        ["git", "remote", "add"] → git remote add
        ('curl','-X','POST')     → curl -X POST
        ["git", "push"]          → git push
        subprocess.run(["git", "push"]) → git push

    Bounded: matches only literal bracket/quote forms. Opaque arbitrary
    Python code (variable assembly, format strings) defers to the
    post-pass verification layer.

    The pattern is permissive about both `'` and `"` AND about backslash
    escaping (`\\"git\\"`), which is how shell scripts typically feed
    subprocess.run via Bash command strings. Also handles unquoted argv
    literals after the quote-strip pass:
        [git, push]   → git push
        [git, remote, add] → git remote add
    """
    import re as _re

    def apply(s: str) -> str:
        # 2-element quoted argv literal: ["x","y"]
        s = _re.sub(
            r"\[\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\]",
            lambda m: f"{m.group(1)} {m.group(2)}", s)
        # 3-element quoted argv literal
        s = _re.sub(
            r"\[\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\]",
            lambda m: f"{m.group(1)} {m.group(2)} {m.group(3)}", s)
        # 4-element quoted argv literal
        s = _re.sub(
            r"\[\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\]",
            lambda m: f"{m.group(1)} {m.group(2)} {m.group(3)} {m.group(4)}", s)
        # 2-element unquoted argv literal: [git, push]
        s = _re.sub(
            r"\[\s*([A-Za-z][A-Za-z0-9_\-.]+)\s*,\s*([A-Za-z][A-Za-z0-9_\-.]+)\s*\]",
            lambda m: f"{m.group(1)} {m.group(2)}", s)
        # 3-element unquoted argv literal
        s = _re.sub(
            r"\[\s*([A-Za-z][A-Za-z0-9_\-.]+)\s*,\s*([A-Za-z][A-Za-z0-9_\-.]+)\s*,\s*([A-Za-z][A-Za-z0-9_\-.]+)\s*\]",
            lambda m: f"{m.group(1)} {m.group(2)} {m.group(3)}", s)
        # subprocess.run("git push") → git push
        s = _re.sub(
            r'subprocess\.\w+\(\s*[\'"](\S[^\'"]*)[\'"]\s*\)',
            lambda m: m.group(1), s)
        # os.system("git push") → git push
        s = _re.sub(
            r'os\.\w+\(\s*[\'"](\S[^\'"]*)[\'"]\s*\)',
            lambda m: m.group(1), s)
        # executable="git", args=["push"] form
        s = _re.sub(
            r'executable\s*=\s*[\'"](\S+)[\'"]\s*,\s*args\s*=\s*\[\s*[\'"]([^\'"]+)[\'"]\s*\]',
            lambda m: f"{m.group(1)} {m.group(2)}", s)
        return s

    # Apply twice: once on the literal string, once on the backslash-stripped form.
    return apply(apply(cmd).replace('\\"', '"').replace("\\'", "'"))


def _normalize_variable_assignment(cmd: str) -> str:
    """Resolve bounded shell variable assignments.

    Example:
        X=push; Y=origin; Z=master; git $X $Y $Z
        → git push origin master
    """
    import re as _re
    # Build a map of FOO=value assignments that precede the executable.
    mapping: dict[str, str] = {}
    # Split on `;` first so each segment sees the right env state.
    parts = cmd.split(";")
    rebuilt: list[str] = []
    for part in parts:
        part_stripped = part.lstrip()
        # Find leading assignments.
        m = _re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(\S+)\s*", part_stripped)
        if m:
            mapping[m.group(1)] = m.group(2)
        # Now substitute $FOO with mapping[FOO] in the rest of the part.
        def sub(match: "_re.Match[str]") -> str:
            var = match.group(1)
            return mapping.get(var, match.group(0))
        substituted = _re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", sub, part_stripped)
        rebuilt.append(substituted)
    return ";".join(rebuilt)


def _normalize_hyphenated_executable(cmd: str) -> str:
    """Resolve hyphenated wrapper executable names to space-separated form.

    Examples:
        git-remote-add    → git remote add
        git-remote-remove → git remote remove
        git-push          → git push
        gh-pr-create      → gh pr create
        operator-cli-cron       → operator cli cron

    Bounded to the four forbidden executable categories in this module;
    ordinary hyphenated commands (grep-something, ls-tr, etc.) pass through.
    """
    import re as _re
    out = cmd
    # Note: we deliberately use hyphenated-equivalent-of-space for the
    # forbidden categories. This means a literal `git-remote-add` becomes
    # `git remote add` for matching purposes.
    for hyphenated, spaced in [
        ("git-remote-add", "git remote add"),
        ("git-remote-set-url", "git remote set-url"),
        ("git-remote-remove", "git remote remove"),
        ("git-push", "git push"),
        ("git-merge", "git merge"),
        ("git-reset-hard", "git reset --hard"),
        ("git-branch-d", "git branch -d"),
        ("git-branch-D", "git branch -D"),
        ("git-clean-fdx", "git clean -fdx"),
        ("git-worktree-prune", "git worktree prune"),
        ("gh-pr-create", "gh pr create"),
        ("gh-pr-merge", "gh pr merge"),
        ("gh-release", "gh release"),
        ("heroku-deploy", "heroku --deploy"),
        ("vercel-deploy", "vercel --deploy"),
        ("netlify-deploy", "netlify --deploy"),
        ("aws-lambda-update", "aws lambda update-function-code"),
        ("kubectl-apply", "kubectl apply"),
        ("kubectl-delete", "kubectl delete"),
        ("kubectl-rollout", "kubectl rollout"),
        ("gcloud-deploy", "gcloud --deploy"),
        ("terraform-apply", "terraform apply"),
        ("helm-install", "helm install"),
        ("helm-upgrade", "helm upgrade"),
        ("supabase-deploy", "supabase --deploy"),
        ("firebase-deploy", "firebase --deploy"),
    ]:
        out = _re.sub(rf"\b{_re.escape(hyphenated)}\b", spaced, out)
    return out

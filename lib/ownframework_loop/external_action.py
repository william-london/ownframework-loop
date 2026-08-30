"""External-action policy module.

OwnFramework Loop allows broad engineering tools (read, write within
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

# Mutating MCP operation tokens. MCP tool names are compound
# (mcp__<server>__<operation...>); a mutating verb ANYWHERE in the operation
# name refuses the call. Matching is exact-token, so `dataset_get` is not
# caught by `set` and `settings` is not caught by `set`.
_MUTATING_MCP_VERBS: frozenset[str] = frozenset({
    "create", "delete", "remove", "drop", "update", "write", "set", "put",
    "post", "patch", "send", "push", "merge", "deploy", "insert", "add",
    "edit", "modify", "mutate", "upload", "publish", "pay", "charge",
    "refund", "bill", "submit", "execute", "start", "stop", "restart",
    "kill", "approve", "reject", "invite", "assign", "unassign", "move",
    "rename", "archive", "close", "reopen", "reply", "comment", "apply",
})


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
    (re.compile(r"\bgh\s+pr\s+(close|reopen|edit|comment|review|ready)\b"), "OF_LOOP_EXTERNAL_PR", "gh pr mutation"),
    (re.compile(r"\bgh\s+release\b"), "OF_LOOP_EXTERNAL_PUBLISH", "gh release"),
    (re.compile(r"\bgh\s+api\b[^|;&]*-X\s*(POST|PUT|PATCH|DELETE)\b"), "OF_LOOP_EXTERNAL_PR", "gh api mutation"),
    (re.compile(r"\bgh\s+repo\s+(create|delete|edit|rename|archive)\b"), "OF_LOOP_EXTERNAL_REMOTE", "gh repo mutation"),
    (re.compile(r"\bgh\s+gist\s+(create|edit|delete)\b"), "OF_LOOP_EXTERNAL_PUBLISH", "gh gist mutation"),
    (re.compile(r"\bgh\s+issue\s+(create|close|reopen|edit|delete|transfer)\b"), "OF_LOOP_EXTERNAL_PR", "gh issue mutation"),
    # Registry publish / image push (external distribution effects). These are
    # refused here as well as in guards.FORBIDDEN_PATTERNS (defense in depth).
    (re.compile(r"\bnpm\s+publish\b"), "OF_LOOP_EXTERNAL_PUBLISH", "npm publish"),
    (re.compile(r"\bpnpm\s+publish\b"), "OF_LOOP_EXTERNAL_PUBLISH", "pnpm publish"),
    (re.compile(r"\byarn\s+publish\b"), "OF_LOOP_EXTERNAL_PUBLISH", "yarn publish"),
    (re.compile(r"\bcargo\s+publish\b"), "OF_LOOP_EXTERNAL_PUBLISH", "cargo publish"),
    (re.compile(r"\btwine\s+upload\b"), "OF_LOOP_EXTERNAL_PUBLISH", "twine upload"),
    (re.compile(r"\bdocker\s+push\b"), "OF_LOOP_EXTERNAL_PUBLISH", "docker push"),
    (re.compile(r"\bdocker\s+compose\s+push\b"), "OF_LOOP_EXTERNAL_PUBLISH", "docker compose push"),
    (re.compile(r"\bdocker-compose\s+push\b"), "OF_LOOP_EXTERNAL_PUBLISH", "docker-compose push"),
    (re.compile(r"\bhelm\s+push\b"), "OF_LOOP_EXTERNAL_PUBLISH", "helm push"),
    (re.compile(r"\bcrane\s+push\b"), "OF_LOOP_EXTERNAL_PUBLISH", "crane push"),
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


def _classify_mcp(name: str) -> str:
    """Classify a compound MCP operation name fail-closed.

    MCP operation names are compound (``mcp__<server>__<op...>``). Inspecting
    only the trailing token is unsafe in both directions: a mutating verb in a
    non-final position would slip through, and a harmless compound read such as
    ``list_issues`` would be refused because its tail is not itself a read
    verb. Scan every operation token instead:

      * any mutating verb anywhere  -> BLOCK;
      * else any read-only verb     -> ALLOW_WITH_DIAGNOSTIC;
      * else (no recognizable verb) -> BLOCK (fail closed).
    """
    n = name.lower()
    parts = [p for p in re.split(r"[_\-]+", n) if p]
    if parts and parts[0] == "mcp":
        parts = parts[1:]
    mutating = [p for p in parts if p in _MUTATING_MCP_VERBS]
    if mutating:
        return (
            "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\n"
            "MCP operation contains mutating verb(s) "
            f"{', '.join(sorted(set(mutating)))}: {name}"
        )
    if any(p in _READ_ONLY_MCP_VERBS for p in parts):
        return "ALLOW_WITH_DIAGNOSTIC"
    return "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\nunknown MCP operation: " + name


def classify_tool_call(*, tool_name: str, tool_input: dict[str, Any], active_run: str) -> str:
    """Classify a tool call from the active-run context.

    Returns "ALLOW", "ALLOW_WITH_DIAGNOSTIC", or "BLOCK:<code>\\n<reason>".
    An unidentifiable tool fails closed: external-authority classification must
    never degrade to an allowance. Every BLOCK reason carries the exact
    semantic-context run id when known, so refusal evidence identifies the
    run it protected.
    """
    decision = _classify(tool_name=tool_name, tool_input=tool_input)
    if decision.startswith("BLOCK:") and active_run:
        decision = decision + f"\n[active run: {active_run}]"
    return decision


def _classify(*, tool_name: str, tool_input: dict[str, Any]) -> str:
    if not tool_name:
        return "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\nempty tool name during active run"

    if tool_name in _ALLOWED_TOOLS:
        # Bash gets a deeper scan.
        if tool_name == "Bash":
            return _classify_bash(tool_input)
        return "ALLOW"

    # MCP-shaped tools.
    if _is_mcp_tool(tool_name):
        return _classify_mcp(tool_name)

    # Unknown tool: refuse during an active run.
    return "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\nunknown tool during active run: " + tool_name


def _classify_bash(tool_input: dict[str, Any]) -> str:
    cmd = (tool_input.get("command") or "").strip()
    if not cmd:
        return "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\\nempty Bash command during active run"
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
    # ONE shared shell-chain parser serves this module and guards.py:
    # `;` alone misses `cmd && curl ...` / `cmd || curl ...` / piped
    # forms, which would hide a mutating tail behind a harmless head.
    for seg in _split_command_chain(cmd_norm):
        seg = seg.strip()
        if not seg:
            continue
        for pattern, code, desc in _BLOCKED_BASH_PATTERNS:
            if pattern.search(seg):
                return "BLOCK:" + code + "\n" + desc + " refused in active run"
        http_violation = _http_mutation_violation(seg)
        if http_violation:
            return (
                "BLOCK:OF_LOOP_EXTERNAL_UNKNOWN\n"
                f"{http_violation} refused in active run"
            )
    return "ALLOW"


def _split_command_chain(command: str) -> list[str]:
    """Split a shell command into segments separated by &&, ||, ;, |, newlines.

    The single canonical chain parser for all textual classification in
    OwnFramework Loop (guards.py imports this exact implementation). Naive
    but adequate — we are matching dangerous tokens, not parsing shell.

    Multiline commands are split per line and the union of all segments is
    returned, so a forbidden action hidden on a non-first line is still
    classified.
    """
    if "\n" not in command and "\r" not in command:
        return _split_single_line(command)

    parts: list[str] = []
    for raw_line in re.split(r"[\r\n]+", command):
        line = raw_line.strip()
        if not line:
            continue
        # Comment-only lines are skipped entirely; mid-line #s (e.g. git
        # refspec) are preserved.
        if line.startswith("#"):
            continue
        parts.extend(_split_single_line(line))
    return parts


def _split_single_line(command: str) -> list[str]:
    """Split a single-line command on &&, ||, ;, | (quote-aware)."""
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
            # fd redirects are not separators: `2>&1`, `>&2`, `&>`.
            if ch == "&":
                prev_ch = command[i - 1] if i > 0 else ""
                next_ch = command[i + 1] if i + 1 < n else ""
                if prev_ch == ">" or next_ch == ">":
                    buf.append(ch)
                    i += 1
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


# Mutating HTTP request flags for curl/wget. Local development legitimately
# issues POST/PUT against loopback services (dev servers, local APIs, e2e).
# The governed-lane rule is fail-closed on destination:
#   mutating HTTP + destination provably loopback     -> allowed
#   mutating HTTP + destination external              -> blocked
#   mutating HTTP + destination cannot be proven
#   loopback (no literal URL, unresolved variable)    -> blocked
_CURL_MUTATING = re.compile(
    r"(?:^|\s)(?:"
    r"-X\s*(?:POST|PUT|DELETE|PATCH)\b"
    r"|--request[=\s](?:POST|PUT|DELETE|PATCH)\b"
    r"|--data(?:-binary|-raw|-urlencode|-ascii)?\b"
    r"|-d\b"
    r"|-F\b|--form\b"
    r"|-T\b|--upload-file\b"
    r"|--json\b"
    r")",
    re.IGNORECASE,
)
_WGET_MUTATING = re.compile(
    r"(?:--post-data|--post-file|--body-data|--method[=\s](?:POST|PUT|DELETE|PATCH))",
    re.IGNORECASE,
)
_URL_HOST = re.compile(r"https?://([^/:?\s]+)", re.IGNORECASE)
_LOOPBACK_HOSTS = frozenset({
    "localhost", "127.0.0.1", "::1", "0.0.0.0", "ip6-localhost",
})


def _host_is_loopback(host: str) -> bool:
    h = host.lower().strip("[]")
    if h in _LOOPBACK_HOSTS:
        return True
    if h.startswith("127."):
        return True
    if h == "localhost.localdomain" or h.endswith(".localhost"):
        return True
    return False


def _http_mutation_violation(seg: str) -> str:
    """Return a violation description when a segment performs a mutating HTTP
    request whose destination is not PROVABLY loopback; empty string only
    when the segment is non-mutating or every visible destination is
    loopback.

    Variable-assignment resolution runs before segmentation, so any `$`
    reference still present here is unresolved; an unresolved or absent
    destination cannot be proven loopback and fails closed.
    """
    first = seg.split()[0] if seg.split() else ""
    base = first.rsplit("/", 1)[-1].lower()
    if base == "curl":
        if not _CURL_MUTATING.search(seg):
            return ""
    elif base == "wget":
        if not _WGET_MUTATING.search(seg):
            return ""
    else:
        return ""
    hosts = _URL_HOST.findall(seg)
    if hosts:
        external = [h for h in hosts if not _host_is_loopback(h)]
        if external:
            return (
                f"mutating HTTP request toward non-loopback host(s) "
                f"{', '.join(sorted(set(external)))}"
            )
        return ""
    if "$" in seg:
        return (
            "mutating HTTP request with unresolved destination "
            "(shell variable); cannot prove loopback"
        )
    return (
        "mutating HTTP request with no visible destination; "
        "cannot prove loopback"
    )


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

# Native Claude Permission Profile

> The OwnFramework Loop V2 supervised-local-only pilot REQUIRES Claude
> permission rules to be active in any session that runs an active loop.
> The plugin hooks are a contextual guard; native Claude permissions are a
> structural one. Both must be present.

## How to enable (per session, no global write)

The OwnFramework Loop **does NOT** modify `~/.claude/settings.json`
silently. The first supervised pilot requires:

```bash
# In your shell, before launching Claude:
export OFLOOP_PERMISSIONS_PROFILE=enforce

# Optional: enable Claude Bash sandbox in this session only:
# (per official Claude Code docs, set via permission-rule settings or --sandbox flag)
claude --plugin-dir /Users/mr.mrs.london/.claude/skills/of-loop \
      --permission-profile enforce
```

## The `enforce` profile

In an active OwnFramework Loop run, the `enforce` profile must deny or
require refusal for every operation that the post-pass verification layer
also checks. The exact rules, in documented Claude permission syntax:

```json
{
  "permissions": {
    "deny": [
      "Bash(git push:*)",
      "Bash(git push --force:*)",
      "Bash(git push --force-with-lease:*)",
      "Bash(git push --no-verify:*)",
      "Bash(git merge:*)",
      "Bash(git merge --no-ff:*)",
      "Bash(git reset --hard:*)",
      "Bash(git clean -fd:*)",
      "Bash(git clean -fdx:*)",
      "Bash(git clean:*)",
      "Bash(git branch -D:*)",
      "Bash(git branch -d:*)",
      "Bash(git worktree prune:*)",
      "Bash(git remote add:*)",
      "Bash(git remote set-url:*)",
      "Bash(git remote remove:*)",
      "Bash(systemctl *:*)",
      "Bash(docker compose up:*)",
      "Bash(docker compose down:*)",
      "Bash(docker compose restart:*)",
      "Bash(ssh horus:*)",
      "Bash(ssh firelove:*)",
      "Bash(/usr/bin/hermes:*)",
      "Bash(/usr/local/bin/hermes:*)",
      "Bash(codex:*)",
      "Edit(/Users/mr.mrs.london/projects/plugins/horus/**)",
      "Edit(/Users/mr.mrs.london/projects/plugins/firelove/**)",
      "Edit(/Users/mr.mrs.london/projects/plugins/cockpit/**)",
      "Edit(/Users/mr.mrs.london/projects/plugins/video-factory/**)"
    ],
    "ask": [
      "Bash(ofloop *)"
    ]
  }
}
```

These rules are model-independent — they sit in the Claude session's
permission system, not in any plugin instruction file.

## What the profile does NOT cover

- Python subprocess (`python3 -c "import subprocess; subprocess.run(['git','push'])"`),
  `eval`, variable-indirection, multiline/heredoc commands — these are
  intentionally not blocked by name. They are caught by the **post-pass
  verification layer** (the audit compares the actual `git` remote count
  and HEAD against the expected baseline after every build/review pass)
  and by the **sandbox boundary** (writes outside the approved worktree
  + loop state directory are refused by the OS-level sandbox).
- `OWNFRAMEWORK_ALLOW=1` — there is no such variable. Removing it would be
  a no-op; the variable is never read.

## Why two layers

The textual classifier does not parse shell. Determined forms (multiline,
eval, Python) evade it. The sandbox boundary is OS-level and enforces
write scope. The post-pass verification is the audit-authoritative
"what actually happened" layer — it inspects git history, remote count,
file diffs, and writes the receipt/verdict only after the artifacts
agree. Both must be present for a supervised pilot to launch.

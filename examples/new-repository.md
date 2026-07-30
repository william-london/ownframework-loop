# Example — new repository packet

Use this shape for `work_class: NEW_REPOSITORY`. The skill refuses to create
a remote or push. The baseline is a minimal bootstrap; product code lives on
the candidate branch.

```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "new-repo-edge-fetcher-001",
  "created_at": "2026-07-23T05:15:00Z",
  "work_class": "NEW_REPOSITORY",
  "risk_class": "medium",
  "authority_class": "medium",
  "title": "Bootstrap a new local-only repository: edge-fetcher",
  "target": {
    "repo": "/srv/repos/edge-fetcher",
    "branch": "master",
    "classification": "local_only"
  },
  "acceptance_criteria": [
    { "id": "AC-1", "text": "Repo exists at the absolute path with branch master and zero remotes", "verification": "ofloop new-repo /srv/repos edge-fetcher --init-baseline" },
    { "id": "AC-2", "text": "Minimal bootstrap baseline (README, .gitignore) is committed", "verification": "git -C /srv/repos/edge-fetcher show HEAD" }
  ],
  "non_goals": [
    { "id": "NG-1", "text": "Do not create a remote" },
    { "id": "NG-2", "text": "Do not push" }
  ],
  "allowed_paths": ["src/", "tests/", "docs/", "README.md", ".gitignore"],
  "protected_paths": ["AGENTS.md", "CLAUDE.md", ".claude/", ".ownframework-loop/", "state/"],
  "required_validation": [
    { "name": "git_identity", "command": "git -C <repo> branch --show-current", "kind": "fast", "expected_exit_code": 0 }
  ],
  "work_units": [
    { "id": "UNIT-1", "title": "Bootstrap repo + initial commit", "scope": "git init -b master, write README and .gitignore, make initial commit", "acceptance": ["AC-1", "AC-2"] }
  ],
  "risk_budget": {
    "max_diff_lines": 100,
    "max_files_changed": 3
  },
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```

# Mission

Create a new local-only repository for an edge-fetcher service. No remote,
no public repository. The bootstrap commit is the minimal baseline.

# Non-goals

- NG-1: Do not create a remote.
- NG-2: Do not push.

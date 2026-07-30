# Example — bug fix packet

Use this shape for `work_class: BUG`.

```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "bug-flake-login-001",
  "created_at": "2026-07-23T05:00:00Z",
  "work_class": "BUG",
  "risk_class": "medium",
  "authority_class": "low",
  "title": "Fix intermittent 500 on /login when email contains a '+' character",
  "target": {
    "repo": "/srv/repos/example-app",
    "branch": "master",
    "classification": "local_only"
  },
  "acceptance_criteria": [
    { "id": "AC-1", "text": "POST /login with email 'foo+bar@example.com' returns 200", "verification": "curl -X POST ... -d '{\"email\":\"foo+bar@example.com\"}'" },
    { "id": "AC-2", "text": "All existing tests pass", "verification": "make test-fast" }
  ],
  "non_goals": [
    { "id": "NG-1", "text": "Do not introduce a new identity provider abstraction" }
  ],
  "relevant_paths": ["src/auth/", "tests/auth/"],
  "allowed_paths": ["src/auth/", "tests/auth/"],
  "protected_paths": ["AGENTS.md", "CLAUDE.md", ".claude/", ".ownframework-loop/", "state/"],
  "required_validation": [
    { "name": "fast_tests", "command": "make test-fast", "kind": "fast", "expected_exit_code": 0 }
  ],
  "work_units": [
    { "id": "UNIT-1", "title": "Reproduce and fix", "scope": "Diagnose the URL-decoding path and add a regression test", "acceptance": ["AC-1", "AC-2"] }
  ],
  "risk_budget": {
    "max_diff_lines": 200,
    "max_files_changed": 4
  },
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```

# Mission

The login endpoint returns HTTP 500 when the email address contains a `+`
character. Suspect an over-eager URL decoding step in the auth middleware.

# Acceptance criteria

- AC-1: POST /login with `foo+bar@example.com` returns 200.
- AC-2: All existing tests pass.

# Non-goals

- NG-1: Do not introduce a new identity provider abstraction.

# Ordered work units

- UNIT-1: Reproduce and fix
  - scope: diagnose the URL-decoding path, fix it, add a regression test.
  - acceptance: AC-1, AC-2.

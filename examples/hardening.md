# Example — hardening packet

Use this shape for `work_class: HARDENING`.

```json
{
  "schema": "ownframework-work-packet/v1",
  "packet_id": "harden-rate-limit-001",
  "created_at": "2026-07-23T05:05:00Z",
  "work_class": "HARDENING",
  "risk_class": "medium",
  "authority_class": "low",
  "title": "Add per-IP rate limit to /api/sync",
  "target": {
    "repo": "/Users/mr.mrs.london/projects/example-app",
    "branch": "master",
    "classification": "local_only"
  },
  "acceptance_criteria": [
    { "id": "AC-1", "text": "A 429 response is returned after 60 requests from one IP in 60s", "verification": "tests/integration/rate_limit_test.py" },
    { "id": "AC-2", "text": "No regression in /api/sync correctness under normal load", "verification": "tests/integration/sync_test.py" }
  ],
  "non_goals": [
    { "id": "NG-1", "text": "Do not add a new third-party dependency" }
  ],
  "allowed_paths": ["src/api/sync/", "src/middleware/", "tests/api/"],
  "protected_paths": ["AGENTS.md", "CLAUDE.md", ".claude/", ".ownframework-loop/", "state/"],
  "required_validation": [
    { "name": "fast_tests", "command": "make test-fast", "kind": "fast", "expected_exit_code": 0 }
  ],
  "work_units": [
    { "id": "UNIT-1", "title": "Token bucket middleware + tests", "scope": "Add a token bucket middleware and unit + integration tests", "acceptance": ["AC-1", "AC-2"] }
  ],
  "risk_budget": {
    "max_diff_lines": 350,
    "max_files_changed": 8
  },
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```

# Mission

`/api/sync` is currently unbounded. Add a token bucket middleware keyed by
client IP. Provide tests that exercise the new behavior without depending on
a real clock.

# Non-goals

- NG-1: No new third-party dependency.

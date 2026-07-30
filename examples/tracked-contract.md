# Example — tracked contract packet

Use this shape when an outside contract (audit, regulation, customer promise)
must be honored. `work_class: TRACKED_CONTRACT`.

```json
{
  "schema": "ownframework-work-packet/v2",
  "packet_id": "contract-soc2-evidence-001",
  "created_at": "2026-07-23T05:10:00Z",
  "work_class": "TRACKED_CONTRACT",
  "risk_class": "high",
  "authority_class": "high",
  "title": "Add SOC2 evidence export endpoint",
  "target": {
    "repo": "/srv/repos/example-app",
    "branch": "master",
    "classification": "local_only"
  },
  "acceptance_criteria": [
    { "id": "AC-1", "text": "GET /admin/evidence returns the last 30 days of audit events as JSONL", "verification": "scripts/verify_evidence.sh" }
  ],
  "non_goals": [
    { "id": "NG-1", "text": "Do not expose the endpoint without an explicit admin token" }
  ],
  "allowed_paths": ["src/admin/", "tests/admin/"],
  "protected_paths": ["AGENTS.md", "CLAUDE.md", ".claude/", ".ownframework-loop/", "state/"],
  "required_validation": [
    { "name": "fast_tests", "command": "make test-fast", "kind": "fast", "expected_exit_code": 0 }
  ],
  "work_units": [
    { "id": "UNIT-1", "title": "Endpoint + tests + admin token gate", "scope": "Add endpoint, JSONL serializer, integration tests, admin-token middleware", "acceptance": ["AC-1"] }
  ],
  "codex_escalation_conditions": [
    "data boundary change",
    "production infrastructure"
  ],
  "risk_budget": {
    "max_diff_lines": 400,
    "max_files_changed": 10
  },
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```

# Mission

Implement a SOC2 evidence export endpoint that produces an immutable JSONL
trail of the last 30 days of audit events. Gate it behind an explicit
admin token. Code review must include Codex on data-boundary concerns.

# Non-goals

- NG-1: Do not expose the endpoint without an admin token.

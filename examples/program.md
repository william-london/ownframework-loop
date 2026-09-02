# Example — PROGRAM packet

Use this shape when one bounded mission benefits from a finite ordered
checkpoint graph rather than separate independent runs.

```json
{
  "schema": "ownframework-work-packet/v3",
  "packet_id": "program-api-observability-001",
  "created_at": "2026-09-02T12:00:00Z",
  "work_class": "FEATURE",
  "risk_class": "medium",
  "authority_class": "medium",
  "title": "Add structured API request tracing with regression coverage",
  "target": {
    "repo": "/srv/repos/example-app",
    "branch": "master",
    "classification": "local_only"
  },
  "execution_mode": "program",
  "checkpoint_graph": {
    "execution_order": ["CP-1", "CP-2"],
    "checkpoints": [
      {
        "id": "CP-1",
        "title": "Tracing foundation",
        "scope": "Add request-id propagation and structured trace fields.",
        "depends_on": [],
        "acceptance_criterion_ids": ["AC-1"],
        "risk_budget": {
          "max_build_passes": 2,
          "max_review_passes": 2,
          "max_repair_rounds": 1
        }
      },
      {
        "id": "CP-2",
        "title": "Coverage and operator docs",
        "scope": "Add regression coverage and document the observable trace contract.",
        "depends_on": ["CP-1"],
        "acceptance_criterion_ids": ["AC-2", "AC-3"],
        "risk_budget": {
          "max_build_passes": 2,
          "max_review_passes": 2,
          "max_repair_rounds": 1
        }
      }
    ],
    "global_source_ceilings": {
      "max_unique_changed_files": 12,
      "max_baseline_to_final_diff_lines": 800
    }
  },
  "promotion_policy": "human_gate",
  "acceptance_criteria": [
    {
      "id": "AC-1",
      "text": "Every API request receives one stable request id that is propagated through application logs.",
      "verification": "python -m pytest -q tests/api/test_request_tracing.py"
    },
    {
      "id": "AC-2",
      "text": "Regression tests cover generated and inbound request ids without relying on network services.",
      "verification": "python -m pytest -q tests/api/test_request_tracing.py"
    },
    {
      "id": "AC-3",
      "text": "Operator documentation describes the request-id field and correlation workflow.",
      "verification": "test -f docs/request-tracing.md"
    }
  ],
  "non_goals": [
    {
      "id": "NG-1",
      "text": "Do not add a hosted tracing vendor or perform deployment."
    }
  ],
  "relevant_paths": ["src/api/", "src/logging/", "tests/api/", "docs/"],
  "allowed_paths": ["src/api/", "src/logging/", "tests/api/", "docs/"],
  "protected_paths": ["AGENTS.md", "CLAUDE.md", ".claude/", ".ownframework-loop/", "state/"],
  "capabilities": ["toolchain.python"],
  "runner_profile": "primary",
  "network_read_allowlist": [],
  "required_validation": [
    {
      "name": "api_tests",
      "command": "python -m pytest -q tests/api/test_request_tracing.py",
      "kind": "full",
      "expected_exit_code": 0
    }
  ],
  "risk_budget": {
    "max_build_passes": 4,
    "max_review_passes": 4,
    "max_repair_rounds": 2,
    "max_diff_lines": 800,
    "max_files_changed": 12,
    "max_runtime_seconds": 14400,
    "max_pass_runtime_seconds": 3600,
    "max_consecutive_no_progress_passes": 4,
    "max_identical_finding_repeats": 4
  },
  "work_units": [
    {
      "id": "UNIT-1",
      "title": "Tracing foundation",
      "scope": "Implement stable request-id propagation and structured logging.",
      "acceptance": ["AC-1"]
    },
    {
      "id": "UNIT-2",
      "title": "Tests and documentation",
      "scope": "Prove request-id behavior and document the operator contract.",
      "acceptance": ["AC-2", "AC-3"]
    }
  ],
  "rollback_requirements": "Revert the candidate branch and rerun the API test suite.",
  "product_decisions": [
    "Use application-owned request ids rather than introducing a tracing vendor."
  ],
  "escalation_conditions": [
    "A required change falls outside the declared API/logging/test/documentation paths."
  ],
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```

# Mission

Add request tracing in two bounded checkpoints: first establish request-id
propagation and structured logging, then prove the behavior and document it.

# Acceptance criteria

- AC-1: Stable request-id propagation is observable in application logs.
- AC-2: Regression coverage proves generated and inbound request ids.
- AC-3: Operator documentation explains the correlation contract.

# Non-goals

- NG-1: No tracing vendor and no deployment.

# Ordered checkpoints

- CP-1: tracing foundation — AC-1.
- CP-2: tests and documentation — AC-2, AC-3; depends on CP-1.

The `primary` runner profile is an operator-owned name. Replace it with a
commissioned profile available on the execution host before using this example
for a real run.

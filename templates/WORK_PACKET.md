<!--
WORK_PACKET.md template for OwnFramework Loop V1.

The metadata block is JSON inside a triple-backtick fence. Do NOT depend on
YAML parsing. The body sections are Markdown for human review.

Replace every <placeholder> with concrete content. Validate the metadata
against schemas/work-packet.schema.json before approval.
-->
```json
{
  "schema": "ownframework-work-packet/v1",
  "packet_id": "<uuid-or-slug>",
  "created_at": "<UTC ISO 8601>",
  "work_class": "FEATURE",
  "risk_class": "medium",
  "authority_class": "medium",
  "title": "<one-line title>",
  "target": {
    "repo": "<absolute path>",
    "branch": "master",
    "classification": "local_only",
    "expected_baseline_sha": "<optional 7+ hex>",
    "candidate_branch_prefix": "factory/candidate/"
  },
  "acceptance_criteria": [
    { "id": "AC-1", "text": "<observable>", "verification": "<command + marker>" }
  ],
  "non_goals": [
    { "id": "NG-1", "text": "<observable refusal>" }
  ],
  "relevant_paths": ["src/", "tests/", "docs/"],
  "allowed_paths": ["src/", "tests/", "docs/"],
  "protected_paths": ["AGENTS.md", "CLAUDE.md", ".claude/", ".ownframework-loop/", "state/"],
  "required_validation": [
    { "name": "fast_tests", "command": "<fast test command>", "kind": "fast", "expected_exit_code": 0 },
    { "name": "full_tests", "command": "<full test command>", "kind": "full", "expected_exit_code": 0 },
    { "name": "secret_scan", "command": "<deterministic secret scan>", "kind": "secret", "expected_exit_code": 0 }
  ],
  "required_runtime_proof": {
    "description": "<optional proof>",
    "max_runtime_seconds": 600
  },
  "risk_budget": {
    "max_build_passes": 4,
    "max_review_passes": 4,
    "max_repair_rounds": 3,
    "max_diff_lines": 400,
    "max_files_changed": 12,
    "max_runtime_seconds": 28800,
    "max_pass_runtime_seconds": 1800,
    "max_consecutive_no_progress_passes": 2,
    "max_identical_finding_repeats": 2
  },
  "work_units": [
    { "id": "UNIT-1", "title": "<one line>", "scope": "<one sentence>", "acceptance": ["AC-1"] }
  ],
  "rollback_requirements": "Revert candidate branch; rerun full test suite.",
  "product_decisions": ["<decision id>"],
  "codex_escalation_conditions": ["<trigger>"],
  "human_approved": false,
  "merge_authority": "human_only",
  "deploy_authority": "human_only",
  "push_authority": "human_only",
  "external_action_authority": "none"
}
```

# Mission

<objective>

# Acceptance criteria

- AC-1: <text>

# Non-goals

- NG-1: <text>

# Ordered work units

- UNIT-1: <title>
  - scope: <sentence>
  - acceptance: AC-1

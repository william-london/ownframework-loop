from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "tests" / "integration" / "test_v090_bounded_concurrency.sh"
text = path.read_text(encoding="utf-8")

old_import = "from ownframework_loop import dispatch, guards, supervisor, worktrees\n"
new_import = (
    "from ownframework_loop import dispatch, guards, supervisor, "
    "supervisor_accounting, supervisor_identity, worktrees\n"
)
if old_import not in text:
    raise RuntimeError("v090 import surface drifted")
text = text.replace(old_import, new_import, 1)

# Recovery consumes durable-output parsers from the canonical accounting owner.
# Keep the race test aimed at that owner rather than retaining an upward import
# only so a legacy supervisor-facade monkey patch remains visible.
for old, new in {
    "orig_cost_parser = supervisor._parse_cost_from_durable_stdout":
        "orig_cost_parser = supervisor_accounting.parse_cost_from_durable_stdout",
    "orig_usage_parser = supervisor._parse_token_usage_from_durable_stdout":
        "orig_usage_parser = supervisor_accounting.parse_token_usage_from_durable_stdout",
    "supervisor._parse_cost_from_durable_stdout = fake_cost_parser":
        "supervisor_accounting.parse_cost_from_durable_stdout = fake_cost_parser",
    "supervisor._parse_token_usage_from_durable_stdout = fake_usage_parser":
        "supervisor_accounting.parse_token_usage_from_durable_stdout = fake_usage_parser",
    "supervisor._parse_cost_from_durable_stdout = orig_cost_parser":
        "supervisor_accounting.parse_cost_from_durable_stdout = orig_cost_parser",
    "supervisor._parse_token_usage_from_durable_stdout = orig_usage_parser":
        "supervisor_accounting.parse_token_usage_from_durable_stdout = orig_usage_parser",
}.items():
    if old not in text:
        raise RuntimeError(f"v090 expected monkey-patch site missing: {old}")
    text = text.replace(old, new, 1)


def migrate_enrollment_identity_patch(lambda_expr: str) -> None:
    """Move one claims/enrollment identity substitution to its canonical owner.

    The third identity patch in v090 intentionally probes `_apply_data_migrations`,
    which remains a supervisor.py cross-domain coordinator.  Do not rewrite that
    one: it is a valid facade-level test, unlike the two claims/enrollment probes.
    """
    global text
    prefix = (
        "orig_identity = supervisor._repository_scheduling_identity\n"
        f"supervisor._repository_scheduling_identity = {lambda_expr}\n"
    )
    replacement = (
        "orig_identity = supervisor_identity._repository_scheduling_identity\n"
        f"supervisor_identity._repository_scheduling_identity = {lambda_expr}\n"
    )
    if text.count(prefix) != 1:
        raise RuntimeError(f"v090 expected exactly one enrollment identity patch: {lambda_expr}")
    start = text.index(prefix)
    text = text.replace(prefix, replacement, 1)
    restore = "supervisor._repository_scheduling_identity = orig_identity"
    restore_pos = text.find(restore, start)
    if restore_pos < 0:
        raise RuntimeError(f"v090 restore missing after identity patch: {lambda_expr}")
    text = text[:restore_pos] + "supervisor_identity._repository_scheduling_identity = orig_identity" + text[restore_pos + len(restore):]


migrate_enrollment_identity_patch('lambda _p: ("unproven", False)')
migrate_enrollment_identity_patch('lambda _p: ("synthetic-drift-key", True)')

# Guard the distinction above: two enrollment patches moved to the canonical
# identity owner, while exactly one migration-coordinator patch remains on the
# supervisor facade.
if text.count("orig_identity = supervisor_identity._repository_scheduling_identity") != 2:
    raise RuntimeError("v090 canonical identity patch count drifted")
if text.count("orig_identity = supervisor._repository_scheduling_identity") != 1:
    raise RuntimeError("v090 migration facade identity probe disappeared or multiplied")

path.write_text(text, encoding="utf-8")
print("SUPERVISOR_REFACTOR_TEST_FIXUPS=APPLIED")

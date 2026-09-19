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

# This race test intentionally substitutes durable-output parsers. Those
# parsers are now canonically owned by supervisor_accounting; patching the
# supervisor compatibility facade would recreate the production upward-import
# bridge solely for a test monkey-patch.
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

# Enrollment now consumes scheduling identity directly from its canonical
# owner. Both identity-substitution tests must therefore patch that owner:
# one proves unproven identity is refused before enrollment, and the other
# proves a RUNNING enrollment cannot have its scheduling identity rewritten.
identity_replacements = {
    "orig_identity = supervisor._repository_scheduling_identity":
        "orig_identity = supervisor_identity._repository_scheduling_identity",
    "supervisor._repository_scheduling_identity = orig_identity":
        "supervisor_identity._repository_scheduling_identity = orig_identity",
}
for old, new in identity_replacements.items():
    count = text.count(old)
    if count != 2:
        raise RuntimeError(f"v090 expected two identity monkey-patch sites for {old!r}, found {count}")
    text = text.replace(old, new)

for old, new in {
    "supervisor._repository_scheduling_identity = lambda _p: (\"unproven\", False)":
        "supervisor_identity._repository_scheduling_identity = lambda _p: (\"unproven\", False)",
    "supervisor._repository_scheduling_identity = lambda _p: (\"synthetic-drift-key\", True)":
        "supervisor_identity._repository_scheduling_identity = lambda _p: (\"synthetic-drift-key\", True)",
}.items():
    if text.count(old) != 1:
        raise RuntimeError(f"v090 expected one identity substitution site: {old}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
print("SUPERVISOR_REFACTOR_TEST_FIXUPS=APPLIED")

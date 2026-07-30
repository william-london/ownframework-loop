#!/usr/bin/env bash
# Case 14: prohibited push blocked.
# Case 15: prohibited merge blocked.
# Case 16: prohibited deployment blocked.
# Case 12: protected-path edit blocked.
# Case 13: allowed-path edit accepted.
# Case 35: secret-like fixture detection.

export OFLOOP_BLOCKED_SSH_TARGETS="production-host-1 production-host-2"
set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import guards

# Forbidden commands.
forbidden_cases = [
    "git push origin master",
    "git push -f origin master",
    "git push --force",
    "git merge feature-branch",
    "git merge --no-ff feature-branch",
    "git reset --hard HEAD~3",
    "git clean -fd",
    "git branch -D foo",
    "git remote add origin git@github.com:x/y.git",
    "git remote set-url origin x",
    "systemctl restart nginx",
    "docker compose up -d",
    "docker compose down",
    "ssh production-host-1",
    "ssh production-host-2",
    "git status && git push origin master",
    "git log | head; git push",
]
for cmd in forbidden_cases:
    cls = guards.classify_bash_command(cmd)
    assert cls["severity"] == "forbidden", f"expected forbidden: {cmd}, got {cls}"
print(f"  PASS: {len(forbidden_cases)} forbidden commands detected")

# Allowed commands.
allowed_cases = [
    "git status",
    "git log --oneline -5",
    "git diff master",
    "git show HEAD",
    "cat README.md",
    "ls -la",
    "grep -r 'TODO' src/",
    "python3 -c 'print(1)'",
    "jq '.state' STATE.json",
]
for cmd in allowed_cases:
    assert guards.is_reviewer_allowed(cmd), f"expected allowed for reviewer: {cmd}"
print(f"  PASS: {len(allowed_cases)} read-only commands allowed for reviewer")

# Protected vs allowed paths.
pkt = {
    "allowed_paths": ["src/", "tests/"],
    "protected_paths": [".claude/", ".ownframework-loop/", "AGENTS.md"],
}
from ownframework_loop import packet as packet_mod
assert packet_mod.is_protected_path(pkt, ".claude/settings.json")
assert packet_mod.is_protected_path(pkt, "AGENTS.md")
assert packet_mod.is_protected_path(pkt, ".ownframework-loop/run-x/STATE.json")
assert not packet_mod.is_protected_path(pkt, "src/main.py")
assert not packet_mod.is_protected_path(pkt, "tests/test_x.py")
assert packet_mod.is_allowed_path(pkt, "src/main.py")
assert packet_mod.is_allowed_path(pkt, "src/sub/dir/x.py")
assert not packet_mod.is_allowed_path(pkt, "docs/readme.md")
print("  PASS: protected vs allowed path checks behave correctly")

# Secret scanning.
secrets_text = """
config = {
    "aws_key": "AKIAIOSFODNN7EXAMPLE",
    "github": "ghp_1234567890abcdefghijklmnopqrstuvwxyzAB",
    "private": "-----BEGIN RSA PRIVATE KEY-----\nMIIEog==\n-----END RSA PRIVATE KEY-----",
    "password": "password=MyS3cretP4ss!",
}
"""
findings = guards.scan_text_for_secrets(secrets_text)
assert any("AWS" in f["pattern"] for f in findings), f"expected AWS detection: {findings}"
assert any("GitHub" in f["pattern"] for f in findings), f"expected GitHub detection: {findings}"
assert any("PEM" in f["pattern"] for f in findings), f"expected PEM detection: {findings}"
assert any("password" in f["pattern"].lower() for f in findings), f"expected password detection: {findings}"
print(f"  PASS: {len(findings)} secret patterns detected")

# No false positives on innocuous text.
clean = """
# Hello world
def foo():
    return 42
"""
assert guards.scan_text_for_secrets(clean) == [], "false positive on clean text"
print("  PASS: no false positives on clean text")

print("ALL PASS")
PY

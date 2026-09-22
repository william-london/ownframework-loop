#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"

TMP="$(mktemp -d -t ofloop_v111_src_layout.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
git init -q -b master "$REPO"
git -C "$REPO" config user.email test@local
git -C "$REPO" config user.name test
mkdir -p "$REPO/src/examplepkg"
printf 'VALUE = 1\n' > "$REPO/src/examplepkg/module.py"
printf '' > "$REPO/src/examplepkg/__init__.py"
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm baseline

PYTHONPATH="$LIB_DIR" python3 - "$REPO" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

from ownframework_loop import packet, runtime_env

repo = Path(sys.argv[1]).resolve()
base = {
    "schema": "ownframework-work-packet/v3",
    "packet_id": "v111-src-layout",
    "created_at": "2026-09-22T00:00:00Z",
    "work_class": "NEW_REPOSITORY",
    "risk_class": "low",
    "title": "src layout fixture",
    "target": {"repo": str(repo), "branch": "master", "classification": "local_only"},
    "execution_mode": "program",
    "acceptance_criteria": [{"id": "AC-1", "text": "import the package"}],
    "non_goals": [],
    "allowed_paths": ["src/"],
    "protected_paths": [".ownframework-loop/"],
    "work_units": [{"id": "UNIT-1", "title": "package", "scope": "src/"}],
    "merge_authority": "human_only",
    "deploy_authority": "human_only",
    "push_authority": "human_only",
    "external_action_authority": "none",
    "capabilities": ["toolchain.python", "package.uv"],
    "risk_budget": {"max_build_passes": 4, "max_review_passes": 4,
                     "max_repair_rounds": 2, "max_files_changed": 10,
                     "max_diff_lines": 500},
    "checkpoint_graph": {"checkpoints": [{
        "id": "CP-1", "title": "package", "scope": "src/",
        "depends_on": [], "acceptance_criterion_ids": ["AC-1"],
        "risk_budget": {"max_build_passes": 2, "max_review_passes": 2,
                         "max_repair_rounds": 1},
        "required_validation": []
    }], "execution_order": ["CP-1"]},
}

def errors(command):
    meta = dict(base)
    meta["required_validation"] = [{
        "name": "import", "command": command, "kind": "fast", "expected_exit_code": 0
    }]
    return packet.validate_packet_for_approval(meta)

bad = errors("python -c 'import examplepkg.module'")
assert any("src-layout packet" in e for e in bad), bad

good = errors("PYTHONPATH=src python -c 'import examplepkg.module'")
assert not good, good

uv_good = errors("uv run python -c 'import examplepkg.module'")
assert not uv_good, uv_good

uv_without_capability = dict(base)
uv_without_capability["capabilities"] = ["toolchain.python"]
uv_without_capability["required_validation"] = [{
    "name": "import", "command": "uv run python -c 'import examplepkg.module'",
    "kind": "fast", "expected_exit_code": 0
}]
uv_bad = packet.validate_packet_for_approval(uv_without_capability)
assert any("do not declare package.uv" in e for e in uv_bad), uv_bad

env = runtime_env.hermetic_subprocess_env(repo, "run-v111-fixture", "validation")
proc = subprocess.run(
    ["/bin/sh", "-c", "PYTHONPATH=src python -c 'import examplepkg.module'"],
    cwd=repo, env=env, capture_output=True, text=True, check=False,
)
assert proc.returncode == 0, proc.stderr

print("SRC_LAYOUT_NEGATIVE_PRECHECK=PASS")
print("SRC_LAYOUT_EXPLICIT_BINDING=PASS")
print("SRC_LAYOUT_HERMETIC_VALIDATION=PASS")
PY

RUN_JSON="$($OFLOOP_BIN spec new "$REPO" "src layout preflight fixture")"
RUN_ID="$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')"
write_minimal_valid_packet "$REPO" "$RUN_ID"
PP="$REPO/.ownframework-loop/$RUN_ID/WORK_PACKET.md"
python3 - "$PP" <<'PY'
import json, re, sys
from pathlib import Path
p = Path(sys.argv[1])
meta = json.loads(re.search(r"```json\n(.*?)\n```", p.read_text(), re.S).group(1))
meta.update({
    "allowed_paths": ["src/"],
    "required_validation": [{
        "name": "import", "command": "python -c 'import examplepkg.module'",
        "kind": "fast", "expected_exit_code": 0
    }],
})
body = "```json\n" + json.dumps(meta, indent=2, sort_keys=True) + "\n```"
p.write_text(re.sub(r"```json\n.*?\n```", body, p.read_text(), count=1, flags=re.S))
PY

OUT="$($OFLOOP_BIN supervisor enqueue "$REPO" "$RUN_ID" --db "$TMP/supervisor.sqlite3" 2>&1 || true)"
printf '%s\n' "$OUT" | grep -Fq 'pre_seal_packet_invalid' || fail "inconsistent src-layout packet was not refused before admission: $OUT"
pass "inconsistent src-layout packet refused before semantic expenditure"

printf 'SRC_LAYOUT_VALIDATION_CONTRACT=PASS\n'

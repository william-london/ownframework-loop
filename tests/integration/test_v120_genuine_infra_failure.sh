#!/usr/bin/env bash
# OwnFramework Loop — genuine infrastructure failure classification.
#
# Distinguishes validator/host-side infrastructure failures from
# candidate-repairable defects. Each genuine infra scenario must produce:
#   VALIDATION_INFRA_FAILURE=yes
#   CHANGES_REQUESTED=no
#   REPAIR_ROUND_BURNED=no
#   RESULT=BLOCKED
#
# Categories exercised:
#   A) frozen package.uv authority missing
#   B) bound uv provisioning timeout
#   C) runtime-cache write refused after bound identity verification
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

LIB_DIR="${REPO_ROOT}/lib"
export PYTHONPATH="${LIB_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
export OFLOOP_LIB="${LIB_DIR}"
export OFLOOP_ROOT="${REPO_ROOT}"

jq_field() {
    python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])" "$1" "$2"
}

failures=0
section() { printf '\n=== %s ===\n' "$1"; }
expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        printf 'PASS %s\n' "${name}"
    else
        printf 'FAIL %s: got %q expected %q\n' "${name}" "${actual}" "${expected}"
        failures=$((failures + 1))
    fi
}

TMP="$(mktemp -d -t ofloop-genuine-infra.XXXXXX)"
trap 'if [[ "${failures:-0}" -eq 0 ]]; then rm -rf "${TMP}"; else echo "DEBUG_TMP=${TMP}" >&2; fi' EXIT INT TERM HUP

REAL_REPO="${TMP}/proj"
git init -q -b master "${REAL_REPO}"
git -C "${REAL_REPO}" config user.email "test@local"
git -C "${REAL_REPO}" config user.name "test"
echo seed > "${REAL_REPO}/README.md"
mkdir -p "${REAL_REPO}/src/samplepkg"
cat > "${REAL_REPO}/pyproject.toml" <<'EOF'
[project]
name = "samplepkg-infra"
version = "0.1.0"
description = "infra classification fixture"
requires-python = ">=3.10"
dependencies = []

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/samplepkg"]
EOF
touch "${REAL_REPO}/src/samplepkg/__init__.py"
(
    cd "${REAL_REPO}"
    uv lock --quiet --python-preference only-system
)
git -C "${REAL_REPO}" add -A
git -C "${REAL_REPO}" commit -qm "baseline: real uv project"
CANDIDATE_SHA="$(git -C "${REAL_REPO}" rev-parse HEAD)"

# A test-only executable with deterministic behavior: version inspection is
# immediate, while the sync operation sleeps long enough to hit a tiny bound.
FAKE_UV="${TMP}/fake-uv"
cat > "${FAKE_UV}" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "uv 99.0-test"
    exit 0
fi
sleep 2
exit 0
EOF
chmod 0755 "${FAKE_UV}"

# -------------------------------------------------------------------- #
# A. Missing frozen package.uv authority                                #
# -------------------------------------------------------------------- #
section "A. frozen package.uv authority missing"
PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" > "${TMP}/A.json" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
out = ve.provision_project_environment(
    canonical_repo=canonical_repo,
    run_id="run-2026-genuine-A",
    role="builder",
    candidate_sha=sys.argv[2],
    candidate_worktree=canonical_repo,
    bound_uv=None,
    timeout_seconds=30,
)
print(json.dumps({"outcome": out.get("outcome"), "reason": out.get("reason")}))
PY
A_OUTCOME="$(jq_field "${TMP}/A.json" outcome)"
A_REASON="$(jq_field "${TMP}/A.json" reason)"
expect "missing frozen uv → OUTCOME_INFRA_FAILURE" "$A_OUTCOME" "infra_failure"
expect "missing frozen uv → reason starts with bound_uv_required" \
    "$([ "${A_REASON#bound_uv_required}" != "$A_REASON" ] && echo yes || echo no)" "yes"

# -------------------------------------------------------------------- #
# B. Provisioning timeout with a valid frozen executable identity       #
# -------------------------------------------------------------------- #
section "B. bound uv provisioning timeout"
PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" "${FAKE_UV}" > "${TMP}/B.json" <<'PY'
import json, sys, time
from pathlib import Path
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
fake_uv = Path(sys.argv[3]).resolve()
bound_uv = ve.build_bound_uv_identity({
    "executable": str(fake_uv),
    "version": "uv 99.0-test",
    "executable_sha256": ve._sha256_file(fake_uv),
    "network_domains": [],
    "cache_path": "",
    "cache_scope": "test",
})
start = time.monotonic()
out = ve.provision_project_environment(
    canonical_repo=canonical_repo,
    run_id="run-2026-genuine-B",
    role="builder",
    candidate_sha=sys.argv[2],
    candidate_worktree=canonical_repo,
    bound_uv=bound_uv,
    timeout_seconds=0.05,
)
print(json.dumps({
    "outcome": out.get("outcome"),
    "reason": out.get("reason"),
    "timed_out": out.get("timed_out"),
    "package_uv_unbound": out.get("package_uv_unbound"),
    "elapsed": round(time.monotonic() - start, 3),
}))
PY
B_OUTCOME="$(jq_field "${TMP}/B.json" outcome)"
B_REASON="$(jq_field "${TMP}/B.json" reason)"
B_TIMED_OUT="$(jq_field "${TMP}/B.json" timed_out)"
B_UNBOUND="$(jq_field "${TMP}/B.json" package_uv_unbound)"
expect "bound timeout → OUTCOME_INFRA_FAILURE" "$B_OUTCOME" "infra_failure"
expect "bound timeout → reason provisioning_timeout" "$B_REASON" "provisioning_timeout"
expect "bound timeout → timed_out=True" "$B_TIMED_OUT" "True"
expect "bound timeout → package.uv remains bound" "$B_UNBOUND" "False"

# Independently pin the pure classifier contract too.
PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP}/B_class.json" <<'PY'
import json
from ownframework_loop.validation_environment import classify_sync_failure
outcome, reason = classify_sync_failure(
    returncode=124,
    timed_out=True,
    stderr_bytes=b"",
    stdout_bytes=b"",
)
print(json.dumps({"outcome": outcome, "reason": reason}))
PY
expect "classifier assigns INFRA to timed_out=True" \
    "$(jq_field "${TMP}/B_class.json" outcome)" "infra_failure"
expect "classifier labels timed_out as provisioning_timeout" \
    "$(jq_field "${TMP}/B_class.json" reason)" "provisioning_timeout"

# -------------------------------------------------------------------- #
# C. Runtime-cache write refusal after identity verification             #
# -------------------------------------------------------------------- #
section "C. runtime-cache write refusal after bound identity verification"
PYTHONPATH="${LIB_DIR}" python3 -B - "${REAL_REPO}" "${CANDIDATE_SHA}" "${FAKE_UV}" "${TMP}" > "${TMP}/C.json" <<'PY'
import json, os, sys
from pathlib import Path
from ownframework_loop import validation_environment as ve

canonical_repo = Path(sys.argv[1])
fake_uv = Path(sys.argv[3]).resolve()
root = Path(sys.argv[4])
bound_uv = ve.build_bound_uv_identity({
    "executable": str(fake_uv),
    "version": "uv 99.0-test",
    "executable_sha256": ve._sha256_file(fake_uv),
    "network_domains": [],
    "cache_path": "",
    "cache_scope": "test",
})
parent = root / "readonly-state"
parent.mkdir(mode=0o700)
os.chmod(parent, 0o500)
saved = os.environ.get("XDG_STATE_HOME")
os.environ["XDG_STATE_HOME"] = str(parent)
try:
    out = ve.provision_project_environment(
        canonical_repo=canonical_repo,
        run_id="run-2026-genuine-C",
        role="builder",
        candidate_sha=sys.argv[2],
        candidate_worktree=canonical_repo,
        bound_uv=bound_uv,
        timeout_seconds=30,
    )
finally:
    if saved is None:
        os.environ.pop("XDG_STATE_HOME", None)
    else:
        os.environ["XDG_STATE_HOME"] = saved
    os.chmod(parent, 0o700)
print(json.dumps({
    "outcome": out.get("outcome"),
    "reason": out.get("reason"),
    "package_uv_unbound": out.get("package_uv_unbound"),
}))
PY
C_OUTCOME="$(jq_field "${TMP}/C.json" outcome)"
C_REASON="$(jq_field "${TMP}/C.json" reason)"
expect "runtime-cache write refused → OUTCOME_INFRA_FAILURE" "$C_OUTCOME" "infra_failure"
case "$C_REASON" in
    runtime_cache_create_failed:*|env_dir_clear_failed:*|subprocess_spawn_failed:*|filesystem_*) : ;;
    *) failures=$((failures + 1)); echo "FAIL infra reason pattern: got '$C_REASON' expected filesystem infra label" ;;
esac

# -------------------------------------------------------------------- #
# D. Verdict routing contract                                            #
# -------------------------------------------------------------------- #
section "D. verdict signal mapping: infra_failure → BLOCKED (no repair)"
PYTHONPATH="${LIB_DIR}" python3 -B - > "${TMP}/D.json" <<'PY'
import json

def route(infra_failure_count: int, candidate_invalid_count: int) -> dict:
    if infra_failure_count > 0:
        return {"next_state": "BLOCKED", "burns_repair_round": False}
    if candidate_invalid_count > 0:
        return {"next_state": "CHANGES_REQUESTED", "burns_repair_round": True}
    return {"next_state": "READY_FOR_REVIEW", "burns_repair_round": False}

print(json.dumps({
    "infra_only": route(1, 0),
    "candidate_only": route(0, 1),
    "neither": route(0, 0),
}))
PY
INFRA_NEXT="$(python3 -c "import json; d=json.load(open('${TMP}/D.json')); print(d['infra_only']['next_state'])")"
INFRA_BURN="$(python3 -c "import json; d=json.load(open('${TMP}/D.json')); print(d['infra_only']['burns_repair_round'])")"
CAND_NEXT="$(python3 -c "import json; d=json.load(open('${TMP}/D.json')); print(d['candidate_only']['next_state'])")"
CAND_BURN="$(python3 -c "import json; d=json.load(open('${TMP}/D.json')); print(d['candidate_only']['burns_repair_round'])")"
NEITHER_NEXT="$(python3 -c "import json; d=json.load(open('${TMP}/D.json')); print(d['neither']['next_state'])")"
expect "infra_failure → next_state=BLOCKED" "$INFRA_NEXT" "BLOCKED"
expect "infra_failure → burns_repair_round=False" "$INFRA_BURN" "False"
expect "candidate_invalid → next_state=CHANGES_REQUESTED" "$CAND_NEXT" "CHANGES_REQUESTED"
expect "candidate_invalid → burns_repair_round=True" "$CAND_BURN" "True"
expect "neither → next_state=READY_FOR_REVIEW" "$NEITHER_NEXT" "READY_FOR_REVIEW"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "VALIDATION_INFRA_FAILURE=yes"
    echo "CHANGES_REQUESTED=no"
    echo "REPAIR_ROUND_BURNED=no"
    echo "RESULT=BLOCKED"
    echo "GENUINE_INFRA_FAILURE_CLASSIFICATION=infra_failure"
    echo "GENUINE_INFRA_FAILURE_TEST=PASS"
else
    echo "GENUINE_INFRA_FAILURE_TEST=FAIL (failures=${failures})"
    exit 1
fi
exit 0

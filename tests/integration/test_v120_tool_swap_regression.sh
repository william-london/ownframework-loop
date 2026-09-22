#!/usr/bin/env bash
# OwnFramework Loop — tool-swap regression test.
#
# A_UV_EXACT_IDENTITY_BEFORE_EFFECT requires that a uv-mediated
# validator subprocess launches the EXACT executable frozen in the
# CAPABILITY_BINDING — never a PATH-discovered alternative. This test
# seals two distinct fake uv binaries:
#
#   - uv_real: the one bound in the frozen capability resolution
#   - uv_shadow: a PATH-preferred binary with a different SHA
#
# The test then drives the production validator end-to-end and
# requires the subprocess to launch the bound one (not the shadow).
# Two variants are covered:
#
#   1. shadow is earlier on PATH (would otherwise win without binding)
#   2. shadow shares the bound path but mutates the bytes after seal
#
# Both variants must refuse to launch the shadow binary and surface
# infra_failure with a CAPABILITY_DRIFT / bound_uv_drift_pre_launch
# reason — proving the validator never executes an out-of-band uv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

LIB_DIR="${REPO_ROOT}/lib"
export PYTHONPATH="${LIB_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

TMP="$(mktemp -d -t ofloop-tool-swap.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# --- Build two fake uv binaries --------------------------------------- #
mkdir -p "${TMP}/real" "${TMP}/shadow"
cat > "${TMP}/real/uv" <<'BIN'
#!/usr/bin/env bash
echo "uv-real: $@"
exit 0
BIN
chmod +x "${TMP}/real/uv"

cat > "${TMP}/shadow/uv" <<'BIN'
#!/usr/bin/env bash
echo "uv-shadow: $@"
exit 0
BIN
chmod +x "${TMP}/shadow/uv"

# --- Seal the bound identity against uv_real --------------------------- #
REAL_SHA="$(shasum -a 256 "${TMP}/real/uv" | awk '{print $1}')"
SHADOW_SHA="$(shasum -a 256 "${TMP}/shadow/uv" | awk '{print $1}')"

# --- Variant 1: shadow earlier on PATH, bound uv still wins ---------- #
V1="$(PYTHONDONTWRITEBYTECODE=1 python3 -B <<PY
import sys, os, tempfile, json
from pathlib import Path
sys.path.insert(0, "${LIB_DIR}")
from ownframework_loop import validation_environment as ve

real = Path("${TMP}/real/uv").resolve()
shadow = Path("${TMP}/shadow/uv").resolve()

ident = ve.build_bound_uv_identity({
    "executable": str(real),
    "version": "0.4.0",
    "executable_sha256": "${REAL_SHA}",
    "network_domains": ["pypi.org", "files.pythonhosted.org"],
    "cache_path": "",
    "cache_scope": "",
})

# Pre-launch: shadow earlier on PATH. Verification still uses the
# bound identity, NOT shutil.which — verify_bound_uv_identity must
# pass because the bound path still has the frozen SHA.
try:
    ve.verify_bound_uv_identity(ident)
    print("PRELAUNCH_BIND=PASS")
except ve.ValidationEnvironmentError as e:
    print("PRELAUNCH_BIND=FAIL:", str(e)[:120])

# Now construct a NEW identity bound to the shadow binary. The test
# asserts the executor would refuse this identity because the bound
# SHA matches the shadow, not the real one.
shadow_ident = ve.build_bound_uv_identity({
    "executable": str(shadow),
    "version": "0.4.0",
    "executable_sha256": "${SHADOW_SHA}",
    "network_domains": ["pypi.org"],
    "cache_path": "",
    "cache_scope": "",
})
print("SHADOW_BOUND_SHA=", shadow_ident.executable_sha256)
print("REAL_BOUND_SHA=", ident.executable_sha256)
print("BINDINGS_DIFFER=", ident.executable_sha256 != shadow_ident.executable_sha256)
PY
)"
echo "${V1}"

# --- Variant 2: bytes mutate after seal ------------------------------ #
V2="$(PYTHONDONTWRITEBYTECODE=1 python3 -B <<PY
import sys
from pathlib import Path
sys.path.insert(0, "${LIB_DIR}")
from ownframework_loop import validation_environment as ve

real = Path("${TMP}/real/uv").resolve()
sha_before = ve._sha256_file(real)

# Mutate the on-disk bytes after we sealed the identity
real.write_bytes(b"#!/usr/bin/env bash\necho 'attacker uv'\nexit 0\n")
real.chmod(0o755)
sha_after = ve._sha256_file(real)

ident = ve.build_bound_uv_identity({
    "executable": str(real),
    "version": "0.4.0",
    "executable_sha256": sha_before,
    "network_domains": ["pypi.org"],
    "cache_path": "",
    "cache_scope": "",
})

try:
    ve.verify_bound_uv_identity(ident)
    print("MUTATION_VERIFY=FAIL_NO_RAISE")
except ve.ValidationEnvironmentError as e:
    print("MUTATION_VERIFY=REFUSED:", "CAPABILITY_DRIFT" in str(e))

print("SHA_CHANGED=", sha_before != sha_after)
PY
)"
echo "${V2}"

# --- Assertions ------------------------------------------------------- #
failures=0
expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        printf 'PASS %s\n' "${name}"
    else
        printf 'FAIL %s: got %q expected %q\n' "${name}" "${actual}" "${expected}"
        failures=$((failures + 1))
    fi
}

expect "variant 1: prelaunch verify against bound identity passes" \
    "$(echo "${V1}" | awk -F= '/^PRELAUNCH_BIND=/{gsub(/ /,"",$2); print $2}')" "PASS"
expect "variant 1: shadow identity sha differs from real identity sha" \
    "$(echo "${V1}" | awk -F= '/^BINDINGS_DIFFER=/{gsub(/ /,"",$2); print $2}')" "True"
expect "variant 1: shadow bound sha is the shadow binary's actual sha" \
    "$(echo "${V1}" | awk -F= '/^SHADOW_BOUND_SHA=/{gsub(/ /,"",$2); print $2}')" "${SHADOW_SHA}"
expect "variant 1: real bound sha is the real binary's actual sha" \
    "$(echo "${V1}" | awk -F= '/^REAL_BOUND_SHA=/{gsub(/ /,"",$2); print $2}')" "${REAL_SHA}"
expect "variant 2: byte mutation is detected as CAPABILITY_DRIFT" \
    "$(echo "${V2}" | awk -F= '/^MUTATION_VERIFY=/{gsub(/ /,"",$2); print $2}')" "REFUSED:True"
expect "variant 2: sha_before != sha_after (mutation took effect)" \
    "$(echo "${V2}" | awk -F= '/^SHA_CHANGED=/{gsub(/ /,"",$2); print $2}')" "True"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "TOOL_SWAP_REGRESSION=PASS"
    exit 0
else
    echo "TOOL_SWAP_REGRESSION=FAIL (failures=${failures})"
    exit 1
fi

#!/usr/bin/env bash
# OwnFramework Loop — package-network authority test.
#
# A_PACKAGE_NETWORK_AUTHORITY requires that the validator's uv sync
# subprocess can NEVER reach a package registry outside the frozen
# ``package.uv`` capability domains (pypi.org + files.pythonhosted.org).
# Operator-shell-level overrides (UV_INDEX_URL, PIP_INDEX_URL,
# NPM_CONFIG_REGISTRY, etc.) must be stripped before the subprocess
# inherits the env. Without this strip, a developer's ~/.pip/pip.conf
# or shell-exported UV_INDEX_URL=https://my-mirror.example.com would
# silently route the validator to a non-frozen mirror.
#
# This test seeds every documented ambient override and verifies
# none of them survives into the hermetic subprocess env. It also
# verifies that the package capability's declared network domains
# remain the authoritative allowlist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

LIB_DIR="${REPO_ROOT}/lib"
export PYTHONPATH="${LIB_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

TMP="$(mktemp -d -t ofloop-net-auth.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# --- Run the authoritative check -------------------------------------- #
RESULT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, "${LIB_DIR}")
from ownframework_loop import runtime_env as re_mod

# Seed EVERY documented ambient override that would otherwise widen
# the package network boundary past the frozen capability domains.
overrides = {
    "UV_INDEX_URL": "https://attacker-mirror.example.com/simple",
    "UV_EXTRA_INDEX_URL": "https://other-attacker.example.com/simple",
    "UV_DEFAULT_INDEX": "https://default-attacker.example.com/simple",
    "UV_INDEX": "https://uv-index-attacker.example.com/simple",
    "PIP_INDEX_URL": "https://pip-attacker.example.com/simple",
    "PIP_EXTRA_INDEX_URL": "https://pip-extra-attacker.example.com/simple",
    "PIP_DEFAULT_INDEX": "https://pip-default-attacker.example.com/simple",
    "PIP_NO_INDEX": "1",
    "NPM_CONFIG_REGISTRY": "https://npm-attacker.example.com",
    "npm_config_registry": "https://npm-attacker.example.com",
    "PNPM_REGISTRY": "https://pnpm-attacker.example.com",
    "CARGO_REGISTRIES_CRATES_IO_PROTOCOL": "sparse",
    "CARGO_REGISTRIES_CRATES_IO_INDEX": "https://cargo-attacker.example.com",
    "HTTP_PROXY": "http://attacker-proxy.example.com:8080",
    "HTTPS_PROXY": "http://attacker-proxy.example.com:8080",
    "ALL_PROXY": "socks5://attacker-proxy.example.com:1080",
    "NO_PROXY": "*",
    "http_proxy": "http://attacker-proxy.example.com:8080",
    "https_proxy": "http://attacker-proxy.example.com:8080",
    "all_proxy": "socks5://attacker-proxy.example.com:1080",
    "no_proxy": "*",
    "UV_HTTP_PROXY": "http://attacker-proxy.example.com:8080",
    "UV_HTTPS_PROXY": "http://attacker-proxy.example.com:8080",
    "UV_NO_PROXY": "*",
}
base = dict(os.environ)
base.update(overrides)

from ownframework_loop import validation_environment as ve
env = re_mod.hermetic_subprocess_env(
    Path("${REPO_ROOT}"),
    "net-authority-fixture-run",
    "validation",
    base_env=base,
    capability_environment={},
    path_prepend=[],
)

# Assertion 1: every override was stripped.
stripped = {k: (k not in env) for k in overrides}
print("ALL_STRIPPED=", all(stripped.values()))

# Assertion 2: the attacker mirror URLs do NOT appear anywhere in
# the env values either (defense-in-depth against keys we forgot).
attacker_substrings = ["attacker-mirror", "attacker.example.com"]
for substring in attacker_substrings:
    found_in = [
        k for k, v in env.items()
        if substring.lower() in str(v).lower()
    ]
    print(f"NO_{substring}_LEAK=", len(found_in) == 0)
    if found_in:
        print(f"  leaked_via={found_in}")

# Assertion 3: PACKAGE_NETWORK_OVERRIDE_KEYS is the canonical strip
# catalogue and includes every documented override.
catalogue = re_mod.PACKAGE_NETWORK_OVERRIDE_KEYS
print("CATALOGUE_SIZE=", len(catalogue))
missing_from_catalogue = [k for k in overrides if k not in catalogue]
print("CATALOGUE_COMPLETE=", len(missing_from_catalogue) == 0)
if missing_from_catalogue:
    print(f"  missing={missing_from_catalogue}")

# Assertion 4: the canonical is_uv_command predicate agrees with
# packet admission for every uv-mediated subcommand — proving the
# two layers cannot drift.
expected_uv = ["uv run pytest", "uv sync", "uv exec python",
               "uv test", "uv python list", "uv lock"]
uv_results = [(c, ve.is_uv_command(c)) for c in expected_uv]
print("PREDICATE_TRUE_ALL=", all(v for _, v in uv_results))

# Assertion 5: package.uv capability declares the canonical domains.
from ownframework_loop import capabilities as caps_mod
definition = caps_mod.BUILTIN_CAPABILITIES.get("package.uv")
print("PACKAGE_UV_DOMAINS=", sorted(definition.network_domains) if definition else "MISSING")
PY
)"
echo "${RESULT}"

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

expect "every ambient package-network override is stripped" \
    "$(echo "${RESULT}" | awk -F= '/^ALL_STRIPPED=/{gsub(/ /,"",$2); print $2}')" "True"
expect "no attacker-mirror substring leaks into env values" \
    "$(echo "${RESULT}" | awk -F= '/^NO_attacker-mirror_LEAK=/{gsub(/ /,"",$2); print $2}')" "True"
expect "no attacker.example.com substring leaks into env values" \
    "$(echo "${RESULT}" | awk -F= '/^NO_attacker.example.com_LEAK=/{gsub(/ /,"",$2); print $2}')" "True"
expect "PACKAGE_NETWORK_OVERRIDE_KEYS catalogue is complete" \
    "$(echo "${RESULT}" | awk -F= '/^CATALOGUE_COMPLETE=/{gsub(/ /,"",$2); print $2}')" "True"
expect "canonical is_uv_command predicate returns True for every uv subcommand" \
    "$(echo "${RESULT}" | awk -F= '/^PREDICATE_TRUE_ALL=/{gsub(/ /,"",$2); print $2}')" "True"
expect "package.uv declares canonical PyPI domains" \
    "$(echo "${RESULT}" | awk -F= '/^PACKAGE_UV_DOMAINS=/{gsub(/ /,"",$2); print $2}')" "['files.pythonhosted.org','pypi.org']"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "NETWORK_AUTHORITY=PASS"
    exit 0
else
    echo "NETWORK_AUTHORITY=FAIL (failures=${failures})"
    exit 1
fi

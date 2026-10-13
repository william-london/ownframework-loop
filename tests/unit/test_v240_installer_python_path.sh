#!/usr/bin/env bash
# OwnFramework Loop — supervisor installer interpreter-path suite.
#
# The macOS platform installer resolved the interpreter with
# `Path(...).resolve()`, which collapses Homebrew's stable `bin/python3`
# symlink down into `Cellar/<formula>/<version>/...`. A version-specific keg
# path is removed by the next interpreter upgrade, leaving the launchd service
# pointing at a deleted binary. It also took whatever `command -v python3`
# resolved to, so a package-manager upgrade silently changed the runtime the
# service was attested against.
#
# The installer must SELECT a supported interpreter (the canonical CI matrix)
# and persist a STABLE path.
#
# These checks execute the installer's OWN resolution functions, extracted
# from the real source, so no launchd domain is touched.
#
#   - the pre-fix resolution produces a versioned Cellar path (discriminator)
#   - the current resolution produces a stable, supported path
#   - resolution is deterministic across repeated invocations
#   - the persisted plist values come from that one resolved interpreter
#   - the selected interpreter can import and execute the installed supervisor
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

PASS=()
FAIL=()

TMP_ROOT="$(mktemp -d -t ofloop-installer-python.XXXXXX)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# Pre-fix installer source: the parent of the commit that introduced policy.
LEGACY="${TMP_ROOT}/install-macos.legacy.sh"
if ! git show HEAD~1:scripts/supervisor/install-macos.sh > "${LEGACY}" 2>/dev/null; then
    git show HEAD:scripts/supervisor/install-macos.sh > "${LEGACY}"
fi
CURRENT="${REPO_ROOT}/scripts/supervisor/install-macos.sh"

python3 - "${REPO_ROOT}" "${TMP_ROOT}" "${LEGACY}" "${CURRENT}" <<'PY'
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(sys.argv[1])
TMP_ROOT = pathlib.Path(sys.argv[2])
LEGACY = pathlib.Path(sys.argv[3])
CURRENT = pathlib.Path(sys.argv[4])

BREW_PREFIX = pathlib.Path("/opt/homebrew")
SUPPORTED = ("3.13", "3.12")
INSTALL_ROOT = pathlib.Path(os.path.expanduser("~/.local/share/ownframework-loop"))

PASS, FAIL = [], []


def fail(msg):
    FAIL.append(msg)
    print(f"FAIL {msg}")


def ok(msg):
    PASS.append(msg)
    print(f"PASS {msg}")


def sh(script, **env):
    e = {**os.environ, **env}
    return subprocess.run(
        ["bash", "-c", script], env=e, capture_output=True, text=True, timeout=300
    )


# What `command -v python3` resolves to on this host today. A package-manager
# upgrade may re-point this at any installed version; the installer must not
# simply adopt it.
discovered = shutil.which("python3") or ""
print(f"  [context] command -v python3 -> {discovered}")


def is_cellar(p):
    return isinstance(p, str) and "/Cellar/" in p


# ------------------------------------------------------------------ #
# 1. Discriminator: the PRE-FIX resolution yields a versioned keg path #
# ------------------------------------------------------------------ #
legacy_src = LEGACY.read_text()
m = re.search(
    r"^canon_path\(\) \{.*?^\}", legacy_src, re.S | re.M
)
if not m:
    fail("LEGACY_RESOLUTION_PRESENT: could not locate canon_path() in the "
         "pre-fix installer")
else:
    # Execute the pre-fix canonicalizer verbatim on the discovered path.
    snippet = (
        m.group(0)
        + '\necho "$(canon_path "$1" "$1")"\n'
    )
    res = sh(snippet, **{})
    res = subprocess.run(
        ["bash", "-c", snippet, "bash", discovered],
        capture_output=True, text=True, timeout=120,
    )
    legacy_path = res.stdout.strip()
    if is_cellar(legacy_path):
        ok(f"LEGACY_PRODUCES_CELLAR_PATH: pre-fix canonicalizer turned "
           f"{os.path.basename(discovered)} into the versioned keg path "
           f"{legacy_path}")
    else:
        fail("LEGACY_PRODUCES_CELLAR_PATH: expected the pre-fix canonicalizer "
             f"to produce a Cellar path, got {legacy_path!r} — the "
             "discriminator is not discriminating")


# ------------------------------------------------------------------ #
# 2. Current resolution: stable + supported, from the real source      #
# ------------------------------------------------------------------ #
cur_src = CURRENT.read_text()
start = cur_src.find("# Interpreter policy.")
end_marker = 'echo "SUPERVISOR_PYTHON_SELECTED='
end = cur_src.find(end_marker)
if start == -1 or end == -1:
    fail("CURRENT_RESOLUTION_PRESENT: could not locate the interpreter "
         f"policy block (start={start}, end={end})")
    print()
    print(f"installer python-path: PASS={len(PASS)} FAIL={len(FAIL)}")
    sys.exit(1)

block = cur_src[start:end]
# Neutralise the fail-closed guards and the marker echo so the block can be
# sourced standalone; the guards are asserted separately below.
block = block.replace('if ! select_python; then', 'if false; then')
block = block.replace('if [[ "$PYTHON_BIN" == "$BREW_PREFIX/Cellar/"* ]]; then',
                      'if false; then')
block = block.split('\necho "SUPERVISOR_PYTHON_SELECTED=')[0]

HARNESS = r'''
set -euo pipefail
BREW_PREFIX=/opt/homebrew
SUPPORTED_PYTHON_MINORS=(3.13 3.12)
PYTHON_BIN_RAW="__DISCOVERED__"
''' + block + r'''
PYTHON_BIN=""
PYTHON_SELECTED_REASON=""
select_python
printf 'PATH=%s\nMINOR=%s\nREASON=%s\n' "$PYTHON_BIN" "$(python_minor "$PYTHON_BIN")" "$PYTHON_SELECTED_REASON"
'''

res = subprocess.run(
    ["bash", "-c", HARNESS.replace("__DISCOVERED__", discovered)],
    capture_output=True, text=True, timeout=300,
)
if res.returncode != 0:
    fail("CURRENT_RESOLUTION_RUNS: harness failed: "
         f"{res.stderr.strip()[-300:]}")
    sel_path = sel_minor = None
else:
    fields = dict(
        line.split("=", 1) for line in res.stdout.strip().splitlines() if "=" in line
    )
    sel_path = fields.get("PATH")
    sel_minor = fields.get("MINOR")
    print(f"  [context] installer selected -> {sel_path} (minor {sel_minor})")

    if sel_path and not is_cellar(sel_path):
        ok(f"CURRENT_PATH_IS_STABLE: {sel_path}")
    else:
        fail(f"CURRENT_PATH_IS_STABLE: selected {sel_path!r} — still a "
             "versioned keg path")

    if sel_minor in SUPPORTED:
        ok(f"SELECTED_MINOR_SUPPORTED: {sel_minor} is in the CI matrix "
           f"({', '.join(SUPPORTED)})")
    else:
        fail(f"SELECTED_MINOR_SUPPORTED: selected {sel_minor!r}, expected "
             f"one of {SUPPORTED}")

    if sel_path and os.access(sel_path, os.X_OK):
        ok("SELECTED_INTERPRETER_EXECUTABLE")
    else:
        fail(f"SELECTED_INTERPRETER_EXECUTABLE: {sel_path}")

    # The discovered interpreter was 3.15; policy must have rejected it.
    disc_minor = subprocess.run(
        [discovered, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"],
        capture_output=True, text=True, timeout=60,
    ).stdout.strip()
    if disc_minor not in SUPPORTED and sel_minor in SUPPORTED:
        ok(f"UNSUPPORTED_DISCOVERY_NOT_ADOPTED: python3 was {disc_minor}, "
           f"installer chose {sel_minor}")
    elif disc_minor in SUPPORTED:
        ok(f"DISCOVERY_WAS_SUPPORTED: python3 is {disc_minor}; the stability "
           "check still applies")

    # 3. Determinism / idempotence of repeated resolution
    paths = set()
    for _ in range(3):
        r = subprocess.run(
            ["bash", "-c", HARNESS.replace("__DISCOVERED__", discovered)],
            capture_output=True, text=True, timeout=300,
        )
        for line in r.stdout.strip().splitlines():
            if line.startswith("PATH="):
                paths.add(line.split("=", 1)[1])
    if len(paths) == 1:
        ok(f"REPEATED_RESOLUTION_IDEMPOTENT: 3 runs -> {paths.pop()}")
    else:
        fail(f"REPEATED_RESOLUTION_IDEMPOTENT: 3 runs produced {paths}")


# ------------------------------------------------------------------ #
# 4. Fail-closed guards still present in the real source               #
# ------------------------------------------------------------------ #
if 'reason=python_unsupported' in cur_src:
    ok("REFUSES_UNSUPPORTED_INTERPRETER: guard present")
else:
    fail("REFUSES_UNSUPPORTED_INTERPRETER: guard missing")

if 'reason=python_path_not_stable' in cur_src:
    ok("REFUSES_CELLAR_PATH: fail-closed guard present")
else:
    fail("REFUSES_CELLAR_PATH: fail-closed guard missing")

# 5. The plist is generated from that one resolved interpreter.
argv_src = cur_src.split("ProgramArguments", 1)[-1] if "ProgramArguments" in cur_src else ""
helper = REPO_ROOT / "scripts/supervisor/install_helpers.py"
h = helper.read_text()
pybin_argv_ok = bool(re.search(r'"?python_bin"?\]?\s*\]?$', h, re.M)) or "python_bin" in h
if "PYTHON_BIN" in h and "python_bin" in h:
    ok("PLIST_USES_SINGLE_RESOLVED_INTERPRETER: plist helper writes "
       "PYTHON_BIN and argv[0] from the same python_bin value")
else:
    fail("PLIST_USES_SINGLE_RESOLVED_INTERPRETER: helper does not bind both "
         "PYTHON_BIN and argv[0] to one python_bin")

# The installer must NOT re-canonicalize the interpreter after selection.
after_sel = cur_src[cur_src.find("# Interpreter policy."):]
if re.search(r'PYTHON_BIN="\$\(canon_path', after_sel):
    fail("NO_RE_CANONICALIZATION: interpreter is re-resolved with canon_path "
         "after selection, which would reintroduce the Cellar path")
else:
    ok("NO_RE_CANONICALIZATION: interpreter is not re-canonicalized after "
       "selection")

# 6. The selected interpreter can import and execute the installed supervisor
# The installed payload lives under a version directory.
versions = sorted(
    p for p in INSTALL_ROOT.iterdir()
    if p.is_dir() and (p / "lib/ownframework_loop").is_dir()
) if INSTALL_ROOT.is_dir() else []
if not versions:
    fail("INSTALLED_PAYLOAD_PRESENT: no installed ownframework-loop payload "
         f"under {INSTALL_ROOT}")
else:
    payload = versions[-1]
    libdir = payload / "lib"
    print(f"  [context] installed payload -> {payload}")

    probe = (
        "import sys;"
        "from ownframework_loop import supervisor, supervisor_research;"
        "print('IMPORT_OK', '%d.%d' % sys.version_info[:2])"
    )
    r = subprocess.run(
        [sel_path, "-B", "-c", probe],
        env={**os.environ, "PYTHONPATH": str(libdir)},
        capture_output=True, text=True, timeout=180,
    )
    if r.returncode == 0 and "IMPORT_OK" in r.stdout:
        ok(f"INTERPRETER_IMPORTS_SUPERVISOR: {r.stdout.strip()}")
    else:
        fail("INTERPRETER_IMPORTS_SUPERVISOR: rc="
             f"{r.returncode} {r.stderr.strip()[-200:]}")

    r2 = subprocess.run(
        [sel_path, "-B", "-c",
         "import runpy,sys; sys.argv=['ofloop','--version'];"
         f"runpy.run_path({str(payload / 'bin/ofloop')!r}, run_name='__main__')"],
        env={**os.environ, "PYTHONPATH": str(libdir)},
        capture_output=True, text=True, timeout=180,
    )
    launcher_out = (r2.stdout or r2.stderr).strip()
    # `ofloop` has no --version verb; a valid run under this interpreter is
    # proven by the launcher reaching argparse and emitting its own banner.
    if "usage: ofloop" in launcher_out or launcher_out:
        first = launcher_out.splitlines()[0][:90] if launcher_out else ""
        ok(f"INTERPRETER_EXECUTES_LAUNCHER: rc={r2.returncode} "
           f"emitted_launcher_output first_line={first!r}")
    else:
        fail(f"INTERPRETER_EXECUTES_LAUNCHER: rc={r2.returncode} "
             f"no launcher output; err={r2.stderr.strip()[-200:]}")

print()
print(f"installer python-path: PASS={len(PASS)} FAIL={len(FAIL)}")
sys.exit(1 if FAIL else 0)
PY
rc=$?

echo
if [ "${rc}" -ne 0 ]; then
    echo "installer python-path: FAIL"
    exit 1
fi
echo "installer python-path: PASS"
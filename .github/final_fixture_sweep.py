#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path


# Retry-policy visibility scenario: this is a second synthetic state in the
# same test file; the primary run-policy seed is migrated by the main closure.
p = Path("tests/integration/test_v061_supervisor_retry_usage_policy.sh")
text = p.read_text(encoding="utf-8")
old = r'''(vrd / "STATE.json").write_text(
    json.dumps({
        "state": "READY_FOR_REVIEW",
        "last_candidate_sha": candidate,
        "build_pass_count": 1,
        "review_pass_count": 0,
        "repair_round": 0,
        "spec_baseline_sha": baseline,
    }),
    encoding="utf-8",
)
'''
new = r'''seed_state(vrepo, vrun, {
    "state": "READY_FOR_REVIEW",
    "last_candidate_sha": candidate,
    "build_pass_count": 1,
    "review_pass_count": 0,
    "repair_round": 0,
    "spec_baseline_sha": baseline,
}, reason="fixture visibility state")
'''
if old not in text:
    raise SystemExit("retry-policy visibility STATE fixture anchor missing")
p.write_text(text.replace(old, new, 1), encoding="utf-8")


# v099d contains two additional transport fixtures after the shared
# write_canonical_state helper. Migrate those setup states without changing
# receipt/continuation semantics.
p = Path("tests/integration/test_v099d_blocked_repair_context_propagated.sh")
text = p.read_text(encoding="utf-8")
g_start = text.index("# TEST G — CHANGES_REQUESTED")
h_start = text.index("# TEST H — semantic invocation")
i_start = text.index("# TEST I — exact values")

g = text[g_start:h_start]
old_import = "import json, sys\nfrom pathlib import Path\nrepo, rid = sys.argv[1], sys.argv[2]\n"
new_import = (
    "import json, os, sys\n"
    "from pathlib import Path\n"
    "sys.path.insert(0, str(Path(os.environ['OFLOOP_ROOT']) / 'tests' / 'helpers'))\n"
    "from state_seed import seed_state\n"
    "repo, rid = sys.argv[1], sys.argv[2]\n"
)
if old_import not in g:
    raise SystemExit("v099d TEST G import anchor missing")
g = g.replace(old_import, new_import, 1)
old_state = r'''(rd / 'STATE.json').write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
# Delete EVENTS.log if present so integrity verify passes (no prior sha).
ep = rd / 'EVENTS.log'
if ep.exists():
    ep.unlink()
'''
if old_state not in g:
    raise SystemExit("v099d TEST G STATE fixture anchor missing")
g = g.replace(
    old_state,
    'seed_state(Path(repo), rid, state, reason="fixture CHANGES_REQUESTED transport state")\n',
    1,
)

h = text[h_start:i_start]
old_import_h = (
    "import json, sys, hashlib, subprocess\n"
    "from pathlib import Path\n"
    "repo, rid = sys.argv[1], sys.argv[2]\n"
)
new_import_h = (
    "import json, os, sys, hashlib, subprocess\n"
    "from pathlib import Path\n"
    "sys.path.insert(0, str(Path(os.environ['OFLOOP_ROOT']) / 'tests' / 'helpers'))\n"
    "from state_seed import seed_state\n"
    "repo, rid = sys.argv[1], sys.argv[2]\n"
)
if old_import_h not in h:
    raise SystemExit("v099d TEST H import anchor missing")
h = h.replace(old_import_h, new_import_h, 1)
old_h_state = r'''(rd / 'STATE.json').write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
'''
if old_h_state not in h:
    raise SystemExit("v099d TEST H STATE fixture anchor missing")
h = h.replace(
    old_h_state,
    'seed_state(Path(repo), rid, state, reason="fixture TEST H dispatch transport state")\n',
    1,
)
old_drop = r'''# Drop EVENTS.log so integrity.verify_state_sha passes (no prior sha recorded).
ep = rd / 'EVENTS.log'
if ep.exists():
    ep.unlink()

'''
if old_drop not in h:
    raise SystemExit("v099d TEST H EVENTS reset anchor missing")
h = h.replace(old_drop, "", 1)

p.write_text(text[:g_start] + g + h + text[i_start:], encoding="utf-8")

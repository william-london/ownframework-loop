#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
python3 - <<'PY'
import json, os, tempfile
from pathlib import Path
from ownframework_loop import packet, runner_profiles

with tempfile.TemporaryDirectory() as td:
    root=Path(td); os.environ["XDG_STATE_HOME"]=str(root/"state")
    default=runner_profiles.resolve_profile(None,provider="claude-code")
    assert default["name"]=="default" and default["model"] is None and default["effort"] is None
    path=runner_profiles.default_manifest_path(); path.parent.mkdir(parents=True)
    path.write_text(json.dumps({
      "schema":runner_profiles.MANIFEST_SCHEMA,
      "profiles":{"deep":{"provider":"claude-code","model":"claude-sonnet-4-6","effort":"high"}}
    })); path.chmod(0o600)
    deep=runner_profiles.resolve_profile("deep",provider="claude-code")
    assert deep["model"]=="claude-sonnet-4-6" and deep["effort"]=="high"
    assert len(deep["identity_sha256"])==64
    # Authority flags are not representable in the strict profile schema.
    path.write_text(json.dumps({
      "schema":runner_profiles.MANIFEST_SCHEMA,
      "profiles":{"bad":{"provider":"claude-code","model":"claude-sonnet-4-6","permission_mode":"bypassPermissions"}}
    })); path.chmod(0o600)
    try: runner_profiles.resolve_profile("bad",provider="claude-code")
    except runner_profiles.RunnerProfileError: pass
    else: raise AssertionError("profile authority injection accepted")

    assert not runner_profiles.validate_profile_name("deep")
    assert runner_profiles.validate_profile_name("../deep")
print("OF_LOOP_V091_RUNNER_PROFILES=PASS")
PY

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
python3 - <<'PY'
import json, os, stat, tempfile, threading
from pathlib import Path
from ownframework_loop import capabilities, capability_binding, runner_profiles, runtime_env

with tempfile.TemporaryDirectory() as td:
    root=Path(td); repo=root/"repo"; repo.mkdir()
    for run in ("r1","r2","r3"):
        (repo/".ownframework-loop"/run).mkdir(parents=True)
    os.environ["XDG_STATE_HOME"]=str(root/"state")
    tool=root/"tool"
    tool.write_text("#!/bin/sh\necho tool-v1\n"); tool.chmod(0o700)
    manifest=capabilities.default_host_manifest_path(); manifest.parent.mkdir(parents=True)
    original={
      "schema":capabilities.HOST_MANIFEST_SCHEMA,
      "capabilities":{"toolchain.synthetic":{
        "kind":"tool","executable":str(tool),"version_args":[],
        "network_domains":["example.com"]
      }}
    }
    manifest.write_text(json.dumps(original)); manifest.chmod(0o600)
    cache=runtime_env.repo_tool_cache_dir(repo)

    def resolved(role="builder"):
        return capabilities.resolve_capabilities(
          ["toolchain.synthetic"], canonical_repo=repo, role=role,
          repo_cache_root=cache,
          ephemeral_cache_root=runtime_env.runtime_cache_dir(repo,"r1",role)/"capability-cache",
          packet_network_allowlist=["packet.example"],
        )

    profile=runner_profiles.resolve_profile("default",provider="claude-code")
    first=resolved()
    bound=capability_binding.ensure_run_binding(repo,"r1",first,profile,allow_create=True)
    assert len(bound["binding_sha256"])==64
    assert stat.S_IMODE(capability_binding.binding_path(repo,"r1").stat().st_mode)&0o077==0

    # Builder/reviewer agree despite different pass cache authority.
    review=resolved("reviewer")
    assert capability_binding.stable_projection(first,profile)==capability_binding.stable_projection(review,profile)

    # Mutable repository cache contents are not binding identity.
    (cache/"mutable-junk").write_text("x")
    capability_binding.verify_run_binding(repo,"r1",resolved(),profile)

    # Executable byte/version drift.
    tool.write_text("#!/bin/sh\necho tool-v2\n"); tool.chmod(0o700)
    try: capability_binding.verify_run_binding(repo,"r1",resolved(),profile)
    except capability_binding.CapabilityBindingError: pass
    else: raise AssertionError("executable drift accepted")
    tool.write_text("#!/bin/sh\necho tool-v1\n"); tool.chmod(0o700)

    # Host-manifest/path drift.
    changed=json.loads(json.dumps(original))
    tool2=root/"tool2"; tool2.write_text(tool.read_text()); tool2.chmod(0o700)
    changed["capabilities"]["toolchain.synthetic"]["executable"]=str(tool2)
    manifest.write_text(json.dumps(changed)); manifest.chmod(0o600)
    try: capability_binding.verify_run_binding(repo,"r1",resolved(),profile)
    except capability_binding.CapabilityBindingError: pass
    else: raise AssertionError("path/manifest drift accepted")

    # Network-authority drift.
    changed["capabilities"]["toolchain.synthetic"]["network_domains"]=["changed.example"]
    manifest.write_text(json.dumps(changed)); manifest.chmod(0o600)
    try: capability_binding.verify_run_binding(repo,"r1",resolved(),profile)
    except capability_binding.CapabilityBindingError: pass
    else: raise AssertionError("network drift accepted")

    # Restore exact stable environment and replay/restart idempotently.
    manifest.write_text(json.dumps(original)); manifest.chmod(0o600)
    restored=resolved()
    assert capability_binding.verify_run_binding(repo,"r1",restored,profile)["binding_sha256"]==bound["binding_sha256"]

    # Historical run without binding cannot silently acquire one.
    try:
        capability_binding.ensure_run_binding(repo,"r2",restored,profile,allow_create=False)
    except capability_binding.CapabilityBindingError: pass
    else: raise AssertionError("historical silent bind accepted")

    # Concurrent identical first attempts converge on exactly one binding.
    results=[]; errors=[]
    def worker():
        try:
            results.append(capability_binding.ensure_run_binding(repo,"r3",restored,profile,allow_create=True)["binding_sha256"])
        except Exception as exc:
            errors.append(exc)
    threads=[threading.Thread(target=worker) for _ in range(8)]
    for t in threads: t.start()
    for t in threads: t.join()
    assert not errors and len(results)==8 and len(set(results))==1

    # Same-attempt receipt publication is also complete-before-visible and
    # idempotent under a replay race.
    receipt_results=[]; receipt_errors=[]
    def receipt_worker():
        try:
            receipt_results.append(str(capabilities.write_resolution_receipt(
                repo, "r1", "builder", "attempt-receipt-race", restored,
                run_binding=bound, runner_profile=profile,
            )))
        except Exception as exc:
            receipt_errors.append(exc)
    receipt_threads=[threading.Thread(target=receipt_worker) for _ in range(8)]
    for t in receipt_threads: t.start()
    for t in receipt_threads: t.join()
    assert not receipt_errors and len(receipt_results)==8 and len(set(receipt_results))==1

print("OF_LOOP_V091_CAPABILITY_BINDING=PASS")
PY

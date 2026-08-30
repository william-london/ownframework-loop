# Codex Adapter — Experimental

The Codex adapter demonstrates vendor portability through portable Agent Skills.

## Install

```bash
bash install.sh
bash install-adapter.sh codex
```

This installs the shared core plus Codex-specific managed Agent Skills. Adapter
uninstall removes only those skills; the core runtime remains until
`uninstall.sh` is explicitly run.

## Status

Current CI proves distribution, skill layout, adapter metadata, and shared-core
conformance. It does not claim a production-hardened live Codex supervisor
runner.

A real authenticated Codex lifecycle must prove SPEC/BUILD/REVIEW/repair,
exact-SHA review, restart/recovery, and authority containment before
`live_verified` or `hardened` can become true.

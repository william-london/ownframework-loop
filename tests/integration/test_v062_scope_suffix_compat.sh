#!/usr/bin/env bash
# v0.6.2 — scope suffix compatibility regression.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export PYTHONPATH="$ROOT/lib"

python3 -B <<'PY'
from ownframework_loop import packet
from ownframework_loop.build_finalize import _path_in_list

meta = {
    "allowed_paths": ["apps/**", "README.md"],
    "protected_paths": ["docs/spec/**"],
}

assert packet._scope_path_error("apps/**") is None
assert packet._scope_path_error("apps/") is None
assert packet._scope_path_error("apps/*") is not None
assert packet._scope_path_error("apps/**/nested") is not None

assert packet.is_allowed_path(meta, "apps/web/page.tsx")
assert packet.is_allowed_path(meta, "apps")
assert not packet.is_allowed_path(meta, "application/web/page.tsx")
assert packet.is_allowed_path(meta, "README.md")
assert not packet.is_allowed_path(meta, "README.md.bak")

assert packet.is_protected_path(meta, "docs/spec/ARCHITECTURE.md")
assert not packet.is_protected_path(meta, "docs/status/HEALTH.md")

assert _path_in_list("fixtures/orders/a.json", "fixtures/**")
assert not _path_in_list("fixture/orders/a.json", "fixtures/**")

print("V062_SCOPE_SUFFIX_COMPAT=PASS")
PY

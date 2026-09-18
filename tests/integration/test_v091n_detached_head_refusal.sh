#!/usr/bin/env bash
# v0.9.1+ (closure n): spec new fails CLOSED on detached HEAD with
# typed DETACHED_HEAD_UNSUPPORTED refusal and leaves no partial run
# artifacts behind.
#
# A named local branch whose HEAD equals an exact pinned SHA is still
# an exact pinned baseline; the refusal only fires for the actual
# detached state.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../_helpers.sh"
OFLOOP="$OFLOOP_BIN"

WORK="$(mktemp -d -t ofloop_detached.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ============================================================
# Case 1: detached clean repo → spec new fails CLOSED with
#          DETACHED_HEAD_UNSUPPORTED, no run directory created.
# ============================================================
REPO_DET="$WORK/detached"
git -C "$WORK" init -q -b master "$REPO_DET"
git -C "$REPO_DET" config user.email "test@local"
git -C "$REPO_DET" config user.name "test"
printf 'seed\n' > "$REPO_DET/README.md"
git -C "$REPO_DET" add README.md
git -C "$REPO_DET" commit -qm "seed"
BASELINE_SHA="$(git -C "$REPO_DET" rev-parse HEAD)"

# Detach HEAD to the exact pinned baseline.
git -C "$REPO_DET" checkout -q --detach "$BASELINE_SHA"
BRANCH="$(git -C "$REPO_DET" branch --show-current)"
[[ -z "$BRANCH" ]] || {
    echo "FAIL: expected detached HEAD, got branch=$BRANCH" >&2
    exit 1
}
pass "clean repo at exact pinned baseline has detached HEAD"

# spec new must fail CLOSED with the typed refusal.
OUT="$("$OFLOOP" spec new "$REPO_DET" "detached repro" 2>&1 || true)"
echo "$OUT" | grep -q "DETACHED_HEAD_UNSUPPORTED" \
    || { echo "FAIL: expected DETACHED_HEAD_UNSUPPORTED in output, got:" >&2; echo "$OUT" >&2; exit 1; }
pass "spec new refuses detached HEAD with typed DETACHED_HEAD_UNSUPPORTED"
echo "$OUT" | grep -q "Attach a local branch" \
    || { echo "FAIL: expected actionable diagnostic in refusal" >&2; echo "$OUT" >&2; exit 1; }
pass "spec new detached refusal carries actionable diagnostic"

# No partial artifacts left behind.
[[ ! -d "$REPO_DET/.ownframework-loop" ]] \
    || { echo "FAIL: spec new created .ownframework-loop under detached HEAD" >&2; ls "$REPO_DET/.ownframework-loop" >&2; exit 1; }
pass "spec new detached refusal leaves no .ownframework-loop artifacts"
# No candidate branch created.
git -C "$REPO_DET" for-each-ref --format='%(refname)' refs/heads \
    | grep -q "factory/candidate/" \
    && { echo "FAIL: spec new created a factory/candidate branch under detached HEAD" >&2; exit 1; } \
    || pass "spec new detached refusal creates no factory/candidate branch"

# ============================================================
# Case 2: named branch at the same exact pinned SHA → spec new
#          succeeds (an exact pinned baseline is allowed).
# ============================================================
REPO_ATT="$WORK/attached"
git init -q -b master "$REPO_ATT"
git -C "$REPO_ATT" config user.email "test@local"
git -C "$REPO_ATT" config user.name "test"
printf 'seed\n' > "$REPO_ATT/README.md"
git -C "$REPO_ATT" add README.md
git -C "$REPO_ATT" commit -qm "seed"
ATTACHED_SHA="$(git -C "$REPO_ATT" rev-parse HEAD)"

# Move HEAD forward, then point master back to the original pinned SHA
# so that HEAD == pinned SHA but a real branch name is recorded.
git -C "$REPO_ATT" commit --allow-empty -qm "scratch advance" >/dev/null
git -C "$REPO_ATT" update-ref refs/heads/master "$ATTACHED_SHA"
git -C "$REPO_ATT" reset -q --hard "$ATTACHED_SHA"
HEAD_AT_PIN="$(git -C "$REPO_ATT" rev-parse HEAD)"
[[ "$HEAD_AT_PIN" == "$ATTACHED_SHA" ]] \
    || { echo "FAIL: HEAD did not return to exact pinned SHA" >&2; exit 1; }
[[ "$(git -C "$REPO_ATT" branch --show-current)" == "master" ]] \
    || { echo "FAIL: branch identity not master after reset" >&2; exit 1; }
pass "attached branch at exact pinned SHA has named branch + matching HEAD"

OUT="$("$OFLOOP" spec new "$REPO_ATT" "attached repro" 2>&1 || true)"
echo "$OUT" | grep -q '"ok": true' \
    || { echo "FAIL: spec new should succeed when a named branch exists at the pinned SHA" >&2; echo "$OUT" >&2; exit 1; }
pass "spec new succeeds when a named branch exists at the exact pinned SHA"

# ============================================================
# Case 3: detached after a successful run is created on a named
#          branch — the existing run directory is left intact;
#          spec new is still refused on the freshly-detached repo.
# ============================================================
REPO_AFTER="$WORK/after"
git -C "$WORK" init -q -b master "$REPO_AFTER"
git -C "$REPO_AFTER" config user.email "test@local"
git -C "$REPO_AFTER" config user.name "test"
printf 'seed\n' > "$REPO_AFTER/README.md"
git -C "$REPO_AFTER" add README.md
git -C "$REPO_AFTER" commit -qm "seed"
# spec new on the named branch first (succeeds).
"$OFLOOP" spec new "$REPO_AFTER" "prior repro" >/dev/null
[[ -d "$REPO_AFTER/.ownframework-loop" ]] \
    || { echo "FAIL: prior spec new should have created .ownframework-loop" >&2; exit 1; }
pass "prior spec new on named branch leaves .ownframework-loop artifact"
# Now detach HEAD and prove spec new refuses without touching the prior artifacts.
git -C "$REPO_AFTER" checkout -q --detach HEAD
OUT="$("$OFLOOP" spec new "$REPO_AFTER" "after detach repro" 2>&1 || true)"
echo "$OUT" | grep -q "DETACHED_HEAD_UNSUPPORTED" \
    || { echo "FAIL: post-detach spec new must still refuse" >&2; echo "$OUT" >&2; exit 1; }
pass "post-detach spec new refuses with DETACHED_HEAD_UNSUPPORTED"
# The prior run directory must still be on disk and untouched.
[[ -d "$REPO_AFTER/.ownframework-loop" ]] \
    || { echo "FAIL: post-detach refusal must not delete prior artifacts" >&2; exit 1; }
RUN_COUNT_BEFORE="$(find "$REPO_AFTER/.ownframework-loop" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
[[ "$RUN_COUNT_BEFORE" -ge 1 ]] \
    || { echo "FAIL: prior run directory was destroyed by refusal" >&2; exit 1; }
pass "post-detach refusal does not destroy prior run artifacts"

echo "V091N_DETACHED_HEAD_REFUSAL=PASS"
pass "spec new fails closed on detached HEAD with typed DETACHED_HEAD_UNSUPPORTED"

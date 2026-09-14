#!/usr/bin/env bash
# Host-safe canonical wrapper for the synthetic final-source closure suite.
#
# The underlying test intentionally constructs capability resolutions with no
# host manifest. On a commissioned workstation, inheriting the operator's real
# XDG state would make that synthetic fixture dishonest: the production
# integrity verifier correctly observes the real manifest and treats it as
# authority drift. Run the synthetic fixture under an empty private XDG state
# root instead of asking the operator to move trusted workstation files.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_STATE_ROOT="$(mktemp -d -t ofloop_final_source_state.XXXXXX)"
cleanup() {
  rm -rf "$TEST_STATE_ROOT"
}
trap cleanup EXIT INT TERM

export XDG_STATE_HOME="$TEST_STATE_ROOT"

bash "$HERE/test_final_source_closure.sh"

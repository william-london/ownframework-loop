#!/usr/bin/env bash
# Shared test helpers — sourced by every test_*.sh.

set -uo pipefail

# Resolve ROOT from the script that sourced us (assumes ../../ relative path).
TEST_HELPERS_LOADED=1
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$ROOT_DIR/lib"
BIN_DIR="$ROOT_DIR/bin"

export PYTHONPATH="$LIB_DIR${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_LIB="$LIB_DIR"
export OFLOOP_ROOT="$ROOT_DIR"

OFLOOP_BIN="$BIN_DIR/ofloop"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; exit 1; }

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-assert_eq}"
  if [[ "$actual" != "$expected" ]]; then
    fail "$msg: expected=$expected actual=$actual"
  fi
  pass "$msg"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-assert_contains}"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "$msg: '$needle' not in '$haystack'"
  fi
  pass "$msg"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-assert_not_contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$msg: '$needle' unexpectedly in '$haystack'"
  fi
  pass "$msg"
}

assert_file_exists() {
  local p="$1" msg="${2:-assert_file_exists: $1}"
  [[ -f "$p" ]] || fail "$msg"
  pass "$msg"
}

assert_dir_exists() {
  local p="$1" msg="${2:-assert_dir_exists: $1}"
  [[ -d "$p" ]] || fail "$msg"
  pass "$msg"
}

make_tmp_repo() {
  local d
  d="$(mktemp -d -t ofloop_test_repo.XXXXXX)"
  git -C "$d" init -b master >/dev/null 2>&1
  git -C "$d" config user.email "test@local"
  git -C "$d" config user.name "test"
  echo "seed" > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -m "init" >/dev/null 2>&1
  echo "$d"
}

make_tmp_run() {
  local repo="$1"
  local run_id
  run_id="run-test-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' $RANDOM)"
  "$OFLOOP_BIN" spec new "$repo" "test mission" >/dev/null
  # Find the latest run dir.
  local latest
  latest="$(ls -1t "$repo/.ownframework-loop" | head -n1)"
  echo "$latest"
}

write_packet() {
  local repo="$1" run_id="$2" packet_md="$3"
  local target="$repo/.ownframework-loop/$run_id/WORK_PACKET.md"
  echo "$packet_md" > "$target"
  echo "$target"
}

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

for f in \
  "$ROOT/skills/spec/SKILL.md" \
  "$ROOT/.agents/skills/of-loop-spec/SKILL.md"
do
  grep -Fq 'execution intent' "$f" || {
    echo "FAIL: spec adapter missing execution-intent doctrine: $f" >&2
    exit 1
  }
  grep -Fq 'draft-only intent' "$f" || {
    echo "FAIL: spec adapter missing draft-only refusal doctrine: $f" >&2
    exit 1
  }
  grep -Fq 'ofloop capabilities preflight <repo> <capability>... --role builder --runner-profile <profile>' "$f" || {
    echo "FAIL: spec adapter missing builder preflight: $f" >&2
    exit 1
  }
  grep -Fq 'ofloop capabilities preflight <repo> <capability>... --role reviewer --runner-profile <profile>' "$f" || {
    echo "FAIL: spec adapter missing reviewer preflight: $f" >&2
    exit 1
  }
  grep -Fq 'ofloop supervisor enqueue <repo> <run-id>' "$f" || {
    echo "FAIL: spec adapter missing durable enqueue: $f" >&2
    exit 1
  }
  grep -Fq 'do not stop merely to hand the operator an enqueue' "$f" || {
    echo "FAIL: spec adapter can still reintroduce enqueue ceremony: $f" >&2
    exit 1
  }
  grep -Fq 'persistent supervisor configuration owns' "$f" || {
    echo "FAIL: spec adapter does not delegate machine tuning to supervisor config: $f" >&2
    exit 1
  }
  grep -Fq 'prefer the trusted workstation profile `primary`' "$f" || {
    echo "FAIL: spec adapter missing workstation profile convention: $f" >&2
    exit 1
  }
done

echo "ZERO_CEREMONY_SPEC_LAUNCH_CONTRACT=PASS"

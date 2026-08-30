#!/usr/bin/env bash
# OwnFramework Loop — self-contained marketplace installer.
#
# This script installs the plugin through Claude Code's official plugin
# manager using the marketplace catalog that lives INSIDE this repository
# at .claude-plugin/marketplace.json. No external parent repository or
# sibling catalog is required.
#
# After install:
#   * marketplace name : ownframework
#   * plugin identity  : of-loop@ownframework
#   * managed cache    : ~/.claude/plugins/cache/ownframework/of-loop/<version>
#   * persistent data  : ~/.claude/plugins/data/of-loop-ownframework
#
# The script is idempotent: a second run re-installs the same plugin.
# A legacy ~/.claude/skills/of-loop directory is NOT touched by this
# script; if one exists from a prior installation, the user must remove
# it manually (it is not a managed install path).
#
# Pre-requisites:
#   * claude CLI on PATH
#   * the source tree must be clean (no uncommitted changes)
#   * the source must be a git repository (for SHA provenance)
#
# Honors:
#   SOURCE_ROOT     - the plugin source directory (default: script dir)
#   SCOPE           - install scope: user (default) | project | local
#   KEEP_MARKETPLACE - if set to 1, do not remove the marketplace on exit
#   OFLOOP_SKIP_SUPERVISOR_REFRESH - set to 1 to skip refresh of an already-commissioned macOS supervisor

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$HERE}"
SCOPE="${SCOPE:-user}"
PLUGIN_ID="of-loop@ownframework"
MARKETPLACE_NAME="ownframework"

log() { echo "[install] $*"; }

# --- pre-flight ---
if ! command -v claude >/dev/null 2>&1; then
    log "claude CLI not on PATH; cannot perform managed install"
    exit 3
fi

if ! git -C "$SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log "SOURCE_ROOT is not a git repository: $SOURCE_ROOT"
    exit 6
fi

if [[ ! -f "$SOURCE_ROOT/.claude-plugin/marketplace.json" ]]; then
    log "marketplace catalog missing at $SOURCE_ROOT/.claude-plugin/marketplace.json"
    log "this script must be run from a clone of the ownframework-loop repository"
    exit 7
fi

SOURCE_BRANCH="$(git -C "$SOURCE_ROOT" branch --show-current 2>/dev/null || echo unknown)"
SOURCE_SHA="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
SOURCE_DIRTY="$(git -C "$SOURCE_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
EXPECTED_VERSION="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$SOURCE_ROOT/.claude-plugin/plugin.json")"
MKT_VERSION="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['plugins'][0]['version'])" "$SOURCE_ROOT/.claude-plugin/marketplace.json")"

log "source: $SOURCE_ROOT (branch=${SOURCE_BRANCH}, sha=${SOURCE_SHA}, dirty=${SOURCE_DIRTY})"
log "plugin version: $EXPECTED_VERSION"
log "marketplace version: $MKT_VERSION"

if [[ "$EXPECTED_VERSION" != "$MKT_VERSION" ]]; then
    log "version mismatch between plugin.json ($EXPECTED_VERSION) and marketplace.json ($MKT_VERSION); refusing"
    exit 2
fi

if [[ "$SOURCE_DIRTY" != "0" ]]; then
    log "source tree is dirty (${SOURCE_DIRTY} files); refusing"
    exit 6
fi

# Before plugin-manager mutation, refuse to replace cache bytes relied on by
# any unfinished commissioned run. This protects old/unbound ledgers too.
if [[ "$(uname -s)" == "Darwin" ]]; then
    PRE_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop"
    PRE_DB="$PRE_STATE_ROOT/supervisor.sqlite3"
    PRE_PLIST="$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
    PRE_PROV="$PRE_STATE_ROOT/runtime-provenance.json"
    if [[ ( -f "$PRE_PLIST" || -f "$PRE_PROV" ) && ! -f "$PRE_DB" && "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" != "1" ]]; then
        log "managed install REFUSED: commissioned supervisor exists but ledger is missing; runtime dependencies cannot be proven"
        log "explicit migration override: OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1"
        exit 13
    fi
    if [[ ( -f "$PRE_PLIST" || -f "$PRE_PROV" ) && -f "$PRE_DB" ]]; then
        PRE_REPORT="$(python3 -B - "$PRE_DB" <<'PY'
import sqlite3, sys
try:
    c=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    rows=c.execute("SELECT run_id,status FROM jobs WHERE status NOT IN ('DONE','RETIRED') ORDER BY id").fetchall()
except sqlite3.Error:
    print("ledger_probe_failed")
    raise SystemExit(0)
print(";".join(f"{r[0]}:{r[1]}" for r in rows[:8]))
PY
        )" || PRE_REPORT="ledger_probe_failed"
        if [[ "$PRE_REPORT" == "ledger_probe_failed" ]]; then
            log "managed install REFUSED: commissioned supervisor ledger unreadable"
            exit 13
        fi
        if [[ -n "$PRE_REPORT" ]]; then
            if [[ "$PRE_REPORT" == *":RUNNING"* && "${OFLOOP_ALLOW_SUPERVISOR_SWAP_WITH_ACTIVE_WORK:-0}" != "1" ]]; then
                log "managed install REFUSED: RUNNING supervisor work exists ($PRE_REPORT)"
                exit 11
            fi
            if [[ "${OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION:-0}" != "1" ]]; then
                log "managed install REFUSED: unfinished supervisor jobs depend on commissioned runtime ($PRE_REPORT)"
                log "finish/stop them first, or explicitly migrate with OFLOOP_ALLOW_RUNTIME_GENERATION_MIGRATION=1"
                exit 13
            fi
        fi
    fi
fi

# Record provenance (does not affect the managed install)
PROVENANCE="$SOURCE_ROOT/.install.provenance"
{
    echo "source_branch=${SOURCE_BRANCH}"
    echo "source_sha=${SOURCE_SHA}"
    echo "expected_version=${EXPECTED_VERSION}"
    echo "marketplace_name=${MARKETPLACE_NAME}"
    echo "plugin_id=${PLUGIN_ID}"
    echo "scope=${SCOPE}"
    echo "installed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$PROVENANCE"
log "provenance: $PROVENANCE"

# --- marketplace registration ---
# If the marketplace is not already registered, register it pointing at
# this source. Using `claude plugin marketplace add` with a local path
# is supported by the official plugin manager.
EXISTING="$(claude plugin marketplace list 2>/dev/null || true)"
if ! echo "$EXISTING" | grep -q "^[[:space:]]*${MARKETPLACE_NAME}[[:space:]]*$"; then
    log "registering marketplace ${MARKETPLACE_NAME} -> $SOURCE_ROOT"
    if ! claude plugin marketplace add "$SOURCE_ROOT" >"$SOURCE_ROOT/.install.log" 2>&1; then
        log "marketplace registration FAILED; see $SOURCE_ROOT/.install.log"
        exit 8
    fi
else
    log "marketplace ${MARKETPLACE_NAME} already registered"
fi

# --- managed install ---
# Uninstall any pre-existing copy first to avoid upgrade refusal.
log "removing any pre-existing ${PLUGIN_ID}"
if ! claude plugin uninstall "$PLUGIN_ID" --scope "$SCOPE" >"$SOURCE_ROOT/.uninstall.log" 2>&1; then
    log "warning: pre-existing uninstall returned non-zero (likely no prior install); continuing"
fi

log "installing ${PLUGIN_ID}@${EXPECTED_VERSION} (scope=${SCOPE})"
if ! claude plugin install "$PLUGIN_ID" --scope "$SCOPE" >"$SOURCE_ROOT/.install.log" 2>&1; then
    log "managed install FAILED; see $SOURCE_ROOT/.install.log"
    exit 4
fi

# --- parity check ---
EXPECTED_CACHE="$HOME/.claude/plugins/cache/${MARKETPLACE_NAME}/of-loop/$EXPECTED_VERSION"
if [[ ! -d "$EXPECTED_CACHE" ]]; then
    log "parity check FAILED: expected cache tree missing at $EXPECTED_CACHE"
    exit 5
fi
log "cache verified at $EXPECTED_CACHE"

# --- payload manifest ---
# Same as before — captures every regular file in the installed cache
# tree with its SHA-256, so post-install tampering is detectable.
MANIFEST="$EXPECTED_CACHE/.payload.manifest"
PAYLOAD_FILES="$( ( cd "$EXPECTED_CACHE" && find . -type f \
  -not -path "./logs/*" \
  -not -path "./.git/*" \
  -not -path "./.ownframework-loop/*" \
  -not -path "*/__pycache__/*" \
  -not -name ".payload.manifest" \
  -not -name ".payload.manifest.tmp" \
  -not -name "*.pyc" \
  -not -name "*.pyo" \
  -not -name "*.pyd" \
  | LC_ALL=C sort ) )"
> "$MANIFEST.tmp"
{
  echo "# OwnFramework Loop payload manifest"
  echo "# generated_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# cache_root=$EXPECTED_CACHE"
  echo "# source_branch=$SOURCE_BRANCH"
  echo "# source_sha=$SOURCE_SHA"
  echo "# installed_version=$EXPECTED_VERSION"
  echo "# marketplace_name=$MARKETPLACE_NAME"
  echo "# plugin_id=$PLUGIN_ID"
} >> "$MANIFEST.tmp"
ENTRY_COUNT=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  rel="${f#./}"
  sha="$(shasum -a 256 "$EXPECTED_CACHE/$rel" 2>/dev/null | awk '{print $1}')"
  echo "sha256  $sha  $rel" >> "$MANIFEST.tmp"
  ENTRY_COUNT=$((ENTRY_COUNT+1))
done <<< "$PAYLOAD_FILES"
echo "# file_count=$ENTRY_COUNT" >> "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
log "payload manifest written: $MANIFEST (with $ENTRY_COUNT files)"

# --- operator CLI shim ---
# Install a small symlink so a fresh operator shell can invoke `ofloop`
# directly without `cd`-ing to the source tree or relying on the
# user's shell config to know about the source bin directory. Idempotent
# and refuses to overwrite an unmanaged binary at the same path.
#
# Default shim location: $HOME/.local/bin (already on most shells' PATH
# via Homebrew / platform defaults). Override with OFLOOP_SHIM_DIR.
# Set OFLOOP_SKIP_SHIM=1 to skip this step entirely.
if [[ "${OFLOOP_SKIP_SHIM:-0}" == "1" ]]; then
    log "operator CLI shim: skipped (OFLOOP_SKIP_SHIM=1)"
else
    SHIM_DIR="${OFLOOP_SHIM_DIR:-$HOME/.local/bin}"
    SHIM_PATH="$SHIM_DIR/ofloop"
    SHIM_TARGET="$EXPECTED_CACHE/bin/ofloop"
    if [[ ! -d "$SHIM_DIR" ]]; then
        log "operator CLI shim: creating $SHIM_DIR"
        mkdir -p "$SHIM_DIR"
    fi
    if [[ -L "$SHIM_PATH" ]]; then
        EXISTING_TARGET="$(readlink "$SHIM_PATH" 2>/dev/null || true)"
        if [[ "$EXISTING_TARGET" == "$SHIM_TARGET" ]]; then
            log "operator CLI shim: already installed at $SHIM_PATH"
        else
            log "operator CLI shim: replacing stale shim $SHIM_PATH -> $SHIM_TARGET (was $EXISTING_TARGET)"
            ln -sfn "$SHIM_TARGET" "$SHIM_PATH"
        fi
    elif [[ -e "$SHIM_PATH" ]]; then
        log "operator CLI shim: refusing to overwrite unmanaged binary at $SHIM_PATH"
        log "  remove it manually, or set OFLOOP_SHIM_DIR to a different location"
    else
        ln -sfn "$SHIM_TARGET" "$SHIM_PATH"
        log "operator CLI shim: created $SHIM_PATH -> $SHIM_TARGET"
    fi
fi

# --- refresh an already-commissioned macOS supervisor ---
# Delegate to a narrow helper so install orchestration stays acyclic/testable.
REFRESH_HELPER="$EXPECTED_CACHE/scripts/refresh-existing-supervisor-macos.sh"
if [[ ! -x "$REFRESH_HELPER" ]]; then
    log "supervisor refresh helper missing from installed payload: $REFRESH_HELPER"
    exit 9
fi
if ! OFLOOP_SKIP_SUPERVISOR_REFRESH="${OFLOOP_SKIP_SUPERVISOR_REFRESH:-0}" \
    "$REFRESH_HELPER" "$EXPECTED_CACHE" "$SOURCE_ROOT" >"$SOURCE_ROOT/.supervisor-refresh.log" 2>&1; then
    log "supervisor refresh FAILED; see $SOURCE_ROOT/.supervisor-refresh.log"
    exit 9
fi
if grep -Fq "SUPERVISOR_REFRESH=PASS" "$SOURCE_ROOT/.supervisor-refresh.log"; then
    log "existing macOS supervisor refreshed to installed payload $EXPECTED_VERSION"
fi

log "managed install complete; reload with: claude /reload-plugins"
exit 0

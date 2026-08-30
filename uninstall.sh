#!/usr/bin/env bash
# OwnFramework Loop — self-contained marketplace uninstall.
#
# Removes the managed plugin via Claude Code's official plugin manager.
# Preserves the marketplace registration so re-installing is a no-op for
# the marketplace step. Use the --remove-marketplace flag to also remove
# the marketplace entry.
#
# Honors:
#   SCOPE - install scope: user (default) | project | local
#   PLUGIN_ID - override the plugin identity (default: of-loop@ownframework)
#   MARKETPLACE_NAME - override the marketplace name (default: ownframework)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE="${SCOPE:-user}"
PLUGIN_ID="${PLUGIN_ID:-of-loop@ownframework}"
MARKETPLACE_NAME="${MARKETPLACE_NAME:-ownframework}"

if ! command -v claude >/dev/null 2>&1; then
    echo "[uninstall] claude CLI not on PATH; cannot run managed uninstall"
    exit 2
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    SUP_PLIST="$HOME/Library/LaunchAgents/com.ownframework.loop-supervisor.plist"
    SUP_PROV="${XDG_STATE_HOME:-$HOME/.local/state}/ownframework-loop/runtime-provenance.json"
    if [[ -f "$SUP_PLIST" || -f "$SUP_PROV" ]]; then
        echo "[uninstall] commissioned supervisor detected; stopping it before plugin removal"
        if ! bash "$HERE/uninstall-supervisor-macos.sh"; then
            echo "[uninstall] refusing plugin removal while supervisor shutdown is unsafe" >&2
            exit 11
        fi
    fi
fi

echo "[uninstall] running: claude plugin uninstall ${PLUGIN_ID} --scope ${SCOPE}"
if ! claude plugin uninstall "$PLUGIN_ID" --scope "$SCOPE"; then
    echo "[uninstall] managed uninstall returned non-zero; the plugin may not have been installed"
    exit 1
fi
echo "[uninstall] complete; persistent plugin data and the marketplace registration are preserved"

# --- operator CLI shim removal ---
# Reverse the symlink installed by install.sh. We only remove the symlink
# if it still points into the now-uninstalled plugin cache, so we never
# delete an unrelated binary the operator happened to place at the same
# path. Override with OFLOOP_SHIM_DIR; set OFLOOP_SKIP_SHIM=1 to keep it.
if [[ "${OFLOOP_SKIP_SHIM:-0}" == "1" ]]; then
    echo "[uninstall] operator CLI shim: skipped (OFLOOP_SKIP_SHIM=1)"
else
    SHIM_DIR="${OFLOOP_SHIM_DIR:-$HOME/.local/bin}"
    SHIM_PATH="$SHIM_DIR/ofloop"
    if [[ -L "$SHIM_PATH" ]]; then
        EXISTING_TARGET="$(readlink "$SHIM_PATH" 2>/dev/null || true)"
        case "$EXISTING_TARGET" in
            *"/.claude/plugins/cache/ownframework/of-loop/"*)
                rm -f "$SHIM_PATH"
                echo "[uninstall] operator CLI shim: removed $SHIM_PATH"
                ;;
            *)
                echo "[uninstall] operator CLI shim: kept (points to $EXISTING_TARGET, not into ownframework)"
                ;;
        esac
    fi
fi

if [[ "${REMOVE_MARKETPLACE:-0}" == "1" ]]; then
    echo "[uninstall] removing marketplace ${MARKETPLACE_NAME}"
    claude plugin marketplace remove "$MARKETPLACE_NAME" || true
fi

exit 0

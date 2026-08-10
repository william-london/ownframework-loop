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
SCOPE="${SCOPE:-user}"
PLUGIN_ID="${PLUGIN_ID:-of-loop@ownframework}"
MARKETPLACE_NAME="${MARKETPLACE_NAME:-ownframework}"

if ! command -v claude >/dev/null 2>&1; then
    echo "[uninstall] claude CLI not on PATH; cannot run managed uninstall"
    exit 2
fi

echo "[uninstall] running: claude plugin uninstall ${PLUGIN_ID} --scope ${SCOPE}"
if ! claude plugin uninstall "$PLUGIN_ID" --scope "$SCOPE"; then
    echo "[uninstall] managed uninstall returned non-zero; the plugin may not have been installed"
    exit 1
fi
echo "[uninstall] complete; persistent plugin data and the marketplace registration are preserved"

if [[ "${REMOVE_MARKETPLACE:-0}" == "1" ]]; then
    echo "[uninstall] removing marketplace ${MARKETPLACE_NAME}"
    claude plugin marketplace remove "$MARKETPLACE_NAME" || true
fi

exit 0

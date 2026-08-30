# Portability Notes

OwnFramework Loop core is intentionally host-neutral.

Claude Code is currently the first production-hardened semantic runner.
Codex is experimental. Future integrations such as other coding-agent CLIs
should register/implement the shared runner contract or consume the generic CLI
contract rather than fork the deterministic state machine.

Platform service support is currently macOS launchd and Linux systemd-user.
WSL2 follows the Linux path when its user service manager is available.

Do not describe plugin installation, `/loop`, or any one model host as the
canonical OwnFramework Loop execution architecture.

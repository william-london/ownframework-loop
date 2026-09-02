# Maintained Runtime Scripts

This directory contains product-owned lifecycle and validation helpers used by the
installed runtime. They are maintained implementation surfaces—not scratch scripts,
one-off migration debris, or operator snippets.

`supervisor/` contains the platform-specific service implementation behind the
operator-facing `bin/install-supervisor` and `bin/uninstall-supervisor` commands.
The remaining helpers support commissioned-supervisor launch/refresh, runtime
dependency proof, and installed-payload manifest verification.

Public setup commands belong in `../bin/` when they are operator-facing. Core
source-checkout lifecycle and validation entrypoints intentionally remain at repository
root (`install.sh`, `uninstall.sh`, `validate.sh`, and `release_gate.sh`).

Add a script here only when it is part of a supported lifecycle or deterministic
validation path. Ad-hoc maintenance commands, generated diagnostics, temporary
experiments, and local-machine helpers do not belong in the repository.

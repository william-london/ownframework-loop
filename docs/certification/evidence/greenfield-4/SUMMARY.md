# Greenfield Certification #4 — Post-Remediation End-to-End Proof

## Identification

- certification name: ofloop-cert-greenfield-4 (2026-09-22)
- classification: MECHANISM_PROOF + SUPERVISOR_PRODUCTION_PATH_PROOF
- fixture upstream project: ownframework-loop at SHA d67af5ff159a59fa0a0ef8adcf384ea60c0dafa0
- fixture physical path: /private/var/folders/r5/_0bfjyj129953ndp19ms9j9r0000gn/T/ofloop-greenfield-4.XXXXXX.TMF0jPdD1Q/repo/repo
- FIXTURE_BASELINE_SHA (greenfield-4 initial empty master after bootstrap): 40cc891ea3a178fb31e780e43d35e8b135efb2ae
- candidate SHA after CP-1 work: 353f8be26a47c6b3384f50c14590ec551f288d5c
- run id: run-20260922T210439Z-583ff7a2
- authoritative artifacts: ~/.local/state/ownframework-loop/certification/greenfield-4-2026-09-22/

## What this certifies (post-remediation validator)

### A_UV_CAPABILITY_DECLARATION_PARITY

```
canonical predicate:        validation_environment.is_uv_command(command)
UV_MEDIATED_SUBCOMMANDS:    (run, sync, exec, test, python, lock)
packet admission consumer:  packet.py
executor consumer:          validation_executor.py
shared canonical:           YES (no independent regex in either layer)
```

### A_UV_EXACT_IDENTITY_BEFORE_EFFECT

```
bound identity:             BoundUvIdentity(executable, version,
                                         executable_sha256, cache_path,
                                         cache_scope, network_domains)
constructed from:           frozen CAPABILITY_BINDING.json (resolution
                            re-derived via commissioned_validation_resolution())
verified pre-launch:        verify_bound_uv_identity(bound) — refuses
                            missing / symlink / byte-mutation
shutil.which("uv") authority:  no (legacy escape hatch with
                               package_uv_unbound=true deprecation flag)
bound uv (greenfield-4):
  executable:               /opt/homebrew/Cellar/uv/0.12.15/bin/uv
  version:                  uv 0.12.15 (Homebrew 2026-09-15 aarch64-apple-darwin)
  executable_sha256:        381ab44fd5422a42...
  cache_path:               (provider-cached, see CAPABILITY_BINDING.json)
  cache_scope:              (provider-cached)
  network_domains:          ['files.pythonhosted.org', 'pypi.org']
```

### A_PACKAGE_NETWORK_AUTHORITY

```
PACKAGE_NETWORK_OVERRIDE_KEYS: UV_INDEX_URL, UV_EXTRA_INDEX_URL,
                               UV_DEFAULT_INDEX, UV_INDEX,
                               PIP_INDEX_URL, PIP_EXTRA_INDEX_URL,
                               PIP_DEFAULT_INDEX, PIP_NO_INDEX,
                               NPM_CONFIG_REGISTRY, npm_config_registry,
                               PNPM_REGISTRY,
                               CARGO_REGISTRIES_CRATES_IO_PROTOCOL,
                               CARGO_REGISTRIES_CRATES_IO_INDEX

hermetic_subprocess_env():   strips every key above before subprocess launch
frozen package.uv domains:   ['files.pythonhosted.org', 'pypi.org']
                             — sole authority for validator network reach
```

### End-to-end validator proof

| Step | Builder | Reviewer |
|------|---------|----------|
| Re-resolve CAPABILITY_BINDING | PASS | PASS |
| Extract BoundUvIdentity | PASS | PASS |
| verify_bound_uv_identity | PASS | PASS |
| provision_project_environment(bound_uv=...) | PASS | PASS |
| role-isolated env_marker_path | builder env | reviewer env (DIFFERENT) |
| `uv run --no-sync pytest -q` | 8 PASS | 8 PASS |
| `uv run --no-sync greenfield4-cmd` | banner OK | n/a |
| package_uv_unbound | False | False |
| worktree .venv leaked | False | False |

## Hosted CI on the final master SHA

```
CI run:        #511 (run ID 35785229071)
SHA:           d67af5ff159a59fa0a0ef8adcf384ea60c0dafa0
Branch:        hardening/validation-env-final-closure-2026-09-22-v2
URL:           https://github.com/william-london/ownframework-loop/actions/runs/35785229071
Jobs (10/10):  codex-adapter-static, security, core (ubuntu-latest, 3.12),
               core (ubuntu-latest, 3.13), core (macos-latest, 3.12),
               core (macos-latest, 3.13), release-gate (3.12),
               release-gate (3.13), claude-adapter, adapter-contract
               — all success
```

## Operator-owned artifacts

```
~/.local/state/ownframework-loop/certification/greenfield-4-2026-09-22/
  APPROVAL.json
  STATE.json
  CAPABILITY_BINDING.json
  BUILD_AGENT_RESULT.json
  builder_proof.json
  reviewer_proof.json
  CI_EVIDENCE.json
  CONTENT_SHA256.json   (canonical SHA-256 of each artifact)
```

An independent operator can re-verify every artifact by comparing the
in-repo SHA-256 to the operator-owned SHA-256 without trusting the
in-repo doc.

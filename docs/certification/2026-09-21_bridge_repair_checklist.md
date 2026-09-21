# Bridge Repair Checklist (2026-09-21 mid-run)

## A-grade (mandatory)
- [x] A-RESEARCH-RESPONSE-FORGE: move responses out of worker allowWrite
- [x] A-RESEARCH-RESPONSE-PATH-CONFINEMENT: strict validators
- [x] A-RESEARCH-SUPERVISOR-LIVENESS: bounded async executor
- [x] A-BROKER-RUNTIME-IDENTITY: SHA verification before launch

## B-grade
- [x] B-QUEUE-ISOLATION: per-run request inbox
- [x] B-ATTEMPT/ROLE-BINDING: durable identity
- [x] B-RESPONSE-LOCATION: canonical owner (single source)
- [x] B-RESEARCH-RATE-LIMIT: durable across ticks
- [x] B-RESOURCE-CAPS: clamp worker max_bytes
- [x] B-CRASH/REPLAY: idempotent lifecycle
- [x] B-BROKER-REQUEST-IDENTITY: pass identity to broker
- [x] B-GENERAL-SEARCH: provider-neutral backend
- [x] B-SPECIAL-USE-ADDRESS: expand SSRF ranges
- [x] B-ROLE-PROMPT-DRIFT: clean stale broker-direct instructions
- [x] B-PROMPT-INJECTION-TEST: real behavioral fixture

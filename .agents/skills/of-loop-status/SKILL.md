---
name: of-loop-status
description: Inspect OwnFramework Loop run state, approval binding, candidate identity, verdict, and adapter evidence without mutating protected state.
---

# OwnFramework Loop — status

Use supported `ofloop` status, doctor, and adapter inspection commands. Status is read-only.

Do not directly edit `STATE.json`, `APPROVAL.json`, `REVIEW_VERDICT.json`, event logs, or lock files. Human approval, build transitions, review transitions, repair accounting, and promotion remain separate authority classes.

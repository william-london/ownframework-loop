# Core invariants

OwnFramework Loop's product identity is the protocol, not a specific coding-agent vendor.

The deterministic core preserves:

1. a human-operated approval gate: interactive core confirmation plus adapter hardening that withholds approval authority from the agent;
2. approval binding to exact work-packet bytes;
3. bounded scope/risk/runtime/repair limits;
4. candidate identity as an exact Git SHA;
5. reviewer binding to that exact SHA;
6. serialized deterministic state transitions;
7. bounded repair cycles;
8. fail-closed terminal semantics;
9. no loop-owned push/merge/deploy/publish/send/payment authority;
10. human promotion outside the loop.

Adapters may strengthen enforcement with host-native hooks or agents, but they may not weaken or reimplement these invariants.

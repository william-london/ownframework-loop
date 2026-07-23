"""Harmless lock holder used only by deterministic refusal tests."""
from __future__ import annotations
import argparse
import time
from .gate_lock import GateLock

p = argparse.ArgumentParser()
p.add_argument("--seconds", type=float, default=2)
a = p.parse_args()
with GateLock.acquire(source_head="fixture", command="gate-lock-fixture"):
    print("LOCK_HELD", flush=True)
    time.sleep(a.seconds)

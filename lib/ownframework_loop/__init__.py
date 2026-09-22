"""OwnFramework Loop — durable execution plane for AI coding agents."""
from __future__ import annotations

# Versioning doctrine:
#   - v1.0.0 is FROZEN at the v1.0.0 tag (f4b1188c80c66327011754a71c166572ee94963b).
#     The installed payload at the canonical v1.0.0 install root remains
#     authoritative for that release. The v1.0.0 tag is NOT moved.
#   - Post-v1 development (progress watchdog, governed research.public,
#     additional runtime/authority behavior) lives on master under the
#     source-identity ``1.1.0.dev0``. The canonical installer places this
#     dev payload under the NEW version identity so the v1.0.0 install root
#     remains distinguishable from the post-v1 dev payload.
#   - Publication authority is the immutable Git tag + GitHub Release.
#     This string is source-identity only; the runtime_generation hash
#     of the installed payload is what verifies identity at runtime.
__version__ = "1.1.0.dev0"
__all__ = ["__version__"]

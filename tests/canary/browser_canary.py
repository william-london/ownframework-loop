#!/usr/bin/env python3
"""Minimal Playwright Chromium browser canary (physical commissioning only).

This is the REAL browser canary used to runtime-prove the
`browser.playwright.chromium` capability during PHYSICAL commissioning.

It proves the EXACT browser runtime Loop will hand to semantic workers: the
launch is forced through the shared immutable asset root
(`capabilities.default_browser_asset_dir()`) via PLAYWRIGHT_BROWSERS_PATH,
never through the operator's ambient Playwright cache. On success (and with
``--write-proof``) it persists a private, freshness-bound runtime proof that
binds:

  * the CURRENT platform identity and semantic runtime fingerprint,
  * the exact imported Python Playwright client package bytes/path/version,
  * the exact Playwright/browser versions,
  * the exact browser asset tree (Merkle digest of the asset root).

Any later drift — platform, Claude/runtime bytes, or asset bytes — stales
the proof automatically; `ofloop capabilities probe` then reports the
capability as provisionable/resolvable but NOT runtime-proven until the
canary is re-run.

The source/CI suite NEVER launches a real browser. This canary is invoked
only by an operator commissioning a physical host:

  # one-time provisioning into the shared immutable asset root
  # (print the root with: python3 -c "import sys; sys.path.insert(0,'lib');
  #  from ownframework_loop import capabilities;
  #  print(capabilities.default_browser_asset_dir())"):
  PLAYWRIGHT_BROWSERS_PATH="<asset-root>" python3 -m playwright install chromium
  # empirical proof (+ durable proof record):
  python3 tests/canary/browser_canary.py --write-proof

Exit code 0 only when the browser was empirically launched and verified from
the exact asset root workers receive.
"""
from __future__ import annotations

import json
import os
import sys

CANARY_SCHEMA = "ownframework-loop-browser-canary/v1"
CAPABILITY = "browser.playwright.chromium"


def _lib_dir() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", "..", "lib"))


def main() -> int:
    write_proof = "--write-proof" in sys.argv[1:]
    sys.path.insert(0, _lib_dir())
    from ownframework_loop import capabilities as cap_mod

    asset_root_raw = cap_mod.default_browser_asset_dir()
    result = {
        "schema": CANARY_SCHEMA,
        "capability": CAPABILITY,
        "ok": False,
        "browser": "chromium",
        "headless": True,
        "browser_asset_root": str(asset_root_raw),
    }

    if asset_root_raw.is_symlink() or not asset_root_raw.is_dir() or not any(asset_root_raw.iterdir()):
        result["error"] = (
            "browser asset root missing or empty; provision it exactly once with: "
            f"PLAYWRIGHT_BROWSERS_PATH={asset_root_raw} python3 -m playwright install chromium"
        )
        print(json.dumps(result, sort_keys=True))
        return 1

    # Normalize parent aliases (notably macOS /var -> /private/var) only AFTER
    # refusing a symlink at the commissioned leaf itself. Workers resolve the
    # same physical root before launch, so the canary must attest that exact
    # canonical path string as well as the same bytes.
    asset_root = cap_mod._browser_asset_root(asset_root_raw, require_exists=True)
    result["browser_asset_root"] = str(asset_root)

    # Prove the EXACT runtime workers receive: force the Playwright registry
    # at the shared immutable asset root BEFORE importing/launching
    # Playwright, so no operator-ambient cache can satisfy the proof.
    os.environ["PLAYWRIGHT_BROWSERS_PATH"] = str(asset_root)

    try:
        from playwright.sync_api import sync_playwright
    except Exception as exc:  # noqa: BLE001 — report any import failure
        result["error"] = f"playwright not importable: {type(exc).__name__}: {exc}"
        print(json.dumps(result, sort_keys=True))
        return 1

    playwright_version = ""
    browser_version = ""
    try:
        import playwright as _pw_mod
        playwright_version = str(getattr(_pw_mod, "__version__", "") or "")
    except Exception:  # noqa: BLE001
        playwright_version = ""

    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=True)
            try:
                browser_version = str(browser.version or "")
                page = browser.new_page()
                page.goto("about:blank")
                value = page.evaluate("1 + 1")
                result["ok"] = bool(value == 2)
                if not result["ok"]:
                    result["error"] = f"unexpected evaluate result: {value!r}"
            finally:
                browser.close()
    except Exception as exc:  # noqa: BLE001 — report any launch/eval failure
        result["ok"] = False
        result["error"] = f"browser launch failed: {type(exc).__name__}: {exc}"

    result["playwright_version"] = playwright_version
    result["browser_version"] = browser_version

    if result.get("ok"):
        # Byte-bind BOTH authority-bearing halves the launch just used:
        # Chromium assets and the imported Python Playwright client.
        try:
            merkle = cap_mod.browser_asset_merkle_sha256(asset_root)
            client_identity = cap_mod.playwright_client_identity()
        except Exception as exc:  # noqa: BLE001
            result["ok"] = False
            result["error"] = f"browser/client identity failed: {type(exc).__name__}: {exc}"
            merkle = ""
            client_identity = {}
        result["browser_asset_merkle_sha256"] = merkle
        result["playwright_client_identity"] = client_identity

    if write_proof and result.get("ok"):
        proof = cap_mod.write_browser_runtime_proof(
            CAPABILITY,
            asset_root=str(asset_root),
            asset_merkle_sha256=result.get("browser_asset_merkle_sha256") or "",
            playwright_client=result.get("playwright_client_identity") or {},
            playwright_version=playwright_version,
            browser_version=browser_version,
        )
        result["proof_path"] = proof.get("proof_path")
        result["proof_sha256"] = proof.get("proof_sha256")

    print(json.dumps(result, sort_keys=True))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())

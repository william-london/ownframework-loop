#!/usr/bin/env python3
"""Minimal Playwright Chromium browser canary (physical commissioning only).

This is the REAL browser canary used to runtime-prove the
`browser.playwright.chromium` capability during PHYSICAL commissioning. It
launches a headless Chromium through Playwright, verifies the browser can
navigate and evaluate JavaScript, and — with ``--write-proof`` — persists a
durable browser-runtime-proof evidence record that `ofloop capabilities probe`
reads to report the capability as ``runtime_proven`` / ``available``.

The source/CI suite NEVER launches a real browser. This canary is invoked only
by an operator commissioning a physical host, mirroring how the privileged
Docker/local-binding canaries are commissioned.

Usage:
  python3 tests/canary/browser_canary.py            # prove, print result
  python3 tests/canary/browser_canary.py --write-proof   # prove + persist

Exit code 0 only when the browser was empirically launched and verified.
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
    result = {
        "schema": CANARY_SCHEMA,
        "capability": CAPABILITY,
        "ok": False,
        "browser": "chromium",
        "headless": True,
    }

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

    if write_proof and result.get("ok"):
        sys.path.insert(0, _lib_dir())
        from ownframework_loop import capabilities as cap_mod
        proof = cap_mod.write_browser_runtime_proof(
            CAPABILITY,
            playwright_version=playwright_version,
            browser_version=browser_version,
        )
        result["proof_path"] = proof.get("proof_path")
        result["proof_sha256"] = proof.get("proof_sha256")

    print(json.dumps(result, sort_keys=True))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())

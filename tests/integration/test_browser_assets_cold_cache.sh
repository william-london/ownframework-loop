#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
export OFLOOP_ROOT="$ROOT"
export PYTHONDONTWRITEBYTECODE=1

python3 -B - <<'PY'
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from ownframework_loop import capabilities


def refused(name, create):
    with tempfile.TemporaryDirectory(prefix="ofloop-browser-link-") as td:
        base = Path(td)
        root = base / "assets"
        root.mkdir()
        create(root, base / "outside")
        try:
            capabilities.browser_asset_merkle_sha256(root)
        except capabilities.CapabilityResolutionError as exc:
            print(f"{name}=REFUSED ({exc})")
        else:
            raise AssertionError(f"unsafe browser asset link accepted: {name}")


def relative_escape(root, outside):
    outside.mkdir()
    (root / "escape").symlink_to("../outside", target_is_directory=True)


def absolute_escape(root, outside):
    outside.mkdir()
    (root / "escape").symlink_to(outside, target_is_directory=True)


def absolute_internal_link(root, _outside):
    target = root / "inside"
    target.mkdir()
    (target / "payload").write_bytes(b"internal target")
    (root / "alias").symlink_to(target, target_is_directory=True)


def chained_escape(root, outside):
    outside.mkdir()
    nested = root / "nested"
    nested.mkdir()
    (nested / "first").symlink_to("second")
    (nested / "second").symlink_to("../../outside", target_is_directory=True)


def broken_link(root, _outside):
    (root / "broken").symlink_to("missing")


def link_cycle(root, _outside):
    (root / "a").symlink_to("b")
    (root / "b").symlink_to("a")


def lexical_internal_but_escaped(root, outside):
    outside.mkdir()
    nested = root / "nested"
    nested.mkdir()
    (nested / "link").symlink_to("proxy")
    (nested / "proxy").symlink_to("../../outside", target_is_directory=True)


def directory_ancestor_cycle(root, _outside):
    nested = root / "nested"
    nested.mkdir()
    (nested / "back").symlink_to("..", target_is_directory=True)


refused("RELATIVE_ESCAPE", relative_escape)
refused("ABSOLUTE_ESCAPE", absolute_escape)
refused("ABSOLUTE_INTERNAL_LINK", absolute_internal_link)
refused("CHAINED_ESCAPE", chained_escape)
refused("BROKEN_LINK", broken_link)
refused("SYMLINK_LOOP", link_cycle)
refused("LEXICAL_INTERNAL_RESOLVES_OUTSIDE", lexical_internal_but_escaped)
refused("DIRECTORY_ANCESTOR_CYCLE", directory_ancestor_cycle)


with tempfile.TemporaryDirectory(prefix="ofloop-browser-internal-links-") as td:
    root = Path(td) / "BrowserRoot"
    framework = root / "Chrome.app/Contents/Frameworks/Chrome.framework"
    version = framework / "Versions/123"
    (version / "Helpers").mkdir(parents=True)
    (version / "Resources").mkdir()
    (version / "Helpers/Inspector").write_bytes(b"synthetic helper")
    (version / "Resources/manifest").write_bytes(b"synthetic resource")
    (version / "Chrome Framework").write_bytes(b"synthetic framework")
    (framework / "Versions/Current").symlink_to("123", target_is_directory=True)
    (framework / "Helpers").symlink_to("Versions/Current/Helpers", target_is_directory=True)
    (framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
    (framework / "Chrome Framework").symlink_to("Versions/Current/Chrome Framework")
    first_digest = capabilities.browser_asset_merkle_sha256(root)
    (framework / "Helpers").unlink()
    (framework / "Helpers").symlink_to("Versions/123/Helpers", target_is_directory=True)
    second_digest = capabilities.browser_asset_merkle_sha256(root)
    assert first_digest != second_digest, "raw symlink structure was omitted from asset identity"
    print("CHROMIUM_FRAMEWORK_INTERNAL_LINKS=PASS")
    print("INTERNAL_FILE_AND_DIRECTORY_LINKS=PASS")
    print("SYMLINK_STRUCTURE_BOUND_IN_DIGEST=PASS")


with tempfile.TemporaryDirectory(prefix="ofloop-browser-cold-cache-") as td:
    base = Path(td)
    state_home = base / "state"
    fake_site = base / "fake-site"
    package = fake_site / "playwright"
    package.mkdir(parents=True)
    (package / "__init__.py").write_text("\"\"\"Test-local Playwright provisioning shim.\"\"\"\n")
    (package / "__main__.py").write_text(r'''from pathlib import Path
import os
import sys

if sys.argv[1:] != ["install", "chromium"]:
    raise SystemExit("fixture supports only the documented install chromium invocation")
root = Path(os.environ["PLAYWRIGHT_BROWSERS_PATH"])
app = root / "chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app"
framework = app / "Contents/Frameworks/Google Chrome for Testing Framework.framework"
binary = app / "Contents/MacOS/Google Chrome for Testing"
if app.exists():
    assert binary.is_file()
    assert (framework / "Helpers").is_symlink()
    assert (framework / "Versions/Current").is_symlink()
    print("browser already provisioned")
    raise SystemExit(0)
(framework / "Versions/123").mkdir(parents=True)
(framework / "Versions/123/Helpers").mkdir()
(framework / "Versions/123/Resources").mkdir()
(framework / "Versions/123/Helpers/Inspector").write_bytes(b"fixture helper")
(framework / "Versions/123/Resources/manifest").write_bytes(b"fixture resource")
(framework / "Versions/123/Chrome Framework").write_bytes(b"fixture framework")
(framework / "Versions/Current").symlink_to("123", target_is_directory=True)
(framework / "Helpers").symlink_to("Versions/Current/Helpers", target_is_directory=True)
(framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
(framework / "Chrome Framework").symlink_to("Versions/Current/Chrome Framework")
binary.parent.mkdir(parents=True)
binary.write_bytes(b"synthetic browser executable")
binary.chmod(0o755)
(app / "Contents/Info.plist").write_bytes(b"synthetic app metadata")
print("browser provisioned")
''')
    (package / "sync_api.py").write_text(r'''import os
from pathlib import Path

class _Page:
    def goto(self, url):
        assert url == "about:blank"
    def evaluate(self, expression):
        assert expression == "1 + 1"
        return 2

class _Browser:
    version = "123.0.0.0"
    def new_page(self):
        return _Page()
    def close(self):
        pass

class _Chromium:
    def launch(self, *, headless):
        assert headless is True
        root = Path(os.environ["PLAYWRIGHT_BROWSERS_PATH"])
        executable = root / "chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        assert executable.is_file()
        return _Browser()

class _Manager:
    def __enter__(self):
        class _Playwright:
            chromium = _Chromium()
        return _Playwright()
    def __exit__(self, *_args):
        return False

def sync_playwright():
    return _Manager()
''')
    dist_info = fake_site / "playwright-1.63.0.dist-info"
    dist_info.mkdir()
    (dist_info / "METADATA").write_text("Metadata-Version: 2.1\nName: playwright\nVersion: 1.63.0\n")

    os.environ["XDG_STATE_HOME"] = str(state_home)
    asset_root = capabilities.default_browser_asset_dir()
    assert not asset_root.exists(), "cold-cache fixture must begin without browser assets"
    repo = base / "repo"
    (repo / ".ownframework-loop/run").mkdir(parents=True)
    cache = base / "repo-cache"

    def invoke_supported_installer():
        env = dict(os.environ)
        env["PLAYWRIGHT_BROWSERS_PATH"] = str(asset_root)
        env["PYTHONPATH"] = str(fake_site)
        completed = subprocess.run(
            [sys.executable, "-m", "playwright", "install", "chromium"],
            env=env, text=True, capture_output=True, check=False,
        )
        assert completed.returncode == 0, completed.stderr or completed.stdout
        return completed.stdout.strip()

    original_resolvable = capabilities._playwright_resolvable
    capabilities._playwright_resolvable = lambda: (True, "test-local Playwright installer")
    try:
        sys.path.insert(0, str(fake_site))
        import importlib
        importlib.invalidate_caches()

        def probe(expected_assets, expected_proof):
            inventory = capabilities.probe_host_capabilities()
            browser = next(
                item for item in inventory["capabilities"]
                if item["name"] == "browser.playwright.chromium"
            )
            assert browser["assets_installed"] is expected_assets, browser
            assert browser["runtime_proven"] is expected_proof, browser

        assert "browser provisioned" in invoke_supported_installer()
        probe(True, False)

        canary_path = Path(os.environ["OFLOOP_ROOT"]) / "tests/canary/browser_canary.py"
        spec = importlib.util.spec_from_file_location("ofloop_test_browser_canary", canary_path)
        canary = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(canary)

        def run_canary():
            old_argv = sys.argv
            output = io.StringIO()
            try:
                sys.argv = [str(canary_path), "--write-proof"]
                with contextlib.redirect_stdout(output):
                    assert canary.main() == 0, output.getvalue()
            finally:
                sys.argv = old_argv
            result = json.loads(output.getvalue())
            assert result["ok"] is True, result
            assert result["proof_path"]
            return result

        first_canary = run_canary()
        probe(True, True)

        def preflight():
            for role in ("builder", "reviewer"):
                resolved = capabilities.resolve_capabilities(
                    ["browser.playwright.chromium"],
                    canonical_repo=repo,
                    role=role,
                    repo_cache_root=cache,
                    packet_network_allowlist=[],
                )
                browser = resolved["resolved"][0]["browser"]
                assert browser["runtime_proven"] is True, (role, browser)
                assert browser["browser_asset_merkle_sha256"] == first_canary["browser_asset_merkle_sha256"], (role, browser, first_canary)
                assert resolved["environment"]["PLAYWRIGHT_BROWSERS_PATH"] == str(asset_root.resolve()), resolved["environment"]

        preflight()
        first_digest = capabilities.browser_asset_merkle_sha256(asset_root)
        assert "already provisioned" in invoke_supported_installer()
        assert capabilities.browser_asset_merkle_sha256(asset_root) == first_digest
        run_canary()
        preflight()
        print("SUPPORTED_INSTALLER_IDEMPOTENT=PASS")

        # Delete only this disposable fixture's browser-assets cache. Its
        # commissioning proof remains durable and must not authorize absence.
        shutil.rmtree(asset_root.parent)
        assert not asset_root.exists()
        probe(False, False)
        assert "browser provisioned" in invoke_supported_installer()
        second_digest = capabilities.browser_asset_merkle_sha256(asset_root)
        assert second_digest == first_digest
        run_canary()
        probe(True, True)
        preflight()
        print("COLD_CACHE_DELETE_REGENERATE_PROOF_PREFLIGHT=PASS")

        framework = asset_root / "chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/Frameworks/Google Chrome for Testing Framework.framework"
        helper_link = framework / "Helpers"
        helper_link.unlink()
        helper_link.symlink_to("Versions/123/Helpers", target_is_directory=True)
        stale, reason = capabilities._browser_runtime_proven(
            "browser.playwright.chromium", expected_asset_root=asset_root
        )
        assert not stale and "asset drift" in reason, (stale, reason)
        helper_link.unlink()
        helper_link.symlink_to("Versions/Current/Helpers", target_is_directory=True)
        preflight()
        print("PREFLIGHT_REJECTS_SYMLINK_STRUCTURE_DRIFT=PASS")
    finally:
        capabilities._playwright_resolvable = original_resolvable
        try:
            sys.path.remove(str(fake_site))
        except ValueError:
            pass

print("BROWSER_ASSET_COLD_CACHE_REGRESSION=PASS")
PY

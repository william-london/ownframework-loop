"""Pytest plugin: disable cacheprovider so test runs never create .pytest_cache.

Auto-loaded via PYTEST_PLUGINS env var (pytest >= 8.x). Belt-and-braces for
the hermetic runtime env: even if a validation command forgets to add
``-p no:cacheprovider`` to PYTEST_ADDOPTS, this plugin still prevents the
cacheplugin from writing ``.pytest_cache`` into the exact-SHA worktree.
"""


def pytest_configure(config):  # noqa: D401
    try:
        config.pluginmanager.unregister(name="cacheprovider")
    except Exception:
        pass

"""Smoke test for broker SSRF primitives (pure-function).

Not run by the official test suite; this is a fast self-contained check
the developer can run while iterating on the broker. Asserts that every
forbidden address range refused in the broker's first slice matches the
public-IP-only intent of the ADR.
"""
from __future__ import annotations

import socket
import sys
from pathlib import Path

BROKER_PATH = Path("bin/ofloop-research-broker")


def _load_broker_module():
    """Load the broker source as a regular module (strip the shebang line)."""
    import types
    source = BROKER_PATH.read_text(encoding="utf-8")
    if source.startswith("#!"):
        _, _, source = source.partition("\n")
    mod = types.ModuleType("ofloop_research_broker")
    sys.modules["ofloop_research_broker"] = mod
    exec(compile(source, str(BROKER_PATH), "exec"), mod.__dict__)
    return mod


def main() -> int:
    m = _load_broker_module()
    failures = 0

    def check(label, got, expected):
        nonlocal failures
        ok = got == expected
        if not ok:
            failures += 1
        print(f'{"PASS" if ok else "FAIL"} {label}: got={got!r} expected={expected!r}')

    cases_v4 = [
        ("127.0.0.1", socket.AF_INET, "127.0.0.1", "loopback"),
        ("10.1.2.3", socket.AF_INET, "10.1.2.3", "rfc1918"),
        ("172.20.0.1", socket.AF_INET, "172.20.0.1", "rfc1918"),
        ("192.168.1.1", socket.AF_INET, "192.168.1.1", "rfc1918"),
        ("169.254.169.254", socket.AF_INET, "169.254.169.254", "link-local"),
        ("100.64.0.1", socket.AF_INET, "100.64.0.1", "carrier-grade-nat"),
        ("0.0.0.0", socket.AF_INET, "0.0.0.0", "unspecified"),
        ("224.0.0.1", socket.AF_INET, "224.0.0.1", "multicast-or-broadcast"),
        ("8.8.8.8", socket.AF_INET, "8.8.8.8", None),
        ("1.1.1.1", socket.AF_INET, "1.1.1.1", None),
    ]
    for label, fam, addr, expected in cases_v4:
        check(label, m._forbidden_address(fam, addr), expected)

    cases_v6 = [
        ("::1", socket.AF_INET6, "::1", "ipv6-loopback"),
        ("fc00::1", socket.AF_INET6, "fc00::1", "ipv6-unique-local"),
        ("fe80::1", socket.AF_INET6, "fe80::1", "ipv6-link-local"),
        ("ff02::1", socket.AF_INET6, "ff02::1", "ipv6-multicast"),
        ("2606:4700:4700::1111", socket.AF_INET6, "2606:4700:4700::1111", None),
    ]
    for label, fam, addr, expected in cases_v6:
        check("v6 " + label, m._forbidden_address(fam, addr), expected)

    url_ok = [
        ("https://example.com/path", "https", "example.com", None),
        ("http://example.com:8080/", "http", "example.com", 8080),
    ]
    for url, scheme, host, port in url_ok:
        try:
            u = m._parse_url(url)
            ok = (u.scheme == scheme and u.host == host and u.port == port)
            print(f'{"PASS" if ok else "FAIL"} URL {url}: parsed correctly')
            if not ok:
                failures += 1
        except Exception as exc:
            print(f"FAIL URL {url}: unexpected exception {type(exc).__name__}: {exc}")
            failures += 1

    url_bad = [
        ("https://user:pass@example.com/", "ForbiddenHeader"),
        ("https://user@example.com/", "ForbiddenHeader"),
        ("file:///etc/passwd", "InvalidRequest"),
        ("data:text/plain,foo", "InvalidRequest"),
        ("ftp://example.com/", "InvalidRequest"),
        ("https://", "InvalidRequest"),
    ]
    for url, expected_err in url_bad:
        try:
            m._parse_url(url)
            print(f"FAIL URL {url}: expected {expected_err} got OK")
            failures += 1
        except m.InvalidRequest as exc:
            ok = expected_err == "InvalidRequest"
            print(
                f'{"PASS" if ok else "FAIL"} URL {url}: refused with InvalidRequest'
            )
            if not ok:
                failures += 1
        except m.ForbiddenHeader as exc:
            ok = expected_err == "ForbiddenHeader"
            print(
                f'{"PASS" if ok else "FAIL"} URL {url}: refused with ForbiddenHeader'
            )
            if not ok:
                failures += 1
        except Exception as exc:
            print(f"FAIL URL {url}: unexpected exception {type(exc).__name__}: {exc}")
            failures += 1

    print(f"--- summary: {failures} failure(s) ---")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

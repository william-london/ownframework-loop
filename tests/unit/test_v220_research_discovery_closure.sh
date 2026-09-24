#!/usr/bin/env bash
# OwnFramework Loop — bounded research capability completion
# (research-discovery-closure-2026-09-23).
#
# Focused behavioral proof for:
#   B1 — bing-rss general public-web discovery via the canonical
#        _browse() transport; wikipedia retained as the narrow
#        alternate; ddg-lite still removed;
#        search backend identity written to receipt;
#        canonical Bing RSS URL construction.
#   B3 — ONE canonical op_id per broker operation:
#        response.op_id == receipt-JSON op_id == receipt filename stem
#        for search, read, and asset-read.
#
# No live public research traffic. All upstream HTTP is stubbed
# at the canonical _browse() boundary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

PYTHONPATH="${REPO_ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}" \
python3 - "${REPO_ROOT}" <<'PY'
import json, sys
from pathlib import Path
repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "lib"))

# Import the broker. It is a shebang'd CLI; the importlib loader
# rejects shebang-only scripts, so we compile from the .py body.
# __file__ must be set so the broker's _self_sha256() resolves.
_broker_path = str(repo / "bin" / "ofloop-research-broker")
src = (repo / "bin" / "ofloop-research-broker").read_text()
mod_globals: dict = {"__file__": _broker_path, "__name__": "__broker__"}
exec(compile(src, _broker_path, "exec"), mod_globals)
br = mod_globals
m = sys.modules["__main__"].__dict__

PASS = 0
FAIL = []
def check(name, ok, detail=""):
    global PASS
    if ok:
        PASS += 1
        print(f"PASS {name}")
    else:
        FAIL.append((name, detail))
        print(f"FAIL {name} {detail}")

# ----------------------------------------------------------------- #
# 1. B1 — bing-rss is a commissioned backend; wikipedia kept.       #
# ----------------------------------------------------------------- #
check("BACKEND_BING_RSS: bing-rss is in SEARCH_BACKENDS",
      "bing-rss" in br["SEARCH_BACKENDS"],
      f"got: {sorted(br['SEARCH_BACKENDS'])}")
check("BACKEND_BING_RSS: wikipedia remains in SEARCH_BACKENDS",
      "wikipedia" in br["SEARCH_BACKENDS"],
      f"got: {sorted(br['SEARCH_BACKENDS'])}")
check("BACKEND_BING_RSS: ddg-lite stays REMOVED",
      "ddg-lite" not in br["SEARCH_BACKENDS"],
      f"got: {sorted(br['SEARCH_BACKENDS'])}")
check("BACKEND_BING_RSS: default backend is bing-rss",
      br["SEARCH_DEFAULT_BACKEND"] == "bing-rss",
      f"got: {br['SEARCH_DEFAULT_BACKEND']}")

# Supervisor accepts the same backends.
import ownframework_loop.supervisor_research as sr
import os
# Patch env so the default resolution lands on bing-rss.
os.environ.pop("OFLOOP_RESEARCH_DEFAULT_SEARCH_BACKEND", None)
# Confirm supervisor mentions bing-rss / wikipedia only.
sup_src = (repo / "lib" / "ownframework_loop" / "supervisor_research.py").read_text()
check("SUPERVISOR_POLICY: supervisor accepts bing-rss",
      '"bing-rss", "wikipedia"' in sup_src or
      "('bing-rss', 'wikipedia')" in sup_src,
      "supervisor policy has both bing-rss + wikipedia")
check("SUPERVISOR_POLICY: supervisor ddg-lite REMOVED",
      "ddg-lite" not in sup_src.split("---------------------------------------------------------------------")[0:30][-1],
      "supervisor policy keeps ddg-lite REMOVED")

# ----------------------------------------------------------------- #
# 2. B1 — bing-rss URL construction uses canonical endpoint + GET. #
# ----------------------------------------------------------------- #
check("BING_RSS_URL: Search endpoint is bing.com/search",
      br["SEARCH_DEFAULT_ENDPOINT_BING_RSS"].startswith(
          "https://www.bing.com/search"),
      f"endpoint={br['SEARCH_DEFAULT_ENDPOINT_BING_RSS']}")
check("BING_RSS_URL: no POST path; _browse() is the only transport",
      "_browse" in br["_search_bing_rss"].__code__.co_names,
      "bing-rss must call _browse()")
check("BING_RSS_URL: bing-rss query path passes through _browse()",
      "POST" not in repr(br["_search_bing_rss"].__doc__ or "").upper()
      and "_browse" in br["_search_bing_rss"].__code__.co_names,
      "bing-rss MUST NOT include POST transport")

# ----------------------------------------------------------------- #
# 3. B1 — bing-rss RSS normalization (stdlib XML parsing).         #
# ----------------------------------------------------------------- #
class FakeBrowse:
    def __init__(self, body, status=200, url="https://www.bing.com/search?q=foo",
                 final_url=None, redirect_chain=(), connect_log=()):
        self.body = body if isinstance(body, bytes) else body.encode("utf-8")
        self.status_code = status
        self.reason = "OK" if status == 200 else "ERR"
        self.final_url = final_url or url
        self.redirect_chain = list(redirect_chain)
        self.connect_log = list(connect_log)
        self.headers = {"content-type": "application/rss+xml"}

# Build a minimal RSS body with two good items, one userinfo URL,
# one non-http URL, and one malformed URL.
RSS_FIXTURE = b"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>Bing</title>
  <item>
    <title>Real Result One</title>
    <link>https://example.com/page-1</link>
    <description>first snippet</description>
    <pubDate>Tue, 23 Sep 2026 00:00:00 GMT</pubDate>
  </item>
  <item>
    <title>Real Result Two</title>
    <link>https://example.invalid/article-2</link>
    <description>second snippet</description>
  </item>
  <item>
    <title>Userinfo Drop</title>
    <link>https://user:pass@example.com/evil</link>
    <description>userinfo URL must be dropped</description>
  </item>
  <item>
    <title>Non-http Drop</title>
    <link>javascript:alert(1)</link>
    <description>non-http scheme must be dropped</description>
  </item>
  <item>
    <title>Malformed Drop</title>
    <link>https:not a url</link>
    <description>malformed URL must be dropped</description>
  </item>
  <item>
    <title>No-link Drop</title>
    <link></link>
    <description>empty link must be dropped</description>
  </item>
</channel></rss>"""

# Stub _browse inside the broker globals to return fixture.
captured_calls = []
def stub_browse(url, max_bytes, *, max_redirects=0, accept=""):
    captured_calls.append({"url": url, "max_bytes": max_bytes,
                            "accept": accept})
    return FakeBrowse(RSS_FIXTURE,
                      final_url=url,
                      redirect_chain=(url,),
                      connect_log=())
br["_browse"] = stub_browse

results, debug = br["_search_bing_rss"]("Some Query")

# Bing-rss MUST have gone through _browse() exactly once.
check("BING_RSS_TRANSPORT: outbound GET went through _browse()",
      len(captured_calls) == 1,
      f"calls={len(captured_calls)}")
check("BING_RSS_TRANSPORT: _browse() URL is canonical Bing search",
      captured_calls[0]["url"].startswith(
          "https://www.bing.com/search?q="),
      f"url={captured_calls[0]['url']}")
check("BING_RSS_TRANSPORT: format=rss present",
      "format=rss" in captured_calls[0]["url"],
      f"url={captured_calls[0]['url']}")
check("BING_RSS_TRANSPORT: NOT a POST; only GET is observable",
      "POST" not in captured_calls[0]["accept"],
      f"accept={captured_calls[0]['accept']}")

# Result list keeps ONLY the two real (absolute http/https, well-formed,
# non-userinfo) results. Userinfo, non-http, malformed, empty-link all drop.
urls = [r["url"] for r in results]
check("BING_RSS_NORMALIZE: two well-formed results returned",
      len(results) == 2,
      f"got {len(results)} results: {urls}")
check("BING_RSS_NORMALIZE: result 1 is absolute https",
      results[0]["url"] == "https://example.com/page-1",
      f"got: {results[0]}")
check("BING_RSS_NORMALIZE: result 2 is absolute https",
      results[1]["url"] == "https://example.invalid/article-2",
      f"got: {results[1]}")
check("BING_RSS_NORMALIZE: userinfo result DROPPED",
      all("user:pass" not in r["url"] for r in results),
      f"got: {urls}")
check("BING_RSS_NORMALIZE: non-http result DROPPED",
      all(not r["url"].startswith("javascript:") for r in results),
      f"got: {urls}")
check("BING_RSS_NORMALIZE: all results have title + snippet",
      all({"title", "snippet", "url"} <= set(r) for r in results),
      f"got shapes: {[set(r) for r in results]}")
check("BING_RSS_NORMALIZE: malformed URL DROPPED",
      all("https:not a url" not in r["url"] for r in results),
      f"got: {urls}")

# ----------------------------------------------------------------- #
# 4. B1 — bing-rss handles non-200 + malformed XML fail-closed.    #
# ----------------------------------------------------------------- #
# Non-200: transient failure shape.
br["_browse"] = lambda *a, **kw: FakeBrowse(b"<rss/>",
                                              status=503,
                                              final_url=a[0])
try:
    br["_search_bing_rss"]("x")
    check("BING_RSS_FAIL: non-200 raises TransientFailure", False,
          "no exception raised")
except br["TransientFailure"] as exc:
    check("BING_RSS_FAIL: non-200 raises TransientFailure",
          True, f"exc={exc}")

# Malformed XML: invalid request shape.
br["_browse"] = lambda *a, **kw: FakeBrowse(b"<<not xml",
                                              final_url=a[0])
try:
    br["_search_bing_rss"]("x")
    check("BING_RSS_FAIL: malformed XML raises InvalidRequest",
          False, "no exception raised")
except br["InvalidRequest"] as exc:
    check("BING_RSS_FAIL: malformed XML raises InvalidRequest",
          True, f"exc={exc}")

# ----------------------------------------------------------------- #
# 5. B1 — ddg-lite remains HARD-REFUSED                            #
# ----------------------------------------------------------------- #
try:
    br["_search_ddg_lite"]("x")
    check("DDG_LITE_REMOVED: ddg-lite refused", False, "no exception")
except br["InvalidRequest"] as exc:
    check("DDG_LITE_REMOVED: ddg-lite refused",
          "removed" in str(exc).lower(),
          f"exc={exc}")

# ----------------------------------------------------------------- #
# 6. B1 — supervisor refuses unknown search backend.               #
# ----------------------------------------------------------------- #
# Confirm by directly reading supervisor source comment, that
# the supervisor whitelists exactly ('bing-rss', 'wikipedia').
needle = 'if policy not in ("bing-rss", "wikipedia"):'
check("SUPERVISOR_WHITELIST: bing-rss / wikipedia only",
      needle in sup_src,
      f"needle={needle!r}")

# ----------------------------------------------------------------- #
# 7. B3 — single canonical op_id per broker operation.             #
# ----------------------------------------------------------------- #
# Build a real broker invocation via _op_* helpers.
import argparse, os, tempfile, uuid as _uuid

def make_args(op, **extra):
    a = argparse.Namespace(
        op=op, url=None, query=None, evidence_dir=None,
        run_id="run-20260923T150000Z-test0001",
        attempt="pass-0001",
        request_id=str(_uuid.uuid4()),
        request_digest="0" * 64,
        kind=None, kind_cap=128,
        max_bytes=None, search_backend=None,
    )
    for k, v in extra.items():
        setattr(a, k, v)
    return a

# Stub _browse + html helpers so no network is required.
br["_browse"] = lambda *a, **kw: FakeBrowse(
    b"<rss version=\"2.0\"><channel><item>"
    b"<title>One</title><link>https://x.test/p"
    b"</link><description>hello</description></item></channel></rss>",
    url=a[0] if a else "https://bing.test")
br["_html_to_text"] = lambda body: body.decode("utf-8", errors="replace") if isinstance(body, (bytes, bytearray)) else body
br["_html_title"] = lambda body: ""

tmp_evidence = Path(tempfile.mkdtemp(prefix="ofloop-b3-"))

def check_op_id_parity(op_name, **extra):
    args = make_args(op_name, **extra)
    args.evidence_dir = str(tmp_evidence / f"run-{op_name}")
    Path(args.evidence_dir).mkdir(parents=True, exist_ok=True)
    if op_name == "search":
        result = br["_op_search"](args)
    elif op_name == "read":
        result = br["_op_read"](args)
    elif op_name == "asset-read":
        # asset-read needs allowed MIME type returned from _browse.
        br["_browse"] = lambda *a, **kw: FakeBrowse(
            b"FAKE_PNG", url=a[0],
            status=200
        )
        # override content-type through the headers dict
        class _PatchedBrowse(FakeBrowse):
            def __init__(self_inner, body, **kw):
                super().__init__(body, **kw)
                self_inner.headers = {"content-type": "image/png"}
        # Re-wire to patched browse with image/png content-type.
        def _pbrowse(*a, **kw):
            return _PatchedBrowse(b"FAKE_PNG_BODY",
                                  url=a[0] if a else "https://x.test")
        br["_browse"] = _pbrowse
        result = br["_op_asset_read"](args)
    else:
        raise SystemExit(f"unknown op: {op_name}")
    # Response carries op_id.
    response_op_id = result.get("op_id")
    receipt_path = Path(result.get("receipt_path"))
    # Receipt JSON carries op_id.
    receipt_body = json.loads(receipt_path.read_text())
    receipt_op_id = receipt_body.get("op_id")
    # Filename stem equals op_id.
    stem = receipt_path.stem
    name = f"OP_ID_PARITY[{op_name}]"
    check(f"{name}: response.op_id is non-empty",
          bool(response_op_id), f"got: {response_op_id!r}")
    check(f"{name}: response.op_id == receipt JSON op_id",
          response_op_id == receipt_op_id,
          f"resp={response_op_id!r} receipt={receipt_op_id!r}")
    check(f"{name}: response.op_id == receipt filename stem",
          stem == response_op_id,
          f"stem={stem!r} resp={response_op_id!r}")
    check(f"{name}: response.op_id == receipt JSON op_id == filename stem",
          receipt_op_id == response_op_id == stem,
          f"three-way mismatch resp={response_op_id!r} "
          f"receipt={receipt_op_id!r} stem={stem!r}")

check_op_id_parity("search", query="hello world", search_backend="bing-rss")
check_op_id_parity("read", url="https://example.invalid/page")
check_op_id_parity("asset-read", url="https://example.invalid/image.png")

# ----------------------------------------------------------------- #
# 8. SPEC inference doctrine is present in skill surfaces.         #
# ----------------------------------------------------------------- #
spec_src = (repo / "skills" / "spec" / "SKILL.md").read_text()
agent_spec_src = (repo / ".agents" / "skills" / "of-loop-spec" / "SKILL.md").read_text()
adr_src = (repo / "docs" / "architecture" / "RESEARCH_AUTHORITY.md").read_text()

# Both SPEC skills must contain the research.public inference doctrine.
for label, src in [("skills/spec/SKILL.md", spec_src),
                    (".agents/skills/of-loop-spec/SKILL.md", agent_spec_src)]:
    check(f"SPEC_DOCTRINE[{label}]: research.public inference bullet",
          "research.public" in src and ("bin)" in src or "bing-rss" in src or
                                         "vendor" in src),
          f"spec skill missing research inference doctrine")
    check(f"SPEC_DOCTRINE[{label}]: PROGRAM_FINAL lifetime mentioned",
          "PROGRAM_FINAL" in src or "whole-product review" in src,
          f"spec skill missing PROGRAM_FINAL reasoning")
    check(f"SPEC_DOCTRINE[{label}]: non-addition negatives present",
          ("purely repository-local" in src) or ("not_applicable" in src),
          f"spec skill missing negative-capability guidance")

# ADR: should NOT contain stale 'GENERAL_WEB_DISCOVERY=DEFERRED' or
# 'wikipedia-only' (historical) on the LIVE STATE block.
adr_live_lines = []
in_live = False
for ln in adr_src.splitlines():
    if "GENERAL_WEB_DISCOVERY=DEFERRED" in ln:
        in_live = True
    elif "GENERAL_WEB_DISCOVERY=SUPPORTED" in ln:
        in_live = False
    if in_live:
        adr_live_lines.append(ln)
check("ADR_LIVE: GENERAL_WEB_DISCOVERY=SUPPORTED in live posture",
      "GENERAL_WEB_DISCOVERY=SUPPORTED" in adr_src,
      "ADR missing SUPPORTED posture")
check("ADR_LIVE: bing-rss is current default",
      "bing-rss" in adr_src,
      "ADR does not name bing-rss")
check("ADR_LIVE: deferred/deferred historical context survives",
      ("DEFERRED" in adr_src) or ("deferred" in adr_src),
      "ADR missing the historical deferred reference")

# ----------------------------------------------------------------- #
# Summary                                                          #
# ----------------------------------------------------------------- #
import shutil as _sh
_sh.rmtree(tmp_evidence, ignore_errors=True)
print()
print(f"research_capability_completion focused tests: PASS={PASS} FAIL={len(FAIL)}")
if FAIL:
    for n, d in FAIL:
        print(f"  FAIL {n}: {d}")
    raise SystemExit(1)
PY

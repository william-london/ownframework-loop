#!/usr/bin/env bash
# Case 27: diff-line limit.
# Case 28: changed-file limit.

set -uo pipefail
. "$(dirname "$0")/../_helpers.sh"

python3 - <<'PY'
import sys, os, tempfile, subprocess
from pathlib import Path
sys.path.insert(0, "/Users/mr.mrs.london/projects/plugins/ownframework-loop/lib")
from ownframework_loop import receipts, guards

# Build a tiny git repo, add a candidate commit, compute diff stats.
with tempfile.TemporaryDirectory() as td:
    d = Path(td)
    subprocess.run(["git", "-C", str(d), "init", "-b", "master"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(d), "config", "user.email", "t@t"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(d), "config", "user.name", "t"], check=True, capture_output=True)
    (d / "seed.txt").write_text("line1\nline2\n")
    subprocess.run(["git", "-C", str(d), "add", "."], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(d), "commit", "-m", "init"], check=True, capture_output=True)
    base = subprocess.run(["git", "-C", str(d), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()

    # Add 6 files, ~80 lines total.
    for i in range(6):
        (d / f"f{i}.txt").write_text("\n".join(f"line{j}" for j in range(15)) + "\n")
    subprocess.run(["git", "-C", str(d), "add", "."], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(d), "commit", "-m", "more"], check=True, capture_output=True)
    head = subprocess.run(["git", "-C", str(d), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()

    stats = receipts.compute_diff_stats(d, base, head)
    assert stats["files_changed"] == 6, f"expected 6 files, got {stats}"
    assert stats["added_lines"] >= 80, f"expected ~80 added, got {stats}"
    print(f"  PASS: diff stats computed ({stats})")

    # Build a packet that requires max_diff_lines=400, max_files_changed=12.
    # This candidate fits.
    over_diff = stats["added_lines"] + stats["removed_lines"] > 400
    over_files = stats["files_changed"] > 12
    assert not over_diff, "expected candidate within diff budget"
    assert not over_files, "expected candidate within file budget"
    print("  PASS: candidate within budget")

    # Now create an over-budget candidate.
    big_path = d / "big.txt"
    big_path.write_text("x\n" * 600)
    subprocess.run(["git", "-C", str(d), "add", "."], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(d), "commit", "-m", "big"], check=True, capture_output=True)
    head2 = subprocess.run(["git", "-C", str(d), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    stats2 = receipts.compute_diff_stats(d, base, head2)
    assert stats2["added_lines"] > 400, f"expected over budget, got {stats2}"
    print(f"  PASS: large commit detected as over-budget ({stats2['added_lines']} lines)")

print("ALL PASS")
PY

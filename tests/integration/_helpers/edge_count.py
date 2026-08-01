"""Count shell_edges for the repaired multiline test."""
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
from pathlib import Path
from ownframework_loop.static_checks import shell_edges
edges = shell_edges(Path(sys.argv[1] + "/tests/integration/test_hook_multiline_bash.sh"))
print(len(edges))

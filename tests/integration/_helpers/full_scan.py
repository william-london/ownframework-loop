"""Scan the canonical ROOT, return reverse_edges count + acyclic."""
import json, sys
sys.path.insert(0, sys.argv[1] + "/lib")
from pathlib import Path
from ownframework_loop.static_checks import scan
data = scan(Path(sys.argv[1]))
print(json.dumps({"reverse": len(data["reverse_edges"]), "acyclic": data["acyclic"]}))

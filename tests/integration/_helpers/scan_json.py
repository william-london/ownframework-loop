"""Emit JSON scan of a tree given ROOT and TREE paths."""
import json, sys
sys.path.insert(0, sys.argv[1] + "/lib")
from pathlib import Path
from ownframework_loop.static_checks import scan
print(json.dumps(scan(Path(sys.argv[2]))))

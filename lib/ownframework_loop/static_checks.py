"""Deterministic executable-edge checks for the release hierarchy.
v0.3.5 (A6-F06): scan covers tests/, hooks/, skills/, agents/, bin/,
release_gate.sh, validate.sh, install.sh. Only scripts in the
explicit allow-list may invoke the release hierarchy by literal
command invocation (not by path-string reference).
"""
from __future__ import annotations

import ast
import re
from pathlib import Path

# Scripts allowed to invoke the release hierarchy by literal basename.
RELEASE_HIERARCHY_BASENAMES = ("release_gate.sh", "validate.sh", "install.sh", "run_all.sh")

# Scripts that legitimately orchestrate these (allow-list).
ORCHESTRATOR_ALLOWLIST = {
    "release_gate.sh",
    "validate.sh",
    "install.sh",
    "tests/run_all.sh",
}


def _test_targeted_script(path: Path) -> str | None:
    """Return the release hierarchy basename this test is allowed to reference.

    Tests whose names start with test_<stem>_… or are exactly test_<stem>.sh
    are testing that script, so path-string references are legitimate.
    """
    name = path.name
    for basename in RELEASE_HIERARCHY_BASENAMES:
        stem = basename.replace(".sh", "")
        if name.startswith(f"test_{stem}_") or name == f"test_{stem}.sh":
            return basename
    return None


def _active_shell(line: str) -> str:
    stripped = line.lstrip()
    if not stripped or stripped.startswith("#"):
        return ""
    quote = None
    out = []
    for i, char in enumerate(line):
        if char in ('"', "'") and (i == 0 or line[i - 1] != "\\"):
            quote = None if quote == char else (char if quote is None else quote)
        if char == "#" and quote is None and (i == 0 or line[i - 1].isspace()):
            break
        out.append(char)
    return "".join(out)


_VAR_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=(?:[\"']?([^\"' ;]+))")


def shell_edges(path: Path) -> list[tuple[str, str]]:
    edges: list[tuple[str, str]] = []
    variables: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = _active_shell(raw)
        if not line:
            continue
        for name, value in _VAR_RE.findall(line):
            variables[name] = value
        command = re.split(r"[|;&()]", line, maxsplit=1)[0].strip()
        if re.match(r"^(?:eval|nohup|disown)\b", command):
            edges.append((str(path), "unsafe-orchestration"))
        if not command:
            continue
        for basename in RELEASE_HIERARCHY_BASENAMES:
            pat = re.compile(
                r"\b(?:bash|sh|source|\.)\b\s+(?:\S*/)?" + re.escape(basename) + r"\b|"
                r"\./" + re.escape(basename) + r"\b|"
                r"\A" + re.escape(basename) + r"\b"
            )
            if pat.search(command):
                edges.append((str(path), basename))
                break
    return edges


def python_unsafe(path: Path) -> list[str]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError:
        return [f"syntax:{path}"]
    hits: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            fn = node.func
            name = fn.attr if isinstance(fn, ast.Attribute) else (fn.id if isinstance(fn, ast.Name) else "")
            if name == "Popen" and path.name != "process_runner.py":
                hits.append(f"{path}:{getattr(node, 'lineno', 0)}:{name}")
            if name in {"os.system", "system"}:
                hits.append(f"{path}:{getattr(node, 'lineno', 0)}:{name}")
            if isinstance(fn, ast.Attribute) and fn.attr == "run":
                for kw in node.keywords:
                    if kw.arg == "shell" and isinstance(kw.value, ast.Constant) and kw.value.value is True:
                        hits.append(f"{path}:{node.lineno}:shell=True")
    return hits


SCAN_SHELL_GLOBS = (
    "tests/**/*.sh",
    "hooks/*.sh",
    "skills/**/*.sh",
    "agents/**/*.sh",
    "bin/*",
    "release_gate.sh",
    "validate.sh",
    "install.sh",
)

SCAN_PYTHON_GLOBS = (
    "lib/**/*.py",
    "agents/**/*.py",
    "bin/*.py",
    "skills/**/*.py",
)


def scan(root: Path) -> dict[str, object]:
    edges: list[tuple[str, str]] = []
    unsafe: list[str] = []
    seen: set[Path] = set()
    for glob in SCAN_SHELL_GLOBS:
        for path in sorted(root.glob(glob)):
            if path in seen or not path.is_file():
                continue
            seen.add(path)
            if path.suffix == ".sh":
                edges.extend(shell_edges(path))
    for glob in SCAN_PYTHON_GLOBS:
        for path in sorted(root.glob(glob)):
            if path in seen or not path.is_file():
                continue
            seen.add(path)
            unsafe.extend(python_unsafe(path))
    rel_edges = []
    reverse = []
    for path_str, basename in edges:
        try:
            rel = str(Path(path_str).relative_to(root))
        except ValueError:
            rel = path_str
        if rel in ORCHESTRATOR_ALLOWLIST:
            continue
        if _test_targeted_script(Path(rel)):
            continue
        reverse.append((rel, basename))
        rel_edges.append((rel, basename))
    return {"edges": rel_edges, "reverse_edges": reverse, "unsafe": unsafe, "acyclic": not reverse}


def main() -> int:
    import argparse, json
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    result = scan(args.root)
    print(json.dumps(result, indent=2, sort_keys=True))
    print("RELEASE_GATE_CALL_GRAPH=acyclic" if result["acyclic"] else "RELEASE_GATE_CALL_GRAPH=cyclic")
    for basename in RELEASE_HIERARCHY_BASENAMES:
        flag = "1" if any(e[1] == basename for e in result["reverse_edges"]) else "0"
        key = f"TESTS_CALL_{basename.replace('.sh', '').upper()}"
        print(f"{key}={flag}")
    print("REVERSE_ORCHESTRATOR_DEPENDENCIES=0" if not result["reverse_edges"] else "REVERSE_ORCHESTRATOR_DEPENDENCIES=1")
    return 0 if result["acyclic"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

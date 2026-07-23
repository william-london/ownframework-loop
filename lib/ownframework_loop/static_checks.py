"""Deterministic executable-edge checks for the release hierarchy."""
from __future__ import annotations

import ast
import re
from pathlib import Path

TARGETS = ("release_gate.sh", "validate.sh", "tests/run_all.sh")
_EXEC = re.compile(r"(?:^|/)(release_gate\.sh|validate\.sh|run_all\.sh)$")


def _active_shell(line: str) -> str:
    stripped = line.lstrip()
    if not stripped or stripped.startswith("#"):
        return ""
    # Remove comments only when they begin outside a quoted assertion string.
    quote = None
    out = []
    for i, char in enumerate(line):
        if char in "'\"" and (i == 0 or line[i - 1] != "\\"):
            quote = None if quote == char else (char if quote is None else quote)
        if char == "#" and quote is None and (i == 0 or line[i - 1].isspace()):
            break
        out.append(char)
    return "".join(out)


def shell_edges(path: Path) -> list[tuple[str, str]]:
    edges: list[tuple[str, str]] = []
    variables: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = _active_shell(raw)
        if not line:
            continue
        for name, value in re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)=(?:[\"']?([^\"' ;]+))", line):
            variables[name] = value
        # Ignore grep/assertion/documentation operands; command forms remain visible.
        command = re.split(r"[|;&()]", line, maxsplit=1)[0].strip()
        if re.match(r"^(?:eval|nohup|disown)\b", command):
            edges.append((str(path), "unsafe-orchestration"))
        tokens = command.split()
        if not tokens:
            continue
        for token in tokens:
            candidate = variables.get(token.lstrip("$"), token.strip("'\""))
            match = _EXEC.search(candidate)
            if match:
                edges.append((str(path), match.group(1)))
                break
        if re.search(r"\b(?:bash|sh|source|\.)\b", command) and _EXEC.search(command):
            match = _EXEC.search(command)
            if match:
                edges.append((str(path), match.group(1)))
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


def scan(root: Path) -> dict[str, object]:
    edges: list[tuple[str, str]] = []
    unsafe: list[str] = []
    for path in sorted(root.glob("tests/**/*.sh")):
        edges.extend(shell_edges(path))
    for path in sorted(root.glob("**/*.py")):
        unsafe.extend(python_unsafe(path))
    reverse = [edge for edge in edges if edge[1] in TARGETS]
    return {"edges": edges, "reverse_edges": reverse, "unsafe": unsafe, "acyclic": not reverse}


def main() -> int:
    import argparse, json
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    result = scan(args.root)
    print(json.dumps(result, indent=2, sort_keys=True))
    print("RELEASE_GATE_CALL_GRAPH=acyclic" if result["acyclic"] else "RELEASE_GATE_CALL_GRAPH=cyclic")
    print("TESTS_CALL_RELEASE_GATE=0" if not any(e[1] == TARGETS[0] for e in result["reverse_edges"]) else "TESTS_CALL_RELEASE_GATE=1")
    print("TESTS_CALL_VALIDATE=0" if not any(e[1] == TARGETS[1] for e in result["reverse_edges"]) else "TESTS_CALL_VALIDATE=1")
    print("TESTS_CALL_RUN_ALL=0" if not any(e[1] == TARGETS[2] for e in result["reverse_edges"]) else "TESTS_CALL_RUN_ALL=1")
    print("REVERSE_ORCHESTRATOR_DEPENDENCIES=0" if not result["reverse_edges"] else "REVERSE_ORCHESTRATOR_DEPENDENCIES=1")
    return 0 if result["acyclic"] else 1

if __name__ == "__main__":
    raise SystemExit(main())

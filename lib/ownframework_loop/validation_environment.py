"""Deterministic candidate-bound project environment for required validations.

Background
==========

The packet's ``required_validation`` commands may legitimately use
``uv run`` (or any uv-mediated project entry point) to execute project
code against the candidate's declared dependencies. ``uv run`` defaults to
auto-syncing the project environment into ``.venv`` next to the
candidate's ``uv.lock`` — i.e. inside the exact-SHA worktree the
deterministic validator just sealed.

That default breaks several invariants:

1. The builder/reviewer worktrees must remain immutable after sealing;
   an in-worktree ``.venv`` is a tracked-or-ignored-mutable artifact that
   the post-validation cleanliness check must special-case. Reviewer
   immutability is the most important: a polluted reviewer worktree
   invalidates the reviewer's verdict.

2. The builder's ``.venv`` is not authoritative for the reviewer. The
   reviewer is supposed to validate against an environment it
   independently produced from the same ``uv.lock``. Otherwise the
   reviewer is testing the builder's success rather than the candidate.

3. ``uv sync`` failures must be classified correctly. Some are genuine
   validator-owned infrastructure failures (bound uv unavailable or drifted,
   registry unreachable, runtime-cache filesystem refused, provisioning
   timeout). Others are candidate-repairable defects (the builder modified
   ``pyproject.toml`` without regenerating ``uv.lock``; declared a dependency
   that does not exist; produced invalid metadata; etc.). The validator
   distinguishes them so infra failures terminalize as ``BLOCKED`` (no repair
   round burned) and candidate-repairable failures transition to
   ``CHANGES_REQUESTED`` (the next builder pass can fix the metadata mistake).

Design
======

The deterministic validator owns a single project environment per
(candidate, project lock, project metadata) triple. The environment:

  - Lives under the supervisor-owned runtime cache, OUTSIDE the builder
    and reviewer worktrees.
  - Is identified by ``env_id = sha256(candidate_sha || uv_lock_sha256 ||
    project_metadata_sha256)``.
  - Is provisioned once per env_id with the exact frozen ``package.uv``
    executable and accepts cache reuse only when the durable marker proves
    the same frozen identity.
  - Binds downstream validation through ``UV_PROJECT_ENVIRONMENT`` and
    ``VIRTUAL_ENV`` without widening semantic-worker authority.

Failure classification
======================

``provision_project_environment`` returns ``PROVISIONED``,
``CANDIDATE_INVALID``, or ``INFRA_FAILURE``. Ambiguous host/tool failures fail
closed as infra rather than consuming a candidate repair round.
"""
from __future__ import annotations

import hashlib
import json
import errno
import os
import re
import shutil
import shlex
import stat
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import runtime_env, util, validation_network


SCHEMA = "ownframework-loop-validation-environment/v1"


class ValidationEnvironmentError(RuntimeError):
    """Validator/host-side infrastructure failure."""


DEFAULT_PROVISION_TIMEOUT_SECONDS = 600


@dataclass(frozen=True)
class BoundUvIdentity:
    """Exact identity of the bound ``package.uv`` capability."""
    executable: str
    version: str
    executable_sha256: str
    cache_path: str
    cache_scope: str
    network_domains: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "executable": self.executable,
            "version": self.version,
            "executable_sha256": self.executable_sha256,
            "cache_path": self.cache_path,
            "cache_scope": self.cache_scope,
            "network_domains": list(self.network_domains),
        }


def build_bound_uv_identity(
    resolved_item: dict[str, Any],
    *,
    cache_path: str = "",
    cache_scope: str = "",
) -> BoundUvIdentity:
    executable = str(resolved_item.get("executable") or "")
    version = str(resolved_item.get("version") or "")
    sha = str(resolved_item.get("executable_sha256") or "")
    if not executable or not version or not sha:
        raise ValidationEnvironmentError(
            "bound package.uv resolution missing executable/version/sha256; "
            "cannot construct BoundUvIdentity from an untrusted resolution"
        )
    domains = tuple(str(d) for d in (resolved_item.get("network_domains") or ()))
    return BoundUvIdentity(
        executable=executable,
        version=version,
        executable_sha256=sha,
        cache_path=str(cache_path),
        cache_scope=str(cache_scope),
        network_domains=domains,
    )


def verify_bound_uv_identity(bound: BoundUvIdentity) -> None:
    """Re-prove the bound uv identity immediately before any subprocess."""
    if not bound.executable:
        raise ValidationEnvironmentError("bound package.uv executable path is empty")
    _read_bound_executable(bound)


OUTCOME_PROVISIONED = "provisioned"
OUTCOME_CANDIDATE_INVALID = "candidate_invalid"
OUTCOME_INFRA_FAILURE = "infra_failure"
ALL_OUTCOMES = (OUTCOME_PROVISIONED, OUTCOME_CANDIDATE_INVALID, OUTCOME_INFRA_FAILURE)


@dataclass(frozen=True)
class ProvisionOutcome:
    outcome: str
    reason: str
    stderr_excerpt: str
    returncode: int | None
    timed_out: bool
    marker_path: str
    identity: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome,
            "reason": self.reason,
            "stderr_excerpt": self.stderr_excerpt,
            "returncode": self.returncode,
            "timed_out": self.timed_out,
            "marker_path": self.marker_path,
            "identity": self.identity,
        }


UV_MEDIATED_SUBCOMMANDS: tuple[str, ...] = (
    "run", "sync", "exec", "test", "python", "lock",
)

_SHELL_PUNCTUATION = ";|&()<>"
_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", re.DOTALL)
_SHELL_WRAPPERS = frozenset({"env", "command", "exec"})
_SHELL_BOUNDARIES = frozenset({";", "|", "&", "&&", "||", "(", ")", "\n"})
_SHELL_INTERPRETERS = frozenset({"sh", "bash", "dash", "zsh", "ksh"})
_SHELL_COMMAND_PREFIXES = frozenset(
    {"if", "then", "else", "elif", "while", "until", "do", "!"}
)


class ValidationCommandError(ValueError):
    """A validation command cannot be classified without ambiguity."""


def _shell_words(command: str) -> list[tuple[str, int, int, bool]]:
    """Tokenize command words/punctuation while retaining replacement spans.

    This intentionally handles shell quoting and common command separators,
    not shell evaluation. Constructs which can manufacture commands are
    rejected by the uv classifier when they mention uv authority.
    """
    tokens: list[tuple[str, int, int, bool]] = []
    index = 0
    while index < len(command):
        if command[index] == "\n":
            tokens.append(("\n", index, index + 1, True))
            index += 1
            continue
        if command[index].isspace():
            index += 1
            continue
        start = index
        if command[index] in _SHELL_PUNCTUATION:
            char = command[index]
            index += 1
            while index < len(command) and command[index] == char:
                index += 1
            tokens.append((command[start:index], start, index, True))
            continue
        quote: str | None = None
        while index < len(command):
            char = command[index]
            if quote is None:
                if char.isspace() or char in _SHELL_PUNCTUATION:
                    break
                if char in "'\"":
                    quote = char
                elif char == "\\" and index + 1 < len(command):
                    index += 1
            elif quote == "'":
                if char == "'":
                    quote = None
            else:
                if char == quote:
                    quote = None
                elif char == "\\" and index + 1 < len(command):
                    index += 1
            index += 1
        raw = command[start:index]
        if quote is not None:
            raise ValidationCommandError("unclosed quote in validation command")
        try:
            decoded = shlex.split(raw, posix=True)
        except ValueError as exc:
            raise ValidationCommandError("invalid shell quoting") from exc
        if len(decoded) != 1:
            raise ValidationCommandError("ambiguous shell word")
        tokens.append((decoded[0], start, index, False))
    return tokens


def _dynamic_shell_word(value: str) -> bool:
    """Whether a command word can change after shell expansion.

    The tokenizer intentionally does not evaluate shell code.  A dynamic
    command head therefore cannot be proven not to resolve to uv and must not
    be treated as an ordinary unmediated command.
    """
    if value in {"[", "[["}:
        return False
    return any(char in value for char in ("$", "`", "*", "?", "["))


def classify_uv_command(command: str, *, _depth: int = 0) -> str:
    """Return ``none``, ``uv``, or ``ambiguous`` for shell command authority.

    Any direct uv/uvx executable is package-capability mediated. Wrappers
    ``env``, ``command`` and ``exec`` plus leading environment assignments are
    recognized. A uv token in an unsupported shell position, command
    substitution, backtick expression, or ``env -S`` form is ambiguous and
    must be refused at packet admission rather than escaping the binding.
    """
    if _depth > 16:
        return "ambiguous"
    if not command or not command.strip():
        return "none"
    try:
        tokens = _shell_words(command)
    except ValidationCommandError:
        if re.search(r"(?<![A-Za-z0-9_])(?:uvx?|[^\s/'\"]*/uv)(?![A-Za-z0-9_])", command):
            return "ambiguous"
        return "none"

    uv_mentions = [
        index for index, (value, _start, _end, punctuation) in enumerate(tokens)
        if not punctuation and (
            Path(value).name in {"uv", "uvx"}
            or re.search(r"(?<![A-Za-z0-9_])uvx?(?![A-Za-z0-9_])", value)
        )
    ]
    if uv_mentions and "`" in command:
        return "ambiguous"
    if uv_mentions and ("$(" in command or "<(" in command or ">(" in command):
        return "ambiguous"
    if uv_mentions and any(
        not punctuation and value in _SHELL_COMMAND_PREFIXES | {"for", "select"}
        for value, _start, _end, punctuation in tokens
    ):
        # The exact-word rewriter does not interpret compound shell grammar.
        # Refuse rather than claim a frozen uv binding for only one branch.
        return "ambiguous"

    segments: list[list[int]] = [[]]
    for index, (value, _start, _end, punctuation) in enumerate(tokens):
        if punctuation and value in _SHELL_BOUNDARIES:
            segments.append([])
        else:
            segments[-1].append(index)

    direct = False
    command_token_indexes: set[int] = set()
    for segment in segments:
        if not segment:
            continue
        position = 0
        while position < len(segment):
            value = tokens[segment[position]][0]
            if _ASSIGNMENT_RE.match(value):
                position += 1
                continue
            if value in _SHELL_COMMAND_PREFIXES:
                position += 1
                continue
            if value in {"for", "select"}:
                # Their first list is a variable/word header, not a command;
                # the body begins after the following `do` token.
                break
            if value in _SHELL_WRAPPERS:
                wrapper = value
                position += 1
                if wrapper == "env":
                    while position < len(segment):
                        option = tokens[segment[position]][0]
                        if option == "--":
                            position += 1
                            break
                        if option == "-S" or option.startswith("--split-string"):
                            return "ambiguous"
                        if option in {"-i", "--ignore-environment"}:
                            position += 1
                            continue
                        if option in {"-u", "--unset"}:
                            position += 2
                            continue
                        if option.startswith("-"):
                            return "ambiguous"
                        if _ASSIGNMENT_RE.match(option):
                            position += 1
                            continue
                        break
                    continue
                if wrapper == "command" and position < len(segment):
                    option = tokens[segment[position]][0]
                    if option.startswith("-"):
                        if option not in {"-p", "--"}:
                            return "ambiguous"
                        position += 1
                        if option == "--":
                            continue
                    continue
                continue
            if value in {">", ">>", "<", "<<", "<<<"}:
                position += 2
                continue
            if value in {"2>", "2>>", "&>", "&>>"}:
                position += 2
                continue
            # `eval` re-parses data as shell source.  Its eventual executable
            # cannot be bound from the packet's literal command and is refused
            # even when the word `uv` is supplied only by an environment value.
            if Path(value).name == "eval":
                return "ambiguous"
            if _dynamic_shell_word(value):
                return "ambiguous"
            # A nested shell -c is a second command grammar.  Recurse only to
            # distinguish a literal ordinary command from an uv/dynamic form;
            # nested uv itself is refused because the exact-word rewriter below
            # cannot safely rewrite through another shell's quoting layer.
            if Path(value).name in _SHELL_INTERPRETERS:
                for option_index in range(position + 1, len(segment) - 1):
                    option = tokens[segment[option_index]][0]
                    if option == "--command" or (
                        option.startswith("-")
                        and not option.startswith("--")
                        and "c" in option[1:]
                    ):
                        nested = tokens[segment[option_index + 1]][0]
                        nested_classification = classify_uv_command(
                            nested, _depth=_depth + 1
                        )
                        if nested_classification != "none":
                            return "ambiguous"
                        break
            command_token_indexes.add(segment[position])
            if Path(value).name == "uv":
                direct = True
            elif Path(value).name == "uvx":
                return "ambiguous"
            break

    for index in uv_mentions:
        value = tokens[index][0]
        if index not in command_token_indexes:
            return "ambiguous"
        if Path(value).name != "uv":
            return "ambiguous"
    if direct:
        return "uv"
    return "ambiguous" if uv_mentions else "none"


def is_uv_command(command: str) -> bool:
    """Compatibility predicate for unambiguous direct uv invocations."""
    return classify_uv_command(command) == "uv"


def bound_uv_snapshot_dir(
    canonical_repo: Path, run_id: str, bound: BoundUvIdentity,
) -> Path:
    if not re.fullmatch(r"[0-9a-f]{64}", bound.executable_sha256):
        raise ValidationEnvironmentError(
            "bound package.uv SHA-256 must be canonical lowercase hexadecimal"
        )
    return (
        runtime_env.runtime_cache_dir(canonical_repo, run_id, "validation")
        / "tool-bindings" / bound.executable_sha256
    )


def _read_bound_executable(bound: BoundUvIdentity) -> tuple[bytes, int]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(bound.executable, flags)
    except FileNotFoundError as exc:
        raise ValidationEnvironmentError(
            f"bound package.uv executable disappeared: {bound.executable}"
        ) from exc
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise ValidationEnvironmentError(
                f"bound package.uv executable is now a symlink: {bound.executable}"
            ) from exc
        raise ValidationEnvironmentError(
            f"bound package.uv executable cannot be opened safely: {exc}"
        ) from exc
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or not (info.st_mode & 0o111)
            or info.st_size > 128 * 1024 * 1024
        ):
            raise ValidationEnvironmentError(
                "bound package.uv executable is not a bounded regular executable file"
            )
        digest = hashlib.sha256()
        chunks: list[bytes] = []
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            chunks.append(block)
        if digest.hexdigest() != bound.executable_sha256:
            raise ValidationEnvironmentError(
                "CAPABILITY_DRIFT: bound package.uv SHA mismatch"
            )
        return b"".join(chunks), info.st_mode & 0o777
    finally:
        os.close(fd)


def snapshot_bound_uv(
    canonical_repo: Path, run_id: str, bound: BoundUvIdentity,
) -> tuple[Path, Path]:
    """Atomically freeze verified uv bytes outside the candidate worktree."""
    payload, mode = _read_bound_executable(bound)
    directory = bound_uv_snapshot_dir(canonical_repo, run_id, bound)
    for parent in (directory.parent, directory):
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = parent.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise ValidationEnvironmentError(
                "package.uv snapshot directory is not a real directory"
            )
        if hasattr(os, "getuid") and info.st_uid != os.getuid():
            raise ValidationEnvironmentError(
                "package.uv snapshot directory has unexpected ownership"
            )
        os.chmod(parent, 0o700)
    executable = directory / "uv"
    try:
        info = executable.lstat()
    except FileNotFoundError:
        info = None
    if info is not None:
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise ValidationEnvironmentError(
                "bound package.uv snapshot path is not a regular file"
            )
        try:
            existing_bound = BoundUvIdentity(
                executable=str(executable), version=bound.version,
                executable_sha256=bound.executable_sha256,
                cache_path=bound.cache_path, cache_scope=bound.cache_scope,
                network_domains=bound.network_domains,
            )
            _read_bound_executable(existing_bound)
        except ValidationEnvironmentError:
            raise ValidationEnvironmentError(
                "CAPABILITY_DRIFT: existing package.uv snapshot contradicts frozen bytes"
            ) from None
        return executable, directory

    temporary = directory / f".uv.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fchmod(fd, (mode & 0o111) | 0o400)
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.link(temporary, executable)
    except FileExistsError:
        if _sha256_file(executable) != bound.executable_sha256:
            raise ValidationEnvironmentError(
                "CAPABILITY_DRIFT: concurrent package.uv snapshot collision"
            )
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    try:
        _read_bound_executable(BoundUvIdentity(
            executable=str(executable), version=bound.version,
            executable_sha256=bound.executable_sha256,
            cache_path=bound.cache_path, cache_scope=bound.cache_scope,
            network_domains=bound.network_domains,
        ))
    except ValidationEnvironmentError as exc:
        raise ValidationEnvironmentError(
            "package.uv snapshot digest verification failed"
        ) from exc
    return executable, directory


def rewrite_bound_uv_tokens(
    command: str, *, expected_executable: str, snapshot_executable: Path,
    cwd: Path,
) -> str:
    """Rewrite only direct absolute/relative uv executable words to snapshot."""
    tokens = _shell_words(command)
    edits: list[tuple[int, int]] = []
    segments: list[list[int]] = [[]]
    for index, (value, _start, _end, punctuation) in enumerate(tokens):
        if punctuation and value in _SHELL_BOUNDARIES:
            segments.append([])
        else:
            segments[-1].append(index)
    for segment in segments:
        position = 0
        while position < len(segment):
            value = tokens[segment[position]][0]
            if _ASSIGNMENT_RE.match(value):
                position += 1
                continue
            if value in _SHELL_WRAPPERS:
                position += 1
                if value == "env":
                    while position < len(segment):
                        option = tokens[segment[position]][0]
                        if option == "--":
                            position += 1
                            break
                        if option in {"-i", "--ignore-environment"} or _ASSIGNMENT_RE.match(option):
                            position += 1
                        elif option in {"-u", "--unset"}:
                            position += 2
                        elif option == "-S" or option.startswith("--split-string"):
                            raise ValidationCommandError("env -S uv form is unsupported")
                        elif option.startswith("-"):
                            raise ValidationCommandError("ambiguous env uv wrapper")
                        else:
                            break
                    continue
                if value == "command" and position < len(segment):
                    if tokens[segment[position]][0] in {"-p", "--"}:
                        position += 1
                continue
            if value in {">", ">>", "<", "<<", "<<<", "2>", "2>>", "&>", "&>>"}:
                position += 2
                continue
            if Path(value).name == "uv":
                if value != "uv":
                    actual = Path(value)
                    if not actual.is_absolute():
                        actual = cwd / actual
                    try:
                        resolved = str(actual.resolve(strict=True))
                    except OSError as exc:
                        raise ValidationCommandError(
                            "absolute uv executable cannot be resolved"
                        ) from exc
                    if resolved != str(Path(expected_executable).resolve(strict=True)):
                        raise ValidationCommandError(
                            "absolute uv executable differs from frozen package.uv"
                        )
                _value, start, end, _punctuation = tokens[segment[position]]
                edits.append((start, end))
            break
    replacement = shlex.quote(str(snapshot_executable))
    for start, end in reversed(edits):
        command = command[:start] + replacement + command[end:]
    return command


_INFRA_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"ofloop_process_group_leak"), "subprocess_process_group_leak"),
    (re.compile(r"failed to connect"), "registry_network_unreachable"),
    (re.compile(r"could not connect"), "registry_network_unreachable"),
    (re.compile(r"connection (timed out|refused|reset)"), "registry_network_unreachable"),
    (re.compile(r"tls handshake|ssl certificate"), "registry_tls_error"),
    (re.compile(r"failed to download"), "registry_download_failed"),
    (re.compile(r"network is unreachable"), "host_network_unreachable"),
    (re.compile(r"temporary failure in name resolution"), "dns_resolution_failed"),
    (re.compile(r"operation timed out"), "registry_timeout"),
    (re.compile(r"timed out waiting"), "registry_timeout"),
    (re.compile(r"permission denied"), "filesystem_permission_denied"),
    (re.compile(r"read-only file system"), "filesystem_read_only"),
    (re.compile(r"no space left on device"), "filesystem_no_space"),
    (re.compile(r"disk quota exceeded"), "filesystem_quota_exceeded"),
    (re.compile(r"i/o error"), "filesystem_io_error"),
    (re.compile(r"signal \d+ \(sig"), "subprocess_signalled"),
    (re.compile(r"failed to invoke"), "host_tool_execution_failed"),
)

_CANDIDATE_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"the lockfile at .* needs to be updated"), "stale_lockfile"),
    (re.compile(r"the lockfile would have been updated"), "stale_lockfile"),
    (re.compile(r"would be updated to"), "stale_lockfile"),
    (re.compile(r"unidentified error .* look.* like a stale lockfile"), "stale_lockfile"),
    (re.compile(r"failed to parse .*pyproject\.toml"), "invalid_pyproject"),
    (re.compile(r"toml decode error"), "invalid_pyproject"),
    (re.compile(r"no `?project\.?workspace`? found"), "no_pyproject"),
    (re.compile(r"failed to read (lock|pyproject)"), "unreadable_metadata"),
    (re.compile(r"distribution .* not found"), "missing_dependency"),
    (re.compile(r"package .* not found in package list"), "missing_dependency"),
    (re.compile(r"requires-python .* does not match"), "python_version_mismatch"),
    (re.compile(r"no matching distribution"), "missing_dependency"),
    (re.compile(r"invalid project name"), "invalid_project_name"),
    (re.compile(r"error: package metadata"), "invalid_metadata"),
    (re.compile(r"version .* is not a valid"), "invalid_metadata"),
    (re.compile(r"duplicate dependency"), "duplicate_dependency"),
)


def _slug(s: str) -> str:
    return "".join(ch for ch in str(s) if ch.isalnum() or ch in "-_.")[:96]


def _sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    try:
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def _project_lock_identity(candidate_worktree: Path) -> str | None:
    return _sha256_file(candidate_worktree / "uv.lock")


def _project_metadata_identity(candidate_worktree: Path) -> str:
    digest = _sha256_file(candidate_worktree / "pyproject.toml")
    return "no-pyproject" if digest is None else digest


def candidate_bound_environment_id(
    candidate_sha: str,
    candidate_worktree: Path,
) -> str:
    if not candidate_sha or not isinstance(candidate_sha, str):
        raise ValidationEnvironmentError("candidate_sha is required")
    lock_id = _project_lock_identity(candidate_worktree)
    meta_id = _project_metadata_identity(candidate_worktree)
    material = "\0".join([
        str(candidate_sha), str(lock_id or ""), str(meta_id),
    ]).encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def project_environment_dir(
    canonical_repo: Path,
    run_id: str,
    role: str,
    env_id: str,
) -> Path:
    safe_role = "validation-builder" if role == "builder" else (
        "validation-reviewer" if role == "reviewer" else (
            role if role in ("validation", "validation-builder", "validation-reviewer")
            else "validation"
        )
    )
    return (
        runtime_env.runtime_cache_path(canonical_repo, run_id, "validation")
        / "project-env" / safe_role / _slug(env_id)
    ).resolve(strict=False)


def project_environment_status(env_dir: Path) -> dict[str, Any]:
    raw = Path(env_dir).expanduser().resolve(strict=False)
    exists = raw.is_dir()
    marker = raw / ".ofloop-env-provisioned.json"
    state: dict[str, Any] = {
        "path": str(raw), "exists": exists, "provisioned": False,
        "identity": "", "candidate_sha": "", "lock_sha256": "",
        "metadata_sha256": "", "provisioned_at": "",
        "uv_executable": "", "uv_version": "",
    }
    if not exists:
        return state
    if marker.is_symlink() or not marker.is_file():
        return state
    try:
        st = marker.stat()
    except OSError:
        return state
    if not stat.S_ISREG(st.st_mode):
        return state
    if hasattr(os, "getuid") and st.st_uid != os.getuid():
        return state
    if stat.S_IMODE(st.st_mode) & 0o077:
        return state
    try:
        doc = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return state
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return state
    body = {k: v for k, v in doc.items() if k != "marker_sha256"}
    expected_marker = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()
    if expected_marker != doc.get("marker_sha256"):
        return state
    state.update({
        "provisioned": True,
        "identity": str(doc.get("identity") or ""),
        "candidate_sha": str(doc.get("candidate_sha") or ""),
        "lock_sha256": str(doc.get("lock_sha256") or ""),
        "metadata_sha256": str(doc.get("metadata_sha256") or ""),
        "uv_executable": str(doc.get("uv_executable") or ""),
        "uv_version": str(doc.get("uv_version") or ""),
        "package_uv_unbound": bool(doc.get("package_uv_unbound", False)),
        "bound_uv_sha256": str(doc.get("bound_uv_sha256") or ""),
        "bound_uv_version": str(doc.get("bound_uv_version") or ""),
        "bound_uv_cache_path": str(doc.get("bound_uv_cache_path") or ""),
        "bound_uv_cache_scope": str(doc.get("bound_uv_cache_scope") or ""),
        "bound_uv_network_domains": list(doc.get("bound_uv_network_domains") or []),
        "provisioned_at": str(doc.get("provisioned_at") or ""),
    })
    return state


def _real_project_environment_matches_bound_uv(
    status: dict[str, Any], bound_uv: BoundUvIdentity,
) -> bool:
    return (
        bool(status.get("provisioned"))
        and not bool(status.get("package_uv_unbound"))
        and str(status.get("uv_executable") or "") == bound_uv.executable
        and str(status.get("bound_uv_sha256") or "") == bound_uv.executable_sha256
        and str(status.get("bound_uv_version") or "") == bound_uv.version
        and str(status.get("bound_uv_cache_path") or "") == bound_uv.cache_path
        and str(status.get("bound_uv_cache_scope") or "") == bound_uv.cache_scope
        and sorted(str(value) for value in (status.get("bound_uv_network_domains") or []))
        == sorted(bound_uv.network_domains)
    )


def _uuid_name() -> str:
    import uuid
    return uuid.uuid4().hex


def _publish_marker(env_dir: Path, body: dict[str, Any]) -> None:
    body = dict(body)
    body["marker_sha256"] = hashlib.sha256(
        json.dumps(
            {k: v for k, v in body.items() if k != "marker_sha256"},
            sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        ).encode("utf-8")
    ).hexdigest()
    encoded = json.dumps(body, indent=2, sort_keys=True) + "\n"
    tmp = env_dir / f".{_uuid_name()}.marker.tmp"
    tmp.write_text(encoded, encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, env_dir / ".ofloop-env-provisioned.json")


def _excerpt(stderr_bytes: bytes, stdout_bytes: bytes, limit: int = 4096) -> str:
    raw = (stderr_bytes or stdout_bytes or b"").decode("utf-8", errors="replace")
    return raw[:limit]


def classify_sync_failure(
    *,
    returncode: int | None,
    timed_out: bool,
    stderr_bytes: bytes,
    stdout_bytes: bytes,
) -> tuple[str, str]:
    if timed_out:
        return OUTCOME_INFRA_FAILURE, "provisioning_timeout"
    text = _excerpt(stderr_bytes, stdout_bytes, limit=8192).lower()
    if not text and returncode is not None:
        text = f"uv sync returned non-zero exit code {returncode} with empty stderr"
    for pattern, label in _INFRA_PATTERNS:
        if pattern.search(text):
            return OUTCOME_INFRA_FAILURE, label
    for pattern, label in _CANDIDATE_PATTERNS:
        if pattern.search(text):
            return OUTCOME_CANDIDATE_INVALID, label
    return OUTCOME_INFRA_FAILURE, f"unclassified_sync_failure_rc={returncode or 'unknown'}"


def _outcome_dict(
    o: ProvisionOutcome, *, status_fields: dict[str, Any] | None = None,
) -> dict[str, Any]:
    base = {
        "outcome": o.outcome,
        "reason": o.reason,
        "stderr_excerpt": o.stderr_excerpt,
        "returncode": o.returncode,
        "timed_out": o.timed_out,
        "marker_path": o.marker_path,
        "identity": o.identity,
        "path": o.marker_path,
        "provisioned": o.outcome == OUTCOME_PROVISIONED,
    }
    if status_fields:
        base.update(status_fields)
    return base


def provision_project_environment(
    *,
    canonical_repo: Path,
    run_id: str,
    role: str,
    candidate_sha: str,
    candidate_worktree: Path,
    bound_uv: BoundUvIdentity | None = None,
    timeout_seconds: int = DEFAULT_PROVISION_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    canonical_repo = Path(canonical_repo).resolve(strict=False)
    candidate_worktree = Path(candidate_worktree).resolve(strict=False)
    if not candidate_worktree.is_dir():
        raise ValidationEnvironmentError(
            f"candidate worktree is not a directory: {candidate_worktree}"
        )
    env_id = candidate_bound_environment_id(candidate_sha, candidate_worktree)
    env_dir = project_environment_dir(canonical_repo, run_id, role, env_id)

    lock_id = _project_lock_identity(candidate_worktree) or ""
    meta_id = _project_metadata_identity(candidate_worktree)
    pyproject = candidate_worktree / "pyproject.toml"
    has_project = pyproject.is_file()

    def _infra(reason: str, **fields: Any) -> dict[str, Any]:
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_INFRA_FAILURE,
            reason=reason,
            stderr_excerpt="",
            returncode=None,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=fields)

    if not has_project:
        try:
            env_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        except OSError as exc:
            return _infra(f"runtime_cache_create_failed:{exc.strerror or exc}")
        try:
            os.chmod(env_dir, 0o700)
        except OSError:
            pass
        _publish_marker(env_dir, {
            "schema": SCHEMA,
            "identity": env_id,
            "candidate_sha": candidate_sha,
            "lock_sha256": lock_id,
            "metadata_sha256": meta_id,
            "uv_executable": "",
            "uv_version": "",
            "package_uv_unbound": False,
            "bound_uv_sha256": bound_uv.executable_sha256 if bound_uv else "",
            "bound_uv_version": bound_uv.version if bound_uv else "",
            "bound_uv_cache_path": bound_uv.cache_path if bound_uv else "",
            "bound_uv_cache_scope": bound_uv.cache_scope if bound_uv else "",
            "bound_uv_network_domains": list(bound_uv.network_domains) if bound_uv else [],
            "provisioned_at": util.utc_now_iso(),
            "no_project": True,
        })
        status = project_environment_status(env_dir)
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_PROVISIONED,
            reason="no_pyproject",
            stderr_excerpt="",
            returncode=0,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=status)

    if bound_uv is None:
        return _infra(
            "bound_uv_required: package.uv must be frozen before uv provisioning"
        )
    try:
        verify_bound_uv_identity(bound_uv)
    except ValidationEnvironmentError as exc:
        return _infra(f"bound_uv_drift:{exc}")

    existing = project_environment_status(env_dir)
    if existing["provisioned"] and existing["identity"] == env_id:
        if not _real_project_environment_matches_bound_uv(existing, bound_uv):
            return _infra(
                "bound_uv_cached_environment_mismatch: existing project "
                "environment does not prove the current frozen package.uv identity"
            )
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_PROVISIONED,
            reason="already_provisioned",
            stderr_excerpt="",
            returncode=0,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=existing)

    if env_dir.is_symlink():
        return _infra("env_dir_is_symlink")
    if env_dir.exists():
        try:
            shutil.rmtree(env_dir)
        except OSError as exc:
            return _infra(f"env_dir_clear_failed:{exc.strerror or exc}")
    try:
        env_dir.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    except OSError as exc:
        return _infra(f"runtime_cache_create_failed:{exc.strerror or exc}")

    try:
        uv_snapshot, uv_snapshot_dir = snapshot_bound_uv(
            canonical_repo, run_id, bound_uv
        )
    except (OSError, ValidationEnvironmentError) as exc:
        return _infra(f"bound_uv_snapshot_failed:{exc}")
    uv_executable = bound_uv.executable
    uv_version = bound_uv.version
    sync_env = runtime_env.hermetic_subprocess_env(canonical_repo, run_id, "validation")
    sync_env["UV_PROJECT_ENVIRONMENT"] = str(env_dir)
    sync_env["VIRTUAL_ENV"] = str(env_dir)
    cmd = [
        str(uv_snapshot), "sync",
        "--project", str(candidate_worktree),
        "--python-preference", "only-system",
        "--locked",
    ]

    stdout_path = env_dir.parent / f".{env_dir.name}.provision.stdout"
    stderr_path = env_dir.parent / f".{env_dir.name}.provision.stderr"
    start = time.monotonic()
    timed_out = False
    returncode: int | None = None
    try:
        with stdout_path.open("wb") as stdout_fh, stderr_path.open("wb") as stderr_fh:
            try:
                os.chmod(stdout_path, 0o600)
                os.chmod(stderr_path, 0o600)
            except OSError:
                pass
            result = validation_network.run_isolated_to_files(
                cmd,
                cwd=candidate_worktree,
                timeout_seconds=timeout_seconds,
                env=sync_env,
                stdout_fh=stdout_fh,
                stderr_fh=stderr_fh,
                protected_paths=(uv_snapshot_dir,),
                package_network_domains=bound_uv.network_domains,
            )
            returncode = result.returncode
            timed_out = result.timed_out
    except (OSError, validation_network.ValidationNetworkError) as exc:
        for output_path in (stdout_path, stderr_path):
            try:
                output_path.unlink()
            except OSError:
                pass
        return _infra(
            f"subprocess_spawn_failed:{getattr(exc, 'strerror', None) or exc}"
        )
    duration = time.monotonic() - start
    stdout_bytes = stdout_path.read_bytes() if stdout_path.exists() else b""
    stderr_bytes = stderr_path.read_bytes() if stderr_path.exists() else b""
    excerpt = _excerpt(stderr_bytes, stdout_bytes)
    try:
        stdout_path.unlink()
    except OSError:
        pass
    try:
        stderr_path.unlink()
    except OSError:
        pass

    if returncode == 0 and not timed_out:
        try:
            os.chmod(env_dir, 0o700)
        except OSError:
            pass
        _publish_marker(env_dir, {
            "schema": SCHEMA,
            "identity": env_id,
            "candidate_sha": candidate_sha,
            "lock_sha256": lock_id,
            "metadata_sha256": meta_id,
            "uv_executable": uv_executable,
            "uv_version": uv_version,
            "package_uv_unbound": False,
            "bound_uv_sha256": bound_uv.executable_sha256,
            "bound_uv_version": bound_uv.version,
            "bound_uv_cache_path": bound_uv.cache_path,
            "bound_uv_cache_scope": bound_uv.cache_scope,
            "bound_uv_network_domains": list(bound_uv.network_domains),
            "provisioned_at": util.utc_now_iso(),
            "duration_seconds": float(duration),
        })
        status = project_environment_status(env_dir)
        return _outcome_dict(ProvisionOutcome(
            outcome=OUTCOME_PROVISIONED,
            reason="uv_sync_returned_zero",
            stderr_excerpt="",
            returncode=0,
            timed_out=False,
            marker_path=str(env_dir),
            identity=env_id,
        ), status_fields=status)

    outcome_class, label = classify_sync_failure(
        returncode=returncode,
        timed_out=timed_out,
        stderr_bytes=stderr_bytes,
        stdout_bytes=stdout_bytes,
    )
    result = _outcome_dict(ProvisionOutcome(
        outcome=outcome_class,
        reason=label,
        stderr_excerpt=excerpt,
        returncode=returncode,
        timed_out=timed_out,
        marker_path=str(env_dir),
        identity=env_id,
    ))
    result["package_uv_unbound"] = False
    result["bound_uv_sha256"] = bound_uv.executable_sha256
    result["bound_uv_version"] = bound_uv.version
    return result


def command_uses_uv_run(command: str) -> bool:
    return is_uv_command(command)


def env_overrides(env_dir: Path) -> dict[str, str]:
    env_dir = Path(env_dir).expanduser().resolve(strict=False)
    return {
        "UV_PROJECT_ENVIRONMENT": str(env_dir),
        "VIRTUAL_ENV": str(env_dir),
    }


__all__ = [
    "ALL_OUTCOMES",
    "BoundUvIdentity",
    "ValidationCommandError",
    "DEFAULT_PROVISION_TIMEOUT_SECONDS",
    "OUTCOME_CANDIDATE_INVALID",
    "OUTCOME_INFRA_FAILURE",
    "OUTCOME_PROVISIONED",
    "ProvisionOutcome",
    "SCHEMA",
    "UV_MEDIATED_SUBCOMMANDS",
    "ValidationEnvironmentError",
    "build_bound_uv_identity",
    "bound_uv_snapshot_dir",
    "candidate_bound_environment_id",
    "classify_uv_command",
    "classify_sync_failure",
    "command_uses_uv_run",
    "env_overrides",
    "is_uv_command",
    "project_environment_dir",
    "project_environment_status",
    "provision_project_environment",
    "rewrite_bound_uv_tokens",
    "snapshot_bound_uv",
    "verify_bound_uv_identity",
]

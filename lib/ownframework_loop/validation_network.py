"""OS-enforced network boundary for deterministic validation subprocesses.

macOS uses the system Seatbelt sandbox and a short-lived CONNECT proxy for
the frozen package registry hosts. Linux uses a private user/network/mount
namespace; loopback remains available, while public egress is absent. If the
host cannot establish its isolation primitive, validation fails closed.
"""
from __future__ import annotations

import ipaddress
import json
import os
import select
import socket
import socketserver
import sys
import tempfile
import threading
from pathlib import Path
from typing import BinaryIO, Mapping, Sequence
from urllib.parse import urlsplit

from . import process_runner


class ValidationNetworkError(RuntimeError):
    """The host could not prove the requested validation network boundary."""


_MAX_PROXY_HEADER = 16 * 1024
_PROXY_CONNECT_TIMEOUT = 20.0


def _domain(value: str) -> str:
    host = str(value).strip().rstrip(".").lower()
    try:
        return host.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ValidationNetworkError("invalid package-network hostname") from exc


def _allowed_upstream(host: str, port: int, allowed: frozenset[str]) -> socket.socket:
    normalized = _domain(host)
    if normalized not in allowed or port != 443:
        raise PermissionError("package network destination is outside frozen authority")
    try:
        addresses = socket.getaddrinfo(
            normalized, port, type=socket.SOCK_STREAM
        )
    except OSError as exc:
        raise OSError("package registry DNS resolution failed") from exc
    last_error: OSError | None = None
    for family, socktype, proto, _canonname, sockaddr in addresses:
        try:
            address = ipaddress.ip_address(str(sockaddr[0]).split("%", 1)[0])
        except ValueError:
            continue
        if not address.is_global:
            continue
        upstream = socket.socket(family, socktype, proto)
        upstream.settimeout(_PROXY_CONNECT_TIMEOUT)
        try:
            upstream.connect(sockaddr)
            upstream.settimeout(None)
            return upstream
        except OSError as exc:
            last_error = exc
            upstream.close()
    raise OSError("no public package-registry address was reachable") from last_error


def _parse_connect_header(raw: bytes) -> tuple[str, int]:
    try:
        lines = raw.decode("ascii").split("\r\n")
        method, authority, version = lines[0].split(" ", 2)
    except (UnicodeDecodeError, ValueError, IndexError) as exc:
        raise ValueError("malformed proxy request") from exc
    if method != "CONNECT" or version not in ("HTTP/1.0", "HTTP/1.1"):
        raise ValueError("only HTTPS CONNECT is allowed")
    parsed = urlsplit("//" + authority)
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("proxy credentials are not accepted")
    try:
        host = parsed.hostname or ""
        port = parsed.port or 0
    except ValueError as exc:
        raise ValueError("malformed proxy destination") from exc
    if not host or not port:
        raise ValueError("proxy destination must include host and port")
    return host, port


def _tunnel(left: socket.socket, right: socket.socket) -> None:
    left.setblocking(False)
    right.setblocking(False)
    peers = {left: right, right: left}
    while True:
        readable, _, exceptional = select.select(
            [left, right], [], [left, right], 60.0
        )
        if exceptional or not readable:
            return
        for source in readable:
            try:
                data = source.recv(64 * 1024)
            except OSError:
                return
            if not data:
                return
            target = peers[source]
            view = memoryview(data)
            while view:
                try:
                    sent = target.send(view)
                except OSError:
                    return
                view = view[sent:]


class _ConnectProxyHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        client: socket.socket = self.request
        client.settimeout(_PROXY_CONNECT_TIMEOUT)
        header = bytearray()
        while b"\r\n\r\n" not in header and len(header) <= _MAX_PROXY_HEADER:
            chunk = client.recv(4096)
            if not chunk:
                return
            header.extend(chunk)
        if len(header) > _MAX_PROXY_HEADER:
            client.sendall(b"HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n")
            return
        try:
            host, port = _parse_connect_header(bytes(header))
            upstream = _allowed_upstream(
                host, port, self.server.allowed_domains  # type: ignore[attr-defined]
            )
        except (OSError, ValueError, ValidationNetworkError):
            try:
                client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            return
        try:
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            client.settimeout(None)
            _tunnel(client, upstream)
        except OSError:
            pass
        finally:
            upstream.close()


class _PackageProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, domains: Sequence[str]) -> None:
        self.allowed_domains = frozenset(_domain(item) for item in domains)
        super().__init__(("127.0.0.1", 0), _ConnectProxyHandler)


class _PackageProxy:
    def __init__(self, domains: Sequence[str]) -> None:
        self.server = _PackageProxyServer(domains)
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            name="ofloop-validation-package-proxy",
            daemon=True,
        )

    @property
    def port(self) -> int:
        return int(self.server.server_address[1])

    def __enter__(self) -> "_PackageProxy":
        self.thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)


class _UnixPackageBrokerHandler(socketserver.BaseRequestHandler):
    """Resolve and connect only frozen registry hosts for a Linux namespace."""

    def handle(self) -> None:
        client: socket.socket = self.request
        client.settimeout(_PROXY_CONNECT_TIMEOUT)
        request = bytearray()
        while b"\n" not in request and len(request) <= 4096:
            chunk = client.recv(1024)
            if not chunk:
                return
            request.extend(chunk)
        if len(request) > 4096 or b"\n" not in request:
            client.sendall(b"DENY\n")
            return
        try:
            payload = json.loads(bytes(request).split(b"\n", 1)[0])
            host = str(payload["host"])
            port = int(payload["port"])
            upstream = _allowed_upstream(
                host, port, self.server.allowed_domains  # type: ignore[attr-defined]
            )
        except (KeyError, TypeError, ValueError, OSError, ValidationNetworkError):
            try:
                client.sendall(b"DENY\n")
            except OSError:
                pass
            return
        try:
            client.sendall(b"ALLOW\n")
            client.settimeout(None)
            _tunnel(client, upstream)
        except OSError:
            pass
        finally:
            upstream.close()


class _UnixPackageBroker(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path: str, domains: Sequence[str]) -> None:
        self.allowed_domains = frozenset(_domain(item) for item in domains)
        super().__init__(path, _UnixPackageBrokerHandler)


class _PackageBroker:
    """Host-side allowlist broker reachable from a private Linux netns."""

    def __init__(self, domains: Sequence[str]) -> None:
        self.directory = tempfile.mkdtemp(prefix="ofl-b-")
        os.chmod(self.directory, 0o700)
        self.socket_path = str(Path(self.directory) / "b")
        self.server = _UnixPackageBroker(self.socket_path, domains)
        os.chmod(self.socket_path, 0o600)
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            name="ofloop-validation-package-broker",
            daemon=True,
        )

    def __enter__(self) -> "_PackageBroker":
        self.thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        os.rmdir(self.directory)


def _mac_profile(*, proxy_port: int | None, protected_paths: Sequence[Path]) -> str:
    rules = [
        "(version 1)",
        "(allow default)",
        "(deny network*)",
    ]
    if proxy_port is not None:
        rules.append(
            f'(allow network-outbound (remote ip "localhost:{int(proxy_port)}"))'
        )
    else:
        rules.extend((
            '(allow network-outbound (remote ip "localhost:*"))',
            '(allow network-inbound (local ip "localhost:*"))',
            '(allow network-bind (local ip "localhost:*"))',
        ))
    for raw_path in protected_paths:
        path = Path(raw_path).resolve(strict=False)
        rules.append(f"(deny file-write* (subpath {json.dumps(str(path))}))")
    return " ".join(rules)


def _linux_namespace_prefix(
    command: Sequence[str], *, protected_paths: Sequence[Path],
    package_broker_socket: str | None = None,
) -> list[str]:
    unshare = next((
        candidate for candidate in ("/usr/bin/unshare", "/bin/unshare")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK)
    ), None)
    if not unshare:
        raise ValidationNetworkError("Linux network namespace tool is unavailable")
    helper = r'''
import ctypes, json, os, select, socket, socketserver, struct, subprocess, sys, threading
protected = [os.fsencode(p) for p in sys.argv[1].split(os.pathsep) if p]
broker_path = sys.argv[2] or None
command = sys.argv[3:]
libc = ctypes.CDLL(None, use_errno=True)
def mount(source, target, filesystem, flags, data):
    src = None if source is None else ctypes.c_char_p(os.fsencode(source))
    dst = ctypes.c_char_p(os.fsencode(target))
    typ = None if filesystem is None else ctypes.c_char_p(os.fsencode(filesystem))
    dat = None if data is None else ctypes.c_char_p(os.fsencode(data))
    if libc.mount(src, dst, typ, ctypes.c_ulong(flags), dat) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), os.fsdecode(target))
mount(None, b"/", None, 16384 | 262144, None)  # MS_REC | MS_PRIVATE
for raw in protected:
    path = os.fsdecode(raw)
    mount(path, path, None, 4096, None)  # MS_BIND
    mount(None, path, None, 4096 | 32 | 1, None)  # bind/remount/readonly
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
name = b"lo"
flags = bytearray(struct.pack("16sH", name, 0))
fcntl = __import__("fcntl")
fcntl.ioctl(sock.fileno(), 0x8913, flags, True)  # SIOCGIFFLAGS
current = struct.unpack_from("H", flags, 16)[0]
struct.pack_into("H", flags, 16, current | 1)  # IFF_UP
fcntl.ioctl(sock.fileno(), 0x8914, flags)  # SIOCSIFFLAGS
sock.close()
if broker_path is None:
    os.execvpe(command[0], command, os.environ)

def tunnel(left, right):
    left.setblocking(False)
    right.setblocking(False)
    peers = {left: right, right: left}
    while True:
        readable, _, exceptional = select.select([left, right], [], [left, right], 120.0)
        if exceptional or not readable:
            return
        for source in readable:
            try:
                data = source.recv(65536)
            except OSError:
                return
            if not data:
                return
            target = peers[source]
            view = memoryview(data)
            while view:
                try:
                    sent = target.send(view)
                except OSError:
                    return
                view = view[sent:]

def connect_authority(authority):
    parsed = authority.rsplit(":", 1)
    if len(parsed) != 2:
        raise ValueError("CONNECT authority needs a port")
    host = parsed[0].strip("[]")
    port = int(parsed[1])
    broker = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    broker.settimeout(20.0)
    broker.connect(broker_path)
    broker.sendall((json.dumps({"host": host, "port": port}) + "\n").encode())
    response = bytearray()
    while b"\n" not in response and len(response) <= 16:
        response.extend(broker.recv(16))
    if response.split(b"\n", 1)[0] != b"ALLOW":
        broker.close()
        raise PermissionError("package destination is outside frozen authority")
    broker.settimeout(None)
    return broker

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(20.0)
        header = bytearray()
        while b"\r\n\r\n" not in header and len(header) <= 16384:
            chunk = client.recv(4096)
            if not chunk:
                return
            header.extend(chunk)
        try:
            if len(header) > 16384:
                raise ValueError("proxy header too large")
            first = bytes(header).split(b"\r\n", 1)[0].decode("ascii")
            method, authority, version = first.split(" ", 2)
            if method != "CONNECT" or version not in ("HTTP/1.0", "HTTP/1.1"):
                raise ValueError("only HTTPS CONNECT is permitted")
            broker = connect_authority(authority)
        except (OSError, UnicodeError, ValueError):
            try:
                client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            return
        try:
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            client.settimeout(None)
            tunnel(client, broker)
        except OSError:
            pass
        finally:
            broker.close()

class Proxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True

server = Proxy(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
proxy = "http://127.0.0.1:%d" % server.server_address[1]
env = os.environ.copy()
for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "UV_HTTP_PROXY", "UV_HTTPS_PROXY", "uv_http_proxy", "uv_https_proxy"):
    env[key] = proxy
env["NO_PROXY"] = ""
env["no_proxy"] = ""
env["UV_NO_PROXY"] = ""
env["uv_no_proxy"] = ""
try:
    child = subprocess.Popen(command, env=env)
    result = child.wait()
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2.0)
sys.exit(result)
'''
    protected = os.pathsep.join(
        str(Path(item).resolve(strict=False)) for item in protected_paths
    )
    return [
        unshare, "--user", "--map-root-user", "--mount", "--net",
        sys.executable, "-c", helper, protected, package_broker_socket or "",
        *command,
    ]


def _probe_linux_namespace(
    *, protected_paths: Sequence[Path],
    package_broker_socket: str | None = None,
) -> None:
    """Prove Linux isolation can be established before running validation.

    ``unshare`` can exist and still be denied by the host's user-namespace
    policy.  Letting its non-zero exit look like the candidate command's exit
    would turn an unavailable safety primitive into a product-validation
    failure.  Run the same namespace/bootstrap helper with a harmless command
    first so that host refusal is reported as infrastructure failure.
    """
    probe = _linux_namespace_prefix(
        ["/bin/true"],
        protected_paths=protected_paths,
        package_broker_socket=package_broker_socket,
    )
    try:
        result = process_runner.run_bounded_capture(
            probe, timeout_seconds=8.0
        )
    except OSError as exc:
        raise ValidationNetworkError(
            "Linux validation namespace preflight could not be completed"
        ) from exc
    if result.timed_out or result.returncode != 0:
        detail = "timed out" if result.timed_out else f"exit={result.returncode}"
        raise ValidationNetworkError(
            f"Linux validation namespace is unavailable ({detail})"
        )


def _isolated_argv(
    command: Sequence[str], *, proxy_port: int | None,
    protected_paths: Sequence[Path],
) -> list[str]:
    if sys.platform == "darwin":
        sandbox = "/usr/bin/sandbox-exec"
        if not sandbox:
            raise ValidationNetworkError("macOS sandbox-exec is unavailable")
        profile = _mac_profile(
            proxy_port=proxy_port, protected_paths=protected_paths
        )
        return [sandbox, "-p", profile, *command]
    if sys.platform.startswith("linux"):
        return _linux_namespace_prefix(command, protected_paths=protected_paths)
    raise ValidationNetworkError(
        f"no supported validation network sandbox for {sys.platform}"
    )


def isolated_argv(
    command: Sequence[str], *, protected_paths: Sequence[Path] = ()
) -> list[str]:
    """Return an OS-enforced local-only command prefix, failing closed."""
    if sys.platform == "darwin":
        sandbox = "/usr/bin/sandbox-exec"
        if not sandbox:
            raise ValidationNetworkError("macOS sandbox-exec is unavailable")
        profile = _mac_profile(proxy_port=None, protected_paths=protected_paths)
        return [sandbox, "-p", profile, *command]
    if sys.platform.startswith("linux"):
        return _linux_namespace_prefix(command, protected_paths=protected_paths)
    raise ValidationNetworkError(
        f"no supported validation network sandbox for {sys.platform}"
    )


def _with_proxy_environment(env: Mapping[str, str], port: int) -> dict[str, str]:
    result = _without_proxy_environment(env)
    proxy = f"http://127.0.0.1:{int(port)}"
    for key in (
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "all_proxy",
        "UV_HTTP_PROXY", "UV_HTTPS_PROXY",
        "uv_http_proxy", "uv_https_proxy",
    ):
        result[key] = proxy
    result["NO_PROXY"] = ""
    result["no_proxy"] = ""
    result["UV_NO_PROXY"] = ""
    result["uv_no_proxy"] = ""
    return result


def _without_proxy_environment(env: Mapping[str, str]) -> dict[str, str]:
    result = dict(env)
    for key in (
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "UV_HTTP_PROXY", "UV_HTTPS_PROXY", "UV_NO_PROXY",
        "uv_http_proxy", "uv_https_proxy", "uv_no_proxy",
    ):
        result.pop(key, None)
    return result


def run_isolated_to_files(
    command: Sequence[str], *, cwd: Path, timeout_seconds: float,
    stdout_fh: BinaryIO, stderr_fh: BinaryIO, env: Mapping[str, str],
    protected_paths: Sequence[Path] = (),
    package_network_domains: Sequence[str] = (),
) -> process_runner.CommandResult:
    """Run a validator with local-only egress or bounded package CONNECT access."""
    domains = tuple(sorted({_domain(item) for item in package_network_domains}))
    if not domains:
        argv = isolated_argv(command, protected_paths=protected_paths)
        if sys.platform.startswith("linux"):
            _probe_linux_namespace(protected_paths=protected_paths)
        return process_runner.run_bounded_to_files(
            argv, cwd=cwd, timeout_seconds=timeout_seconds,
            stdout_fh=stdout_fh, stderr_fh=stderr_fh,
            env=_without_proxy_environment(env),
        )

    if sys.platform == "darwin":
        with _PackageProxy(domains) as proxy:
            sandboxed = _isolated_argv(
                command, proxy_port=proxy.port, protected_paths=protected_paths
            )
            return process_runner.run_bounded_to_files(
                sandboxed, cwd=cwd, timeout_seconds=timeout_seconds,
                stdout_fh=stdout_fh, stderr_fh=stderr_fh,
                env=_with_proxy_environment(env, proxy.port),
            )
    if sys.platform.startswith("linux"):
        with _PackageBroker(domains) as broker:
            _probe_linux_namespace(
                protected_paths=protected_paths,
                package_broker_socket=broker.socket_path,
            )
            sandboxed = _linux_namespace_prefix(
                command,
                protected_paths=protected_paths,
                package_broker_socket=broker.socket_path,
            )
            return process_runner.run_bounded_to_files(
                sandboxed, cwd=cwd, timeout_seconds=timeout_seconds,
                stdout_fh=stdout_fh, stderr_fh=stderr_fh, env=env,
            )
    raise ValidationNetworkError(
        f"no supported package-network sandbox for {sys.platform}"
    )


__all__ = [
    "ValidationNetworkError",
    "isolated_argv",
    "run_isolated_to_files",
]

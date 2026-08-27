#!/usr/bin/env python3
"""Deterministic IPC smoke test for the production Rust streaming engine."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import selectors
import socket
import stat
import subprocess
import sys
import threading
import time


SOCKET_PATH = Path("/tmp/hydra_unix_sock")
ROUTE_ID = "rust-ipc-smoke"
START_TIMEOUT_SECONDS = 20.0
STOP_TIMEOUT_SECONDS = 10.0


class SmokeFailure(RuntimeError):
    """Raised when the engine violates its production IPC contract."""


class SocketCollector:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.server: socket.socket | None = None
        self.connection: socket.socket | None = None
        self.chunks: list[bytes] = []
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        if self.path.exists() or self.path.is_symlink():
            mode = self.path.lstat().st_mode
            if not stat.S_ISSOCK(mode):
                raise SmokeFailure(f"refusing to replace non-socket path: {self.path}")
            self.path.unlink()

        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen(1)
        self.server.settimeout(0.2)
        self.thread = threading.Thread(target=self._collect, daemon=True)
        self.thread.start()

    def _collect(self) -> None:
        assert self.server is not None
        while not self.stop_event.is_set() and self.connection is None:
            try:
                self.connection, _ = self.server.accept()
                self.connection.settimeout(0.2)
            except TimeoutError:
                continue
            except OSError:
                return

        while not self.stop_event.is_set() and self.connection is not None:
            try:
                chunk = self.connection.recv(65536)
                if not chunk:
                    return
                self.chunks.append(chunk)
            except TimeoutError:
                continue
            except OSError:
                return

    def text(self) -> str:
        return b"".join(self.chunks).decode("utf-8", errors="replace")

    def close(self) -> None:
        self.stop_event.set()
        for stream in (self.connection, self.server):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        if self.thread is not None:
            self.thread.join(timeout=1.0)
        if self.path.exists() or self.path.is_symlink():
            mode = self.path.lstat().st_mode
            if stat.S_ISSOCK(mode):
                self.path.unlink()


def reserve_udp_socket() -> socket.socket:
    reservation = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    reservation.bind(("127.0.0.1", 0))
    return reservation


def build_init(source_port: int, sink_port: int) -> str:
    return json.dumps(
        {
            "type": "init",
            "route_id": ROUTE_ID,
            "primary_source": {
                "type": "srtsrc",
                "uri": (
                    f"srt://127.0.0.1:{source_port}"
                    "?mode=listener&latency=120"
                ),
            },
            "sinks": [
                {
                    "type": "udpsink",
                    "host": "127.0.0.1",
                    "port": sink_port,
                }
            ],
        },
        separators=(",", ":"),
    )


def validate_engine(engine: Path) -> None:
    if not engine.is_file():
        raise SmokeFailure(f"engine does not exist: {engine}")
    if not os.access(engine, os.X_OK):
        raise SmokeFailure(f"engine is not executable: {engine}")


def drain_process(
    process: subprocess.Popen[bytes],
    timeout_seconds: float,
    predicate,
) -> tuple[bytes, bytes]:
    assert process.stdout is not None
    assert process.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    output = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        for key, _ in selector.select(timeout=0.1):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if chunk:
                output[key.data].extend(chunk)
            else:
                selector.unregister(key.fileobj)

        if predicate(bytes(output["stdout"]), bytes(output["stderr"])):
            break
        if process.poll() is not None and not selector.get_map():
            break

    selector.close()
    return bytes(output["stdout"]), bytes(output["stderr"])


def failure_message(reason: str, stdout: bytes, stderr: bytes, frames: str) -> str:
    return "\n".join(
        [
            reason,
            "--- stdout ---",
            stdout.decode("utf-8", errors="replace"),
            "--- stderr ---",
            stderr.decode("utf-8", errors="replace"),
            "--- socket frames ---",
            frames,
        ]
    )


def run_smoke(engine: Path) -> None:
    validate_engine(engine)
    collector = SocketCollector(SOCKET_PATH)
    source_reservation = reserve_udp_socket()
    sink_receiver = reserve_udp_socket()
    source_port = source_reservation.getsockname()[1]
    sink_port = sink_receiver.getsockname()[1]
    process: subprocess.Popen[bytes] | None = None

    try:
        collector.start()
        source_reservation.close()
        process = subprocess.Popen(
            [str(engine.resolve()), ROUTE_ID],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        assert process.stdin is not None
        process.stdin.write((build_init(source_port, sink_port) + "\n").encode())
        process.stdin.flush()

        stdout, stderr = drain_process(
            process,
            START_TIMEOUT_SECONDS,
            lambda out, _err: b" to PLAYING" in out or b" to PAUSED" in out,
        )
        if b" to PLAYING" not in stdout and b" to PAUSED" not in stdout:
            raise SmokeFailure(
                failure_message(
                    "engine never reached PLAYING/PAUSED",
                    stdout,
                    stderr,
                    collector.text(),
                )
            )

        handshake_deadline = time.monotonic() + 2.0
        handshake = f"route_id:{ROUTE_ID}"
        while handshake not in collector.text() and time.monotonic() < handshake_deadline:
            time.sleep(0.05)
        if handshake not in collector.text():
            raise SmokeFailure(
                failure_message(
                    "missing route-id socket handshake",
                    stdout,
                    stderr,
                    collector.text(),
                )
            )

        process.stdin.write(b'{"command":"stop-route"}\n')
        process.stdin.flush()
        stopped_out, stopped_err = drain_process(
            process,
            STOP_TIMEOUT_SECONDS,
            lambda out, _err: b"Socket closed." in out,
        )
        stdout += stopped_out
        stderr += stopped_err

        try:
            return_code = process.wait(timeout=2.0)
        except subprocess.TimeoutExpired as error:
            raise SmokeFailure(
                failure_message(
                    "engine did not exit after stop-route",
                    stdout,
                    stderr,
                    collector.text(),
                )
            ) from error

        if return_code != 0 or b"Socket closed." not in stdout:
            raise SmokeFailure(
                failure_message(
                    f"engine shutdown contract failed (exit={return_code})",
                    stdout,
                    stderr,
                    collector.text(),
                )
            )
    finally:
        source_reservation.close()
        sink_receiver.close()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2.0)
        collector.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, type=Path)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="validate harness prerequisites without starting engine",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        validate_engine(args.engine)
        if args.check_only:
            reservation = reserve_udp_socket()
            reservation.close()
            print("Rust IPC smoke prerequisites passed")
            return 0
        run_smoke(args.engine)
        print("Rust IPC smoke passed")
        return 0
    except (OSError, SmokeFailure) as error:
        print(f"Rust IPC smoke failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

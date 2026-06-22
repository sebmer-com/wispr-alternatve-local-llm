#!/usr/bin/env python3
import json
import os
import pty
import select
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"
TEST_TEXT = "Grüße vom Protokolltest"


def read_exact(fd: int, length: int, timeout: float = 5.0) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while len(data) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError(f"timed out after {len(data)}/{length} bytes")
        data.extend(os.read(fd, length - len(data)))
    return bytes(data)


def read_line(fd: int, timeout: float = 5.0) -> str:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError("timed out waiting for protocol line")
        byte = os.read(fd, 1)
        if byte == b"\n":
            return data.rstrip(b"\r").decode("ascii")
        data.extend(byte)


def write_line(fd: int, line: str) -> None:
    os.write(fd, f"KBD1 {line}\n".encode("ascii"))


def emulate_firmware(master_fd: int, errors: list[str]) -> None:
    try:
        if read_line(master_fd) != "KBD1 STATUS":
            raise AssertionError("client did not request STATUS first")
        write_line(
            master_fd,
            "STATUS stack=1 bonded=1 connected=1 pairing=0 busy=0 layout=de-DE key_delay_ms=4 max_bytes=8192",
        )

        header = read_line(master_fd).split()
        if len(header) != 5 or header[:2] != ["KBD1", "TYPE_CHUNKED"]:
            raise AssertionError(f"unexpected transfer header: {header}")
        payload_length = int(header[2])
        expected_crc = int(header[3], 16)
        chunk_size = int(header[4])
        if chunk_size != 32:
            raise AssertionError(f"unexpected chunk header: {header}")

        write_line(master_fd, f"READY bytes={payload_length} chunk={chunk_size}")
        payload = bytearray()
        while len(payload) < payload_length:
            payload.extend(read_exact(master_fd, min(chunk_size, payload_length - len(payload))))
            write_line(master_fd, f"RECEIVED bytes={len(payload)}")

        if bytes(payload) != TEST_TEXT.encode("utf-8"):
            raise AssertionError("UTF-8 payload changed during serial transfer")
        if zlib.crc32(payload) & 0xFFFFFFFF != expected_crc:
            raise AssertionError("CRC32 in transfer header does not match payload")

        write_line(master_fd, f"QUEUED bytes={payload_length} codepoints={len(TEST_TEXT)}")
        write_line(
            master_fd,
            f"DONE bytes={payload_length} codepoints={len(TEST_TEXT)} strokes={len(TEST_TEXT)} reports=1 elapsed_us=1",
        )
    except Exception as error:
        errors.append(str(error))


def main() -> int:
    master_fd, slave_fd = pty.openpty()
    slave_path = os.ttyname(slave_fd)
    errors: list[str] = []
    thread = threading.Thread(target=emulate_firmware, args=(master_fd, errors), daemon=True)

    try:
        config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
        config["bluetooth_keyboard"]["port"] = slave_path
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "config.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            thread.start()
            completed = subprocess.run(
                [
                    str(BINARY),
                    "--config",
                    str(config_path),
                    "--test-bluetooth-keyboard",
                    TEST_TEXT,
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                timeout=15,
            )
            thread.join(timeout=2)
    finally:
        os.close(slave_fd)
        os.close(master_fd)

    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if thread.is_alive():
        print("Bluetooth keyboard protocol regression: firmware emulator did not finish", file=sys.stderr)
        return 1
    if errors:
        print(f"Bluetooth keyboard protocol regression: {errors[0]}", file=sys.stderr)
        return 1
    if completed.returncode != 0:
        print("Bluetooth keyboard protocol regression: client failed", file=sys.stderr)
        return 1
    if "[bluetooth-keyboard] typed" not in completed.stdout:
        print("Bluetooth keyboard protocol regression: success output missing", file=sys.stderr)
        return 1
    print("bluetooth keyboard protocol checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Independent wire-level checks against a localhost-only simulated scanner."""
from pathlib import Path
import os
import signal
import socket
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parent
binary = Path(os.environ.get("DCP_SCAN_BINARY", root / "dcp-j315w-scan"))
pixels = bytes((i * 13) % 256 for i in range(128))
# Include page-end-valued bytes *inside* row data, which must not terminate a scan.
pixels = pixels[:7] + b"\x80" + pixels[8:]


def request(conn):
    data = bytearray()
    while not data.endswith(b"\x80"):
        part = conn.recv(1)
        assert part
        data.extend(part)
        assert len(data) < 512
    return bytes(data)


def fragmented(conn, data):
    for i in range(0, len(data), 3):
        conn.sendall(data[i:i+3])
        time.sleep(0.001)


def exercise(kind, output):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 54921))
    listener.listen(1)
    listener.settimeout(10)
    errors = []
    scanning = threading.Event()

    def scanner():
        try:
            with listener.accept()[0] as conn:
                conn.settimeout(10)
                fragmented(conn, b"+OK 200\r\n")
                assert request(conn) == b"\x1bI\nR=100,100\nM=GRAY256\n\x80"
                info = b"100,100,2,209,32,294,4"
                fragmented(conn, b"\0" + len(info).to_bytes(2, "little") + info)
                scan = request(conn)
                assert scan.startswith(b"\x1bX\n") and b"A=0,0,32,4\n\x80" in scan
                scanning.set()
                if kind == "cancel":
                    conn.sendall(b"\x40\x20\0" + pixels[:4])
                    assert conn.recv(2) == b"\x1bR"
                    return
                if kind == "bad-width":
                    conn.sendall(b"\x40\x1f\0")
                    assert conn.recv(2) == b"\x1bR"
                    return
                for row in range(4):
                    fragmented(conn, b"\x40\x20\0" + pixels[row*32:(row+1)*32])
                if kind != "missing-end":
                    conn.sendall(b"\x80")
        except Exception as exc:
            errors.append(exc)
        finally:
            listener.close()

    thread = threading.Thread(target=scanner)
    thread.start()
    process = subprocess.Popen([binary, "--scan", "127.0.0.1", output],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if kind == "cancel":
        assert scanning.wait(5)
        time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
    stdout, stderr = process.communicate(timeout=15)
    thread.join(timeout=10)
    assert not thread.is_alive() and not errors, errors
    return process.returncode, stdout, stderr


with tempfile.TemporaryDirectory(prefix="dcp-j315w-transport-") as tmp:
    output = Path(tmp) / "scan.pgm"
    result = exercise("complete", output)
    assert result[0] == 0, result
    assert output.read_bytes() == b"P5\n# DCP-J315W network scan, 100 dpi\n32 4\n255\n" + pixels
    print("PASS: fragmented greeting/info/rows decode exactly, including 0x80 pixels")
    output.unlink()
    for kind in ("missing-end", "bad-width", "cancel"):
        result = exercise(kind, output)
        assert result[0] == 1 and not output.exists(), (kind, result)
        print(f"PASS: {kind} fails clearly without saving a partial image")
    output.write_bytes(b"existing scan")
    result = exercise("complete", output)
    assert result[0] == 1 and output.read_bytes() == b"existing scan", result
    print("PASS: an existing output file is preserved")

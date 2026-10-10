#!/usr/bin/env python3
"""Independent wire-level checks against a localhost-only simulated scanner."""
from pathlib import Path
import os
import signal
import stat
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
# Independent colour vectors: black, white, red, green, blue, neutral, and two
# out-of-gamut values that exercise clipping. Wire tuples are (Cr, Y, Cb).
colour_vectors = [(128, 0, 128), (128, 255, 128), (255, 76, 85),
                  (21, 150, 44), (107, 29, 255), (128, 128, 128),
                  (0, 0, 0), (255, 255, 255)] * 16
rgb = bytes([0, 0, 0, 255, 255, 255, 254, 0, 0, 0, 255, 1,
             0, 0, 254, 128, 128, 128, 0, 135, 0, 255, 121, 255] * 16)


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


def exercise(kind, output, dpi=100, area=None, colour=False):
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
                mode = "CGRAY" if colour else "GRAY256"
                assert request(conn) == f"\x1bI\nR={dpi},{dpi}\nM={mode}\n".encode() + b"\x80"
                info = f"{dpi},{dpi},2,209,32,294,4".encode()
                if kind == "bad-info":
                    info = b"100,100,2,209,99999999999999999999999999,294,4"
                fragmented(conn, b"\0" + len(info).to_bytes(2, "little") + info)
                if kind == "bad-info":
                    return
                scan = request(conn)
                expected_area = b"16,1,32,3" if area else b"0,0,32,4"
                assert scan.startswith(b"\x1bX\n") and b"A=" + expected_area + b"\n\x80" in scan
                assert f"M={mode}\n".encode() in scan
                scanning.set()
                if kind == "cancel":
                    conn.sendall(bytes([0x44 if colour else 0x40, 32, 0]) + pixels[:4])
                    assert conn.recv(2) == b"\x1bR"
                    return
                if kind == "bad-width":
                    conn.sendall(bytes([0x44 if colour else 0x40, 31, 0]))
                    assert conn.recv(2) == b"\x1bR"
                    return
                width, height = (16, 2) if area else (32, 4)
                for row in range(height):
                    for plane in range(3 if colour else 1):
                        tag = 0x44 + plane * 4 if colour else 0x40
                        if kind == "wrong-plane" and plane == 1:
                            conn.sendall(b"\x44")
                            assert conn.recv(2) == b"\x1bR"
                            return
                        if kind == "incomplete-colour-row" and plane == 1:
                            conn.sendall(b"\x80")
                            assert conn.recv(2) == b"\x1bR"
                            return
                        data = bytes(v[plane] for v in colour_vectors[row*width:(row+1)*width]) if colour else pixels[row*width:(row+1)*width]
                        fragmented(conn, bytes([tag]) + width.to_bytes(2, "little") + data)
                if kind != "missing-end":
                    conn.sendall(b"\x80")
        except Exception as exc:
            errors.append(exc)
        finally:
            listener.close()

    thread = threading.Thread(target=scanner)
    thread.start()
    args = [binary, "--scan", "127.0.0.1", output, "--dpi", str(dpi)]
    if colour:
        args += ["--mode", "colour"]
    if area:
        args += ["--area", area]
    process = subprocess.Popen(args,
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
    for kind in ("missing-end", "bad-width", "cancel", "bad-info"):
        result = exercise(kind, output)
        assert result[0] == 1 and not output.exists(), (kind, result)
        print(f"PASS: {kind} fails clearly without saving a partial image")
    result = exercise("complete", output, dpi=300, area="16,1,16,2")
    assert result[0] == 0, result
    assert output.read_bytes() == b"P5\n# DCP-J315W network scan, 300 dpi\n16 2\n255\n" + pixels[:32]
    print("PASS: 300 dpi and an offset scan area are encoded and decoded correctly")
    output.write_bytes(b"existing scan")
    result = subprocess.run([binary, "--scan", "127.0.0.1", output], capture_output=True, timeout=2)
    assert result.returncode == 1 and output.read_bytes() == b"existing scan", result
    print("PASS: an existing output file is preserved without connecting or scanning")
    output = Path(tmp) / "colour.ppm"
    result = exercise("complete", output, colour=True)
    assert result[0] == 0, result
    assert output.read_bytes() == b"P6\n# DCP-J315W network scan, 100 dpi\n32 4\n255\n" + rgb
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    print("PASS: fragmented colour planes produce correct RGB vectors, clipping and neutral tones")
    output.unlink()
    for kind in ("wrong-plane", "incomplete-colour-row", "missing-end", "bad-width", "cancel"):
        result = exercise(kind, output, colour=True)
        assert result[0] == 1 and not output.exists(), (kind, result)
        print(f"PASS: colour {kind} fails without exposing an incomplete image")
    if os.uname().sysname == "Darwin":
        output = Path(tmp) / "scan.png"
        result = exercise("complete", output, dpi=300)
        assert result[0] == 0 and output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), result
        assert stat.S_IMODE(output.stat().st_mode) == 0o600
        assert not list(Path(tmp).glob("*.partial.*"))
        print("PASS: native PNG export is private and leaves no staging directory")
        output = Path(tmp) / "colour.png"
        result = exercise("complete", output, dpi=300, colour=True)
        assert result[0] == 0 and output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), result
        assert stat.S_IMODE(output.stat().st_mode) == 0o600
        assert not list(Path(tmp).glob("*.partial.*"))
        info = subprocess.run(["sips", "-g", "space", "-g", "dpiWidth", "-g", "dpiHeight", output],
                              capture_output=True, text=True, check=True).stdout
        assert "space: RGB" in info and "dpiWidth: 300" in info and "dpiHeight: 300" in info, info
        print("PASS: colour PNG uses RGB, correct DPI metadata and private output")

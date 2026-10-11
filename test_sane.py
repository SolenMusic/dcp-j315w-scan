#!/usr/bin/env python3
"""Exercise the installed backend through libSANE and scanimage, on loopback only."""
import ctypes as C
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parent
GOOD, UNSUPPORTED, CANCELLED, BUSY, INVAL, EOF, IO_ERROR = 0, 1, 2, 3, 4, 5, 9

class Device(C.Structure):
    _fields_ = [(n, C.c_char_p) for n in ('name', 'vendor', 'model', 'type')]
class Parameters(C.Structure):
    _fields_ = [(n, C.c_int) for n in ('format', 'last_frame', 'bytes_per_line', 'pixels_per_line', 'lines', 'depth')]
class Descriptor(C.Structure):
    _fields_ = [(n, C.c_char_p) for n in ('name', 'title', 'desc')] + [(n, C.c_int) for n in ('type', 'unit', 'size', 'cap', 'constraint_type')]

sane = C.CDLL('libsane.so.1')
sane.sane_init.argtypes = [C.POINTER(C.c_int), C.c_void_p]
sane.sane_get_devices.argtypes = [C.POINTER(C.POINTER(C.POINTER(Device))), C.c_int]
sane.sane_open.argtypes = [C.c_char_p, C.POINTER(C.c_void_p)]
sane.sane_get_option_descriptor.argtypes = [C.c_void_p, C.c_int]
sane.sane_get_option_descriptor.restype = C.POINTER(Descriptor)
sane.sane_control_option.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_void_p, C.POINTER(C.c_int)]
sane.sane_get_parameters.argtypes = [C.c_void_p, C.POINTER(Parameters)]
sane.sane_start.argtypes = [C.c_void_p]
sane.sane_read.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.POINTER(C.c_int)]
sane.sane_cancel.argtypes = [C.c_void_p]
sane.sane_cancel.restype = None
sane.sane_close.argtypes = [C.c_void_p]
sane.sane_close.restype = None
sane.sane_set_io_mode.argtypes = [C.c_void_p, C.c_int]
sane.sane_get_select_fd.argtypes = [C.c_void_p, C.POINTER(C.c_int)]
sane.sane_exit.restype = None

wire_vectors = [(128, 0, 128), (128, 255, 128), (255, 76, 85), (21, 150, 44),
                (107, 29, 255), (128, 128, 128), (0, 0, 0), (255, 255, 255)]
rgb_vectors = [(0,0,0), (255,255,255), (254,0,0), (0,255,1),
               (0,0,254), (128,128,128), (0,135,0), (255,121,255)]
def gray(x, y): return (13*x+29*y) % 256

def receive_request(conn):
    data = bytearray()
    while not data.endswith(b'\x80'):
        part = conn.recv(1)
        assert part, data
        data += part
        assert len(data) <= 512
    return bytes(data)

class Scanner:
    def __init__(self, kind='complete', full_rows=4):
        self.kind, self.full_rows = kind, full_rows
        self.scanning = threading.Event()
        self.errors = []
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(('127.0.0.1', 54921))
        self.listener.listen(1)
        self.listener.settimeout(8)
        self.thread = threading.Thread(target=self.run)
        self.thread.start()
    def run(self):
        try:
            with self.listener.accept()[0] as conn:
                conn.settimeout(8)
                for part in [b'+OK', b' 200\r', b'\n']: conn.sendall(part)
                info_req = receive_request(conn).decode('latin1')
                dpi = int(info_req.split('R=')[1].split(',')[0])
                colour = 'M=CGRAY\n' in info_req
                width, height = (826, 1157) if dpi == 100 else (2480, 3472)
                info = f'{dpi},{dpi},2,209,{width},294,{height}'.encode()
                conn.sendall(b'\0' + len(info).to_bytes(2, 'little') + info)
                req = receive_request(conn).decode('latin1')
                assert req.startswith('\x1bX\n')
                x,y,right,bottom = map(int, req.split('A=')[1].split('\n')[0].split(','))
                self.area = x,y,right,bottom
                self.dpi = dpi
                self.scanning.set()
                if self.kind == 'cancel':
                    conn.sendall(bytes([0x44 if colour else 0x40]) + (right-x).to_bytes(2,'little') + b'\x00')
                    assert conn.recv(2) == b'\x1bR'
                    return
                rows = min(bottom-y, self.full_rows) if bottom-y > 20 else bottom-y
                self.rows = rows
                for row in range(y,y+rows):
                    for plane in range(3 if colour else 1):
                        samples = bytes(wire_vectors[(i+row)%8][plane] if colour else gray(i,row) for i in range(x,right))
                        record = bytes([0x44+plane*4 if colour else 0x40]) + len(samples).to_bytes(2,'little') + samples
                        for start in range(0,len(record),13): conn.sendall(record[start:start+13])
                if self.kind != 'incomplete': conn.sendall(b'\x80')
        except Exception as exc:
            self.errors.append(exc)
        finally:
            self.listener.close()
    def finish(self):
        self.thread.join(10)
        assert not self.thread.is_alive() and not self.errors, self.errors

def open_handle():
    h = C.c_void_p()
    assert sane.sane_open(b'dcpj315w:127.0.0.1', C.byref(h)) == GOOD
    return h

def option_map(h):
    count = C.c_int()
    assert sane.sane_control_option(h,0,0,C.byref(count),None) == GOOD
    return {sane.sane_get_option_descriptor(h,i).contents.name.decode(): i for i in range(1,count.value)}

def set_option(h, name, value):
    idx = option_map(h)[name]
    if isinstance(value, str): data = C.create_string_buffer(value.encode(),16)
    else: data = C.c_int(value)
    info = C.c_int()
    status = sane.sane_control_option(h,idx,1,C.byref(data),C.byref(info))
    return status, info.value

def mm(pixels, dpi=300): return round(pixels*25.4/dpi*65536)

def area(h, x, y, width, height, dpi=300):
    for name, value in zip(('tl-x','tl-y','br-x','br-y'), (x,y,x+width,y+height)):
        assert set_option(h,name,mm(value,dpi))[0] == GOOD

def read_all(h):
    data = bytearray()
    buf, length = C.create_string_buffer(7), C.c_int()
    while True:
        status = sane.sane_read(h,buf,7,C.byref(length))
        if status == EOF:
            assert length.value == 0
            return bytes(data)
        assert status == GOOD and 0 < length.value <= 7, (status,length.value)
        data += buf.raw[:length.value]

def parameters(h):
    p = Parameters()
    assert sane.sane_get_parameters(h,C.byref(p)) == GOOD
    return p

with tempfile.TemporaryDirectory(prefix='dcp-sane-test-') as tmp:
    config = Path(tmp)/'config'
    config.mkdir()
    (config/'dll.conf').write_text('dcpj315w\n')
    (config/'dcpj315w.conf').write_text('# loopback fixture\ninvalid\n127.0.0.1\n127.0.0.1 # duplicate\n')
    os.environ['SANE_CONFIG_DIR'] = str(config)
    assert sane.sane_init(None,None) == GOOD
    devices = C.POINTER(C.POINTER(Device))()
    assert sane.sane_get_devices(C.byref(devices),0) == GOOD
    assert devices[0].contents.name == b'dcpj315w:127.0.0.1' and not devices[1]
    assert sane.sane_get_devices(C.byref(devices),1) == GOOD and not devices[0]
    listing = subprocess.run(['scanimage','-L'],capture_output=True,text=True,timeout=10)
    assert listing.returncode == 0 and 'dcpj315w:127.0.0.1' in listing.stdout, listing
    h = open_handle()
    help_result = subprocess.run(['scanimage','-d','dcpj315w:127.0.0.1','--help'],capture_output=True,text=True,timeout=10)
    assert help_result.returncode == 0 and 'Color|Gray|Lineart' in help_result.stdout, help_result
    assert set_option(h,'resolution',600)[0] == INVAL
    assert set_option(h,'mode','Invalid')[0] == INVAL
    assert set_option(h,'source','ADF')[0] == INVAL
    print('PASS: stock libSANE loader and scanimage discover the backend and expose valid options')

    for mode in ('Color','Gray','Lineart'):
        sane.sane_cancel(h)
        assert set_option(h,'mode',mode)[0] == GOOD
        area(h,7,3,73,6)
        fixture = Scanner()
        assert sane.sane_start(h) == GOOD
        p = parameters(h)
        assert (p.pixels_per_line,p.lines,p.depth,p.last_frame) == (73,6,1 if mode == 'Lineart' else 8,1)
        assert sane.sane_set_io_mode(h,0) == GOOD
        assert sane.sane_set_io_mode(h,1) == UNSUPPORTED
        assert sane.sane_get_select_fd(h,C.byref(C.c_int())) == UNSUPPORTED
        assert set_option(h,'mode','Gray')[0] == BUSY
        result = read_all(h)
        fixture.finish()
        assert fixture.area == (0,3,80,9), fixture.area
        if mode == 'Color':
            expected = bytes(v for y in range(3,9) for x in range(7,80) for v in rgb_vectors[(x+y)%8])
        elif mode == 'Gray':
            expected = bytes(gray(x,y) for y in range(3,9) for x in range(7,80))
        else:
            packed = bytearray()
            for y in range(3,9):
                for start in range(7,80,8):
                    packed.append(sum(0x80 >> bit for bit in range(min(8,80-start)) if gray(start+bit,y) < 128))
            expected = bytes(packed)
        assert result == expected, (mode, result[:30], expected[:30])
        print(f'PASS: {mode} exact offset crop, real line count, short reads, and end of frame')

    sane.sane_cancel(h)
    assert set_option(h,'mode','Gray')[0] == GOOD
    assert set_option(h,'preview',1)[0] == GOOD
    area(h,0,0,816,1145,100)
    assert parameters(h).pixels_per_line == 816
    fixture = Scanner()
    assert sane.sane_start(h) == GOOD
    assert (parameters(h).pixels_per_line,parameters(h).lines) == (816,4)
    assert len(read_all(h)) == 816*4
    fixture.finish()
    assert fixture.dpi == 100
    print('PASS: preview uses 100 dpi and a short physical page is not padded or truncated')

    fixture = Scanner('incomplete')
    assert sane.sane_start(h) == IO_ERROR
    fixture.finish()
    buf, count = C.create_string_buffer(8), C.c_int(99)
    assert sane.sane_read(h,buf,8,C.byref(count)) == INVAL and count.value == 0
    print('PASS: failed transfer exposes no image bytes')

    fixture = Scanner('cancel')
    statuses = []
    worker = threading.Thread(target=lambda: statuses.append(sane.sane_start(h)))
    worker.start()
    assert fixture.scanning.wait(5)
    other = open_handle()
    assert sane.sane_start(other) == BUSY
    sane.sane_cancel(h)
    worker.join(10)
    fixture.finish()
    assert not worker.is_alive() and statuses == [CANCELLED], statuses
    assert sane.sane_read(h,buf,8,C.byref(count)) == CANCELLED and count.value == 0
    sane.sane_close(other)
    print('PASS: concurrent handle is busy; asynchronous cancel sends device reset and returns no partial image')
    sane.sane_close(h)
    sane.sane_exit()

    # A real frontend exports a complete portable image; no ctypes shortcut.
    fixture = Scanner()
    result = subprocess.run(['scanimage','-d','dcpj315w:127.0.0.1','--mode','Color','--resolution','300',
                             '-l','0','-t','0','-x','10','-y','1','--format=pnm'],capture_output=True,timeout=15)
    fixture.finish()
    assert result.returncode == 0, result.stderr
    header, pixels = result.stdout.split(b'\n255\n',1)
    width = round(10*300/25.4)
    assert f'{width} {fixture.rows}'.encode() in header and header.startswith(b'P6\n'), header
    expected = bytes(v for y in range(fixture.rows) for x in range(width) for v in rgb_vectors[(x+y)%8])
    assert pixels == expected
    print('PASS: scanimage exports a complete RGB PPM with exact decoded pixels')
print('All SANE integration checks passed (simulated scanner; no physical hardware).')

#!/usr/bin/env python3
"""Loopback-only AirScan/core integration; no Bonjour and no physical scanner."""
from pathlib import Path
from io import BytesIO
from PIL import Image
import http.client
import os
import platform
import queue
import re
import socket
import struct
import subprocess
import threading
import time
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
binary = Path(os.environ.get('DCP_AIRSCAN_BINARY', root / 'build/DCPJ315WAirScanBridge.app/Contents/MacOS/DCPJ315WAirScanBridge'))
# Test only this Mac's native slice. Forcing the production app under Rosetta
# records it in macOS's Intel-app history and can generate a misleading
# macOS 28 compatibility notification. Intel coverage uses the Intel CI runner.
hardware = subprocess.run(['/usr/sbin/sysctl','-n','hw.optional.arm64'], capture_output=True, text=True)
if hardware.returncode == 0 and hardware.stdout.strip() in ('0','1'):
    native_arch = 'arm64' if hardware.stdout.strip() == '1' else 'x86_64'
elif platform.machine() == 'arm64':
    native_arch = 'arm64'
elif 'unknown oid' in hardware.stderr.lower() and platform.machine() == 'x86_64':
    # Older Intel macOS versions do not expose the Apple Silicon capability.
    native_arch = 'x86_64'
else:
    raise SystemExit('Cannot verify this Mac\'s native hardware architecture; allow the sysctl query before testing.')
requested_arch = os.environ.get('DCP_AIRSCAN_ARCH', native_arch)
if requested_arch != native_arch:
    raise SystemExit(f'Run {requested_arch} tests on a native {requested_arch} Mac or CI runner; this Mac tests {native_arch} without Rosetta.')
if subprocess.run(['/usr/bin/lipo', str(binary), '-verify_arch', native_arch], capture_output=True).returncode:
    raise SystemExit(f'The test helper must include a native {native_arch} slice. Build it before testing.')
# (Cr,Y,Cb) input and independent expected RGB output.
vectors = [(128,0,128),(128,255,128),(255,76,85),(21,150,44),
           (107,29,255),(128,128,128),(0,0,0),(255,255,255)]
rgb = [(0,0,0),(255,255,255),(254,0,0),(0,255,1),
       (0,0,254),(128,128,128),(0,135,0),(255,121,255)]
gray = [0,64,127,128,200,255,1,254]
def pixels(image):
    return list(image.get_flattened_data() if hasattr(image,'get_flattened_data') else image.getdata())


def exact(conn,n):
    data=bytearray()
    while len(data)<n:
        p=conn.recv(n-len(data))
        if not p: raise EOFError('unexpected connection close')
        data.extend(p)
    return bytes(data)


def command(conn):
    data=bytearray()
    while not data.endswith(b'\x80'):
        data.extend(exact(conn,1))
        assert len(data)<512
    return bytes(data)


class Scanner:
    def __init__(self):
        self.listener=socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        self.listener.bind(('127.0.0.1',54921))
        self.listener.listen(4);self.listener.settimeout(.2)
        self.plans=queue.Queue();self.errors=[];self.count=0
        self.stop=False;self.partial=threading.Event();self.cancelled=threading.Event()
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
    def run(self):
        while not self.stop:
            try:conn,_=self.listener.accept()
            except socket.timeout:continue
            except OSError:break
            self.count+=1
            try:
                with conn:
                    conn.settimeout(10);kind=self.plans.get(timeout=3)
                    conn.sendall(b'+OK 200\r\n')
                    info=command(conn)
                    dpi=int(re.search(rb'R=(\d+)',info)[1]);colour=b'M=CGRAY\n' in info
                    caps=f'{dpi},{dpi},2,209,96,294,12'.encode()
                    conn.sendall(b'\0'+len(caps).to_bytes(2,'little')+caps)
                    scan=command(conn)
                    left,top,right,bottom=map(int,re.search(rb'A=(\d+),(\d+),(\d+),(\d+)',scan).groups())
                    width=right-left;height=bottom-top
                    assert width%16==0 and right<=96 and bottom<=12
                    if kind=='cancel':
                        conn.sendall(bytes([0x44 if colour else 0x40])+width.to_bytes(2,'little')+bytes(4))
                        self.partial.set()
                        assert exact(conn,2)==b'\x1bR'
                        self.cancelled.set();conn.sendall(b'\x83');continue
                    if kind=='slow':time.sleep(1.4)
                    if kind=='incomplete':height=1
                    for y in range(height):
                        for plane in range(3 if colour else 1):
                            data=bytes(vectors[(left+x+top+y)%8][plane] if colour else gray[(left+x+top+y)%8] for x in range(width))
                            record=bytes([0x44+plane*4 if colour else 0x40])+width.to_bytes(2,'little')+data
                            for i in range(0,len(record),7):conn.sendall(record[i:i+7])
                    if kind!='incomplete':conn.sendall(b'\x80')
            except Exception as e:self.errors.append(e)
    def close(self):
        self.stop=True;self.listener.close();self.thread.join(timeout=3)
        assert not self.thread.is_alive() and not self.errors,self.errors


def settings(dpi=300,mode='RGB24',mime='image/png',x=7,y=3,w=72,h=6):
    return f'''<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
    <pwg:ScanRegions><pwg:ScanRegion><pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
    <pwg:XOffset>{x}</pwg:XOffset><pwg:YOffset>{y}</pwg:YOffset><pwg:Width>{w}</pwg:Width><pwg:Height>{h}</pwg:Height>
    </pwg:ScanRegion></pwg:ScanRegions><scan:XResolution>{dpi}</scan:XResolution><scan:YResolution>{dpi}</scan:YResolution>
    <scan:ColorMode>{mode}</scan:ColorMode><pwg:InputSource>Platen</pwg:InputSource><pwg:DocumentFormat>{mime}</pwg:DocumentFormat></scan:ScanSettings>'''.encode()


scanner=Scanner()
command_line=['/usr/bin/arch','-'+native_arch,binary,'--address','127.0.0.1','--no-discovery']
process=subprocess.Popen(command_line,stderr=subprocess.PIPE,stdout=subprocess.DEVNULL,text=True)
logs=queue.Queue()
def logging():
    for line in process.stderr:logs.put(line)
reader=threading.Thread(target=logging,daemon=True);reader.start()
try:
    deadline=time.monotonic()+10;port=None
    while time.monotonic()<deadline:
        line=logs.get(timeout=10)
        match=re.search(r'listening only on 127.0.0.1:(\d+)',line)
        if match:port=int(match[1]);break
    assert port
    def request(method,path,body=None,headers=None):
        c=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
        c.request(method,path,body,headers if headers is not None else {'Content-Type':'text/xml'} if body else {})
        r=c.getresponse();result=(r.status,dict(r.getheaders()),r.read());c.close();return result
    def create(body):
        result=request('POST','/eSCL/ScanJobs',body)
        assert result[0]==201,result
        return result[1]['Location'].split(f':{port}',1)[1]
    def fetch(path):
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            result=request('GET',path+'/NextDocument')
            if result[0]!=503:return result
        raise AssertionError('image never became ready')
    caps=request('GET','/eSCL/ScannerCapabilities')
    assert caps[0]==200;ET.fromstring(caps[2])
    assert b'RGB24' in caps[2] and b'Grayscale8' in caps[2]
    print('PASS: capabilities XML is valid and lists supported modes')
    assert request('POST','/eSCL/ScanJobs',settings(),{'Content-Type':'text/xml','Origin':'https://example.invalid'})[0]==403
    assert request('POST','/eSCL/ScanJobs',settings(),{'Content-Type':'text/plain'})[0]==415
    assert scanner.count==0
    print('PASS: browser-origin and non-XML job submissions are rejected before scanning')
    # Native Image Capture probes defaults then cancels: it must not touch hardware.
    probe=create(b'<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"><scan:ColorMode>BlackAndWhite1</scan:ColorMode></scan:ScanSettings>')
    assert request('DELETE',probe)[0]==200 and scanner.count==0
    print('PASS: native default-settings probe can be cancelled without starting hardware')
    bad=settings().replace(b'<scan:XResolution>300',b'<scan:XResolution>600')
    assert request('POST','/eSCL/ScanJobs',bad)[0]==400 and scanner.count==0
    dtd=b'<!DOCTYPE scan [<!ENTITY x SYSTEM "file:///etc/passwd">]>'+settings()
    assert request('POST','/eSCL/ScanJobs',dtd)[0]==400 and scanner.count==0
    print('PASS: unsupported settings and external-entity declarations are rejected before scanning')
    # Leave a new connection idle briefly, then fragment every header/body. This
    # catches accepted sockets accidentally inheriting O_NONBLOCK from listener.
    wire=(f'POST /eSCL/ScanJobs HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/xml\r\nContent-Length: {len(settings())}\r\n\r\n').encode()+settings()
    with socket.create_connection(('127.0.0.1',port),3) as sock:
        time.sleep(.06)
        for i in range(0,len(wire),11):sock.sendall(wire[i:i+11])
        response=http.client.HTTPResponse(sock);response.begin();assert response.status==201
        path=response.getheader('Location').split(f':{port}',1)[1];response.read()
    scanner.plans.put('complete');result=fetch(path)
    assert result[0]==200 and result[1]['Content-Type']=='image/png'
    with Image.open(BytesIO(result[2])) as image:
        assert image.mode=='RGB' and image.size==(72,6)
        expected=[rgb[(7+x+3+y)%8] for y in range(6) for x in range(72)]
        assert pixels(image)==expected
        assert abs(image.info['dpi'][0]-300)<.1
    assert fetch(path)[0]==404
    request('DELETE',path)
    print('PASS: fragmented HTTP and colour records preserve exact offset crop, RGB pixels and DPI')
    for mode in ('Grayscale8','BlackAndWhite1'):
        scanner.plans.put('complete');path=create(settings(mode=mode,x=3,w=73))
        result=fetch(path);assert result[0]==200
        with Image.open(BytesIO(result[2])) as image:
            assert image.size==(73,6)
            expected=[gray[(3+x+3+y)%8] for y in range(6) for x in range(73)]
            if mode=='BlackAndWhite1':expected=[255 if v>=128 else 0 for v in expected];assert image.mode=='1'
            else:assert image.mode=='L'
            assert pixels(image)==expected
        request('DELETE',path)
    print('PASS: grayscale and true one-bit PNGs crop correctly, including partial final bytes')
    scanner.plans.put('complete');path=create(settings(mime='image/jpeg'));result=fetch(path)
    assert result[0]==200 and result[1]['Content-Type']=='image/jpeg'
    with Image.open(BytesIO(result[2])) as image:assert image.mode=='RGB' and image.size==(72,6)
    request('DELETE',path)
    print('PASS: native-compatible JPEG transport returns the declared format')
    scanner.plans.put('slow');path=create(settings())
    with socket.create_connection(('127.0.0.1',port),3) as sock:
        sock.sendall(f'GET {path}/NextDocument HTTP/1.1\r\nHost: localhost\r\n\r\n'.encode())
        time.sleep(.1);sock.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0))
    time.sleep(1.7);result=fetch(path)
    assert result[0]==200 and result[2].startswith(b'\x89PNG')
    request('DELETE',path)
    print('PASS: a disconnected document request does not consume the completed image')
    scanner.plans.put('incomplete');path=create(settings());assert fetch(path)[0]==404
    request('DELETE',path)
    print('PASS: incomplete hardware transfer never becomes a downloadable image')
    scanner.plans.put('cancel');path=create(settings());results=[]
    getter=threading.Thread(target=lambda:results.append(fetch(path)));getter.start()
    assert scanner.partial.wait(4)
    assert request('POST','/eSCL/ScanJobs',settings())[0]==503
    assert request('DELETE',path)[0]==200
    getter.join(timeout=5);assert not getter.is_alive() and results[0][0]==404
    assert scanner.cancelled.wait(3)
    print('PASS: busy jobs are rejected and cancellation reaches hardware without an image')
finally:
    process.terminate();process.wait(timeout=7)
    scanner.close()
    assert process.returncode==0,process.returncode
print('PASS: bridge exits cleanly and removes its loopback listener')

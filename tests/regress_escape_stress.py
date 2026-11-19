#!/usr/bin/env python3
"""Deterministic PTY/ANSI/parser + X11 resize stress test.

Run: xvfb-run -a python3 tests/regress_escape_stress.py ./fastst-compat-gas
"""
import ctypes as C
import os
import random
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from regress_scrollback_input import x, wait, find_window

BINARY = str(Path(sys.argv[1]).resolve())
XResizeWindow = x.XResizeWindow
XResizeWindow.argtypes = [C.c_void_p, C.c_ulong, C.c_uint, C.c_uint]
XResizeWindow.restype = C.c_int
x.XSync.argtypes = [C.c_void_p, C.c_int]

FIXTURE = '''import os, sys, tty, time
from pathlib import Path
tty.setraw(0)
data=Path(sys.argv[1], 'payload').read_bytes()
for i in range(0,len(data),32768):
  chunk=memoryview(data)[i:i+32768]
  while chunk:
    n=os.write(1,chunk)
    chunk=chunk[n:]
Path(sys.argv[1], 'ready').touch()
time.sleep(9)
'''

def generate():
    rng=random.Random(0xfaf50)
    chunks=[]
    alphabet=[b'abc 123456789 \r\n', b'\x1b[2J\x1b[H', b'\x1b[3J',
              b'\x1b[?1049h',b'\x1b[?1049l',b'\x1b[0m',
              b'\x1b[48;2;255;0;30m',b'\x1b[38;5;219m',
              b'\x1b[>4;m',b'\x1b[12;20H',b'\x1b[?25l',b'\x1b[?25h',
              b'\x1b[1;12r',b'\x1b[r',b'\x1b[12P',b'\x1b[9@',
              b'\xe2\x96\xbd',b'\xe4\xb8\xad\xe6\x96\x87',b'\xf0\x9f\x98\x80',
              b'\xf4\xbf\xbf\xbf',b'\xed\xa0\x80', b'\xc0\xaf',b'\xff',
              b'\x1b]2;'+b't'*700+b'\x07',
              b'\x1b[65535S',b'\x1b[65535T',b'\x1b[65535L',b'\x1b[65535M',
              b'\x1b[65535P',b'\x1b[65535@',b'\x1b[65535X',
              b'\x1b[65535;65535H',b'\x1b[99999999;3m']
    # Weighted, bounded hostile control cases and a large amount of normal text.
    for i in range(1200):
        chunks.append(alphabet[rng.randrange(len(alphabet)) if i%53 else 0])
        if i%7==0:
            chunks.append(b'ASCII fast path: '+b'abcdefghijklmnopqrstuvwxyz0123456789'*10+b'\r\n')
    chunks.append(b'\x1b[?1049l\x1b[r\x1b[0m\x1b[2J\x1b[Hstress-complete\r\n')
    return b''.join(chunks)

def main():
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp,'fixture.py').write_text(FIXTURE)
        payload=generate()
        Path(tmp,'payload').write_bytes(payload)
        proc=subprocess.Popen([BINARY,'-e',sys.executable,'-u',str(Path(tmp,'fixture.py')),tmp],stderr=subprocess.PIPE)
        d=x.XOpenDisplay(None)
        if not d:raise RuntimeError('XOpenDisplay failed')
        try:
            win=wait(find_window,8)
            for i in range(70):
                # Mix small, normal and large geometries while parsing output.
                w,h=[(12,12),(160,70),(640,420),(1230,850),(3200,1600)][i%5]
                XResizeWindow(d,win,w,h)
                x.XFlush(d)
                time.sleep(.007)
            XResizeWindow(d,win,800,510)
            x.XSync(d,0)
            wait(lambda: Path(tmp,'ready').exists(),12)
            time.sleep(.8)
            assert proc.poll() is None,f'terminal died during stress: {proc.returncode}'
            print(f'PASS: {len(payload):,} PTY bytes (ANSI/OSC/UTF-8/CSI), 71 resizes; no crash or hang')
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:proc.kill()

if __name__=='__main__':main()

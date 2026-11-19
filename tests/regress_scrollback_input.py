#!/usr/bin/env python3
"""Xvfb regression: PgUp/PgDn, keyboard snap-to-live, selection scroll binding.

Run: xvfb-run -a python3 tests/regress_scrollback_input.py ./fastst
Requires Xvfb, libX11 and xwininfo; no OCR or extra input-injection tools.
"""
import ctypes as C
import ctypes.util
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BIN = str(Path(sys.argv[1] if len(sys.argv)>1 else './fastst').resolve())
CHILD = r'''import os, sys, time, tty
from pathlib import Path
p = Path(sys.argv[1])
tty.setraw(0)
sys.stdout.write('\033[?25l\033[2J\033[H')
for i in range(180): sys.stdout.write(f'line {i:04d}  abcdefghijklmnopqrstuvwxyz\r\n')
sys.stdout.write('LIVE PROMPT>')
sys.stdout.flush()
(p/'ready').touch()
ch = os.read(0,1)
(p/'char').write_bytes(ch)
time.sleep(2)
'''

class XImage(C.Structure):
    _fields_ = [('width',C.c_int),('height',C.c_int),('xoffset',C.c_int),
                ('format',C.c_int),('data',C.c_void_p),('byte_order',C.c_int),
                ('bitmap_unit',C.c_int),('bitmap_bit_order',C.c_int),
                ('bitmap_pad',C.c_int),('depth',C.c_int),
                ('bytes_per_line',C.c_int),('bits_per_pixel',C.c_int)]

class XKeyEvent(C.Structure):
    _fields_=[('type',C.c_int),('serial',C.c_ulong),('send_event',C.c_int),
             ('display',C.c_void_p),('window',C.c_ulong),('root',C.c_ulong),
             ('subwindow',C.c_ulong),('time',C.c_ulong),('x',C.c_int),
             ('y',C.c_int),('x_root',C.c_int),('y_root',C.c_int),
             ('state',C.c_uint),('keycode',C.c_uint),('same_screen',C.c_int)]

class XButtonEvent(C.Structure):
    _fields_=[('type',C.c_int),('serial',C.c_ulong),('send_event',C.c_int),
             ('display',C.c_void_p),('window',C.c_ulong),('root',C.c_ulong),
             ('subwindow',C.c_ulong),('time',C.c_ulong),('x',C.c_int),
             ('y',C.c_int),('x_root',C.c_int),('y_root',C.c_int),
             ('state',C.c_uint),('button',C.c_uint),('same_screen',C.c_int)]

x = C.CDLL(C.util.find_library('X11'))
x.XOpenDisplay.argtypes=[C.c_char_p]; x.XOpenDisplay.restype=C.c_void_p
x.XCloseDisplay.argtypes=[C.c_void_p]
x.XGetImage.argtypes=[C.c_void_p,C.c_ulong,C.c_int,C.c_int,C.c_uint,C.c_uint,C.c_ulong,C.c_int]
x.XGetImage.restype=C.POINTER(XImage)
x.XSendEvent.argtypes=[C.c_void_p,C.c_ulong,C.c_int,C.c_long,C.c_void_p]
x.XSendEvent.restype=C.c_int
x.XKeysymToKeycode.argtypes=[C.c_void_p,C.c_ulong]; x.XKeysymToKeycode.restype=C.c_uint
x.XFlush.argtypes=[C.c_void_p]
x.XFree.argtypes=[C.c_void_p]


def wait(fn, seconds=6):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        z=fn()
        if z:return z
        time.sleep(.03)
    raise TimeoutError('waiting for test stage')


def find_window():
    r=subprocess.run(['xwininfo','-root','-tree'], text=True,capture_output=True)
    for line in r.stdout.splitlines():
        if 'fastst' in line:
            m=re.search(r'0x[0-9a-fA-F]+',line)
            if m:return int(m[0],16)


def size(win):
    attrs=subprocess.check_output(['xwininfo','-id',hex(win)],text=True)
    return (int(re.search(r'Width:\s+(\d+)',attrs)[1]),
            int(re.search(r'Height:\s+(\d+)',attrs)[1]))


def grab(d, win, width, height):
    img=x.XGetImage(d,win,0,0,width,height,C.c_ulong(-1).value,2)
    if not img:raise RuntimeError('XGetImage failed')
    assert img.contents.bits_per_pixel==32
    stride=img.contents.bytes_per_line
    pixels=C.string_at(img.contents.data,stride*height)
    x.XFree(img.contents.data);x.XFree(img)
    return (pixels,stride)


def sample(frame, cx, cy):
    pixels,stride=frame
    i=cy*stride+cx*4
    return pixels[i:i+3]


def send_key(d, win, sym, state=0):
    ev=XKeyEvent(2,0,1,d,win,0,0,0,10,10,10,10,state,x.XKeysymToKeycode(d,sym),1)
    assert x.XSendEvent(d,win,0,1,C.byref(ev)),hex(sym)
    x.XFlush(d)


def send_mouse(d,win,typ,button,cx,cy,state=0):
    ev=XButtonEvent(typ,0,1,d,win,0,0,0,cx,cy,cx,cy,state,button,1)
    mask={4:4,5:8,6:64}[typ]
    assert x.XSendEvent(d,win,0,mask,C.byref(ev))
    x.XFlush(d)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        fixture=Path(tmp,'fixture.py');fixture.write_text(CHILD)
        proc=subprocess.Popen([BIN,'-e',sys.executable,'-u',str(fixture),tmp],stderr=subprocess.PIPE)
        d=x.XOpenDisplay(None)
        try:
            win=wait(find_window)
            wait(lambda: Path(tmp,'ready').exists())
            w,h=size(win)
            cw=(w-6)//80;ch=(h-6)//24
            time.sleep(.2)
            live=grab(d,win,w,h)
            send_key(d,win,0xff55)  # Page Up
            time.sleep(.2)
            up=grab(d,win,w,h)
            assert up[0]!=live[0], 'Page Up did not scroll history'
            send_key(d,win,0xff56)  # Page Down
            time.sleep(.2)
            down=grab(d,win,w,h)
            assert down==live, 'Page Down did not return to the live screen'
            send_key(d,win,0xff55)
            time.sleep(.15)
            send_key(d,win,ord('z'))
            wait(lambda: Path(tmp,'char').exists())
            assert Path(tmp,'char').read_bytes()==b'z', 'typing never reached the PTY'
            time.sleep(.2)
            typed=grab(d,win,w,h)
            assert typed==live, 'typed input did not snap the view back to live'

            # Start selection on visible live row 5, extend it to the right.
            x0=3+3*cw+1; y0=3+5*ch+2
            x1=3+15*cw+1
            send_mouse(d,win,4,1,x0,y0)
            send_mouse(d,win,6,1,x1,y0,256)
            send_mouse(d,win,5,1,x1,y0)
            time.sleep(.2)
            selected=grab(d,win,w,h)
            px=3+8*cw+1
            c0=sample(selected,px,3+5*ch+1)
            assert c0!=sample(live,px,3+5*ch+1), 'selection highlight missing at anchor row'
            send_mouse(d,win,4,4,px,3+5*ch+2) # wheel up: 3 lines
            time.sleep(.2)
            shifted=grab(d,win,w,h)
            c1=sample(shifted,px,3+8*ch+1)
            assert c1==c0, f'selection did not move with content: {c0!r} -> {c1!r}'
            print('PASS: Page Up/Down, typed input snaps live, selection highlight follows content')
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:proc.kill()

if __name__=='__main__':main()

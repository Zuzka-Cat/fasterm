#!/usr/bin/env python3
"""End-to-end PTY paste backpressure, wrapped-history resize, and cell metrics.

Run: xvfb-run -a python3 tests/regress_paste_resize.py ./fasterm
"""
import ctypes as C
import ctypes.util
import hashlib
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from regress_scrollback_input import (find_window, grab, sample, send_key, size,
                                      wait, x)

BIN = str(Path(sys.argv[1] if len(sys.argv) > 1 else './fasterm').resolve())

OWNER = r'''
import ctypes as C, ctypes.util, sys, time
from pathlib import Path
x=C.CDLL(C.util.find_library('X11'))
x.XOpenDisplay.argtypes=[C.c_char_p];x.XOpenDisplay.restype=C.c_void_p
x.XDefaultRootWindow.argtypes=[C.c_void_p];x.XDefaultRootWindow.restype=C.c_ulong
x.XCreateSimpleWindow.argtypes=[C.c_void_p,C.c_ulong,C.c_int,C.c_int,C.c_uint,C.c_uint,C.c_uint,C.c_ulong,C.c_ulong];x.XCreateSimpleWindow.restype=C.c_ulong
x.XInternAtom.argtypes=[C.c_void_p,C.c_char_p,C.c_int];x.XInternAtom.restype=C.c_ulong
x.XSetSelectionOwner.argtypes=[C.c_void_p,C.c_ulong,C.c_ulong,C.c_ulong]
x.XChangeProperty.argtypes=[C.c_void_p,C.c_ulong,C.c_ulong,C.c_ulong,C.c_int,C.c_int,C.c_void_p,C.c_int]
x.XNextEvent.argtypes=[C.c_void_p,C.c_void_p]
x.XSendEvent.argtypes=[C.c_void_p,C.c_ulong,C.c_int,C.c_long,C.c_void_p];x.XSendEvent.restype=C.c_int
x.XSync.argtypes=[C.c_void_p,C.c_int]
x.XFlush.argtypes=[C.c_void_p]
base=Path(sys.argv[1]);raw=(base/'payload').read_bytes()
d=x.XOpenDisplay(None);assert d
win=x.XCreateSimpleWindow(d,x.XDefaultRootWindow(d),0,0,1,1,0,0,0)
clip=x.XInternAtom(d,b'CLIPBOARD',0);utf=x.XInternAtom(d,b'UTF8_STRING',0)
x.XSetSelectionOwner(d,clip,win,0);x.XSync(d,0)
(base/'owner_ready').touch()
ev=C.create_string_buffer(192)
while True:
 x.XNextEvent(d,ev)
 if C.c_int.from_buffer(ev).value!=30:continue
 req=C.c_ulong.from_buffer(ev,40).value
 target=C.c_ulong.from_buffer(ev,56).value
 prop=C.c_ulong.from_buffer(ev,64).value or target
 if target==utf:
  data=C.create_string_buffer(raw)
  x.XChangeProperty(d,req,prop,utf,8,0,data,len(raw))
 else:prop=0
 note=C.create_string_buffer(192)
 C.c_int.from_buffer(note).value=31
 C.c_void_p.from_buffer(note,24).value=d
 for offset,val in [(32,req),(40,clip),(48,target),(56,prop)]:
  C.c_ulong.from_buffer(note,offset).value=val
 x.XSendEvent(d,req,0,0,note);x.XFlush(d)
 (base/'served').touch()
 time.sleep(5)
 break
'''

PASTE_CHILD = r'''
import hashlib, os, sys, time, tty
from pathlib import Path
base=Path(sys.argv[1]);expected=b'\x1b[200~'+(base/'payload').read_bytes()+b'\x1b[201~'
tty.setraw(0)
sys.stdout.write('\x1b[?2004h');sys.stdout.flush()
(base/'child_ready').touch()
received=bytearray()
while len(received)<len(expected):
 part=os.read(0,65536)
 if not part:break
 received.extend(part)
(base/'received').write_text(str(len(received))+' '+hashlib.sha256(received).hexdigest())
time.sleep(1)
'''

RESIZE_CHILD = r'''
import sys, time
from pathlib import Path
base=Path(sys.argv[1]);sys.stdout.write('\033[?25l')
for i in range(2800):
 sys.stdout.write(f'STALE SCREEN LINE {i:05d} abcdefghijklmnopqrstuvwxyz\r\n')
sys.stdout.flush();(base/'resize_ready').touch()
while not (base/'again').exists():time.sleep(.02)
for i in range(2800,5600):
 sys.stdout.write(f'STALE AGAIN {i:05d} abcdefghijklmnopqrstuvwxyz\r\n')
sys.stdout.write('\033[?1049hALT SCREEN ACTIVE');sys.stdout.flush()
(base/'alt_ready').touch()
while not (base/'return').exists():time.sleep(.02)
sys.stdout.write('\033[?1049l');sys.stdout.flush()
(base/'main_ready').touch();time.sleep(4)
'''


def make_fixture(directory, name, text):
    p = directory / name
    p.write_text(text)
    return str(p)


def start_test(binary_args):
    return subprocess.Popen([BIN, '-e', sys.executable, '-u', *binary_args],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def stop(*procs):
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()


def test_paste(d, directory):
    # >64 KiB XGetWindowProperty transfer and much greater than PTY input queue.
    payload = b'PASTE-BEGIN|' + b'0123456789abcdef' * 13000 + b'|PASTE-END'
    (directory / 'payload').write_bytes(payload)
    child = make_fixture(directory, 'paste_child.py', PASTE_CHILD)
    owner = make_fixture(directory, 'owner.py', OWNER)
    term = start_test([child, str(directory)])
    clipboard = subprocess.Popen([sys.executable, '-u', owner, str(directory)],
                                 stderr=subprocess.PIPE)
    try:
        win = wait(find_window)
        wait(lambda: (directory / 'child_ready').exists())
        wait(lambda: (directory / 'owner_ready').exists())
        time.sleep(.1)  # child must enable bracketed paste before input
        send_key(d, win, ord('v'), 5)   # Ctrl+Shift+V
        wait(lambda: (directory / 'served').exists())
        wait(lambda: (directory / 'received').exists(), 18)
        count, digest = (directory / 'received').read_text().split()
        expected=b'\x1b[200~'+payload+b'\x1b[201~'
        assert int(count)==len(expected), (count,len(expected))
        assert digest == hashlib.sha256(expected).hexdigest(), 'pasted bytes differ'
    finally:
        stop(clipboard, term)


def test_resize(d, directory):
    fixture = make_fixture(directory, 'resize_child.py', RESIZE_CHILD)
    term = start_test([fixture, str(directory)])
    try:
        win = wait(find_window)
        wait(lambda: (directory / 'resize_ready').exists(), 12)
        w, h = size(win)
        cw = (w-6)//80
        ch = (h-6)//24
        assert cw > 0 and ch > 0
        # The font's ASCII advance must match the terminal cell width.
        xft = C.CDLL(C.util.find_library('Xft'))
        x.XDefaultScreen.argtypes=[C.c_void_p]
        x.XDefaultScreen.restype=C.c_int
        xft.XftFontOpenName.argtypes=[C.c_void_p,C.c_int,C.c_char_p]
        xft.XftFontOpenName.restype=C.c_void_p
        xft.XftTextExtents32.argtypes=[C.c_void_p,C.c_void_p,C.c_void_p,C.c_int,C.c_void_p]
        xft.XftFontClose.argtypes=[C.c_void_p,C.c_void_p]
        font=xft.XftFontOpenName(d,x.XDefaultScreen(d),b'monospace:pixelsize=15:antialias=true')
        assert font
        metrics=C.create_string_buffer(12)
        probe=C.c_uint(ord('M'))
        xft.XftTextExtents32(d,font,C.byref(probe),1,metrics)
        advance=C.c_short.from_buffer(metrics,8).value
        xft.XftFontClose(d,font)
        assert cw==advance, (cw, advance)

        x.XResizeWindow.argtypes=[C.c_void_p,C.c_ulong,C.c_uint,C.c_uint]
        x.XResizeWindow(d,win,w,40*ch+6)
        x.XFlush(d)
        wait(lambda:size(win)[1]==40*ch+6)
        time.sleep(.4)
        new_h=size(win)[1]
        pixels = grab(d,win,w,new_h)
        bg=sample(pixels,1,1)
        for row in range(25,39):
            for y in range(3+row*ch+1,min(3+(row+1)*ch-1,new_h-3),3):
                for xp in range(4,min(w-4,400),4):
                    assert sample(pixels,xp,y)==bg, ('stale scrollback after resize',row,xp,y)
        # Margins are restored after rendering, including the right/bottom slack.
        for xx,yy in [(0,0),(1,1),(w-2,1),(1,new_h-2),(w-2,new_h-2),
                      (1,40*ch//2),(w-2,40*ch//2)]:
            assert sample(pixels,xx,yy)==bg, ('border damaged',xx,yy)

        # Regenerate wrapped history at the smaller size, then grow while
        # an alternate screen is active. Returning must not expose stale main
        # buffer cells that became visible during the editor's resize.
        x.XResizeWindow(d,win,w,h);x.XFlush(d)
        wait(lambda:size(win)[1]==h)
        (directory/'again').touch()
        wait(lambda:(directory/'alt_ready').exists(),12)
        time.sleep(.2)
        x.XResizeWindow(d,win,w,40*ch+6);x.XFlush(d)
        wait(lambda:size(win)[1]==40*ch+6)
        time.sleep(.25)
        (directory/'return').touch()
        wait(lambda:(directory/'main_ready').exists())
        time.sleep(.25)
        pixels=grab(d,win,w,40*ch+6)
        for row in range(25,39):
            for y in range(3+row*ch+1,3+(row+1)*ch-1,3):
                for xp in range(4,min(w-4,400),4):
                    assert sample(pixels,xp,y)==bg, ('inactive screen leaked old output',row,xp,y)
    finally:
        stop(term)


def main():
    d = x.XOpenDisplay(None)
    assert d, 'Xvfb display required'
    try:
        with tempfile.TemporaryDirectory() as a:
            test_paste(d,Path(a))
        with tempfile.TemporaryDirectory() as b:
            test_resize(d,Path(b))
        print('PASS: 208 KiB bracketed paste, wrapped main/alternate resize, border, ASCII cell width')
    finally:
        x.XCloseDisplay(d)


if __name__=='__main__':main()

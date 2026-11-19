#!/usr/bin/env python3
"""Pixel-compare normal screen before/after Vim-style ?1049 switches.

Run: xvfb-run -a python3 tests/regress_altscreen_restore.py ./fastst
Requires libX11, xwininfo and Xvfb (xorg-server-xvfb).
"""
import ctypes
import ctypes.util
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BIN = str(Path(sys.argv[1] if len(sys.argv) > 1 else './fastst').resolve())

CHILD = '''import os, sys, time
from pathlib import Path
p = Path(sys.argv[1]);
def ack(n):
    (p / ('ready'+str(n))).touch()
    while not (p / ('go'+str(n))).exists(): time.sleep(0.02)
def emit(s):
    sys.stdout.write(s); sys.stdout.flush()
# fixed geometry and cursor, consistent frame capture
emit('\\x1b[?25l\\x1b[2J\\x1b[H')
emit('PRE VIM - ORIGINAL MAIN SCREEN\\r\\n')
emit('\\x1b[32moriginal green text\\x1b[0m\\r\\n')
emit('\\x1b[35moriginal purple text\\x1b[0m\\r\\n')
emit('Main text survives switching.\\r\\n')
ack(0)
# Deliberately LEAVE various editor modes changed on exit to check state isolation.
emit('\\x1b[?1049h\\x1b[31;44m\\x1b[2J\\x1b[H')
emit('ALT SCREEN WITH COLORS\\r\\n')
emit('\\x1b(0lqqqqqqqqqqk\\x1b(B\\r\\n')
emit('\\x1b[?1h\\x1b[?25h\\x1b[?2004h')
ack(1)
emit('\\x1b[?1049l')
ack(2)
time.sleep(0.1)
'''


def until(check, timeout=6):
    limit = time.monotonic() + timeout
    while time.monotonic() < limit:
        v = check()
        if v:
            return v
        time.sleep(0.035)
    raise TimeoutError('timed out waiting for child/display')


def window_id():
    r = subprocess.run(['xwininfo', '-root', '-tree'], text=True, capture_output=True)
    for line in r.stdout.splitlines():
        if 'fastst' in line:
            m = re.search(r'0x[0-9a-fA-F]+', line)
            if m:
                return m.group(0)
    return None


class XImage(ctypes.Structure):
    _fields_ = [('width', ctypes.c_int), ('height', ctypes.c_int),
                ('xoffset', ctypes.c_int), ('format', ctypes.c_int),
                ('data', ctypes.c_void_p), ('byte_order', ctypes.c_int),
                ('bitmap_unit', ctypes.c_int), ('bitmap_bit_order', ctypes.c_int),
                ('bitmap_pad', ctypes.c_int), ('depth', ctypes.c_int),
                ('bytes_per_line', ctypes.c_int), ('bits_per_pixel', ctypes.c_int)]


def grab(window):
    """Read rendered X11 pixels via XGetImage; avoid OCR and external tools."""
    x = ctypes.CDLL(ctypes.util.find_library('X11'))
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                            ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
    x.XGetImage.restype = ctypes.POINTER(XImage)
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    attrs = subprocess.check_output(['xwininfo', '-id', window], text=True)
    w = int(re.search(r'Width:\s+(\d+)', attrs)[1])
    h = int(re.search(r'Height:\s+(\d+)', attrs)[1])
    display = x.XOpenDisplay(None)
    image = x.XGetImage(display, int(window, 16), 0, 0, w, h,
                        ctypes.c_ulong(-1).value, 2)
    if not image:
        raise RuntimeError('XGetImage returned NULL')
    pixels = ctypes.string_at(image.contents.data, image.contents.bytes_per_line * h)
    # XDestroyImage is a macro, but XFree will release the allocated image data.
    x.XFree.argtypes = [ctypes.c_void_p]
    x.XFree(image.contents.data)
    x.XFree(image)
    x.XCloseDisplay(display)
    return pixels


def main():
    with tempfile.TemporaryDirectory() as t:
        fixture = Path(t, 'fixture.py')
        fixture.write_text(CHILD)
        proc = subprocess.Popen([BIN, '-e', sys.executable, '-u', str(fixture), t], stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE)
        try:
            w = until(window_id)
            stages = []
            for n in range(3):
                until(lambda: Path(t, 'ready'+str(n)).exists())
                time.sleep(.2)  # allow the render loop to flush after PTY read
                stages.append(grab(w))
                Path(t, 'go'+str(n)).touch()
            assert stages[0] != stages[1], 'alternate screen did not display'
            assert stages[0] == stages[2], 'normal screen pixels changed after alternate screen exit'
            print('PASS: alternate screen is displayed, then normal screen pixels are fully restored')
        finally:
            proc.terminate()
            try: proc.wait(timeout=3)
            except subprocess.TimeoutExpired: proc.kill()

if __name__ == '__main__':
    main()

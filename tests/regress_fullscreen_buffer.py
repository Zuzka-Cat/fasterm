#!/usr/bin/env python3
"""Regression: a fast fullscreen repaint must retain bright ink to the bottom.

Run: xvfb-run -a python3 tests/regress_fullscreen_buffer.py ./fasterm
This checks final rendered pixels under Xvfb, not hardware scanout/vblank.
"""
import ctypes as C
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from regress_scrollback_input import find_window, grab, size, wait, x

BINARY = str(Path(sys.argv[1]).resolve())
x.XResizeWindow.argtypes = [C.c_void_p, C.c_ulong, C.c_uint, C.c_uint]
x.XResizeWindow.restype = C.c_int

FIXTURE = r'''import fcntl, os, struct, sys, time
from pathlib import Path
folder = Path(sys.argv[1])
while not (folder/'go').exists(): time.sleep(.01)
rows, cols, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, 0x5413, b'\0'*8))
cols = max(2, min(cols, 256))
rows = max(2, min(rows, 128))
# Force several complete fullscreen invalidations and large glyph batches.
for n in range(6):
    seq = ['\033[?25l\033[2J\033[H', '\033[37;40m']
    for row in range(rows):
        seq.append(('M' if n % 2 else 'W') * (cols-1))
        if row < rows-1: seq.append('\r\n')
    sys.stdout.write(''.join(seq))
    sys.stdout.flush()
# Settle on a uniform bright ASCII raster for top/middle/bottom comparison.
sys.stdout.write('\033[?25l\033[2J\033[H\033[97;40m')
for row in range(rows):
    sys.stdout.write('M' * (cols-1))
    if row < rows-1: sys.stdout.write('\r\n')
sys.stdout.flush()
(folder/'rows').write_text(str(rows))
while True: time.sleep(1)
'''


def main():
    with tempfile.TemporaryDirectory() as tmp:
        fixture = Path(tmp, 'fixture.py')
        fixture.write_text(FIXTURE)
        proc = subprocess.Popen([BINARY, '-e', sys.executable, '-u',
                                 str(fixture), tmp], stderr=subprocess.PIPE)
        d = x.XOpenDisplay(None)
        try:
            win = wait(find_window)
            old_w, old_h = size(win)
            cw = (old_w - 6) // 80
            ch = (old_h - 6) // 24
            assert cw > 0 and ch > 0
            # Xvfb is larger than a default terminal, exercising fullscreen-like
            # drawing with substantially more than 24 dirty rows.
            assert x.XResizeWindow(d, win, 1200, 850)
            x.XFlush(d)
            wait(lambda: size(win) == (1200, 850))
            time.sleep(.12)
            Path(tmp, 'go').touch()
            rows = int(wait(lambda: Path(tmp, 'rows').read_text()
                            if Path(tmp, 'rows').exists() else None, 10))
            assert rows > 24, f'fullscreen size yielded only {rows} rows'
            # Allow the terminal to drain the PTY and draw the final frame.
            time.sleep(.35)
            frame = grab(d, win, 1200, 850)
            pixels, stride = frame
            # The same bright glyphs should occupy every one of these rows.
            # A wrongly clipped or partly repainted bottom must not pass.
            def raster(row):
                y = 3 + row * ch
                return b''.join(pixels[(y+dy)*stride+3*4:(y+dy)*stride+(3+min(cw*25,1100))*4]
                                for dy in range(ch))
            top = raster(0)
            middle = raster(rows//2)
            bottom = raster(rows-1)
            assert top == middle == bottom, 'ink intensity/coverage differs at bottom row'
            assert sum(1 for i in range(0, len(top), 4) if max(top[i:i+3]) > 160) > 100, \
                'bright glyphs not present in comparison rows'
            assert proc.poll() is None, f'terminal exited: {proc.returncode}'
            print('PASS: fast fullscreen updates preserve bright bottom-row glyph raster')
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try: proc.communicate(timeout=3)
            except subprocess.TimeoutExpired: proc.kill(); proc.communicate()


if __name__ == '__main__':
    main()

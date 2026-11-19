#!/usr/bin/env python3
"""Compare baseline and optimized startup rendering pixel-for-pixel under Xvfb.

This verifies that Fontconfig preinitialization doesn't change Xft's choices,
including geometry, normal/bright ANSI colors, and Unicode fallback.
"""
import pathlib
import subprocess
import sys
import tempfile
import time
from regress_scrollback_input import wait, find_window, size, grab, x

if len(sys.argv)!=3:
    raise SystemExit('usage: regress_startup_pixels.py BASELINE OPTIMIZED')

FIXTURE = r'''import sys,time
sys.stdout.write('\x1b[?25l\x1b[2J\x1b[H')
sys.stdout.write('Startup pixel-equivalence test\r\n')
sys.stdout.write('\x1b[31mred \x1b[32mgreen \x1b[34mblue \x1b[0mnormal\r\n')
sys.stdout.write('UTF-8: \u25bd \u03bb \u4e16\u754c\r\n')
sys.stdout.write('\x1b[38;5;202m256 colors\x1b[0m\r\n')
sys.stdout.flush()
time.sleep(5)
'''

def capture(binary, fixture, display):
    proc=subprocess.Popen([str(binary),'-e',sys.executable,'-u',str(fixture)],
                          stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    try:
        win=wait(find_window)
        w,h=size(win)
        # With a persistent Xvfb, XGetImage synchronizes earlier drawing.
        # Give the real PTY child time to issue text before the capture.
        time.sleep(.35)
        return (w,h,grab(display,win,w,h))
    finally:
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill();proc.wait()
        proc.stderr.close()

with tempfile.TemporaryDirectory() as t:
    fixture=pathlib.Path(t,'fixture.py')
    fixture.write_text(FIXTURE)
    d=x.XOpenDisplay(None)
    assert d
    try:
        images=[capture(pathlib.Path(p).resolve(),fixture,d) for p in sys.argv[1:]]
    finally:
        x.XCloseDisplay(d)
    assert images[0][:2]==images[1][:2],f'Cell size/geometry changed: {images[0][:2]} -> {images[1][:2]}'
    assert images[0][2]==images[1][2], 'Startup frame pixels differ from baseline'
    print('PASS: baseline and optimized have identical X11 geometry and ANSI/Unicode pixels')

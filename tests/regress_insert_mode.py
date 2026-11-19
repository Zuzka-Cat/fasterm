#!/usr/bin/env python3
"""Check that the 4-byte ASCII fast path honors CSI 4 h (insert mode)."""
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from regress_scrollback_input import find_window, grab, sample, size, wait, x

BIN = str(Path(sys.argv[1] if len(sys.argv)>1 else './fasterm').resolve())
CHILD = r'''
import sys, time
from pathlib import Path
p=Path(sys.argv[1])
# Four green cells followed by four inserted (default background) cells.
# Their original BCD must move to columns 5,6,7, not get overwritten.
sys.stdout.write('\033[?25l\033[2J\033[H\033[48;2;12;180;36mABCD\033[0m\033[1;2H\033[4hWXYZ\033[4l')
sys.stdout.flush();(p/'ready').touch();time.sleep(5)
'''

def main():
    with tempfile.TemporaryDirectory() as tmp:
        fixture=Path(tmp,'fixture.py');fixture.write_text(CHILD)
        term=subprocess.Popen([BIN,'-e',sys.executable,'-u',str(fixture),tmp],stderr=subprocess.PIPE)
        d=x.XOpenDisplay(None)
        try:
            win=wait(find_window)
            wait(lambda:Path(tmp,'ready').exists())
            w,h=size(win);cw=(w-6)//80
            time.sleep(.25)
            frame=grab(d,win,w,h)
            green=sample(frame,3+cw//3,4)
            empty=sample(frame,3+9*cw,4)
            assert green!=empty, 'initial green cell background did not render'
            for col in (5,6,7):
                assert sample(frame,3+col*cw+cw//3,4)==green, ('insert mode lost shifted cell',col)
            for col in (1,2,3,4):
                assert sample(frame,3+col*cw+cw//3,4)==empty, ('insert mode failed to open space',col)
            print('PASS: CSI 4h insertion shifts cells even for four printable ASCII bytes')
        finally:
            x.XCloseDisplay(d)
            term.terminate()
            try:term.wait(timeout=3)
            except subprocess.TimeoutExpired:term.kill()

if __name__=='__main__':main()

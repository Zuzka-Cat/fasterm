#!/usr/bin/env python3
"""Xvfb pixel regression: half-block image cells, box joins, bold/italic faces.
Run: xvfb-run -a python3 tests/regress_cell_geometry.py ./fasterm
"""
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from regress_scrollback_input import find_window, grab, sample, size, wait, x

BINARY = str(Path(sys.argv[1]).resolve())
FIXTURE = r'''import sys,time
from pathlib import Path
p=Path(sys.argv[1])
def emit(s):
 sys.stdout.write(s);sys.stdout.flush()
emit('\x1b[?25l\x1b[2J\x1b[H')
emit('\x1b[38;2;255;0;0m▀▄█▌▐\x1b[0m\r\n')
emit('\x1b[38;2;0;255;0m┌─┬─┐\r\n')
emit('│ │ │\r\n')
emit('└─┴─┘\x1b[0m\r\n')
emit('\x1b[38;2;225;195;160mM\x1b[1mM\x1b[22;3mM\x1b[1mM\x1b[0m\r\n')
emit('\x1b[38;2;0;255;0m╭─╮\r\n│ │\r\n╰─╯\x1b[0m\r\n')
emit('\x1b[38;2;255;0;0;48;2;0;0;255m▀\x1b[0m')
p.touch();time.sleep(12)
'''


def main():
    with tempfile.TemporaryDirectory() as tmp:
        fixture=Path(tmp,'fixture.py')
        fixture.write_text(FIXTURE)
        proc=subprocess.Popen([BINARY,'-e',sys.executable,'-u',str(fixture),str(Path(tmp,'ready'))],
                              stderr=subprocess.PIPE)
        d=x.XOpenDisplay(None)
        try:
            win=wait(find_window)
            wait(lambda:Path(tmp,'ready').exists())
            time.sleep(.2)
            w,h=size(win)
            cw=(w-6)//80;ch=(h-6)//24
            px=grab(d,win,w,h)
            def at(col,row,dx,dy):
                b,g,r=sample(px,3+col*cw+dx,3+row*ch+dy)
                return r,g,b
            red=(255,0,0)
            bg=(16,18,22)
            # U+2580/2584 exact half blocks and U+2588 exact full block.
            for dx in range(cw):
                for dy in range(ch):
                    assert at(0,0,dx,dy)==(red if dy<ch//2 else bg), ('upper half',dx,dy,at(0,0,dx,dy))
                    assert at(1,0,dx,dy)==(bg if dy<ch//2 else red), ('lower half',dx,dy,at(1,0,dx,dy))
                    assert at(2,0,dx,dy)==red, ('full block',dx,dy,at(2,0,dx,dy))
                    assert at(3,0,dx,dy)==(red if dx<cw//2 else bg), ('left half',dx,dy,at(3,0,dx,dy))
                    assert at(4,0,dx,dy)==(bg if dx<cw//2 else red), ('right half',dx,dy,at(4,0,dx,dy))
            # A continuous line must make it to the boundary on both sides,
            # including joins between the right edge of one cell and the left
            # edge of its neighbor.
            for col in range(5):
                assert at(col,1, cw//2,ch//2)==(0,255,0), ('box upper row',col)
                assert at(col,3, cw//2,ch//2)==(0,255,0), ('box lower row',col)
            for col in (0,2,4):
                for dy in range(ch):
                    assert at(col,2,cw//2,dy)==(0,255,0), ('vertical box',col,dy,at(col,2,cw//2,dy))
            for col in (1,3):
                assert at(col,1,0,ch//2)==(0,255,0), ('left join',col)
                assert at(col,1,cw-1,ch//2)==(0,255,0), ('right join',col)
            # Curved btop-style borders must connect to neighboring straight
            # lines, at the shared pixel where their cell boundaries meet.
            for row in (5,7):
                assert at(0,row,cw-1,ch//2)==(0,255,0), ('rounded right',row)
                assert at(1,row,0,ch//2)==(0,255,0), ('rounded adjacent left',row)
                assert at(1,row,cw-1,ch//2)==(0,255,0), ('rounded adjacent right',row)
                assert at(2,row,0,ch//2)==(0,255,0), ('rounded left',row)
            for col in (0,2):
                assert at(col,5,cw//2,ch-1)==(0,255,0), ('rounded bottom edge',col)
                assert at(col,6,cw//2,0)==(0,255,0), ('vertical top edge',col)
                assert at(col,6,cw//2,ch-1)==(0,255,0), ('vertical bottom edge',col)
                assert at(col,7,cw//2,0)==(0,255,0), ('rounded top edge',col)
            for dx in range(cw):
                for dy in range(ch):
                    assert at(0,8,dx,dy)==((255,0,0) if dy<ch//2 else (0,0,255)), ('two-color image cell',dx,dy,at(0,8,dx,dy))
            # Same glyph/color in four styles, compare actual rasterizations,
            # not just SGR attribute flags or color-index changes.
            def mask(col):
                return tuple(at(col,4,dx,dy)!=bg for dy in range(ch) for dx in range(cw))
            masks=[mask(i) for i in range(4)]
            assert masks[0]!=masks[1], 'bold font has the regular glyph shape'
            assert masks[0]!=masks[2], 'italic font has the regular glyph shape'
            assert masks[2]!=masks[3], 'bold-italic glyph is not distinct from italic'
            assert proc.poll() is None, f'terminal exited: {proc.returncode}'
            print('PASS: gapless image half blocks, joined box borders, bold/italic/bold-italic glyphs')
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try:proc.communicate(timeout=3)
            except subprocess.TimeoutExpired:proc.kill();proc.communicate()

if __name__=='__main__':main()

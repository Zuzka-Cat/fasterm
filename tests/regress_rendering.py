#!/usr/bin/env python3
"""Pixel regression for exact RGB backgrounds and terminal Unicode glyphs.

Run with: xvfb-run -a python3 tests/regress_rendering.py ./fasterm
"""
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from regress_scrollback_input import find_window, grab, sample, size, wait, x

BINARY = str(Path(sys.argv[1]).resolve())
FIXTURE = r'''import sys, time
from pathlib import Path
ready = Path(sys.argv[1])
def emit(text):
    sys.stdout.write(text)
    sys.stdout.flush()
emit('\x1b[?25l\x1b[2J\x1b[H')
emit('\x1b[48;2;17;34;51m    ')
emit('\x1b[48;2;28;39;53m    ')
emit('\x1b[0m\r\n')
emit('\x1b[38;2;150;60;10;48;2;30;70;110;7m    ')
emit('\x1b[0m\r\n')
emit('\x1b[38;2;226;196;166m⣿⠿⣷  ┌─┬─┐  ░▒▓\x1b[0m\r\n')
emit('\x1b[48:2::5:47:129m    \x1b[0m')
ready.touch()
time.sleep(10)
'''


def rgb(frame, cx, cy):
    # XImage 32-bit little-endian TrueColor stores B, G, R, then padding.
    b, g, r = sample(frame, cx, cy)
    return (r, g, b)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        fixture = Path(tmp, 'fixture.py')
        fixture.write_text(FIXTURE)
        proc = subprocess.Popen([BINARY, '-e', sys.executable, '-u', str(fixture),
                                 str(Path(tmp, 'ready'))], stderr=subprocess.PIPE)
        d = x.XOpenDisplay(None)
        try:
            win = wait(find_window)
            wait(lambda: Path(tmp, 'ready').exists())
            time.sleep(.25)
            w, h = size(win)
            cw, ch = (w - 6)//80, (h - 6)//24
            pixels = grab(d, win, w, h)
            def at(col, row, dx=0, dy=0):
                return rgb(pixels, 3 + col*cw + cw//2 + dx,
                           3 + row*ch + ch//2 + dy)
            assert at(1, 0) == (17, 34, 51), f'RGB background #112233: {at(1, 0)}'
            assert at(5, 0) == (28, 39, 53), f'RGB background #1c2735: {at(5, 0)}'
            assert at(1, 1) == (150, 60, 10), f'inverted RGB background: {at(1, 1)}'
            assert at(1, 3) == (5, 47, 129), f'colon RGB background: {at(1, 3)}'
            # Exact ink pixels are not guaranteed for antialiased thin lines.
            # Check substantial colored coverage for braille, borders, blocks.
            def ink_mask(col):
                return tuple((rgb(pixels, 3 + col*cw + dx, 3 + 2*ch + dy)[0] > 160
                              and rgb(pixels, 3 + col*cw + dx, 3 + 2*ch + dy)[1] > 135)
                             for dy in range(ch) for dx in range(cw))
            for col in (0, 1, 2, 5, 6, 7, 8, 9, 12, 13, 14):
                assert any(ink_mask(col)), f'no colored Unicode glyph ink in column {col}'
            assert ink_mask(0) != ink_mask(1), 'distinct braille glyphs rendered alike (tofu)'
            assert ink_mask(12) != ink_mask(14), 'light/dark block shades rendered alike'
            assert proc.poll() is None, f'terminal exited: {proc.returncode}'
            print('PASS: exact RGB (; and :) backgrounds, inverse colors, braille, box drawing, blocks')
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try:
                proc.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()


if __name__ == '__main__':
    main()

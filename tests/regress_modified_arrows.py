#!/usr/bin/env python3
"""Check xterm modifier sequences for cursor keys in normal and DECCKM mode.

Run: xvfb-run -a python3 tests/regress_modified_arrows.py ./fasterm
Requires Xvfb and xwininfo; sends X11 KeyPress events to the real terminal.
"""
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from regress_scrollback_input import find_window, send_key, wait, x

BIN = str(Path(sys.argv[1] if len(sys.argv) > 1 else './fasterm').resolve())
CHILD = r'''
import os, select, sys, time, tty
from pathlib import Path
p = Path(sys.argv[1])
tty.setraw(0)
for mode in range(2):
    os.write(1, b'\x1b[?1h' if mode else b'\x1b[?1l')
    (p / f'mode{mode}').touch()
    for i in range(8):
        (p / f'ready{mode}_{i}').touch()
        data = bytearray()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            ready, _, _ = select.select([0], [], [], .15 if data else deadline - time.monotonic())
            if not ready:
                break
            data.extend(os.read(0, 64))
        (p / f'recv{mode}_{i}').write_bytes(data)
'''

# X11 modifier flags: ShiftMask = 1, ControlMask = 4, Mod1Mask = 8.
CASES = (
    (0xff51, 0, b'\x1b[D', 'Left'),
    (0xff53, 0, b'\x1b[C', 'Right'),
    (0xff51, 4, b'\x1b[1;5D', 'Ctrl+Left'),
    (0xff53, 4, b'\x1b[1;5C', 'Ctrl+Right'),
    (0xff51, 5, b'\x1b[1;6D', 'Ctrl+Shift+Left'),
    (0xff53, 12, b'\x1b[1;7C', 'Ctrl+Alt+Right'),
    (0xff51, 8, b'\x1b[1;3D', 'Alt+Left'),
    (0xff53, 1, b'\x1b[1;2C', 'Shift+Right'),
)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        fixture = Path(tmp, 'fixture.py')
        fixture.write_text(CHILD)
        proc = subprocess.Popen(
            [BIN, '-e', sys.executable, '-u', str(fixture), tmp],
            stderr=subprocess.PIPE,
        )
        d = x.XOpenDisplay(None)
        assert d, 'cannot open the test display'
        try:
            win = wait(find_window)
            for mode in range(2):
                wait(lambda: (Path(tmp) / f'mode{mode}').exists())
                time.sleep(.15)  # let terminal parse the application-cursor toggle
                for i, (sym, state, expected, label) in enumerate(CASES):
                    wait(lambda: (Path(tmp) / f'ready{mode}_{i}').exists())
                    send_key(d, win, sym, state)
                    received = Path(tmp) / f'recv{mode}_{i}'
                    wait(received.exists)
                    result = received.read_bytes()
                    if mode and not state:
                        expected = b'\x1bO' + expected[-1:]
                    assert result == expected, (
                        f'{label} in mode {mode}: got {result!r}, expected {expected!r}'
                    )
            print('PASS: Ctrl+Left/Right word-jump sequences and other modified arrows, normal/DECCKM')
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == '__main__':
    main()

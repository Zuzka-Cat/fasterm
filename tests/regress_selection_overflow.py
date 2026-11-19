#!/usr/bin/env python3
"""X11 regression for historical clipboard overflow with very long selections.

Needs an *unstripped* executable so nm can locate the clipboard buffer in .bss.
Run: xvfb-run -a python3 tests/regress_selection_overflow.py ./fastst-compat-debug
"""
import re
import os
import ctypes as C
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Reuse genuine X11 event injection helpers from the existing interaction test.
from regress_scrollback_input import x, find_window, wait, size, send_key, send_mouse

BINARY = str(Path(sys.argv[1]).resolve())
CLIP_CAPACITY = 131584
FIXTURE = '''import os,sys,tty,time
from pathlib import Path
tty.setraw(0)
for n in range(2150):
 os.write(1, (f'{n:04d}: ' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'*2 + '\\r\\n').encode())
Path(sys.argv[1], 'ready').touch()
time.sleep(15)
'''

def symbol_addr(name):
    p = subprocess.check_output(['nm', BINARY], text=True)
    m = re.search(r'^([0-9a-fA-F]+) [bBdD] '+re.escape(name)+r'$', p, re.M)
    if not m:
        raise RuntimeError(f'{name} not found: use unstripped fastst-compat-debug executable')
    return int(m[1], 16)

def read_mem(pid, addr, length):
    with open(f'/proc/{pid}/mem', 'rb', buffering=0) as mem:
        return os.pread(mem.fileno(),length,addr)

def main():
    clip = symbol_addr('clip_buffer')
    count = symbol_addr('clip_len')
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp,'fixture.py').write_text(FIXTURE)
        proc=subprocess.Popen([BINARY,'-e',sys.executable,'-u',str(Path(tmp,'fixture.py')),tmp],stderr=subprocess.PIPE)
        d = x.XOpenDisplay(None)
        if not d:
            raise RuntimeError('XOpenDisplay failed')
        try:
            win=wait(find_window)
            wait(lambda: Path(tmp,'ready').exists(),10)
            time.sleep(.3)
            w,h = size(win)
            cw=(w-6)//80; ch=(h-6)//24
            # Clipboard overflow lands beyond 131584 into BSS padding.
            before=read_mem(proc.pid,clip+CLIP_CAPACITY,64)
            assert before==bytes(64),f'unexpected nonzero padding BEFORE selection: {before.hex()}'
            send_key(d,win,0xff50,1) # Shift+Home => earliest scrollback
            time.sleep(.2)
            send_mouse(d,win,4,1,3+cw,3+ch,0)
            send_key(d,win,0xff57,1) # Shift+End => live screen
            time.sleep(.2)
            send_mouse(d,win,5,1,3+76*cw,3+23*ch,0)
            time.sleep(.4)
            assert proc.poll() is None, f'terminal crashed: {proc.returncode}'
            n=int.from_bytes(read_mem(proc.pid,count,4),'little')
            after=read_mem(proc.pid,clip+CLIP_CAPACITY,64)
            assert before==after,f'clipboard overflow: {after.hex()}'
            assert 120000 <= n <= CLIP_CAPACITY,f'unexpected long selection length: {n}'
            print(f'PASS: clipped {n:,}-byte selection within {CLIP_CAPACITY:,}-byte buffer; guard intact')
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:proc.kill()

if __name__=='__main__':main()

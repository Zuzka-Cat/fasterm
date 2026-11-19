#!/usr/bin/env python3
"""Real Vim alternate-screen restoration test under Xvfb.

Run: xvfb-run -a python3 tests/regress_vim_exit.py ./fasterm
"""
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from regress_scrollback_input import wait, find_window, size, grab, send_key, x

BIN = str(Path(sys.argv[1] if len(sys.argv)>1 else './fasterm').resolve())
CHILD = r'''import os,subprocess,sys,time
from pathlib import Path
p=Path(sys.argv[1])
sys.stdout.write('\033[2J\033[HPRE-VIM MAIN SCREEN\r\n\033[32mgreen main line\033[0m\r\nsecond plain line')
sys.stdout.flush()
(p/'ready').touch()
while not (p/'go').exists():time.sleep(.02)
subprocess.run(['vim','-Nu','NONE','-N','-n','-i','NONE','-c','set notitle',str(p/'test.txt')],check=False)
(p/'vim_exited').touch()
while not (p/'go_final').exists():time.sleep(.02)
'''

def main():
    with tempfile.TemporaryDirectory() as tmp:
        fixture=Path(tmp,'fixture.py');fixture.write_text(CHILD)
        Path(tmp,'test.txt').write_text('hello, Vim!\nsecond buffer line\n')
        proc=subprocess.Popen([BIN,'-e',sys.executable,'-u',str(fixture),tmp],
                              stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        d=x.XOpenDisplay(None)
        try:
            win=wait(find_window)
            wait(lambda:Path(tmp,'ready').exists())
            w,h=size(win)
            time.sleep(.2)
            before=grab(d,win,w,h)
            Path(tmp,'go').touch()
            time.sleep(.6)
            in_vim=grab(d,win,w,h)
            assert before!=in_vim, 'vim did not use alternate screen'
            # Escape, then ZQ = quit immediately, without a colon command.
            send_key(d,win,0xff1b)
            for ch in 'ZQ':
                time.sleep(.06)
                send_key(d,win,ord(ch),1)
            wait(lambda:Path(tmp,'vim_exited').exists(),5)
            time.sleep(.2)
            after=grab(d,win,w,h)
            if before != after:
                from PIL import Image, ImageChops
                stride=before[1]
                orig=Image.frombytes('RGB',(w,h),before[0],'raw','BGRX',stride,1)
                fin=Image.frombytes('RGB',(w,h),after[0],'raw','BGRX',stride,1)
                delta=ImageChops.difference(orig,fin)
                print('Vim exit pixel diff bbox:',delta.getbbox())
                orig.save('/tmp/fst_vim_before.png')
                fin.save('/tmp/fst_vim_after.png')
                delta.save('/tmp/fst_vim_diff.png')
            assert before==after, 'normal screen not restored after actual Vim exit' 
            print('PASS: real Vim launches, quits with ZQ, restores all original screen pixels')
            Path(tmp,'go_final').touch()
        finally:
            x.XCloseDisplay(d)
            proc.terminate()
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:proc.kill()

if __name__=='__main__':main()

#!/usr/bin/env python3
"""Hotkey mode functional smoke test on Xvfb with XTest input injection.
Uses the current server's default shell and verifies genuinely mapped windows.
Requires libXtst.so.6 and Xvfb; no XTest development headers required.
"""
import ctypes as ct
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

if len(sys.argv)!=3:raise SystemExit('usage: regress_hotkey.py TERMINAL HOTKEY')
server=str(pathlib.Path(sys.argv[1]).resolve())
hotkey=str(pathlib.Path(sys.argv[2]).resolve())
if not os.environ.get('DISPLAY'):raise SystemExit('run under xvfb-run')
x=ct.CDLL('libX11.so.6');t=ct.CDLL('libXtst.so.6')
x.XOpenDisplay.argtypes=[ct.c_char_p];x.XOpenDisplay.restype=ct.c_void_p
x.XKeysymToKeycode.argtypes=[ct.c_void_p,ct.c_ulong];x.XKeysymToKeycode.restype=ct.c_uint
x.XStringToKeysym.argtypes=[ct.c_char_p];x.XStringToKeysym.restype=ct.c_ulong
x.XSync.argtypes=[ct.c_void_p,ct.c_int]
t.XTestFakeKeyEvent.argtypes=[ct.c_void_p,ct.c_uint,ct.c_int,ct.c_ulong]

def mapped():
    tree=subprocess.run(['xwininfo','-root','-tree'],text=True,capture_output=True,timeout=3).stdout
    ids=re.findall(r'(0x[0-9a-fA-F]+) "fasterm - FASM X11 terminal"',tree)
    return sum('Map State: IsViewable' in subprocess.run(['xwininfo','-id',ident],text=True,capture_output=True,timeout=3).stdout for ident in ids)

with tempfile.TemporaryDirectory() as tmp:
    path=pathlib.Path(tmp,'output')
    script=pathlib.Path(tmp,'test-shell')
    script.write_text(f'#!/bin/sh\nprintf "HI\\n" >> "{path}"\nsleep 1.5\n')
    script.chmod(0o755)
    env=os.environ.copy();env['FASTERM_SHELL']=str(script)
    srv=subprocess.Popen([server,'--server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    hk=None;dpy=None
    try:
        time.sleep(.5)
        if srv.poll() is not None:raise RuntimeError('server failed')
        # The two idle workers may have X windows, but none may be mapped.
        assert mapped()==0, 'idle workers incorrectly mapped windows before a request'
        hk=subprocess.Popen([hotkey],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        time.sleep(.3)
        if hk.poll() is not None:raise RuntimeError('hotkey exited: '+hk.stderr.read().decode())
        dpy=x.XOpenDisplay(None)
        keys=[x.XKeysymToKeycode(dpy,x.XStringToKeysym(s)) for s in (b'Control_L',b'Alt_L',b'Return')]
        assert all(keys)
        for count in range(1,4):
            for code in keys:t.XTestFakeKeyEvent(dpy,code,1,0)
            for code in reversed(keys):t.XTestFakeKeyEvent(dpy,code,0,0)
            x.XSync(dpy,False)
            end=time.monotonic()+1.2
            while time.monotonic()<end:
                if path.exists() and path.read_text().count('HI\n')>=count and mapped()>=count:break
                time.sleep(.03)
            assert path.exists() and path.read_text().count('HI\n')>=count,f'launch {count} missing script output'
            assert mapped()>=count, f'launch {count} missing a mapped X11 terminal'
            time.sleep(.14) # key repeat suppression is 125ms
        print('PASS: Ctrl+Alt+Return launches 3 real shells with 3 mapped X11 windows; idle windows remain unmapped')
    finally:
        if dpy:
            x.XCloseDisplay.argtypes=[ct.c_void_p];x.XCloseDisplay(dpy)
        if hk:
            hk.terminate()
            try:hk.wait(timeout=3)
            except subprocess.TimeoutExpired:hk.kill();hk.wait()
            hk.stderr.close()
        srv.terminate()
        try:srv.wait(timeout=3)
        except subprocess.TimeoutExpired:srv.kill();srv.wait()
        srv.stderr.close()

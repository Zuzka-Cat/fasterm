#!/usr/bin/env python3
"""Warm Xvfb synthetic-keypress -> XSync first frame/text.

No per-launch process.  Hotkey listener, server, X server, and key injector are
already running.  A XTest synthetic Return event is used as the timestamped
trigger while Ctrl+Alt are held.  Includes event delivery and hotkey IPC.
This does NOT include physical keyboard, WM, monitor compositor/presentation,
or one-time pool startup costs.
"""
import argparse
import ctypes as ct
import os
import pathlib
import select
import statistics
import subprocess
import tempfile
import time

p=argparse.ArgumentParser()
p.add_argument('--runs',type=int,default=40)
p.add_argument('--warmup',type=int,default=5)
p.add_argument('--mode',choices=('frame','text'),default='frame')
p.add_argument('--server',default='./fasterm')
p.add_argument('--hotkey',default='./fasterm-hotkey')
p.add_argument('--probe',default='tests/startup_probe.so')
p.add_argument('--csv',default='')
a=p.parse_args()
server,hotkey,probe=[str(pathlib.Path(x).resolve()) for x in [a.server,a.hotkey,a.probe]]
if 'DISPLAY' not in os.environ:p.error('Must run within an X11 session')
x11=ct.CDLL('libX11.so.6')
xtst=ct.CDLL('libXtst.so.6')
x11.XOpenDisplay.argtypes=[ct.c_char_p];x11.XOpenDisplay.restype=ct.c_void_p
x11.XStringToKeysym.argtypes=[ct.c_char_p];x11.XStringToKeysym.restype=ct.c_ulong
x11.XKeysymToKeycode.argtypes=[ct.c_void_p,ct.c_ulong];x11.XKeysymToKeycode.restype=ct.c_uint
x11.XFlush.argtypes=[ct.c_void_p];x11.XFlush.restype=ct.c_int
x11.XSync.argtypes=[ct.c_void_p,ct.c_int];x11.XSync.restype=ct.c_int
xtst.XTestFakeKeyEvent.argtypes=[ct.c_void_p,ct.c_uint,ct.c_int,ct.c_ulong];xtst.XTestFakeKeyEvent.restype=ct.c_int
rd,wr=os.pipe()
with tempfile.TemporaryDirectory() as tmp:
    script=pathlib.Path(tmp,'startup-shell')
    script.write_text('#!/bin/sh\nprintf "FASTERM_READY\\n"\nsleep 0.17\n');script.chmod(0o755)
    env=os.environ.copy();env['SHELL']=str(script);env['PWD']=tmp
    server_env=env.copy()
    server_env.update(LD_PRELOAD=probe,FASTERM_BENCH_FD=str(wr),FASTERM_BENCH_TARGET=a.mode)
    sv=subprocess.Popen([server,'--server'],env=server_env,cwd=tmp,pass_fds=(wr,),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    os.close(wr)
    hk=None
    dpy=None
    try:
        time.sleep(.45)
        if sv.poll() is not None:raise RuntimeError('server exit: '+sv.stderr.read().decode())
        hk=subprocess.Popen([hotkey],cwd=tmp,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        time.sleep(.25)
        if hk.poll() is not None:raise RuntimeError('hotkey exit: '+hk.stderr.read().decode())
        dpy=x11.XOpenDisplay(None)
        if not dpy:raise RuntimeError('Cannot open X11 for injector')
        kctrl=x11.XKeysymToKeycode(dpy,x11.XStringToKeysym(b'Control_L'))
        kalt=x11.XKeysymToKeycode(dpy,x11.XStringToKeysym(b'Alt_L'))
        kret=x11.XKeysymToKeycode(dpy,x11.XStringToKeysym(b'Return'))
        if not kctrl or not kalt or not kret:raise RuntimeError('Missing keycode')
        samples=[]
        for i in range(a.warmup+a.runs):
            # Set modifier state ahead of the timestamp; time starts at Return.
            xtst.XTestFakeKeyEvent(dpy,kctrl,1,0)
            xtst.XTestFakeKeyEvent(dpy,kalt,1,0)
            x11.XSync(dpy,False)
            t0=time.monotonic_ns()
            xtst.XTestFakeKeyEvent(dpy,kret,1,0)
            x11.XFlush(dpy)
            if not select.select([rd],[],[],5)[0]:raise TimeoutError('No first frame from grabbed hotkey')
            data=os.read(rd,16384).decode()
            out=None
            for line in data.splitlines():
                v=line.split()
                if len(v)==3 and v[0]=='first_'+a.mode:out=int(v[2]);break
            if out is None or out<t0:raise RuntimeError(f'Invalid timestamp: {t0} {out} {data}')
            xtst.XTestFakeKeyEvent(dpy,kret,0,0)
            xtst.XTestFakeKeyEvent(dpy,kalt,0,0)
            xtst.XTestFakeKeyEvent(dpy,kctrl,0,0)
            x11.XSync(dpy,False)
            if i>=a.warmup:samples.append((out-t0)/1e6)
            time.sleep(.19)
        x=sorted(samples)
        print(f'hotkey-to-server-first-{a.mode}: n={len(x)}, median={statistics.median(x):.3f}ms, '
              f'p10={x[int(.1*(len(x)-1))]:.3f}ms, p90={x[int(.9*(len(x)-1))]:.3f}ms, '
              f'min={x[0]:.3f}ms')
        if a.csv:
            with open(a.csv,'w') as f:
                f.write('run,key_event_to_XSync_ms\n')
                for i,val in enumerate(samples):f.write(f'{i},{val:.6f}\n')
    finally:
        if dpy:
            x11.XCloseDisplay.argtypes=[ct.c_void_p]
            x11.XCloseDisplay(dpy)
        os.close(rd)
        if hk:
            hk.terminate()
            try:hk.wait(timeout=3)
            except subprocess.TimeoutExpired:hk.kill();hk.wait()
            hk.stderr.close()
        sv.terminate()
        try:sv.wait(timeout=3)
        except subprocess.TimeoutExpired:sv.kill();sv.wait()
        sv.stderr.close()

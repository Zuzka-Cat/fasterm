#!/usr/bin/env python3
"""Paired warm-Xvfb latency: generic launcher vs default-shell trigger.

Both clients run exactly the same shell executable and receive equivalent
cwd/environment (except probe-only variables).  Report server-processed first
frame and first actual text glyph, separately.  One server, persistent DISPLAY.
One measurement is the interval from just before subprocess.Popen to the
XSync completion in the worker.  The initial server warm-up is EXCLUDED.
"""
import argparse
import os
import pathlib
import random
import select
import statistics
import subprocess
import tempfile
import time

p=argparse.ArgumentParser()
p.add_argument('--runs',type=int,default=35)
p.add_argument('--warmup',type=int,default=5)
p.add_argument('--mode',choices=('frame','text'),default='text')
p.add_argument('--seed',type=int,default=15)
p.add_argument('--csv',default='')
p.add_argument('--server',default='./fasterm')
p.add_argument('--launcher',default='./fasterm-launch')
p.add_argument('--trigger',default='./fasterm-hotkey')
p.add_argument('--probe',default='tests/startup_probe.so')
a=p.parse_args()
if 'DISPLAY' not in os.environ:p.error('Run under xvfb-run or an X11 server')
server,launcher,trigger,probe=(str(pathlib.Path(x).resolve()) for x in (a.server,a.launcher,a.trigger,a.probe))

with tempfile.TemporaryDirectory() as tmp:
    script=pathlib.Path(tmp,'startup-shell')
    script.write_text('#!/bin/sh\nprintf "FASTERM_READY\\n"\nsleep 0.17\n')
    script.chmod(0o755)
    rd,wr=os.pipe()
    env=os.environ.copy()
    env['FASTERM_SHELL']=str(script)
    env['PWD']=tmp
    env['PS1']=''
    # The tracer never affects the launcher (no LD_PRELOAD in either launch client).
    server_env=env.copy()
    server_env.update(LD_PRELOAD=probe,FASTERM_BENCH_FD=str(wr),FASTERM_BENCH_TARGET=a.mode)
    proc=subprocess.Popen([server,'--server'],cwd=tmp,env=server_env,pass_fds=(wr,),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    os.close(wr)
    # One complete report is written atomically (a few KiB) per worker. No
    # concurrent launches are issued by the benchmark; any missing frame fails.
    def fetch(start):
        if not select.select([rd],[],[],5)[0]:raise TimeoutError('No XSync report')
        data=os.read(rd,16384).decode()
        stamp=None
        for line in data.splitlines():
            part=line.split()
            if len(part)==3 and part[0]=='first_'+a.mode:
                stamp=int(part[2]);break
        if stamp is None or stamp < start:raise RuntimeError(f'Invalid report start={start} got={stamp} data={data}')
        return (stamp-start)/1e6
    try:
        time.sleep(.55)
        if proc.poll() is not None:raise RuntimeError('Server exit: '+proc.stderr.read().decode())
        rng=random.Random(a.seed)
        cases=[kind for _ in range(a.runs+a.warmup) for kind in rng.sample(('general','trigger'),2)]
        res={'general':[],'trigger':[]}
        for i,kind in enumerate(cases):
            start=time.monotonic_ns()
            client=subprocess.Popen([launcher if kind=='general' else trigger],cwd=tmp,env=server_env,
                                    stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            elapsed=fetch(start)
            status=client.wait(timeout=3)
            err=client.stderr.read().decode();client.stderr.close()
            if status:raise RuntimeError(f'{kind} failed: {err}')
            if i>=2*a.warmup:res[kind].append(elapsed)
            time.sleep(.18)  # let child exit and replacement worker warm up
        for kind,arr in res.items():
            a0=sorted(arr)
            print(f'{kind}: n={len(arr)}, median={statistics.median(arr):.3f}ms, '
                  f'p10={a0[int(.1*(len(arr)-1))]:.3f}ms, '
                  f'p90={a0[int(.9*(len(arr)-1))]:.3f}ms')
        base=statistics.median(res['general']); target=statistics.median(res['trigger'])
        print(f'trigger improvement: {(base-target):.3f}ms ({(1-target/base)*100:.1f}%)')
        if a.csv:
            with open(a.csv,'w') as f:
                f.write('variant,run,launch_to_XSync_ms\n')
                for k,arr in res.items():
                    for i,val in enumerate(arr):f.write(f'{k},{i},{val:.6f}\n')
    finally:
        os.close(rd)
        proc.terminate()
        try:proc.wait(timeout=3)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
        proc.stderr.close()

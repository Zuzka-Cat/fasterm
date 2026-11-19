#!/usr/bin/env python3
"""Compare standalone start-to-XSync with ready preconnected worker launch-to-XSync.
Fresh standalone terminal per trial, same persistent Xvfb for all trials.
The preload probe lives inside the worker and timestamps frame processing.
Standalone is also wrapped by exactly the same LD_PRELOAD tracer.
"""
import argparse
import collections
import os
import pathlib
import random
import select
import statistics
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--runs', type=int, default=35)
p.add_argument('--warmup', type=int, default=5)
p.add_argument('--mode', choices=('frame', 'text'), default='frame')
p.add_argument('--seed', type=int, default=13)
p.add_argument('--csv', default='')
p.add_argument('--standalone', default='./fasterm')
p.add_argument('--updated', default='./fasterm')
p.add_argument('--launcher', default='')
p.add_argument('--probe', default='tests/startup_probe.so')
a = p.parse_args()
if 'DISPLAY' not in os.environ: p.error('Run inside persistent Xvfb')
standalone = str(pathlib.Path(a.standalone).resolve())
updated = str(pathlib.Path(a.updated).resolve())
probe = str(pathlib.Path(a.probe).resolve())
launcher = str(pathlib.Path(a.launcher).resolve()) if a.launcher else ''
for name in (standalone,updated,probe) + ((launcher,) if launcher else ()):
    if not pathlib.Path(name).is_file():p.error('Missing '+name)

def report(pipe, start):
    fd=pipe[0]
    if not select.select([fd],[],[],8)[0]: raise TimeoutError('No first-frame probe report')
    data=os.read(fd,16384).decode()
    stamps=[]
    for line in data.splitlines():
        v=line.split()
        if len(v)==3: stamps.append((v[0],int(v[1]),int(v[2])))
    end=next((e for n,s,e in stamps if n=='first_'+a.mode),None)
    if end is None or end < start: raise RuntimeError(f'Bad probe report: {data}')
    return (end-start)/1e6

r,w=os.pipe()
server_env=os.environ.copy()
server_env.update(LD_PRELOAD=probe,FASTERM_BENCH_FD=str(w),FASTERM_BENCH_TARGET=a.mode)
server=subprocess.Popen([updated,'--server'],env=server_env,pass_fds=(w,),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
os.close(w)
try:
    time.sleep(.45)
    if server.poll() is not None: raise RuntimeError('Preload server failed: '+server.stderr.read().decode())
    rng=random.Random(a.seed)
    cases=[v for _ in range(a.runs+a.warmup) for v in rng.sample(('standalone','preconnected'),2)]
    results={'standalone':[],'preconnected':[]}
    script="printf 'FASTERM_READY\\n'; sleep 0.18"
    for idx,kind in enumerate(cases):
        if kind=='standalone':
            rd,wr=os.pipe()
            env=os.environ.copy()
            env.update(LD_PRELOAD=probe,FASTERM_BENCH_FD=str(wr),FASTERM_BENCH_TARGET=a.mode)
            start=time.monotonic_ns()
            proc=subprocess.Popen([standalone,'-e','/bin/sh','-c',script],env=env,pass_fds=(wr,),stderr=subprocess.DEVNULL,stdout=subprocess.DEVNULL)
            os.close(wr)
            try:ms=report((rd,),start)
            finally:
                os.close(rd)
                proc.terminate()
                try:proc.wait(timeout=2)
                except subprocess.TimeoutExpired:proc.kill();proc.wait()
        else:
            start=time.monotonic_ns()
            proc=subprocess.Popen(([launcher] if launcher else [updated,'--client'])+['-e','/bin/sh','-c',script],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            try:
                ms=report((r,),start)
                status=proc.wait(timeout=2)
                if status: raise RuntimeError(proc.stderr.read().decode())
            finally:
                proc.stderr.close()
        # Allow the short child to exit so inactive windows don't accumulate.
        time.sleep(.185)
        if idx>=a.warmup*2: results[kind].append(ms)
    for kind, samples in results.items():
        sorted_ms=sorted(samples)
        print(f'{kind}: n={len(samples)}, median={statistics.median(samples):.3f}ms, '
              f'p10={sorted_ms[int(.1*(len(samples)-1))]:.3f}ms, '
              f'p90={sorted_ms[int(.9*(len(samples)-1))]:.3f}ms')
    a0,b0=map(statistics.median,(results['standalone'],results['preconnected']))
    print(f'savings: {a0-b0:.3f}ms ({100*(a0-b0)/a0:.1f}%)')
    if a.csv:
        with open(a.csv,'w') as f:
            f.write('kind,run,launch_to_server_sync_ms\n')
            for kind,arr in results.items():
                for i,val in enumerate(arr): f.write(f'{kind},{i},{val:.6f}\n')
finally:
    os.close(r)
    server.terminate()
    try:server.wait(timeout=3)
    except subprocess.TimeoutExpired:server.kill();server.wait()
    server.stderr.close()

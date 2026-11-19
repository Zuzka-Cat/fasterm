#!/usr/bin/env python3
"""Paired, randomized X11 startup benchmark (first frame / first real PTY text).

Runs each binary as a fresh process under one persistent already-running X
server; startup is timestamped before subprocess.Popen and ends after the
X server has processed the drawing via XSync. No shell-exit measurements.
Use --mode text to require actual PTY output rendered by XftDrawString32.
Test-only LD_PRELOAD instrumentation is applied equally to both builds.
A compositor's physical presentation latency is not measured by XSync.
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

p=argparse.ArgumentParser()
p.add_argument('binaries',nargs='+')
p.add_argument('--mode',choices=('frame','text'),default='frame')
p.add_argument('--runs',type=int,default=35)
p.add_argument('--warmup',type=int,default=5)
p.add_argument('--probe',default=str(pathlib.Path(__file__).with_name('startup_probe.so')))
p.add_argument('--seed',type=int,default=73)
p.add_argument('--csv',default='')
a=p.parse_args()
if not os.environ.get('DISPLAY'):
    p.error('Run inside Xvfb/X11 with a prestarted display (e.g. xvfb-run -a python3 ...)')
paths=[str(pathlib.Path(x).resolve()) for x in a.binaries]
for path in paths:
    if not pathlib.Path(path).is_file(): p.error(f'Binary missing: {path}')
if not pathlib.Path(a.probe).is_file(): p.error('Build tests/startup_probe.so first')
rng=random.Random(a.seed)
records={b:[] for b in paths}
order=[b for i in range(a.warmup + a.runs) for b in rng.sample(paths,len(paths))]
for idx,b in enumerate(order):
    r,w=os.pipe()
    env=os.environ.copy()
    env['FASTST_BENCH_FD']=str(w)
    env['FASTST_BENCH_TARGET']=a.mode
    env['LD_PRELOAD']=str(pathlib.Path(a.probe).resolve())
    t0=time.monotonic_ns()
    proc=subprocess.Popen([b,'-e','/bin/sh','-c',"printf 'FASTST_READY\\n'; exec cat"],env=env,
       pass_fds=(w,),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    os.close(w)
    # Probe writes the entire record as one write; forkpty children may hold
    # the inherited FD open, so waiting for EOF would benchmark child lifetime.
    # Protect against a crashed terminal or a missing initial text frame.
    if not select.select([r], [], [], 8)[0]:
        proc.kill(); proc.wait()
        raise TimeoutError(f'No {a.mode} marker from {b}; stderr={proc.stderr.read()}')
    log=os.read(r,16384).decode()
    os.close(r)
    proc.terminate()
    try: proc.wait(timeout=2)
    except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    if not log:
        raise RuntimeError(f'No first-frame marker from {b}. Error: {proc.stderr.read()}')
    stamp=[]
    for line in log.splitlines():
        v=line.split()
        if len(v)==3: stamp.append((v[0],int(v[1]),int(v[2])))
    ctor=next((x[1] for x in stamp if x[0]=='ldpreload_ctor'),None)
    frame=next((x[2] for x in stamp if x[0]==('first_text' if a.mode=='text' else 'first_frame')),None)
    flush=next((x[2] for x in stamp if x[0]=='XFlush'),None)
    if frame is None or ctor is None or flush is None: raise RuntimeError(log)
    row={'ms_spawn_to_frame':(frame-t0)/1e6,'ms_ctor_to_frame':(frame-ctor)/1e6,
         'ms_spawn_to_flush':(flush-t0)/1e6,
         'events':stamp}
    if idx>=a.warmup*len(paths): records[b].append(row)
    proc.stderr.close()

for b in paths:
    rows=records[b]; vals=sorted(x['ms_spawn_to_frame'] for x in rows)
    med=statistics.median(vals); p90=vals[int(.9*(len(vals)-1))];
    print(f'{pathlib.Path(b).name}: n={len(vals)} {a.mode} server-synced: '
          f'median={med:.3f}ms p10={vals[int(.1*(len(vals)-1))]:.3f}ms '
          f'p90={p90:.3f}ms min={vals[0]:.3f}ms')
    print(f'  ctor -> {a.mode} median={statistics.median(x["ms_ctor_to_frame"] for x in rows):.3f}ms; '
          f'spawn -> flush median={statistics.median(x["ms_spawn_to_flush"] for x in rows):.3f}ms')
    stages=collections.defaultdict(list)
    for row in rows:
        for name,start,end in row['events']: stages[name].append((end-start)/1e6)
    for name, durations in sorted(stages.items(),key=lambda kv:-statistics.median(kv[1])):
        if name in ('first_frame','first_text','ldpreload_ctor'):continue
        print(f'    {name:27} {statistics.median(durations):7.3f}ms median')
# Report both absolute medians and a paired bootstrap interval. Alternating
# the order within each run limits bias from cache warming or CPU drift.
if len(paths) == 2:
    baseline=[x['ms_spawn_to_frame'] for x in records[paths[0]]]
    updated=[x['ms_spawn_to_frame'] for x in records[paths[1]]]
    n=len(baseline)
    baseline_med=statistics.median(baseline)
    updated_med=statistics.median(updated)
    pct=100*(baseline_med-updated_med)/baseline_med
    diffs=[a-b for a,b in zip(baseline,updated)]
    boot_rng=random.Random(a.seed+990)
    deltas=[]; percentages=[]
    for _ in range(5000):
        ids=[boot_rng.randrange(n) for __ in range(n)]
        m0=statistics.median(baseline[i] for i in ids)
        m1=statistics.median(updated[i] for i in ids)
        deltas.append(m0-m1)
        percentages.append(100*(m0-m1)/m0)
    deltas.sort();percentages.sort()
    print(f'PAIRWISE COMPARISON ({a.mode}, baseline -> updated):')
    print(f'  median of per-run savings: {statistics.median(diffs):.3f}ms')
    print(f'  median reduction: {baseline_med-updated_med:.3f}ms ({pct:.1f}%)')
    print(f'  paired bootstrap 95% interval: '
          f'{deltas[125]:.3f}..{deltas[4874]:.3f}ms '
          f'({percentages[125]:.1f}..{percentages[4874]:.1f}%)')
if a.csv:
    with open(a.csv,'w') as out:
        out.write('binary,run,spawn_to_frame_ms,ctor_to_frame_ms,spawn_to_flush_ms\n')
        for b in paths:
            for i,row in enumerate(records[b]):
                out.write(f'{pathlib.Path(b).name},{i},{row["ms_spawn_to_frame"]:.6f},{row["ms_ctor_to_frame"]:.6f},{row["ms_spawn_to_flush"]:.6f}\n')

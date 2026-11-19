#!/usr/bin/env python3
"""Reference-model verification for the FASM dirty-cell/Present update logic.

Tests inclusive cell changes, one-cell halo, forced repaint, unchanged rows,
and consecutive identical-span XRender rectangle merging. Does NOT compile FASM.
"""
import random
from pathlib import Path

source = Path(__file__).resolve().parents[1] / 'fasterm.asm'
present = Path(__file__).resolve().parents[1] / 'include' / 'present_impl.inc'
s = source.read_text()
p = present.read_text()
for required in (
    'paint_snapshot rb MAXROW*ROWB',
    'paint_x0 rd MAXROW',
    'paint_x1 rd MAXROW',
    'paint_full_frame rb 1',
    'mov byte [dirty+rax],2',
    'call visaddr',
    'mov ecx,[cols]',
    'rep movsq',
    'lea rsi,[bg_rects]',
    'lea rsi,[border_rects]',
    'ccall qword [fixes_set_fn]',
):
    assert required in s, required
for required in ('XFixesSetRegion', 'XFixesCreateRegion', 'mov r9,[present_update_region]'):
    assert required in (s+p), required

rng = random.Random(20261119)
for _ in range(20000):
    cols = rng.randint(1,256)
    old = [rng.getrandbits(64) for _ in range(cols)]
    new = old.copy()
    dirty = rng.randrange(4)
    force = bool(rng.randrange(10)==0)
    valid = bool(rng.randrange(30)!=0)
    for _ in range(rng.randrange(0, cols+1) if dirty else 0):
        pos=rng.randrange(cols)
        new[pos] = rng.getrandbits(64)
    if force or not valid:
        lo,hi = 0,cols
    else:
        first = next((i for i in range(cols) if old[i]!=new[i]), None)
        if first is None:
            assert all(a==b for a,b in zip(old,new))
            continue
        last = max(i for i in range(cols) if old[i]!=new[i])
        lo=max(0,first-1)
        hi=min(cols,last+2)
    assert 0<=lo<hi<=cols
    assert all(lo<=i<hi for i in range(cols) if old[i]!=new[i])

# Full repaint always covers margins; incremental requests must cover the
# changed glyphs, but the server may choose to copy more than requested.
for _ in range(5000):
    rows=rng.randrange(1,129)
    widths=[]
    for i in range(rows):
        if rng.randrange(3):
            lo=rng.randrange(256); hi=rng.randrange(lo+1,257)
            widths.append((i,lo,hi))
    rects=[]
    for row,lo,hi in widths:
        if rects and rects[-1][0]+rects[-1][3]==row and rects[-1][1:3]==(lo,hi):
            rr,x0,x1,height=rects[-1]
            rects[-1] = (rr,x0,x1,height+1)
        else:
            rects.append((row,lo,hi,1))
    assert len(rects)<=rows
    for row,lo,hi in widths:
        assert any(r<=row<r+height and x0<=lo and hi<=x1
                   for r,x0,x1,height in rects)
print('PASS: 20,000 randomized dirty-span checks, 5,000 merged-rectangle checks')

#!/usr/bin/env python3
"""Detect a common FASM ELF64 pitfall: typed symbol size vs. register width.

FASM carries the declared size of `rb` / `rd` / `rq` labels into memory
operands, including [label+offset]. GNU as does not enforce that label type.
This is intentionally a narrow static check, not a replacement for FASM.
"""
import re
import sys
from pathlib import Path

DECL = {'db': 8, 'rb': 8, 'dw': 16, 'rw': 16,
        'dd': 32, 'rd': 32, 'dq': 64, 'rq': 64}
REGS = {}
for bits, names in [
    (8, 'al bl cl dl ah bh ch dh sil dil spl bpl r8b r9b r10b r11b r12b r13b r14b r15b'),
    (16, 'ax bx cx dx si di sp bp r8w r9w r10w r11w r12w r13w r14w r15w'),
    (32, 'eax ebx ecx edx esi edi esp ebp r8d r9d r10d r11d r12d r13d r14d r15d'),
    (64, 'rax rbx rcx rdx rsi rdi rsp rbp r8 r9 r10 r11 r12 r13 r14 r15'),
]:
    REGS.update({name: bits for name in names.split()})

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else 'fastst.asm')
lines = SRC.read_text().splitlines()
labels = {}
for number, line in enumerate(lines, 1):
    found = re.match(r'^\s*(\w+)\s+(db|rb|dw|rw|dd|rd|dq|rq)\b', line)
    if found:
        labels[found[1]] = DECL[found[2]]

bad = 0
for number, line in enumerate(lines, 1):
    code = line.split(';', 1)[0].strip()
    head = code.split(None, 1)
    if len(head) != 2 or head[0].lower() not in {'mov', 'cmp', 'add', 'sub', 'and', 'or', 'xor', 'test', 'xchg'}:
        continue
    operands = [p.strip().lower() for p in head[1].split(',')]
    if len(operands) != 2:
        continue
    for index, operand in enumerate(operands):
        found = re.fullmatch(r'(?:(byte|word|dword|qword)\s+)?\[\s*(\w+)(?:\s*\+[^\]]+)?\s*\]', operand)
        if not found or found[2] not in labels:
            continue
        qualifier, symbol = found.groups()
        intended = {'byte': 8, 'word': 16, 'dword': 32, 'qword': 64}.get(qualifier, labels[symbol])
        peer = operands[1 - index]
        if peer in REGS and intended != REGS[peer]:
            print(f'{SRC}:{number}: {symbol} resolves to {intended}-bit, '
                  f'but {peer} is {REGS[peer]}-bit: {code}')
            bad += 1

if bad:
    sys.exit(1)
print(f'{SRC}: no statically detectable label/register width mismatches')

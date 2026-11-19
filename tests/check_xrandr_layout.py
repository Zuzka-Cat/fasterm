#!/usr/bin/env python3
"""Sanity-check FASM ABI struct layouts against independent LP64 ctypes models.

FASM has its own stronger assemble-time assertions in include/xrandr.inc.
This lightweight check works even on machines without an assembler.
"""
import ctypes as C
import re
from pathlib import Path

SRC = Path('include/xrandr.inc').read_text()


class Mode(C.Structure):
    _fields_ = [
        ('id', C.c_ulong), ('width', C.c_uint), ('height', C.c_uint),
        ('dotClock', C.c_ulong), ('hSyncStart', C.c_uint), ('hSyncEnd', C.c_uint),
        ('hTotal', C.c_uint), ('hSkew', C.c_uint), ('vSyncStart', C.c_uint),
        ('vSyncEnd', C.c_uint), ('vTotal', C.c_uint), ('name', C.c_void_p),
        ('nameLength', C.c_uint), ('modeFlags', C.c_ulong),
    ]


class Resources(C.Structure):
    _fields_ = [
        ('timestamp', C.c_ulong), ('configTimestamp', C.c_ulong),
        ('ncrtc', C.c_int), ('crtcs', C.c_void_p), ('noutput', C.c_int),
        ('outputs', C.c_void_p), ('nmode', C.c_int), ('modes', C.c_void_p),
    ]


class Crtc(C.Structure):
    _fields_ = [
        ('timestamp', C.c_ulong), ('x', C.c_int), ('y', C.c_int),
        ('width', C.c_uint), ('height', C.c_uint), ('mode', C.c_ulong),
        ('rotation', C.c_ushort), ('noutput', C.c_int),
        ('outputs', C.c_void_p), ('rotations', C.c_ushort),
        ('npossible', C.c_int), ('possible', C.c_void_p),
    ]


class Cache(C.Structure):
    _fields_ = [
        ('x', C.c_int), ('y', C.c_int), ('width', C.c_uint),
        ('height', C.c_uint), ('period', C.c_ulonglong),
        ('unused', C.c_ulonglong),
    ]


def fasm_fields(struct):
    match = re.search(rf'struc {struct} \{{(.*?)\n\}}', SRC, re.S)
    assert match, f'Missing {struct}'
    pos = 0
    fields = {}
    sizes = {'rb': 1, 'rw': 2, 'rd': 4, 'rq': 8}
    for line in match[1].splitlines():
        line = line.split(';', 1)[0].strip()
        if not line:
            continue
        field = re.fullmatch(r'(\.\w+\s+)?(rb|rw|rd|rq)\s+(\d+)', line)
        assert field, f'Unexpected directive: {line}'
        name, kind, count = field.groups()
        if name:
            fields[name.strip()[1:]] = pos
        pos += sizes[kind] * int(count)
    return fields, pos


for fasm_name, python_type in [
    ('xrr_mode_info', Mode), ('xrr_screen_resources', Resources),
    ('xrr_crtc_info', Crtc), ('xrr_cache_entry', Cache),
]:
    fields, size = fasm_fields(fasm_name)
    assert size == C.sizeof(python_type), (fasm_name, size, C.sizeof(python_type))
    for name, offset in fields.items():
        assert offset == getattr(python_type, name).offset, (fasm_name, name, offset)
    print(f'{fasm_name}: {size} bytes, {len(fields)} ABI fields verified')

# Regression inputs for the precise integer arithmetic used in randr_mode_period.
def period(dotclock, htotal, vtotal, double_scan=False, interlace=False):
    numerator = 1_000_000_000 * htotal * vtotal * (2 if double_scan else 1)
    if interlace:
        numerator //= 2
    return (numerator + dotclock // 2) // dotclock

assert period(148_500_000, 2200, 1125) == 16_666_667
assert period(593_406_000, 2200, 1125) == 4_170_838
assert period(891_000_000, 2200, 1125) == 2_777_778
assert period(148_500_000, 2200, 1125, double_scan=True) == 33_333_333
assert period(148_500_000, 2200, 1125, interlace=True) == 8_333_333
print('XRandR fractional, interlaced and double-scan rate arithmetic: OK')

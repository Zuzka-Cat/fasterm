#!/usr/bin/env python3
"""Static validation of XPresent event/call ABI and presentation invariants.
Does not make claims about physical Xorg/vblank behavior without a monitor.
"""
import ctypes as c
import re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
inc=(root/'include/present.inc').read_text()
impl=(root/'include/present_impl.inc').read_text()
asm=(root/'fasterm.asm').read_text()

class Cookie(c.Structure):
    _fields_=[('type',c.c_int),('serial',c.c_ulong),('send_event',c.c_int),('display',c.c_void_p),('extension',c.c_int),('evtype',c.c_int),('cookie',c.c_uint),('data',c.c_void_p)]
class Idle(c.Structure):
    _fields_=[('type',c.c_int),('serial',c.c_ulong),('send_event',c.c_int),('display',c.c_void_p),('extension',c.c_int),('evtype',c.c_int),('eid',c.c_uint),('window',c.c_ulong),('serial_number',c.c_uint),('pixmap',c.c_ulong),('idle_fence',c.c_ulong)]
assert c.sizeof(Cookie)==56 and Cookie.extension.offset==32 and Cookie.data.offset==48
assert c.sizeof(Idle)==80 and Idle.eid.offset==40 and Idle.serial_number.offset==56 and Idle.pixmap.offset==64
assert 'XGenericCookie.data <> 48' in inc and 'XPresentIdle.serial_number <> 56' in inc
# SysV arg slots: 1-6 in registers, 7-17 in 11 64-bit stack slots.
for addr in range(0,81,8):
    assert re.search(r'\[rsp(?:\+'+str(addr)+r')?\]',impl) if addr else 'mov [rsp],rax' in impl
assert 'mov qword [rsp+40],PresentOptionCopy' in impl
assert 'sub rsp,96' in impl
assert 'PresentOptionAsync' not in impl.replace('no PresentOptionAsync','')
assert 'cmp edx,[present_serial]' in impl
assert 'call XCopyArea' not in asm
assert 'call present_receive_idle' in asm and 'call present_submit' in asm
assert 'cmp byte [present_busy],0' in asm
assert 'call present_disable' in asm and 'call recreate_draw_target' in impl
# No native C helper or source for display/refresh/presentation.
assert not (root/'refresh.c').exists()
assert 'ccall qword [present_query_fn]' in impl
print('PASS: FASM XPresent ABI, serial gating, copy option, no XCopyArea, direct fallback')

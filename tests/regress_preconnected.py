#!/usr/bin/env python3
"""End-to-end fastst preconnected-worker launcher regression under Xvfb.

Exercises real command launching, caller environment, cwd, multiple windows,
malformed same-uid requests, and overlong request rejection. An isolated Xvfb
instance is required because the server uses an abstract UID+DISPLAY socket.
"""
import os
import pathlib
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import time

if len(sys.argv)!=3:
    raise SystemExit('usage: regress_preconnected.py TERMINAL LAUNCHER')
terminal=str(pathlib.Path(sys.argv[1]).resolve())
launcher=str(pathlib.Path(sys.argv[2]).resolve())
if not os.environ.get('DISPLAY'): raise SystemExit('Run with xvfb-run -a')
server=subprocess.Popen([terminal,'--server'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
try:
    time.sleep(.4)
    if server.poll() is not None:
        raise RuntimeError('preconnected server failed: '+server.stderr.read().decode())
    # An untrusted/malformed local request must not kill the warm worker.
    name=(f'fastst-v3:{os.geteuid()}:{os.environ["DISPLAY"]}').encode()
    address=(b'\0'+name)[:108].ljust(108,b'\0')
    with socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET) as s:
        s.connect(address)
        s.sendall(b'wrong protocol'.ljust(32768,b'\0'))

    with tempfile.TemporaryDirectory() as tmp:
        out=pathlib.Path(tmp,'output.txt')
        env=os.environ.copy()
        env['FASTST_IPC_TEST']='ENV_OK'
        env['FASTST_LONG_ENV']='Q'*14000
        # Check the actual PTY child, not merely the launcher's exit status.
        cmd=f'printf "%s\\n%s\\n%s\\n" "$FASTST_IPC_TEST" "$PWD" "$FASTST_LONG_ENV" > {shlex.quote(str(out))}'
        proc=subprocess.run([launcher,'-e','/bin/sh','-c',cmd],cwd=tmp,env=env,
                            capture_output=True,timeout=4)
        assert proc.returncode==0,(proc.returncode,proc.stderr)
        for _ in range(300):
            if out.exists(): break
            time.sleep(.01)
        assert out.exists(),'PTY shell never started'
        values=out.read_text().splitlines()
        assert values==['ENV_OK',tmp,'Q'*14000], 'argv/cwd/env differs from client'

    # More than the two warm workers: the supervisor must replenish on demand.
    clients=[subprocess.Popen([launcher,'-e','/bin/sh','-c','printf B; sleep 1.3'],
                              stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
             for _ in range(8)]
    try:
        for proc in clients:
            assert proc.wait(timeout=5)==0,proc.stderr.read().decode()
        windows=0
        for _ in range(50):
            tree=subprocess.run(['xwininfo','-root','-tree'],capture_output=True,text=True,timeout=3).stdout
            ids=re.findall(r'(0x[0-9a-fA-F]+) "fastst - FASM X11 terminal"',tree)
            # Idle workers precreate UNMAPPED X windows; they must not count as
            # launched/visible terminals. Check actual X11 Map State instead.
            mapped=0
            for xid in ids:
                result=subprocess.run(['xwininfo','-id',xid],capture_output=True,text=True,timeout=3)
                if 'Map State: IsViewable' in result.stdout:mapped+=1
            windows=max(windows,mapped)
            if windows>=8:break
            time.sleep(.02)
        assert windows>=8,f'Only {windows}/8 preconnected windows are mapped'
    finally:
        for proc in clients:proc.stderr.close()

    # Over-sized environment must fail closed, not overflow or silently drop.
    huge_env=os.environ.copy()
    huge_env['FASTST_ENV_OVERFLOW_TEST']='Y'*42000
    proc=subprocess.run([launcher,'-e','/bin/true'],env=huge_env,capture_output=True,timeout=5)
    assert proc.returncode!=0,'Oversized environment did not reject launch'

    print('PASS: prepared X11 worker launches, exact cwd/argv/env (14KB), malformed-request rejection, 8 concurrent windows, oversized-request rejection')
finally:
    server.terminate()
    try:server.wait(timeout=3)
    except subprocess.TimeoutExpired:server.kill();server.wait()
    server.stderr.close()

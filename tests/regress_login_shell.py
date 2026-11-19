#!/usr/bin/env python3
"""Default shell must follow chsh/NSS even when service/client SHELL is stale.

Exercises both direct execution and prepared-worker launching under isolated Xvfb.
Also checks FASTERM_SHELL is an intentional override, unlike inherited SHELL.
"""
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 3:
    raise SystemExit('usage: regress_login_shell.py TERMINAL LAUNCHER')
term = str(Path(sys.argv[1]).resolve())
launcher = str(Path(sys.argv[2]).resolve())
if not os.environ.get('DISPLAY'):
    raise SystemExit('run with xvfb-run -a')
login_shell = pwd.getpwuid(os.getuid()).pw_shell
assert login_shell, 'test account has no configured login shell'
resolved_login_shell = os.path.realpath(login_shell)


def descendants(pid):
    """Find Linux child processes using /proc status (children file is optional)."""
    children_by_parent = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            for line in (entry / 'status').read_text().splitlines():
                if line.startswith('PPid:'):
                    parent = int(line.split()[1])
                    children_by_parent.setdefault(parent, []).append(int(entry.name))
                    break
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    found = []
    pending = [pid]
    while pending:
        current = pending.pop()
        direct = children_by_parent.get(current, [])
        found.extend(direct)
        pending.extend(direct)
    return found


def started_login_shell(pid):
    for child in descendants(pid):
        try:
            exe = os.path.realpath(os.readlink(f'/proc/{child}/exe'))
            if exe != resolved_login_shell:
                continue
            environ = Path(f'/proc/{child}/environ').read_bytes().split(b'\0')
            expected = f'SHELL={login_shell}'.encode()
            assert expected in environ, f'launched {exe} but SHELL not synchronized'
            return True
        except (FileNotFoundError, ProcessLookupError):
            continue
    return False


def wait_for(predicate, message, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.04)
    raise AssertionError(message)


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


env = os.environ.copy()
env.pop('FASTERM_SHELL', None)
env['SHELL'] = '/bin/false'  # deliberately stale, like systemd after chsh
with tempfile.TemporaryDirectory() as tmp:
    direct = subprocess.Popen([term], env=env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE)
    try:
        wait_for(lambda: started_login_shell(direct.pid),
                 'direct fasterm used stale $SHELL instead of passwd pw_shell')
    finally:
        stop(direct)
        direct.stderr.close()

    server = subprocess.Popen([term, '--server'], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        time.sleep(.45)  # let the server create the listening socket and prewarm
        assert server.poll() is None, 'server exited unexpectedly'
        result = subprocess.run([launcher], env=env, capture_output=True, timeout=4)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        wait_for(lambda: started_login_shell(server.pid),
                 'preconnected fasterm-launch used stale caller/server $SHELL')

        # A deliberate, explicit override must still work with prepared workers.
        script = Path(tmp) / 'custom-shell'
        marker = Path(tmp) / 'selected-shell'
        script.write_text('#!/bin/sh\nprintf "%s" "$SHELL" > '+repr(str(marker))+'\nsleep 2\n')
        script.chmod(0o755)
        overridden = env.copy()
        overridden['FASTERM_SHELL'] = str(script)
        result = subprocess.run([launcher], env=overridden,
                                capture_output=True, timeout=4)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        wait_for(marker.exists, 'FASTERM_SHELL override did not start')
        assert marker.read_text() == str(script), 'child SHELL did not match override'
    finally:
        stop(server)
        server.stderr.close()
print('PASS: passwd login shell overrides stale SHELL in direct and server launches; FASTERM_SHELL override works')

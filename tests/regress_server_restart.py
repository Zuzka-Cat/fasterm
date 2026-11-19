#!/usr/bin/env python3
"""Restart a server & dedicated hotkey without killing an existing window.

This exercises the actual Linux PR_SET_PDEATHSIG lifecycle used by the
KillMode=process user service. Run with xvfb-run and libXtst installed.
"""
import ctypes as ct
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

assert len(sys.argv) == 3, 'usage: regress_server_restart.py TERM HOTKEY'
term = str(Path(sys.argv[1]).resolve())
hotkey = str(Path(sys.argv[2]).resolve())

x = ct.CDLL('libX11.so.6')
t = ct.CDLL('libXtst.so.6')
x.XOpenDisplay.argtypes = [ct.c_char_p]
x.XOpenDisplay.restype = ct.c_void_p
x.XCloseDisplay.argtypes = [ct.c_void_p]
x.XKeysymToKeycode.argtypes = [ct.c_void_p, ct.c_ulong]
x.XKeysymToKeycode.restype = ct.c_uint
x.XStringToKeysym.argtypes = [ct.c_char_p]
x.XStringToKeysym.restype = ct.c_ulong
x.XSync.argtypes = [ct.c_void_p, ct.c_int]
t.XTestFakeKeyEvent.argtypes = [ct.c_void_p, ct.c_uint, ct.c_int, ct.c_ulong]


def visible_window_ids():
    out = subprocess.run(['xwininfo', '-root', '-tree'], capture_output=True,
                         text=True, check=True, timeout=3).stdout
    ids = re.findall(r'(0x[0-9a-fA-F]+) "fasterm - FASM X11 terminal"', out)
    return {win_id for win_id in ids if 'Map State: IsViewable' in
            subprocess.run(['xwininfo', '-id', win_id], capture_output=True,
                           text=True, check=True, timeout=3).stdout}


def wait_for(predicate, message, timeout=4):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.04)
    raise AssertionError(message)


def stop(proc):
    if proc is None:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


with tempfile.TemporaryDirectory() as directory:
    marker = Path(directory) / 'launches'
    shell = Path(directory) / 'shell'
    shell.write_text(f'#!/bin/sh\necho ready >> "{marker}"\nexec sleep 15\n')
    shell.chmod(0o755)
    env = os.environ.copy()
    env['SHELL'] = str(shell)
    dpy = x.XOpenDisplay(None)
    assert dpy, 'XOpenDisplay failed'
    keys = [x.XKeysymToKeycode(dpy, x.XStringToKeysym(name)) for name in
            (b'Control_L', b'Alt_L', b'Return')]
    assert all(keys), 'missing X11 keycodes'

    def press_hotkey():
        for key in keys:
            t.XTestFakeKeyEvent(dpy, key, 1, 0)
        for key in reversed(keys):
            t.XTestFakeKeyEvent(dpy, key, 0, 0)
        x.XSync(dpy, False)

    def launched_count():
        return marker.read_text().count('ready\n') if marker.exists() else 0

    srv = hk = None
    try:
        srv = subprocess.Popen([term, '--server'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
        assert srv.poll() is None, 'server failed to start'
        hk = subprocess.Popen([hotkey], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.3)
        assert hk.poll() is None, 'hotkey failed to start'
        press_hotkey()
        wait_for(lambda: launched_count() == 1 and bool(visible_window_ids()),
                 'first hotkey launch failed')
        original_windows = visible_window_ids()
        assert original_windows

        # The native stop command uses SO_PEERCRED to kill ONLY the original
        # listening server, not its preforked workers or terminal windows.
        result = subprocess.run([term, '--stop-server'], env=env, timeout=4)
        assert result.returncode == 0, 'native --stop-server failed'
        srv.wait(timeout=4)
        srv = None
        time.sleep(0.2)
        assert original_windows <= visible_window_ids(), \
            'server shutdown unexpectedly killed already-open terminals'

        # Hotkey has a live socket tied to an old preforked worker; restart it
        # after bringing the new server back, just like the service units do.
        stop(hk)
        hk = None
        srv = subprocess.Popen([term, '--server'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
        assert srv.poll() is None, 'replacement server failed to start'
        hk = subprocess.Popen([hotkey], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.3)
        assert hk.poll() is None, 'replacement hotkey failed to grab key'
        press_hotkey()
        wait_for(lambda: launched_count() == 2 and len(visible_window_ids()) >= 2,
                 'replacement hotkey launch failed')
        assert original_windows <= visible_window_ids(), \
            'old terminal windows disappeared after restarting both services'
        print('PASS: server+hotkey restart launches new terminal; existing window stays open')
    finally:
        stop(hk)
        stop(srv)
        x.XCloseDisplay(dpy)

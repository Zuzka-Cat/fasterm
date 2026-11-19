#!/usr/bin/env python3
"""Deployment invariant checks; no systemd user session required."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
server = (root / 'systemd/fasterm-server.service.in').read_text()
hotkey = (root / 'systemd/fasterm-hotkey.service.in').read_text()
make = (root / 'Makefile').read_text()

assert 'ExecStart=@BINDIR@/fasterm --server' in server
assert 'KillMode=process' in server, 'default cgroup kill would close existing terminals'
assert 'ExecStart=@BINDIR@/fasterm-hotkey' in hotkey
assert 'After=fasterm-server.service' in hotkey
assert 'Requires=fasterm-server.service' in hotkey
assert 'PartOf=fasterm-server.service' in hotkey
assert '$(SYSTEMCTL) --user import-environment DISPLAY XAUTHORITY' in make
assert '$(SYSTEMCTL) --user restart fasterm-server.service fasterm-hotkey.service' in make
assert '$(BINDIR)/fasterm' in make and '--stop-server' in make
assert 'pkill -u' in make and '-x fasterm-hotkey' in make
print('PASS: service updates preserve existing terminals and reload both daemons')

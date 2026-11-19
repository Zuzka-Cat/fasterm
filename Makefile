# fasterm: Linux x86-64 / X11, assembled with FASM.
# `make` builds only the terminal, static launcher, and resident hotkey client.

FASM    ?= fasm
CC      ?= cc
LD      ?= ld
INSTALL ?= install
SYSTEMCTL ?= systemctl

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
DESTDIR ?=
UNITDIR ?= $(if $(filter $(HOME)/.local,$(PREFIX)),$(HOME)/.local/share/systemd/user,$(PREFIX)/lib/systemd/user)

# Keep the existing small, non-PIE Linux ELF link layout.
TERM_LDFLAGS ?= -no-pie -Wl,-z,relro -Wl,-z,now -Wl,--build-id=none -Wl,-z,noseparate-code
TERM_LIBS    ?= -lX11 -l:libXft.so.2 -l:libXrender.so.1 -l:libXrandr.so.2 -l:libfontconfig.so.1 -lutil -ldl -pthread

PROGRAMS = fasterm fasterm-launch fasterm-hotkey
# FASM includes are source dependencies, not merely text substituted at build time.
FASM_INCLUDES := $(wildcard include/*.inc)

.PHONY: all install uninstall clean check check-server start stop status logs restart takeover update dev check-services

all: $(PROGRAMS)

%.o: %.asm $(FASM_INCLUDES)
	$(FASM) $< $@

fasterm: fasterm.o
	$(CC) $(TERM_LDFLAGS) -s -o $@ $< $(TERM_LIBS)

# No libc, X11, or dynamic loader in the launcher.
fasterm-launch: fasterm-launch.o
	$(LD) -static -s --build-id=none -o $@ $<

fasterm-hotkey: fasterm-hotkey.o
	$(CC) -no-pie -Wl,--build-id=none -s -o $@ $< -lX11

install: $(PROGRAMS)
	$(INSTALL) -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(UNITDIR)"
	$(INSTALL) -m 755 $(PROGRAMS) "$(DESTDIR)$(BINDIR)/"
	@# User services use the exact installed binary path, including PREFIX overrides.
	sed 's|@BINDIR@|$(BINDIR)|g' systemd/fasterm-server.service.in > "$(DESTDIR)$(UNITDIR)/fasterm-server.service"
	sed 's|@BINDIR@|$(BINDIR)|g' systemd/fasterm-hotkey.service.in > "$(DESTDIR)$(UNITDIR)/fasterm-hotkey.service"
	chmod 644 "$(DESTDIR)$(UNITDIR)/fasterm-server.service" "$(DESTDIR)$(UNITDIR)/fasterm-hotkey.service"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/fasterm" \
	      "$(DESTDIR)$(BINDIR)/fasterm-launch" \
	      "$(DESTDIR)$(BINDIR)/fasterm-hotkey" \
	      "$(DESTDIR)$(UNITDIR)/fasterm-server.service" \
	      "$(DESTDIR)$(UNITDIR)/fasterm-hotkey.service"

# Run as the desktop user (NEVER sudo): import X11 environment, reload unit
# changes, then let systemd restart the server and hotkey in dependency order.
# KillMode=process is essential: it keeps already-open terminals alive.
restart:
	@test -n "$$DISPLAY" || { echo 'restart: DISPLAY is missing (run inside your i3/X11 session)' >&2; exit 1; }
	$(SYSTEMCTL) --user import-environment DISPLAY XAUTHORITY
	$(SYSTEMCTL) --user daemon-reload
	$(SYSTEMCTL) --user restart fasterm-server.service fasterm-hotkey.service

# Convenience controls; native systemd keeps the server and hotkey supervised.
start:
	@test -n "$$DISPLAY" || { echo 'start: DISPLAY is missing' >&2; exit 1; }
	$(SYSTEMCTL) --user import-environment DISPLAY XAUTHORITY
	$(SYSTEMCTL) --user daemon-reload
	$(SYSTEMCTL) --user start fasterm-hotkey.service

stop:
	$(SYSTEMCTL) --user stop fasterm-hotkey.service fasterm-server.service

status:
	$(SYSTEMCTL) --user --no-pager status fasterm-server.service fasterm-hotkey.service

logs:
	journalctl --user -u fasterm-server.service -u fasterm-hotkey.service -n 60 --no-pager

# One-time migration (also safe on future updates): end unmanaged copies
# of the hotkey, and stop the *actual* listening server PID via SO_PEERCRED.
# Never use pkill fasterm: terminal windows share the process name.
takeover:
	@test -n "$$DISPLAY" || { echo 'takeover: DISPLAY is missing' >&2; exit 1; }
	@pkill -u "$$(id -u)" -x fasterm-hotkey 2>/dev/null || true
	@"$(BINDIR)/fasterm" --stop-server >/dev/null 2>&1 || true
	@sleep 0.25
	$(MAKE) restart

# One-command developer update for the default /usr/local installation.
# Build without root, elevate *only* the file installation, and restart user
# services as the actual logged-in user. Do not use 'sudo make update'.
update: all
	sudo $(MAKE) install PREFIX="$(PREFIX)" BINDIR="$(BINDIR)" UNITDIR="$(UNITDIR)"
	$(MAKE) takeover

dev: update

# Check service specs without touching the user's systemd instance.
check-services:
	python3 tests/check_services.py

# Focused test suite; only runs when requested. Requires Xvfb and Python 3.
check: $(PROGRAMS) check-services
	python3 tests/check_fasm_widths.py fasterm.asm
	python3 tests/check_xrandr_layout.py
	python3 tests/check_present_fasm.py
	python3 tests/check_fasm_widths.py fasterm-launch.asm
	python3 tests/check_fasm_widths.py fasterm-hotkey.asm
	xvfb-run -a python3 tests/regress_scrollback_input.py ./fasterm
	xvfb-run -a python3 tests/regress_modified_arrows.py ./fasterm
	xvfb-run -a python3 tests/regress_altscreen_restore.py ./fasterm
	xvfb-run -a python3 tests/regress_vim_exit.py ./fasterm
	python3 tests/regress_unicode_fallback.py ./fasterm
	xvfb-run -a python3 tests/regress_escape_stress.py ./fasterm
	xvfb-run -a python3 tests/regress_rendering.py ./fasterm
	xvfb-run -a python3 tests/regress_fullscreen_buffer.py ./fasterm
	xvfb-run -a python3 tests/regress_cell_geometry.py ./fasterm
	xvfb-run -a python3 tests/regress_insert_mode.py ./fasterm
	xvfb-run -a python3 tests/regress_paste_resize.py ./fasterm

# More expensive end-to-end server tests; needs XTest (libXtst).
check-server: $(PROGRAMS)
	xvfb-run -a python3 tests/regress_preconnected.py ./fasterm ./fasterm-launch
	xvfb-run -a python3 tests/regress_login_shell.py ./fasterm ./fasterm-launch
	xvfb-run -a python3 tests/regress_hotkey.py ./fasterm ./fasterm-hotkey
	xvfb-run -a python3 tests/regress_server_restart.py ./fasterm ./fasterm-hotkey

clean:
	rm -f $(PROGRAMS) fasterm.o fasterm-launch.o fasterm-hotkey.o

# fasterm: Linux x86-64 / X11, assembled with FASM.
# `make` builds only the terminal, static launcher, and resident hotkey client.

FASM    ?= fasm
CC      ?= cc
LD      ?= ld
INSTALL ?= install

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
DESTDIR ?=

# Keep the existing small, non-PIE Linux ELF link layout.
TERM_LDFLAGS ?= -no-pie -Wl,-z,relro -Wl,-z,now -Wl,--build-id=none -Wl,-z,noseparate-code
TERM_LIBS    ?= -lX11 -l:libXft.so.2 -l:libfontconfig.so.1 -lutil -pthread

PROGRAMS = fasterm fasterm-launch fasterm-hotkey

.PHONY: all install uninstall clean check check-server

all: $(PROGRAMS)

%.o: %.asm
	$(FASM) $< $@

fasterm: fasterm.o
	$(CC) $(TERM_LDFLAGS) -s -o $@ $< $(TERM_LIBS)

# No libc, X11, or dynamic loader in the launcher.
fasterm-launch: fasterm-launch.o
	$(LD) -static -s --build-id=none -o $@ $<

fasterm-hotkey: fasterm-hotkey.o
	$(CC) -no-pie -Wl,--build-id=none -s -o $@ $< -lX11

install: $(PROGRAMS)
	$(INSTALL) -d "$(DESTDIR)$(BINDIR)"
	$(INSTALL) -m 755 $(PROGRAMS) "$(DESTDIR)$(BINDIR)/"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/fasterm" \
	      "$(DESTDIR)$(BINDIR)/fasterm-launch" \
	      "$(DESTDIR)$(BINDIR)/fasterm-hotkey"

# Focused test suite; only runs when requested. Requires Xvfb and Python 3.
check: $(PROGRAMS)
	python3 tests/check_fasm_widths.py fasterm.asm
	python3 tests/check_fasm_widths.py fasterm-launch.asm
	python3 tests/check_fasm_widths.py fasterm-hotkey.asm
	xvfb-run -a python3 tests/regress_scrollback_input.py ./fasterm
	xvfb-run -a python3 tests/regress_altscreen_restore.py ./fasterm
	xvfb-run -a python3 tests/regress_vim_exit.py ./fasterm
	python3 tests/regress_unicode_fallback.py ./fasterm
	xvfb-run -a python3 tests/regress_escape_stress.py ./fasterm
	xvfb-run -a python3 tests/regress_rendering.py ./fasterm
	xvfb-run -a python3 tests/regress_insert_mode.py ./fasterm
	xvfb-run -a python3 tests/regress_paste_resize.py ./fasterm

# More expensive end-to-end server tests; needs XTest (libXtst).
check-server: $(PROGRAMS)
	xvfb-run -a python3 tests/regress_preconnected.py ./fasterm ./fasterm-launch
	xvfb-run -a python3 tests/regress_hotkey.py ./fasterm ./fasterm-hotkey

clean:
	rm -f $(PROGRAMS) fasterm.o fasterm-launch.o fasterm-hotkey.o

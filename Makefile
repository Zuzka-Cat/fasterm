# fastst: Linux x86-64 / X11, assembled with FASM.
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

PROGRAMS = fastst fastst-launch fastst-hotkey

.PHONY: all install uninstall clean check check-server fast-launch fast-hotkey

all: $(PROGRAMS)

%.o: %.asm
	$(FASM) $< $@

fastst: fastst.o
	$(CC) $(TERM_LDFLAGS) -s -o $@ $< $(TERM_LIBS)

# No libc, X11, or dynamic loader in the launcher.
fastst-launch: fastst-launch.o
	$(LD) -static -s --build-id=none -o $@ $<

fastst-hotkey: fastst-hotkey.o
	$(CC) -no-pie -Wl,--build-id=none -s -o $@ $< -lX11

# Compatibility with the previous documented build targets.
fast-launch: fastst fastst-launch
fast-hotkey: fastst fastst-hotkey

install: $(PROGRAMS)
	$(INSTALL) -d "$(DESTDIR)$(BINDIR)"
	$(INSTALL) -m 755 $(PROGRAMS) "$(DESTDIR)$(BINDIR)/"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/fastst" \
	      "$(DESTDIR)$(BINDIR)/fastst-launch" \
	      "$(DESTDIR)$(BINDIR)/fastst-hotkey"

# Focused test suite; only runs when requested. Requires Xvfb and Python 3.
check: $(PROGRAMS)
	python3 tests/check_fasm_widths.py fastst.asm
	python3 tests/check_fasm_widths.py fastst-launch.asm
	python3 tests/check_fasm_widths.py fastst-hotkey.asm
	xvfb-run -a python3 tests/regress_scrollback_input.py ./fastst
	xvfb-run -a python3 tests/regress_altscreen_restore.py ./fastst
	xvfb-run -a python3 tests/regress_vim_exit.py ./fastst
	python3 tests/regress_unicode_fallback.py ./fastst
	xvfb-run -a python3 tests/regress_escape_stress.py ./fastst

# More expensive end-to-end server tests; needs XTest (libXtst).
check-server: $(PROGRAMS)
	xvfb-run -a python3 tests/regress_preconnected.py ./fastst ./fastst-launch
	xvfb-run -a python3 tests/regress_hotkey.py ./fastst ./fastst-hotkey

clean:
	rm -f $(PROGRAMS) fastst.o fastst-launch.o fastst-hotkey.o

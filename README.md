# fastst — fast x86-64/X11 terminal in assembly

A compact Linux terminal emulator written in FASM-style x86-64 assembly, with
X11/Xft rendering, PTY-backed shell sessions, UTF-8, ANSI sequences, alternate
screen, and ring-buffer scrollback. The design is informed by suckless st but
is not a byte-for-byte translation or a complete xterm-compatible terminal.

## Build and install (Arch Linux)

```sh
sudo pacman -S --needed fasm gcc binutils libx11 libxft
make -j"$(nproc)"
sudo make install                  # installs to /usr/local/bin
```

`make` builds exactly three executables:

| Program | Purpose |
| --- | --- |
| `fastst` | Standalone terminal and optional preconnected X11 server |
| `fastst-launch` | Small static launcher for the preconnected server |
| `fastst-hotkey` | Resident Ctrl+Alt+Return shortcut listener |

There are no prebuilt benchmark or compatibility binaries in the default build.

### Install options

```sh
sudo make PREFIX=/usr install       # installs to /usr/bin
make PREFIX="$HOME/.local" install # no root required
sudo make uninstall                 # removes just the three executables
make clean                          # deletes generated binaries and objects
```

`PREFIX` defaults to `/usr/local`, and `BINDIR` defaults to `$(PREFIX)/bin`.
`DESTDIR` is supported for distro packaging, e.g.:

```sh
make DESTDIR=/tmp/package-root PREFIX=/usr install
```

`uninstall` must use the same `PREFIX`/`DESTDIR` as `install`.

## Running

You can use the terminal without any background process:

```sh
fastst
fastst -e htop
```

For the fast preconnected path, start the server **once** in your X11 session:

```sh
fastst --server >/dev/null 2>&1 &
fastst-launch
fastst-launch -e htop
fastst-hotkey &               # optional; grabs Ctrl+Return
```

To start automatically with `startx`, add `fastst --server &` and, optionally,
`fastst-hotkey &` before the window-manager `exec` in `~/.xinitrc`.
The resident shortcut must not conflict with a shortcut already used by your
window manager. `fastst-launch` forwards your launch-time arguments, cwd and
environment; the hotkey uses the server's original environment and cwd.

The very low first-frame benchmark numbers require **a prestarted server and
hotkey**. They do not describe standalone cold startup or physical monitor
presentation. The actual shell prompt takes longer than the first X11 frame.

## Tests (optional)

The normal build and install do **not** build or run tests. On Arch, install
the optional test dependencies:

```sh
sudo pacman -S --needed python xorg-server-xvfb xorg-xwininfo vim libxtst
make check          # terminal, Unicode, Vim, scrollback, escape stress
make check-server   # launcher/server and hotkey end-to-end tests
```

Test scripts are in `tests/`. They rely on a running virtual X11 server and
are not required when using the installed terminal.

## Build details

FASM produces ELF64 objects, linked using the system GCC and GNU ld. The
launcher is static and uses no libc. The terminal uses libX11, Xft,
Fontconfig, and libutil. `fastst-hotkey` links libX11. The default terminal
link keeps the project's historical `-z noseparate-code` option to minimize
ELF size; no segment is both writable and executable.

`make fast-launch` and `make fast-hotkey` remain supported as aliases for
building their corresponding programs together with `fastst`.

Native FASM compilation cannot be independently checked in this build
environment. The Makefile, build dependencies, install/uninstall behavior and
Xvfb test suite have been checked with a GNU-as compatibility conversion of
the same assembly sources. Build with native FASM on Arch before installing.

## Known limitations

Not a full st/xterm replacement: resize reflow, full IME integration, complex
Unicode shaping, exact RGB truecolor, and some terminal escape protocols are
not implemented. Treat it as an experimental terminal and keep a fallback.

- [suckless st](https://st.suckless.org/)
- [st scrollback patch](https://st.suckless.org/patches/scrollback/)

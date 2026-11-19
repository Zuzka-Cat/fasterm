# fasterm

A small Linux x86-64 terminal written in FASM assembly. Uses X11/Xft, a PTY,
UTF-8, ANSI/256-color/24-bit RGB, scrollback, buffered paste, and an alternate screen.

## Build

Install FASM, GCC, libX11, Xft, Fontconfig and libutil (on Arch:
`sudo pacman -S fasm gcc libx11 libxft`). Then:

```sh
make -j"$(nproc)"
sudo make install             # defaults to /usr/local/bin
```

For a local install, use `make PREFIX="$HOME/.local" install`.
`make uninstall` removes the three installed executables.

## Run

```sh
fasterm                       # terminal window
fasterm -e btop               # launch a program
```

Optional preconnected mode (start the server once per X11 session):

```sh
fasterm --server &
fasterm-launch                # launch a new window
fasterm-hotkey &              # optional Ctrl+Return shortcut
```

The launcher forwards your environment, working directory and arguments.
Add the server and optional hotkey to `~/.xinitrc` before starting your WM.
Standalone mode needs neither background process.

## Test

```sh
make check                    # requires Python, Xvfb, xwininfo, Vim
make check-server             # also requires XTest
make clean
```

The normal build does not run tests. The launcher is static; the terminal
uses X11, Xft and Fontconfig. Screen cells remain 8 bytes. RGB colors retain
exact values for up to 3,840 distinct colors per session; after that, newly
encountered colors fall back to the xterm 256-color palette.

**Limitations:** experimental, not a complete xterm replacement. No complex
text shaping or full IME support, and not all escape sequences or resize
reflow behavior are implemented. Keep a fallback terminal available.

Public domain (see [UNLICENSE](UNLICENSE)).

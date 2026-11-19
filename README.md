# fasterm

A small Linux x86-64 terminal written in FASM assembly. Uses X11/Xft, a PTY,
UTF-8, ANSI/256-color/24-bit RGB, scrollback, buffered paste, and an alternate screen.

## Build and install

Install FASM, GCC, libX11, Xft, Fontconfig and libutil (on Arch:
`sudo pacman -S fasm gcc libx11 libxft`). Then:

```sh
make -j"$(nproc)"
sudo make install             # /usr/local/bin plus systemd user service units
```

For a local install without sudo, `make PREFIX="$HOME/.local" install` puts
user units in `~/.local/share/systemd/user`. Other prefixes can use a custom
`UNITDIR` that systemd searches. `make uninstall` removes all three
executables and both units (stop user services first).

## i3 + Ctrl+Alt+Return hotkey (recommended)

The **actual fasterm-hotkey binary** owns Ctrl+Alt+Return via an X11 passive
key grab. Do not bind that combination in i3 too. No shell-script supervisor,
PID file, or additional executable is needed: the two included systemd *user*
services supervise the already-existing binaries.

After `sudo make install`, put **one** startup line in `~/.config/i3/config`:

```i3
# Import i3's X11 authentication/display and restart both services.
# exec_always is safe here: systemd prevents duplicate instances.
exec_always --no-startup-id sh -c 'systemctl --user import-environment DISPLAY XAUTHORITY && systemctl --user restart fasterm-server.service fasterm-hotkey.service'
```

Optional: `$mod+Return` can additionally use the tiny launcher (but does not
replace the dedicated hotkey daemon):

```i3
bindsym $mod+Return exec --no-startup-id /usr/local/bin/fasterm-launch
```

Delete any older `exec fasterm --server`, `exec fasterm-hotkey` and
`bindsym Ctrl+Mod1+Return` lines from i3 or `.xinitrc` so they don't fight
the supervised processes. For the initial switch from unsupervised processes:

```sh
make takeover                # safely stop old server + old hotkey and start units
```

`fasterm --stop-server` uses Unix `SO_PEERCRED` to signal **only** the server
that owns the socket, even when that server is an older build. Don't use
`pkill fasterm`: that can close live terminals!

After editing i3 config, `i3-msg restart` also activates the startup line.
You can start/restart the services without restarting i3 with `make restart`.

### Day-to-day development

Inside the fasterm source directory:

```sh
make update             # build, sudo install, adopt old processes, restart services
# OR, if you prefer the two explicit steps:
make -j"$(nproc)" && sudo make install
make restart            # run as your desktop user, not under sudo
```

`make dev` is an alias for `make update`. **Do not** run `sudo make update`
or `sudo make restart`: these issue `systemctl --user` commands for the user
running them. `make update` already handles migration automatically, so you
can skip `make takeover` when using `make update` from the start. Restarting the fasterm server does not close existing terminal
windows because the server systemd unit has `KillMode=process`; newly launched
windows use the newly installed binary. The hotkey restarts after the server
and refreshes its preconnected worker socket.

Debugging:

```sh
systemctl --user status fasterm-server fasterm-hotkey
journalctl --user -u fasterm-server -u fasterm-hotkey -n 50 --no-pager
```

The Makefile also supports `make start`, `make stop`, `make status` and
`make logs`. `systemctl --user restart fasterm-server fasterm-hotkey` can be
used directly. This setup assumes your i3 X11 session has an active systemd
user manager.

## Run without services

```sh
fasterm                       # independent terminal window
fasterm -e btop               # launch a program
fasterm --server &            # optional, manual server
fasterm-launch                # fast client of that server
fasterm-hotkey &              # Ctrl+Alt+Return daemon
```

Ctrl+Left and Ctrl+Right send standard xterm word-navigation key sequences
(`CSI 1;5D` and `CSI 1;5C`). Shift/Alt/Ctrl combinations of the
arrow keys use the corresponding xterm modifier sequences. Actual word
movement is handled by the shell or application running in the terminal.

### Rendering fidelity

SGR 1 / 3 / 1+3 now use actual bold, italic and bold-italic Xft faces, not
just brighter palette entries. The faces load lazily so the first window's
normal-font startup cost does not change. SGR 22 and 23 return to normal
weight and slant independently.

Unicode block/quadrant characters (U+2580..U+259F, excluding dither shades)
are filled to exact fractional cell boundaries, including two-color image
previews constructed from half-blocks. Common box-drawing strokes and rounded
corners connect all the way to the next cell without 1-pixel gaps. Special
dashed and diagonal borders continue to use the original font glyphs.

`make check` includes `regress_cell_geometry.py`, an Xvfb pixel regression
for these rendering cases. Open terminals keep their old renderer until they
are closed; `make update` restarts the server and dedicated hotkey for new
windows without closing existing terminals.

The launcher forwards your environment, working directory and arguments.
The hotkey uses the server's environment and cwd.

## Test

```sh
make check                    # requires Python, Xvfb, xwininfo, Vim
make check-server             # also requires XTest
make check-services           # no display or systemd user session needed
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

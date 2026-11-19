# fasterm

A tiny x86-64 Linux terminal written in fasm assembly ^w^.
Uses X11/Xft with PTY support, UTF-8, ANSI and truecolor, scrollback, buffered paste, and an alternate screen.

## Build

Requires FASM 1.73, GCC, X11, Xft, Fontconfig, and libutil.
On Arch Linux, build and install with:

```sh
sudo pacman -S fasm gcc libx11 libxft libxrender libxrandr
make
sudo make install
```

## i3 setup

`fasterm-hotkey` handles launching fasterm directly through X11 with `Ctrl+Alt+Return`. No i3 keybinding is needed.
Add this to `~/.config/i3/config`:

```i3
exec_always --no-startup-id sh -c 'systemctl --user import-environment DISPLAY XAUTHORITY && systemctl --user restart fasterm-server.service fasterm-hotkey.service'
```

if you do not want to use fasterm-hotkey, you can use this below but it'll be slower to launch:

```i3
bindsym $mod+Return exec --no-startup-id /usr/local/bin/fasterm-launch
```

For an existing installation with manually started processes, run:

```sh
make takeover
i3-msg restart
```

## Usage without i3 or systemd

```sh
fasterm                  # open a terminal
fasterm -e btop          # run a program
fasterm --server &       # start the server
fasterm-launch           # open through the server
fasterm-hotkey &         # enable Ctrl+Alt+Return
```

## Development

Build, install, and restart everything with:

```sh
make update
```

Run make as your normal user, not with `sudo`. `make update` handles installation privileges itself.
Restarting the server does not close existing terminal windows. New windows use the updated binary.
Avoid `pkill fasterm`, which can close active terminal windows. Use `fasterm --stop-server` to stop a manually running server.

### Rendering

Supports bold, italic, and bold-italic fonts, 256-color and 24-bit RGB output, and cell-aligned block and box-drawing characters.
RGB values are preserved for up to 3,840 distinct colors per session. Additional colors fall back to the xterm 256-color palette.
Modifier combinations for arrow keys use standard xterm escape sequences, including `Ctrl+Left` and `Ctrl+Right` for word navigation where supported by the shell or application.

## Tests

```sh
make check             # FASM/XRandR layout checks, Python, Xvfb, Vim
make check-server      # also requires XTest
make check-services    # no X11 session required
make clean
```

Public domain. See [UNLICENSE](UNLICENSE).

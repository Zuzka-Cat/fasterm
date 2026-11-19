# FASM 1.73 source readability refactor — handoff

## Scope

Refactored `fasterm.asm`, `fasterm-launch.asm`, and `fasterm-hotkey.asm` with shared native FASM 1.x include files:

- `include/protocol.inc`: named request-header, `sockaddr_un`, and protocol constants, with assembler-time layout checks.
- `include/sysv64.inc`: shared System V AMD64 C-call alignment helper and Linux/GLIBC structure offsets.
- `include/x11.inc`: LP64 X11/Xft/XRender event/record field names and key constants.
- `include/cell.inc`: 8-byte terminal-cell structure and style flag constants.

`Makefile` now tracks includes as object dependencies. `README.md` explains the include layout and 64-bit ABI choices. The intent is clearer references to fixed data layouts, with the same fundamental instruction and control-flow patterns.

## Verification status

**Not built or executed.** Per request, no assembler, linker, downloads, runtime tests, or binary comparisons were performed. Changes were reviewed statically only. ABI offset and macro syntax compatibility must be confirmed by building with classic FASM 1.73 on Linux.

From the project root, run:

```sh
make clean && make FASM=fasm
make check
```

If investigating binary equivalence, compare a freshly assembled baseline against the refactor; the original executables in the supplied archive are **not** evidence of refactored build success. Validate ABI calling, stack alignment, X11 events, scrollback, and client/server packet handling.

## Deferred

- Avoided blanket conversion to 32-bit `proc`/`invoke`/`stdcall`/`cinvoke`: this is ELF64 and uses the System V AMD64 ABI.
- Kept low-level stack-argument calls, hardware-visible instruction ordering, and sensitive branch structure explicit rather than concealing them in new macros.
- No algorithm changes or fixes to pre-existing behavior have been attempted.

## Distribution

This source package intentionally excludes pre-existing linked executables and object files to prevent confusing old binaries with tested results.

# fasterm — cmatrix stress profile optimization

Source input: the provided `perf.data` recording, with `fasterm` running a
fast-changing `cmatrix`. This is an **on-CPU profile**, not a GPU performance
counter recording. The capture contains **both** processes.

The container running this analysis has no `perf(1)` executable, and the
provided capture does not include the matching `/usr/local/bin/fasterm`
executable. I decoded the standard `PERFILE2` mmap, comm and IP/TID/time/period
sample records directly. This recovers sampled DSOs and instruction offsets,
but cannot reliably recover the FASM *function names* of a stripped ELF. Do
not interpret the offsets below as named FASM functions.

## Measured baseline

| Process | Samples | Share of recording |
|---|---:|---:|
| cmatrix | 23,501 | 71.06% |
| fasterm | 9,572 | 28.94% |

Within the 9,572 fasterm-process samples:

| DSO | Samples | Share of fasterm samples |
|---|---:|---:|
| fasterm | 4,809 | 50.24% |
| libXft | 1,781 | 18.61% |
| libc | 1,087 | 11.36% |
| libX11 | 650 | 6.79% |
| libXrender | 352 | 3.68% |
| [unknown] | 722 | 7.54% |
| other | 171 | 1.79% |

### Top five sampled fasterm *instruction locations*

| Relative address | Samples | Share of fasterm samples |
|---|---:|---:|
| `fasterm+0x4a2d` | 649 | 6.78% |
| `fasterm+0x482f` | 300 | 3.13% |
| `fasterm+0x4a20` | 213 | 2.23% |
| `fasterm+0x4582` | 180 | 1.88% |
| `fasterm+0x4610` | 168 | 1.76% |

`fasterm+0x4a20` and `fasterm+0x4a2d` are adjacent and likely part of the
same basic-block cluster, but the matching ELF is needed to prove the function
identity. Raw samples have an embedded period; percentages here use sample
counts, as reported in the table.

## Changes made in FASM

1. `feed_bytes`: add an eight-ASCII-cell SSE4.1 vector writer. If the bytes,
   parser state or remaining width do not qualify, retain the existing
   four-cell SSE4.1 and per-byte fallback paths. No AVX2 hardware assumption.
2. `render`: compare dirty candidate rows to a retained snapshot with SSE4.1
   `PTEST`; skip unchanged rows entirely, and skip presentation when there
   is no actual pixel work.
3. `render`: restrict background, Xft glyph runs, and underline rendering to
   changed horizontal spans, with a one-cell overhang halo; batch adjacent
   XRender rectangles when the spans coincide.
4. `check_cursor`: do not force an entire row repaint on cursor movement when
   the cursor is hidden (common in animation workloads). Force the previous
   and current row when the cursor actually is visible.
5. `Present`: send a single XFixes update region covering changed cell spans
   and clipped borders so a compositing/copy path can copy less pixel data.
   Entire-window invalidations request a full update. XFixes is loaded
   dynamically; if unavailable, the existing vblank-aware full-area Present
   remains the fallback. Never reintroduce unsynchronized `XCopyArea`.

## Build and validation

Pure FASM source: no C code added to the terminal, and no new required shared
library. All XFixes symbols are resolved at runtime only when supported.

Static/source checks run here:

- `python3 tests/check_damage_regions.py` — 20,000 randomized damage spans and
  5,000 merged-region cases
- `python3 tests/check_fasm_widths.py fasterm.asm`
- `python3 tests/check_present_fasm.py`
- `python3 tests/check_xrandr_layout.py`
- `python3 tests/check_services.py`

**Important:** FASM is unavailable in this environment, so the changed source
has not been assembled, graphically tested or benchmarked here. Consequently
there is **no measured before/after CPU or GPU reduction** and no basis for a
"fastest terminal" claim. For a reproducible comparison on the same Xorg
monitor, build the source then use `perf stat`, `perf record`, `perf report`
and GPU monitoring on the same cmatrix settings and screen geometry. A matching
unstripped executable will be needed to map the hotspot offsets to labels.

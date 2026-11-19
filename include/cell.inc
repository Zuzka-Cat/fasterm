; Terminal cell's fixed ABI and packed rendition word.
; The eight-byte stride is used directly by ring-buffer addressing and SSE.

struc terminal_cell {
  .codepoint rd 1
  .style     rd 1
}
virtual at 0
  Cell terminal_cell
  CELL_BYTES = $
end virtual

STYLE_INDEX_BITS = 12
STYLE_INDEX_MASK = 0fffh
STYLE_BG_SHIFT = 12
STYLE_BG_MASK = 0fff000h
STYLE_BOLD = 01000000h
STYLE_INVERSE = 02000000h
STYLE_UNDERLINE = 04000000h
STYLE_WIDE_TRAIL = 08000000h
STYLE_ITALIC = 10000000h
STYLE_FONT_MASK = STYLE_BOLD or STYLE_ITALIC
STYLE_DEFAULT = 7             ; default foreground palette entry
PALETTE_RGB_FIRST = 256       ; xterm palette occupies indices 0..255
PALETTE_CAP = 1 shl STYLE_INDEX_BITS

if Cell.style <> 4 | CELL_BYTES <> 8
  display 'terminal cell ABI changed',13,10
  err
end if

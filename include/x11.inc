; Xlib/Xft ABI offsets for LP64 Linux. No output bytes are generated here.
; XEvent is a union; each event view intentionally starts at offset zero.
; C longs and pointers are 8 bytes, while C ints are 4 bytes on x86-64.

KeyPress = 2
ButtonPress = 4
ButtonRelease = 5
MotionNotify = 6
Expose = 12
DestroyNotify = 17
ConfigureNotify = 22
SelectionRequest = 30
SelectionNotify = 31
ClientMessage = 33
KeyPressMask = 1
ButtonPressMask = 4
ButtonReleaseMask = 8
PointerMotionMask = 64
ExposureMask = 32768
StructureNotifyMask = 131072
ShiftMask = 1
LockMask = 2
Mod2Mask = 16                 ; conventionally NumLock, depends on X mapping
ControlMask = 4
Mod1Mask = 8
Button1Mask = 256

; These two event types have the same starting coordinates and modifier state,
; but the detail word names different fields (keycode vs mouse button).
struc x_key_event {
  rb 56
  .time        rq 1
  .x           rd 1
  .y           rd 1
  .x_root      rd 1
  .y_root      rd 1
  .state       rd 1
  .keycode     rd 1
  .same_screen rd 1
  rb 4
}
virtual at 0
  XKey x_key_event
end virtual

struc x_button_event {
  rb 56
  .time        rq 1
  .x           rd 1
  .y           rd 1
  .x_root      rd 1
  .y_root      rd 1
  .state       rd 1
  .button      rd 1
  .same_screen rd 1
  rb 4
}
virtual at 0
  XButton x_button_event
end virtual

struc x_motion_event {
  rb 64
  .x           rd 1
  .y           rd 1
  .x_root      rd 1
  .y_root      rd 1
  .state       rd 1
}
virtual at 0
  XMotion x_motion_event
end virtual

struc x_configure_event {
  rb 56
  .width  rd 1
  .height rd 1
}
virtual at 0
  XConfigure x_configure_event
end virtual

struc x_client_message {
  rb 56
  .data_l0 rq 1           ; first 64-bit XClientMessageEvent.data.l
}
virtual at 0
  XClientMessage x_client_message
end virtual

struc x_selection_request {
  rb 40
  .requestor rq 1
  .selection rq 1
  .target    rq 1
  .property  rq 1
  .time      rq 1
}
virtual at 0
  XSelectionRequest x_selection_request
end virtual

struc x_selection_notify {
  rb 24
  .display   rq 1
  .requestor rq 1
  .selection rq 1
  .target    rq 1
  .property  rq 1
  .time      rq 1
}
virtual at 0
  XSelectionNotify x_selection_notify
end virtual

; Xlib's XEvent union is 192 bytes on the project target.
XEVENT_BYTES = 192

struc x_glyph_info {
  .width  rw 1
  .height rw 1
  .x      rw 1
  .y      rw 1
  .xOff   rw 1
  .yOff   rw 1
}
virtual at 0
  XGlyphInfo x_glyph_info
  XGLYPHINFO_BYTES = $
end virtual

struc x_rectangle {
  .x      rw 1
  .y      rw 1
  .width  rw 1
  .height rw 1
}
virtual at 0
  XRectangle x_rectangle
  XRECTANGLE_BYTES = $
end virtual

struc x_render_color {
  .red   rw 1
  .green rw 1
  .blue  rw 1
  .alpha rw 1
}
virtual at 0
  XRenderColor x_render_color
  XRENDERCOLOR_BYTES = $
end virtual

; XftColor is {unsigned long pixel, XRenderColor color} on LP64.
struc xft_color {
  .pixel rq 1
  .color rb XRENDERCOLOR_BYTES
}
virtual at 0
  XftColor xft_color
  XFTCOLOR_BYTES = $
end virtual

struc xft_font_header {
  .ascent            rd 1
  .descent           rd 1
  .height            rd 1
  .max_advance_width rd 1
}
virtual at 0
  XftFont xft_font_header
end virtual

if XKey.time <> 56 | XKey.state <> 80 | XButton.button <> 84
  display 'Xlib input event ABI layout changed',13,10
  err
end if
if XConfigure.width <> 56 | XMotion.x <> 64 | XClientMessage.data_l0 <> 56
  display 'Xlib event union layout changed',13,10
  err
end if
if XSelectionRequest.time <> 72 | XSelectionNotify.property <> 56
  display 'Xlib selection event ABI layout changed',13,10
  err
end if
if XGLYPHINFO_BYTES <> 12 | XRECTANGLE_BYTES <> 8 | XRENDERCOLOR_BYTES <> 8 | XFTCOLOR_BYTES <> 16
  display 'Xft/Xrender geometry ABI layout changed',13,10
  err
end if

; X11 KeySyms used by the keyboard handler (stable X11 protocol values).
XK_BackSpace = 0ff08h
XK_Tab = 0ff09h
XK_Return = 0ff0dh
XK_Escape = 0ff1bh
XK_Home = 0ff50h
XK_Left = 0ff51h
XK_Up = 0ff52h
XK_Right = 0ff53h
XK_Down = 0ff54h
XK_Page_Up = 0ff55h
XK_Page_Down = 0ff56h
XK_End = 0ff57h
XK_Insert = 0ff63h
XK_Delete = 0ffffh

; XRandR 1.2 LP64 public ABI (X11/extensions/Xrandr.h).
; Layouts follow include/x11.inc: FASM struc + virtual gives typed offsets
; without emitting data or requiring C headers/a C compilation unit.

RRScreenChangeNotifyMask = 1
RRCrtcChangeNotifyMask = 2
RROutputChangeNotifyMask = 4
RR_Interlace = 10h
RR_DoubleScan = 20h
XRR_CRTC_CAP = 32

struc xrr_mode_info {
  .id          rq 1                ; RRMode / unsigned long
  .width       rd 1
  .height      rd 1
  .dotClock    rq 1                ; unsigned long
  .hSyncStart  rd 1
  .hSyncEnd    rd 1
  .hTotal      rd 1
  .hSkew       rd 1
  .vSyncStart  rd 1
  .vSyncEnd    rd 1
  .vTotal      rd 1
  rb 4                             ; align pointer to 8 bytes
  .name        rq 1
  .nameLength  rd 1
  rb 4
  .modeFlags   rq 1
}
virtual at 0
  XRRModeInfo xrr_mode_info
  XRR_MODE_BYTES = $
end virtual

struc xrr_screen_resources {
  .timestamp        rq 1
  .configTimestamp  rq 1
  .ncrtc            rd 1
  rb 4
  .crtcs            rq 1
  .noutput          rd 1
  rb 4
  .outputs          rq 1
  .nmode            rd 1
  rb 4
  .modes            rq 1
}
virtual at 0
  XRRScreenResources xrr_screen_resources
  XRR_RES_BYTES = $
end virtual

struc xrr_crtc_info {
  .timestamp  rq 1
  .x          rd 1
  .y          rd 1
  .width      rd 1
  .height     rd 1
  .mode       rq 1
  .rotation   rw 1
  rb 2
  .noutput    rd 1
  .outputs    rq 1
  .rotations  rw 1
  rb 2
  .npossible  rd 1
  .possible   rq 1
}
virtual at 0
  XRRCrtcInfo xrr_crtc_info
  XRR_CRTC_BYTES = $
end virtual

; One compact, 32-byte cache entry: unsigned extents, signed position,
; integer nanosecond period. 32-byte stride avoids multiplication in scan.
struc xrr_cache_entry {
  .x      rd 1
  .y      rd 1
  .width  rd 1
  .height rd 1
  .period rq 1
  .unused rq 1
}
virtual at 0
  XRRCachedCrtc xrr_cache_entry
  XRR_CACHE_BYTES = $
end virtual

if XRR_MODE_BYTES <> 80 | XRRModeInfo.dotClock <> 16 | XRRModeInfo.vTotal <> 48 | XRRModeInfo.modeFlags <> 72
  display 'XRandR mode LP64 ABI mismatch',13,10
  err
end if
if XRR_RES_BYTES <> 64 | XRRScreenResources.crtcs <> 24 | XRRScreenResources.modes <> 56
  display 'XRandR screen resources LP64 ABI mismatch',13,10
  err
end if
if XRR_CRTC_BYTES <> 64 | XRRCrtcInfo.mode <> 24 | XRRCrtcInfo.outputs <> 40
  display 'XRandR CRTC LP64 ABI mismatch',13,10
  err
end if
if XRR_CACHE_BYTES <> 32 | XRRCachedCrtc.period <> 16
  display 'XRandR cache stride mismatch',13,10
  err
end if

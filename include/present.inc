; Xlib GenericEventCookie and XPresentIdleNotifyEvent LP64 ABI.
; The XPresent API is loaded at runtime. Nothing here uses C source.
GenericEvent = 35
PresentIdleNotify = 2
PresentIdleNotifyMask = 4
PresentOptionCopy = 2

struc x_generic_event_cookie {
  .type       rd 1
  rb 4
  .serial     rq 1
  .send_event rd 1
  rb 4
  .display    rq 1
  .extension  rd 1
  .evtype     rd 1
  .cookie     rd 1
  rb 4
  .data       rq 1
}
virtual at 0
  XGenericCookie x_generic_event_cookie
  XGENERICCOOKIE_BYTES = $
end virtual

struc x_present_idle_notify {
  .type         rd 1
  rb 4
  .serial       rq 1
  .send_event   rd 1
  rb 4
  .display      rq 1
  .extension    rd 1
  .evtype       rd 1
  .eid          rd 1
  rb 4
  .window       rq 1
  .serial_number rd 1
  rb 4
  .pixmap       rq 1
  .idle_fence   rq 1
}
virtual at 0
  XPresentIdle x_present_idle_notify
  XPRESENTIDLE_BYTES = $
end virtual

if XGenericCookie.extension <> 32 | XGenericCookie.evtype <> 36 | XGenericCookie.data <> 48 | XGENERICCOOKIE_BYTES <> 56
  display 'Generic event cookie LP64 ABI mismatch',13,10
  err
end if
if XPresentIdle.eid <> 40 | XPresentIdle.window <> 48 | XPresentIdle.serial_number <> 56 | XPresentIdle.pixmap <> 64 | XPRESENTIDLE_BYTES <> 80
  display 'XPresent IdleNotify LP64 ABI mismatch',13,10
  err
end if

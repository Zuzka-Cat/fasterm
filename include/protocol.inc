; Shared wire format for fasterm, fasterm-launch and fasterm-hotkey.
; Classic FASM 1.x: struc + virtual define offsets without emitting bytes.
; This is protocol v3: numeric values and packet layout are intentionally fixed.

PRELOAD_MAGIC   = 334d5246h       ; 'FRM3' in little endian
PRELOAD_PACKET  = 32768
PRELOAD_MAXARGS = 32
PRELOAD_MAXENVS = 255
PRELOAD_CWD_BYTES = 1024

AF_UNIX = 1
SOCK_CLOEXEC = 80000h
SOCK_SEQPACKET_CLOEXEC = 80005h
MSG_TRUNC = 20h
MSG_NOSIGNAL = 4000h

; Both the abstract-name length and the full sockaddr_un size are ABI
; contracts. The name starts after sa_family and the leading abstract NUL.
SOCKET_NAME_CAP = 96              ; snprintf size, including the final NUL
struc abstract_sockaddr {
  .family       rw 1
  .leading_nul  rb 1
  .name         rb 107
}
virtual at 0
  SocketAddr abstract_sockaddr
  SOCKET_ADDR_BYTES = $
end virtual

; 16-byte wire header. A normal request then carries a fixed-size cwd field
; followed by NUL-separated arguments and environment strings. The instant
; hotkey request stops after the 16-byte header, with envc = -1.
struc preload_request {
  .magic    rd 1
  .argc     rd 1
  .envc     rd 1
  .length   rd 1
  .cwd      rb PRELOAD_CWD_BYTES
}
virtual at 0
  Request preload_request
  PRELOAD_FIXED_BYTES = $
end virtual
PRELOAD_HEADER_BYTES = Request.cwd

if SOCKET_ADDR_BYTES <> 110 | SocketAddr.name <> 3
  display 'Linux sockaddr_un layout changed',13,10
  err
end if
if PRELOAD_HEADER_BYTES <> 16 | PRELOAD_FIXED_BYTES <> 1040
  display 'preconnected request ABI changed',13,10
  err
end if

; Linux x86-64 and System V ABI definitions used by libc and the PTY.
; These are FASM 1.x structure macros, not the 32-bit PROC32.INC macros.

; Align RSP for direct System V calls whose arguments are already in registers.
; Restores caller's RSP and RBP exactly; flags/volatile registers are not kept.
; Calls requiring stack arguments still use the explicit outgoing stack block.
macro ccall function {
  push rbp
  mov rbp,rsp
  and rsp,-16
  call function
  mov rsp,rbp
  pop rbp
}

POLLIN  = 1
POLLOUT = 4
POLLERR = 8
POLLHUP = 16
POLLNVAL = 32

struc poll_fd {
  .fd       rd 1
  .events   rw 1
  .revents  rw 1
}
virtual at 0
  PollFd poll_fd
  POLLFD_BYTES = $
end virtual

struc terminal_winsize {
  .rows    rw 1
  .cols    rw 1
  .xpixels rw 1
  .ypixels rw 1
}
virtual at 0
  WinSize terminal_winsize
  WINSIZE_BYTES = $
end virtual

; Linux SO_PEERCRED returns pid_t, uid_t, gid_t (all 32-bit).
struc unix_credentials {
  .pid rd 1
  .uid rd 1
  .gid rd 1
}
virtual at 0
  UCred unix_credentials
  UCRED_BYTES = $
end virtual

; glibc x86-64 struct passwd (NSS getpwuid return value).
struc glibc_passwd {
  .name    rq 1
  .passwd  rq 1
  .uid     rd 1
  .gid     rd 1
  .gecos   rq 1
  .dir     rq 1
  .shell   rq 1
}
virtual at 0
  Passwd glibc_passwd
end virtual

if POLLFD_BYTES <> 8 | WINSIZE_BYTES <> 8 | UCRED_BYTES <> 12 | Passwd.shell <> 40
  display 'Linux x86-64 ABI layout changed',13,10
  err
end if

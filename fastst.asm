; fastst -- a compact x86-64 terminal emulator for Linux/X11, Flat Assembler syntax.
; Inspired by st's terminal/pty/X11 architecture; independently implemented.
; Build: fasm fastst.asm fastst.o && gcc -no-pie -Wl,-z,relro -s -o fastst fastst.o -lX11 -l:libXft.so.2 -lutil
;
; Deliberate hot-path design:
;   8 bytes/cell, 256-cell stride, 2048-line ring, O(1) full-screen scroll.
;   SSE4.1 ASCII writer, dirty-row drawing, nonblocking PTY batching.
;
format ELF64
public main
extrn XOpenDisplay
extrn XDefaultScreen
extrn XRootWindow
extrn XDefaultVisual
extrn XDefaultColormap
extrn XCreateSimpleWindow
extrn XSelectInput
extrn XMapWindow
extrn XCreateGC
extrn XSetForeground
extrn XFillRectangle
extrn XDrawLine
extrn XStoreName
extrn XInternAtom
extrn XSetWMProtocols
extrn XNextEvent
extrn XPending
extrn XConnectionNumber
extrn XLookupString
extrn XFlush
extrn XSync
extrn XDestroyWindow
extrn XftFontOpenName
extrn pthread_create
extrn pthread_join
extrn FcInit
extrn socket
extrn bind
extrn listen
extrn connect
extrn accept4
extrn getsockopt
extrn send
extrn recv
extrn pipe2
extrn fork
extrn signal
extrn getuid
extrn geteuid
extrn snprintf
extrn getcwd
extrn chdir
extrn strnlen
extrn environ
extrn prctl
extrn XftFontClose
extrn XftDrawCreate
extrn XftDrawDestroy
extrn XftCharExists
extrn XftDrawString32
extrn XftColorAllocValue
extrn XftDrawRect
extrn XSetSelectionOwner
extrn XConvertSelection
extrn XGetWindowProperty
extrn XChangeProperty
extrn XSendEvent
extrn XFree
extrn forkpty
extrn execvp
extrn getenv
extrn setenv
extrn setlocale
extrn ioctl
extrn fcntl
extrn read
extrn write
extrn poll
extrn close
extrn _exit
extrn strcmp
extrn strlen
extrn memcpy
extrn memset
extrn wcwidth
extrn waitpid
extrn malloc
extrn free
extrn fprintf
extrn stderr
extrn usleep

; ABI-safe compact call wrapper: preserve RBP, maintain 16-byte stack alignment.
; This is shorter and avoids the extra 16-byte temporary stack allocation.
macro ccall function {
  push rbp
  mov rbp,rsp
  and rsp,-16
  call function
  mov rsp,rbp
  pop rbp
}

; All screen cells are {uint32 codepoint, uint32 style}.
MAXCOL = 256
MAXROW = 128
RBITS  = 11
RING   = 2048
RMASK  = RING-1
ROWB   = 2048             ; MAXCOL*8
CLIPCAP = 131584          ; X11 selection transfer bound; avoid XChangeProperty BadLength
PAD    = 3
POLLIN  = 1
O_NONBLOCK = 2048
F_GETFL = 3
F_SETFL = 4
TIOCSWINSZ = 5414h
; Optional preconnected launch service: Linux abstract AF_UNIX, AF_UNIX=1.
SOCK_SEQPACKET_CLOEXEC = 80005h
SOCK_CLOEXEC = 80000h
SOL_SOCKET = 1
SO_PEERCRED = 17
MSG_WAITALL = 100h
MSG_NOSIGNAL = 4000h
SIGCHLD = 17
SIGTERM = 15
PR_SET_PDEATHSIG = 1
PRELOAD_MAGIC = 33545346h     ; 'FST3', seqpacket protocol v3
PRELOAD_PACKET = 32768
PRELOAD_MAXARGS = 32

; X11 event types and masks
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
ControlMask = 4
Mod1Mask = 8

section '.text' executable

main:
  push rbp
  mov rbp,rsp
  mov [cmd_argc],edi
  mov [cmd_argv],rsi
  cmp edi,2
  jl .normal_start
  mov rdi,[rsi+8]
  lea rsi,[opt_server]
  ccall strcmp
  test eax,eax
  jnz .not_server
  call preload_server
  xor eax,eax
  leave
  ret
.not_server:
  mov rax,[cmd_argv]
  mov rdi,[rax+8]
  lea rsi,[opt_client]
  ccall strcmp
  test eax,eax
  jnz .normal_start
  call preload_client
  xor eax,eax
  leave
  ret
.normal_start:
  ; Initialize locale for wchar width only; visual rendering is UTF-32/Xft.
  xor edi,edi
  lea rsi,[locale_utf8]
  ccall setlocale
  test rax,rax
  jnz .locale_ok
  xor edi,edi
  lea rsi,[empty]
  ccall setlocale
.locale_ok:
  ; Start Fontconfig matching before the blocking X11 connection handshake.
  ; The worker calls only Fontconfig; all Xlib/Xft display operations stay
  ; in the main thread (no XInitThreads needed).
  lea rdi,[font_worker_tid]
  xor esi,esi
  lea rdx,[font_match_worker]
  xor ecx,ecx
  ccall pthread_create
  mov [font_worker_status],eax

  xor edi,edi
  ccall XOpenDisplay
  test rax,rax
  jnz .display_ok
  lea rdi,[error_x]
  call fatal
.display_ok:
  mov [dpy],rax
  mov rdi,rax
  ccall XDefaultScreen
  mov [screen],eax
  mov rdi,[dpy]
  mov esi,[screen]
  ccall XRootWindow
  mov [root],rax
  mov rdi,[dpy]
  mov esi,[screen]
  ccall XDefaultVisual
  mov [visual],rax
  mov rdi,[dpy]
  mov esi,[screen]
  ccall XDefaultColormap
  mov [cmap],rax

  ; Fontconfig initialization runs concurrently with the X handshake.
  ; Join before calling the unmodified XftFontOpenName path, preserving
  ; XftDefaultSubstitute's per-display settings (DPI, hinting, antialiasing).
  cmp dword [font_worker_status],0
  jne .font_slow
  mov rdi,[font_worker_tid]
  xor esi,esi
  ccall pthread_join
.font_slow:
  mov rdi,[dpy]
  mov esi,[screen]
  lea rdx,[font_spec]
  ccall XftFontOpenName
  test rax,rax
  jnz .font_ok
  lea rdi,[error_font]
  call fatal
.font_ok:
  mov [font],rax
  mov eax,[rax+12]             ; XftFont.max_advance_width
  test eax,eax
  jg .cw_ok
  mov eax,8
.cw_ok:
  mov [cell_w],eax
  mov rax,[font]
  mov ecx,[rax]                ; ascent
  mov [ascent],ecx
  add ecx,[rax+4]              ; descent
  add ecx,2
  mov [cell_h],ecx

  ; Default 80x24, actual dimensions via ConfigureNotify.
  mov dword [cols],80
  mov dword [rows],24
  mov eax,[cell_w]
  imul eax,80
  add eax,PAD*2
  mov [width],eax
  mov eax,[cell_h]
  imul eax,24
  add eax,PAD*2
  mov [height],eax

  ; A preconnected worker creates its unmapped window and all Xft/WM state
  ; before accepting a launch.  This moves window creation, resource IDs and
  ; X11 protocol round trips off the per-launch critical path.
  ; XCreateSimpleWindow(dpy, root, x,y,width,height,border,borderPixel,bgPixel)
  mov rdi,[dpy]
  mov rsi,[root]
  xor edx,edx
  xor ecx,ecx
  mov r8d,[width]
  mov r9d,[height]
  mov rax,rsp
  and rsp,-16
  sub rsp,48
  mov qword [rsp],0
  mov qword [rsp+8],0
  mov qword [rsp+16],0x101216 ; default black
  mov [rsp+40],rax
  call XCreateSimpleWindow
  mov rsp,[rsp+40]
  mov [win],rax

  mov rdi,[dpy]
  mov rsi,[win]
  mov edx,KeyPressMask+ButtonPressMask+ButtonReleaseMask+PointerMotionMask+ExposureMask+StructureNotifyMask
  ccall XSelectInput
  mov rdi,[dpy]
  mov rsi,[win]
  xor edx,edx
  xor ecx,ecx
  ccall XCreateGC
  mov [gc],rax

  mov rdi,[dpy]
  mov rsi,[win]
  mov rdx,[visual]
  mov rcx,[cmap]
  ccall XftDrawCreate
  mov [draw],rax

  ; WM_DELETE_WINDOW protocol
  mov rdi,[dpy]
  lea rsi,[wm_del_name]
  xor edx,edx
  ccall XInternAtom
  mov [wm_delete],rax
  mov [atom_one],rax
  mov rdi,[dpy]
  mov rsi,[win]
  lea rdx,[atom_one]
  mov ecx,1
  ccall XSetWMProtocols

  mov rdi,[dpy]
  lea rsi,[clipboard_name]
  xor edx,edx
  ccall XInternAtom
  mov [clipboard],rax
  mov rdi,[dpy]
  lea rsi,[utf8_name]
  xor edx,edx
  ccall XInternAtom
  mov [utf8_atom],rax
  mov rdi,[dpy]
  lea rsi,[paste_name]
  xor edx,edx
  ccall XInternAtom
  mov [paste_atom],rax
  mov rdi,[dpy]
  lea rsi,[targets_name]
  xor edx,edx
  ccall XInternAtom
  mov [targets_atom],rax

  ; Prepare first ANSI palette entries lazily (default fg/bg need these).
  mov edi,0
  call ensure_color
  mov edi,7
  call ensure_color
  mov edi,15
  call ensure_color
  mov dword [curattr],7
  mov dword [cursor_show],1
  mov dword [wrap_enable],1
  mov dword [bottom],23
  call invalidate_all

  mov rdi,[dpy]
  mov rsi,[win]
  lea rdx,[title]
  ccall XStoreName
  ; Workers precreate the unmapped X window and the *pty + child process*
  ; while idle.  The pty child accepts the launch request and then execs it;
  ; the X11 parent simply waits for one-byte handoff and maps the window.
  cmp byte [preload_worker],0
  je .activate_window
  mov rdi,[dpy]
  xor esi,esi
  ccall XSync
  ; Record the X fd before forking. The prepared child closes its duplicate.
  mov rdi,[dpy]
  ccall XConnectionNumber
  mov [xfd],eax
  lea rdi,[preload_ready_pipe]
  mov esi,SOCK_CLOEXEC
  ccall pipe2
  test eax,eax
  js .quit
  call spawn_shell
  cmp dword [ptyfd],0
  jl .quit
  ; Only the pre-forked PTY child needs the listener/refill pipe now.
  mov edi,[preload_ready_pipe+4]
  ccall close
  mov edi,[server_pipe+4]
  ccall close
  mov edi,[server_sock]
  ccall close
  mov edi,[preload_ready_pipe]
  lea rsi,[server_handoff]
  mov edx,1
  ccall read
  cmp eax,1
  jne .quit
  mov edi,[preload_ready_pipe]
  ccall close
  ; The terminal window must survive the supervisor's exit.
  mov edi,PR_SET_PDEATHSIG
  xor esi,esi
  ccall prctl
.activate_window:
  mov rdi,[dpy]
  mov rsi,[win]
  ccall XMapWindow

  cmp byte [preload_worker],0
  jne .pty_ready
  call spawn_shell
.pty_ready:
  cmp dword [ptyfd],0
  jl .quit
  mov edi,[ptyfd]
  mov esi,F_GETFL
  ccall fcntl
  or eax,O_NONBLOCK
  mov edx,eax
  mov edi,[ptyfd]
  mov esi,F_SETFL
  ccall fcntl

  mov rdi,[dpy]
  ccall XConnectionNumber
  mov [xfd],eax
  mov eax,[ptyfd]
  mov dword [pollfds],eax
  mov word [pollfds+4],POLLIN
  mov eax,[xfd]
  mov dword [pollfds+8],eax
  mov word [pollfds+12],POLLIN

.event_loop:
  call drain_x_events
  call check_cursor
  cmp byte [dirty_any],0
  je .no_draw
  call render
.no_draw:
  lea rdi,[pollfds]
  mov esi,2
  mov edx,-1
  ccall poll
  test eax,eax
  js .event_loop
  ; POLLIN can arrive together with POLLHUP; drain the data before exit.
  test word [pollfds+4],POLLIN
  jnz .read_pty
  test word [pollfds+6],8+16+32
  jnz .quit
  jmp .event_loop
.read_pty:
  ; Drain the PTY; limit to 4 chunks before handling X / drawing.
  mov ebx,4
.read_more:
  mov edi,[ptyfd]
  lea rsi,[iobuf]
  mov edx,32768
  ccall read
  test rax,rax
  jle .read_done
  mov rdi,rax
  lea rsi,[iobuf]
  call feed_bytes
  dec ebx
  jz .event_loop
  jmp .read_more
.read_done:
  test eax,eax
  jz .quit
  ; EAGAIN/EINTR may be retried, but Linux PTYs often return EIO
  ; on a dead child while POLLHUP is asserted.
  test word [pollfds+6],8+16+32
  jnz .quit
  jmp .event_loop
.quit:
  mov edi,[ptyfd]
  ccall close
  mov rdi,[dpy]
  mov rsi,[win]
  ccall XDestroyWindow
  xor eax,eax
  leave
  ret

fatal:
  ; rdi points to a zero-terminated diagnostic string.
  push rdi
  ccall strlen
  mov rdx,rax
  pop rsi
  mov edi,2
  ccall write
  mov edi,1
  ccall _exit

 ; Worker preinitializes the global Fontconfig configuration/cache.
; XftFontOpenName remains the authority for selecting the display font.
font_match_worker:
  ccall FcInit
  xor eax,eax
  ret


; ---------------- optional preconnected mode ----------------
; Service: fastst --server  (foreground; background with & or systemd user)
; Client:  fastst --client [-e command args...]
; Every worker creates its OWN Display/XftFont before accept().  No Xlib
; connection is used by more than one live process, even across fork().
; One reply/write from an accepted worker tells the supervisor to refill.
;
; Linux abstract Unix socket keyed by uid + DISPLAY.  This avoids filesystem
; races or stale socket paths; SO_PEERCRED rejects other users.
preload_socket_addr:
  mov word [server_addr],1
  lea rdi,[display_env]
  ccall getenv
  test rax,rax
  jnz .env_ok
  lea rax,[empty]
.env_ok:
  mov [tmp_display],rax
  ccall geteuid
  mov [server_uid],eax
  lea rdi,[server_addr+3]
  mov esi,96
  lea rdx,[sock_pattern]
  mov ecx,[server_uid]
  mov r8,[tmp_display]
  xor eax,eax
  ccall snprintf
  ; address length is always sizeof(sockaddr_un) to avoid ambiguous lengths
  ret

preload_open_socket:
  mov edi,1
  mov esi,SOCK_SEQPACKET_CLOEXEC
  xor edx,edx
  ccall socket
  ret

preload_client:
  call preload_socket_addr
  call preload_open_socket
  test eax,eax
  js .fail
  mov [server_sock],eax
  mov edi,eax
  lea rsi,[server_addr]
  mov edx,110
  ccall connect
  test eax,eax
  js .fail_socket
  ; Bounded variable-length request: header / cwd / NUL-separated argv.
  mov dword [request_buffer],PRELOAD_MAGIC
  mov rax,[cmd_argv]
  mov eax,[cmd_argc]
  sub eax,2
  cmp eax,PRELOAD_MAXARGS
  ja .fail_socket
  mov dword [request_buffer+4],eax
  lea rdi,[request_buffer+16]
  mov esi,1024
  ccall getcwd
  test rax,rax
  jz .fail_socket
.cwd_ok:
  lea r12,[request_buffer+1040]
  lea r13,[request_buffer+PRELOAD_PACKET]
  mov eax,dword [request_buffer+4]
  test eax,eax
  jz .copy_environment
  mov [server_remaining],eax
  mov rbx,[cmd_argv]
  add rbx,16
.copy_args:
  mov rdi,[rbx]
  mov r14,rdi
  ccall strlen
  inc rax
  lea rcx,[r12+rax]
  cmp rcx,r13
  ja .fail_socket
  mov rdi,r12
  mov rsi,r14
  mov rdx,rax
  ccall memcpy
  mov rdi,r14
  ccall strlen
  lea r12,[r12+rax+1]
  add rbx,8
  dec dword [server_remaining]
  jnz .copy_args
.copy_environment:
  ; Preserve the caller's exact exported environment, not the server's.
  ; The fixed-size packet rejects oversized environments rather than
  ; silently running the user's shell with incorrect settings.
  mov rbx,[environ]
  mov dword [request_buffer+8],0
.env_loop:
  mov rax,[rbx]
  test rax,rax
  jz .send
  cmp dword [request_buffer+8],255
  jae .fail_socket
  mov r14,rax
  mov rdi,rax
  ccall strlen
  lea r15,[rax+1]
  lea rcx,[r12+r15]
  cmp rcx,r13
  ja .fail_socket
  mov rdi,r12
  mov rsi,r14
  mov rdx,r15
  ccall memcpy
  add r12,r15
  add rbx,8
  inc dword [request_buffer+8]
  jmp .env_loop
.send:
  ; Send only the populated bytes (usually 2-8 KiB), not 32 KiB of zeros.
  lea rax,[request_buffer]
  mov r13,r12
  sub r13,rax
  mov dword [request_buffer+12],r13d
  mov r12,rax
.send_loop:
  mov edi,[server_sock]
  mov rsi,r12
  mov edx,r13d
  mov ecx,MSG_NOSIGNAL
  ccall send
  test eax,eax
  jle .fail_socket
  add r12,rax
  sub r13d,eax
  jnz .send_loop
  mov edi,[server_sock]
  ccall close
  ret
.fail_socket:
  mov edi,[server_sock]
  ccall close
.fail:
  lea rdi,[error_server]
  call fatal

preload_server:
  call preload_socket_addr
  call preload_open_socket
  test eax,eax
  js .fail
  mov [server_sock],eax
  mov edi,eax
  lea rsi,[server_addr]
  mov edx,110
  ccall bind
  test eax,eax
  js .fail
  mov edi,[server_sock]
  mov esi,32
  ccall listen
  test eax,eax
  js .fail
  lea rdi,[server_pipe]
  mov esi,SOCK_CLOEXEC
  ccall pipe2
  test eax,eax
  js .fail
  ; Parent auto-reaps terminal workers.  Workers restore SIGCHLD=default
  ; before launching any user shells, which must be able to waitpid().
  mov edi,SIGCHLD
  mov esi,1                     ; SIG_IGN
  ccall signal
  call preload_spawn_worker
  call preload_spawn_worker
.loop:
  mov eax,[server_pipe]
  mov dword [server_pollfd],eax
  mov word [server_pollfd+4],POLLIN
  lea rdi,[server_pollfd]
  mov esi,1
  mov edx,-1
  ccall poll
  test eax,eax
  jle .loop
  test word [server_pollfd+4],POLLIN
  jz .loop
  mov edi,[server_pipe]
  lea rsi,[server_events]
  mov edx,64
  ccall read
  test eax,eax
  jle .loop
  mov ebx,eax
.refill:
  cmp ebx,0
  jle .loop
  call preload_spawn_worker
  dec ebx
  jmp .refill
.fail:
  lea rdi,[error_bind]
  call fatal

preload_spawn_worker:
  ccall fork
  test eax,eax
  jz .worker
  ret
.worker:
  mov edi,[server_pipe]
  ccall close
  ; The idle workers die when server exits.  Once a terminal is accepted,
  ; clear the PDEATHSIG so active terminal windows remain independent.
  mov edi,PR_SET_PDEATHSIG
  mov esi,SIGTERM
  ccall prctl
  mov edi,SIGCHLD
  xor esi,esi                  ; SIG_DFL
  ccall signal
  mov byte [preload_worker],1
  mov edi,1
  lea rsi,[server_dummy_argv]
  call main
  xor edi,edi
  ccall _exit

preload_accept_request:
.wait:
  mov edi,[server_sock]
  xor esi,esi
  xor edx,edx
  mov ecx,SOCK_CLOEXEC
  ccall accept4
  test eax,eax
  js .wait
  mov [server_client_sock],eax
  ; Linux SO_PEERCRED: {pid_t pid, uid_t uid, gid_t gid}.
  mov dword [server_credlen],12
  mov edi,eax
  mov esi,SOL_SOCKET
  mov edx,SO_PEERCRED
  lea rcx,[server_creds]
  lea r8,[server_credlen]
  ccall getsockopt
  test eax,eax
  jnz .reject
  mov eax,dword [server_creds+4]
  cmp eax,[server_uid]
  jne .reject
  ; SOCK_SEQPACKET delivers the bounded request atomically in ONE recv.
  ; Linux MSG_TRUNC makes recv return the original size for oversized packets.
  mov edi,[server_client_sock]
  lea rsi,[request_buffer]
  mov edx,PRELOAD_PACKET
  mov ecx,20h                  ; MSG_TRUNC (Linux)
  ccall recv
  cmp eax,16
  jl .reject
  cmp eax,PRELOAD_PACKET
  jg .reject
  cmp dword [request_buffer],PRELOAD_MAGIC
  jne .reject
  cmp eax,dword [request_buffer+12]
  jne .reject
  ; 16-byte trigger: server's original shell, cwd and environment.
  ; No argument/environment serialization or cwd round trip on this path.
  cmp eax,16
  jne .full_request
  cmp dword [request_buffer+4],0
  jne .reject
  cmp dword [request_buffer+8],-1
  jne .reject
  mov dword [cmd_argc],1
  lea rax,[server_dummy_argv]
  mov [cmd_argv],rax
  jmp .accepted
.full_request:
  cmp eax,1040
  jl .reject
  mov r14d,dword [request_buffer+4]
  cmp r14d,PRELOAD_MAXARGS
  ja .reject
  ; Never search outside packet even if same-uid client sends bad input.
  lea rdi,[request_buffer+16]
  mov esi,1024
  ccall strnlen
  cmp eax,1024
  jae .reject
  mov [server_cwd_len],eax
  ; Validate all NUL-terminated args before accepting the request.
  lea r12,[request_buffer+1040]
  mov eax,dword [request_buffer+12]
  lea r13,[request_buffer]
  add r13,rax
  mov r15d,r14d
  lea rax,[server_executable]
  mov [server_argv],rax
  lea rbx,[server_argv+8]
.parse_args:
  test r15d,r15d
  jz .parse_done
  mov rax,r13
  sub rax,r12
  jz .reject
  mov rdi,r12
  mov rsi,rax
  ccall strnlen
  lea rcx,[r12+rax]
  cmp rcx,r13
  jae .reject
  mov [rbx],r12
  add rbx,8
  lea r12,[rcx+1]
  dec r15d
  jmp .parse_args
.parse_done:
  mov qword [rbx],0
  mov r15d,dword [request_buffer+8]
  cmp r15d,255
  ja .reject
  mov [server_env_count],r15d
  lea rbx,[server_env_argv]
.parse_env:
  test r15d,r15d
  jz .env_done
  mov rax,r13
  sub rax,r12
  jz .reject
  mov rdi,r12
  mov rsi,rax
  ccall strnlen
  lea rcx,[r12+rax]
  cmp rcx,r13
  jae .reject
  mov [rbx],r12
  add rbx,8
  lea r12,[rcx+1]
  dec r15d
  jmp .parse_env
.env_done:
  mov qword [rbx],0
  lea rdi,[request_buffer+16]
  cmp byte [rdi],0
  je .no_chdir
  ccall chdir
  test eax,eax
  jnz .reject
.no_chdir:
  cmp dword [server_env_count],0
  je .keep_env
  lea rax,[server_env_argv]
  mov [environ],rax
.keep_env:
  lea rax,[server_argv]
  mov [cmd_argv],rax
  lea eax,[r14+1]
  mov [cmd_argc],eax
.accepted:
  ; Unblock the X11 parent as soon as the request is validated. Cleanup,
  ; supervisor refill and exec can proceed concurrently with XMapWindow.
  mov edi,[preload_ready_pipe+4]
  lea rsi,[server_handoff]
  mov edx,1
  ccall write
  mov edi,[preload_ready_pipe+4]
  ccall close
  mov edi,[server_client_sock]
  ccall close
  ; Tell supervisor to refill immediately, leaving this worker's sole
  ; X11 connection untouched by any other process.
  mov edi,[server_pipe+4]
  lea rsi,[server_handoff]
  mov edx,1
  ccall write
  mov edi,[server_pipe+4]
  ccall close
  mov edi,[server_sock]
  ccall close
  mov edi,PR_SET_PDEATHSIG
  xor esi,esi
  ccall prctl
  ret
.reject:
  mov edi,[server_client_sock]
  ccall close
  jmp .wait

spawn_shell:
  mov word [winsize],24
  mov word [winsize+2],80
  mov word [winsize+4],0
  mov word [winsize+6],0
  lea rdi,[ptyfd]
  xor esi,esi
  xor edx,edx
  lea rcx,[winsize]
  ccall forkpty
  test eax,eax
  jz .child
  mov [childpid],eax
  ret
.child:
  cmp byte [preload_worker],0
  je .exec_child
  ; The idle child owns the listener; do not keep an unnecessary X11 fd.
  mov edi,[preload_ready_pipe]
  ccall close
  mov edi,[xfd]
  ccall close
  mov edi,PR_SET_PDEATHSIG
  mov esi,SIGTERM
  ccall prctl
  call preload_accept_request
.exec_child:
  lea rdi,[term_name]
  lea rsi,[term_value]
  mov edx,1
  ccall setenv
  lea rdi,[color_name]
  lea rsi,[color_value]
  mov edx,1
  ccall setenv
  ; Optional: -e <command> [args]. execvp uses existing argv+2 vector.
  mov eax,[cmd_argc]
  cmp eax,2
  jl .default
  mov rbx,[cmd_argv]
  mov rdi,[rbx+8]
  lea rsi,[opt_e]
  ccall strcmp
  test eax,eax
  jne .default
  mov rbx,[cmd_argv]
  mov rdi,[rbx+16]
  lea rsi,[rbx+16]
  ccall execvp
.default:
  lea rdi,[shell_name]
  ccall getenv
  test rax,rax
  jz .sh
  cmp byte [rax],0
  jz .sh
  mov [shell_ptr],rax
  jmp .exec
.sh:
  lea rax,[fallback_shell]
  mov [shell_ptr],rax
.exec:
  mov rax,[shell_ptr]
  mov [sh_argv],rax
  mov rdi,rax
  lea rsi,[sh_argv]
  ccall execvp
  mov edi,127
  ccall _exit

; eax = 0-based screen row, return rax=&cell[0] for live screen.
rowaddr:
  test byte [altscreen],1
  jnz .alt
  add eax,[head]
  and eax,RMASK
  shl rax,11
  lea r11,[history]
  add rax,r11
  ret
.alt:
  shl rax,11
  lea r11,[alternate]
  add rax,r11
  ret

; eax = visible row, returns line, incorporating main-buffer history view.
visaddr:
  test byte [altscreen],1
  jnz rowaddr
  sub eax,[view]
  jmp rowaddr

; eax=row, wipes MAXCOL cells. zero cell means empty with default bg.
clear_row:
  call rowaddr
  mov rdi,rax
  ; Erased cells retain the active background color (BCE).
  mov eax,[curattr]
  shl rax,32
  mov ecx,MAXCOL
  rep stosq
  ret

invalidate_all:
  mov byte [dirty_any],1
  lea rdi,[dirty]
  mov ecx,MAXROW
  mov al,1
  rep stosb
  ret

; eax = row to dirty
mark_row:
  cmp eax,[rows]
  jae .done
  lea rdx,[dirty]
  mov byte [rdx+rax],1
  mov byte [dirty_any],1
.done:
  ret

; rax = visible row pointer, selection/buffer shared for render and clipboard.
; ecx = the visual row when computing; leave reserved registers alone.

; scroll_up: one line of upward scrolling in active region. full screen O(1).
scroll_up:
  cmp dword [top],0
  jne .region
  mov eax,[rows]
  dec eax
  cmp [bottom],eax
  jne .region
  cmp byte [altscreen],0
  jne .region
  mov eax,[head]
  inc eax
  and eax,RMASK
  mov [head],eax
  mov eax,RING-MAXROW
  cmp [histcount],eax
  jae .hist_full
  inc dword [histcount]
.hist_full:
  mov eax,[rows]
  dec eax
  call clear_row
  cmp dword [view],0
  je .selection_shift
  inc dword [view]
  mov eax,[histcount]
  cmp [view],eax
  jle .selection_shift
  mov [view],eax
.selection_shift:
  ; Selection rows are signed offsets from the live head, not screen Y.
  ; Advance their offsets with the ring head so highlights follow content.
  cmp byte [selection_active],0
  je .invalid
  dec dword [sel_anchor_y]
  dec dword [sel_end_y]
  ; Once either end of a selection is overwritten, discard the highlight.
  mov eax,[histcount]
  neg eax
  cmp [sel_anchor_y],eax
  jl .selection_expired
  cmp [sel_end_y],eax
  jge .invalid
.selection_expired:
  mov byte [selection_active],0
.invalid:
  call invalidate_all
  ret
.region:
  ; Region scrolling rearranges cells in place, unlike a ring advance.
  mov byte [selection_active],0
  mov r14d,[top]
.copy:
  cmp r14d,[bottom]
  jge .wipe
  mov eax,r14d
  inc eax
  call rowaddr
  mov rsi,rax
  mov eax,r14d
  call rowaddr
  mov rdi,rax
  mov ecx,MAXCOL
  rep movsq
  inc r14d
  jmp .copy
.wipe:
  mov eax,[bottom]
  call clear_row
  call invalidate_all
  ret

scroll_down:
  ; Reverse-index scrolling mutates in-place rows; stale selections are invalid.
  mov byte [selection_active],0
  mov r14d,[bottom]
.copy:
  cmp r14d,[top]
  jle .wipe
  mov eax,r14d
  dec eax
  call rowaddr
  mov rsi,rax
  mov eax,r14d
  call rowaddr
  mov rdi,rax
  mov ecx,MAXCOL
  rep movsq
  dec r14d
  jmp .copy
.wipe:
  mov eax,[top]
  call clear_row
  call invalidate_all
  ret

newline:
  mov eax,[cursor_y]
  cmp eax,[bottom]
  jne .normal
  call scroll_up
  jmp .done
.normal:
  mov eax,[rows]
  dec eax
  cmp [cursor_y],eax
  jge .done
  inc dword [cursor_y]
.done:
  ret

; Put UTF-32 codepoint in edi. Width from wcwidth for non-ASCII.
put_rune:
  push rbx
  mov ebx,edi
  mov dword [glyph_width],1
  cmp ebx,128
  jb .have_width
  ccall wcwidth
  cmp eax,1
  jge .width_good
  pop rbx
  ret
.width_good:
  cmp eax,2
  jle .width_good2
  mov eax,1
.width_good2:
  mov [glyph_width],eax
.have_width:
  cmp byte [wrap_next],0
  je .no_wrap
  mov byte [wrap_next],0
  cmp dword [wrap_enable],0
  je .no_wrap
  mov dword [cursor_x],0
  call newline
.no_wrap:
  mov eax,[cols]
  sub eax,[glyph_width]
  cmp [cursor_x],eax
  jle .fits
  mov dword [cursor_x],0
  call newline
.fits:
  mov eax,[cursor_y]
  call rowaddr
  cmp byte [insert_mode],0
  je .no_insert
  ; DECTCEM/IRM insertion: move screen cells right when enabled.
  mov ecx,[cols]
  dec ecx
  mov edx,[glyph_width]
.insert_loop:
  mov edi,ecx
  sub edi,edx
  cmp edi,[cursor_x]
  jl .insert_done
  mov r8,[rax+rdi*8]
  mov [rax+rcx*8],r8
  dec ecx
  jmp .insert_loop
.insert_done:
  mov byte [dirty_any],1
.no_insert:
  mov edx,[cursor_x]
  lea rdx,[rax+rdx*8]
  mov [rdx],ebx
  mov eax,[curattr]
  mov [rdx+4],eax
  mov eax,[glyph_width]
  cmp eax,2
  jne .single
  mov dword [rdx+8],0
  mov eax,[curattr]
  or eax,80000h               ; trailing-cell marker
  mov [rdx+12],eax
.single:
  mov eax,[cursor_y]
  call mark_row
  mov eax,[cursor_x]
  add eax,[glyph_width]
  cmp eax,[cols]
  jl .next_col
  mov eax,[cols]
  dec eax
  mov byte [wrap_next],1
  jmp .store
.next_col:
  mov byte [wrap_next],0
.store:
  mov [cursor_x],eax
  pop rbx
  ret

; CSI parsing: up to 16 numeric args. Unspecified args read as zero.
parse_csi:
  cmp al,'?'
  jne .not_priv
  ; DEC private CSI is the only extra parameter introducer we implement.
  cmp dword [csi_count],0
  jne .unsupported
  mov byte [csi_private],1
  ret
.not_priv:
  cmp al,'0'
  jb .not_digit
  cmp al,'9'
  ja .not_digit
  movzx edx,al
  sub edx,'0'
  mov ecx,[csi_count]
  cmp ecx,15
  ja .end
  lea rdi,[csi_args]
  mov eax,[rdi+rcx*4]
  imul eax,10
  add eax,edx
  cmp eax,65535
  jbe .save
  mov eax,65535
.save:
  mov [rdi+rcx*4],eax
  ret
.not_digit:
  cmp al,';'
  jne .final
  cmp dword [csi_count],15
  jae .end
  inc dword [csi_count]
  ret
.final:
  ; CSI can have parameter-prefix bytes (<,=,>,?), colon subparameters,
  ; and intermediate bytes (20h..2fh). Never render those bytes as text
  ; just because we do not implement the corresponding extension.
  ; Vim sends CSI > 4 ; m (xterm modifyOtherKeys reset) on exit.
  cmp al,40h
  jae .terminator
  cmp al,20h
  jae .unsupported
  cmp al,27
  jne .continue
  mov dword [parse_state],1   ; ESC aborts current CSI, starts a new one
  ret
.unsupported:
  mov byte [csi_ignore],1
.continue:
  ret
.terminator:
  cmp al,7eh
  ja .end
  cmp byte [csi_ignore],0
  jne .end
  call csi_exec
.end:
  mov byte [parse_state],0
  ret

; Handle bytes, including UTF-8 incremental decoder, CSI, OSC and DEC graphics.
; AL is the incoming byte.
process_byte:
  movzx ebx,al
  mov eax,[parse_state]
  cmp eax,0
  je .ground
  cmp eax,1
  je .escape
  cmp eax,2
  je .csi
  cmp eax,3
  je .osc
  cmp eax,4
  je .osc_esc
  cmp eax,5
  je .charset
  mov dword [parse_state],0
  ret
.ground:
  cmp bl,27
  jne .control
  mov dword [parse_state],1
  mov dword [utf_need],0
  ret
.control:
  cmp bl,32
  jae .printable
  cmp bl,13
  je .cr
  cmp bl,10
  je .lf
  cmp bl,8
  je .bs
  cmp bl,9
  je .tab
  ret
.cr:
  mov dword [cursor_x],0
  mov byte [wrap_next],0
  ret
.lf:
  mov byte [wrap_next],0
  call newline
  ret
.bs:
  cmp dword [cursor_x],0
  jle .done
  dec dword [cursor_x]
.done:
  mov byte [wrap_next],0
  ret
.tab:
  mov eax,[cursor_x]
  add eax,8
  and eax,-8
  cmp eax,[cols]
  jl .tab_ok
  mov eax,[cols]
  dec eax
.tab_ok:
  mov [cursor_x],eax
  ret
.printable:
  cmp bl,7fh
  je .done
  cmp dword [utf_need],0
  jne .utf_cont
  cmp bl,80h
  jb .ascii
  cmp bl,0c2h
  jb .replacement
  cmp bl,0e0h
  jb .two
  cmp bl,0f0h
  jb .three
  cmp bl,0f5h
  jae .replacement
  mov dword [utf_need],3
  and ebx,7
  mov [utf_code],ebx
  ret
.two:
  mov dword [utf_need],1
  and ebx,31
  mov [utf_code],ebx
  ret
.three:
  mov dword [utf_need],2
  and ebx,15
  mov [utf_code],ebx
  ret
.utf_cont:
  cmp bl,80h
  jb .replacement
  cmp bl,0bfh
  ja .replacement
  mov eax,[utf_code]
  shl eax,6
  and ebx,63
  or eax,ebx
  mov [utf_code],eax
  dec dword [utf_need]
  jnz .done
  mov edi,eax
  call put_rune
  ret
.replacement:
  mov dword [utf_need],0
  mov edi,0fffdh
  call put_rune
  ret
.ascii:
  mov edi,ebx
  cmp byte [dec_graphics],0
  je .ascii_direct
  call dec_translate
.ascii_direct:
  call put_rune
  ret
.escape:
  mov dword [parse_state],0
  cmp bl,'['
  je .start_csi
  cmp bl,']'
  je .start_osc
  cmp bl,'('
  je .charset_esc
  cmp bl,'7'
  je .save_cursor
  cmp bl,'8'
  je .restore_cursor
  cmp bl,'D'
  je .index
  cmp bl,'E'
  je .next_line
  cmp bl,'M'
  je .reverse_index
  cmp bl,'c'
  je .reset
  ret
.start_csi:
  mov dword [parse_state],2
  mov byte [csi_private],0
  mov byte [csi_ignore],0
  mov dword [csi_count],0
  lea rdi,[csi_args]
  xor eax,eax
  mov ecx,16
  rep stosd
  ret
.start_osc:
  mov dword [parse_state],3
  mov dword [osc_len],0
  ret
.charset_esc:
  mov dword [parse_state],5
  ret
.save_cursor:
  mov eax,[cursor_x]
  mov [saved_x],eax
  mov eax,[cursor_y]
  mov [saved_y],eax
  ret
.restore_cursor:
  mov eax,[saved_x]
  mov [cursor_x],eax
  mov eax,[saved_y]
  mov [cursor_y],eax
  ret
.index:
  call newline
  ret
.next_line:
  mov dword [cursor_x],0
  call newline
  ret
.reverse_index:
  mov eax,[cursor_y]
  cmp eax,[top]
  jne .rev_normal
  call scroll_down
  ret
.rev_normal:
  test eax,eax
  jz .done
  dec dword [cursor_y]
  ret
.reset:
  call terminal_reset
  ret
.csi:
  mov al,bl
  call parse_csi
  ret
.osc:
  cmp bl,7
  je .osc_end
  cmp bl,27
  je .osc_bslash
  mov eax,[osc_len]
  cmp eax,510
  jae .done
  lea rdx,[osc_buffer]
  mov [rdx+rax],bl
  inc dword [osc_len]
  ret
.osc_bslash:
  mov dword [parse_state],4
  ret
.osc_esc:
  cmp bl,'\'
  je .osc_end
  mov dword [parse_state],3
  ret
.osc_end:
  mov dword [parse_state],0
  mov eax,[osc_len]
  lea rdx,[osc_buffer]
  mov byte [rdx+rax],0
  cmp byte [osc_buffer],'0'
  je .osc_title
  cmp byte [osc_buffer],'2'
  jne .done
.osc_title:
  cmp byte [osc_buffer+1],';'
  jne .done
  mov rdi,[dpy]
  mov rsi,[win]
  lea rdx,[osc_buffer+2]
  ccall XStoreName
  ret
.charset:
  mov dword [parse_state],0
  cmp bl,'0'
  setz byte [dec_graphics]
  ret

; `dec_translate` in edi -> edi, maps VT100 line-drawing to Unicode.
dec_translate:
  cmp edi,'q'
  jne .x
  mov edi,2500h
  ret
.x:
  cmp edi,'x'
  jne .l
  mov edi,2502h
  ret
.l:
  cmp edi,'l'
  jne .k
  mov edi,250ch
  ret
.k:
  cmp edi,'k'
  jne .m
  mov edi,2510h
  ret
.m:
  cmp edi,'m'
  jne .j
  mov edi,2514h
  ret
.j:
  cmp edi,'j'
  jne .t
  mov edi,2518h
  ret
.t:
  cmp edi,'t'
  jne .u
  mov edi,251ch
  ret
.u:
  cmp edi,'u'
  jne .v
  mov edi,2524h
  ret
.v:
  cmp edi,'v'
  jne .w
  mov edi,2534h
  ret
.w:
  cmp edi,'w'
  jne .n
  mov edi,252ch
  ret
.n:
  cmp edi,'n'
  jne .done
  mov edi,253ch
.done:
  ret

; PTY feed. rdi=length, rsi=bytes.
feed_bytes:
  push r12
  push r13
  push rbx
  mov r12,rsi
  lea r13,[rsi+rdi]
.loop:
  cmp r12,r13
  jae .end
  ; SSE4.1 batch: four printable ASCII characters, normal parser state,
  ; width available and no pending wrap. No libc call in fast path.
  cmp dword [parse_state],0
  jne .slow
  cmp dword [utf_need],0
  jne .slow
  cmp byte [dec_graphics],0
  jne .slow
  cmp byte [wrap_next],0
  jne .slow
  lea rax,[r12+4]
  cmp rax,r13
  ja .slow
  mov eax,[cols]
  sub eax,[cursor_x]
  cmp eax,4
  jl .slow
  mov eax,[r12]
  mov edx,eax
  and edx,80808080h
  jnz .slow
  mov edx,eax
  sub edx,20202020h
  and edx,80808080h
  jnz .slow
  mov edx,eax
  add edx,01010101h
  and edx,80808080h
  jnz .slow
  movd xmm0,eax
  pmovzxbd xmm0,xmm0
  movd xmm1,[curattr]
  pshufd xmm1,xmm1,0
  movdqa xmm2,xmm0
  punpckldq xmm0,xmm1
  punpckhdq xmm2,xmm1
  mov eax,[cursor_y]
  call rowaddr
  mov edx,[cursor_x]
  lea rax,[rax+rdx*8]
  movdqu [rax],xmm0
  movdqu [rax+16],xmm2
  add dword [cursor_x],4
  mov eax,[cursor_x]
  cmp eax,[cols]
  jne .simd_not_wrap
  dec dword [cursor_x]
  mov byte [wrap_next],1
.simd_not_wrap:
  mov eax,[cursor_y]
  call mark_row
  add r12,4
  jmp .loop
.slow:
  mov al,[r12]
  inc r12
  call process_byte
  jmp .loop
.end:
  pop rbx
  pop r13
  pop r12
  ret

; cursor limits and erase: CSI argument helper returns max(1,args[index]).
; edi = argument position, eax result.
param1:
  mov eax,[csi_args+rdi*4]
  test eax,eax
  jnz .done
  mov eax,1
.done:
  ret

; csi_exec: al final byte, csi_args / csi_private / csi_count.
csi_exec:
  mov [final_byte],al
  cmp al,'m'
  je csi_sgr
  cmp al,'H'
  je csi_cup
  cmp al,'f'
  je csi_cup
  cmp al,'A'
  je .up
  cmp al,'B'
  je .down
  cmp al,'C'
  je .right
  cmp al,'D'
  je .left
  cmp al,'E'
  je .next
  cmp al,'F'
  je .prev
  cmp al,'G'
  je .col
  cmp al,'d'
  je .row
  cmp al,'J'
  je csi_erase_display
  cmp al,'K'
  je csi_erase_line
  cmp al,'X'
  je .erase_chars
  cmp al,'r'
  je .region
  cmp al,'S'
  je .scroll_up
  cmp al,'T'
  je .scroll_down
  cmp al,'L'
  je .insert_lines
  cmp al,'M'
  je .delete_lines
  cmp al,'@'
  je .insert_chars
  cmp al,'P'
  je .delete_chars
  cmp al,'h'
  je .setmode
  cmp al,'l'
  je .resetmode
  cmp al,'s'
  je .save
  cmp al,'u'
  je .restore
  cmp al,'n'
  je .status
  cmp al,'c'
  je .identity
  ret
.up:
  xor edi,edi
  call param1
  sub [cursor_y],eax
  jmp clamp_cursor
.down:
  xor edi,edi
  call param1
  add [cursor_y],eax
  jmp clamp_cursor
.right:
  xor edi,edi
  call param1
  add [cursor_x],eax
  jmp clamp_cursor
.left:
  xor edi,edi
  call param1
  sub [cursor_x],eax
  jmp clamp_cursor
.next:
  xor edi,edi
  call param1
  add [cursor_y],eax
  mov dword [cursor_x],0
  jmp clamp_cursor
.prev:
  xor edi,edi
  call param1
  sub [cursor_y],eax
  mov dword [cursor_x],0
  jmp clamp_cursor
.col:
  xor edi,edi
  call param1
  dec eax
  mov [cursor_x],eax
  jmp clamp_cursor
.row:
  xor edi,edi
  call param1
  dec eax
  mov [cursor_y],eax
  jmp clamp_cursor
.region:
  cmp byte [csi_private],0
  jne .done
  xor edi,edi
  call param1
  dec eax
  mov ebx,eax
  mov edi,1
  mov eax,[csi_args+4]
  test eax,eax
  jnz .have_bot
  mov eax,[rows]
.have_bot:
  dec eax
  cmp ebx,eax
  jge .done
  cmp eax,[rows]
  jae .done
  mov [top],ebx
  mov [bottom],eax
  mov dword [cursor_y],0
  mov dword [cursor_x],0
.done:
  ret
.scroll_up:
  xor edi,edi
  call param1
  mov ebx,eax
  ; Malformed CSI 65535{S,T,L,M} must not perform millions of line copies.
  cmp ebx,[rows]
  jle .su_bounded
  mov ebx,[rows]
.su_bounded:
.su_loop:
  call scroll_up
  dec ebx
  jnz .su_loop
  ret
.scroll_down:
  xor edi,edi
  call param1
  mov ebx,eax
  ; Malformed CSI 65535{S,T,L,M} must not perform millions of line copies.
  cmp ebx,[rows]
  jle .sd_bounded
  mov ebx,[rows]
.sd_bounded:
.sd_loop:
  call scroll_down
  dec ebx
  jnz .sd_loop
  ret
.insert_lines:
  mov ebx,[cursor_y]
  mov eax,[top]
  mov [saved_top],eax
  mov [top],ebx
  xor edi,edi
  call param1
  mov ebx,eax
  ; Malformed CSI 65535{S,T,L,M} must not perform millions of line copies.
  cmp ebx,[rows]
  jle .il_bounded
  mov ebx,[rows]
.il_bounded:
.il_loop:
  call scroll_down
  dec ebx
  jnz .il_loop
  mov eax,[saved_top]
  mov [top],eax
  ret
.delete_lines:
  mov eax,[top]
  mov [saved_top],eax
  mov eax,[cursor_y]
  mov [top],eax
  xor edi,edi
  call param1
  mov ebx,eax
  ; Malformed CSI 65535{S,T,L,M} must not perform millions of line copies.
  cmp ebx,[rows]
  jle .dl_bounded
  mov ebx,[rows]
.dl_bounded:
.dl_loop:
  call scroll_up
  dec ebx
  jnz .dl_loop
  mov eax,[saved_top]
  mov [top],eax
  ret
.erase_chars:
  xor edi,edi
  call param1
  mov edx,[cursor_x]
  add eax,edx
  dec eax
  cmp eax,[cols]
  jl .ec_bound
  mov eax,[cols]
  dec eax
.ec_bound:
  mov esi,[cursor_y]
  mov ecx,eax
  call clear_range
  ret
.insert_chars:
  xor edi,edi
  call param1
  mov ebx,eax
  mov eax,[cursor_y]
  call rowaddr
  mov r8,rax
  mov eax,[cols]
  sub eax,[cursor_x]
  cmp ebx,eax
  jle .ic_have
  mov ebx,eax
.ic_have:
  mov ecx,[cols]
  dec ecx
  mov edx,[cols]
  sub edx,ebx
  dec edx
.ic_loop:
  cmp edx,[cursor_x]
  jl .ic_blank
  mov rax,[r8+rdx*8]
  mov [r8+rcx*8],rax
  dec edx
  dec ecx
  jmp .ic_loop
.ic_blank:
  mov edx,[cursor_x]
  mov ecx,ebx
  xor eax,eax
.ic_clear:
  test ecx,ecx
  jle .ic_end
  mov [r8+rdx*8],rax
  inc edx
  dec ecx
  jmp .ic_clear
.ic_end:
  mov eax,[cursor_y]
  call mark_row
  ret
.delete_chars:
  xor edi,edi
  call param1
  mov ebx,eax
  mov eax,[cursor_y]
  call rowaddr
  mov r8,rax
  mov eax,[cols]
  sub eax,[cursor_x]
  cmp ebx,eax
  jle .dc_have
  mov ebx,eax
.dc_have:
  mov edx,[cursor_x]
.dc_loop:
  mov ecx,edx
  add ecx,ebx
  cmp ecx,[cols]
  jge .dc_blank
  mov rax,[r8+rcx*8]
  mov [r8+rdx*8],rax
  inc edx
  jmp .dc_loop
.dc_blank:
  xor eax,eax
.dc_clear:
  cmp edx,[cols]
  jge .dc_end
  mov [r8+rdx*8],rax
  inc edx
  jmp .dc_clear
.dc_end:
  mov eax,[cursor_y]
  call mark_row
  ret
.setmode:
  mov dl,1
  jmp csi_mode
.resetmode:
  xor edx,edx
  jmp csi_mode
.save:
  mov eax,[cursor_x]
  mov [saved_x],eax
  mov eax,[cursor_y]
  mov [saved_y],eax
  ret
.restore:
  mov eax,[saved_x]
  mov [cursor_x],eax
  mov eax,[saved_y]
  mov [cursor_y],eax
  jmp clamp_cursor
.status:
  cmp dword [csi_args],6
  jne .ready
  ; Cursor position report ESC[row;colR; variable-length decimal.
  push r15
  lea r15,[reply_buf]
  mov byte [r15],27
  mov byte [r15+1],'['
  add r15,2
  mov eax,[cursor_y]
  inc eax
  call append_dec
  mov byte [r15],';'
  inc r15
  mov eax,[cursor_x]
  inc eax
  call append_dec
  mov byte [r15],'R'
  inc r15
  lea rax,[reply_buf]
  sub r15,rax
  mov rdx,r15
  lea rsi,[reply_buf]
  call pty_write
  pop r15
  ret
.ready:
  cmp dword [csi_args],5
  jne .done
  lea rsi,[status_ok]
  mov edx,4
  jmp pty_write
.identity:
  cmp byte [csi_private],0
  jne .done
  lea rsi,[device_id]
  mov edx,5
  jmp pty_write

clamp_cursor:
  cmp dword [cursor_y],0
  jge .cy_ok
  mov dword [cursor_y],0
.cy_ok:
  mov eax,[rows]
  dec eax
  cmp [cursor_y],eax
  jle .cy_max
  mov [cursor_y],eax
.cy_max:
  cmp dword [cursor_x],0
  jge .cx_ok
  mov dword [cursor_x],0
.cx_ok:
  mov eax,[cols]
  dec eax
  cmp [cursor_x],eax
  jle .cx_max
  mov [cursor_x],eax
.cx_max:
  mov byte [wrap_next],0
  ret

; ecx=endCol, edx=startCol, esi=row; inclusive range.
clear_range:
  push rbx
  mov ebx,ecx
  mov eax,esi
  call rowaddr
  lea rdi,[rax+rdx*8]
  mov ecx,ebx
  sub ecx,edx
  inc ecx
  jle .none
  ; BCE: an erase uses the current rendition, not always black.
  mov eax,[curattr]
  shl rax,32
  rep stosq
  mov eax,esi
  call mark_row
.none:
  pop rbx
  ret

csi_erase_line:
  mov eax,[csi_args]
  mov edx,[cursor_x]
  mov ecx,[cols]
  dec ecx
  cmp eax,0
  je .clear
  xor edx,edx
  cmp eax,1
  je .first
  cmp eax,2
  jne .done
  jmp .clear
.first:
  mov ecx,[cursor_x]
.clear:
  mov esi,[cursor_y]
  call clear_range
.done:
  ret

csi_erase_display:
  mov ebx,[csi_args]
  cmp ebx,3
  jne .normal
  mov dword [histcount],0
  mov dword [view],0
  ret
.normal:
  cmp ebx,0
  jne .not_zero
  mov edi,[cursor_y]
  mov [erase_first],edi
  mov eax,[rows]
  dec eax
  mov [erase_last],eax
  jmp .go
.not_zero:
  cmp ebx,1
  jne .all
  mov dword [erase_first],0
  mov eax,[cursor_y]
  mov [erase_last],eax
  jmp .go
.all:
  cmp ebx,2
  jne .done
  mov dword [erase_first],0
  mov eax,[rows]
  dec eax
  mov [erase_last],eax
.go:
  mov r14d,[erase_first]
.loop:
  cmp r14d,[erase_last]
  jg .done
  xor edx,edx
  mov ecx,[cols]
  dec ecx
  cmp ebx,0
  jne .not_start
  cmp r14d,[cursor_y]
  jne .not_start
  mov edx,[cursor_x]
.not_start:
  cmp ebx,1
  jne .not_end
  cmp r14d,[cursor_y]
  jne .not_end
  mov ecx,[cursor_x]
.not_end:
  mov esi,r14d
  call clear_range
  inc r14d
  jmp .loop
.done:
  ret

csi_sgr:
  xor esi,esi
.loop:
  cmp esi,[csi_count]
  jg .done
  mov eax,[csi_args+rsi*4]
  cmp eax,0
  je .reset
  cmp eax,1
  je .bold
  cmp eax,22
  je .normal
  cmp eax,4
  je .underline
  cmp eax,24
  je .no_underline
  cmp eax,7
  je .inverse
  cmp eax,27
  je .uninverse
  cmp eax,30
  jb .other
  cmp eax,37
  jle .fg
  cmp eax,39
  je .fg_default
  cmp eax,40
  jb .other
  cmp eax,47
  jle .bg
  cmp eax,49
  je .bg_default
  cmp eax,90
  jb .other
  cmp eax,97
  jle .bright_fg
  cmp eax,100
  jb .other
  cmp eax,107
  jle .bright_bg
.other:
  cmp eax,38
  je .extended
  cmp eax,48
  je .extended
  jmp .advance
.reset:
  mov dword [curattr],7
  jmp .advance
.bold:
  or dword [curattr],10000h
  jmp .advance
.underline:
  or dword [curattr],40000h
  jmp .advance
.no_underline:
  and dword [curattr],0fffbffffh
  jmp .advance
.normal:
  and dword [curattr],0fffeffffh
  jmp .advance
.inverse:
  or dword [curattr],20000h
  jmp .advance
.uninverse:
  and dword [curattr],0fffdffffh
  jmp .advance
.fg:
  sub eax,30
  and dword [curattr],0ffffff00h
  or [curattr],eax
  jmp .advance
.bg:
  sub eax,40
  shl eax,8
  and dword [curattr],0ffff00ffh
  or [curattr],eax
  jmp .advance
.bright_fg:
  sub eax,82
  and dword [curattr],0ffffff00h
  or [curattr],eax
  jmp .advance
.bright_bg:
  sub eax,92
  shl eax,8
  and dword [curattr],0ffff00ffh
  or [curattr],eax
  jmp .advance
.fg_default:
  and dword [curattr],0ffffff00h
  or dword [curattr],7
  jmp .advance
.bg_default:
  and dword [curattr],0ffff00ffh
  jmp .advance
.extended:
  mov ebx,eax
  mov ecx,esi
  inc ecx
  cmp ecx,[csi_count]
  jg .advance
  cmp dword [csi_args+rcx*4],5
  jne .rgb
  inc esi
  inc ecx
  cmp ecx,[csi_count]
  jg .advance
  mov eax,[csi_args+rcx*4]
  and eax,255
  inc esi
  jmp .ext_set
.rgb:
  cmp dword [csi_args+rcx*4],2
  jne .advance
  lea ecx,[rsi+4]
  cmp ecx,[csi_count]
  jg .advance
  ; Map 24-bit RGB into xterm 6x6x6 gamut without allocation.
  ; Exact truecolor is deliberately not retained in the 8-byte cell.
  mov eax,[csi_args+rsi*4+8]
  imul eax,5
  xor edx,edx
  mov edi,255
  div edi
  imul eax,36
  mov r8d,eax
  mov eax,[csi_args+rsi*4+12]
  imul eax,5
  xor edx,edx
  div edi
  imul eax,6
  add r8d,eax
  mov eax,[csi_args+rsi*4+16]
  imul eax,5
  xor edx,edx
  div edi
  add eax,r8d
  add eax,16
  add esi,4
.ext_set:
  cmp ebx,38
  jne .ext_bg
  and dword [curattr],0ffffff00h
  or [curattr],eax
  jmp .advance
.ext_bg:
  shl eax,8
  and dword [curattr],0ffff00ffh
  or [curattr],eax
.advance:
  inc esi
  jmp .loop
.done:
  ret

csi_cup:
  mov edi,0
  call param1
  dec eax
  mov ebx,eax
  mov edi,1
  call param1
  dec eax
  mov [cursor_x],eax
  mov [cursor_y],ebx
  jmp clamp_cursor

; CSI ?h/?l (DEC private modes) and non-private insert mode.
csi_mode:
  mov [mode_on],dl
  xor r14d,r14d
.loop:
  cmp r14d,[csi_count]
  jg .done
  mov eax,[csi_args+r14*4]
  cmp byte [csi_private],0
  je .normal
  cmp eax,25
  je .cursor
  cmp eax,1049
  je .altscreen
  cmp eax,1047
  je .altscreen
  cmp eax,47
  je .altscreen
  cmp eax,1048
  je .save_cursor_only
  cmp eax,2004
  je .bracket
  cmp eax,1000
  je .mouse
  cmp eax,1002
  je .mouse
  cmp eax,1006
  je .sgr_mouse
  cmp eax,1
  je .app_cursor
  cmp eax,7
  je .wrap
  jmp .next
.normal:
  cmp eax,4
  jne .next
  mov al,[mode_on]
  mov [insert_mode],al
  jmp .next
.cursor:
  movzx eax,byte [mode_on]
  mov [cursor_show],eax
  call invalidate_all
  jmp .next
.save_cursor_only:
  ; DECSC/DECRC without changing the active screen.
  cmp byte [mode_on],0
  je .private_restore
  mov eax,[cursor_x]
  mov [saved_x],eax
  mov eax,[cursor_y]
  mov [saved_y],eax
  jmp .next
.private_restore:
  mov eax,[saved_x]
  mov [cursor_x],eax
  mov eax,[saved_y]
  mov [cursor_y],eax
  call clamp_cursor
  jmp .next
.altscreen:
  mov al,[mode_on]
  cmp [altscreen],al
  je .next
  test al,al
  jz .restore_main
  ; Save the live-screen state BEFORE activating the alternate buffer.
  ; Editors legitimately change SGR, scroll region, charset, cursor mode,
  ; etc. Those changes must not leak back into the shell on exit.
  mov eax,[cursor_x]
  mov [main_x],eax
  mov eax,[cursor_y]
  mov [main_y],eax
  mov eax,[saved_x]
  mov [main_saved_x],eax
  mov eax,[saved_y]
  mov [main_saved_y],eax
  mov eax,[curattr]
  mov [main_attr],eax
  mov eax,[top]
  mov [main_top],eax
  mov eax,[bottom]
  mov [main_bottom],eax
  mov eax,[view]
  mov [main_view],eax
  mov eax,[cursor_show]
  mov [main_cursor_show],eax
  mov eax,[wrap_enable]
  mov [main_wrap_enable],eax
  mov al,[wrap_next]
  mov [main_wrap_next],al
  mov al,[insert_mode]
  mov [main_insert_mode],al
  mov al,[dec_graphics]
  mov [main_dec_graphics],al
  mov al,[app_cursor]
  mov [main_app_cursor],al
  mov al,[bracketed]
  mov [main_bracketed],al
  mov al,[mouse_mode]
  mov [main_mouse_mode],al
  mov al,[mouse_sgr]
  mov [main_mouse_sgr],al

  mov byte [altscreen],1
  mov byte [selecting],0
  mov byte [selection_active],0
  lea rdi,[alternate]
  xor eax,eax
  mov ecx,MAXROW*MAXCOL
  rep stosq
  mov dword [cursor_x],0
  mov dword [cursor_y],0
  mov dword [saved_x],0
  mov dword [saved_y],0
  mov dword [top],0
  mov eax,[rows]
  dec eax
  mov [bottom],eax
  mov dword [curattr],7
  mov dword [view],0
  mov byte [wrap_next],0
  mov byte [insert_mode],0
  mov byte [dec_graphics],0
  call invalidate_all
  jmp .next
.restore_main:
  mov byte [altscreen],0
  mov byte [selecting],0
  mov byte [selection_active],0
  mov eax,[main_x]
  mov [cursor_x],eax
  mov eax,[main_y]
  mov [cursor_y],eax
  mov eax,[main_saved_x]
  mov [saved_x],eax
  mov eax,[main_saved_y]
  mov [saved_y],eax
  mov eax,[main_attr]
  mov [curattr],eax
  mov eax,[main_top]
  mov [top],eax
  mov eax,[main_bottom]
  mov [bottom],eax
  mov eax,[main_view]
  mov [view],eax
  mov eax,[main_cursor_show]
  mov [cursor_show],eax
  mov eax,[main_wrap_enable]
  mov [wrap_enable],eax
  mov al,[main_wrap_next]
  mov [wrap_next],al
  mov al,[main_insert_mode]
  mov [insert_mode],al
  mov al,[main_dec_graphics]
  mov [dec_graphics],al
  mov al,[main_app_cursor]
  mov [app_cursor],al
  mov al,[main_bracketed]
  mov [bracketed],al
  mov al,[main_mouse_mode]
  mov [mouse_mode],al
  mov al,[main_mouse_sgr]
  mov [mouse_sgr],al
  ; Normal-screen contents never belonged to the alternate buffer;
  ; force every visible row to be repainted after the switch.
  call invalidate_all
  jmp .next
.bracket:
  mov al,[mode_on]
  mov [bracketed],al
  jmp .next
.mouse:
  mov al,[mode_on]
  mov [mouse_mode],al
  jmp .next
.sgr_mouse:
  mov al,[mode_on]
  mov [mouse_sgr],al
  jmp .next
.app_cursor:
  mov al,[mode_on]
  mov [app_cursor],al
  jmp .next
.wrap:
  movzx eax,byte [mode_on]
  mov [wrap_enable],eax
.next:
  inc r14d
  jmp .loop
.done:
  ret

terminal_reset:
  mov byte [selection_active],0
  mov dword [curattr],7
  mov dword [top],0
  mov eax,[rows]
  dec eax
  mov [bottom],eax
  mov dword [cursor_x],0
  mov dword [cursor_y],0
  mov dword [view],0
  mov byte [altscreen],0
  mov dword [head],0
  mov dword [histcount],0
  lea rdi,[history]
  xor eax,eax
  mov ecx,MAXROW*MAXCOL
  rep stosq
  call invalidate_all
  ret

; Write to child PTY: rsi data, rdx count. Protocol replies and mouse
; reports do not move history; interactive key/paste entry points do.
pty_write:
  mov edi,[ptyfd]
  ccall write
  ret

; Get a color, allocate only on first use. Input edi = xterm palette index.
; Return rax = &XftColor. Does not preserve caller-saved registers.
ensure_color:
  push rbx
  mov ebx,edi
  cmp ebx,255
  jbe .valid
  mov ebx,7
.valid:
  lea rax,[colormap_xft]
  lea rax,[rax+rbx*8]
  lea rax,[rax+rbx*8]         ; 16 bytes per XftColor
  lea rcx,[color_ready]
  cmp byte [rcx+rbx],0
  jne .done
  cmp ebx,15
  jg .other
  lea rcx,[ansi16]
  mov eax,[rcx+rbx*4]
  jmp .convert
.other:
  cmp ebx,231
  jg .gray
  mov eax,ebx
  sub eax,16
  xor edx,edx
  mov ecx,36
  div ecx
  mov esi,eax                  ; red 0..5
  mov eax,edx
  xor edx,edx
  mov ecx,6
  div ecx
  mov edi,eax                  ; green 0..5
  mov ecx,edx                  ; blue 0..5
  lea r8,[cube]
  movzx eax,byte [r8+rsi]
  shl eax,16
  movzx edx,byte [r8+rdi]
  shl edx,8
  or eax,edx
  movzx edx,byte [r8+rcx]
  or eax,edx
  jmp .convert
.gray:
  mov eax,ebx
  sub eax,232
  imul eax,10
  add eax,8
  imul eax,010101h
.convert:
  ; XRenderColor {uint16 red,green,blue,alpha}
  mov ecx,eax
  shr ecx,16
  imul ecx,257
  mov word [render_color],cx
  mov ecx,eax
  shr ecx,8
  and ecx,255
  imul ecx,257
  mov word [render_color+2],cx
  mov ecx,eax
  and ecx,255
  imul ecx,257
  mov word [render_color+4],cx
  mov word [render_color+6],65535
  mov rdi,[dpy]
  mov rsi,[visual]
  mov rdx,[cmap]
  lea rcx,[render_color]
  lea r8,[colormap_xft]
  lea r8,[r8+rbx*8]
  lea r8,[r8+rbx*8]
  ccall XftColorAllocValue
  lea rdx,[color_ready]
  mov byte [rdx+rbx],1
  lea rax,[colormap_xft]
  lea rax,[rax+rbx*8]
  lea rax,[rax+rbx*8]
.done:
  pop rbx
  ret

; Retrieve effective colors for a cell (attrs):
; edi=attribute. eax=effective fg index, edx=effective bg index.
cell_colors:
  mov eax,edi
  and eax,255
  mov edx,edi
  shr edx,8
  and edx,255
  test edi,10000h
  jz .no_bold
  cmp eax,8
  jae .no_bold
  add eax,8
.no_bold:
  test edi,20000h
  jz .done
  xchg eax,edx
.done:
  ret

; Render only dirty visible rows. Puts background rectangles first,
; then groups foreground glyphs into same-color runs.
render:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov byte [dirty_any],0
  xor r13d,r13d
.row:
  cmp r13d,[rows]
  jge .cursor
  lea rax,[dirty]
  cmp byte [rax+r13],0
  je .row_next
  mov byte [rax+r13],0
  mov eax,r13d
  call visaddr
  mov r14,rax                 ; 256 8-byte cells
  mov eax,r13d
  imul eax,[cell_h]
  add eax,PAD
  mov [paint_y],eax
  ; fill the whole row once with the default background
  xor edi,edi
  call ensure_color
  mov rsi,rax
  mov rdi,[draw]
  mov edx,PAD
  mov ecx,[paint_y]
  mov r8d,[width]
  sub r8d,PAD*2
  mov r9d,[cell_h]
  ccall XftDrawRect
  ; background runs: only nondefault background
  xor r12d,r12d
.bg_loop:
  cmp r12d,[cols]
  jge .fg_start
  mov edi,[r14+r12*8+4]
  call cell_colors
  mov ebx,edx
  test ebx,ebx
  jz .bg_next
  mov r15d,r12d
.bg_find:
  inc r12d
  cmp r12d,[cols]
  jge .bg_draw
  mov edi,[r14+r12*8+4]
  call cell_colors
  cmp edx,ebx
  je .bg_find
.bg_draw:
  mov edi,ebx
  call ensure_color
  mov rsi,rax
  mov rdi,[draw]
  mov edx,r15d
  imul edx,[cell_w]
  add edx,PAD
  mov ecx,[paint_y]
  mov r8d,r12d
  sub r8d,r15d
  imul r8d,[cell_w]
  mov r9d,[cell_h]
  ccall XftDrawRect
  jmp .bg_loop
.bg_next:
  inc r12d
  jmp .bg_loop
.fg_start:
  ; Overlay the visible mouse-selection range, if any.
  cmp byte [selection_active],0
  je .fg_no_selection
  mov eax,[sel_anchor_y]
  shl eax,8
  add eax,[sel_anchor_x]
  mov edx,[sel_end_y]
  shl edx,8
  add edx,[sel_end_x]
  cmp eax,edx
  jle .fg_sel_sorted
  xchg eax,edx
.fg_sel_sorted:
  ; Compare selection's content-relative positions with this visible row.
  mov ebx,r13d
  sub ebx,[view]
  shl ebx,8
  mov ecx,ebx
  add ecx,[cols]
  dec ecx
  cmp edx,ebx
  jl .fg_no_selection
  cmp eax,ecx
  jg .fg_no_selection
  sub eax,ebx
  jns .fg_sel_start_ok
  xor eax,eax
.fg_sel_start_ok:
  mov [selection_draw_x0],eax
  sub edx,ebx
  cmp edx,[cols]
  jl .fg_sel_end_ok
  mov edx,[cols]
  dec edx
.fg_sel_end_ok:
  mov [selection_draw_x1],edx
  mov edi,4
  call ensure_color
  mov rdi,[draw]
  mov rsi,rax
  mov edx,[selection_draw_x0]
  imul edx,[cell_w]
  add edx,PAD
  mov ecx,[paint_y]
  mov r8d,[selection_draw_x1]
  sub r8d,[selection_draw_x0]
  inc r8d
  imul r8d,[cell_w]
  mov r9d,[cell_h]
  ccall XftDrawRect
.fg_no_selection:
  xor r12d,r12d
.fg_loop:
  cmp r12d,[cols]
  jge .underline_start
  test dword [r14+r12*8+4],80000h  ; wide rune trailing cell
  jz .fg_not_dummy
  inc r12d
  jmp .fg_loop
.fg_not_dummy:
  mov eax,[r14+r12*8]
  cmp eax,128
  jae .fg_unicode
  mov edi,[r14+r12*8+4]
  call cell_colors
  mov ebx,eax                 ; foreground index
  mov r15d,r12d              ; run beginning
  lea r9,[glyphs]
  xor r10d,r10d              ; characters in this run
.fg_find:
  cmp r12d,[cols]
  jge .fg_draw
  test dword [r14+r12*8+4],80000h
  jnz .fg_draw
  mov edi,[r14+r12*8+4]
  call cell_colors
  cmp eax,ebx
  jne .fg_draw
  mov eax,[r14+r12*8]
  cmp eax,128
  jae .fg_draw
  test eax,eax
  jnz .fg_add
  mov eax,' '
.fg_add:
  mov [r9+r10*4],eax
  inc r10d
  inc r12d
  jmp .fg_find
.fg_draw:
  ; Skip all-space runs: the background already cleared them.
  xor ecx,ecx
.check_run:
  cmp ecx,r10d
  jge .fg_loop
  cmp dword [r9+rcx*4],' '
  jne .fg_actual
  inc ecx
  jmp .check_run
.fg_actual:
  mov [run_len],r10d
  mov edi,ebx
  call ensure_color
  mov rdi,[draw]
  mov rsi,rax
  mov rdx,[font]
  mov ecx,r15d
  imul ecx,[cell_w]
  add ecx,PAD
  mov r8d,[paint_y]
  add r8d,[ascent]
  lea r9,[glyphs]
  ; Dedicated 7-arg call with fixed stack restore using global variable.
  mov [stack_save],rsp
  and rsp,-16
  sub rsp,16
  mov qword [rsp],0
  mov eax,[run_len]
  mov [rsp],rax
  call XftDrawString32
  mov rsp,[stack_save]
  jmp .fg_loop
.fg_unicode:
  ; Draw a non-ASCII rune separately at its absolute cell position.
  ; This handles double-width alignment and allows lazy font fallback.
  mov edi,[r14+r12*8+4]
  call cell_colors
  mov ebx,eax
  mov rdi,[dpy]
  mov rsi,[font]
  mov edx,[r14+r12*8]
  ccall XftCharExists
  ; Preserve the base font across subsequent libc/Xft calls.
  ; System V AMD64 makes RDX caller-saved: XftCharExists may destroy it.
  mov rdx,[font]
  mov [unicode_font_tmp],rdx
  test eax,eax
  jnz .u_font_ready
  ; Fontconfig is only asked for an additional font on missing Unicode.
  cmp qword [fallback_cjk],0
  jne .u_check_cjk
  mov rdi,[dpy]
  mov esi,[screen]
  lea rdx,[fallback_spec]
  ccall XftFontOpenName
  mov [fallback_cjk],rax
.u_check_cjk:
  mov rsi,[fallback_cjk]
  test rsi,rsi
  jz .u_font_ready
  mov rdi,[dpy]
  mov edx,[r14+r12*8]
  ccall XftCharExists
  test eax,eax
  jz .u_font_ready
  mov rdx,[fallback_cjk]
  mov [unicode_font_tmp],rdx
.u_font_ready:
  mov edi,ebx
  call ensure_color
  mov rdi,[draw]
  mov rsi,rax
  mov rdx,[unicode_font_tmp]
  mov ecx,r12d
  imul ecx,[cell_w]
  add ecx,PAD
  mov r8d,[paint_y]
  add r8d,[ascent]
  lea r9,[r14+r12*8]
  mov [stack_save],rsp
  and rsp,-16
  sub rsp,16
  mov qword [rsp],1
  call XftDrawString32
  mov rsp,[stack_save]
  inc r12d
  jmp .fg_loop
; SGR underline, grouped in contiguous foreground-color runs.
.underline_start:
  xor r12d,r12d
.ul_loop:
  cmp r12d,[cols]
  jge .row_next
  mov edi,[r14+r12*8+4]
  test edi,40000h
  jz .ul_next
  call cell_colors
  mov ebx,eax
  mov r15d,r12d
.ul_find:
  inc r12d
  cmp r12d,[cols]
  jge .ul_draw
  mov edi,[r14+r12*8+4]
  test edi,40000h
  jz .ul_draw
  call cell_colors
  cmp eax,ebx
  je .ul_find
.ul_draw:
  mov edi,ebx
  call ensure_color
  mov rdi,[draw]
  mov rsi,rax
  mov edx,r15d
  imul edx,[cell_w]
  add edx,PAD
  mov ecx,[paint_y]
  add ecx,[cell_h]
  sub ecx,2
  mov r8d,r12d
  sub r8d,r15d
  imul r8d,[cell_w]
  mov r9d,1
  ccall XftDrawRect
  jmp .ul_loop
.ul_next:
  inc r12d
  jmp .ul_loop
.row_next:
  inc r13d
  jmp .row
.cursor:
  cmp dword [cursor_show],0
  je .flush
  cmp dword [view],0
  jne .flush
  ; Cursor block only if it is within bounds.
  mov eax,[cursor_y]
  cmp eax,[rows]
  jae .flush
  call rowaddr
  mov edx,[cursor_x]
  lea r14,[rax+rdx*8]
  ; white cursor rectangle
  mov edi,15
  call ensure_color
  mov rsi,rax
  mov rdi,[draw]
  mov edx,[cursor_x]
  imul edx,[cell_w]
  add edx,PAD
  mov ecx,[cursor_y]
  imul ecx,[cell_h]
  add ecx,PAD
  mov r8d,[cell_w]
  mov r9d,[cell_h]
  ccall XftDrawRect
  mov eax,[r14]
  test eax,eax
  jz .flush
  mov [cursor_glyph],eax
  mov edi,0
  call ensure_color
  mov rdi,[draw]
  mov rsi,rax
  mov rdx,[font]
  mov ecx,[cursor_x]
  imul ecx,[cell_w]
  add ecx,PAD
  mov r8d,[cursor_y]
  imul r8d,[cell_h]
  add r8d,[ascent]
  add r8d,PAD
  lea r9,[cursor_glyph]
  mov [stack_save],rsp
  and rsp,-16
  sub rsp,16
  mov qword [rsp],1
  call XftDrawString32
  mov rsp,[stack_save]
.flush:
  mov rdi,[dpy]
  ccall XFlush
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

; Mark previous and current cursor rows when position changes.
check_cursor:
  mov eax,[cursor_x]
  cmp eax,[old_cx]
  jne .moved
  mov eax,[cursor_y]
  cmp eax,[old_cy]
  jne .moved
  ret
.moved:
  mov eax,[old_cy]
  call mark_row
  mov eax,[cursor_y]
  call mark_row
  mov eax,[cursor_x]
  mov [old_cx],eax
  mov eax,[cursor_y]
  mov [old_cy],eax
  ret

; X11 event queue: process all pending before polling again.
drain_x_events:
  push rbx
.loop:
  mov rdi,[dpy]
  ccall XPending
  test eax,eax
  jle .done
  mov rdi,[dpy]
  lea rsi,[event]
  ccall XNextEvent
  mov eax,dword [event]
  cmp eax,KeyPress
  je .key
  cmp eax,Expose
  je .expose
  cmp eax,ConfigureNotify
  je .config
  cmp eax,ButtonPress
  je .press
  cmp eax,ButtonRelease
  je .release
  cmp eax,MotionNotify
  je .motion
  cmp eax,SelectionRequest
  je .selection_req
  cmp eax,SelectionNotify
  je .selection_notify
  cmp eax,ClientMessage
  je .client
  jmp .loop
.key:
  call handle_key
  jmp .loop
.expose:
  call invalidate_all
  jmp .loop
.config:
  call handle_resize
  jmp .loop
.press:
  call handle_button_press
  jmp .loop
.release:
  call handle_button_release
  jmp .loop
.motion:
  call handle_motion
  jmp .loop
.selection_req:
  call handle_selection_request
  jmp .loop
.selection_notify:
  call handle_selection_notify
  jmp .loop
.client:
  mov rax,qword [event+56]
  cmp rax,[wm_delete]
  jne .loop
  mov edi,0
  ccall _exit
.done:
  pop rbx
  ret

handle_resize:
  mov eax,dword [event+56]
  cmp eax,[width]
  jne .different
  mov eax,dword [event+60]
  cmp eax,[height]
  je .end
.different:
  mov eax,dword [event+56]
  mov [width],eax
  mov eax,dword [event+60]
  mov [height],eax
  mov eax,[width]
  sub eax,PAD*2
  xor edx,edx
  div dword [cell_w]
  cmp eax,1
  jge .width_nonzero
  mov eax,1
.width_nonzero:
  cmp eax,MAXCOL
  jle .width_ok
  mov eax,MAXCOL
.width_ok:
  mov ebx,eax
  mov eax,[height]
  sub eax,PAD*2
  xor edx,edx
  div dword [cell_h]
  cmp eax,1
  jge .height_nonzero
  mov eax,1
.height_nonzero:
  cmp eax,MAXROW
  jle .height_ok
  mov eax,MAXROW
.height_ok:
  cmp eax,[rows]
  jne .changed
  cmp ebx,[cols]
  je .end
.changed:
  mov [rows],eax
  mov [cols],ebx
  mov ecx,eax
  dec ecx
  mov [bottom],ecx
  mov dword [top],0
  call clamp_cursor
  mov eax,[rows]
  mov word [winsize],ax
  mov eax,[cols]
  mov word [winsize+2],ax
  mov edi,[ptyfd]
  mov esi,TIOCSWINSZ
  lea rdx,[winsize]
  ccall ioctl
  call invalidate_all
.end:
  ret

; Scrollback wheel / keyboard; edi = signed delta in rows (positive up).
view_scroll:
  cmp byte [altscreen],0
  jne .done
  mov eax,[view]
  add eax,edi
  cmp eax,0
  jge .above_zero
  xor eax,eax
.above_zero:
  cmp eax,[histcount]
  jle .within
  mov eax,[histcount]
.within:
  cmp eax,[view]
  je .done
  mov [view],eax
  call invalidate_all
.done:
  ret

; Scroll to the live prompt for real keyboard input (but not for scroll
; navigation, copy, or mouse reporting), then write to the child PTY.
key_escape:
  cmp dword [view],0
  je .write
  mov dword [view],0
  call invalidate_all
.write:
  jmp pty_write

handle_key:
  lea rdi,[event]
  lea rsi,[keybuf]
  mov edx,128
  lea rcx,[keysym]
  xor r8d,r8d
  ccall XLookupString
  mov ebx,eax
  mov eax,dword [event+80]
  mov [key_state],eax
  ; Ctrl+Shift+C/V: primary selection to clipboard/paste.
  and eax,ShiftMask+ControlMask
  cmp eax,ShiftMask+ControlMask
  jne .normal
  mov eax,dword [keysym]
  and eax,0dfh
  cmp eax,'C'
  je .copy
  cmp eax,'V'
  je .paste
.normal:
  mov eax,dword [keysym]
  cmp eax,0ff55h
  je .pageup
  cmp eax,0ff56h
  je .pagedown
  cmp eax,0ff50h
  je .home
  cmp eax,0ff57h
  je .end
  cmp eax,0ff51h
  je .left
  cmp eax,0ff52h
  je .up
  cmp eax,0ff53h
  je .right
  cmp eax,0ff54h
  je .down
  cmp eax,0ffffh
  je .delete
  cmp eax,0ff63h
  je .insert
  cmp eax,0ff08h
  je .backspace
  cmp eax,0ff0dh
  je .return
  cmp eax,0ff09h
  je .tab
  cmp eax,0ff1bh
  je .esc
  cmp ebx,0
  jle .done
  test dword [key_state],Mod1Mask
  jz .plain
  mov byte [onechar],27
  lea rsi,[onechar]
  mov edx,1
  call key_escape
.plain:
  lea rsi,[keybuf]
  mov edx,ebx
  jmp key_escape
.copy:
  call copy_selection
  ret
.paste:
  call request_paste
  ret
 .pageup:
  ; Ordinary PgUp/PgDn navigate main-buffer history. Ctrl+PgUp/PgDn
  ; still go to the application, as do unmodified keys in alternate screen.
  cmp byte [altscreen],0
  jne .send_pageup
  test dword [key_state],ControlMask
  jnz .send_pageup
  mov edi,[rows]
  sub edi,2
  call view_scroll
  ret
.send_pageup:
  lea rsi,[seq_pageup]
  mov edx,4
  jmp key_escape
 .pagedown:
  cmp byte [altscreen],0
  jne .send_pagedown
  test dword [key_state],ControlMask
  jnz .send_pagedown
  mov edi,[rows]
  neg edi
  add edi,2
  call view_scroll
  ret
.send_pagedown:
  lea rsi,[seq_pagedown]
  mov edx,4
  jmp key_escape
.home:
  test dword [key_state],ShiftMask
  jz .send_home
  mov edi,[histcount]
  call view_scroll
  ret
.send_home:
  lea rsi,[seq_home]
  mov edx,3
  jmp key_escape
.end:
  test dword [key_state],ShiftMask
  jz .send_end
  mov edi,-1000000
  call view_scroll
  ret
.send_end:
  lea rsi,[seq_end]
  mov edx,3
  jmp key_escape
.left:
  lea rsi,[seq_left]
  jmp .arrow
.up:
  lea rsi,[seq_up]
  jmp .arrow
.right:
  lea rsi,[seq_right]
  jmp .arrow
.down:
  lea rsi,[seq_down]
.arrow:
  cmp byte [app_cursor],0
  je .normal_arrow
  ; Convert ESC [ A to ESC O A without rewriting the constants.
  mov byte [arrow_buf],27
  mov byte [arrow_buf+1],'O'
  mov al,[rsi+2]
  mov [arrow_buf+2],al
  lea rsi,[arrow_buf]
.normal_arrow:
  mov edx,3
  jmp key_escape
.delete:
  lea rsi,[seq_delete]
  mov edx,4
  jmp key_escape
.insert:
  lea rsi,[seq_insert]
  mov edx,4
  jmp key_escape
.backspace:
  mov byte [onechar],127
  lea rsi,[onechar]
  mov edx,1
  jmp key_escape
.return:
  mov byte [onechar],13
  lea rsi,[onechar]
  mov edx,1
  jmp key_escape
.tab:
  mov byte [onechar],9
  lea rsi,[onechar]
  mov edx,1
  jmp key_escape
.esc:
  mov byte [onechar],27
  lea rsi,[onechar]
  mov edx,1
  jmp key_escape
.done:
  ret

; Mouse wheel scrolling and basic X10/SGR mouse reporting.
handle_button_press:
  mov eax,dword [event+84]         ; XButtonEvent button number
  cmp eax,4
  jne .not_up
  cmp byte [mouse_mode],0
  je .wheel_up
  test dword [event+80],ShiftMask
  jnz .wheel_up
  mov edi,64
  mov esi,'M'
  jmp mouse_report
.wheel_up:
  mov edi,3
  jmp view_scroll
.not_up:
  cmp eax,5
  jne .not_down
  cmp byte [mouse_mode],0
  je .wheel_down
  test dword [event+80],ShiftMask
  jnz .wheel_down
  mov edi,65
  mov esi,'M'
  jmp mouse_report
.wheel_down:
  mov edi,-3
  jmp view_scroll
.not_down:
  cmp byte [mouse_mode],0
  je .normal_mouse
  test dword [event+80],ShiftMask
  jnz .normal_mouse
  cmp eax,1
  jne .app_middle
  xor edi,edi
  mov esi,'M'
  jmp mouse_report
.app_middle:
  cmp eax,2
  jne .app_right
  mov edi,1
  mov esi,'M'
  jmp mouse_report
.app_right:
  cmp eax,3
  jne .done
  mov edi,2
  mov esi,'M'
  jmp mouse_report
.normal_mouse:
  cmp eax,1
  jne .middle
  call mouse_cell
  mov [sel_anchor_x],edx
  sub ecx,[view]          ; store buffer-relative Y, not viewport Y
  mov [sel_anchor_y],ecx
  mov [sel_end_x],edx
  mov [sel_end_y],ecx
  mov byte [selecting],1
  mov byte [selection_active],1
  call invalidate_all
  ret
.middle:
  cmp eax,2
  jne .done
  call request_paste
.done:
  ret

handle_button_release:
  cmp byte [mouse_mode],0
  je .normal_release
  test dword [event+80],ShiftMask
  jnz .normal_release
  cmp dword [event+84],1
  jne .done
  mov edi,3
  mov esi,'m'
  jmp mouse_report
.normal_release:
  cmp dword [event+84],1
  jne .done
  cmp byte [selecting],0
  je .done
  mov byte [selecting],0
  call mouse_cell
  mov [sel_end_x],edx
  sub ecx,[view]
  mov [sel_end_y],ecx
  call copy_selection
  call invalidate_all
.done:
  ret

handle_motion:
  test dword [event+80],256 ; Button1Mask
  jz .done
  cmp byte [mouse_mode],0
  je .normal_motion
  test dword [event+80],ShiftMask
  jnz .normal_motion
  mov edi,32
  mov esi,'M'
  jmp mouse_report
.normal_motion:
  cmp byte [selecting],0
  je .done
  call mouse_cell
  sub ecx,[view]
  cmp [sel_end_x],edx
  jne .changed
  cmp [sel_end_y],ecx
  je .done
.changed:
  mov [sel_end_x],edx
  mov [sel_end_y],ecx
  call invalidate_all
.done:
  ret

; Mouse reports: X10 (ESC[M + 3 bytes) or SGR 1006 (ESC[<b;x;yM).
; edi=button code, esi='M' pressed or 'm' released.
mouse_report:
  push rbx
  push r15
  mov [mouse_button_tmp],edi
  mov [mouse_suffix_tmp],sil
  call mouse_cell
  mov [mouse_col_tmp],edx
  mov [mouse_row_tmp],ecx
  lea r15,[mouse_buffer]
  mov byte [r15],27
  mov byte [r15+1],'['
  cmp byte [mouse_sgr],0
  jne .sgr
  mov byte [r15+2],'M'
  mov eax,[mouse_button_tmp]
  add eax,32
  mov [r15+3],al
  mov eax,[mouse_col_tmp]
  add eax,33
  mov [r15+4],al
  mov eax,[mouse_row_tmp]
  add eax,33
  mov [r15+5],al
  mov edx,6
  jmp .send
.sgr:
  add r15,2
  mov byte [r15],'<'
  inc r15
  mov eax,[mouse_button_tmp]
  call append_dec
  mov byte [r15],';'
  inc r15
  mov eax,[mouse_col_tmp]
  inc eax
  call append_dec
  mov byte [r15],';'
  inc r15
  mov eax,[mouse_row_tmp]
  inc eax
  call append_dec
  mov al,[mouse_suffix_tmp]
  mov [r15],al
  inc r15
  lea rax,[mouse_buffer]
  sub r15,rax
  mov rdx,r15
.send:
  lea rsi,[mouse_buffer]
  call pty_write
  pop r15
  pop rbx
  ret

 ; Append decimal unsigned eax (0..9999) at r15, update r15.
append_dec:
  push rbx
  push r12
  mov ebx,10
  xor r12d,r12d
.extract:
  xor edx,edx
  div ebx
  push rdx
  inc r12d
  test eax,eax
  jnz .extract
.emit:
  pop rax
  add al,'0'
  mov [r15],al
  inc r15
  dec r12d
  jnz .emit
  pop r12
  pop rbx
  ret

; coordinates from X event -> edx=col,ecx=row
mouse_cell:
  mov eax,dword [event+64]
  sub eax,PAD
  jns .nonnegative_x
  xor eax,eax
.nonnegative_x:
  xor edx,edx
  div dword [cell_w]
  cmp eax,[cols]
  jb .save_x
  mov eax,[cols]
  dec eax
.save_x:
  mov r8d,eax
  mov eax,dword [event+68]
  sub eax,PAD
  jns .nonnegative_y
  xor eax,eax
.nonnegative_y:
  xor edx,edx
  div dword [cell_h]
  cmp eax,[rows]
  jb .save_y
  mov eax,[rows]
  dec eax
.save_y:
  mov ecx,eax
  mov edx,r8d
  ret

; Selected text is converted to UTF-8 and owned as both CLIPBOARD and PRIMARY.
; Selected endpoints are signed offsets from the live ring head.
; Read the selected content even when the viewport has moved since dragging.
copy_selection:
  cmp byte [selection_active],0
  je .nothing
  push rbx
  mov eax,[sel_anchor_y]
  mov edx,[sel_end_y]
  mov ecx,[sel_anchor_x]
  mov ebx,[sel_end_x]
  cmp eax,edx
  jl .ordered
  jg .swap
  cmp ecx,ebx
  jle .ordered
.swap:
  xchg eax,edx
  xchg ecx,ebx
.ordered:
  mov [select_y0],eax
  mov [select_y1],edx
  mov [select_x0],ecx
  mov [select_x1],ebx
  lea r15,[clip_buffer]
  mov r13d,eax
.row:
  cmp r13d,[select_y1]
  jg .finish
  mov eax,r13d
  call rowaddr
  mov r14,rax
  xor r12d,r12d
  cmp r13d,[select_y0]
  jne .colstart
  mov r12d,[select_x0]
.colstart:
  mov ebx,[cols]
  dec ebx
  cmp r13d,[select_y1]
  jne .colend
  mov ebx,[select_x1]
.colend:
  ; Trim trailing blanks using the cell codepoint, not pasted padding.
.trim:
  cmp ebx,r12d
  jl .nextline
  mov eax,[r14+rbx*8]
  cmp eax,' '
  ja .characters
  dec ebx
  jmp .trim
.characters:
  cmp r12d,ebx
  jg .nextline
  ; Reserve 4 bytes for any UTF-8 rune, plus 1 for a row separator.
  ; Selections spanning thousands of scrollback lines used to overwrite
  ; clip_buffer, adjacent state, and the alternate-screen buffer.
  lea rax,[clip_buffer+CLIPCAP-5]
  cmp r15,rax
  jae .finish
  mov edi,[r14+r12*8]
  test edi,edi
  jz .skip_codepoint
  call utf8_append
.skip_codepoint:
  inc r12d
  jmp .characters
.nextline:
  cmp r13d,[select_y1]
  je .finish
  lea rax,[clip_buffer+CLIPCAP-5]
  cmp r15,rax
  jae .finish
  mov byte [r15],10
  inc r15
  inc r13d
  jmp .row
.finish:
  lea rax,[clip_buffer]
  sub r15,rax
  mov [clip_len],r15d
  mov rdi,[dpy]
  mov rsi,[clipboard]
  mov rdx,[win]
  xor ecx,ecx
  ccall XSetSelectionOwner
  mov rdi,[dpy]
  mov esi,1                   ; XA_PRIMARY
  mov rdx,[win]
  xor ecx,ecx
  ccall XSetSelectionOwner
  pop rbx
.nothing:
  ret

; edi = Unicode codepoint; append to clip_buffer through r15.
utf8_append:
  cmp edi,7fh
  ja .two
  mov [r15],dil
  inc r15
  ret
.two:
  cmp edi,7ffh
  ja .three
  mov eax,edi
  shr eax,6
  or eax,0c0h
  mov [r15],al
  mov eax,edi
  and eax,63
  or eax,80h
  mov [r15+1],al
  add r15,2
  ret
.three:
  cmp edi,0ffffh
  ja .four
  mov eax,edi
  shr eax,12
  or eax,0e0h
  mov [r15],al
  mov eax,edi
  shr eax,6
  and eax,63
  or eax,80h
  mov [r15+1],al
  mov eax,edi
  and eax,63
  or eax,80h
  mov [r15+2],al
  add r15,3
  ret
.four:
  mov eax,edi
  shr eax,18
  or eax,0f0h
  mov [r15],al
  mov eax,edi
  shr eax,12
  and eax,63
  or eax,80h
  mov [r15+1],al
  mov eax,edi
  shr eax,6
  and eax,63
  or eax,80h
  mov [r15+2],al
  mov eax,edi
  and eax,63
  or eax,80h
  mov [r15+3],al
  add r15,4
  ret

request_paste:
  ; The paste is asynchronous; return to the live prompt on request.
  cmp dword [view],0
  je .live
  mov dword [view],0
  call invalidate_all
.live:
  mov rdi,[dpy]
  mov rsi,[clipboard]
  mov rdx,[utf8_atom]
  mov rcx,[paste_atom]
  mov r8,[win]
  xor r9d,r9d
  ccall XConvertSelection
  ret

handle_selection_request:
  ; Copy fields before overwriting XEvent with SelectionNotify.
  mov rax,qword [event+40]
  mov [req_window],rax
  mov rax,qword [event+48]
  mov [req_selection],rax
  mov rax,qword [event+56]
  mov [req_target],rax
  mov rax,qword [event+64]
  mov [req_property],rax
  mov rax,qword [event+72]
  mov [req_time],rax
  test qword [req_property],-1
  jnz .has_property
  mov rax,[req_target]
  mov [req_property],rax
.has_property:
  mov rax,[req_target]
  cmp rax,[utf8_atom]
  je .text
  cmp rax,31                   ; XA_STRING
  je .text
  cmp rax,[targets_atom]
  je .targets
  mov qword [req_property],0
  jmp .notify
.text:
  mov rdi,[dpy]
  mov rsi,[req_window]
  mov rdx,[req_property]
  mov rcx,[req_target]
  mov r8d,8
  xor r9d,r9d
  lea rax,[clip_buffer]
  mov [stack_save],rsp
  and rsp,-16
  sub rsp,32
  mov [rsp],rax               ; data
  mov eax,[clip_len]
  mov [rsp+8],rax             ; elements
  call XChangeProperty
  mov rsp,[stack_save]
  jmp .notify
.targets:
  mov rax,[utf8_atom]
  mov [atom_pair],rax
  mov rax,[targets_atom]
  mov [atom_pair+8],rax
  mov rdi,[dpy]
  mov rsi,[req_window]
  mov rdx,[req_property]
  mov ecx,4                   ; XA_ATOM
  mov r8d,32
  xor r9d,r9d
  lea rax,[atom_pair]
  mov [stack_save],rsp
  and rsp,-16
  sub rsp,32
  mov [rsp],rax
  mov qword [rsp+8],2
  call XChangeProperty
  mov rsp,[stack_save]
.notify:
  lea rdi,[event]
  xor eax,eax
  mov ecx,24
  rep stosq
  mov dword [event],SelectionNotify
  mov rax,[dpy]
  mov qword [event+24],rax
  mov rax,[req_window]
  mov qword [event+32],rax
  mov rax,[req_selection]
  mov qword [event+40],rax
  mov rax,[req_target]
  mov qword [event+48],rax
  mov rax,[req_property]
  mov qword [event+56],rax
  mov rax,[req_time]
  mov qword [event+64],rax
  mov rdi,[dpy]
  mov rsi,[req_window]
  xor edx,edx
  xor ecx,ecx
  lea r8,[event]
  ccall XSendEvent
  ret

handle_selection_notify:
  cmp qword [event+56],0
  je .done
  mov rdi,[dpy]
  mov rsi,[win]
  mov rdx,[paste_atom]
  xor ecx,ecx
  mov r8d,16384               ; maximum 64k bytes
  mov r9d,1                   ; delete=True
  mov [stack_save],rsp
  and rsp,-16
  sub rsp,64
  mov qword [rsp],0           ; AnyPropertyType
  lea rax,[prop_type]
  mov [rsp+8],rax
  lea rax,[prop_format]
  mov [rsp+16],rax
  lea rax,[prop_count]
  mov [rsp+24],rax
  lea rax,[prop_after]
  mov [rsp+32],rax
  lea rax,[prop_data]
  mov [rsp+40],rax
  call XGetWindowProperty
  mov rsp,[stack_save]
  test eax,eax
  jne .done
  cmp qword [prop_data],0
  je .done
  cmp byte [bracketed],0
  je .paste_text
  lea rsi,[bracket_start]
  mov edx,6
  call pty_write
.paste_text:
  mov rsi,[prop_data]
  mov rdx,[prop_count]
  test rdx,rdx
  jz .paste_end
  call pty_write
.paste_end:
  cmp byte [bracketed],0
  je .free
  lea rsi,[bracket_end]
  mov edx,6
  call pty_write
.free:
  mov rdi,[prop_data]
  ccall XFree
  mov qword [prop_data],0
.done:
  ret

section '.data' writeable
  title db 'fastst - FASM X11 terminal',0
  font_spec db 'monospace:pixelsize=15:antialias=true',0
  fallback_spec db 'sans:lang=ja:pixelsize=15:antialias=true',0
  empty db 0
  locale_utf8 db 'C.UTF-8',0
  error_x db 'fastst: cannot connect to X server (DISPLAY)',10,0
  error_font db 'fastst: unable to load Xft font',10,0
  wm_del_name db 'WM_DELETE_WINDOW',0
  clipboard_name db 'CLIPBOARD',0
  utf8_name db 'UTF8_STRING',0
  paste_name db 'FASTST_PASTE',0
  targets_name db 'TARGETS',0
  term_name db 'TERM',0
  term_value db 'xterm-256color',0
  color_name db 'COLORTERM',0
  color_value db '256color',0
  shell_name db 'SHELL',0
  fallback_shell db '/bin/sh',0
  opt_e db '-e',0
  opt_server db '--server',0
  opt_client db '--client',0
  display_env db 'DISPLAY',0
  sock_pattern db 'fastst-v3:%u:%s',0
  server_executable db 'fastst',0
  error_server db 'fastst: no preconnected server; run fastst --server first',10,0
  error_bind db 'fastst: could not start preconnected server (already running?)',10,0
  server_handoff db 65
  align 8
  server_dummy_argv dq server_executable,0
  cube db 0,95,135,175,215,255
  align 4
  ansi16 dd 0x101216,0xcd3131,0x29a753,0xd8ad3a
         dd 0x3c75cc,0xac62c0,0x32a3a3,0xc4c6ca
         dd 0x595b64,0xff6b6b,0x63d88e,0xffd766
         dd 0x7ea8ff,0xe89aee,0x73d5e6,0xffffff
  seq_up db 27,'[A'
  seq_down db 27,'[B'
  seq_right db 27,'[C'
  seq_left db 27,'[D'
  seq_home db 27,'[H'
  seq_end db 27,'[F'
  seq_pageup db 27,'[5~'
  seq_pagedown db 27,'[6~'
  seq_insert db 27,'[2~'
  seq_delete db 27,'[3~'
  bracket_start db 27,'[200~'
  bracket_end db 27,'[201~'
  status_ok db 27,'[0n'
  device_id db 27,'[?6c'

; The ring buffers below use `align 4096`. For ELF64 objects, FASM
; requires the section alignment to be at least the largest in-section align.
section '.bss' writeable align 4096
  align 16
  preload_worker rb 1
  align 8
  server_sock rd 1
  server_client_sock rd 1
  server_uid rd 1
  server_remaining rd 1
  server_cwd_len rd 1
  server_env_count rd 1
  server_credlen rd 1
  server_creds rb 12
  server_pipe rd 2
  preload_ready_pipe rd 2
  server_pollfd rb 8
  server_events rb 64
  tmp_display rq 1
  server_argv rq PRELOAD_MAXARGS+2
  server_env_argv rq 256
  server_addr rb 110
  request_buffer rb PRELOAD_PACKET
  dpy rq 1
  win rq 1
  root rq 1
  visual rq 1
  cmap rq 1
  font rq 1
  fallback_cjk rq 1
  font_worker_tid rq 1
  font_worker_status rd 1
  unicode_font_tmp rq 1
  draw rq 1
  gc rq 1
  clipboard rq 1
  utf8_atom rq 1
  paste_atom rq 1
  targets_atom rq 1
  wm_delete rq 1
  atom_one rq 1
  atom_pair rq 2
  req_window rq 1
  req_selection rq 1
  req_target rq 1
  req_property rq 1
  req_time rq 1
  prop_type rq 1
  prop_format rd 1
  prop_count rq 1
  prop_after rq 1
  prop_data rq 1
  stack_save rq 1
  cmd_argv rq 1
  shell_ptr rq 1
  sh_argv rq 2
  cmd_argc rd 1
  screen rd 1
  width rd 1
  height rd 1
  cell_w rd 1
  cell_h rd 1
  ascent rd 1
  cols rd 1
  rows rd 1
  cursor_x rd 1
  cursor_y rd 1
  old_cx rd 1
  old_cy rd 1
  main_x rd 1
  main_y rd 1
  main_saved_x rd 1
  main_saved_y rd 1
  main_attr rd 1
  main_top rd 1
  main_bottom rd 1
  main_view rd 1
  main_cursor_show rd 1
  main_wrap_enable rd 1
  main_wrap_next rb 1
  main_insert_mode rb 1
  main_dec_graphics rb 1
  main_app_cursor rb 1
  main_bracketed rb 1
  main_mouse_mode rb 1
  main_mouse_sgr rb 1
  saved_x rd 1
  saved_y rd 1
  top rd 1
  bottom rd 1
  head rd 1
  histcount rd 1
  view rd 1
  curattr rd 1
  cursor_show rd 1
  wrap_enable rd 1
  glyph_width rd 1
  paint_y rd 1
  run_len rd 1
  parse_state rd 1
  utf_need rd 1
  utf_code rd 1
  csi_count rd 1
  csi_args rd 16
  osc_len rd 1
  erase_first rd 1
  erase_last rd 1
  saved_top rd 1
  cmdarg rd 1
  ptyfd rd 1
  childpid rd 1
  xfd rd 1
  key_state rd 1
  keysym rq 1
  clip_len rd 1
  selection_draw_x0 rd 1
  selection_draw_x1 rd 1
  mouse_button_tmp rd 1
  mouse_col_tmp rd 1
  mouse_row_tmp rd 1
  mouse_suffix_tmp rb 1
  sel_anchor_x rd 1
  sel_anchor_y rd 1
  sel_end_x rd 1
  sel_end_y rd 1
  select_x0 rd 1
  select_y0 rd 1
  select_x1 rd 1
  select_y1 rd 1
  mode_on rb 1
  final_byte rb 1
  dirty_any rb 1
  altscreen rb 1
  selecting rb 1
  selection_active rb 1
  app_cursor rb 1
  insert_mode rb 1
  bracketed rb 1
  mouse_mode rb 1
  mouse_sgr rb 1
  csi_private rb 1
  csi_ignore rb 1
  wrap_next rb 1
  dec_graphics rb 1
  onechar rb 1
  arrow_buf rb 4
  cursor_glyph rd 1
  keybuf rb 128
  mouse_buffer rb 64
  winsize rb 8
  pollfds rb 16
  event rb 192
  render_color rb 8
  color_ready rb 256
  align 16
  colormap_xft rb 4096
  dirty rb MAXROW
  glyphs rd MAXCOL
  osc_buffer rb 512
  reply_buf rb 64
  iobuf rb 32768
  clip_buffer rb CLIPCAP
  align 4096
  alternate rb MAXROW*ROWB
  history rb RING*ROWB

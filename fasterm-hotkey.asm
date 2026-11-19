; fasterm-hotkey: resident X11 hotkey activating the preforked PTY child.
; Press Ctrl+Alt+Return to open the server's default shell.
; One persistent AF_UNIX SOCK_SEQPACKET connection is prepared BEFORE input;
; keypress => one 16-byte send, then re-arm a connection for next use.
; This intentionally uses the server's environment/cwd, not caller-specific ones.
; Build: fasm fasterm-hotkey.asm fasterm-hotkey.o && cc -no-pie -s -o fasterm-hotkey fasterm-hotkey.o -lX11
format ELF64
include 'include/protocol.inc'
include 'include/sysv64.inc'
include 'include/x11.inc'
public main
extrn XOpenDisplay
extrn XDefaultScreen
extrn XRootWindow
extrn XKeysymToKeycode
extrn XGrabKey
extrn XSync
extrn XNextEvent
extrn socket
extrn connect
extrn send
extrn close
extrn geteuid
extrn getenv
extrn snprintf

section '.text' executable
main:
  push rbp
  mov rbp,rsp
  mov word [sockaddr+SocketAddr.family],AF_UNIX
  lea rdi,[display_name]
  ccall getenv
  test rax,rax
  jnz .have_display
  lea rax,[empty]
.have_display:
  mov [display_val],rax
  ccall geteuid
  mov ecx,eax
  lea rdi,[sockaddr+SocketAddr.name]
  mov esi,SOCKET_NAME_CAP
  lea rdx,[sock_pattern]
  mov r8,[display_val]
  xor eax,eax
  ccall snprintf
  xor edi,edi
  ccall XOpenDisplay
  test rax,rax
  jz .fail
  mov [dpy],rax
  mov rdi,rax
  ccall XDefaultScreen
  mov esi,eax
  mov rdi,[dpy]
  ccall XRootWindow
  mov [root],rax
  mov rdi,[dpy]
  mov esi,XK_Return              ; X11 Return KeySym
  ccall XKeysymToKeycode
  test eax,eax
  jz .fail
  mov [keycode],eax
  ; Passive grabs including caps/num lock states. If WM owns this shortcut,
  ; Xlib will issue BadAccess: choose another key combo in the source.
  xor r12d,r12d
.grab:
  mov rdi,[dpy]
  mov esi,[keycode]
  mov edx,dword [modifiers+r12*4]
  mov rcx,[root]
  xor r8d,r8d                   ; owner_events=False
  mov r9d,1                     ; GrabModeAsync pointer
  mov rax,rsp
  and rsp,-16
  sub rsp,32
  mov qword [rsp],1            ; GrabModeAsync keyboard (7th arg)
  mov [rsp+16],rax
  call XGrabKey
  mov rsp,[rsp+16]
  inc r12d
  cmp r12d,4
  jl .grab
  mov rdi,[dpy]
  xor esi,esi
  ccall XSync
  ; Reserve a live worker connection before the first keypress.
  call connect_worker
.wait:
  mov rdi,[dpy]
  lea rsi,[event]
  ccall XNextEvent
  cmp dword [event],KeyPress
  jne .wait
  mov eax,dword [event+XKey.time]     ; XKeyEvent.time in milliseconds
  mov edx,eax
  sub eax,[last_press]
  cmp eax,125
  jb .wait                     ; suppress auto-repeat
  mov [last_press],edx
  cmp dword [client_fd],0
  jge .send
  call connect_worker
  cmp dword [client_fd],0
  jl .wait
.send:
  mov edi,[client_fd]
  lea rsi,[instant_request]
  mov edx,PRELOAD_HEADER_BYTES
  mov ecx,MSG_NOSIGNAL
  ccall send
  mov edi,[client_fd]
  ccall close
  mov dword [client_fd],-1
  ; Reconnect after launch, NOT while the keypress is being handled.
  call connect_worker
  jmp .wait
.fail:
  mov eax,1
  leave
  ret
connect_worker:
  mov edi,AF_UNIX
  mov esi,SOCK_SEQPACKET_CLOEXEC
  xor edx,edx
  ccall socket
  test eax,eax
  js .fail
  mov [client_fd],eax
  mov edi,eax
  lea rsi,[sockaddr]
  mov edx,SOCKET_ADDR_BYTES
  ccall connect
  test eax,eax
  jns .good
  mov edi,[client_fd]
  ccall close
.fail:
  mov dword [client_fd],-1
.good:
  ret

section '.data' writeable
sock_pattern db 'fasterm-v3:%u:%s',0
display_name db 'DISPLAY',0
empty db 0
; Ctrl+Alt+Return, including CapsLock / NumLock combinations.
modifiers dd ControlMask+Mod1Mask, ControlMask+Mod1Mask+LockMask
          dd ControlMask+Mod1Mask+Mod2Mask, ControlMask+Mod1Mask+LockMask+Mod2Mask
instant_request dd PRELOAD_MAGIC,0,-1,PRELOAD_HEADER_BYTES
client_fd dd -1
section '.bss' writeable align 16
sockaddr rb SOCKET_ADDR_BYTES
align 16
event rb XEVENT_BYTES
dpy rq 1
root rq 1
display_val rq 1
keycode rd 1
last_press rd 1

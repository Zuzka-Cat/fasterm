; fastst-hotkey: resident X11 hotkey activating the preforked PTY child.
; Press Ctrl+Alt+Return to open the server's default shell.
; One persistent AF_UNIX SOCK_SEQPACKET connection is prepared BEFORE input;
; keypress => one 16-byte send, then re-arm a connection for next use.
; This intentionally uses the server's environment/cwd, not caller-specific ones.
; Build: fasm fastst-hotkey.asm fastst-hotkey.o && cc -no-pie -s -o fastst-hotkey fastst-hotkey.o -lX11
format ELF64
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

macro ccall function {
  push rbp
  mov rbp,rsp
  and rsp,-16
  call function
  mov rsp,rbp
  pop rbp
}
SOCK_SEQPACKET_CLOEXEC = 80005h
MSG_NOSIGNAL = 4000h
PRELOAD_MAGIC = 33545346h
KeyPress = 2
section '.text' executable
main:
  push rbp
  mov rbp,rsp
  mov word [sockaddr],1
  lea rdi,[display_name]
  ccall getenv
  test rax,rax
  jnz .have_display
  lea rax,[empty]
.have_display:
  mov [display_val],rax
  ccall geteuid
  mov ecx,eax
  lea rdi,[sockaddr+3]
  mov esi,96
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
  mov esi,0ff0dh               ; XK_Return
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
  mov eax,dword [event+56]     ; XKeyEvent.time in milliseconds
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
  mov edx,16
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
  mov edi,1
  mov esi,SOCK_SEQPACKET_CLOEXEC
  xor edx,edx
  ccall socket
  test eax,eax
  js .fail
  mov [client_fd],eax
  mov edi,eax
  lea rsi,[sockaddr]
  mov edx,110
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
sock_pattern db 'fastst-v3:%u:%s',0
display_name db 'DISPLAY',0
empty db 0
; modifiers dd 12,14,28,30   ; Ctrl+Alt, plus LockMask/Mod2Mask variations
modifiers dd 8,10,24,26    ; Alt+Enter, with CapsLock/NumLock variations
instant_request dd PRELOAD_MAGIC,0,-1,16
client_fd dd -1
section '.bss' writeable align 16
sockaddr rb 110
align 16
event rb 192
dpy rq 1
root rq 1
display_val rq 1
keycode rd 1
last_press rd 1

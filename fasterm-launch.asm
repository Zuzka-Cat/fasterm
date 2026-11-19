; fasterm-launch -- tiny, libc-free Linux x86-64 launcher for a preconnected
; fasterm worker.  FASM ELF64 object, linked as a static ET_EXEC (not PIE).
; Usage: fasterm --server &       # once per DISPLAY
;        fasterm-launch [-e command args...]
; The request is accepted only from the same Unix uid via SO_PEERCRED.
format ELF64
include 'include/protocol.inc'
public _start

; Linux x86-64 syscall numbers (this launcher deliberately does not use libc).
SYS_WRITE   = 1
SYS_SOCKET  = 41
SYS_CONNECT = 42
SYS_SENDTO  = 44
SYS_EXIT    = 60
SYS_GETCWD  = 79
SYS_GETEUID = 107

section '.text' executable
_start:
  xor ebp,ebp
  mov r13,[rsp]                   ; argc (including our executable)
  lea r14,[rsp+8]                 ; argv
  cmp r13,PRELOAD_MAXARGS+1
  ja error_exit
  lea r15,[r14+r13*8+8]          ; envp after argv NULL
  mov [env_start],r15
  xor r12d,r12d                   ; optional DISPLAY value
  mov r8,3d59414c50534944h      ; 'DISPLAY=' little-endian
.env_loop:
  mov rax,[r15]
  test rax,rax
  jz .env_done
  cmp qword [rax],r8
  je .found_display
  add r15,8
  jmp .env_loop
.found_display:
  lea r12,[rax+8]
.env_done:
  mov word [sockaddr+SocketAddr.family],AF_UNIX ; Linux abstract socket
  lea rdi,[sockaddr+SocketAddr.name]
  lea rsi,[sock_prefix]
  mov ecx,sock_prefix_len
  rep movsb
  ; Render geteuid() as ASCII decimal, identical to server's snprintf %u.
  mov eax,SYS_GETEUID
  syscall
  mov r9d,10
  lea rsi,[digits+12]
  xor r10d,r10d
.digit:
  xor edx,edx
  div r9d
  dec rsi
  add dl,48
  mov [rsi],dl
  inc r10d
  test eax,eax
  jnz .digit
  mov ecx,r10d
  rep movsb
  mov byte [rdi],58              ; ':'
  inc rdi
  test r12,r12
  jz .no_display
  ; Server reserves 96 bytes for entire abstract name, including NUL.
  lea r11,[sockaddr+SocketAddr.name+SOCKET_NAME_CAP-1]
.copy_display:
  cmp rdi,r11
  jae .no_display
  mov al,[r12]
  test al,al
  jz .no_display
  mov [rdi],al
  inc r12
  inc rdi
  jmp .copy_display
.no_display:
  mov dword [packet+Request.magic],PRELOAD_MAGIC
  mov rax,r13
  dec eax
  mov dword [packet+Request.argc],eax
  ; cwd is capped at 1024 bytes; empty if getcwd fails.
  mov eax,SYS_GETCWD
  lea rdi,[packet+Request.cwd]
  mov esi,PRELOAD_CWD_BYTES
  syscall
  test rax,rax
  jle error_exit
.cwd_done:
  lea rdi,[packet+PRELOAD_FIXED_BYTES]
  lea r11,[packet+PRELOAD_PACKET]
  lea r14,[r14+8]                ; argv[1] onward
  mov r15,r13
  dec r15
.next_arg:
  test r15,r15
  jz .copy_environment
  mov rsi,[r14]
.copy_arg:
  cmp rdi,r11
  jae error_exit
  mov al,[rsi]
  mov [rdi],al
  inc rsi
  inc rdi
  test al,al
  jnz .copy_arg
  add r14,8
  dec r15
  jmp .next_arg
.copy_environment:
  mov r14,[env_start]
  mov dword [packet+Request.envc],0
.next_env:
  mov rsi,[r14]
  test rsi,rsi
  jz .connect
  cmp dword [packet+Request.envc],PRELOAD_MAXENVS
  jae error_exit
.copy_env_byte:
  cmp rdi,r11
  jae error_exit
  mov al,[rsi]
  mov [rdi],al
  inc rsi
  inc rdi
  test al,al
  jnz .copy_env_byte
  add r14,8
  inc dword [packet+Request.envc]
  jmp .next_env
.connect:
  ; Request.length carries the exact (bounded) request size.
  lea rax,[packet]
  sub rdi,rax
  mov dword [packet+Request.length],edi
  mov r13d,edi
  mov eax,SYS_SOCKET             ; SOCK_SEQPACKET|CLOEXEC
  mov edi,AF_UNIX
  mov esi,SOCK_SEQPACKET_CLOEXEC
  xor edx,edx
  syscall
  test rax,rax
  js error_exit
  mov ebx,eax                    ; fd
  mov eax,SYS_CONNECT
  mov edi,ebx
  lea rsi,[sockaddr]
  mov edx,SOCKET_ADDR_BYTES
  syscall
  test rax,rax
  js error_exit
  lea r12,[packet]
.send:
  mov eax,SYS_SENDTO             ; MSG_NOSIGNAL
  mov edi,ebx
  mov rsi,r12
  mov edx,r13d
  mov r10d,MSG_NOSIGNAL
  xor r8d,r8d
  xor r9d,r9d
  syscall
  test rax,rax
  jle error_exit
  add r12,rax
  sub r13,rax
  jnz .send
  mov eax,SYS_EXIT
  xor edi,edi
  syscall
error_exit:
  mov eax,SYS_WRITE
  mov edi,2
  lea rsi,[error_message]
  mov edx,err_len
  syscall
  mov eax,SYS_EXIT
  mov edi,1
  syscall

section '.rodata'
sock_prefix db 'fasterm-v3:'
sock_prefix_len = $ - sock_prefix
error_message db 'fasterm-launch: no ready fasterm --server, or invalid request',10
err_len = $ - error_message

section '.bss' writeable align 16
sockaddr rb SOCKET_ADDR_BYTES
align 16
packet rb PRELOAD_PACKET
digits rb 16
env_start rq 1

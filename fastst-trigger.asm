; fastst-trigger — minimal x86-64 ELF client for the preconnected fastst-v3 pool.
; This shortcut intentionally launches ONLY the server's default shell using
; its startup cwd/environment. Use fastst-launch for inherited cwd/env or -e.
; FASM ELF64 object with raw syscalls and no libc, linked static by ld.
format ELF64
public _start
SOCK_SEQPACKET_CLOEXEC = 80005h
PRELOAD_MAGIC = 33545346h
MSG_NOSIGNAL = 4000h
section '.text' executable
_start:
  ; Linux process entry: argc, argv pointers, NULL, envp pointers, NULL.
  mov rcx,[rsp]
  lea rbx,[rsp+rcx*8+16]
  mov r8,3d59414c50534944h   ; DISPLAY=, little endian
  xor r12d,r12d
.find_display:
  mov rax,[rbx]
  test rax,rax
  jz .name
  cmp qword [rax],r8
  je .display
  add rbx,8
  jmp .find_display
.display:
  lea r12,[rax+8]
.name:
  mov word [sockaddr],1
  lea rdi,[sockaddr+3]
  lea rsi,[prefix]
  mov ecx,10
  rep movsb
  mov eax,107               ; geteuid
  syscall
  mov r10d,10
  lea rsi,[digits+12]
  xor ecx,ecx
.digit:
  xor edx,edx
  div r10d
  dec rsi
  add dl,48
  mov [rsi],dl
  inc ecx
  test eax,eax
  jnz .digit
  rep movsb
  mov byte [rdi],58         ; ':'
  inc rdi
  test r12,r12
  jz .connect
  lea r11,[sockaddr+98]
.copy_display:
  cmp rdi,r11
  jae .connect
  mov al,[r12]
  test al,al
  jz .connect
  mov [rdi],al
  inc rdi
  inc r12
  jmp .copy_display
.connect:
  mov eax,41                ; socket
  mov edi,1
  mov esi,SOCK_SEQPACKET_CLOEXEC
  xor edx,edx
  syscall
  test eax,eax
  js .failed
  mov ebx,eax
  mov eax,42                ; connect
  mov edi,ebx
  lea rsi,[sockaddr]
  mov edx,110
  syscall
  test eax,eax
  js .failed
  mov eax,44                ; sendto
  mov edi,ebx
  lea rsi,[instant_request]
  mov edx,16
  mov r10d,MSG_NOSIGNAL
  xor r8d,r8d
  xor r9d,r9d
  syscall
  cmp eax,16
  jne .failed
  mov eax,60                ; exit
  xor edi,edi
  syscall
.failed:
  mov eax,60                ; exit nonzero (e.g. no preconnected server)
  mov edi,1
  syscall
section '.rodata'
prefix db 'fastst-v3:'
instant_request dd PRELOAD_MAGIC,0,-1,16
section '.bss' writeable align 16
sockaddr rb 110
digits rb 16

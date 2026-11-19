; Pure FASM XRandR refresh detection. Uses the typed ABI layouts from
; include/xrandr.inc and the project ccall macro from include/sysv64.inc.
; Never assumes 60 Hz. Zero period means the display reported no usable mode.

; rdi = Display*, rsi = root; eax = XRandR event base, or -1.
randr_watch:
  mov [randr_display],rdi
  mov [randr_root],rsi
  mov byte [randr_cache_valid],0
  lea rsi,[randr_event_base]
  lea rdx,[randr_error_base]
  ccall XRRQueryExtension
  test eax,eax
  jz .unavailable

  mov dword [randr_major],1
  mov dword [randr_minor],3
  mov rdi,[randr_display]
  lea rsi,[randr_major]
  lea rdx,[randr_minor]
  ccall XRRQueryVersion
  test eax,eax
  jz .unavailable
  cmp dword [randr_major],1
  jl .unavailable
  jne .version_ok
  cmp dword [randr_minor],2
  jl .unavailable
.version_ok:
  mov byte [randr_legacy],0
  cmp dword [randr_major],1
  jne .select
  cmp dword [randr_minor],3
  jae .select
  mov byte [randr_legacy],1
.select:
  mov rdi,[randr_display]
  mov rsi,[randr_root]
  mov edx,RRScreenChangeNotifyMask+RRCrtcChangeNotifyMask+RROutputChangeNotifyMask
  ccall XRRSelectInput
  mov eax,[randr_event_base]
  ret
.unavailable:
  mov eax,-1
  ret

; rdi = XRRScreenResources*, rsi = RRMode, returns period (ns).
; Keep fractional rates: use the mode's dotClock / (hTotal * vTotal),
; respecting double-scan and interlaced output (as XRandR specifies).
randr_mode_period:
  xor eax,eax
  test rsi,rsi
  jz .done
  mov ecx,[rdi+XRRScreenResources.nmode]
  test ecx,ecx
  jle .done
  mov r8,[rdi+XRRScreenResources.modes]
  test r8,r8
  jz .done
.loop:
  cmp [r8+XRRModeInfo.id],rsi
  jne .next
  mov r11,[r8+XRRModeInfo.dotClock]
  test r11,r11
  jz .next
  mov r10d,[r8+XRRModeInfo.hTotal]
  test r10d,r10d
  jz .next
  mov eax,[r8+XRRModeInfo.vTotal]
  test eax,eax
  jz .next
  test qword [r8+XRRModeInfo.modeFlags],RR_DoubleScan
  jz .no_doublescan
  add rax,rax
.no_doublescan:
  imul rax,r10
  imul rax,1000000000
  test qword [r8+XRRModeInfo.modeFlags],RR_Interlace
  jz .not_interlaced
  shr rax,1
.not_interlaced:
  mov r9,r11
  shr r9,1
  add rax,r9                    ; round to nearest integer nanosecond
  xor edx,edx
  div r11
  ret
.next:
  add r8,XRR_MODE_BYTES
  dec ecx
  jnz .loop
  xor eax,eax
.done:
  ret

; Fetch CRTC coordinates and periods once per XRandR notification.
; A window move only needs a coordinate translation and cache scan.
randr_load_crtcs:
  push rbx
  push r12
  push r13
  push r14
  mov byte [randr_cache_valid],1
  mov dword [randr_cache_count],0
  mov rdi,[randr_display]
  mov rsi,[randr_root]
  cmp byte [randr_legacy],0
  jne .legacy
  ccall XRRGetScreenResourcesCurrent
  jmp .resources
.legacy:
  ccall XRRGetScreenResources
.resources:
  test rax,rax
  jz .done
  mov r12,rax                   ; XRRScreenResources*
  xor ebx,ebx                   ; CRTC index
.loop:
  cmp ebx,[r12+XRRScreenResources.ncrtc]
  jge .free_resources
  cmp dword [randr_cache_count],XRR_CRTC_CAP
  jae .free_resources
  mov rax,[r12+XRRScreenResources.crtcs]
  mov rdx,[rax+rbx*8]
  mov rdi,[randr_display]
  mov rsi,r12
  ccall XRRGetCrtcInfo
  test rax,rax
  jz .next
  mov r14,rax                   ; XRRCrtcInfo*
  cmp qword [r14+XRRCrtcInfo.mode],0
  je .free_crtc
  cmp dword [r14+XRRCrtcInfo.width],0
  je .free_crtc
  cmp dword [r14+XRRCrtcInfo.height],0
  je .free_crtc
  mov rdi,r12
  mov rsi,[r14+XRRCrtcInfo.mode]
  call randr_mode_period
  mov edx,[randr_cache_count]
  shl rdx,5                     ; 32-byte cache stride
  lea r13,[randr_crtcs+rdx]
  mov ecx,[r14+XRRCrtcInfo.x]
  mov [r13+XRRCachedCrtc.x],ecx
  mov ecx,[r14+XRRCrtcInfo.y]
  mov [r13+XRRCachedCrtc.y],ecx
  mov ecx,[r14+XRRCrtcInfo.width]
  mov [r13+XRRCachedCrtc.width],ecx
  mov ecx,[r14+XRRCrtcInfo.height]
  mov [r13+XRRCachedCrtc.height],ecx
  mov [r13+XRRCachedCrtc.period],rax
  inc dword [randr_cache_count]
.free_crtc:
  mov rdi,r14
  ccall XRRFreeCrtcInfo
.next:
  inc ebx
  jmp .loop
.free_resources:
  mov rdi,r12
  ccall XRRFreeScreenResources
.done:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

; rdi = Display*, rsi = root, rdx = window, ecx = width, r8d = height,
; r9d = flags (bit 1 means reload on RandR events). Returns nanoseconds.
; Select monitor with greatest window/CRTC intersection. Off-screen windows
; retain the first active mode until they re-enter an output's bounds.
randr_refresh_interval_ns:
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
  mov r12d,ecx                  ; unsigned window width
  mov r13d,r8d                  ; unsigned window height
  mov rbx,rdx                   ; window id
  cmp byte [randr_cache_valid],0
  je .reload
  cmp [randr_display],rdi
  jne .reload
  cmp [randr_root],rsi
  jne .reload
  test r9d,2
  jz .cached
.reload:
  mov [randr_display],rdi
  mov [randr_root],rsi
  call randr_load_crtcs
.cached:
  ; XTranslateCoordinates(Display*, src, root, 0, 0, &wx, &wy, &child)
  ; 8 arguments: the last two are on the System V stack.
  mov rdi,[randr_display]
  mov rsi,rbx
  mov rdx,[randr_root]
  xor ecx,ecx
  xor r8d,r8d
  lea r9,[randr_win_x]
  mov rax,rsp
  and rsp,-16
  sub rsp,32
  lea r10,[randr_win_y]
  mov [rsp],r10
  lea r10,[randr_child]
  mov [rsp+8],r10
  mov [rsp+24],rax
  call XTranslateCoordinates
  mov rsp,[rsp+24]
  test eax,eax
  jz .unknown

  mov r14,r12                   ; x end = window x + unsigned width
  mov r15,r13                   ; y end = window y + unsigned height
  movsxd r12,dword [randr_win_x]
  movsxd r13,dword [randr_win_y]
  add r14,r12
  add r15,r13
  lea rbx,[randr_crtcs]
  mov ebp,[randr_cache_count]
  shl rbp,5
  add rbp,rbx                   ; end of 32-byte cache entries
  mov rdi,-1                    ; unsigned area sentinel: first is accepted
  xor esi,esi                   ; best monitor period
.scan:
  cmp rbx,rbp
  jae .selected
  movsxd rcx,dword [rbx+XRRCachedCrtc.x]
  movsxd rdx,dword [rbx+XRRCachedCrtc.y]
  mov r8,r12                    ; left = max(window.x, crtc.x)
  cmp r8,rcx
  cmovl r8,rcx
  mov r9,r13                    ; top = max(window.y, crtc.y)
  cmp r9,rdx
  cmovl r9,rdx
  mov r10,rcx
  mov eax,[rbx+XRRCachedCrtc.width]
  add r10,rax
  cmp r10,r14                   ; right = min(crtc.right, window.right)
  cmovg r10,r14
  mov r11,rdx
  mov eax,[rbx+XRRCachedCrtc.height]
  add r11,rax
  cmp r11,r15                   ; bottom = min(crtc.bottom, window.bottom)
  cmovg r11,r15
  sub r10,r8
  jle .next
  sub r11,r9
  jle .next
  imul r10,r11                  ; overlap area in pixels, 64-bit
  jmp .compare
.next:
  xor r10d,r10d
.compare:
  cmp rdi,-1
  je .choose
  cmp r10,rdi
  jbe .skip
.choose:
  mov rdi,r10
  mov rsi,[rbx+XRRCachedCrtc.period]
.skip:
  add rbx,XRR_CACHE_BYTES
  jmp .scan
.selected:
  mov rax,rsi
  jmp .done
.unknown:
  xor eax,eax
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
  ret

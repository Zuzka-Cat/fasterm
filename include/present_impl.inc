; Optional XPresent vblank-driven presentation. Xlib stays the sole owner of
; the display connection and events, including XGenericEventCookie records.
; Lookup is once per window; no runtime linking requirement for libXpresent.
; PresentOptionCopy ensures the pixmap is idle on IdleNotify and permits
; reuse of the SAME retained pixmap without allocating per-frame buffers.

present_probe:
  push rbx
  lea rdi,[present_library]
  mov esi,1                        ; RTLD_LAZY
  ccall dlopen
  test rax,rax
  jz .done
  mov [present_handle],rax
  mov rbx,rax
  mov rdi,rbx
  lea rsi,[present_query_symbol]
  ccall dlsym
  mov [present_query_fn],rax
  test rax,rax
  jz .fail
  mov rdi,rbx
  lea rsi,[present_select_symbol]
  ccall dlsym
  mov [present_select_fn],rax
  test rax,rax
  jz .fail
  mov rdi,rbx
  lea rsi,[present_pixmap_symbol]
  ccall dlsym
  mov [present_pixmap_fn],rax
  test rax,rax
  jz .fail
  mov rdi,[dpy]
  lea rsi,[present_opcode]
  lea rdx,[present_event_base]
  lea rcx,[present_error_base]
  ccall qword [present_query_fn]
  test eax,eax
  jz .fail
  mov rdi,[dpy]
  mov rsi,[win]
  mov edx,PresentIdleNotifyMask
  ccall qword [present_select_fn]
  test rax,rax
  jz .fail
  mov [present_eid],rax
  mov byte [present_available],1
  ; Optional XFixes update region. The Present extension still works if
  ; XFixes is unavailable. No direct libXfixes link or C glue is required.
  lea rdi,[fixes_library]
  mov esi,1
  ccall dlopen
  test rax,rax
  jz .done
  mov [fixes_handle],rax
  mov rdi,rax
  lea rsi,[fixes_query_symbol]
  ccall dlsym
  mov [fixes_query_fn],rax
  test rax,rax
  jz .fixes_fail
  mov rdi,[dpy]
  lea rsi,[fixes_event_base]
  lea rdx,[fixes_error_base]
  ccall qword [fixes_query_fn]
  test eax,eax
  jz .fixes_fail
  mov rdi,[fixes_handle]
  lea rsi,[fixes_create_symbol]
  ccall dlsym
  mov [fixes_create_fn],rax
  test rax,rax
  jz .fixes_fail
  mov rdi,[fixes_handle]
  lea rsi,[fixes_set_symbol]
  ccall dlsym
  mov [fixes_set_fn],rax
  test rax,rax
  jz .fixes_fail
  mov rdi,[dpy]
  xor esi,esi
  xor edx,edx
  ccall qword [fixes_create_fn]
  mov [present_update_region],rax
  test rax,rax
  jnz .done
.fixes_fail:
  mov rdi,[fixes_handle]
  ccall dlclose
  mov qword [fixes_handle],0
  jmp .done
.fail:
  mov rdi,[present_handle]
  ccall dlclose
  mov qword [present_handle],0
.done:
  pop rbx
  ret

; Submit a single complete pixmap to the next vblank on the window's active
; CRTC. Present chooses the CRTC (target_crtc=0), including after a move.
; Nothing is painted to this pixmap again until IdleNotify for our serial.
present_submit:
  inc dword [present_serial]
  mov byte [present_busy],1
  call frame_clock
  mov [present_started_ns],rax
  mov rdi,[dpy]                   ; args 1-6 are registers
  mov rsi,[win]
  mov rdx,[back_pixmap]
  mov ecx,[present_serial]
  xor r8d,r8d                     ; valid: whole retained pixmap
  mov r9,[present_update_region]  ; update: changed cells + borders
  mov [stack_save],rsp
  and rsp,-16
  sub rsp,96                      ; 11 stack args + 8 alignment bytes
  xor eax,eax
  mov [rsp],rax                   ; x_off
  mov [rsp+8],rax                 ; y_off
  mov [rsp+16],rax                ; target_crtc: server chooses active monitor
  mov [rsp+24],rax                ; wait_fence
  mov [rsp+32],rax                ; idle_fence
  mov qword [rsp+40],PresentOptionCopy  ; no PresentOptionAsync
  mov [rsp+48],rax                ; target_msc=0: NEXT vblank
  mov [rsp+56],rax                ; divisor=0
  mov [rsp+64],rax                ; remainder=0
  mov [rsp+72],rax                ; notifies=NULL
  mov [rsp+80],rax                ; nnotifies=0
  call qword [present_pixmap_fn]
  mov rsp,[stack_save]
  ret

; XPresentIdleNotifyEvent confirms the server is done reading this pixmap.
; Only matching serial and event-id may retire the pending request, so an
; older idle after resize cannot incorrectly retire a newer frame.
present_receive_idle:
  mov rdi,[dpy]
  lea rsi,[event]
  ccall XGetEventData
  test eax,eax
  jz .done
  mov rax,qword [event+XGenericCookie.data]
  test rax,rax
  jz .release
  mov edx,[rax+XPresentIdle.eid]
  cmp edx,dword [present_eid]
  jne .release
  mov rdx,[rax+XPresentIdle.window]
  cmp rdx,[win]
  jne .release
  mov edx,[rax+XPresentIdle.serial_number]
  cmp edx,[present_serial]
  jne .release
  mov byte [present_busy],0
.release:
  mov rdi,[dpy]
  lea rsi,[event]
  ccall XFreeEventData
.done:
  ret

; If Xorg/driver never completes a Present request, recover without using
; the potentially still-in-flight pixmap. XFreePixmap safely drops only our
; reference; the server keeps the old pixmap until presentation finishes.
present_disable:
  mov byte [present_available],0
  mov byte [present_active],0
  mov byte [present_busy],0
  mov qword [next_frame_ns],0
  call recreate_draw_target
  call invalidate_all
  ret

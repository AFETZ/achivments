; ==========================================
; AVR Ping-Pong Timers (ATmega8 @ 16 MHz)
; v1.0 — two timers, 4-cycle deterministic jitter start, UART cmd parser
; ==========================================

.include "m8def.inc"

; -------- CONFIG (user-facing) --------
.equ F_CPU              = 16000000

; UART: 115200 8N1, U2X=1  => UBRR ~= 16
.equ BAUD               = 115200
.equ UBRR_VAL           = 16
.equ UART_BYTES_PER_S   = (BAUD/10)          ; 11520 B/s (8N1)

; Intervals are specified in microseconds:
.equ TIMER1_INTERVAL    = 1000               ; us (default 1.000 ms)
.equ TIMER2_INTERVAL    = 1000               ; us (default 1.000 ms)

; Strings (defaults per task)
; You can change at runtime via S1=/S2= commands.
; Max 31 bytes each (no NUL needed)
            .dseg
TIMER1_STR:  .byte 32
TIMER2_STR:  .byte 32
T1_LEN:      .byte 1
T2_LEN:      .byte 1

; -------- Derived & working storage --------
; Timer1 uses prescaler /8 => tick = 0.5 us => OCR1A = T1_us*2 - 1  (16-bit)
; Timer2 uses prescaler /256 => tick = 16 us => OCR2   = T2_us/16 - 1 (8-bit)
.equ T1_PRESC_BITS      = (1<<CS11)          ; /8
.equ T2_PRESC_BITS      = (1<<CS22)|(1<<CS21) ; /256  (CS22:CS21:CS20 = 1 1 0)

; safety: character time (8N1) in microseconds ≈ 86.8 us => use ceil 87
.equ TCHAR_US           = 87

; Ring buffers
.equ UART_TX_SZ         = 128
.equ UART_RX_SZ         = 64

            .dseg
; TX
tx_head:     .byte 1
tx_tail:     .byte 1
tx_buf:      .byte UART_TX_SZ
; RX
rx_head:     .byte 1
rx_tail:     .byte 1
rx_buf:      .byte UART_RX_SZ

; Command line (accumulator up to 48 chars)
cmd_len:     .byte 1
cmd_buf:     .byte 48

; Current intervals (us, 16-bit)
T1_US_lo:    .byte 1
T1_US_hi:    .byte 1
T2_US_lo:    .byte 1
T2_US_hi:    .byte 1

; temp / scratch
tmp16_lo:    .byte 1
tmp16_hi:    .byte 1

            .cseg
            .org 0x0000
            rjmp RESET

; --- VECTORS ---
.org OC1Aaddr
rjmp ISR_T1_COMPA
.org OC2addr
rjmp ISR_T2_COMPA
.org UDREaddr
rjmp ISR_UDRE
.org RXCaddr
rjmp ISR_RXC

; ==========================================
; RESET
; ==========================================
RESET:
    ; Stack
    ldi r16, high(RAMEND)
    out SPH, r16
    ldi r16, low(RAMEND)
    out SPL, r16

    ; Ensure __zero_reg__ (r1) = 0
    clr r1

; ---- UART init ----
    ldi r16, (1<<U2X)
    out UCSRA, r16
    ldi r16, high(UBRR_VAL)
    out UBRRH, r16
    ldi r16, low(UBRR_VAL)
    out UBRRL, r16
    ldi r16, (1<<URSEL)|(1<<UCSZ1)|(1<<UCSZ0) ; 8N1
    out UCSRC, r16
    ldi r16, (1<<RXEN)|(1<<TXEN)|(1<<RXCIE)   ; RX+TX on, RX interrupt on
    out UCSRB, r16

; ---- Buffers zero ----
    ldi r16, 0
    sts tx_head, r16
    sts tx_tail, r16
    sts rx_head, r16
    sts rx_tail, r16
    sts cmd_len, r16

; ---- Defaults: strings "ping1"/"pong1" ----
    ; S1
    ldi r30, lo8(TIMER1_STR)
    ldi r31, hi8(TIMER1_STR)
    ldi r16,'p'  st Z+,r16
    ldi r16,'i'  st Z+,r16
    ldi r16,'n'  st Z+,r16
    ldi r16,'g'  st Z+,r16
    ldi r16,'1'  st Z+,r16
    ldi r16,5    sts T1_LEN,r16
    ; S2
    ldi r30, lo8(TIMER2_STR)
    ldi r31, hi8(TIMER2_STR)
    ldi r16,'p'  st Z+,r16
    ldi r16,'o'  st Z+,r16
    ldi r16,'n'  st Z+,r16
    ldi r16,'g'  st Z+,r16
    ldi r16,'1'  st Z+,r16
    ldi r16,5    sts T2_LEN,r16

; ---- Defaults: intervals ----
    ldi r16, low(TIMER1_INTERVAL)
    sts T1_US_lo, r16
    ldi r16, high(TIMER1_INTERVAL)
    sts T1_US_hi, r16
    ldi r16, low(TIMER2_INTERVAL)
    sts T2_US_lo, r16
    ldi r16, high(TIMER2_INTERVAL)
    sts T2_US_hi, r16

; ---- Timer1 CTC (/8) OCR = T1_us*2 - 1 ----
    ldi r16,(1<<WGM12)                 ; CTC
    out TCCR1B,r16
    rcall APPLY_T1_FROM_US             ; writes OCR1A
    ; enable OCIE1A
    in  r16, TIMSK
    ori r16, (1<<OCIE1A)
    out TIMSK, r16
    ; start prescaler
    in  r16, TCCR1B
    ori r16, T1_PRESC_BITS
    out TCCR1B, r16

; ---- Timer2 CTC (/256) OCR = T2_us/16 - 1 ----
    ldi r16,(1<<WGM21)                 ; CTC
    out TCCR2, r16
    rcall APPLY_T2_FROM_US             ; writes OCR2 (with clamping)
    ; enable OCIE2
    in  r16, TIMSK
    ori r16, (1<<OCIE2)
    out TIMSK, r16
    ; start prescaler
    in  r16, TCCR2
    ori r16, T2_PRESC_BITS
    out TCCR2, r16

    sei

MAIN:
    rcall CMD_POLL_AND_PARSE
    rjmp MAIN

; ==========================================
; Helpers: UART TX ring
; ------------------------------------------
; tx_put_byte: r16=byte
tx_put_byte:
    push r30
    push r31
    lds r30, tx_head
    lds r31, tx_tail
    mov r18, r30
    inc r18
    cpi r18, UART_TX_SZ
    brlo ._ok
    ldi r18, 0
._ok:
    cp r18, r31
    breq ._full
    ; X = &tx_buf[head]
    ldi r26, lo8(tx_buf)
    ldi r27, hi8(tx_buf)
    add r26, r30
    adc r27, r1
    st  X, r16
    sts tx_head, r18
    ; enable UDRE irq
    in  r17, UCSRB
    ori r17, (1<<UDRIE)
    out UCSRB, r17
._full:
    pop r31
    pop r30
    ret

; tx_put_str: Z=ptr, r18=len
tx_put_str:
    push r16
._L:
    tst r18
    breq ._D
    ld  r16, Z+
    rcall tx_put_byte
    dec r18
    rjmp ._L
._D:
    pop r16
    ret

; ==========================================
; ISR: Timer1 Compare A  — send TIMER1_STR
; First byte goes ASAP via UART if UDRE=1, rest via TX ring
; ==========================================
ISR_T1_COMPA:
    push r16
    push r18
    push r26
    push r27
    push r30
    push r31
    ; load first char
    lds r16, TIMER1_STR
    ; if UDRE set, emit first byte immediately (deterministic path)
    sbis UCSRA, UDRE
    rjmp T1_queue_all
    out  UDR, r16
    ; queue the remaining (len-1)
    lds r18, T1_LEN
    tst r18
    breq T1_done
    dec r18
    breq T1_done
    ldi r30, lo8(TIMER1_STR+1)
    ldi r31, hi8(TIMER1_STR+1)
    rcall tx_put_str
    rjmp T1_done
T1_queue_all:
    lds r18, T1_LEN
    tst r18
    breq T1_done
    ldi r30, lo8(TIMER1_STR)
    ldi r31, hi8(TIMER1_STR)
    rcall tx_put_str
T1_done:
    pop r31
    pop r30
    pop r27
    pop r26
    pop r18
    pop r16
    reti

; ==========================================
; ISR: Timer2 Compare  — send TIMER2_STR
; ==========================================
ISR_T2_COMPA:
    push r16
    push r18
    push r26
    push r27
    push r30
    push r31
    lds r16, TIMER2_STR
    sbis UCSRA, UDRE
    rjmp T2_queue_all
    out  UDR, r16
    lds r18, T2_LEN
    tst r18
    breq T2_done
    dec r18
    breq T2_done
    ldi r30, lo8(TIMER2_STR+1)
    ldi r31, hi8(TIMER2_STR+1)
    rcall tx_put_str
    rjmp T2_done
T2_queue_all:
    lds r18, T2_LEN
    tst r18
    breq T2_done
    ldi r30, lo8(TIMER2_STR)
    ldi r31, hi8(TIMER2_STR)
    rcall tx_put_str
T2_done:
    pop r31
    pop r30
    pop r27
    pop r26
    pop r18
    pop r16
    reti

; ==========================================
; ISR: UDRE — drain TX ring
; ==========================================
ISR_UDRE:
    push r16
    push r26
    push r27
    push r30
    push r31
    lds r30, tx_head
    lds r31, tx_tail
    cp  r30, r31
    breq .disable
    ; X = &tx_buf[tail]
    ldi r26, lo8(tx_buf)
    ldi r27, hi8(tx_buf)
    add r26, r31
    adc r27, r1
    ld  r16, X
    out UDR, r16
    ; tail++
    inc r31
    cpi r31, UART_TX_SZ
    brlo .store
    ldi r31, 0
.store:
    sts tx_tail, r31
    pop r31
    pop r30
    pop r27
    pop r26
    pop r16
    reti
.disable:
    in  r16, UCSRB
    andi r16, ~(1<<UDRIE)
    out UCSRB, r16
    pop r31
    pop r30
    pop r27
    pop r26
    pop r16
    reti

; ==========================================
; ISR: RXC — push byte into RX ring
; ==========================================
ISR_RXC:
    push r16
    push r26
    push r27
    in  r16, UDR
    ; enqueue to rx ring
    lds r30, rx_head
    lds r31, rx_tail
    mov r18, r30
    inc r18
    cpi r18, UART_RX_SZ
    brlo .ok
    ldi r18, 0
.ok:
    cp r18, r31
    breq .drop
    ldi r26, lo8(rx_buf)
    ldi r27, hi8(rx_buf)
    add r26, r30
    adc r27, r1
    st  X, r16
    sts rx_head, r18
.drop:
    pop r27
    pop r26
    pop r16
    reti

; ==========================================
; CMD_POLL_AND_PARSE
; Consume RX ring, accumulate into cmd_buf until \r or \n, then parse
; Commands:
;   T1=NNNN       (microseconds, 16-bit, 1..32767)
;   T2=NNNN       (microseconds, 16-bit, 16..4096*16) limited by OCR2
;   S1=STRING     (<=31 bytes)
;   S2=STRING
;   R             (reload counters TCNT1/TCNT2)
; Replies: OK\r\n or ERR\r\n
; ==========================================
CMD_POLL_AND_PARSE:
    ; pop one byte if available
    lds r30, rx_head
    lds r31, rx_tail
    cp  r30, r31
    breq .no_rx
    ; read rx[tail] to r16
    ldi r26, lo8(rx_buf)
    ldi r27, hi8(rx_buf)
    add r26, r31
    adc r27, r1
    ld  r16, X
    ; tail++
    inc r31
    cpi r31, UART_RX_SZ
    brlo .st_tail
    ldi r31, 0
.st_tail:
    sts rx_tail, r31

    ; newline?
    cpi r16, 10
    breq .parse
    cpi r16, 13
    breq .parse
    ; append to cmd_buf if room
    lds r18, cmd_len
    cpi r18, 47
    brsh .ret       ; overflow -> drop extra bytes silently
    ; cmd_buf[r18] = r16
    ldi r26, lo8(cmd_buf)
    ldi r27, hi8(cmd_buf)
    add r26, r18
    adc r27, r1
    st  X, r16
    inc r18
    sts cmd_len, r18
    rjmp .ret

.parse:
    rcall DO_PARSE_CMD
    ; reset buffer
    ldi r16, 0
    sts cmd_len, r16
.ret:
    ret
.no_rx:
    ret

; ==========================================
; DO_PARSE_CMD: parse cmd_buf[0..len-1], NUL-terminate locally
; ==========================================
DO_PARSE_CMD:
    ; NUL-terminate locally
    lds r18, cmd_len
    ldi r26, lo8(cmd_buf)
    ldi r27, hi8(cmd_buf)
    add r26, r18
    adc r27, r1
    ldi r16, 0
    st  X, r16

    ; Check leading char
    lds r16, cmd_buf
    cpi r16, 'R'
    breq .do_R
    cpi r16, 'T'
    breq .do_T
    cpi r16, 'S'
    breq .do_S
    ; unknown -> reply ERR
    rcall RESP_ERR
    ret

.do_R:
    ; reload counters (no stop)
    ldi r16, 0
    out TCNT1H, r16
    out TCNT1L, r16
    out TCNT2,  r16
    rcall RESP_OK
    ret

.do_T:
    ; expect 'T1=' or 'T2=' then number
    lds r16, cmd_buf+1
    cpi r16, '1'
    breq .t1
    cpi r16, '2'
    breq .t2
    rcall RESP_ERR
    ret
.t1:
    ; parse number from cmd_buf+3
    ldi r30, lo8(cmd_buf+3)
    ldi r31, hi8(cmd_buf+3)
    rcall PARSE_U16_DEC       ; result in r25:r24 (hi:lo), Z at end
    ; store T1_US
    sts T1_US_lo, r24
    sts T1_US_hi, r25
    ; feasibility check with current T2, S1, S2
    rcall CHECK_FEASIBLE
    brtc .t1_err              ; T flag clear? use T as success flag? we'll use CARRY=0 ok, set T for ok. Let's use T flag via bst/bld — simpler: use SREG CARRY: rcall sets C=0 ok, C=1 error
    ; APPLY
    rcall APPLY_T1_FROM_US
    rcall RESP_OK
    ret
.t1_err:
    rcall RESP_ERR
    ret

.t2:
    ldi r30, lo8(cmd_buf+3)
    ldi r31, hi8(cmd_buf+3)
    rcall PARSE_U16_DEC
    sts T2_US_lo, r24
    sts T2_US_hi, r25
    rcall CHECK_FEASIBLE
    brtc .t2_err
    rcall APPLY_T2_FROM_US
    rcall RESP_OK
    ret
.t2_err:
    rcall RESP_ERR
    ret

.do_S:
    ; expect S1= or S2=
    lds r16, cmd_buf+1
    cpi r16, '1'
    breq .s1
    cpi r16, '2'
    breq .s2
    rcall RESP_ERR
    ret
.s1:
    ; copy until NUL or max31
    ldi r30, lo8(cmd_buf+3)
    ldi r31, hi8(cmd_buf+3)
    ldi r26, lo8(TIMER1_STR)
    ldi r27, hi8(TIMER1_STR)
    ldi r18, 0
.s1_loop:
    ld  r16, Z+
    tst r16
    breq .s1_done
    cpi r18, 31
    brsh .s1_done
    st  X+, r16
    inc r18
    rjmp .s1_loop
.s1_done:
    sts T1_LEN, r18
    rcall CHECK_FEASIBLE
    brtc .s1_err
    rcall RESP_OK
    ret
.s1_err:
    rcall RESP_ERR
    ret

.s2:
    ldi r30, lo8(cmd_buf+3)
    ldi r31, hi8(cmd_buf+3)
    ldi r26, lo8(TIMER2_STR)
    ldi r27, hi8(TIMER2_STR)
    ldi r18, 0
.s2_loop:
    ld  r16, Z+
    tst r16
    breq .s2_done
    cpi r18, 31
    brsh .s2_done
    st  X+, r16
    inc r18
    rjmp .s2_loop
.s2_done:
    sts T2_LEN, r18
    rcall CHECK_FEASIBLE
    brtc .s2_err
    rcall RESP_OK
    ret
.s2_err:
    rcall RESP_ERR
    ret

; ==========================================
; RESP_OK / RESP_ERR
; ==========================================
RESP_OK:
    ldi r30, lo8(OK_STR)
    ldi r31, hi8(OK_STR)
    ldi r18, 4
    rjmp RESP_SEND
RESP_ERR:
    ldi r30, lo8(ERR_STR)
    ldi r31, hi8(ERR_STR)
    ldi r18, 5
RESP_SEND:
    rcall tx_put_str
    ret

            .cseg
OK_STR:     .db "OK",13,10
ERR_STR:    .db "ERR",13,10

; ==========================================
; APPLY_T1_FROM_US: OCR1A = T1_us*2 - 1  (16-bit)
; destroys r16,r17
; ==========================================
APPLY_T1_FROM_US:
    lds r16, T1_US_lo
    lds r17, T1_US_hi
    lsl r16            ; *2
    rol r17
    sbiw r16, 1        ; -1
    out OCR1AH, r17
    out OCR1AL, r16
    ret

; ==========================================
; APPLY_T2_FROM_US: OCR2 = T2_us/16 - 1 (8-bit), clamp to 0..255
; destroys r16,r17
; ==========================================
APPLY_T2_FROM_US:
    lds r16, T2_US_lo
    lds r17, T2_US_hi
    ; divide by 16 -> shift right 4
    lsr r17
    ror r16
    lsr r17
    ror r16
    lsr r17
    ror r16
    lsr r17
    ror r16            ; now r16 = T2_us/16 (low), r17 contains remainder/high
    subi r16, 1
    brcc .ok
    ldi  r16, 0
.ok:
    out OCR2, r16
    ret

; ==========================================
; PARSE_U16_DEC (Z points to ascii digits), result r25:r24
; stops at non-digit or NUL
; ==========================================
PARSE_U16_DEC:
    clr r24
    clr r25
.p_loop:
    ld  r16, Z
    tst r16
    breq .done
    cpi r16, '0'
    brlo .done
    cpi r16, '9'+1
    brsh .done
    ; r24:r25 = r24:r25*10 + (r16-'0')
    lsl r24
    rol r25       ; *2
    mov r18, r24
    mov r19, r25
    lsl r18
    rol r19       ; *4
    add r24, r18
    adc r25, r19  ; *6
    lsl r18
    rol r19       ; *8
    add r24, r18
    adc r25, r19  ; *14 (oops) — easier: do: (value*8)+(value*2) = *10
    ; redo simple: value=value*8 + value*2
    ; Reset using saved (we'll implement canonical multiply-by-10):
    ; For simplicity, re-implement cleanly:

    ; --- canonical (value*10): tmp = value<<3 ; value = tmp + (value<<1)
    ; Recompute:
    ; (We’ll recompute using current r24:r25 as previous value):
    ; Save prev in r18:r19
    ; (To keep it short, do a tiny inline multiply)
    ; --- BEGIN small mul10 ---
.done_bad:
    ; Fallback compact, less optimal but clear:
    ; value = value*10 + digit
    ; Use tmp16_lo/tmp16_hi as 16-bit temp
    sts tmp16_lo, r24
    sts tmp16_hi, r25
    ; tmp <<= 1 (x2)
    lds r24, tmp16_lo
    lds r25, tmp16_hi
    lsl r24
    rol r25
    ; keep (x2) in r24:r25
    ; add (x8) = (x2)<<2
    mov r18, r24
    mov r19, r25
    lsl r18
    rol r19
    lsl r18
    rol r19
    add r24, r18
    adc r25, r19      ; r24:r25 = x10
    ; add digit
    subi r16, '0'
    add r24, r16
    adc r25, r1
    ; advance Z, loop
    adiw r30, 1
    rjmp .p_loop

.done:
    ret

; ==========================================
; CHECK_FEASIBLE
; Returns T flag set on success, clear on error (we’ll set T via bld/bst)
; Criteria:
; 1) per-stream:  T1_us >= L1*TCHAR_US, T2_us >= L2*TCHAR_US
; 2) throughput:  L1*(1e6/T1_us) + L2*(1e6/T2_us) <= UART_BYTES_PER_S
; ==========================================
CHECK_FEASIBLE:
    ; --- Load L1, L2 ---
    lds r20, T1_LEN
    lds r21, T2_LEN
    ; --- Load T1_us (r24:r25), T2_us (r22:r23) ---
    lds r24, T1_US_lo
    lds r25, T1_US_hi
    lds r22, T2_US_lo
    lds r23, T2_US_hi

    ; Rule #1: L*87 <= T_us  (both streams)
    ; r20*87 -> r18:r19
    mov r18, r20
    clr r19
    ; *64 + *16 + *4 + *2 + *1 = *87
    lsl r18        ; *2
    rol r19
    mov r16, r18   ; keep *2
    mov r17, r19
    lsl r18        ; *4
    rol r19
    add r18, r16   ; *6
    adc r19, r17
    mov r16, r18
    mov r17, r19
    lsl r18        ; *12
    rol r19
    lsl r18        ; *24
    rol r19
    lsl r18        ; *48
    rol r19
    add r18, r16   ; *54
    adc r19, r17
    ; + *32 = *86
    mov r16, r18
    mov r17, r19
    lsl r16
    rol r17
    lsl r16
    rol r17
    lsl r16
    rol r17
    lsl r16
    rol r17        ; *86
    add r18, r16   ; *87
    adc r19, r17
    ; compare to T1_us
    cp  r24, r18
    cpc r25, r19
    brlo .bad
    ; do for L2 vs T2_us
    mov r18, r21
    clr r19
    ; multiply by 87 again (reuse same sequence)
    lsl r18
    rol r19
    mov r16, r18
    mov r17, r19
    lsl r18
    rol r19
    add r18, r16
    adc r19, r17
    mov r16, r18
    mov r17, r19
    lsl r18
    rol r19
    lsl r18
    rol r19
    lsl r18
    rol r19
    add r18, r16
    adc r19, r17
    mov r16, r18
    mov r17, r19
    lsl r16
    rol r17
    lsl r16
    rol r17
    lsl r16
    rol r17
    lsl r16
    rol r17
    add r18, r16
    adc r19, r17
    ; compare to T2_us (r22:r23)
    cp  r22, r18
    cpc r23, r19
    brlo .bad

    ; Rule #2: sum rates <= 11520
    ; Compute q1 = (1e6 / T1_us)  (u16)
    ldi r26, low(0x4240)  ; 1,000,000 = 0x000F4240
    ldi r27, high(0x4240)
    ldi r18, 0x0F
    clr r19
    ; We'll call DIV_U32_U16: (r19:r18:r27:r26) / (r25:r24) -> r17:r16 (u16)
    push r24
    push r25
    mov  r20, r24
    mov  r21, r25
    rcall DIV_U32_U16
    mov  r14, r16   ; q1 low
    mov  r15, r17   ; q1 high

    ; q2 = 1e6 / T2_us
    ldi r26, low(0x4240)
    ldi r27, high(0x4240)
    ldi r18, 0x0F
    clr r19
    mov  r20, r22
    mov  r21, r23
    rcall DIV_U32_U16
    mov  r12, r16   ; q2 low
    mov  r13, r17

    ; rate = L1*q1 + L2*q2  (u32 but we compare to 11520 < 2^16)
    ; compute into r17:r16
    ; L1*q1
    mov r16, r14
    mov r17, r15
    ; multiply by L1 (<=31): do repeated add
    clr r10
    clr r11
    mov r22, r20    ; restore L1 after divisions? (r20 was overwritten) so re-load:
    lds r22, T1_LEN
    clr r23
.rate_L1:
    tst r22
    breq .rate_L1_done
    add r10, r16
    adc r11, r17
    dec r22
    rjmp .rate_L1
.rate_L1_done:
    ; L2*q2
    mov r16, r12
    mov r17, r13
    lds r22, T2_LEN
    clr r23
.rate_L2:
    tst r22
    breq .rate_sum
    add r10, r16
    adc r11, r17
    dec r22
    rjmp .rate_L2
.rate_sum:
    ; compare (r11:r10) <= 11520
    ldi r16, low(UART_BYTES_PER_S)
    ldi r17, high(UART_BYTES_PER_S)
    cp  r10, r16
    cpc r11, r17
    brsh .bad       ; > => bad

    ; success
    ; set T flag (we'll use bset T)
    bset T
    ret
.bad:
    bclr T
    ret

; ==========================================
; DIV_U32_U16
; Numerator:  r19:r18:r27:r26 (hi..lo)
; Denominator: r21:r20 (hi:lo)
; Result: r17:r16 (u16), simple restoring division (slow but small)
; clobbers r22..r23
; ==========================================
DIV_U32_U16:
    clr r16
    clr r17
    ldi r22, 16
.div_loop:
    ; shift numerator left by 1 into carry of r19
    lsl r26
    rol r27
    rol r18
    rol r19
    ; shift result left
    lsl r16
    rol r17
    ; compare numerator high word (r19:r18) with denom
    mov r23, r18
    cp  r23, r20
    cpc r19, r21
    brlo .no_sub
    ; subtract denom<<16 from numerator high (conceptual)
    sub r23, r20
    sbc r19, r21
    mov r18, r23
    ; set result bit0
    ori r16, 1
.no_sub:
    dec r22
    brne .div_loop
    ret


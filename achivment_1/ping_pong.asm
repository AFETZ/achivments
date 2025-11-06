; ==========================================
; AVR Ping‑Pong Timers
; ATmega8 @ 16 MHz
; Two timers (CTC) enqueue messages; UART UDRE ISR drains a TX ring buffer.
; Strings: "ping1" for T1, "pong1" for T2.
; ==========================================

.include "m8def.inc"

; ---- CONFIG ----
.equ F_CPU       = 16000000
; UART 115200 8N1, double speed (U2X=1): UBRR = Fosc/(8*BAUD)-1  => 16e6/(8*115200)-1 ≈ 16
.equ UBRR_VAL    = 16

; Timer1: CTC, /8   (tick = 0.5 us)
.equ T1_PRESC_BITS = (1<<CS11)
; Timer2: CTC, /128 (tick = 8 us)  CS22..0 = 1 0 1
.equ T2_PRESC_BITS = (1<<CS22)|(1<<CS20)

; initial ~1ms each
.equ T1_OCR_INIT = 2000-1
.equ T2_OCR_INIT = 125-1

; buffers
.equ UART_TX_SZ = 128
.equ MSGQ_SZ    = 8

; ---- SRAM ----
            .dseg
uart_tx_head: .byte 1
uart_tx_tail: .byte 1
uart_tx_buf:  .byte UART_TX_SZ

msgq_head:    .byte 1
msgq_tail:    .byte 1
msgq:         .byte MSGQ_SZ

str1_len:     .byte 1
str2_len:     .byte 1
str1:         .byte 32
str2:         .byte 32

; ---- CODE ----
            .cseg
            .org 0x0000
            rjmp RESET

.org OC1Aaddr
rjmp ISR_T1_COMPA
.org OC2addr
rjmp ISR_T2_COMPA
.org UDREaddr
rjmp ISR_UDRE

; ==========================================
RESET:
    ; stack
    ldi r16, high(RAMEND)
    out SPH, r16
    ldi r16, low(RAMEND)
    out SPL, r16

; UART init
    ldi r16, (1<<U2X)
    out UCSRA, r16
    ldi r16, high(UBRR_VAL)
    out UBRRH, r16
    ldi r16, low(UBRR_VAL)
    out UBRRL, r16
    ldi r16, (1<<URSEL)|(1<<UCSZ1)|(1<<UCSZ0) ; 8N1
    out UCSRC, r16
    ldi r16, (1<<TXEN)                        ; TX on; UDRE IRQ will be enabled on demand
    out UCSRB, r16

; Timer1 CTC /8, OCR1A = T1_OCR_INIT
    ldi r16, (1<<WGM12) ; CTC
    out TCCR1B, r16
    ldi r17, high(T1_OCR_INIT)
    ldi r16, low(T1_OCR_INIT)
    out OCR1AH, r17
    out OCR1AL, r16
    in  r16, TIMSK
    ori r16, (1<<OCIE1A)
    out TIMSK, r16
    in  r16, TCCR1B
    ori r16, T1_PRESC_BITS
    out TCCR1B, r16

; Timer2 CTC /128, OCR2 = T2_OCR_INIT
    ldi r16, (1<<WGM21)
    out TCCR2, r16
    ldi r16, T2_OCR_INIT
    out OCR2, r16
    in  r17, TIMSK
    ori r17, (1<<OCIE2)
    out TIMSK, r17
    in  r16, TCCR2
    ori r16, T2_PRESC_BITS
    out TCCR2, r16

; init strings
    ldi r30, lo8(str1)
    ldi r31, hi8(str1)
    ldi r16, 'p'  ; "ping1"
    st  Z+, r16
    ldi r16, 'i'
    st  Z+, r16
    ldi r16, 'n'
    st  Z+, r16
    ldi r16, 'g'
    st  Z+, r16
    ldi r16, '1'
    st  Z+, r16
    ldi r16, 5
    sts str1_len, r16

    ldi r30, lo8(str2)
    ldi r31, hi8(str2)
    ldi r16, 'p'  ; "pong1"
    st  Z+, r16
    ldi r16, 'o'
    st  Z+, r16
    ldi r16, 'n'
    st  Z+, r16
    ldi r16, 'g'
    st  Z+, r16
    ldi r16, '1'
    st  Z+, r16
    ldi r16, 5
    sts str2_len, r16

; zero heads
    ldi r16, 0
    sts uart_tx_head, r16
    sts uart_tx_tail, r16
    sts msgq_head, r16
    sts msgq_tail, r16

    sei
MAIN:
    rjmp MAIN

; ==========================================
; helpers
; put message id (r16 = 1 or 2) into queue
put_msgq:
    push r30
    push r31
    lds r30, msgq_head
    lds r31, msgq_tail
    mov r18, r30
    inc r18
    cpi r18, MSGQ_SZ
    brlo .pm_ok
    ldi r18, 0
.pm_ok:
    cp r18, r31
    breq .pm_exit     ; full -> drop softly
    ldi r19, lo8(msgq)
    ldi r20, hi8(msgq)
    add r19, r30
    adc r20, __zero_reg__
    st X, r16
    sts msgq_head, r18
    ; enable UDRE
    in  r21, UCSRB
    ori r21, (1<<UDRIE)
    out UCSRB, r21
.pm_exit:
    pop r31
    pop r30
    ret

; put byte r16 into TX ring buffer
uart_tx_put:
    push r30
    push r31
    lds r30, uart_tx_head
    lds r31, uart_tx_tail
    mov r18, r30
    inc r18
    cpi r18, UART_TX_SZ
    brlo .utp_ok
    ldi r18, 0
.utp_ok:
    cp r18, r31
    breq .utp_exit
    ldi r19, lo8(uart_tx_buf)
    ldi r20, hi8(uart_tx_buf)
    add r19, r30
    adc r20, __zero_reg__
    st X, r16
    sts uart_tx_head, r18
    in  r21, UCSRB
    ori r21, (1<<UDRIE)
    out UCSRB, r21
.utp_exit:
    pop r31
    pop r30
    ret

; put string at Z, length r18
uart_tx_put_str:
    push r16
.utps_L:
    tst r18
    breq .utps_D
    ld  r16, Z+
    rcall uart_tx_put
    dec r18
    rjmp .utps_L
.utps_D:
    pop r16
    ret

; ==========================================
; ISRs
ISR_T1_COMPA:
    push r16
    ldi  r16, 1
    rcall put_msgq
    pop  r16
    reti

ISR_T2_COMPA:
    push r16
    ldi  r16, 2
    rcall put_msgq
    pop  r16
    reti

ISR_UDRE:
    push r16
    push r17
    push r30
    push r31

    ; if queue has message, expand to TX buffer
    lds r30, msgq_head
    lds r31, msgq_tail
    cp  r30, r31
    breq .no_msg
    ; msg = msgq[tail]
    ldi r19, lo8(msgq)
    ldi r20, hi8(msgq)
    add r19, r31
    adc r20, __zero_reg__
    ld  r16, X
    ; tail++
    inc r31
    cpi r31, MSGQ_SZ
    brlo .ok_tail
    ldi r31, 0
.ok_tail:
    sts msgq_tail, r31
    ; enqueue string
    cpi r16, 1
    brne .is2
    ldi r30, lo8(str1)
    ldi r31, hi8(str1)
    lds r18, str1_len
    rcall uart_tx_put_str
    rjmp .after_put
.is2:
    ldi r30, lo8(str2)
    ldi r31, hi8(str2)
    lds r18, str2_len
    rcall uart_tx_put_str
.after_put:

.no_msg:
    ; send next byte from TX buffer if any
    lds r30, uart_tx_head
    lds r31, uart_tx_tail
    cp  r30, r31
    breq .disable_udre
    ldi r19, lo8(uart_tx_buf)
    ldi r20, hi8(uart_tx_buf)
    add r19, r31
    adc r20, __zero_reg__
    ld  r16, X
    out UDR, r16
    ; tail++
    inc r31
    cpi r31, UART_TX_SZ
    brlo .udre_exit
    ldi r31, 0
.udre_exit:
    sts uart_tx_tail, r31
    pop r31
    pop r30
    pop r17
    pop r16
    reti

.disable_udre:
    in  r17, UCSRB
    andi r17, ~(1<<UDRIE)
    out UCSRB, r17
    pop r31
    pop r30
    pop r17
    pop r16
    reti

;==============================================================================
; sram_test.asm — synthetic ASCII8+SRAM test ROM for the Yamanooto
; SRAM-emulation helper (phase A verification).
;
; What it does on every boot:
;   1. Enables "SRAM" in region 2 (LD A,0x10 / LD (0x7000),A — the converter
;      rewrites this into CALL 0xF036 so the launcher helper flips page 2).
;   2. Reads a boot counter at 0x8000, increments it, writes a 0..255 pattern
;      at 0x8100-0x81FF, and verifies it in the shadow.
;   3. Disables SRAM (LD A,0 -> bank reg) — the helper flushes the shadow to
;      the game's 64KB save sector in flash (program + verify + commit).
;   4. Re-enables SRAM — the helper reloads the shadow FROM FLASH — and
;      verifies the pattern + counter again.
;   5. Prints "SRAM OK n=<boots>" or "SRAM FAIL x" via the BIOS.
;
; The boot counter growing across openMSX restarts is the end-to-end proof
; that saves persist in the cartridge flash.
;
; Build (see testroms/build_sram_test.sh):
;   pasmo --bin sram_test.asm sram_test.raw
;   pad to 32KB -> convert with ascii8sram_to_k5.py -> pack mapper=ascii8_sram
;==============================================================================

CHPUT   equ 0x00A2          ; BIOS: print char in A
INITXT  equ 0x006C          ; BIOS: init SCREEN 0 (launcher leaves SCREEN 2)

; ASCII8 bank-register addresses (the converter patches these writes)
REG_R1  equ 0x6800          ; region 1 (0x6000-0x7FFF)
REG_R2  equ 0x7000          ; region 2 (0x8000-0x9FFF)
REG_R3  equ 0x7800          ; region 3 (0xA000-0xBFFF)

SRAM_EN equ 0x10            ; enable bit for a 32KB ROM (nbanks=4 -> min 0x10)

CNT_AT  equ 0x8000          ; boot counter lives at shadow byte 0
PAT_AT  equ 0x8100          ; 256-byte test pattern

    org 0x4000

    db  "AB"
    dw  init
    dw  0, 0, 0
    ds  6, 0

init:
    call INITXT             ; text mode (the launcher menu was in SCREEN 2)

    ; --- 1. enable SRAM in region 2 ---
    ld   a, SRAM_EN
    ld   (REG_R2), a        ; -> CALL helper (flip in, shadow <- save slot)

    ; --- diagnostics line (helper state after enable) ---
    ld   hl, msg_d_a8
    call print
    in   a, (0xA8)          ; expect page 2 flipped to the RAM slot
    call print_hex
    ld   hl, msg_d_fl
    call print
    ld   a, (0xF007)        ; P_SR_FLIP
    call print_hex
    ld   hl, msg_d_en
    call print
    ld   a, (0xF001)        ; P_SR_ENBIT
    call print_hex
    ld   hl, msg_d_ex
    call print
    ld   a, (0xF00A)        ; P_SR_EXP
    call print_hex
    ld   hl, msg_d_af
    call print
    ld   a, (0xF009)        ; P_SR_A8FLIP
    call print_hex
    ld   hl, msg_d_w
    call print
    ld   a, 0xA5            ; probe write into the shadow
    ld   (0x9F00), a
    ld   a, (0x9F00)
    call print_hex          ; A5 = writes land in RAM; anything else = no flip

    ; --- 2. counter + pattern ---
    ld   a, (CNT_AT)
    cp   0xFF               ; virgin SRAM (no save yet)?
    jr   nz, cnt_ok
    xor  a
cnt_ok:
    inc  a
    ld   (CNT_AT), a
    ld   (boots), a

    ld   hl, PAT_AT         ; pattern: (low byte of address) XOR boots
    ld   b, 0
fill:
    ld   a, (boots)
    xor  l
    ld   (hl), a
    inc  hl
    djnz fill

    ; verify in-shadow
    ld   hl, PAT_AT
    ld   b, 0
vfy1:
    ld   a, (boots)
    xor  l
    cp   (hl)
    jp   nz, fail1
    inc  hl
    djnz vfy1

    ; --- 3. disable SRAM -> helper flushes shadow to flash ---
    xor  a
    ld   (REG_R2), a        ; -> CALL helper (flip out + FLUSH)

    ; --- 4. re-enable -> helper reloads shadow FROM FLASH ---
    ld   a, SRAM_EN
    ld   (REG_R2), a

    ld   a, (CNT_AT)
    ld   hl, boots
    cp   (hl)
    jp   nz, fail2          ; counter did not survive the flash round-trip

    ld   hl, PAT_AT
    ld   b, 0
vfy2:
    ld   a, (boots)
    xor  l
    cp   (hl)
    jp   nz, fail3
    inc  hl
    djnz vfy2

    ; leave SRAM disabled (clean flush: compare-skip, no wear)
    xor  a
    ld   (REG_R2), a

    ; --- 5. report ---
    ld   hl, msg_ok
    call print
    ld   a, (boots)
    call print_dec
    ld   hl, msg_nl
    call print
hang:
    jr   hang

fail1:
    ld   a, '1'
    jr   fail
fail2:
    ld   a, '2'
    jr   fail
fail3:
    ld   a, '3'
fail:
    push af
    ld   hl, msg_fail
    call print
    pop  af
    call CHPUT
    ld   hl, msg_nl
    call print
    jr   hang

; --- print helpers -----------------------------------------------------------
print:
    ld   a, (hl)
    or   a
    ret  z
    call CHPUT
    inc  hl
    jr   print

print_dec:                  ; A = 0..255 -> decimal, no leading zeros
    ld   b, 0               ; printed-anything flag
    ld   c, 100
    call pd_digit
    ld   c, 10
    call pd_digit
    add  a, '0'
    jp   CHPUT
pd_digit:
    ld   d, '0' - 1
pd_loop:
    inc  d
    sub  c
    jr   nc, pd_loop
    add  a, c
    push af
    ld   a, d
    cp   '0'
    jr   nz, pd_show
    ld   e, a
    ld   a, b
    or   a
    ld   a, e
    jr   z, pd_skip
pd_show:
    call CHPUT
    ld   b, 1
pd_skip:
    pop  af
    ret

print_hex:                  ; A -> two hex digits
    push af
    rrca
    rrca
    rrca
    rrca
    call ph_nib
    pop  af
ph_nib:
    and  0x0F
    add  a, '0'
    cp   '9' + 1
    jr   c, ph_out
    add  a, 'A' - '9' - 1
ph_out:
    jp   CHPUT

msg_ok:
    db   13, 10, "SRAM OK n=", 0
msg_fail:
    db   13, 10, "SRAM FAIL ", 0
msg_nl:
    db   13, 10, 0
msg_d_a8:
    db   13, 10, "A8=", 0
msg_d_fl:
    db   " FL=", 0
msg_d_en:
    db   " EN=", 0
msg_d_ex:
    db   " EX=", 0
msg_d_af:
    db   " AF=", 0
msg_d_w:
    db   " W=", 0

boots   equ  0xC800         ; scratch var in plain RAM (page 3)

    end

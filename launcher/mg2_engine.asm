;==============================================================================
; mg2_engine.asm — MG2 save flash engine, runs from RAM at 0xC000.
;------------------------------------------------------------------------------
; Copied here by mg2_driver (0xC000 = dead launcher-trampoline area MG2 never
; uses). Assembled at its real run address so every internal CALL resolves in
; RAM: during AMD program/erase the whole flash reads as status, so NOTHING
; may execute from the cartridge. Entered with DI (MG2 saves with interrupts
; off). Inputs in the param block just above; A = 0 ok / 0xFF fail on return.
;
; Build: pasmo --bin mg2_engine.asm mg2_engine.bin   (org 0xE000)
;==============================================================================

YAMA_ENAR    equ 0x7FFF
ENAR_WREN    equ 0x10
SCC_REG_A000 equ 0xB000     ; bank register for the 0xA000-0xBFFF window

E_BANK       equ 0xE5B0     ; sector bank to operate on
E_MODE       equ 0xE5B1     ; 0 = erase only, 1 = erase + program
E_PTR        equ 0xE5B2     ; source buffer (game RAM)
E_LEN        equ 0xE5B4     ; data length

    org 0xE500

engine:
    ld   a, (E_BANK)
    ld   (SCC_REG_A000), a  ; window = sector (BEFORE WREN: banking freezes)
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    ; --- sector erase ---
    ld   a, 0xAA
    ld   (0xAAAA), a        ; (addr>>1)&0x7FF = 0x555  (x8x16 flash)
    ld   a, 0x55
    ld   (0xA555), a        ; -> 0x2AA
    ld   a, 0x80
    ld   (0xAAAA), a
    ld   a, 0xAA
    ld   (0xAAAA), a
    ld   a, 0x55
    ld   (0xA555), a
    ld   a, 0x30
    ld   (0xA000), a        ; sector erase
    ld   bc, 0
epoll:
    ld   a, (0xA000)
    cp   0xFF
    jr   z, erased
    ld   d, 8
edly:
    dec  d
    jr   nz, edly
    dec  bc
    ld   a, b
    or   c
    jr   nz, epoll
    jr   fail
erased:
    ld   a, (E_MODE)
    or   a
    jr   z, ok             ; delete: done
    ; --- program marker(0xA5), len lo, len hi at 0xA000..0xA002 ---
    ld   de, 0xA000
    ld   c, 0xA5
    call pgm
    jr   c, fail
    inc  de
    ld   a, (E_LEN)
    ld   c, a
    call pgm
    jr   c, fail
    inc  de
    ld   a, (E_LEN+1)
    ld   c, a
    call pgm
    jr   c, fail
    ; --- program data at 0xA010.. ---
    ld   de, 0xA010
    ld   hl, (E_PTR)
    ld   bc, (E_LEN)
ploop:
    ld   a, b
    or   c
    jr   z, ok
    push bc
    ld   a, (hl)
    ld   c, a
    call pgm
    pop  bc
    jr   c, fail
    inc  hl
    inc  de
    dec  bc
    jr   ploop
ok:
    xor  a
    ld   (YAMA_ENAR), a
    ret
fail:
    xor  a
    ld   (YAMA_ENAR), a
    ld   a, 0xFF
    ret

; program one byte: (DE) = C. WREN already on. Carry set on failure.
pgm:
    ld   a, 0xAA
    ld   (0xAAAA), a
    ld   a, 0x55
    ld   (0xA555), a
    ld   a, 0xA0
    ld   (0xAAAA), a
    ld   a, c
    ld   (de), a
    push bc
    ld   b, 0
pgpoll:
    ld   a, (de)
    cp   c
    jr   z, pgok
    djnz pgpoll
    pop  bc
    scf
    ret
pgok:
    pop  bc
    or   a
    ret
engine_end:
    end

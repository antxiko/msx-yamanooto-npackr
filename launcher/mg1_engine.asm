;==============================================================================
; mg1_engine.asm — rewrite MG1's 64KB save sector (READ-MODIFY-WRITE).
;------------------------------------------------------------------------------
; Metal Gear 1 (Konami-4, 128KB) gets 3 tape-save slots in ONE 64KB flash
; sector at game-relative bank 0x18 (see docs/MG1_SAVES.md). Slot i's record
; lives at window offset i*0x400:
;   Record = [marker 0xA5 | name(6) | len(2, LE) | data(0x301)].
; Flash can only flip 1->0, so the driver stages the WHOLE first bank of the
; sector (raw 0xC00 bytes) in RAM at STAGE, edits the target slot there, and
; this engine erases the sector and reprograms those 0xC00 bytes (0xFF bytes
; are skipped: erased state already).
;
; Runs from RAM (0xF100): during AMD erase/program the whole flash reads as
; status, so nothing may execute from the cartridge. Entered with DI (the
; bank-F shim holds DI for the whole call — MG1's interrupt handler remaps
; banks 0x6000/0x8000 and would pull the rug otherwise). The save sector is
; reached with MG1's own OFFR via the K4 window-3 register (no OFFR change).
; Adapted from mg2_engine.asm (verified working); only the mapper register
; family changes (K4 0xA000 instead of SCC 0xB000). A = 0 ok / 0xFF fail.
;
; Build: pasmo --bin mg1_engine.asm mg1_engine.bin   (org 0xF100)
;==============================================================================

YAMA_ENAR    equ 0x7FFF
ENAR_WREN    equ 0x10
K4_REG_A000  equ 0xA000     ; K4 bank register for the 0xA000-0xBFFF window
SAVE_BANK    equ 0x18       ; the game's 64KB save sector (first bank)
STAGE        equ 0xD800     ; raw staged copy of the sector's first bank
STAGE_LEN    equ 0x0C00     ; 3 slots x 0x400

    org 0xF100

engine:
    ld   a, SAVE_BANK
    ld   (K4_REG_A000), a   ; map the sector (BEFORE WREN: banking freezes)
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    call erase_sector
    jr   c, e_fail
    ; reprogram the staged bank image (skip 0xFF = already-erased bytes)
    ld   hl, STAGE
    ld   de, 0xA000
    ld   bc, STAGE_LEN
e_loop:
    ld   a, b
    or   c
    jr   z, e_ok
    ld   a, (hl)
    cp   0xFF
    jr   z, e_skip
    push bc
    ld   c, a
    call pgm
    pop  bc
    jr   c, e_fail
e_skip:
    inc  hl
    inc  de
    dec  bc
    jr   e_loop
e_ok:
    xor  a
    ld   (YAMA_ENAR), a
    ret
e_fail:
    xor  a
    ld   (YAMA_ENAR), a
    ld   a, 0xFF
    ret

; --- erase the 64KB sector (bank mapped, WREN on). Carry set on timeout. ------
erase_sector:
    ld   a, 0xAA
    ld   (0xAAAA), a
    ld   a, 0x55
    ld   (0xA555), a
    ld   a, 0x80
    ld   (0xAAAA), a
    ld   a, 0xAA
    ld   (0xAAAA), a
    ld   a, 0x55
    ld   (0xA555), a
    ld   a, 0x30
    ld   (0xA000), a        ; sector erase (any address inside the sector)
    ld   bc, 0
er_poll:
    ld   a, (0xA000)
    cp   0xFF
    jr   z, er_done
    ld   d, 8
er_dly:
    dec  d
    jr   nz, er_dly
    dec  bc
    ld   a, b
    or   c
    jr   nz, er_poll
    scf                     ; timeout
    ret
er_done:
    or   a                  ; clear carry
    ret

; --- program one byte: (DE) = C. WREN on. Carry set on failure. ---------------
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
pg_poll:
    ld   a, (de)
    cp   c
    jr   z, pg_ok
    djnz pg_poll
    pop  bc
    scf
    ret
pg_ok:
    pop  bc
    or   a
    ret
engine_end:
    end

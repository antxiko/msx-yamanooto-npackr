;==============================================================================
; mg2_driver.asm — micro save-driver for Metal Gear 2: Solid Snake (Yamanooto)
;------------------------------------------------------------------------------
; MG2 saves through Game Master 2's SRAM-disk API: it maps a companion driver
; bank into the 0x8000 window and does CALL 0x8000 with C = function code and
; DE -> a parameter block (C3B0: name[5], +0D/0E buffer ptr = 0xC700, +0F/10
; length = 115). We do NOT embed GM2 — THIS bank is the "GM2" MG2 talks to.
;
; VERIFIED (RE of MG2's save module): MG2 decides success/failure ONLY from the
; returned A register (it never re-reads the param block), and its call wrapper
; (0x66F5) retries with delete(0x06) then prints "SRAM ERROR" whenever a call
; returns A != 0. So EVERY function here MUST return A = 0:
;   C=0x00 create -> A=0 (no-op; return ignored)   C=0x01 close -> A=0
;   C=0x02 open   -> A=0 (never "not found")        C=0x06 delete -> A=0
;   C=0x08 read   -> copy len bytes sector->buffer, A=0 (fill 0 if empty)
;   C=0x09 write  -> erase sector + program marker/len/data, A=0
;
; Files "SNAK1".."SNAK3": last char picks one of three dedicated 64KB flash
; sectors (relative banks 0x48/0x50/0x58). Sector layout (first bank):
;   +0x00 marker 0xA5, +0x01/02 len, +0x10 data.
;
; This bank is embedded as relative bank 0x40 and mapped into 0x8000 by the
; patched MG2 helper (SCC register 0x9000; the patch preserves the driver's A).
; Flash is reached through the 0xA000 window (SCC register 0xB000; MG2 shadow at
; 0xC383). AMD program/erase runs from RAM (mg2_engine at 0xE000). MG2 calls us
; with DI + H.KEYI stubbed.
;
; Build: pasmo --bin mg2_driver.asm mg2_driver.bin   (org 0x8000, one 8KB bank)
;==============================================================================

SCC_REG_A000 equ 0xB000
MG2_SHADOW3  equ 0xC383     ; MG2's shadow of the 0xA000-window bank register
SECTOR_BASE  equ 0x48       ; SNAK1 sector; SNAK2 = +8, SNAK3 = +16
ENG_RAM      equ 0xE500
E_BANK       equ 0xE5B0
E_MODE       equ 0xE5B1
E_PTR        equ 0xE5B2
E_LEN        equ 0xE5B4

    org 0x8000

entry:
    ld   a, c
    cp   0x08
    jr   z, fn_read
    cp   0x09
    jr   z, fn_write
    xor  a                  ; create/open/close/delete/unknown: A=0 (success)
    ret

; --- name[4] ('1'..'3') -> A = file's sector bank -----------------------------
slot_bank:
    push hl
    ld   hl, 4
    add  hl, de
    ld   a, (hl)
    sub  '1'
    and  0x03
    add  a, a
    add  a, a
    add  a, a               ; *8 banks per 64KB sector
    add  a, SECTOR_BASE
    pop  hl
    ret

map_sector:                 ; A = bank -> 0xA000 window
    ld   (SCC_REG_A000), a
    ret
unmap_sector:
    ld   a, (MG2_SHADOW3)
    ld   (SCC_REG_A000), a
    ret

; read a word from (param + C) -> HL. Preserves DE.
pword:
    ld   l, c
    ld   h, 0
    add  hl, de
    ld   a, (hl)
    inc  hl
    ld   h, (hl)
    ld   l, a
    ret

;------------------------------------------------------------------------------
; C=0x08 READ — copy len bytes from the sector to the caller's buffer.
; If the sector has no save (marker != 0xA5), zero-fill the buffer. A=0 always.
;------------------------------------------------------------------------------
fn_read:
    call slot_bank
    call map_sector
    ld   c, 15
    call pword             ; HL = len
    push hl                ; [len]
    ld   c, 13
    call pword             ; HL = dest buffer
    ld   a, (0xA000)       ; marker
    cp   0xA5
    jr   nz, rd_empty
    ; copy sector+0x10 -> dest
    ex   de, hl            ; DE = dest
    ld   hl, 0xA010        ; source
    pop  bc                ; BC = len
    ldir
    jr   rd_done
rd_empty:
    ; zero-fill dest for len bytes
    pop  bc                ; BC = len
    ld   a, b
    or   c
    jr   z, rd_done        ; len 0
    ld   (hl), 0
    dec  bc
    ld   a, b
    or   c
    jr   z, rd_done        ; len 1
    ld   e, l
    ld   d, h
    inc  de
    ldir
rd_done:
    call unmap_sector
    xor  a
    ret

;------------------------------------------------------------------------------
; C=0x09 WRITE — erase the sector, program marker+len+data from the buffer.
; A=0 always (the chip status in A is ignored; the engine sets P_SR_ERR on
; failure, which we could surface later, but MG2 must never see A != 0).
;------------------------------------------------------------------------------
fn_write:
    call slot_bank
    ld   (E_BANK), a
    ld   a, 1
    ld   (E_MODE), a
    ld   c, 13
    call pword             ; HL = buffer ptr
    ld   (E_PTR), hl
    ld   c, 15
    call pword             ; HL = length
    ld   (E_LEN), hl
    call run_engine
    xor  a                 ; A=0 (success to MG2 regardless of chip status)
    ret

;------------------------------------------------------------------------------
; copy the flash engine to RAM and run it.
;------------------------------------------------------------------------------
run_engine:
    ld   hl, engine_blob
    ld   de, ENG_RAM
    ld   bc, engine_blob_end - engine_blob
    ldir
    call ENG_RAM
    call unmap_sector       ; restore MG2's bank in the 0xA000 window
    ret

engine_blob:
    incbin "mg2_engine.bin"
engine_blob_end:

    ds   0x2000 - ($ - 0x8000), 0xFF
    end

;==============================================================================
; mg1_driver.asm — Metal Gear 1 "virtual tape" driver (game-relative bank 0x10)
;------------------------------------------------------------------------------
; MG1 saves to cassette through six BIOS entry points. The packager rewires
; every `call TAP*` in the game's saveload code (bank 0x0F) to six stubs in
; that bank's free tail (see mg1_shim.asm); the stubs map THIS bank into the
; 0x8000 window and call `entry` with:
;     C = function id (0 TAPION / 1 TAPIN / 2 TAPIOF / 3 TAPOON / 4 TAPOUT /
;         5 TAPOOF),   A = the BIOS call's input (TAPOON type / TAPOUT byte).
; CONTRACT (unlike MG2's A=0 protocol!): success = CARRY CLEAR, error = CARRY
; SET; TAPIN returns its byte in A. The whole call runs under DI (the shim
; sets it): MG1's interrupt handler remaps banks 0x6000/0x8000 mid-frame.
;
; The virtual tape is the 64KB save sector at game-relative bank 0x18: three
; slot records, stride 0x400, [0xA5 | name 6 | len 2 LE | data 0x301]
; (0x300 bytes of GameProgressBuffer + the checksum tail the game writes).
; Reads (TAPION/TAPIN) enumerate non-empty slots as header+data block pairs —
; matching the game's SearchFile scanner, which TAPIONs to the next block on
; any non-0xEA sync byte. Writes capture the filename (TAPOON A!=0 + 16
; TAPOUTs), pick the target slot on TAPOON A=0 (name match, else first empty,
; else CARRY -> the game shows SAVE ERROR), accumulate data TAPOUTs into a
; raw staged copy of the sector bank at 0xD800, and commit on TAPOOF via the
; RAM engine (erase 64KB + reprogram — see mg1_engine.asm). The game's own
; VERIFY then re-reads everything from real flash.
;
; RAM (verified free in docs/MG1_SAVES.md): engine 0xF100, state 0xF300,
; staging 0xD800 (EnemyListCopy — dead during the save commit).
;
; Build (engine first — it is INCBIN'd):
;   pasmo --bin mg1_engine.asm mg1_engine.bin
;   pasmo --bin mg1_driver.asm mg1_driver.bin      (must be EXACTLY 8192)
;==============================================================================

K4_REG_8000  equ 0x8000     ; K4 bank register, window 2 (this driver's window)
K4_REG_A000  equ 0xA000     ; K4 bank register, window 3
SAVE_BANK    equ 0x18
BankIn60     equ 0xF0F1     ; MG1's bank shadows (Variables.asm)
BankIn80     equ 0xF0F2
BankInA0     equ 0xF0F3
WIN3         equ 0xA000
RECSZ        equ 0x400      ; slot stride (flash and staging)
REC_NAME     equ 1
REC_LEN      equ 7
REC_DATA     equ 9
DATA_LEN     equ 0x301      ; 0x300 game bytes + checksum tail
NSLOTS       equ 3
STAGE        equ 0xD800
ENGINE       equ 0xF100

; driver state (free RAM, see docs/MG1_SAVES.md)
st_mode      equ 0xF300     ; 0 idle / 1 reading / 2 hdr capture / 3 data capture
st_slot      equ 0xF301     ; current read slot (0xFF = before first)
st_isdat     equ 0xF302     ; current read block: 0 header / 1 data
st_pos       equ 0xF303     ; 2 bytes: position inside the block
cap_cnt      equ 0xF305     ; header-capture byte counter
cap_name     equ 0xF306     ; 6 bytes: captured filename
wr_pos       equ 0xF30C     ; 2 bytes: data-capture position
tgt_slot     equ 0xF30E     ; slot being written

    org 0x8000

;------------------------------------------------------------------------------
; entry — C = function id, A = input. Returns carry + A per contract.
;------------------------------------------------------------------------------
entry:
    push af
    ld   a, c
    cp   6
    jr   c, en_ok
    pop  af
    or   a                  ; unknown id: harmless no-op, no error
    ret
en_ok:
    add  a, a
    ld   e, a
    ld   d, 0
    ld   hl, jtab
    add  hl, de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    pop  af                 ; A = the BIOS call's input
    jp   (hl)
jtab:
    dw   fn_tapion, fn_tapin, fn_tapiof, fn_tapoon, fn_tapout, fn_tapoof

;------------------------------------------------------------------------------
; TAPION — position at the NEXT block (header/data pairs of non-empty slots).
; Carry when the tape is exhausted (game shows LOAD/TAPE error — correct UX
; for "filename not found").
;------------------------------------------------------------------------------
fn_tapion:
    ld   a, (st_mode)
    cp   1
    jr   z, ti_adv
    ld   a, 1               ; new enumeration from the start
    ld   (st_mode), a
    xor  a
    ld   (st_isdat), a
    ld   a, 0xFF
    ld   (st_slot), a
ti_adv:
    ld   hl, 0
    ld   (st_pos), hl
    ld   a, (st_isdat)
    or   a
    jr   nz, ti_nextslot    ; after a data block -> next slot's header
    ld   a, (st_slot)
    cp   0xFF
    jr   z, ti_nextslot     ; before the first block -> first non-empty slot
    ld   a, 1               ; after a header -> same slot's data block
    ld   (st_isdat), a
    or   a
    ret
ti_nextslot:
    ld   a, (st_slot)
ti_nsl:
    inc  a
    cp   NSLOTS
    jr   nc, ti_end
    push af
    call map_save
    pop  af
    push af
    call slot_base          ; HL = record of slot A
    ld   a, (hl)
    cp   0xA5
    jr   z, ti_found
    call unmap_save
    pop  af
    jr   ti_nsl
ti_found:
    call unmap_save
    pop  af
    ld   (st_slot), a
    xor  a
    ld   (st_isdat), a      ; header block, pos 0
    ret                     ; xor a cleared carry
ti_end:
    xor  a
    ld   (st_mode), a
    scf
    ret

;------------------------------------------------------------------------------
; TAPIN — serve the next byte of the current block in A.
; Header block = 10 x 0xEA + 6 name bytes; data block = the 0x301 data bytes.
;------------------------------------------------------------------------------
fn_tapin:
    ld   a, (st_mode)
    cp   1
    jr   nz, tin_err
    ld   a, (st_isdat)
    or   a
    jr   nz, tin_data
    ; --- header block ---
    ld   hl, (st_pos)
    ld   a, h
    or   a
    jr   nz, tin_err
    ld   a, l
    cp   10
    jr   nc, tin_name
    call pos_inc
    ld   a, 0xEA
    or   a                  ; sync byte, carry clear
    ret
tin_name:
    cp   16
    jr   nc, tin_err
    sub  10                 ; name index 0..5
    ld   c, a
    ld   b, 0
    call map_save
    ld   a, (st_slot)
    call slot_base
    add  hl, bc
    inc  hl                 ; + REC_NAME
    ld   a, (hl)
    push af
    call unmap_save
    call pos_inc
    pop  af
    or   a
    ret
tin_data:
    ; --- data block: pos must be < DATA_LEN ---
    ld   hl, (st_pos)
    ld   a, h
    cp   DATA_LEN >> 8
    jr   c, tin_dok
    jr   nz, tin_err
    ld   a, l
    cp   DATA_LEN & 0xFF
    jr   nc, tin_err
tin_dok:
    call map_save
    ld   a, (st_slot)
    call slot_base
    ld   de, (st_pos)
    add  hl, de
    ld   de, REC_DATA
    add  hl, de
    ld   a, (hl)
    push af
    call unmap_save
    call pos_inc
    pop  af
    or   a
    ret
tin_err:
    scf
    ret

;------------------------------------------------------------------------------
; TAPIOF — stop reading (also aborts whatever was in progress).
;------------------------------------------------------------------------------
fn_tapiof:
    xor  a
    ld   (st_mode), a
    ret

;------------------------------------------------------------------------------
; TAPOON — A != 0: start filename capture. A == 0: pick the target slot
; (name match > first empty > CARRY = tape full -> game shows SAVE ERROR),
; stage the sector bank in RAM and start data capture.
;------------------------------------------------------------------------------
fn_tapoon:
    or   a
    jr   z, tpn_data
    ld   a, 2
    ld   (st_mode), a
    xor  a
    ld   (cap_cnt), a
    ret
tpn_data:
    call map_save
    ld   b, 0               ; pass 1: match by name
tpd_match:
    ld   a, b
    call slot_base
    ld   a, (hl)
    cp   0xA5
    jr   nz, tpd_next1
    inc  hl                 ; + REC_NAME
    ld   de, cap_name
    ld   c, 6
tpd_cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, tpd_next1
    inc  hl
    inc  de
    dec  c
    jr   nz, tpd_cmp
    jr   tpd_have
tpd_next1:
    inc  b
    ld   a, b
    cp   NSLOTS
    jr   c, tpd_match
    ld   b, 0               ; pass 2: first empty slot
tpd_empty:
    ld   a, b
    call slot_base
    ld   a, (hl)
    cp   0xA5
    jr   nz, tpd_have
    inc  b
    ld   a, b
    cp   NSLOTS
    jr   c, tpd_empty
    call unmap_save         ; all 3 slots used by other names
    scf
    ret
tpd_have:
    ld   a, b
    ld   (tgt_slot), a
    ld   hl, WIN3           ; stage the whole sector bank, raw
    ld   de, STAGE
    ld   bc, NSLOTS*RECSZ
    ldir
    call unmap_save
    ld   a, (tgt_slot)      ; build the target record header in staging
    call stage_base
    ld   (hl), 0xA5
    inc  hl
    ex   de, hl
    ld   hl, cap_name
    ld   bc, 6
    ldir
    ex   de, hl             ; HL = record + REC_LEN
    ld   (hl), DATA_LEN & 0xFF
    inc  hl
    ld   (hl), DATA_LEN >> 8
    ld   hl, 0
    ld   (wr_pos), hl
    ld   a, 3
    ld   (st_mode), a
    or   a
    ret

;------------------------------------------------------------------------------
; TAPOUT — B/A byte: header capture counts sync + keeps the 6 name bytes;
; data capture appends into the staged record.
;------------------------------------------------------------------------------
fn_tapout:
    ld   b, a
    ld   a, (st_mode)
    cp   2
    jr   z, tpo_hdr
    cp   3
    jr   z, tpo_dat
    or   a                  ; not capturing: swallow quietly
    ret
tpo_hdr:
    ld   a, (cap_cnt)
    cp   10
    jr   c, tpo_hcnt        ; sync byte: just count it
    cp   16
    jr   nc, tpo_hcnt       ; overflow: ignore
    sub  10
    ld   e, a
    ld   d, 0
    ld   hl, cap_name
    add  hl, de
    ld   (hl), b
tpo_hcnt:
    ld   hl, cap_cnt
    inc  (hl)
    or   a
    ret
tpo_dat:
    ld   hl, (wr_pos)
    ld   a, h
    cp   DATA_LEN >> 8
    jr   c, tpo_dw
    jr   nz, tpo_err
    ld   a, l
    cp   DATA_LEN & 0xFF
    jr   nc, tpo_err
tpo_dw:
    push hl
    ld   a, (tgt_slot)
    call stage_base
    pop  de
    add  hl, de
    ld   de, REC_DATA
    add  hl, de
    ld   (hl), b
    ld   hl, (wr_pos)
    inc  hl
    ld   (wr_pos), hl
    or   a
    ret
tpo_err:
    scf
    ret

;------------------------------------------------------------------------------
; TAPOOF — after a data capture: COMMIT (copy engine to RAM, erase + program).
; Otherwise just stop. The game never checks TAPOOF's carry; a failed commit
; is caught by its own VERIFY, which re-reads real flash.
;------------------------------------------------------------------------------
fn_tapoof:
    ld   a, (st_mode)
    cp   3
    jr   z, tpf_commit
    xor  a
    ld   (st_mode), a
    ret
tpf_commit:
    xor  a
    ld   (st_mode), a
    ld   hl, engine_blob
    ld   de, ENGINE
    ld   bc, engine_blob_end - engine_blob
    ldir
    call ENGINE             ; DI is already held by the shim
    ; engine left window 3 on the save bank; put MG1's bank back, and
    ; defensively restore window 1 (ENAR writes may alias the K4 bank regs
    ; on some cores — docs/MG1_SAVES.md unknown #1)
    ld   a, (BankInA0)
    ld   (K4_REG_A000), a
    ld   a, (BankIn60)
    ld   (0x6000), a
    or   a
    ret

;------------------------------------------------------------------------------
; helpers
;------------------------------------------------------------------------------
map_save:
    ld   a, SAVE_BANK
    ld   (K4_REG_A000), a
    ret
unmap_save:
    ld   a, (BankInA0)      ; = 0x0F while saveload runs (GS_Pause maps it)
    ld   (K4_REG_A000), a
    ret

slot_base:                  ; A = slot -> HL = WIN3 + A*0x400
    ld   h, a
    ld   l, 0
    add  hl, hl
    add  hl, hl             ; H = slot*4
    ld   a, h
    add  a, WIN3 >> 8
    ld   h, a
    ret

stage_base:                 ; A = slot -> HL = STAGE + A*0x400
    ld   h, a
    ld   l, 0
    add  hl, hl
    add  hl, hl
    ld   a, h
    add  a, STAGE >> 8
    ld   h, a
    ret

pos_inc:
    push hl
    ld   hl, (st_pos)
    inc  hl
    ld   (st_pos), hl
    pop  hl
    ret

;------------------------------------------------------------------------------
; flash engine blob (copied to ENGINE and executed from RAM)
;------------------------------------------------------------------------------
engine_blob:
    incbin "mg1_engine.bin"
engine_blob_end:

    ds   0x2000 - ($ - 0x8000), 0xFF
    end

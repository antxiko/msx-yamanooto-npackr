;==============================================================================
; sram_engine_gm2.asm — GM2 flush engine (loaded on demand, runs at 0x8000)
;------------------------------------------------------------------------------
; The GM2 SRAM-emulation variant doesn't fit the resident RAM budget, so the
; flush machinery lives here. The resident helper LDIRs this blob from the
; launcher ROM into 0x8000 (the rebuildable scratch half of the flipped page-2
; shadow) and CALLs 0x8000 with DI. On return the resident rebuilds that half.
;
; Context on entry (set up by the resident helper):
;   - page 2 flipped to system RAM; 0xA000-0xBFFF = active SRAM page p (dup),
;     0xB000-0xBFFF is the canonical (HW-writable) copy.
;   - P_SR_* params valid; P_SR_STATE+3 = 0x80|p (active page).
;   - Interrupts disabled. All registers free.
;
; GM2 save-sector layout (64KB): 7 single-bank slots (bank 0..6) + META bank 7.
; Commit log at META+0x10, one byte per slot: 0x00 = page 0 committed,
; 0x01 = page 1 committed, 0x0F = bad, 0xFF = free. The latest version of each
; page is its highest committed slot. Each flush programs ONE bank: the active
; 4KB page duplicated twice (matches GM2's 4KB-mirrored-in-8KB mapping, so a
; read-only flash-map of the bank shows the right bytes everywhere).
;
; Job: compare-skip -> advance slot (wrap: stash other page @0x9000, erase,
; reprogram it) -> program active page (skip-equal) -> verify -> commit last.
; Errors set P_SR_ERR and bail with WREN off.
;
; Assembled standalone (org 0x8000) and INCBIN'd into launcher.bin:
;   pasmo --bin sram_engine_gm2.asm sram_engine_gm2.bin
;==============================================================================

; --- shared parameter block (must match launcher.asm) -------------------------
P_SR_TYPE    equ 0xF000
P_SR_ENBIT   equ 0xF001
P_SR_SECREL  equ 0xF002
P_SR_SLOTBK  equ 0xF003
P_SR_NSLOTS  equ 0xF004
P_SR_SLOT    equ 0xF005
P_SR_DIRTY   equ 0xF006
P_SR_FLIP    equ 0xF007
P_SR_STATE   equ 0xF013
P_SR_ERR     equ 0xF017

YAMA_ENAR    equ 0x7FFF
ENAR_WREN    equ 0x10
MAP_BANK1    equ 0x7000

SHADOW_PAGE  equ 0xB000     ; canonical active-page bytes (4KB)
STASH        equ 0x9000     ; wrap-time stash for the other page (4KB)

    org 0x8000

engine_entry:
    ; A = active page p (0/1), passed by the resident caller
    ld   (eng_page), a
    ; ---- 1. compare-skip: identical to page p's latest committed slot? ----
    call scan_page              ; A = last slot committed with page p, 0xFF none
    cp   0xFF
    jr   z, eng_advance
    call map_slot               ; window 1 = that slot's bank
    ld   hl, SHADOW_PAGE
    ld   de, 0x6000
    ld   bc, 0x1000
eng_cmp:
    ld   a, (de)
    cpi
    jr   nz, eng_advance
    inc  de
    jp   pe, eng_cmp
    ; identical: nothing to burn
    xor  a
    ld   (P_SR_DIRTY), a
    ret

    ; ---- 2. pick the destination slot -------------------------------------
eng_advance:
    ld   a, (P_SR_SLOT)
    inc  a                      ; 0xFF -> 0
    ld   (eng_next), a
    ld   b, a
    ld   a, (P_SR_NSLOTS)
    dec  a
    cp   b
    jr   nc, eng_program        ; next <= NSLOTS-1: no wrap

    ; ---- wrap: preserve the OTHER page, erase, restart at slot 0 ----------
    ld   a, (eng_page)
    xor  1
    ld   c, a                   ; C = other page
    call scan_page_c            ; A = last slot committed with page C
    ld   (eng_osl), a
    cp   0xFF
    jr   z, eng_do_erase        ; other page never written: nothing to keep
    call map_slot
    ld   hl, 0x6000             ; stash 4KB of the other page
    ld   de, STASH
    ld   bc, 0x1000
    ldir
eng_do_erase:
    call erase_sector
    ld   a, (P_SR_ERR)
    or   a
    ret  nz
    xor  a
    ld   (eng_next), a
    ld   a, (eng_osl)
    cp   0xFF
    jr   z, eng_program         ; no stash to restore
    ; reprogram the other page into slot 0, commit it, active goes to slot 1
    xor  a
    call map_slot_direct        ; window 1 = slot 0 bank (A = slot idx)
    ld   hl, STASH
    call program_dup            ; program stash dup x2 + verify
    ld   a, (P_SR_ERR)
    or   a
    ret  nz
    xor  a                      ; slot 0
    ld   b, a
    ld   a, (eng_page)
    xor  1
    ld   c, a                   ; commit value = other page number
    ld   a, b
    call commit_slot
    ld   a, (P_SR_ERR)
    or   a
    ret  nz
    ld   a, 1
    ld   (eng_next), a

    ; ---- 3. program the active page --------------------------------------
eng_program:
    ld   a, (eng_next)
    call map_slot_direct
    ld   hl, SHADOW_PAGE
    call program_dup
    ld   a, (P_SR_ERR)
    or   a
    ret  nz
    ; ---- 4. commit (last, power-safe) -------------------------------------
    ld   a, (eng_page)
    ld   c, a                   ; commit value = page number
    ld   a, (eng_next)
    call commit_slot
    ld   a, (P_SR_ERR)
    or   a
    ret  nz
    ; ---- 5. bookkeeping ----------------------------------------------------
    ld   a, (eng_next)
    ld   (P_SR_SLOT), a
    xor  a
    ld   (P_SR_DIRTY), a
    ret

;------------------------------------------------------------------------------
; scan_page — A = highest slot whose commit byte == active page (0xFF if none)
; scan_page_c — same for page in C
;------------------------------------------------------------------------------
scan_page:
    ld   a, (eng_page)
    ld   c, a
scan_page_c:
    push bc
    ld   a, (P_SR_SECREL)
    add  a, 7
    ld   (MAP_BANK1), a         ; window 1 = META bank
    ld   hl, 0x6010             ; commit log
    ld   a, (P_SR_NSLOTS)
    ld   b, a
    ld   e, 0xFF                ; best
    ld   d, 0                   ; index
scp_loop:
    ld   a, (hl)
    cp   c
    jr   nz, scp_next
    ld   e, d                   ; match: keep (ascending scan -> last wins)
scp_next:
    inc  hl
    inc  d
    djnz scp_loop
    ld   a, e
    pop  bc
    ret

;------------------------------------------------------------------------------
; map_slot — window 1 = bank of slot A (game-relative). map_slot_direct: same.
;------------------------------------------------------------------------------
map_slot:
map_slot_direct:
    push bc
    ld   b, a
    ld   a, (P_SR_SECREL)
    add  a, b                   ; slot_banks = 1 for GM2
    ld   (MAP_BANK1), a
    pop  bc
    ret

;------------------------------------------------------------------------------
; program_dup — program HL[0..0xFFF] twice into the bank mapped at window 1
; (offsets 0x0000 and 0x1000), skip-equal bytes, then verify both halves.
; Window 1 must already be mapped (WREN raised/lowered here).
;------------------------------------------------------------------------------
program_dup:
    push hl
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    ld   de, 0x6000
    call pd_half
    ld   a, (P_SR_ERR)
    or   a
    jr   nz, pd_bail_wren
    pop  hl
    push hl
    ld   de, 0x7000
    call pd_half
    ld   a, (P_SR_ERR)
    or   a
    jr   nz, pd_bail_wren
    xor  a
    ld   (YAMA_ENAR), a
    ; verify both 4KB halves
    pop  hl
    push hl
    ld   de, 0x6000
    call pd_vfy
    ld   a, (P_SR_ERR)
    or   a
    jr   nz, pd_bail
    pop  hl
    ld   de, 0x7000
    jp   pd_vfy                 ; tail call: its RET returns to our caller
pd_bail_wren:
    xor  a
    ld   (YAMA_ENAR), a
pd_bail:
    pop  hl
    ret

pd_vfy:                         ; compare 4KB HL vs (DE); mismatch -> ERR
    ld   bc, 0x1000
pdv_loop:
    ld   a, (de)
    cpi
    jr   nz, pdv_fail
    inc  de
    jp   pe, pdv_loop
    ret
pdv_fail:
    ld   a, 1
    ld   (P_SR_ERR), a
    ret

pd_half:                        ; program 4KB HL -> (DE), WREN already on
    ld   bc, 0x1000
pdh_loop:
    ld   a, (de)
    cp   (hl)
    jr   z, pdh_next            ; already right (erased 0xFF or equal)
    push bc
    ld   c, (hl)
    call pgm_byte
    pop  bc
    ld   a, (P_SR_ERR)
    or   a
    ret  nz                     ; ERR set: caller bails (and drops WREN)
pdh_next:
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, pdh_loop
    ret

;------------------------------------------------------------------------------
; commit_slot — program META log[A] = C (0x00/0x01 page commit, 0x0F bad)
;------------------------------------------------------------------------------
commit_slot:
    push de
    ld   e, a
    ld   a, (P_SR_SECREL)
    add  a, 7
    ld   (MAP_BANK1), a         ; META bank (before WREN)
    ld   a, 0x10
    add  a, e
    ld   e, a
    ld   d, 0x60                ; DE = 0x6010 + slot
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    call pgm_byte
    xor  a
    ld   (YAMA_ENAR), a
    pop  de
    ret

;------------------------------------------------------------------------------
; pgm_byte — AMD byte program: (DE) = C. WREN must be ON.
;------------------------------------------------------------------------------
pgm_byte:
    ld   a, 0xAA
    ld   (0x6AAA), a
    ld   a, 0x55
    ld   (0x6555), a
    ld   a, 0xA0
    ld   (0x6AAA), a
    ld   a, c
    ld   (de), a
    push bc
    ld   b, 0
pgb_poll:
    ld   a, (de)
    cp   c
    jr   z, pgb_done
    djnz pgb_poll
    ld   a, 1
    ld   (P_SR_ERR), a
pgb_done:
    pop  bc
    ret

;------------------------------------------------------------------------------
; erase_sector — AMD sector erase (~500ms, DI) + rewrite the META header.
;------------------------------------------------------------------------------
erase_sector:
    push bc
    push de
    ld   a, (P_SR_SECREL)
    ld   (MAP_BANK1), a
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    ld   a, 0xAA
    ld   (0x6AAA), a
    ld   a, 0x55
    ld   (0x6555), a
    ld   a, 0x80
    ld   (0x6AAA), a
    ld   a, 0xAA
    ld   (0x6AAA), a
    ld   a, 0x55
    ld   (0x6555), a
    ld   a, 0x30
    ld   (0x6000), a
    ld   bc, 0
ers_poll:
    ld   a, (0x6000)
    cp   0xFF
    jr   z, ers_done
    ld   d, 8
ers_dly:
    dec  d
    jr   nz, ers_dly
    dec  bc
    ld   a, b
    or   c
    jr   nz, ers_poll
    ld   a, 1
    ld   (P_SR_ERR), a
    jr   ers_exit
ers_done:
    xor  a
    ld   (YAMA_ENAR), a
    ld   a, (P_SR_SECREL)
    add  a, 7
    ld   (MAP_BANK1), a
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    ld   a, (P_SR_TYPE)
    ld   (ers_hdr + 5), a
    ld   a, (P_SR_SLOTBK)
    ld   (ers_hdr + 6), a
    ld   de, 0x6000
    ld   hl, ers_hdr
    ld   b, 7
ers_hloop:
    ld   c, (hl)
    call pgm_byte
    inc  hl
    inc  de
    djnz ers_hloop
ers_exit:
    xor  a
    ld   (YAMA_ENAR), a
    pop  de
    pop  bc
    ret
ers_hdr:
    db   "YSAV", 1, 0, 0        ; +5/+6 patched with TYPE/SLOTBK

; --- engine scratch vars (inside the blob, RAM at run time) -------------------
eng_page:
    db   0                      ; active page (0/1)
eng_next:
    db   0                      ; destination slot
eng_osl:
    db   0                      ; other page's source slot (wrap path)

engine_end:
    end

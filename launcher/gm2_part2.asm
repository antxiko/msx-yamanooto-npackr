;==============================================================================
; gm2_part2.asm — GM2 bespoke patch, stage 2 + pointer fix + flash engine
;------------------------------------------------------------------------------
; Lives in GM2's ROM bank 4 free space at offset 0x700 and EXECUTES FROM THE
; RAM COPY at 0x8700+ (stage 1 copied the whole bank there; page 2 = RAM).
;
; Memory picture while this runs:
;   0x4000-0x5FFF  GM2 bank 0 (fixed, cart)         — trampoline, 0x5752
;   0x6000-0x7FFF  cart window (K4 reg 0x6000)      — flash access window
;   0x8000-0x9FFF  RAM: copy of patched bank 4      — driver + this code
;   0xA000-0xBFFF  RAM: SRAM shadow (linear 8KB: page1 @A000, page0 @B000)
;
; Flow: load shadow from the save flash bank (rel bank 0x10, 8KB) -> call the
; patched driver at 0x8000 -> if the function writes, flush the shadow back
; (sector erase + program, AMD protocol; all code in RAM because the whole
; flash chip reads as status during program/erase) -> page 2 back to the cart
; via a tail-jump through ENASLT so its RET lands in the trampoline (0x4039),
; where an EX AF,AF' recovers the driver status stashed here.
;
; Save layout v1: fixed image, no log — the 8KB shadow (0xA000-0xBFFF) stored
; verbatim in relative flash banks 0x10-0x11 (start of the game's 64KB save
; sector); erase-per-save. Virgin sector = 0xFF = GM2 asks to format. A power
; cut during erase+program loses the save (documented v1 risk).
;
; Build: pasmo --bin gm2_part2.asm gm2_part2.bin   (org 0x8700)
;==============================================================================

ENASLT   equ 0x0024         ; BIOS: enable slot A in page H
GM2_GETCART equ 0x5752      ; GM2's own "get cartridge slot id" (bank 0)
YAMA_ENAR   equ 0x7FFF
ENAR_WREN   equ 0x10
K4_REG_6000 equ 0x6000      ; K4 bank register for the 0x6000-0x7FFF window
SAVE_BANK   equ 0x10        ; save image = relative banks 0x10-0x11 (8KB)
SHADOW      equ 0xA000      ; linear 8KB shadow (page1 @A000, page0 @B000)

    org 0x8700

;------------------------------------------------------------------------------
; fix2 @0x8700 — data-pointer base for the patched driver.
; The two computed page-selects (ROM 0x840E / 0x854D: LD DE,0xB000) become
; CALL 0x8700. C = 0x10 (page 0) or 0x30 (page 1).
;------------------------------------------------------------------------------
fix2:
    ld   de, 0xB000         ; page 0 lives at 0xB000 (metadata addressing intact)
    ld   a, c
    cp   0x30
    ret  nz
    ld   d, 0xA0            ; page 1 lives at 0xA000 (the never-used mirror)
    ret

    ds   0x8710 - $, 0xFF   ; stage 2 entry fixed at 0x8710 (part1 jumps here)

;------------------------------------------------------------------------------
; stage 2 — entry with C = function code, DE = caller's parameter block
;------------------------------------------------------------------------------
part2:
    push bc
    push de
    ; --- load the shadow from flash (8KB, one K4 bank switch) ---
    ld   a, SAVE_BANK
    ld   (K4_REG_6000), a   ; window = save banks (reg is in page 1 = cart)
    ld   hl, 0x6000
    ld   de, SHADOW
    ld   bc, 0x2000
    ldir
    pop  de
    pop  bc
    ; --- run the (patched) driver on the shadow ---
    push bc
    call 0x8000
    pop  bc
    push af                 ; driver status
    ; --- flush if this function writes ---
    ld   a, c
    cp   0x0E
    jr   nc, p2_done        ; out of range: nothing
    ld   hl, wclass
    ld   b, 0
    add  hl, bc
    ld   a, (hl)
    or   a
    jr   z, p2_done
    call flush
p2_done:
    ld   a, 1
    ld   (K4_REG_6000), a   ; window back to game bank 1 (GM2's usual mapping)
    pop  af                 ; driver status
    ex   af, af'            ; stash: ENASLT destroys AF; trampoline recovers it
    call GM2_GETCART        ; A = cartridge slot id
    ld   h, 0x80
    jp   ENASLT             ; page 2 = cart again; ENASLT's RET -> trampoline
                            ; (stack top = 0x4039, pushed by the CALL 0x6680)

; write-class table, indexed by function code 0x00-0x0D
wclass:
    db   1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 1, 0
    ;    CRE CLO OPN DF  DN  DL  DEL REN RD  WR  CRW LD  FMT VFY

;------------------------------------------------------------------------------
; flush — erase the save sector, program the 8KB shadow into banks 0x10-0x11.
; Runs from RAM with DI implied? No: caller context has EI. The AMD sequence
; is not interrupt-sensitive for RAM code, but keep DI around WREN to be safe.
;------------------------------------------------------------------------------
flush:
    push bc
    push de
    push hl
    ld   a, i               ; P/V = IFF2
    push af
    di
    ; --- erase the 64KB sector (any address inside selects it) ---
    ld   a, SAVE_BANK
    ld   (K4_REG_6000), a   ; BEFORE WREN (banking freezes under WREN)
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
    ld   (0x6000), a        ; sector erase (~500ms)
    ld   bc, 0
fl_epoll:
    ld   a, (0x6000)
    cp   0xFF
    jr   z, fl_erased
    ld   d, 8
fl_edly:
    dec  d
    jr   nz, fl_edly
    dec  bc
    ld   a, b
    or   c
    jr   nz, fl_epoll
    jr   fl_fail
fl_erased:
    xor  a
    ld   (YAMA_ENAR), a
    ; --- program 8KB: shadow -> banks 0x10 (via window) then 0x11 ---
    ld   a, SAVE_BANK
    call fl_bank            ; program 0xA000-0xBFFF... first half from 0xA000
    jr   c, fl_fail
    ; (fl_bank programs 8KB in one go through the 8KB window: single bank)
    jr   fl_ok
fl_fail:
    xor  a
    ld   (YAMA_ENAR), a
fl_ok:
    pop  af
    jp   po, fl_noei
    ei
fl_noei:
    pop  hl
    pop  de
    pop  bc
    ret

; program the whole 8KB shadow into the (already erased) bank A via the window.
; K4 window 0x6000-0x7FFF is 8KB = the full image in ONE bank. Returns C on fail.
fl_bank:
    ld   (K4_REG_6000), a   ; dest bank (WREN still off)
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    ld   hl, SHADOW
    ld   de, 0x6000
    ld   bc, 0x2000
flb_loop:
    ld   a, (hl)
    cp   0xFF
    jr   z, flb_next        ; erased byte already correct: skip (wear + speed)
    push bc
    ld   c, a
    ld   a, 0xAA
    ld   (0x6AAA), a
    ld   a, 0x55
    ld   (0x6555), a
    ld   a, 0xA0
    ld   (0x6AAA), a
    ld   a, c
    ld   (de), a            ; program byte
    ld   b, 0
flb_poll:
    ld   a, (de)
    cp   c
    jr   z, flb_pok
    djnz flb_poll
    pop  bc
    jr   flb_fail
flb_pok:
    pop  bc
flb_next:
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, flb_loop
    xor  a
    ld   (YAMA_ENAR), a
    ; verify
    ld   hl, SHADOW
    ld   de, 0x6000
    ld   bc, 0x2000
flb_vfy:
    ld   a, (de)
    cpi
    jr   nz, flb_fail
    inc  de
    jp   pe, flb_vfy
    or   a                  ; clear carry: success
    ret
flb_fail:
    xor  a
    ld   (YAMA_ENAR), a
    scf
    ret

    end

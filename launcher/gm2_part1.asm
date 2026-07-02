;==============================================================================
; gm2_part1.asm — GM2 bespoke patch, stage 1 (runs from the 0x6000 window)
;------------------------------------------------------------------------------
; Placed in GM2's ROM bank 4 free space at offset 0x680 (CPU 0x6680 when the
; patched trampoline maps bank 4 into the 0x6000-0x7FFF window, page 1).
;
; Job: switch page 2 to the system RAM slot (GM2's own workspace slot, which
; its INIT stores at 0xF2A0), copy the whole patched bank 4 (driver + this
; blob + engine) into RAM 0x8000-0x9FFF, and jump to stage 2 in that copy.
; Entry: C = driver function code, DE = caller's parameter block.
;
; Build: pasmo --bin gm2_part1.asm gm2_part1.bin   (org 0x6680)
;==============================================================================

ENASLT  equ 0x0024          ; BIOS: enable slot A in page (H = high addr bits)
GM2_RAMSLT equ 0xF2A0       ; GM2's own saved RAM-slot id (set by its INIT)

    org 0x6680

part1:
    push bc
    push de
    ld   a, (GM2_RAMSLT)
    ld   h, 0x80
    call ENASLT             ; page 2 (0x8000-0xBFFF) = system RAM
    ld   hl, 0x6000         ; copy the whole bank-4 window (we ARE this bank)
    ld   de, 0x8000
    ld   bc, 0x2000
    ldir                    ; patched driver + fix + stage2 + engine -> RAM
    pop  de
    pop  bc
    jp   0x8710             ; stage 2, running from the RAM copy

    end

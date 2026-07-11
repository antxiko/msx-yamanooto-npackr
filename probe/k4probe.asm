;==============================================================================
; K4 PROBE — bank 0 (8KB) of the 128KB probe ROM
;
; AB header + stub that copies the experiment engine to RAM (0xC800) and jumps
; to it. The engine binary is assembled separately (k4probe_engine.asm) and
; embedded here. make_probe_rom.py appends banks 1-15 (0xFF + signatures) and
; stamps the per-bank signature 'P'/'Q','B',bank,~bank at +0x1F00.
;
; The launcher trampoline CALLs our INIT with EI, SP~0xF37C, pages 1-2 mapped
; to the cartridge slot and page 0 = main BIOS. 0xC800 does not collide with
; the trampoline (0xC000-0xC1FF) nor the helpers (0xF000+).
;==============================================================================

        org 0x4000

        db   "AB"
        dw   probe_init
        ds   12, 0              ; rest of the 16-byte cartridge header

probe_init:
        di
        ld   hl, engine_img
        ld   de, 0xC800
        ld   bc, engine_end - engine_img
        ldir
        jp   0xC800

engine_img:
        incbin "k4probe_engine.bin"
engine_end:

        ; pad up to the signature offset (+0x1F00 within the bank).
        ; HARD GUARD: if the engine outgrows the bank this ds goes negative ->
        ; pasmo emits an empty/garbage binary -> make_probe_rom.py aborts on
        ; the exact-8192 size check.
        ds   0x5F00 - $, 0xFF

        db   "PB", 0, 0xFF      ; signature of bank 0 (copy B patches 'P'->'Q')

        ds   0x6000 - $, 0xFF   ; bank is exactly 8192 bytes

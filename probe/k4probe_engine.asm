;==============================================================================
; K4 PROBE — experiment engine (runs from RAM at 0xC800)
;
; Characterizes the Yamanooto mapper on real hardware vs the openMSX model
; (openMSX emulates the OLD firmware; Ziggy cores add MSTEN/master offset —
; official source: GitLab mfides/msx_dma_sw, YAMABOOT.Z8A + sdnextor HARD.Z8A).
;
; The probe ROM is 128KB, packed as MAPPER_K5 at OFFR=4 (flash banks 16-31,
; signatures 'P','B',bank,~bank at +0x1F00 of every 8KB bank). A twin copy
; with 'Q' signatures sits at OFFR=8 (banks 32-47) so ANY tag read is
; positionally unambiguous: P=own region, Q=+256KB region, FFxx=launcher pad.
;
; Output: one line per experiment on SCREEN 0 (BIOS CHPUT). The user compares
; against the expected-value table (docs in probe/EXPECTED.md).
;
; Assembled with pasmo (one instruction per line, no ':' separators).
;==============================================================================

        org 0xC800

;------------------------------------------------------------------------------
; Constants
;------------------------------------------------------------------------------
YAMA_ENAR  equ 0x7FFF
YAMA_OFFR  equ 0x7FFE       ; mapper OFFR; with ENAR.MSTEN=1 -> Ziggy MASTER offset
YAMA_CFGR  equ 0x7FFD

REGEN      equ 0x01
MSTEN      equ 0x04         ; Ziggy cores only (old firmware/openMSX ignore it)
CFG_ECHO   equ 0x02
CFG_K4     equ 0x08

PROBE_OFFR equ 4            ; hardcoded placement of copy A (32K units) — the
                            ; pack step MUST confirm OFFR=0x04 for "K4 PROBE"

W0SIG      equ 0x5F00       ; window signature addresses (+0x1F00 per window)
W1SIG      equ 0x7F00
W2SIG      equ 0x9F00
W3SIG      equ 0xBF00

CHPUT      equ 0x00A2
INITXT     equ 0x006C
FORCLR     equ 0xF3E9
BAKCLR     equ 0xF3EA
BDRCLR     equ 0xF3EB
LINL40     equ 0xF3AE

;------------------------------------------------------------------------------
; Entry
;------------------------------------------------------------------------------
main:
        di
        ld   a, 15
        ld   (FORCLR), a
        ld   a, 4
        ld   (BAKCLR), a
        ld   (BDRCLR), a
        ld   a, 38
        ld   (LINL40), a
        ei
        call INITXT             ; SCREEN 0, colours applied

        ld   hl, s_banner
        call pstr

;--- E0: open registers, raw readback ----------------------------------------
        di
        ld   a, REGEN
        ld   (YAMA_ENAR), a
        ld   a, (YAMA_CFGR)
        ld   (v_cfgr), a
        and  CFG_ECHO           ; preserve the user's Echo bit in every CFGR write
        ld   (v_echo), a
        ld   a, (YAMA_OFFR)
        ld   (v_offr), a
        ld   a, (YAMA_ENAR)
        ld   (v_enar), a
        ei
        ld   hl, s_e0
        call pstr
        ld   a, (v_cfgr)
        call phex
        ld   a, ' '
        call CHPUT
        ld   a, (v_offr)
        call phex
        ld   a, ' '
        call CHPUT
        ld   a, (v_enar)
        call phex
        call pcrlf

;--- E1: K5 sanity — known state: K4=0, OFFR=4, banks 0..3 -------------------
        di
        ld   a, (v_echo)
        ld   (YAMA_CFGR), a     ; K4=0 MDIS=0 (also unfreezes the PLAIN B copy)
        ld   a, PROBE_OFFR
        ld   (YAMA_OFFR), a
        xor  a
        ld   (0x5000), a
        inc  a
        ld   (0x7000), a
        inc  a
        ld   (0x9000), a
        inc  a
        ld   (0xB000), a
        ei
        ld   hl, s_e1
        call pstr
        call tags4

;--- SWP: flash integrity sweep of the 16 probe banks through window 3 -------
        ld   hl, s_sw
        call pstr
        ld   b, 0
swp_loop:
        di
        ld   a, b
        ld   (0xB000), a
        ld   a, (W3SIG)
        cp   'P'
        jr   nz, swp_bad
        ld   a, (W3SIG+1)
        cp   'B'
        jr   nz, swp_bad
        ld   a, (W3SIG+2)
        cp   b
        jr   nz, swp_bad
        ei
        ld   a, b
        call phex_n             ; single hex digit 0..F
        jr   swp_next
swp_bad:
        ei
        ld   a, '!'
        call CHPUT
swp_next:
        inc  b
        ld   a, b
        cp   16
        jr   c, swp_loop
        di
        ld   a, 3
        ld   (0xB000), a        ; restore window 3
        ei
        call pcrlf

;--- E11: MASTER offset probe (still in K5 mode) ------------------------------
; Write 0x7FFE with MSTEN=1 and NO bank writes afterwards.
; openMSX: just offsetReg=4 again -> tags unchanged (P00-P03).
; Ziggy (master applied at decode): every window shifts +4 units -> Q00-Q03.
        ld   hl, s_e11a
        call pstr
        di
        ld   a, REGEN|MSTEN
        ld   (YAMA_ENAR), a
        ld   a, PROBE_OFFR
        ld   (YAMA_OFFR), a     ; Ziggy: MASTER=4 / openMSX: offsetReg=4
        ei
        call tags4
        ld   hl, s_e11b
        call pstr
        di
        xor  a
        ld   (YAMA_OFFR), a     ; Ziggy: MASTER back to 0 (MSTEN still on)
        ld   a, REGEN
        ld   (YAMA_ENAR), a     ; MSTEN off
        ld   a, PROBE_OFFR
        ld   (YAMA_OFFR), a     ; openMSX: offsetReg back to 4 for what follows
        ei
        call tags4

;--- E2: enter K4 WITHOUT touching banks (inheritance test) -------------------
; openMSX: single bankRegs[] -> w0/w2/w3 keep P00/P02/P03; the CFGR write
; itself falls through into the K4 window-1 zone: w1 := (8+echo)+16 -> P08.
        ld   hl, s_e2
        call pstr
        di
        ld   a, (v_echo)
        or   CFG_K4
        ld   (YAMA_CFGR), a
        ei
        call tags4

;--- E3: canonical K4 writes, small values ------------------------------------
        ld   hl, s_e3
        call pstr
        di
        ld   a, 5
        ld   (0x6000), a
        ld   a, 6
        ld   (0x8000), a
        ld   a, 7
        ld   (0xA000), a
        ei
        call tags4              ; openMSX: P00 P05 P06 P07

;--- E3b: canonical K4 writes, values 0x11-0x13 (latch vs absolute) -----------
; latch(+OFFR*4): 0x11+16=33 -> Q01/Q02/Q03 · absolute: banks 17-19 -> P01-P03
        ld   hl, s_e3b
        call pstr
        di
        ld   a, 0x11
        ld   (0x6000), a
        ld   a, 0x12
        ld   (0x8000), a
        ld   a, 0x13
        ld   (0xA000), a
        ei
        call tags4              ; openMSX: P00 Q01 Q02 Q03

;--- E4: K5-style register addresses while in K4 ------------------------------
        ld   hl, s_e4
        call pstr
        di
        ld   a, 8
        ld   (0x7000), a
        ld   a, 9
        ld   (0x9000), a
        ld   a, 10
        ld   (0xB000), a
        ei
        call tags4              ; openMSX (range decode): P00 P08 P09 P0A

;--- E5: does the ENAR write clobber window 1 in K4? --------------------------
        ld   hl, s_e5
        call pstr
        di
        ld   a, 1
        ld   (0x6000), a
        ei
        ld   hl, W1SIG
        call ptag               ; P01
        ld   a, '>'
        call CHPUT
        di
        xor  a
        ld   (YAMA_ENAR), a     ; lock — openMSX: w1 := (0+16) -> P00
        ei
        ld   hl, W1SIG
        call ptag
        ld   a, '>'
        call CHPUT
        di
        ld   a, REGEN
        ld   (YAMA_ENAR), a     ; unlock — openMSX: w1 := (1+16) -> P01
        ei
        ld   hl, W1SIG
        call ptag
        call pcrlf

;--- E6: is window 0 switchable in K4? ----------------------------------------
        ld   hl, s_e6
        call pstr
        di
        ld   a, 2
        ld   (0x4000), a
        ld   a, 2
        ld   (0x5000), a
        ei
        ld   hl, W0SIG
        call ptag               ; openMSX: P00 (writes <0x6000 ignored in K4)
        ld   hl, W1SIG
        call ptag               ; and w1 untouched -> P01
        call pcrlf

;--- E7: mapper OFFR during K4 runtime ----------------------------------------
; openMSX: the OFFR write itself hits w1 (K4 zone). Sequence expected:
;   OFFR<-0 + 0x6000<-1  -> w1 abs bank 1 (launcher pad) -> FFFF
;   OFFR<-4              -> w1 := (4+16) -> P04 (fall-through artifact)
;   0x6000<-1            -> w1 := (1+16) -> P01
        ld   hl, s_e7
        call pstr
        di
        xor  a
        ld   (YAMA_OFFR), a
        ld   a, 1
        ld   (0x6000), a
        ei
        ld   hl, W1SIG
        call ptag
        di
        ld   a, PROBE_OFFR
        ld   (YAMA_OFFR), a
        ei
        ld   hl, W1SIG
        call ptag
        di
        ld   a, 1
        ld   (0x6000), a
        ei
        ld   hl, W1SIG
        call ptag
        call pcrlf

;--- E7b: latch-at-write vs offset-at-decode ----------------------------------
; Normalize banks, then change mapper OFFR with NO bank writes.
; latch model (openMSX): w2/w3 stay P02/P03 (w1 shows the fall-through Q08).
; decode model: every window jumps to the Q region.
        ld   hl, s_e7b
        call pstr
        di
        ld   a, 1
        ld   (0x6000), a
        ld   a, 2
        ld   (0x8000), a
        ld   a, 3
        ld   (0xA000), a
        ld   a, 8
        ld   (YAMA_OFFR), a     ; openMSX fall-through: w1 := (8+32) -> Q08
        ei
        call tags4              ; openMSX: P00 Q08 P02 P03
        di
        ld   a, PROBE_OFFR
        ld   (YAMA_OFFR), a
        ld   a, 1
        ld   (0x6000), a        ; repair w1
        ld   a, 2
        ld   (0x8000), a
        ld   a, 3
        ld   (0xA000), a
        ei

;--- E8: final register readback (still in K4) --------------------------------
        ld   hl, s_e8
        call pstr
        di
        ld   a, (YAMA_CFGR)
        ld   b, a
        ld   a, (YAMA_OFFR)
        ld   c, a
        ld   a, (YAMA_ENAR)
        ld   d, a
        ei
        ld   a, b
        call phex
        ld   a, ' '
        call CHPUT
        ld   a, c
        call phex
        ld   a, ' '
        call CHPUT
        ld   a, d
        call phex
        call pcrlf

;--- E10: step-by-step replay of the NEW launcher trampoline ------------------
; Precondition like real hw: mapper OFFR=0, banks scrambled, K5 mode.
        di
        ld   a, (v_echo)
        ld   (YAMA_CFGR), a     ; K5 mode
        ld   a, PROBE_OFFR
        ld   (YAMA_OFFR), a
        ld   a, 4
        ld   (0x5000), a
        ld   a, 5
        ld   (0x7000), a
        ld   a, 6
        ld   (0x9000), a
        ld   a, 7
        ld   (0xB000), a        ; scramble -> P04 P05 P06 P07
        xor  a
        ld   (YAMA_OFFR), a     ; hw precondition (openMSX: banks stay latched)
        ei
        ld   hl, s_sx
        call pstr
        call tags4              ; SX  both models: P04 P05 P06 P07

        di
        ld   a, REGEN|MSTEN
        ld   (YAMA_ENAR), a
        ld   a, PROBE_OFFR
        ld   (YAMA_OFFR), a     ; trampoline offset write (master / offsetReg)
        ld   a, REGEN
        ld   (YAMA_ENAR), a
        ei
        ld   hl, s_s1b
        call pstr
        call tags4              ; openMSX: P04-P07 · Ziggy decode-master: Q04-Q07

        di
        ld   a, (v_echo)
        ld   (YAMA_CFGR), a     ; STEP1 (plain K4: SUBOFF=0)
        xor  a
        ld   (0x5000), a        ; STEP2: raw banks 0..3
        inc  a
        ld   (0x7000), a
        inc  a
        ld   (0x9000), a
        inc  a
        ld   (0xB000), a
        ei
        ld   hl, s_s2
        call pstr
        call tags4              ; both: P00 P01 P02 P03

        di
        ld   a, (v_echo)
        or   CFG_K4
        ld   (YAMA_CFGR), a     ; STEP3
        ei
        ld   hl, s_s3
        call pstr
        call tags4              ; openMSX: P00 P08 P02 P03 (fall-through)

        di
        xor  a
        ld   (YAMA_ENAR), a     ; STEP4 lock
        ei
        ld   hl, s_s4
        call pstr
        call tags4              ; openMSX: P00 P00 P02 P03

        di
        ld   a, 1
        ld   (0x6000), a        ; STEP4b canonical re-prime
        ld   a, 2
        ld   (0x8000), a
        ld   a, 3
        ld   (0xA000), a
        ei
        ld   hl, s_s4b
        call pstr
        call tags4              ; VERDICT — both models: P00 P01 P02 P03

;--- E9: reset test — leave the game-like K4 state in place -------------------
        ld   hl, s_e9
        call pstr
halt_loop:
        ei
        halt
        jr   halt_loop

;------------------------------------------------------------------------------
; Print helpers (CHPUT preserves all registers)
;------------------------------------------------------------------------------

; print NUL-terminated string at HL
pstr:
        ld   a, (hl)
        inc  hl
        or   a
        ret  z
        call CHPUT
        jr   pstr

; print CR+LF
pcrlf:
        ld   a, 13
        call CHPUT
        ld   a, 10
        jp   CHPUT

; print A as two hex digits
phex:
        push af
        rrca
        rrca
        rrca
        rrca
        call phex_n
        pop  af
; fall through: print low nibble of A as one hex digit
phex_n:
        and  0x0F
        add  a, 0x90
        daa
        adc  a, 0x40
        daa
        jp   CHPUT

; print the 4-byte window signature at HL as a tag + space:
;   valid  ('P'|'Q','B',b,~b) -> letter + 2 hex digits  (e.g. "P05 ")
;   other  -> first two bytes as 4 hex digits            (e.g. "FFFF ")
ptag:
        ld   a, (hl)
        ld   b, a               ; byte0 letter
        inc  hl
        ld   a, (hl)
        ld   c, a               ; byte1 'B'
        inc  hl
        ld   a, (hl)
        ld   d, a               ; byte2 bank
        inc  hl
        ld   a, (hl)
        ld   e, a               ; byte3 ~bank
        ld   a, c
        cp   'B'
        jr   nz, ptag_raw
        ld   a, b
        cp   'P'
        jr   z, ptag_chk
        cp   'Q'
        jr   nz, ptag_raw
ptag_chk:
        ld   a, d
        cpl
        cp   e
        jr   nz, ptag_raw
        ld   a, b
        call CHPUT
        ld   a, d
        call phex
        jr   ptag_sp
ptag_raw:
        ld   a, b
        call phex
        ld   a, c
        call phex
ptag_sp:
        ld   a, ' '
        jp   CHPUT

; print the tags of the four windows + CRLF
tags4:
        ld   hl, W0SIG
        call ptag
        ld   hl, W1SIG
        call ptag
        ld   hl, W2SIG
        call ptag
        ld   hl, W3SIG
        call ptag
        jp   pcrlf

;------------------------------------------------------------------------------
; Strings
;------------------------------------------------------------------------------
s_banner: db "K4 PROBE v1  OFFR=4", 13, 10, 0
s_e0:     db "E0  ", 0
s_e1:     db "E1  ", 0
s_sw:     db "SW  ", 0
s_e11a:   db "11A ", 0
s_e11b:   db "11B ", 0
s_e2:     db "E2  ", 0
s_e3:     db "E3  ", 0
s_e3b:    db "E3B ", 0
s_e4:     db "E4  ", 0
s_e5:     db "E5  ", 0
s_e6:     db "E6  ", 0
s_e7:     db "E7  ", 0
s_e7b:    db "E7B ", 0
s_e8:     db "E8  ", 0
s_sx:     db "SX  ", 0
s_s1b:    db "S1B ", 0
s_s2:     db "S2  ", 0
s_s3:     db "S3  ", 0
s_s4:     db "S4  ", 0
s_s4b:    db "S4B ", 0
s_e9:     db "RESET: MENU=CLEAN  PROBE=MST SURVIVES", 13, 10
          db "NO DIRECTORY = FIXB SHORT", 0

;------------------------------------------------------------------------------
; Variables
;------------------------------------------------------------------------------
v_cfgr:  db 0
v_offr:  db 0
v_enar:  db 0
v_echo:  db 0

engine_size_guard:
        ; HARD GUARD: the engine must fit in 0xC800-0xD7FF (4KB). A negative
        ; ds makes pasmo emit an empty binary (exit 0); make_probe_rom.py
        ; aborts on size 0 or > 4096.
        ds   0xD800 - $, 0

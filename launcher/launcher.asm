;==============================================================================
; Yamanooto Konami Compilation Launcher
;------------------------------------------------------------------------------
; Target: Yamanooto MSX cartridge (Konami SCC mode at boot, OFFR=0)
; Size:   <= 32 KB (fits in 4 SCC banks, no extra bank switching for code)
; Assembler: sjasmplus / glass compatible Z80 syntax
;
; Flash layout (managed by the packager):
;   0x000000-0x007FFF  Launcher code + data       (this file, banks 0-3)
;   0x008000-0x01FFFF  Launcher extra data        (banks 4-15, used for dir paging)
;   0x020000-...       Games pool                 (each game aligned to OFFR*32K)
;   <last block>       Game directory             (paged in via bank swap)
;
; Game launch protocol:
;   1. Read directory entry into RAM
;   2. Copy trampoline_src to 0xC000 (RAM page 3)
;   3. Jump to RAM trampoline
;   4. Trampoline: set ENAR.REGEN, write CFGR (K4/SUBOFF), write OFFR, write
;      mapper banks 0..3, jump to game's INIT vector
;==============================================================================

; Build with pasmo:
;   pasmo --bin launcher.asm launcher.bin
; Then pad to exactly 32768 bytes with the packager.

;------------------------------------------------------------------------------
; BIOS entry points (MSX1 compatible)
;------------------------------------------------------------------------------
CHPUT   equ 0x00A2          ; print char in A
CHGET   equ 0x009F          ; wait for keypress, char in A
CHSNS   equ 0x009C          ; Z set if no key in buffer
CHGMOD  equ 0x005F          ; set screen mode (A=0..3)
POSIT   equ 0x00C6          ; cursor pos H=col L=row (BIOS uses H=row,L=col)
CLS     equ 0x00C3          ; clear screen (needs A=0)
ERAFNK  equ 0x00CC          ; erase function key area
BEEP    equ 0x00C0          ; beep
LDIRVM  equ 0x005C          ; copy CPU mem to VRAM (HL=src, DE=dest, BC=count)

LINL40  equ 0xF3AE          ; line length for SCREEN 0

SCROLL_VRAM equ 23*40       ; VRAM offset for row 24 (0-indexed)
SCROLL_RATE equ 3           ; ticks between scroll advances (3 = 50ms NTSC)

;------------------------------------------------------------------------------
; Yamanooto registers
;------------------------------------------------------------------------------
YAMA_ENAR equ 0x7FFF
YAMA_OFFR equ 0x7FFE
YAMA_CFGR equ 0x7FFD

; ENAR bits
ENAR_REGEN equ 0x01
ENAR_WREN  equ 0x10

; CFGR bits
CFGR_MDIS   equ 0x01
CFGR_ECHO   equ 0x02
CFGR_ROMDIS equ 0x04
CFGR_K4     equ 0x08
CFGR_SUBOFF equ 0x30        ; bits 4-5

; Konami SCC mapper bank registers (segment 0..3 of pages 4000h..BFFFh)
MAP_BANK0 equ 0x5000        ; controls 4000-5FFF
MAP_BANK1 equ 0x7000        ; controls 6000-7FFF
MAP_BANK2 equ 0x9000        ; controls 8000-9FFF
MAP_BANK3 equ 0xB000        ; controls A000-BFFF

;------------------------------------------------------------------------------
; Directory format (32 bytes per entry)
;------------------------------------------------------------------------------
DIR_NAME    equ 0x00        ; 24 bytes, NUL-terminated
DIR_OFFR    equ 0x18        ; 1 byte: OFFR value (32K units)
DIR_SUBOFF  equ 0x19        ; 1 byte: SUBOFF in bits 4-5
DIR_FLAGS   equ 0x1A        ; 1 byte
DIR_SIZE32  equ 0x1B        ; 1 byte: size in 32K blocks (informational)
DIR_BANKS   equ 0x1C        ; 4 bytes: bank values for MAP_BANK0..3
DIR_ENTRY_SIZE equ 32

; DIR_FLAGS bits
FLAG_K4     equ 0x01
FLAG_MDIS   equ 0x02        ; small ROM, lock mapping
FLAG_PSGMUTE equ 0x04
FLAG_ASCII16 equ 0x08       ; install ASCII16->K5 helper at 0xF000 before launch
FLAG_SCC_HELPER equ 0x10    ; install SCC enable helper at 0xF020 (avoids 4x mirror)
; bits 5-7 reserved

ASCII16_HELPER_DST equ 0xF000   ; RAM destination for the ASCII16 helper
P_SCC_OFFR_COMP    equ 0xF018   ; OFFR compensated for SCC enable write (1 byte)
P_SCC_OFFR_NORM    equ 0xF019   ; OFFR normal for the game (1 byte)
SCC_HELPER_DST     equ 0xF020   ; RAM destination for the SCC enable helper

;------------------------------------------------------------------------------
; Directory location (set by packager — banks 4..15 reserved, dir bank is the last)
;------------------------------------------------------------------------------
DIR_BANK    equ 15          ; bank number where directory header starts
; Directory magic at offset 0 of the directory: bytes 'Y','M','N','T'
DIR_HDR_LEN equ 32

;------------------------------------------------------------------------------
; RAM workspace (system RAM, page 3). Declared as equ so we don't emit bytes.
;------------------------------------------------------------------------------
RAM_BASE      equ 0xE000
menu_count    equ RAM_BASE + 0    ; 2 bytes
menu_top      equ RAM_BASE + 2    ; 2 bytes
menu_cursor   equ RAM_BASE + 4    ; 1 byte
entry_cache   equ RAM_BASE + 5    ; 32 bytes (DIR_ENTRY_SIZE)
scroll_offset equ RAM_BASE + 37   ; 1 byte: position in scroll_text
scroll_ticker equ RAM_BASE + 38   ; 1 byte: frame counter for slowdown

;==============================================================================
; CARTRIDGE HEADER (0x4000)
;==============================================================================
    org 0x4000

cart_header:
    db  "AB"
    dw  init                ; INIT — entry called by BIOS
    dw  0                   ; STATEMENT
    dw  0                   ; DEVICE
    dw  0                   ; BASIC text
    ds  6, 0                ; reserved (header = 16 bytes)

;==============================================================================
; INIT — entry from MSX BIOS
;==============================================================================
init:
    di
    ld   sp, 0xF380         ; standard BIOS work area top of stack

    ; --- Map page 2 (0x8000-0xBFFF) to the cartridge slot ---
    ; BIOS calls INIT with page 1 set to the cart slot but page 2 is RAM.
    ; The Yamanooto bank registers live at 0xB000 etc., so we must move
    ; page 2 to the cart slot or our writes go to RAM instead.
    ; (Simple primary-slot version; assumes non-expanded cart slot.)
    in   a, (0xA8)          ; current slot register
    ld   b, a
    and  0x0C               ; isolate page 1 slot (bits 2-3)
    rlca
    rlca                    ; shift to page 2 position (bits 4-5)
    ld   c, a
    ld   a, b
    and  0xCF               ; clear page 2 bits
    or   c                  ; page 2 = page 1 slot
    out  (0xA8), a

    ; --- screen setup (SCREEN 0, 40-column) ---
    ld   a, 40
    ld   (LINL40), a
    xor  a
    call CHGMOD             ; SCREEN 0
    call ERAFNK
    xor  a
    call CLS

    ei

    ; --- load directory header (paged in at A000-BFFF) ---
    call dir_page_in
    call dir_validate
    jr   nc, .dir_ok
    call fatal_no_dir
.dir_ok:

    ; --- splash + initial menu ---
    call draw_splash
    call menu_init

main_loop:
    call CHSNS              ; Z=1 if no key in buffer
    jr   z, main_no_key
    call CHGET
    cp   28
    jp   z, menu_next_page
    cp   29
    jp   z, menu_prev_page
    cp   30
    jp   z, menu_cursor_up
    cp   31
    jp   z, menu_cursor_down
    cp   13
    jp   z, do_launch
    cp   ' '
    jp   z, do_launch
    jp   main_loop

main_no_key:
    call scroll_tick
    halt                    ; wait for VBlank (slows scroll naturally)
    jp   main_loop

do_launch:
    call menu_get_selected  ; HL = pointer to selected entry in RAM
    call launch_game        ; never returns

;==============================================================================
; FATAL
;==============================================================================
fatal_no_dir:
    ld   hl, msg_no_dir
    call print_string
fatal_halt:
    halt
    jr   fatal_halt

msg_no_dir:
    db   "Directory not found.",13,10
    db   "Flash needs repackaging.",13,10,0

;==============================================================================
; DIRECTORY ACCESS
;------------------------------------------------------------------------------
; The directory lives in flash bank DIR_BANK. We page it in at 0xA000-0xBFFF
; (segment 3, controlled by MAP_BANK3). Once paged, header lives at 0xA000.
;==============================================================================
dir_page_in:
    ld   a, DIR_BANK
    ld   (MAP_BANK3), a
    ret

dir_validate:
    ; Check magic "YMNT" at 0xA000
    ld   hl, 0xA000
    ld   a, (hl)
    cp   'Y'
    jr   nz, dir_validate_bad
    inc  hl
    ld   a, (hl)
    cp   'M'
    jr   nz, dir_validate_bad
    inc  hl
    ld   a, (hl)
    cp   'N'
    jr   nz, dir_validate_bad
    inc  hl
    ld   a, (hl)
    cp   'T'
    jr   nz, dir_validate_bad
    or   a                  ; clear carry
    ret
dir_validate_bad:
    scf
    ret

; Get directory entry count -> BC
dir_get_count:
    ld   bc, (0xA004)       ; entry count is 2 bytes little-endian
    ret

; Get pointer to entry index BC -> HL (in paged-in flash area)
; Header is 32 bytes; entries start at 0xA020 (0xA000 + 32)
dir_get_entry:
    push bc
    ld   hl, 0
    ld   de, DIR_ENTRY_SIZE
    ; multiply BC * 32 -> HL (entries fit in 13 bits since cap is 4096)
dir_get_entry_mul:
    ld   a, b
    or   c
    jr   z, dir_get_entry_done
    add  hl, de
    dec  bc
    jr   dir_get_entry_mul
dir_get_entry_done:
    ld   de, 0xA020
    add  hl, de
    pop  bc
    ret

;==============================================================================
; MENU
;------------------------------------------------------------------------------
; State in RAM:
;   menu_count    (2B)  total entries
;   menu_top      (2B)  index of first entry shown
;   menu_cursor   (1B)  row in viewport (0..VIEW_ROWS-1)
;==============================================================================
VIEW_ROWS    equ 18         ; rows visible in the list
VIEW_TOP_ROW equ 4          ; first row of the list (1-based)
VIEW_COL     equ 3          ; column of game names (1-based, leave col 1-2 for cursor)

menu_init:
    call dir_get_count
    ld   (menu_count), bc
    ld   hl, 0
    ld   (menu_top), hl
    xor  a
    ld   (menu_cursor), a
    call menu_redraw_full
    ret

menu_redraw_full:
    ; Header
    ld   h, 1
    ld   l, 1
    call POSIT
    ld   hl, msg_title
    call print_string

    ld   h, 1
    ld   l, 2
    call POSIT
    ld   hl, msg_dashes
    call print_string

    call menu_redraw_list
    call menu_redraw_footer
    ret

menu_redraw_footer:
    ; Footer is now a scrolling marquee — initial draw at offset 0.
    xor  a
    ld   (scroll_offset), a
    ld   (scroll_ticker), a
    jp   scroll_redraw

;------------------------------------------------------------------------------
; Marquee scroll at row 24.
; Uses LDIRVM to write 40 chars to VRAM without moving BIOS cursor (no scroll).
;------------------------------------------------------------------------------
scroll_redraw:
    ld   a, (scroll_offset)
    ld   d, 0
    ld   e, a
    ld   hl, scroll_text
    add  hl, de
    ld   de, SCROLL_VRAM
    ld   bc, 40
    call LDIRVM
    ret

scroll_tick:
    ld   a, (scroll_ticker)
    inc  a
    cp   SCROLL_RATE
    jr   nc, scroll_advance
    ld   (scroll_ticker), a
    ret
scroll_advance:
    xor  a
    ld   (scroll_ticker), a
    ld   a, (scroll_offset)
    inc  a
    cp   SCROLL_LEN
    jr   c, scroll_offset_ok
    xor  a
scroll_offset_ok:
    ld   (scroll_offset), a
    jp   scroll_redraw

menu_redraw_list:
    ld   b, VIEW_ROWS       ; rows remaining
    ld   c, 0               ; row index 0..VIEW_ROWS-1
    ld   hl, (menu_top)     ; entry index
menu_redraw_loop:
    push bc
    push hl
    ; clear line first
    ld   a, VIEW_TOP_ROW
    add  a, c
    ld   l, a
    ld   h, 1
    call POSIT
    ld   hl, msg_blank_line
    call print_string
    pop  hl
    push hl

    ; check if entry index < count
    ex   de, hl
    ld   hl, (menu_count)
    or   a
    sbc  hl, de
    jr   z, menu_redraw_skip
    jr   c, menu_redraw_skip
    ex   de, hl             ; restore HL = entry index

    push bc
    ld   b, h
    ld   c, l
    call dir_get_entry      ; HL = pointer to entry
    pop  bc
    push hl
    ; position cursor at name column
    ld   a, VIEW_TOP_ROW
    add  a, c
    ld   l, a
    ld   h, VIEW_COL
    call POSIT
    pop  hl                 ; HL = entry ptr
    call print_string_max24
    jr   menu_redraw_next
menu_redraw_skip:
menu_redraw_next:
    pop  hl
    inc  hl
    pop  bc
    inc  c
    djnz menu_redraw_loop

    call menu_draw_cursor
    ret

menu_draw_cursor:
    ld   a, (menu_cursor)
    add  a, VIEW_TOP_ROW
    ld   l, a
    ld   h, 1
    call POSIT
    ld   a, '>'
    call CHPUT
    ret

menu_clear_cursor:
    ld   a, (menu_cursor)
    add  a, VIEW_TOP_ROW
    ld   l, a
    ld   h, 1
    call POSIT
    ld   a, ' '
    call CHPUT
    ret

menu_cursor_up:
    ld   a, (menu_cursor)
    or   a
    jr   z, menu_prev_page
    call menu_clear_cursor
    ld   a, (menu_cursor)
    dec  a
    ld   (menu_cursor), a
    call menu_draw_cursor
    jp   main_loop

menu_cursor_down:
    ld   a, (menu_cursor)
    cp   VIEW_ROWS-1
    jr   z, menu_next_page
    ; also check if we'd exceed entry count
    ld   b, a
    inc  b
    ld   hl, (menu_top)
    ld   d, 0
    ld   e, b
    add  hl, de
    ex   de, hl
    ld   hl, (menu_count)
    or   a
    sbc  hl, de
    jr   c, menu_down_nop
    jr   z, menu_down_nop
    call menu_clear_cursor
    ld   a, (menu_cursor)
    inc  a
    ld   (menu_cursor), a
    call menu_draw_cursor
menu_down_nop:
    jp   main_loop

menu_next_page:
    ld   hl, (menu_top)
    ld   de, VIEW_ROWS
    add  hl, de
    push hl
    ex   de, hl
    ld   hl, (menu_count)
    or   a
    sbc  hl, de
    pop  hl
    jr   c, menu_next_nop
    jr   z, menu_next_nop
    ld   (menu_top), hl
    xor  a
    ld   (menu_cursor), a
    call menu_redraw_list
menu_next_nop:
    jp   main_loop

menu_prev_page:
    ld   hl, (menu_top)
    ld   a, h
    or   l
    jp   z, main_loop
    ld   de, VIEW_ROWS
    or   a
    sbc  hl, de
    jr   nc, menu_prev_ok
    ld   hl, 0
menu_prev_ok:
    ld   (menu_top), hl
    xor  a
    ld   (menu_cursor), a
    call menu_redraw_list
    jp   main_loop

; Return HL = pointer to selected entry in paged-in flash (0xA000+ region)
menu_get_selected:
    ld   a, (menu_cursor)
    ld   d, 0
    ld   e, a
    ld   hl, (menu_top)
    add  hl, de
    ld   b, h
    ld   c, l
    call dir_get_entry
    ret

;==============================================================================
; LAUNCH GAME
;------------------------------------------------------------------------------
; HL = pointer to selected directory entry (currently in paged-in flash 0xA000+)
; We copy 32 bytes to RAM first, then copy the trampoline to 0xC000 and execute
; it. The trampoline finishes the configuration switch and never returns.
;==============================================================================
; RAM addresses for trampoline runtime
TRAMP_RAM    equ 0xC000     ; trampoline code copied here (up to 256 bytes)
TRAMP_PARAMS equ 0xC100     ; parameter area read by trampoline (after code)
P_CFGR       equ TRAMP_PARAMS + 0   ; 1 byte
P_OFFR       equ TRAMP_PARAMS + 1   ; 1 byte
P_BANKS      equ TRAMP_PARAMS + 2   ; 4 bytes

launch_game:
    ; HL -> entry in paged-in flash (0xA000+). Copy 32 bytes to RAM cache.
    ld   de, entry_cache
    ld   bc, DIR_ENTRY_SIZE
    ldir

    di

    ; --- Compute CFGR ---
    ; bit 3 K4   from flags bit 0
    ; bit 0 MDIS from flags bit 1
    ; bits 4-5   from DIR_SUBOFF (already in those positions)
    ld   a, (entry_cache + DIR_FLAGS)
    ld   b, a
    and  0x01               ; K4
    rlca                    ; -> bit 3
    rlca
    rlca
    ld   c, a
    ld   a, b
    and  0x02               ; MDIS (bit 1 -> bit 0)
    rrca
    or   c
    ld   c, a
    ld   a, (entry_cache + DIR_SUBOFF)
    and  CFGR_SUBOFF
    or   c
    ld   (P_CFGR), a

    ld   a, (entry_cache + DIR_OFFR)
    ld   (P_OFFR), a

    ; Copy BANKS[0..3] -> P_BANKS
    ld   hl, entry_cache + DIR_BANKS
    ld   de, P_BANKS
    ld   bc, 4
    ldir

    ; Copy trampoline code to RAM
    ld   hl, trampoline_src
    ld   de, TRAMP_RAM
    ld   bc, trampoline_end - trampoline_src
    ldir

    jp   TRAMP_RAM

;------------------------------------------------------------------------------
; Trampoline (executes from RAM at 0xC000)
;
; Reads parameters from TRAMP_PARAMS, configures Yamanooto registers, primes
; the bank registers, and jumps to the game's INIT vector. Never returns.
;------------------------------------------------------------------------------
trampoline_src:
    ; Open register access (REGEN=1, WREN=0)
    ld   a, ENAR_REGEN
    ld   (YAMA_ENAR), a

    ; If FLAG_ASCII16 is set, install the ASCII16->K5 helper at 0xF000.
    ld   a, (entry_cache + DIR_FLAGS)
    and  FLAG_ASCII16
    jr   z, tramp_no_helper
    ld   hl, TRAMP_RAM + (ascii16_helper - trampoline_src)
    ld   de, ASCII16_HELPER_DST
    ld   bc, ascii16_helper_end - ascii16_helper
    ldir
tramp_no_helper:

    ; If FLAG_SCC_HELPER is set, install the SCC-enable helper at 0xF020
    ; and compute its OFFR parameters. The helper rewires writes of
    ; 0x3F (etc.) to bank 2 so they land on the game's actual last bank,
    ; eliminating the need to mirror the ROM 4x in flash.
    ld   a, (entry_cache + DIR_FLAGS)
    and  FLAG_SCC_HELPER
    jr   z, tramp_no_scc_helper

    ld   a, (entry_cache + DIR_OFFR)
    ld   (P_SCC_OFFR_NORM), a
    ld   b, a
    ; OFFR_comp = OFFR_norm + SIZE32 - 16 (mod 256)
    ld   a, (entry_cache + DIR_SIZE32)
    add  a, b
    sub  16
    ld   (P_SCC_OFFR_COMP), a

    ld   hl, TRAMP_RAM + (scc_helper - trampoline_src)
    ld   de, SCC_HELPER_DST
    ld   bc, scc_helper_end - scc_helper
    ldir
tramp_no_scc_helper:

    ; STEP 1: Force CFGR to a clean K5/SCC state with no MDIS.
    ; Bank writes via Konami-SCC addresses (5000/7000/9000/B000) only fire
    ; when K4=0 AND MDIS=0. The final CFGR (K4/MDIS) is applied after the
    ; bank writes so the game inherits the correct state.
    xor  a
    ld   (YAMA_CFGR), a

    ; OFFR — game position (32K units). Has no effect until a mapper write.
    ld   a, (P_OFFR)
    ld   (YAMA_OFFR), a

    ; STEP 2: prime mapper banks (this also commits OFFR).
    ld   a, (P_BANKS + 0)
    ld   (MAP_BANK0), a
    ld   a, (P_BANKS + 1)
    ld   (MAP_BANK1), a
    ld   a, (P_BANKS + 2)
    ld   (MAP_BANK2), a
    ld   a, (P_BANKS + 3)
    ld   (MAP_BANK3), a

    ; STEP 3: apply final CFGR (K4 / MDIS / SUBOFF / ROMDIS=0 / ECHO=0).
    ; After this, the cartridge behaves exactly like the original cart.
    ld   a, (P_CFGR)
    ld   (YAMA_CFGR), a

    ; STEP 4: LOCK config registers. Set REGEN=0 so any accidental write by
    ; the game to 0x7FFC-0x7FFF is ignored. Without this, a stray write
    ; (e.g. graphics/sprite tables, music driver writing to flash area) can
    ; flip MDIS in CFGR and silently disable all further bank switching —
    ; symptom: SCC music stops working while graphics keep going.
    xor  a
    ld   (YAMA_ENAR), a

    ; 0x4000-0xBFFF now shows the game. Strategy:
    ;   - CALL the game's INIT directly. Most games take over the CPU (set
    ;     their own SP and run forever) so this path is fast — no BIOS
    ;     reboot needed.
    ;   - If the game's INIT *returns* (hook-based games like Metal Gear 2),
    ;     execution falls through to tramp_warmboot which JPs to 0x0000.
    ;     BIOS reboots, finds the game's AB header (OFFR persists across
    ;     warm boot), and does its standard cart init flow, triggering any
    ;     hooks the game installed.
    ld   a, (0x4000)
    cp   'A'
    jr   nz, tramp_warmboot
    ld   a, (0x4001)
    cp   'B'
    jr   nz, tramp_warmboot
    ld   hl, (0x4002)
    ld   a, h
    or   a
    jr   z, tramp_warmboot      ; null INIT -> warm boot

    ; CALL game's INIT — push warm-boot as return address.
    ; Use the RAM address of tramp_warmboot (within the copied trampoline at
    ; TRAMP_RAM), NOT the source-ROM address. Otherwise game RETs to flash
    ; that's now showing game data, executing random bytes as code.
    ld   de, TRAMP_RAM + (tramp_warmboot - trampoline_src)
    push de
    ei
    jp   (hl)

tramp_warmboot:
    di
    ld   sp, 0xF380
    jp   0x0000

tramp_hard:
    rst  0

;------------------------------------------------------------------------------
; ASCII16->K5 helper data — copied to 0xF000 when launching ASCII16-patched
; games. Each helper turns a single CPU register write (A=bank_value) into the
; two K5 bank writes that load both halves of an ASCII16 16KB segment.
;------------------------------------------------------------------------------
ascii16_helper:
    ; Helper for ASCII16 segment 0 (called at 0xF000)
    add  a, a
    ld   (MAP_BANK0), a     ; K5 segment 0 bank = 2*A
    inc  a
    ld   (MAP_BANK1), a     ; K5 segment 1 bank = 2*A + 1
    ret
    ds   7, 0               ; pad to 0x10 so seg1 helper sits at 0xF010
    ; Helper for ASCII16 segment 1 (called at 0xF010)
    add  a, a
    ld   (MAP_BANK2), a     ; K5 segment 2 bank = 2*A
    inc  a
    ld   (MAP_BANK3), a     ; K5 segment 3 bank = 2*A + 1
    ret
ascii16_helper_end:

;------------------------------------------------------------------------------
; SCC-enable helper — copied to 0xF020. Called by patched ROMs in place of
; the original `LD (0x9LL), A` (with A pre-set to 0x3F/7F/BF/FF).
;
; The helper opens REGEN, swaps OFFR to the compensated value so the bank
; write lands on the game's actual last bank (where the music driver lives),
; writes A to the K5 bank-2 register, then restores OFFR and locks REGEN.
;------------------------------------------------------------------------------
scc_helper:
    push af                 ; save SCC-enable value
    ld   a, ENAR_REGEN
    ld   (YAMA_ENAR), a
    ld   a, (P_SCC_OFFR_COMP)
    ld   (YAMA_OFFR), a
    pop  af                 ; restore A
    push af
    ld   (MAP_BANK2), a     ; bankRegs[2] = A + OFFR_comp*4 = last game bank
    ld   a, (P_SCC_OFFR_NORM)
    ld   (YAMA_OFFR), a     ; restore normal OFFR for game's other bank writes
    xor  a
    ld   (YAMA_ENAR), a     ; lock REGEN
    pop  af
    ret
scc_helper_end:

trampoline_end:

;==============================================================================
; STRING / PRINT HELPERS
;==============================================================================
; HL = NUL-terminated string
print_string:
    ld   a, (hl)
    or   a
    ret  z
    call CHPUT
    inc  hl
    jr   print_string

; HL points to entry (name at +0). Print up to 24 chars or until NUL.
print_string_max24:
    ld   b, 24
print_str_max_loop:
    ld   a, (hl)
    or   a
    ret  z
    call CHPUT
    inc  hl
    djnz print_str_max_loop
    ret

;==============================================================================
; STATIC STRINGS
;==============================================================================
msg_title:
    db   "  YAMANOOTO KONAMI COMPILATION  ",0
msg_dashes:
    db   "----------------------------------------",0
msg_footer:
    db   " UP/DN  ENTER:launch  RESET:back",0

;------------------------------------------------------------------------------
; Scrolling marquee text. Stored twice so the 40-char display window never
; wraps the buffer; offset cycles 0..SCROLL_LEN-1.
;
; Layout per copy:
;   - Anti-scam prefix (92 bytes, immutable, hardcoded here)
;   - Custom buffer  (64 bytes, default = repo URL; the packager rewrites it
;     when --marquee is passed). Total per copy = 156 bytes.
;------------------------------------------------------------------------------
scroll_text:
    db   "    ESTA HERRAMIENTA ES GRATUITA   ***   SI HAS PAGADO POR ESTA ROM, TE HAN ESTAFADO    *** "
    db   "        THIS TEXT CAN BE REPLACED, PLEASE READ THE DOCS         "
SCROLL_LEN equ $ - scroll_text
    db   "    ESTA HERRAMIENTA ES GRATUITA   ***   SI HAS PAGADO POR ESTA ROM, TE HAN ESTAFADO    *** "
    db   "        THIS TEXT CAN BE REPLACED, PLEASE READ THE DOCS         "
msg_blank_line:
    db   "                                        ",0

;==============================================================================
; SPLASH (shown once at boot, before the menu)
;==============================================================================
draw_splash:
    ; line 1: row 8, centered (17 chars -> col 12)
    ld   h, 12
    ld   l, 8
    call POSIT
    ld   hl, splash_l1
    call print_string

    ld   h, 8
    ld   l, 11
    call POSIT
    ld   hl, splash_l2
    call print_string

    ld   h, 9
    ld   l, 12
    call POSIT
    ld   hl, splash_l3
    call print_string

    ld   h, 9
    ld   l, 14
    call POSIT
    ld   hl, splash_l4
    call print_string

    ld   h, 12
    ld   l, 15
    call POSIT
    ld   hl, splash_l5
    call print_string

    ld   h, 9
    ld   l, 18
    call POSIT
    ld   hl, splash_prompt
    call print_string

    call CHGET              ; wait for any key

    xor  a
    call CLS
    ret

splash_l1:
    db "*** A V I S O ***",0
splash_l2:
    db "La herramienta para hacer",0
splash_l3:
    db "esta ROM es GRATUITA.",0
splash_l4:
    db "Si has pagado por ella,",0
splash_l5:
    db "TE HAN ESTAFADO.",0
splash_prompt:
    db "Pulsa cualquier tecla...",0

;==============================================================================
; RAM workspace (page 3, MSX system RAM)
;------------------------------------------------------------------------------
; Declared as equ so no ROM bytes are emitted. The launcher writes/reads
; directly at these addresses. Total: 38 bytes at 0xE000+.
; 0xC000-0xC07F is reserved for the trampoline + params.
;==============================================================================
    end

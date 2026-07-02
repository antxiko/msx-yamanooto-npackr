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
FILVRM  equ 0x0056          ; fill VRAM (HL=addr, BC=len, A=byte)
SETWRT  equ 0x0053          ; set VRAM write address (HL)
WRTVRM  equ 0x004D          ; write A to VRAM (HL)
RDVRM   equ 0x004A          ; read VRAM at HL into A

; System work-area colour vars (read by CHGMOD/INIGRP when it builds SCREEN 2)
FORCLR  equ 0xF3E9          ; foreground colour
BAKCLR  equ 0xF3EA          ; background colour
BDRCLR  equ 0xF3EB          ; border colour

;------------------------------------------------------------------------------
; SCREEN 2 VRAM layout (standard) + the font-blitter menu palette.
;------------------------------------------------------------------------------
PATBASE equ 0x0000          ; pattern generator table (3*2KB = 768 tiles)
NAMBASE equ 0x1800          ; name table (32x24 = 768 bytes)
COLBASE equ 0x2000          ; colour table (per 8x1: fg<<4 | bg)

; NOTE: menu colours are no longer compile-time constants. They are computed
; at boot into v_col_normal/v_col_hilite/v_col_box from the packager-configured
; nibbles cfg_col_text/cfg_col_bg/cfg_col_box (see init_colors). These equates
; are kept only to document the historical defaults.
COL_NORMAL equ 0xF1         ; default: white on black
COL_HILITE equ 0x1F         ; default: black on white (inverse selection bar)
COL_RED    equ 0x81         ; default: medium red on black (title box)

PAGE_ROW   equ 22           ; page counter row (right corner, just above marquee)

SCROLL_RATE equ 1           ; frames between 1px marquee advances

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
FLAG_SRAM   equ 0x20        ; SRAM-emulation game: install sram helper at 0xF070,
                            ; save area = 64KB flash sector (see SRAM table, bank 14)
; bits 5-7 reserved

ASCII16_HELPER_DST equ 0xF000   ; RAM destination for the ASCII16 helper
P_SCC_OFFR_COMP    equ 0xF018   ; OFFR compensated for SCC enable write (1 byte)
P_SCC_OFFR_NORM    equ 0xF019   ; OFFR normal for the game (1 byte)
SCC_HELPER_DST     equ 0xF020   ; RAM destination for the SCC enable helper

;------------------------------------------------------------------------------
; SRAM-emulation helper: parameter block (0xF000) + resident code (0xF030).
; Installed by launch_game when the entry has FLAG_SRAM. The game's bank-switch
; writes are patched by the packager into CALL SRAM_HELPER_DST+3*region.
; NOTE: this REUSES the ASCII16/SCC helper area — an SRAM game never sets
; FLAG_ASCII16/FLAG_SCC_HELPER (its converter subsumes both behaviours).
;------------------------------------------------------------------------------
P_SR_TYPE    equ 0xF000   ; 1=GM2 2=ASCII8SRAM8 3=ASCII16SRAM2 4=ASCII8SRAM2
P_SR_ENBIT   equ 0xF001   ; bank-value bit that selects SRAM (A8: nbanks; else 0x10)
P_SR_SECREL  equ 0xF002   ; save sector base bank, relative to the game (OFFR*4)
P_SR_SLOTBK  equ 0xF003   ; 8KB banks per save slot (A8: 1, GM2: 2)
P_SR_NSLOTS  equ 0xF004   ; save slots per sector (A8: 7, GM2: 3)
P_SR_SLOT    equ 0xF005   ; current committed slot (0xFF = none yet)
P_SR_DIRTY   equ 0xF006   ; shadow modified since last flush
P_SR_FLIP    equ 0xF007   ; page 2 currently flipped to system RAM
P_SR_A8GAME  equ 0xF008   ; primary slot reg value while the game runs
P_SR_A8FLIP  equ 0xF009   ; same with page 2 pointing at the RAM slot
P_SR_EXP     equ 0xF00A   ; RAM lives in an expanded slot (use 0xFFFF too)
P_SR_SUBGAME equ 0xF00B   ; RAM-slot secondary reg value, game state
P_SR_SUBFLIP equ 0xF00C   ; same with page 2 = RAM's page-3 subslot
P_SR_SLTTBL  equ 0xF00D   ; 2 bytes: address of SLTTBL[RAM P3 slot] (0 if !EXP)
P_SR_BANKS   equ 0xF00F   ; 4 bytes: game's view of the 4 bank regs (ROM banks)
P_SR_STATE   equ 0xF013   ; 4 bytes/region: 0x00=ROM, else 0x80|sram_page
P_SR_ERR     equ 0xF017   ; sticky error flag (flush/verify failed)
P_SR_OFFR    equ 0xF018   ; game's OFFR (engine loader restores it)
P_SR_W1BANK  equ 0xF019   ; current game-visible window-1 bank (GM2 restore)
SRAM_HELPER_DST equ 0xF030 ; resident code (entries at +0/+3/+6/+9)
SRAM_CODE_MAX   equ 0x0310 ; hard budget: 0xF030-0xF33F (stack cushion above)
SLTTBL       equ 0xFCC5   ; BIOS: secondary-slot reg copies, 1 byte per primary
EXPTBL       equ 0xFCC1   ; BIOS: bit7 set if primary slot is expanded

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
rl_i          equ RAM_BASE + 39   ; 1 byte: viewport row index during list redraw
rp_x          equ RAM_BASE + 40   ; 2 bytes: current pixel X for the font blitter
marq_char     equ RAM_BASE + 42   ; 1 byte: marquee head char index (0..127)
marq_fine     equ RAM_BASE + 43   ; 1 byte: marquee sub-char pixel offset (0..5)
box_l         equ RAM_BASE + 44   ; 1 byte: title box left edge (pixel x)
box_r         equ RAM_BASE + 45   ; 1 byte: title box right edge (pixel x)
box_lc        equ RAM_BASE + 46   ; 1 byte: box left cell (x>>3)
box_rc        equ RAM_BASE + 47   ; 1 byte: box right cell (x>>3)
box_nc        equ RAM_BASE + 48   ; 1 byte: box cell count
jump_ch       equ RAM_BASE + 49   ; 1 byte: target letter for A-Z jump
pgbuf         equ RAM_BASE + 50   ; 14 bytes: "PAG x/y" text buffer
v_col_normal  equ RAM_BASE + 64   ; 1 byte: text row colour  = text<<4 | bg
v_col_hilite  equ RAM_BASE + 65   ; 1 byte: selection bar    = bg<<4 | text (inverse)
v_col_box     equ RAM_BASE + 66   ; 1 byte: title box edges   = box<<4 | bg
sel_index     equ RAM_BASE + 67   ; 2 bytes: directory index of the launched game
                                  ; (needed to look up its SRAM-table entry)

; Scanline pattern buffer. For the marquee it is used as: 8-byte left guard
; cell (rendered but NOT blitted -> left clip) + 256 visible bytes + 8 slack.
; The menu/splash use the first 256 bytes directly (X starts at 0). 272 total.
LINEBUF       equ 0xE100          ; 272 bytes at 0xE100-0xE20F
MARQ_VIS      equ LINEBUF + 8     ; visible portion for the marquee (256 bytes)

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

    ; --- screen setup (SCREEN 2) using the packager-configured colours ---
    call init_colors        ; build v_col_* in RAM + set FORCLR/BAKCLR/BDRCLR
    ld   a, 2
    call CHGMOD             ; SCREEN 2 (INIGRP builds the VDP tables)
    call scr2_init          ; name table 0..255 x3, blank patterns, base colour

    ei

    call play_jingle        ; Konami-style boot chime (PSG)

    ; --- load directory header (paged in at A000-BFFF) ---
    call dir_page_in
    call dir_validate
    jr   nc, .dir_ok
    call fatal_no_dir
.dir_ok:

    ; --- splash + initial menu ---
    ; Splash is shown only if cfg_splash_enable is non-zero. The packager
    ; flips that byte (locating it via the magic anchor right before it).
    ld   a, (cfg_splash_enable)
    or   a
    call nz, draw_splash
    call menu_init

main_loop:
    halt                    ; one frame tick
    call scroll_tick        ; keep the marquee moving every frame (even during nav)
    call CHSNS              ; Z=1 if no key in buffer
    jr   z, main_loop
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
    call menu_jump_letter   ; A = key; jumps if it's a letter, else no-op
    jp   main_loop

do_launch:
    call menu_get_selected  ; HL = pointer to selected entry in RAM
    call launch_game        ; never returns

;==============================================================================
; FATAL
;==============================================================================
fatal_no_dir:
    ld   hl, msg_no_dir
    ld   a, 20
    ld   b, 10
    call blit_line_at
fatal_halt:
    halt
    jr   fatal_halt

msg_no_dir:
    db   "NO DIRECTORY - REPACK FLASH",0

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
VIEW_ROWS    equ 19         ; game rows visible in the list
LIST_TOP     equ 3          ; first text row of the list (rows 0-2 = boxed title)
TITLE_ROW    equ 1          ; title row (inside the box)
MARQ_ROW     equ 23         ; marquee row (bottom, 0-based)
NAME_X       equ 8          ; start pixel X for game names

; Red title-box geometry (pixels). Box frames the title across rows 0-2.
BOX_TOP_Y    equ 4          ; top edge scanline
BOX_BOT_Y    equ 19         ; bottom edge scanline

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
    call draw_title_box
    call menu_redraw_list
    call menu_redraw_footer
    ret

menu_redraw_footer:
    xor  a                  ; reset marquee to the start of the buffer
    ld   (marq_char), a
    ld   (marq_fine), a
    ld   (scroll_ticker), a
    jp   marquee_render     ; initial draw

; scroll_tick — advance the marquee one pixel every SCROLL_RATE frames, redraw.
scroll_tick:
    ld   a, (scroll_ticker)
    inc  a
    ld   (scroll_ticker), a
    cp   SCROLL_RATE
    ret  c                  ; not time to advance yet
    xor  a
    ld   (scroll_ticker), a
    ld   a, (marq_fine)
    add  a, 2               ; advance 2 px per tick (faster scroll)
    cp   6
    jr   c, st_finestore
    sub  6                  ; wrapped: keep remainder, advance the head char
    ld   (marq_fine), a
    ld   a, (marq_char)
    inc  a
    cp   128
    jr   c, st_charstore
    xor  a
st_charstore:
    ld   (marq_char), a
    jp   marquee_render
st_finestore:
    ld   (marq_fine), a
    jp   marquee_render

menu_redraw_list:
    xor  a
    ld   (rl_i), a
menu_rl_loop:
    call menu_draw_row
    ld   a, (rl_i)
    inc  a
    ld   (rl_i), a
    cp   VIEW_ROWS
    jr   c, menu_rl_loop
    jp   draw_page_indicator

; menu_draw_row — draw the single viewport row whose index is in rl_i.
; Renders the entry name (if valid), flushes it, colours the row normal, and
; overlays the inverse title bar when this row is the cursor row. Cheap enough
; to call twice per cursor move (old + new) so the marquee never stalls.
menu_draw_row:
    call clear_linebuf
    ld   hl, (menu_top)
    ld   a, (rl_i)
    ld   e, a
    ld   d, 0
    add  hl, de           ; hl = entry index
    ex   de, hl           ; de = entry index
    ld   hl, (menu_count)
    or   a
    sbc  hl, de           ; count - index
    jr   z, mdr_empty
    jr   c, mdr_empty
    ld   b, d
    ld   c, e             ; bc = entry index
    call dir_get_entry    ; hl = entry ptr (name at +0)
    ld   a, NAME_X
    call render_str_prop  ; -> LINEBUF, leaves rp_x = title end pixel
mdr_empty:
    ld   a, (rl_i)
    add  a, LIST_TOP
    ld   b, a
    call flush_row_pat
    ld   a, (rl_i)
    add  a, LIST_TOP
    ld   b, a
    ld   a, (v_col_normal)
    call set_row_color
    ld   a, (rl_i)
    ld   hl, menu_cursor
    cp   (hl)
    ret  nz
    jp   hilite_title     ; cursor row: overlay the bar on the title cells

; Overlay the inverse selection bar on just the title cells of the cursor row.
; Uses rl_i (viewport row) and rp_x (title end pixel from the last render).
hilite_title:
    ld   a, (rl_i)
    add  a, LIST_TOP
    ld   h, a
    ld   l, 0               ; HL = row*256
    ld   de, COLBASE + 8    ; colour base + first title cell (NAME_X=8 -> cell 1)
    add  hl, de
    ld   a, (rp_x)          ; title end pixel (low byte; titles < 256)
    dec  a
    rrca
    rrca
    rrca
    and  0x1F               ; last title cell index
    sub  1                  ; minus first cell (NAME_X>>3 = 1)
    inc  a                  ; -> cell count
    add  a, a
    add  a, a
    add  a, a               ; * 8 bytes per cell
    ld   c, a
    ld   b, 0
    ld   a, (v_col_hilite)
    call FILVRM
    ret

menu_cursor_up:
    ld   a, (menu_cursor)
    or   a
    jr   z, menu_prev_page
    ld   (rl_i), a          ; rl_i = old cursor row
    dec  a
    ld   (menu_cursor), a   ; cursor moves up
    call menu_draw_row      ; old row: rl_i != cursor -> normal (bar cleared)
    ld   a, (menu_cursor)
    ld   (rl_i), a
    call menu_draw_row      ; new row: rl_i == cursor -> hilited
    jp   main_loop

menu_cursor_down:
    ld   a, (menu_cursor)
    cp   VIEW_ROWS-1
    jr   z, menu_next_page
    ; don't move the cursor past the last entry
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
    ld   a, (menu_cursor)
    ld   (rl_i), a          ; old cursor row
    inc  a
    ld   (menu_cursor), a   ; cursor moves down
    call menu_draw_row      ; old row -> normal
    ld   a, (menu_cursor)
    ld   (rl_i), a
    call menu_draw_row      ; new row -> hilited
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

; Return HL = pointer to selected entry in paged-in flash (0xA000+ region).
; Also records the directory index in sel_index (the SRAM table is indexed
; by directory position).
menu_get_selected:
    ld   a, (menu_cursor)
    ld   d, 0
    ld   e, a
    ld   hl, (menu_top)
    add  hl, de
    ld   (sel_index), hl
    ld   b, h
    ld   c, l
    call dir_get_entry
    ret

;------------------------------------------------------------------------------
; menu_jump_letter — jump the cursor to the first game whose name starts with
; the letter in A (A-Z, case-insensitive). No-op for non-letter keys.
;------------------------------------------------------------------------------
menu_jump_letter:
    cp   0x61
    jr   c, mjl_up
    cp   0x7B
    jr   nc, mjl_up
    sub  0x20               ; uppercase the pressed key
mjl_up:
    cp   'A'
    ret  c
    cp   'Z' + 1
    ret  nc
    ld   (jump_ch), a
    ld   hl, 0              ; index = 0
mjl_scan:
    ex   de, hl            ; de = index
    ld   hl, (menu_count)
    or   a
    sbc  hl, de           ; count - index
    ret  z                ; scanned all -> no match
    ret  c
    ex   de, hl           ; hl = index
    ld   b, h
    ld   c, l             ; bc = index
    push hl
    call dir_get_entry    ; hl = entry ptr (name at +0)
    ld   a, (hl)          ; first character of the name
    cp   0x61
    jr   c, mjl_cu
    cp   0x7B
    jr   nc, mjl_cu
    sub  0x20             ; uppercase it
mjl_cu:
    ld   hl, jump_ch
    cp   (hl)
    pop  hl               ; hl = index
    jr   z, mjl_found
    inc  hl
    jr   mjl_scan
mjl_found:
    ld   (menu_top), hl   ; put the match at the top of the viewport
    xor  a
    ld   (menu_cursor), a
    jp   menu_redraw_list

;------------------------------------------------------------------------------
; draw_page_indicator — "x/y" (page/total) in the bottom-right corner, sharing
; row 23 with the marquee (which only flushes the left cells). Redrawn from
; menu_redraw_list, i.e. only when the page/view changes.
;------------------------------------------------------------------------------
draw_page_indicator:
    ld   de, pgbuf
    ld   a, 'P'
    ld   (de), a
    inc  de
    ld   a, 'A'
    ld   (de), a
    inc  de
    ld   a, 'G'
    ld   (de), a
    inc  de
    ld   a, ' '
    ld   (de), a
    inc  de
    ld   hl, (menu_top)     ; current page = menu_top / VIEW_ROWS + 1
    call udiv_hl_vr
    inc  a
    call put_u8
    ld   a, '/'
    ld   (de), a
    inc  de
    ld   hl, (menu_count)   ; total = (count - 1) / VIEW_ROWS + 1
    dec  hl
    call udiv_hl_vr
    inc  a
    call put_u8
    xor  a
    ld   (de), a            ; NUL terminate
    ; right-align on PAGE_ROW (its own row, above the marquee)
    ld   hl, pgbuf
    call str_width_px       ; A = width
    ld   b, a
    ld   a, 254
    sub  b                  ; X = 254 - width (2px right margin)
    ld   b, PAGE_ROW
    ld   hl, pgbuf
    jp   blit_line_at

; udiv_hl_vr — A = HL / VIEW_ROWS (quotient). Preserves DE. Destroys HL, B.
udiv_hl_vr:
    push de
    ld   b, 0
udv_loop:
    ld   a, h
    or   a
    jr   nz, udv_sub        ; H != 0 -> HL >= VIEW_ROWS (VIEW_ROWS < 256)
    ld   a, l
    cp   VIEW_ROWS
    jr   c, udv_done
udv_sub:
    ld   de, VIEW_ROWS
    or   a
    sbc  hl, de
    inc  b
    jr   udv_loop
udv_done:
    pop  de
    ld   a, b
    ret

; put_u8 — write A (0-255) as decimal to (DE), no leading zeros, advance DE.
put_u8:
    ld   c, 0               ; "already printed a digit" flag
    ld   b, 100
    call pu_digit
    ld   b, 10
    call pu_digit
    add  a, '0'             ; ones digit (always printed)
    ld   (de), a
    inc  de
    ret
pu_digit:
    ld   l, 0
pu_d1:
    cp   b
    jr   c, pu_d2
    sub  b
    inc  l
    jr   pu_d1
pu_d2:
    push af
    ld   a, l
    or   a
    jr   nz, pu_print       ; nonzero digit -> print
    ld   a, c
    or   a
    jr   z, pu_skip         ; leading zero -> skip
pu_print:
    ld   a, l
    add  a, '0'
    ld   (de), a
    inc  de
    ld   c, 1
pu_skip:
    pop  af
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

    ; SRAM-emulation game? Set up params + install the resident helper.
    ; Done here (still running from launcher ROM, no size pressure) so the
    ; trampoline block does not grow.
    ld   a, (entry_cache + DIR_FLAGS)
    and  FLAG_SRAM
    call nz, sram_setup

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
; SRAM EMULATION (FLAG_SRAM games)
;------------------------------------------------------------------------------
; The Yamanooto has no physical SRAM, but its flash IS runtime-writable via
; ENAR.WREN. Strategy (see docs/SRAM_DESIGN.md):
;   - The packager patches every game bank-register write into
;     CALL SRAM_HELPER_DST + 3*region (bank value still in A).
;   - The resident helper keeps a software copy of the mapper state.
;   - SRAM selected in page 1 (read-only by HW in all supported mappers):
;     map the current save slot's flash bank into that window.
;   - SRAM selected in page 2: FLIP the CPU's page 2 to the system RAM slot
;     ("shadow"). The SRAM half is rebuilt from the save slot in flash, the
;     other half gets a copy of its mapped ROM bank so reads/ISRs stay valid.
;     Arbitrary game writes (LD (HL),A / LDIR...) then land in real RAM.
;   - On SRAM deselect (or page-1 remap) a dirty shadow is FLUSHED to a save
;     slot in the game's dedicated 64KB flash sector (log-structured: program
;     slots 0..N-1, sector-erase only when full; commit byte written last).
; Save sector layout (64KB): banks 0..5 = save slots, bank 7 = META:
;   +0 "YSAV" +4 ver +5 type +6 slot_banks; +0x10 commit log (1 byte/slot,
;   0xFF=free, 0x00=committed, 0x0F=bad).
; Constraint (verified in openMSX AmdFlash/Yamanooto): WREN=1 sends writes in
; 0x4000-0xBFFF to the AMD command interpreter AND freezes banking — bank regs
; must be set BEFORE raising WREN. Unlock addresses 0xAAA/0x555 are reachable
; from any 8KB window (matcher masks (addr>>1)&0x7FF).
;==============================================================================

;------------------------------------------------------------------------------
; sram_setup — called from launch_game (DI, running from launcher ROM) when
; the entry has FLAG_SRAM. Reads the game's SRAM-table entry (flash bank 14),
; scans the save sector's commit log, precomputes slot-flip values and installs
; the resident helper variant at SRAM_HELPER_DST.
;------------------------------------------------------------------------------
SRAM_TABLE_BANK equ 14

sram_setup:
    ld   a, ENAR_REGEN
    ld   (YAMA_ENAR), a         ; open REGEN (OFFR writes below)
    ld   a, SRAM_TABLE_BANK
    ld   (MAP_BANK3), a         ; 0xA000+ = SRAM table (OFFR=0 in the menu)
    ; magic "YSRT"?
    ld   hl, 0xA000
    ld   a, (hl)
    cp   'Y'
    jp   nz, srs_table_bad
    inc  hl
    ld   a, (hl)
    cp   'S'
    jp   nz, srs_table_bad
    inc  hl
    ld   a, (hl)
    cp   'R'
    jp   nz, srs_table_bad
    inc  hl
    ld   a, (hl)
    cp   'T'
    jp   nz, srs_table_bad
    ; entry = 0xA008 + sel_index*8
    ld   hl, (sel_index)
    add  hl, hl
    add  hl, hl
    add  hl, hl
    ld   de, 0xA008
    add  hl, de
    ld   e, (hl)                ; sector_bank low
    inc  hl
    ld   d, (hl)                ; sector_bank high (unused: SECREL is 8-bit)
    inc  hl
    ld   a, (hl)                ; sram_type
    or   a
    jp   z, srs_table_bad
    cp   0xFF
    jp   z, srs_table_bad
    ld   (P_SR_TYPE), a
    inc  hl
    ld   a, (hl)                ; enable bit
    ld   (P_SR_ENBIT), a
    inc  hl
    ld   a, (hl)                ; banks per slot
    ld   (P_SR_SLOTBK), a
    cp   2
    ld   a, 7                   ; 1 bank/slot -> 7 slots (bank 7 = META)
    jr   nz, srs_nslots
    ld   a, 3                   ; 2 banks/slot -> 3 slots
srs_nslots:
    ld   (P_SR_NSLOTS), a
    ; SECREL = (sector_bank - OFFR*4) & 0xFF  (fits by construction)
    ld   a, (P_OFFR)
    add  a, a
    add  a, a
    ld   b, a
    ld   a, e
    sub  b
    ld   (P_SR_SECREL), a
    ; --- scan the commit log (META bank needs the game's OFFR) ---
    ld   a, (P_OFFR)
    ld   (YAMA_OFFR), a
    ld   a, (P_SR_SECREL)
    add  a, 7
    ld   (MAP_BANK3), a         ; META bank at 0xA000 (commits new OFFR)
    ld   hl, 0xA000
    ld   a, (hl)
    cp   'Y'
    jr   nz, srs_no_meta        ; sector never initialised -> no saves yet
    inc  hl
    ld   a, (hl)
    cp   'S'
    jr   nz, srs_no_meta
    inc  hl
    ld   a, (hl)
    cp   'A'
    jr   nz, srs_no_meta
    inc  hl
    ld   a, (hl)
    cp   'V'
    jr   nz, srs_no_meta
    ; find the LAST committed slot (0x00) in the log
    ld   hl, 0xA010
    ld   a, (P_SR_NSLOTS)
    ld   b, a
    ld   c, 0xFF                ; best so far = none
    ld   e, 0                   ; slot index
srs_scan:
    ld   a, (hl)
    cp   0x0F                   ; 0x00/0x01 = committed (page tag); 0x0F/0xFF skip
    jr   nc, srs_scan_next
    ld   c, e                   ; committed: remember (keep scanning: latest wins)
srs_scan_next:
    inc  hl
    inc  e
    djnz srs_scan
    ld   a, c
    jr   srs_have_slot
srs_no_meta:
    ld   a, 0xFF
srs_have_slot:
    ld   (P_SR_SLOT), a
    jr   srs_restore
srs_table_bad:
    ; Corrupt/missing table: install the helper anyway so the game's patched
    ; CALLs stay valid, but with NSLOTS=0 any flush fails fast into P_SR_ERR
    ; (game runs, saves don't persist).
    ld   a, 0xFF
    ld   (P_SR_SLOT), a
    xor  a
    ld   (P_SR_NSLOTS), a
    ld   (P_SR_SECREL), a
    ld   a, 2
    ld   (P_SR_TYPE), a
    ld   a, 0x10
    ld   (P_SR_ENBIT), a
    ld   a, 1
    ld   (P_SR_SLOTBK), a
srs_restore:
    xor  a
    ld   (YAMA_OFFR), a         ; OFFR back to the menu's 0
    ld   a, DIR_BANK
    ld   (MAP_BANK3), a         ; directory back in
    xor  a
    ld   (YAMA_ENAR), a         ; lock regs (trampoline reopens them)
    ; --- runtime state ---
    xor  a
    ld   (P_SR_DIRTY), a
    ld   (P_SR_FLIP), a
    ld   (P_SR_ERR), a
    ld   (P_SR_EXP), a
    ld   hl, P_SR_BANKS
    ld   (hl), 0
    inc  hl
    ld   (hl), 1
    inc  hl
    ld   (hl), 2
    inc  hl
    ld   (hl), 3
    inc  hl                     ; -> P_SR_STATE
    xor  a                      ; 0x00 = ROM everywhere
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    ; --- precompute slot-flip register values ---
    in   a, (0xA8)
    ld   (P_SR_A8GAME), a
    ld   b, a
    and  0xCF                   ; clear page-2 bits
    ld   c, a
    ld   a, b
    rrca
    rrca                        ; page-3 slot bits (6-7) -> page-2 (4-5)
    and  0x30
    or   c
    ld   (P_SR_A8FLIP), a
    ld   a, b
    rlca
    rlca                        ; page-3 primary slot number -> bits 0-1
    and  0x03
    ld   c, a
    ld   b, 0
    ld   hl, EXPTBL
    add  hl, bc
    bit  7, (hl)
    jr   z, srs_not_exp
    ld   a, 1
    ld   (P_SR_EXP), a
    ld   hl, SLTTBL
    add  hl, bc
    ld   (P_SR_SLTTBL), hl
    ld   a, (hl)
    ld   (P_SR_SUBGAME), a
    ld   b, a
    and  0xCF
    ld   c, a
    ld   a, b
    rrca
    rrca
    and  0x30
    or   c
    ld   (P_SR_SUBFLIP), a
srs_not_exp:
    ld   a, (P_OFFR)
    ld   (P_SR_OFFR), a         ; engine loader restores OFFR from here
    ld   a, 1
    ld   (P_SR_W1BANK), a       ; window 1 starts at game bank 1
    ; --- install the mapper variant for this game's SRAM type ---
    ld   a, (P_SR_TYPE)
    cp   1                      ; 1 = GameMaster2
    jr   z, srs_inst_gm2
    ld   hl, sram_a8_src
    ld   de, SRAM_HELPER_DST
    ld   bc, sram_a8_end - sram_a8_src
    ldir
    ret
srs_inst_gm2:
    ld   hl, sram_gm2_src
    ld   de, SRAM_HELPER_DST
    ld   bc, sram_gm2_end - sram_gm2_src
    ldir
    ret

;------------------------------------------------------------------------------
; SRAM helper, ASCII8-SRAM variant. Assembled here in ROM, executed at
; SRAM_HELPER_DST (0xF070): every absolute internal reference is written as
; SRAM_HELPER_DST + (label - sram_a8_src), same relocation pattern as the
; trampoline's helpers. Regions: 0=0x4000 1=0x6000 2=0x8000 3=0xA000; their
; K5 bank regs: 0x5000/0x7000/0x9000/0xB000. A = bank value written by game.
;------------------------------------------------------------------------------
sram_a8_src:
    jp   SRAM_HELPER_DST + (sra_r0 - sram_a8_src)   ; +0  region 0
    jp   SRAM_HELPER_DST + (sra_r1 - sram_a8_src)   ; +3  region 1
    jp   SRAM_HELPER_DST + (sra_r2 - sram_a8_src)   ; +6  region 2
    jp   SRAM_HELPER_DST + (sra_r3 - sram_a8_src)   ; +9  region 3
sra_r0:
    push bc
    ld   c, 0
    jr   sra_common
sra_r1:
    push bc
    ld   c, 1
    jr   sra_common
sra_r2:
    push bc
    ld   c, 2
    jr   sra_common
sra_r3:
    push bc
    ld   c, 3
sra_common:
    push af
    push de
    push hl
    ld   b, a                   ; B = bank value
    ld   a, i                   ; P/V = IFF2
    push af
    di
    ld   a, (P_SR_ENBIT)
    and  b
    jp   nz, SRAM_HELPER_DST + (sra_sram - sram_a8_src)
    ;=== ROM bank value ======================================================
    ld   hl, P_SR_BANKS
    ld   d, 0
    ld   e, c
    add  hl, de
    ld   (hl), b                ; BANKS[c] = value
    ld   hl, P_SR_STATE
    add  hl, de
    ld   a, (hl)
    ld   (hl), 0                ; STATE[c] = ROM
    add  a, a                   ; old bit7 (SRAM) -> carry
    jr   nc, sra_rom_write      ; was ROM already: plain bank write
    ; region was SRAM before
    ld   a, c
    cp   2
    jr   c, sra_rom_write       ; page-1 view: overwrite the flash-map
    ; page-2 region leaves SRAM: other page-2 region still SRAM?
    ld   a, c
    xor  1                      ; 2<->3
    ld   e, a
    ld   hl, P_SR_STATE
    add  hl, de                 ; D is still 0
    bit  7, (hl)
    jr   z, sra_flipout
    ; still flipped: materialise ROM bank B inside this shadow half
    call SRAM_HELPER_DST + (sra_copy_to_half - sram_a8_src)
    jr   sra_exit
sra_flipout:
    call SRAM_HELPER_DST + (sra_flush_if_dirty - sram_a8_src)
    call SRAM_HELPER_DST + (sra_unflip - sram_a8_src)
    ld   a, (P_SR_BANKS+2)      ; re-prime page-2 regs (both ROM now)
    ld   (MAP_BANK2), a
    ld   a, (P_SR_BANKS+3)
    ld   (MAP_BANK3), a
    jr   sra_exit
sra_rom_write:
    call SRAM_HELPER_DST + (sra_wr_bank - sram_a8_src)
    jr   sra_exit
    ;=== SRAM bank value =====================================================
sra_sram:
    ld   hl, P_SR_STATE
    ld   d, 0
    ld   e, c
    add  hl, de
    bit  7, (hl)
    jr   nz, sra_exit           ; already SRAM here: nothing to do
    ld   (hl), 0x80             ; STATE[c] = SRAM (ASCII8: single page)
    ld   a, c
    cp   2
    jr   nc, sra_flipin
    ; page-1 SRAM view is read-only by HW: flush pending changes, then map
    ; the save slot's flash bank into this window.
    call SRAM_HELPER_DST + (sra_flush_if_dirty - sram_a8_src)
    call SRAM_HELPER_DST + (sra_slot_bank - sram_a8_src)
    ld   b, a
    call SRAM_HELPER_DST + (sra_wr_bank - sram_a8_src)
    jr   sra_exit
sra_flipin:
    ld   a, (P_SR_FLIP)
    or   a
    jr   nz, sra_fi_this        ; already flipped: only build this half
    call SRAM_HELPER_DST + (sra_flip - sram_a8_src)
    ; other page-2 half: ROM while FLIP was 0 -> copy its mapped bank
    ld   a, c
    xor  1
    ld   e, a
    ld   d, 0
    ld   hl, P_SR_BANKS
    add  hl, de
    push bc
    ld   b, (hl)                ; B = other half's ROM bank
    ld   c, e                   ; C = other region
    call SRAM_HELPER_DST + (sra_copy_to_half - sram_a8_src)
    pop  bc
sra_fi_this:
    call SRAM_HELPER_DST + (sra_load_half - sram_a8_src)
    ld   a, 1
    ld   (P_SR_DIRTY), a
sra_exit:
    pop  af                     ; P/V = saved IFF2
    jp   po, SRAM_HELPER_DST + (sra_noei - sram_a8_src)
    ei
sra_noei:
    pop  hl
    pop  de
    pop  af
    pop  bc
    ret

; --- write B to region C's bank register (flip-aware) ------------------------
sra_wr_bank:
    ld   a, c
    rrca
    rrca
    rrca                        ; C<<5
    add  a, 0x50                ; 0x50/0x70/0x90/0xB0
    ld   d, a
    ld   e, 0
    ld   a, c
    cp   2
    jr   c, sra_wb_direct       ; page-1 regs always show the cart
    ld   a, (P_SR_FLIP)
    or   a
    jr   z, sra_wb_direct
    ld   a, (P_SR_A8GAME)       ; momentary unflip (subslot regs keep state)
    out  (0xA8), a
    ld   a, b
    ld   (de), a
    ld   a, (P_SR_A8FLIP)
    out  (0xA8), a
    ret
sra_wb_direct:
    ld   a, b
    ld   (de), a
    ret

; --- full flip in/out of page 2 ----------------------------------------------
sra_flip:
    ld   a, (P_SR_EXP)
    or   a
    jr   z, sra_fl_prim
    ld   a, (P_SR_SUBFLIP)
    ld   (0xFFFF), a            ; RAM slot: page-2 subslot = its page-3 one
    push hl
    ld   hl, (P_SR_SLTTBL)
    ld   (hl), a                ; keep BIOS SLTTBL coherent
    pop  hl
sra_fl_prim:
    ld   a, (P_SR_A8FLIP)
    out  (0xA8), a
    ld   a, 1
    ld   (P_SR_FLIP), a
    ret

sra_unflip:
    ld   a, (P_SR_A8GAME)
    out  (0xA8), a
    ld   a, (P_SR_EXP)
    or   a
    jr   z, sra_uf_done
    ld   a, (P_SR_SUBGAME)
    ld   (0xFFFF), a
    push hl
    ld   hl, (P_SR_SLTTBL)
    ld   (hl), a
    pop  hl
sra_uf_done:
    xor  a
    ld   (P_SR_FLIP), a
    ret

; --- copy game ROM bank B into shadow half of region C (requires FLIP) -------
sra_copy_to_half:
    ld   a, b
    ld   (MAP_BANK1), a         ; window 1 = source bank
    ld   a, c
    rrca
    rrca
    rrca                        ; C<<5
    add  a, 0x40                ; region 2 -> 0x80, region 3 -> 0xA0
    ld   d, a
    ld   e, 0
    ld   hl, 0x6000
    push bc
    ld   bc, 0x2000
    ldir
    pop  bc
    jp   SRAM_HELPER_DST + (sra_restore_w1 - sram_a8_src)

; --- build shadow half of region C from the save slot ------------------------
; SLOT==0xFF resolves to the (erased = all 0xFF) slot-0 area, which equals
; "SRAM without battery" for the game.
sra_load_half:
    call SRAM_HELPER_DST + (sra_slot_bank - sram_a8_src)
    ld   b, a                   ; B (game value) no longer needed here
    jp   SRAM_HELPER_DST + (sra_copy_to_half - sram_a8_src)

; --- A = save-slot flash bank (game-relative); SLOT 0xFF -> slot-0 area ------
sra_slot_bank:
    push bc
    ld   a, (P_SR_SLOT)
    cp   0xFF
    jr   nz, ssb_have
    xor  a
ssb_have:
    ld   b, a
    ld   a, (P_SR_SLOTBK)
    dec  a
    jr   z, ssb_one
    sla  b                      ; 2 banks/slot
ssb_one:
    ld   a, (P_SR_SECREL)
    add  a, b
    pop  bc
    ret

; --- restore window 1 to the game's view (ROM bank or SRAM slot map) ---------
sra_restore_w1:
    ld   a, (P_SR_STATE+1)
    bit  7, a
    jr   z, srw1_rom
    call SRAM_HELPER_DST + (sra_slot_bank - sram_a8_src)
    jr   srw1_wr
srw1_rom:
    ld   a, (P_SR_BANKS+1)
srw1_wr:
    ld   (MAP_BANK1), a
    ret

; --- flush shadow -> flash save slot (log-structured) ------------------------
sra_flush_if_dirty:
    ld   a, (P_SR_FLIP)
    or   a
    ret  z
    ld   a, (P_SR_DIRTY)
    or   a
    ret  z
sra_flush:
    ld   a, (P_SR_NSLOTS)
    or   a
    jr   nz, srf_go
    ld   a, 1
    ld   (P_SR_ERR), a
    ret
srf_go:
    ; canonical source half = the page-2 region currently marked SRAM
    ld   a, (P_SR_STATE+3)
    bit  7, a
    ld   h, 0xA0
    jr   nz, srf_src_ok
    ld   h, 0x80
srf_src_ok:
    ld   l, 0                   ; HL = shadow source (RAM, we are flipped)
    ; compare-skip: identical to the committed slot? then nothing to do
    ld   a, (P_SR_SLOT)
    cp   0xFF
    jr   z, srf_new
    call SRAM_HELPER_DST + (sra_slot_bank - sram_a8_src)
    ld   (MAP_BANK1), a
    push hl
    ld   de, 0x6000
    ld   bc, 0x2000
srf_cmp:
    ld   a, (de)
    cpi
    jr   nz, srf_diff
    inc  de
    jp   pe, SRAM_HELPER_DST + (srf_cmp - sram_a8_src)
    pop  hl
    xor  a
    ld   (P_SR_DIRTY), a        ; clean: no wear
    jp   SRAM_HELPER_DST + (sra_restore_w1 - sram_a8_src)
srf_diff:
    pop  hl
srf_new:
    ld   a, (P_SR_SLOT)
    inc  a                      ; 0xFF -> 0
    ld   d, a                   ; D = candidate slot
    ld   e, 0                   ; E = erase-done flag
srf_try:
    ld   a, (P_SR_NSLOTS)
    dec  a
    cp   d
    jr   nc, srf_have           ; d <= NSLOTS-1
    ld   a, e
    or   a
    jp   nz, SRAM_HELPER_DST + (srf_fail - sram_a8_src) ; wrapped twice: give up
    ld   e, 1
    call SRAM_HELPER_DST + (sra_erase_sector - sram_a8_src)
    ld   a, (P_SR_ERR)
    or   a
    jp   nz, SRAM_HELPER_DST + (srf_fail - sram_a8_src)
    ld   d, 0
srf_have:
    push de
    push hl
    ; window 1 = dest bank (MUST precede WREN: banking freezes under WREN)
    ld   a, (P_SR_SLOTBK)
    dec  a
    ld   a, d
    jr   z, srf_sb1
    add  a, a
srf_sb1:
    ld   b, a
    ld   a, (P_SR_SECREL)
    add  a, b
    ld   (MAP_BANK1), a
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    ld   de, 0x6000
    ld   bc, 0x2000
srf_pgm:
    ld   a, (de)
    cp   (hl)
    jr   z, srf_pnext           ; byte already right (erased 0xFF or equal)
    push bc
    ld   c, (hl)
    call SRAM_HELPER_DST + (sra_pgm_byte - sram_a8_src)
    pop  bc
    ld   a, (P_SR_ERR)
    or   a
    jr   nz, srf_bad
srf_pnext:
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, srf_pgm
    xor  a
    ld   (YAMA_ENAR), a         ; WREN off
    ; verify (plain array reads)
    pop  hl
    push hl
    ld   de, 0x6000
    ld   bc, 0x2000
srf_vfy:
    ld   a, (de)
    cpi
    jr   nz, srf_bad
    inc  de
    jp   pe, SRAM_HELPER_DST + (srf_vfy - sram_a8_src)
    ; success: commit (programmed LAST -> power-safe)
    pop  hl
    pop  de
    ld   a, d
    push de
    push hl
    ld   b, 0x00
    call SRAM_HELPER_DST + (sra_meta_byte - sram_a8_src)
    pop  hl
    pop  de
    ld   a, (P_SR_ERR)
    or   a
    jp   nz, SRAM_HELPER_DST + (srf_fail - sram_a8_src)
    ld   a, d
    ld   (P_SR_SLOT), a
    xor  a
    ld   (P_SR_DIRTY), a
    jp   SRAM_HELPER_DST + (sra_restore_w1 - sram_a8_src)
srf_bad:
    ; program/verify failed: give up (v1; next flush retries the next slot)
    pop  hl
    pop  de
    jp   SRAM_HELPER_DST + (srf_fail - sram_a8_src)
srf_fail:
    ld   a, 1
    ld   (P_SR_ERR), a
    xor  a
    ld   (YAMA_ENAR), a
    jp   SRAM_HELPER_DST + (sra_restore_w1 - sram_a8_src)

; --- program one flash byte: (DE) = C. WREN must already be ON. --------------
sra_pgm_byte:
    ld   a, 0xAA
    ld   (0x6AAA), a
    ld   a, 0x55
    ld   (0x6555), a
    ld   a, 0xA0
    ld   (0x6AAA), a
    ld   a, c
    ld   (de), a
    push bc
    ld   b, 0                   ; 256 polls (~2.5ms) >> 60us program time
spb_poll:
    ld   a, (de)
    cp   c
    jr   z, spb_done
    djnz spb_poll
    ld   a, 1
    ld   (P_SR_ERR), a
spb_done:
    pop  bc
    ret

; --- program META commit-log byte: log[A] = B --------------------------------
sra_meta_byte:
    push de
    push bc
    ld   c, b                   ; C = value
    ld   e, a
    ld   a, (P_SR_SECREL)
    add  a, 7
    ld   (MAP_BANK1), a         ; window 1 = META bank (before WREN)
    ld   a, 0x10
    add  a, e
    ld   e, a
    ld   d, 0x60                ; DE = 0x6010 + slot
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    call SRAM_HELPER_DST + (sra_pgm_byte - sram_a8_src)
    xor  a
    ld   (YAMA_ENAR), a
    pop  bc
    pop  de
    ret

; --- erase the save sector (~500ms, DI) and rewrite the META header ----------
sra_erase_sector:
    push bc
    push de
    ld   a, (P_SR_SECREL)
    ld   (MAP_BANK1), a         ; any bank inside the sector selects it
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
    ld   (0x6000), a            ; sector erase
    ld   bc, 0                  ; 65536-iteration poll (~2.7s worst case)
sre_poll:
    ld   a, (0x6000)
    cp   0xFF
    jr   z, sre_done
    ld   d, 8
sre_dly:
    dec  d
    jr   nz, sre_dly
    dec  bc
    ld   a, b
    or   c
    jr   nz, sre_poll
    ld   a, 1
    ld   (P_SR_ERR), a
    jr   sre_exit
sre_done:
    ; rewrite META header: "YSAV", ver, type, slot_banks
    xor  a
    ld   (YAMA_ENAR), a
    ld   a, (P_SR_SECREL)
    add  a, 7
    ld   (MAP_BANK1), a
    ld   a, ENAR_WREN
    ld   (YAMA_ENAR), a
    ; first the two RAM-sourced bytes into the header staging spots
    ld   a, (P_SR_TYPE)
    ld   (SRAM_HELPER_DST + (sre_hdr + 5 - sram_a8_src)), a
    ld   a, (P_SR_SLOTBK)
    ld   (SRAM_HELPER_DST + (sre_hdr + 6 - sram_a8_src)), a
    ld   de, 0x6000
    ld   hl, SRAM_HELPER_DST + (sre_hdr - sram_a8_src)
    ld   b, 7
sre_hloop:
    ld   c, (hl)
    call SRAM_HELPER_DST + (sra_pgm_byte - sram_a8_src)
    inc  hl
    inc  de
    djnz sre_hloop
sre_exit:
    xor  a
    ld   (YAMA_ENAR), a
    pop  de
    pop  bc
    ret
sre_hdr:
    db   "YSAV", 1, 0, 0        ; +5/+6 patched with TYPE/SLOTBK before use
sram_a8_end:

; Hard budget check: the installed helper must fit 0xF070-0xF2FF.
    ds   SRAM_CODE_MAX - (sram_a8_end - sram_a8_src), 0xFF

;------------------------------------------------------------------------------
; SRAM helper, GameMaster2 variant — executed at SRAM_HELPER_DST (0xF030).
; GM2 registers 0x6000/0x8000/0xA000 (bit12==0) = regions 1/2/3 (region 0 has
; no register). Bank value: bit4 = SRAM select, bit5 = SRAM page (2 pages of
; 4KB), bits 0-3 = 8KB ROM bank. The SRAM is only WRITABLE at 0xB000-0xBFFF
; (region 3), so the slot-flip is only entered there; regions 1/2 SRAM views
; are read-only -> flash-map of the page's save slot (page duplicated in the
; bank, so the 4KB-mirrored-in-8KB view is exact).
; Save sector: 7 single-bank slots + META; commit log tags each slot with its
; page (0x00/0x01). The flush machinery is sram_engine_gm2.bin, loaded on
; demand at 0x8000 (scratch half of the flipped shadow) by smg_engine.
;------------------------------------------------------------------------------
sram_gm2_src:
    jp   SRAM_HELPER_DST + (smg_r0 - sram_gm2_src)   ; +0 (unused on GM2)
    jp   SRAM_HELPER_DST + (smg_r1 - sram_gm2_src)   ; +3 reg 0x6000
    jp   SRAM_HELPER_DST + (smg_r2 - sram_gm2_src)   ; +6 reg 0x8000
    jp   SRAM_HELPER_DST + (smg_r3 - sram_gm2_src)   ; +9 reg 0xA000
smg_r0:
    ret                          ; no region-0 register: safe no-op
smg_r1:
    push bc
    ld   c, 1
    jr   smg_common
smg_r2:
    push bc
    ld   c, 2
    jr   smg_common
smg_r3:
    push bc
    ld   c, 3
smg_common:
    push af
    push de
    push hl
    ld   b, a                   ; B = value written by the game
    ld   a, i                   ; P/V = IFF2
    push af
    di
    ld   a, (P_SR_ENBIT)        ; 0x10
    and  b
    jp   nz, SRAM_HELPER_DST + (smg_sram - sram_gm2_src)
    ;=== ROM bank value ======================================================
    ld   a, b
    and  0x0F
    ld   b, a                   ; B = 8KB ROM bank (GM2 pairs of 4KB blocks)
    ld   hl, P_SR_BANKS
    ld   d, 0
    ld   e, c
    add  hl, de
    ld   (hl), b
    ld   hl, P_SR_STATE
    add  hl, de
    ld   a, (hl)
    ld   d, a                   ; D = old state
    ld   (hl), 0                ; STATE[c] = ROM
    add  a, a
    jr   nc, smg_rom_write      ; was ROM already
    ld   a, c
    cp   3
    jr   nz, smg_rom_write      ; r1/r2 leaving SRAM: plain remap
    ; region 3 leaves SRAM (flipped): flush old page, unflip, reprime page 2
    ld   a, (P_SR_DIRTY)
    or   a
    jr   z, smg_fo_nf
    ld   a, d
    and  0x01                   ; old page
    call SRAM_HELPER_DST + (smg_engine - sram_gm2_src)
smg_fo_nf:
    call SRAM_HELPER_DST + (smg_unflip - sram_gm2_src)
    ld   a, b
    ld   (MAP_BANK3), a         ; region 3 = its new ROM bank
    ld   a, (P_SR_STATE+2)      ; region 2 reprime per its state
    add  a, a
    jr   c, smg_fo_sr2
    ld   a, (P_SR_BANKS+2)
    ld   (MAP_BANK2), a
    jp   SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
smg_fo_sr2:
    ld   a, (P_SR_STATE+2)
    and  0x01
    call SRAM_HELPER_DST + (smg_page_bank - sram_gm2_src)
    ld   (MAP_BANK2), a
    jp   SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
smg_rom_write:
    ; r2 going ROM while flipped (r3 still SRAM): materialise bank in shadow
    ld   a, c
    cp   2
    jr   nz, smg_rw_reg
    ld   a, (P_SR_FLIP)
    or   a
    jr   z, smg_rw_reg
    call SRAM_HELPER_DST + (smg_copy8k_r2 - sram_gm2_src)
    jp   SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
smg_rw_reg:
    call SRAM_HELPER_DST + (smg_wr_bank - sram_gm2_src)
    jp   SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
    ;=== SRAM value ==========================================================
smg_sram:
    ld   a, b
    rlca
    rlca
    rlca                        ; bit5 -> bit0
    and  0x01
    ld   e, a                   ; E = page p
    or   0x80
    ld   d, a                   ; D = new state 0x80|p
    ld   a, c
    cp   3
    jr   z, smg_sr3
    cp   1
    jr   z, smg_sr1
    ; --- region 2: read-only SRAM view -------------------------------------
    ld   hl, P_SR_STATE+2
    ld   a, (hl)
    cp   d
    jp   z, SRAM_HELPER_DST + (smg_exit - sram_gm2_src)            ; same page already mapped
    ld   (hl), d
    ld   a, (P_SR_FLIP)
    or   a
    jr   z, smg_sr2_map
    ld   a, e
    call SRAM_HELPER_DST + (smg_page_bank - sram_gm2_src)
    ld   b, a
    call SRAM_HELPER_DST + (smg_dup_r2 - sram_gm2_src)
    jp   SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
smg_sr2_map:
    ld   a, e
    call SRAM_HELPER_DST + (smg_page_bank - sram_gm2_src)
    ld   b, a
    ld   c, 2
    call SRAM_HELPER_DST + (smg_wr_bank - sram_gm2_src)
    jp   SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
    ; --- region 1: read-only SRAM view -------------------------------------
smg_sr1:
    ld   hl, P_SR_STATE+1
    ld   a, (hl)
    cp   d
    jp   z, SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
    ld   (hl), d
    call SRAM_HELPER_DST + (smg_flush_ifd - sram_gm2_src)
    ld   a, e
    call SRAM_HELPER_DST + (smg_page_bank - sram_gm2_src)
    ld   b, a
    ld   c, 1
    call SRAM_HELPER_DST + (smg_wr_bank - sram_gm2_src)
    jp   SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
    ; --- region 3: the writable window (flip domain) ------------------------
smg_sr3:
    ld   hl, P_SR_STATE+3
    ld   a, (hl)
    cp   d
    jp   z, SRAM_HELPER_DST + (smg_exit - sram_gm2_src)
    ld   b, a                   ; B = old state
    ld   (hl), d
    ld   a, b
    add  a, a
    jr   nc, smg_fi3            ; was ROM: full flip-in
    ; page switch: flush the OLD page if dirty, then load the new one
    ld   a, (P_SR_DIRTY)
    or   a
    jr   z, smg_sw_load
    ld   a, b
    and  0x01
    call SRAM_HELPER_DST + (smg_engine - sram_gm2_src)
    call SRAM_HELPER_DST + (smg_build_r2 - sram_gm2_src)
    jr   smg_sw_load
smg_fi3:
    call SRAM_HELPER_DST + (smg_flip - sram_gm2_src)
    call SRAM_HELPER_DST + (smg_build_r2 - sram_gm2_src)
smg_sw_load:
    ld   a, e
    call SRAM_HELPER_DST + (smg_page_bank - sram_gm2_src)
    ld   b, a
    call SRAM_HELPER_DST + (smg_dup_r3 - sram_gm2_src)
    ld   a, 1
    ld   (P_SR_DIRTY), a
smg_exit:
    pop  af
    jp   po, SRAM_HELPER_DST + (smg_noei - sram_gm2_src)
    ei
smg_noei:
    pop  hl
    pop  de
    pop  af
    pop  bc
    ret

; --- flush if flipped+dirty (region-1 remap path) -----------------------------
smg_flush_ifd:
    ld   a, (P_SR_FLIP)
    or   a
    ret  z
    ld   a, (P_SR_DIRTY)
    or   a
    ret  z
    ld   a, (P_SR_STATE+3)
    and  0x01
    call SRAM_HELPER_DST + (smg_engine - sram_gm2_src)
    jp   SRAM_HELPER_DST + (smg_build_r2 - sram_gm2_src)

; --- load + run the flush engine (A = page to flush). Requires FLIP. ----------
smg_engine:
    push af
    ld   a, ENAR_REGEN
    ld   (YAMA_ENAR), a
    xor  a
    ld   (YAMA_OFFR), a         ; absolute banking: reach the launcher banks
    ld   a, GM2_ENGINE_BANK
    ld   (MAP_BANK1), a
    ld   hl, 0x6000 + GM2_ENGINE_OFF
    ld   de, 0x8000
    ld   bc, GM2_ENGINE_LEN
    ldir
    ld   a, (P_SR_OFFR)
    ld   (YAMA_OFFR), a         ; back to the game's offset
    xor  a
    ld   (YAMA_ENAR), a
    pop  af
    call 0x8000                 ; run the engine (DI, flipped)
    jp   SRAM_HELPER_DST + (smg_restore_w1 - sram_gm2_src)

; --- A = page (0/1) -> A = its save-slot bank (game-relative) -----------------
; Latest committed slot for that page; if none, the last (erased) slot area.
smg_page_bank:
    push bc
    push de
    push hl
    ld   c, a
    ld   a, (P_SR_SECREL)
    add  a, 7
    ld   (MAP_BANK1), a         ; window 1 = META
    ld   hl, 0x6010
    ld   a, (P_SR_NSLOTS)
    ld   b, a
    ld   d, 0
    ld   e, 0xFF
smb_loop:
    ld   a, (hl)
    cp   c
    jr   nz, smb_next
    ld   e, d
smb_next:
    inc  hl
    inc  d
    djnz smb_loop
    ld   a, e
    cp   0xFF
    jr   nz, smb_have
    ld   a, (P_SR_NSLOTS)
    dec  a                      ; virgin page -> last slot area (erased 0xFF)
smb_have:
    ld   b, a
    ld   a, (P_SR_SECREL)
    add  a, b
    ld   b, a
    call SRAM_HELPER_DST + (smg_restore_w1 - sram_gm2_src)
    ld   a, b
    pop  hl
    pop  de
    pop  bc
    ret

; --- rebuild the 0x8000 scratch half per STATE[2] (requires FLIP) -------------
smg_build_r2:
    ld   a, (P_SR_STATE+2)
    add  a, a
    jr   c, smb2_sram
    ld   a, (P_SR_BANKS+2)
    ld   b, a
    jp   SRAM_HELPER_DST + (smg_copy8k_r2 - sram_gm2_src)
smb2_sram:
    ld   a, (P_SR_STATE+2)
    and  0x01
    call SRAM_HELPER_DST + (smg_page_bank - sram_gm2_src)
    ld   b, a
    ; fall through: page dup into 0x8000/0x9000
smg_dup_r2:                     ; bank B: 4KB dup -> 0x8000 + 0x9000
    ld   d, 0x80
    jr   smg_dup
smg_dup_r3:                     ; bank B: 4KB dup -> 0xA000 + 0xB000
    ld   d, 0xA0
smg_dup:
    ld   a, b
    ld   (MAP_BANK1), a
    ld   e, 0
    ld   hl, 0x6000
    push bc
    push de
    ld   bc, 0x1000
    ldir                        ; first 4KB half
    pop  de
    ld   a, d
    add  a, 0x10
    ld   d, a                   ; second half (+0x1000)
    ld   e, 0
    ld   hl, 0x6000
    ld   bc, 0x1000
    ldir
    pop  bc
    jp   SRAM_HELPER_DST + (smg_restore_w1 - sram_gm2_src)

; --- copy ROM bank B (8KB) into the 0x8000 half (requires FLIP) ---------------
smg_copy8k_r2:
    ld   a, b
    ld   (MAP_BANK1), a
    ld   hl, 0x6000
    ld   de, 0x8000
    push bc
    ld   bc, 0x2000
    ldir
    pop  bc
    jp   SRAM_HELPER_DST + (smg_restore_w1 - sram_gm2_src)

; --- window 1 back to the game's view (tracked in P_SR_W1BANK) ----------------
smg_restore_w1:
    ld   a, (P_SR_W1BANK)
    ld   (MAP_BANK1), a
    ret

; --- write B to region C's K5 bank reg (flip-aware; tracks window 1) ----------
smg_wr_bank:
    ld   a, c
    cp   1
    jr   nz, swb_nw1
    ld   a, b
    ld   (P_SR_W1BANK), a       ; region 1 = window 1: remember the mapping
swb_nw1:
    ld   a, c
    rrca
    rrca
    rrca                        ; C<<5
    add  a, 0x50                ; 0x50/0x70/0x90/0xB0
    ld   d, a
    ld   e, 0
    ld   a, c
    cp   2
    jr   c, swb_direct
    ld   a, (P_SR_FLIP)
    or   a
    jr   z, swb_direct
    ld   a, (P_SR_A8GAME)
    out  (0xA8), a
    ld   a, b
    ld   (de), a
    ld   a, (P_SR_A8FLIP)
    out  (0xA8), a
    ret
swb_direct:
    ld   a, b
    ld   (de), a
    ret

; --- full page-2 flip in/out ---------------------------------------------------
smg_flip:
    ld   a, (P_SR_EXP)
    or   a
    jr   z, smf_prim
    ld   a, (P_SR_SUBFLIP)
    ld   (0xFFFF), a
    push hl
    ld   hl, (P_SR_SLTTBL)
    ld   (hl), a
    pop  hl
smf_prim:
    ld   a, (P_SR_A8FLIP)
    out  (0xA8), a
    ld   a, 1
    ld   (P_SR_FLIP), a
    ret

smg_unflip:
    ld   a, (P_SR_A8GAME)
    out  (0xA8), a
    ld   a, (P_SR_EXP)
    or   a
    jr   z, smu_done
    ld   a, (P_SR_SUBGAME)
    ld   (0xFFFF), a
    push hl
    ld   hl, (P_SR_SLTTBL)
    ld   (hl), a
    pop  hl
smu_done:
    xor  a
    ld   (P_SR_FLIP), a
    ret
sram_gm2_end:

; Hard budget check for the GM2 variant.
    ds   SRAM_CODE_MAX - (sram_gm2_end - sram_gm2_src), 0xFF

; --- GM2 flush engine blob (assembled separately, loaded at 0x8000) -----------
sram_gm2_engine_blob:
    incbin "sram_engine_gm2.bin"
sram_gm2_engine_end:
GM2_ENGINE_BANK equ (sram_gm2_engine_blob - 0x4000) / 0x2000
GM2_ENGINE_OFF  equ (sram_gm2_engine_blob - 0x4000) AND 0x1FFF
GM2_ENGINE_LEN  equ sram_gm2_engine_end - sram_gm2_engine_blob

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
; SCREEN 2 FONT BLITTER (proportional, 6px advance, via a RAM line buffer)
;==============================================================================

; init_colors — read the packager-configured colour nibbles (cfg_col_*) and
; build the three colour-table bytes the menu uses, in RAM. Also seeds the
; BIOS colour work area so INIGRP's initial fill matches. Nibbles masked 0-15.
;   v_col_normal = text<<4 | bg      (list rows, title text)
;   v_col_hilite = bg<<4  | text     (inverse selection bar)
;   v_col_box    = box<<4 | bg       (title box edges)
init_colors:
    ld   a, (cfg_col_text)
    and  0x0F
    ld   b, a               ; B = text nibble
    ld   a, (cfg_col_bg)
    and  0x0F
    ld   c, a               ; C = bg nibble
    ld   a, b
    rlca
    rlca
    rlca
    rlca                    ; A = text<<4
    or   c
    ld   (v_col_normal), a
    ld   a, c
    rlca
    rlca
    rlca
    rlca                    ; A = bg<<4
    or   b
    ld   (v_col_hilite), a
    ld   a, (cfg_col_box)
    and  0x0F
    rlca
    rlca
    rlca
    rlca                    ; A = box<<4
    or   c
    ld   (v_col_box), a
    ld   a, b
    ld   (FORCLR), a        ; BIOS text colour
    ld   a, c
    ld   (BAKCLR), a        ; BIOS background
    ld   (BDRCLR), a        ; BIOS border
    ret

; scr2_init — after CHGMOD 2: name table = 0,1,..,255 (x3 thirds), blank
; patterns, base colour from v_col_normal everywhere.
scr2_init:
    ld   hl, NAMBASE
    call SETWRT
    ld   c, 3               ; three thirds of the screen
scr2_nt_third:
    xor  a
scr2_nt_byte:
    out  (0x98), a
    inc  a
    jr   nz, scr2_nt_byte   ; write 0..255, then A wraps to 0 -> next third
    dec  c
    jr   nz, scr2_nt_third
    ld   hl, PATBASE
    ld   bc, 0x1800
    xor  a
    call FILVRM             ; blank all patterns (6144 bytes)
    ld   hl, COLBASE
    ld   bc, 0x1800
    ld   a, (v_col_normal)
    call FILVRM             ; white on black everywhere
    ret

; clear_linebuf — zero the 264-byte line buffer. Preserves all registers.
clear_linebuf:
    push af
    push bc
    push de
    push hl
    ld   hl, LINEBUF
    ld   de, LINEBUF + 1
    ld   bc, 271
    ld   (hl), 0
    ldir
    pop  hl
    pop  de
    pop  bc
    pop  af
    ret

; blit_line_at — draw a whole text line. In: HL=asciiz, A=start pixel X, B=row.
blit_line_at:
    call clear_linebuf      ; (preserves regs)
    push bc                 ; save row
    call render_str_prop    ; A=startX, HL=string -> LINEBUF
    pop  bc                 ; B=row
    push bc                 ; flush_row_pat does ld bc,256 -> keep the row
    call flush_row_pat      ; LINEBUF -> VRAM pattern row
    pop  bc                 ; B=row
    ld   a, (v_col_normal)
    call set_row_color
    ret

; blit_center — draw a string horizontally centred on the 256px row.
; In: HL=asciiz, B=row.
blit_center:
    push hl                 ; measure length -> C
    ld   c, 0
bcen_len:
    ld   a, (hl)
    or   a
    jr   z, bcen_done
    inc  hl
    inc  c
    jr   bcen_len
bcen_done:
    pop  hl
    ld   a, c               ; width = c*6
    add  a, a
    ld   d, a               ; 2c
    add  a, a               ; 4c
    add  a, d               ; 6c
    neg                     ; A = 256 - width (mod 256)
    srl  a                  ; X = (256 - width) / 2
    jp   blit_line_at       ; A=X, B=row, HL=string

; render_str_prop — render ASCIIZ into LINEBUF (must be pre-cleared).
; In: HL=string, A=start pixel X. Stops at NUL or right edge.
render_str_prop:
    push hl                 ; save string ptr
    ld   l, a
    ld   h, 0
    ld   (rp_x), hl         ; rp_x = start pixel X (16-bit)
    pop  hl
rsp_loop:
    ld   a, (hl)
    or   a
    ret  z
    ld   a, (rp_x)          ; low byte (menu/splash X stays < 256)
    cp   251                ; room for one more 6px glyph?
    ret  nc
    ld   a, (hl)            ; char
    push hl
    call render_char_prop
    pop  hl
    inc  hl
    jr   rsp_loop

; render_char_prop — blit one glyph into LINEBUF at pixel rp_x (16-bit),
; advance rp_x by 6. In: A = character. Auto-uppercases a..z; oob -> space.
render_char_prop:
    cp   0x61
    jr   c, rcp_nolow
    cp   0x7B
    jr   nc, rcp_nolow
    sub  0x20               ; a..z -> A..Z
rcp_nolow:
    sub  0x20               ; index = char - 0x20
    jr   c, rcp_space
    cp   64
    jr   c, rcp_ok
rcp_space:
    xor  a                  ; glyph 0 = space
rcp_ok:
    push iy
    ; dest cell -> IY = LINEBUF + (rp_x>>3)*8 ; B = shift (rp_x & 7)
    ld   hl, (rp_x)         ; HL = pixel X (16-bit)
    ld   c, a               ; stash glyph index
    ld   a, l
    and  7
    ld   b, a               ; B = shift
    srl  h
    rr   l
    srl  h
    rr   l
    srl  h
    rr   l                  ; HL = cell (rp_x>>3)
    add  hl, hl
    add  hl, hl
    add  hl, hl             ; HL = cell*8
    ld   de, LINEBUF
    add  hl, de
    push hl
    pop  iy                 ; IY = &LINEBUF[cell*8]
    ; src -> HL = font + index*8
    ld   l, c
    ld   h, 0
    add  hl, hl
    add  hl, hl
    add  hl, hl             ; index*8
    ld   de, font
    add  hl, de             ; HL = glyph source
    ld   c, 8               ; 8 pixel rows
rcp_rows:
    ld   a, (hl)            ; glyph row byte
    inc  hl
    ld   d, a
    ld   e, 0               ; DE = g<<8
    ld   a, b
    or   a
    jr   z, rcp_noshift
    push bc
    ld   b, a
rcp_sh:
    srl  d
    rr   e
    djnz rcp_sh
    pop  bc
rcp_noshift:
    ld   a, (iy+0)
    or   d
    ld   (iy+0), a          ; hi part into this cell
    ld   a, (iy+8)
    or   e
    ld   (iy+8), a          ; lo part into next cell
    inc  iy
    dec  c
    jr   nz, rcp_rows
    pop  iy
    ld   hl, (rp_x)         ; advance X by 6 (16-bit)
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    ld   (rp_x), hl
    ret

; flush_row_pat — LINEBUF (256 bytes) -> pattern row. In: B = text row.
flush_row_pat:
    ld   h, b
    ld   l, 0               ; HL = row*256
    ex   de, hl             ; DE = VRAM dest (PATBASE=0)
    ld   hl, LINEBUF
    ld   bc, 256
    call LDIRVM
    ret

; set_row_color — fill a text row's colour cells. In: B = row, A = colour.
set_row_color:
    push af
    ld   h, b
    ld   l, 0
    ld   de, COLBASE
    add  hl, de             ; HL = COLBASE + row*256
    ld   bc, 256
    pop  af
    call FILVRM
    ret

;------------------------------------------------------------------------------
; MARQUEE — pixel-smooth bottom scroll.
; State: marq_char (head char 0..127) + marq_fine (0..5 pixel offset). The
; 128-byte customizable buffer is stored twice back-to-back (scroll_text and
; its copy) so ~43 chars can be read from any head index without wrapping.
; The head char is drawn at physical X = 8 - fine; the 8-byte guard cell it
; spills into is never blitted, giving a clean left-edge clip.
;------------------------------------------------------------------------------
marquee_render:
    call clear_linebuf
    ld   a, 8
    ld   hl, marq_fine
    sub  (hl)               ; A = 8 - fine (first char physical X, 3..8)
    ld   l, a
    ld   h, 0
    ld   (rp_x), hl
    ld   a, (marq_char)
    ld   e, a
    ld   d, 0
    ld   hl, scroll_text
    add  hl, de             ; HL = &scroll_text[marq_char]
mr_loop:
    push hl
    ld   hl, (rp_x)
    ld   de, 264
    or   a
    sbc  hl, de
    pop  hl
    jr   nc, mr_done        ; rp_x >= 264 -> visible row filled
    ld   a, (hl)
    push hl
    call render_char_prop
    pop  hl
    inc  hl
    jr   mr_loop
mr_done:
    ld   b, MARQ_ROW
    ; fall through to flush_marq

; flush_marq — copy the 256 visible bytes (LINEBUF+8) to pattern row B.
flush_marq:
    ld   h, b
    ld   l, 0               ; HL = row*256
    ex   de, hl             ; DE = VRAM dest
    ld   hl, MARQ_VIS       ; skip the 8-byte left guard
    ld   bc, 256            ; full-width marquee (counter is on its own row)
    call LDIRVM
    ret

;==============================================================================
; TITLE + RED ROUNDED BOX
;------------------------------------------------------------------------------
; Renders the centred title on TITLE_ROW and frames it with a red rectangle
; whose four corner pixels are left blank (rounded look).
;==============================================================================
draw_title_box:
    ld   hl, msg_title
    call str_width_px       ; A = title width in pixels
    ld   b, a               ; B = width
    neg
    srl  a
    ld   c, a               ; C = x_start = (256 - width) / 2
    ; box_l = x_start - 8 ; box_r = x_start + width + 6
    ld   a, c
    sub  8
    ld   (box_l), a
    ld   a, c
    add  a, b
    add  a, 6
    ld   (box_r), a
    ; render the centred title
    ld   hl, msg_title
    ld   a, c               ; X = x_start
    ld   b, TITLE_ROW
    call blit_line_at
    call draw_box_edges
    jp   colour_box_red

; str_width_px — HL=asciiz -> A = length*6 (assumes < 256). Clobbers HL.
str_width_px:
    ld   c, 0
swpx_loop:
    ld   a, (hl)
    or   a
    jr   z, swpx_done
    inc  hl
    inc  c
    jr   swpx_loop
swpx_done:
    ld   a, c
    add  a, a
    ld   b, a               ; 2c
    add  a, a               ; 4c
    add  a, b               ; 6c
    ret

; vpset — set one pixel in the pattern table. In: D=x (0..255), E=y (0..191).
vpset:
    ld   a, e
    rrca
    rrca
    rrca
    and  0x1F
    ld   h, a               ; H = y>>3
    ld   a, d
    and  0xF8
    ld   l, a               ; L = (x>>3)*8
    ld   a, e
    and  0x07
    add  a, l
    ld   l, a               ; L += y&7  -> HL = pattern byte address
    ld   a, d
    and  0x07
    ld   b, a
    ld   c, 0x80
    inc  b
vps_rot:
    dec  b
    jr   z, vps_set
    srl  c
    jr   vps_rot
vps_set:
    push bc                 ; keep the bit mask across RDVRM
    call RDVRM              ; A = VRAM(HL)
    pop  bc
    or   c
    call WRTVRM             ; VRAM(HL) = A | mask
    ret

; hline — plot pixels x=C..B at y=E.
hline:
hln_loop:
    push bc
    push de
    ld   d, c
    call vpset
    pop  de
    pop  bc
    ld   a, c
    cp   b
    ret  z
    inc  c
    jr   hln_loop

; vline — plot pixels y=C..B at x=D.
vline:
vln_loop:
    push bc
    push de
    ld   e, c
    call vpset
    pop  de
    pop  bc
    ld   a, c
    cp   b
    ret  z
    inc  c
    jr   vln_loop

; draw_box_edges — the four red edges, corners left 1px short (rounded).
draw_box_edges:
    ld   a, (box_l)
    inc  a
    ld   c, a
    ld   a, (box_r)
    dec  a
    ld   b, a
    ld   e, BOX_TOP_Y
    call hline              ; top edge
    ld   a, (box_l)
    inc  a
    ld   c, a
    ld   a, (box_r)
    dec  a
    ld   b, a
    ld   e, BOX_BOT_Y
    call hline              ; bottom edge
    ld   a, (box_l)
    ld   d, a
    ld   c, BOX_TOP_Y + 1
    ld   b, BOX_BOT_Y - 1
    call vline              ; left edge
    ld   a, (box_r)
    ld   d, a
    ld   c, BOX_TOP_Y + 1
    ld   b, BOX_BOT_Y - 1
    jp   vline              ; right edge (tail)

; col_span — colour a run of cells. In: B=row, D=firstcell, E=ncells, A=colour.
col_span:
    push af
    ld   h, b
    ld   l, 0               ; HL = row*256
    ld   a, d
    add  a, a
    add  a, a
    add  a, a               ; firstcell*8
    ld   c, a
    ld   b, 0
    add  hl, bc
    ld   bc, COLBASE
    add  hl, bc             ; HL = COLBASE + row*256 + firstcell*8
    ld   a, e
    add  a, a
    add  a, a
    add  a, a               ; ncells*8
    ld   c, a
    ld   b, 0
    pop  af
    call FILVRM
    ret

; colour_box_red — paint the box cells red (title cells stay white).
colour_box_red:
    ld   a, (box_l)
    rrca
    rrca
    rrca
    and  0x1F
    ld   (box_lc), a
    ld   a, (box_r)
    rrca
    rrca
    rrca
    and  0x1F
    ld   (box_rc), a
    ld   hl, box_lc
    sub  (hl)               ; A = rightcell - leftcell
    inc  a
    ld   (box_nc), a        ; cell count for the horizontal edges
    ; top edge row 0
    ld   a, (box_lc)
    ld   d, a
    ld   a, (box_nc)
    ld   e, a
    ld   b, 0
    ld   a, (v_col_box)
    call col_span
    ; bottom edge row 2
    ld   a, (box_lc)
    ld   d, a
    ld   a, (box_nc)
    ld   e, a
    ld   b, 2
    ld   a, (v_col_box)
    call col_span
    ; left side cell, row 1
    ld   a, (box_lc)
    ld   d, a
    ld   e, 1
    ld   b, 1
    ld   a, (v_col_box)
    call col_span
    ; right side cell, row 1
    ld   a, (box_rc)
    ld   d, a
    ld   e, 1
    ld   b, 1
    ld   a, (v_col_box)
    call col_span
    ret

;==============================================================================
; BOOT JINGLE — short Konami-style ascending arpeggio on PSG channel A.
; Uses the MSX internal PSG (I/O 0xA0 address / 0xA1 data). reg7 = 0xBE keeps
; the standard MSX port directions (A input, B output) so nothing else breaks.
;==============================================================================
JINGLE_N equ 6
play_jingle:
    ld   a, 7               ; mixer
    out  (0xA0), a
    ld   a, 0xBE            ; tone A enabled; port dirs preserved
    out  (0xA1), a
    ld   a, 8               ; channel A volume register
    out  (0xA0), a
    ld   a, 13
    out  (0xA1), a
    ld   hl, jingle_notes
    ld   b, JINGLE_N
pj_loop:
    push bc
    xor  a                  ; reg 0 = tone A period, fine
    out  (0xA0), a
    ld   a, (hl)
    out  (0xA1), a
    inc  hl
    ld   a, 1               ; reg 1 = tone A period, coarse
    out  (0xA0), a
    ld   a, (hl)
    out  (0xA1), a
    inc  hl
    ld   b, (hl)            ; duration in frames
    inc  hl
pj_delay:
    halt
    djnz pj_delay
    pop  bc
    djnz pj_loop
    ld   a, 8               ; silence channel A
    out  (0xA0), a
    xor  a
    out  (0xA1), a
    ret

; note table: period low, period high, duration (frames).
jingle_notes:
    db   107, 0, 6          ; C6
    db   85,  0, 6          ; E6
    db   107, 0, 6          ; C6
    db   85,  0, 6          ; E6
    db   71,  0, 6          ; G6
    db   53,  0, 24         ; C7 (held)

;------------------------------------------------------------------------------
; 6x8 font: 64 glyphs (ASCII 0x20..0x5F), 8 bytes each = 512 bytes.
; Generated from font6x8.png by packager/font_to_bin.py.
;------------------------------------------------------------------------------
font:
    incbin "font6x8.bin"

;==============================================================================
; STATIC STRINGS
;==============================================================================
; Packager-rewritable title buffer. Fixed 32 bytes: text + NUL + padding.
; The packager finds it by the default string below and overwrites up to 31
; chars (+NUL). blit/str_width measure to the first NUL, so shorter titles work
; and the red box auto-fits. Keep this default in sync with both packagers.
TITLE_MAXLEN equ 32
msg_title:
    db   "YAMANOOTO KONAMI COLLECTION"
    ds   TITLE_MAXLEN - 27, 0
msg_dashes:
    db   "----------------------------------------",0
msg_footer:
    db   " UP/DN  ENTER:launch  RESET:back",0

;------------------------------------------------------------------------------
; Scrolling marquee text. Stored twice so the 40-char display window never
; wraps the buffer; offset cycles 0..SCROLL_LEN-1.
;
; The anti-scam notice already shows on the boot splash, so the marquee is
; fully customizable: 128-byte buffer (×2 for the no-wrap trick). The
; packager locates both copies by searching for the default placeholder
; and overwrites them with the --marquee text.
;------------------------------------------------------------------------------
scroll_text:
    db   "                                        THIS TEXT CAN BE REPLACED, PLEASE READ THE DOCS                                         "
SCROLL_LEN equ $ - scroll_text
    db   "                                        THIS TEXT CAN BE REPLACED, PLEASE READ THE DOCS                                         "
msg_blank_line:
    db   "                                        ",0

;==============================================================================
; SPLASH (shown once at boot, before the menu)
;==============================================================================
draw_splash:
    ld   hl, splash_l1
    ld   a, 77
    ld   b, 8
    call blit_line_at
    ld   hl, splash_l2
    ld   a, 53
    ld   b, 11
    call blit_line_at
    ld   hl, splash_l3
    ld   a, 62
    ld   b, 12
    call blit_line_at
    ld   hl, splash_l4
    ld   a, 56
    ld   b, 14
    call blit_line_at
    ld   hl, splash_l5
    ld   a, 80
    ld   b, 15
    call blit_line_at
    ld   hl, splash_prompt
    ld   a, 56
    ld   b, 18
    call blit_line_at

    call CHGET              ; wait for any key

    ; clear the pattern table so the menu starts from a blank screen
    ld   hl, PATBASE
    ld   bc, 0x1800
    xor  a
    call FILVRM
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
; Packager-rewritable config block.
; Located via the 8-byte magic anchor; the packager flips the bytes that
; follow it to apply runtime tweaks without recompiling.
;==============================================================================
cfg_anchor:
    db 0x59, 0x4D, 0x4E, 0x54, 0x43, 0x46, 0x47, 0x21   ; "YMNTCFG!"
cfg_splash_enable:
    db 1                   ; +8  0 = skip splash, 1 = show (default)
cfg_col_text:
    db 15                  ; +9  text colour nibble (MSX palette 1-15). Default white.
cfg_col_bg:
    db 1                   ; +10 background colour nibble. Default black.
cfg_col_box:
    db 8                   ; +11 title-box colour nibble. Default medium red.
cfg_reserved:
    db 0, 0, 0, 0          ; +12..15 reserved for future toggles

;==============================================================================
; RAM workspace (page 3, MSX system RAM)
;------------------------------------------------------------------------------
; Declared as equ so no ROM bytes are emitted. The launcher writes/reads
; directly at these addresses. Total: 38 bytes at 0xE000+.
; 0xC000-0xC07F is reserved for the trampoline + params.
;==============================================================================
    end

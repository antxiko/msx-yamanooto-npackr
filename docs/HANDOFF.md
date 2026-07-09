# Development handoff — night session results + what's next

> Continuation notes. Snapshot: 2026-07-05, after the Windows night session
> (commits `d53722a`, `c71431b`, `446ca09` on `main`). Previous handoff topic
> (SRAM saves / MG2) is DONE and shipped earlier; this session delivered the
> CFGR SUBOFF packing plus launcher features.

## What shipped this session (all verified, see commit messages for evidence)

1. **SUBOFF packing (d53722a)** — small K4/plain games (≤16KB) now share a 32KB
   OFFR unit at 8KB granularity via CFGR SUBOFF (bits 4-5), in **both builders**
   (`yamanooto_pack.py` AND `gui-rs/src/pack.rs`, algorithm mirrored 1:1, twin
   parity tests). 24 real 16KB Konami carts → 12 units (384KB reclaimed).
   `cmd_test` was broken (tuple unpack TypeError) — fixed and turned into a real
   self-test with hand-computed placement asserts. Rust test no longer writes to
   /tmp (Windows).
2. **⚠ THE OLD HANDOFF WAS WRONG about "launch side already wired, packer-only
   change".** The trampoline wrote the bank registers BEFORE setting SUBOFF in
   CFGR, and openMSX 21.0 (`Yamanooto.cc:242`) — and per its hardware notes most
   likely the real cart too — **latches OFFR*4+SUBOFF at bank-write time**. Every
   sub-placed game booted its unit's slot-0 neighbour (user asked for Athletic
   Land, got Antarctic Adventure; confirmed with signature-marked dummies).
   Fixed in `446ca09`: trampoline STEP 1 now writes CFGR = SUBOFF|ECHO (K4/MDIS
   still 0) before priming banks. **Re-verify on real hardware** — if the real
   cart resolves banks dynamically instead of latching, the fix is still
   harmless.
3. **Boot jingle build-time flag (c71431b)** — `YMNTCFG!` block byte +12
   (`cfg_music_enable`), `[launcher] boot_music` / `--no-boot-music` in the
   Python CLI, checkbox in the GUI. Bytes +13..+20 are reserved for the
   background tile (`cfg_tile`), +21..+23 free.
4. **50/60Hz + R800 session toggles (446ca09)** — machine detected once at boot
   (BIOS 0x002D), status shown on the PAGE_ROW line ('5' toggles 50/60 on MSX2+,
   '8' toggles R800 DRAM on turbo R). Applied in launch_game: R#9 bit1 + RG9SAV
   mirror; CHGCPU 0x82 (before di, double-guarded). 50/60 verified in emulator
   both ways (R9/RG9SAV byte dumps); **R800 verified working in openMSX
   (FS-A1GT) but the user wants a REAL turbo R test before calling it done.**
   Known v1 limitation: games that rewrite R#9 in their init override the
   50/60 preset.
5. **Echo Mode preserved through launch (446ca09)** — the trampoline used to
   wipe CFGR's ECHO bit (PSG mirroring to the cart minijack, HOME at power-on).
   Now read once after REGEN=1 (masking FPGA_WAIT bit 7) and carried through
   both CFGR writes. Only ever preserved, never set (ECHO may not be
   software-settable on real hardware — manual marks it "RC"). Not yet
   verified in emulator.
6. **Forensic gate recreated** — `.forja/gate.json` + `.forja/asm_check.py`
   (gitignored, machine-local). Checks: 6× pasmo with exact-size asserts
   (launcher uses a range — it grows), launcher-bin-sync (filecmp of the two
   copies), py-compile ×8, pack-selftest (`yamanooto_pack.py test`),
   cargo build + cargo test. If lost, recreate from this list; runner is the
   forja plugin's `forensic-gate.py` (config keys: `name`/`command`/`is_test`).

## Build & test recipe (updated sizes)

Same as before (pasmo/python/cargo/openMSX 21). Current reference sizes:
`launcher.bin` **5682**, `mg2_engine.bin` 181, `mg2_driver.bin` 8192,
`gm2_part1.bin` 26, `gm2_part2.bin` 274, `sram_engine_gm2.bin` 530.
ALWAYS size-check after pasmo (negative `ds` → empty bin, exit 0) and resync
`gui-rs/data/launcher.bin` after touching launcher.asm (the gate enforces both).

### openMSX on this Windows box (learned the hard way)
- **The user tests in openMSX; the assistant only launches** (no -script, no
  key injection, no screenshots, never kill instances that may be the user's).
- If openmsx dies instantly with exit 1 and NO output: system audio broke —
  launch with `SDL_AUDIODRIVER=dummy` (no sound, but works).
- `Panasonic_FS-A1ST` does not boot on this install (silent exit 1, testconfig
  OK) — **use `Panasonic_FS-A1GT`** for turbo R testing.
- file-hunter systemroms downloads need a browser User-Agent + referer (405
  otherwise).

## Also shipped later the same night (commits 2cd3eb2, 7c86f23, 976616f)

- **Background tile animation — DONE, user-verified.** 8x8 tile baked at
  build time (YMNTCFG! +13..+20), scroll direction (+21, 8 compass dirs) and
  colour (+22, 0 = box colour). Variable-width list flushes (per-row NT remap
  via mdr_nt) let the tile fill everything right of each title. GUI has a
  grid pixel editor, direction/colour dropdowns and a LIVE animated preview.
  Shared pattern index 31 per third (NEVER 255 — flush_marq rewrites the full
  marquee row every frame).
- **Metal Gear 1 saves to flash — DONE, user-verified** (save at an elevator,
  VERIFY OK, clean quit, reload, load OK). Virtual-tape driver over one 64KB
  sector at relative bank 0x18; carry-based contract; patcher validates every
  original byte before writing. Full design + checkpoint-semantics note in
  `docs/MG1_SAVES.md`. Works on the local fan-translation dump (CRC 5F3BB2F1)
  — its code layout matches the disasm reference.

## What's next (in priority order)

- (obsolete section below kept for reference — T4 shipped, see above)
- **★ T4 — background tile animation** (designed, not started). Full design:
  - The menu uses SCREEN 2 as a bitmap (NT = 0..255×3), so there is no shared
    tile: **remap background NT cells to ONE shared pattern index per third —
    use index 31 in ALL three thirds** (pattern bytes at 0x00F8/0x08F8/0x10F8,
    colour at 0x20F8/0x28F8/0x30F8 ← write `v_col_box` once).
    Index-31-per-third is never flushed IF list-row flushes are restricted
    (below). ⚠ Do NOT use 255 for third 2: `flush_marq` copies the FULL 256
    bytes of row 23 every frame and would clobber pattern 255 (a plan earlier
    tonight got this wrong — re-derive collision analysis if changing indices).
  - Add `flush_row_pat_n`/`set_row_color_n` variants (bc=176 = cells 0..21)
    used ONLY by `menu_draw_row` (titles end < 147px, safe). Title row, status
    row (22) and marquee (23) keep full-row flushes — do NOT remap row 22's
    right strip ("PAG x/y" renders in cells ~25-31).
  - `bg_remap` (call at end of `menu_init`): rows 0/2 outside box_lc..box_rc,
    cols 22..31 of rows 3..21, cols 30..31 of row 23 → all to index 31; then
    the three 8-byte colour fills. One-time cost, NT is never rewritten after.
  - `anim_tick` (call from main_loop after `scroll_tick`): every ANIM_RATE=8
    frames, phase=(phase+1)&7; visible row r = cfg_tile[(r+phase)&7] rotated
    right by phase → 45° diagonal scroll; write the 8 rotated bytes to the 3
    shared pattern addresses (LDIRVM ×3). With cfg_tile all-0 (default) the
    screen is byte-identical to today.
  - GUI: `apply_tile` (anchor +13..+20, clone of apply_music_flag), 8×8 pixel
    editor in egui next to the colour pickers, `tile: [u8;8]` through
    build_image. Python CLI stays neutral (default zeros).
  - Verify: user's eyes (tile scrolling diagonally in margins; menu/hilite/
    marquee/status intact; with no tile configured, identical to today).
- **T5 — MG1 skeletons**: `launcher/mg1_driver.asm` (8192B exact, carry
  contract, stubs scf/ret) + `packager/mg1_to_yamanooto.py` (CRC32 E85C5731,
  PATCHES from the verified table) + `MAPPER_MG1` (footprint_units=8, even
  OFFR). **The complete verified design (20 intercept offsets, RAM map,
  virtual-tape semantics, flash layout, unknowns) is in `docs/MG1_SAVES.md`.**
- R800 on real turbo R hardware (user's call — emulator says OK).
- Echo preserve verification (inject ECHO by debug in openMSX, launch, read
  CFGR — openMSX allows software-set; hardware may not).
- Backlog (from the user, unscheduled): GM2 migration to the per-game RMW
  model, ASCII8-SRAM (Xanadu) / ASCII16-SRAM2 (Hydlide), full MG2 3-slot test.

## Load-bearing gotchas (unchanged + new)

- Two launcher.bin copies must stay in sync (gate check makes it mechanical).
- Per-game save sectors don't need OFFR juggling (relative to the game).
- SUBOFF must be IN CFGR before the bank writes (this session's bug).
- Dummy games in test images DI/HALT by design — a frozen screen after
  launching one is success, not a hang.
- The directory sorts alphabetically; physical placement order is by size
  descending within each pass — don't infer flash position from menu position.

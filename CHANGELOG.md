# Changelog

## v1.7.1 — 2026-07-11

GUI redesign only — no launcher, builder or flash-format changes (v1.7 images
and this build are byte-compatible on the cartridge).

- **Bigger, more readable UI.** Captions that used to render at 9px are now
  12px; body text and buttons are 15px.
- **Cleaner main window.** It now shows only the live menu preview (50% larger,
  centred) and the ROM list. Every setting — marquee, menu title, colours,
  flash size, boot splash, boot jingle and the background-tile editor — moved
  to a **⚙ Settings** window opened from the top bar.
- **Free-space bar moved to the top bar**, to the left of Settings / Build ROM.
- **Reworked drag-to-reorder.** A six-dot grip handle (drawn, so it never shows
  as a missing-glyph box), a robust per-row drop zone, and a floating preview
  of the game title while you drag it.
- **Uniform ROM rows.** Each row has a fixed full-width background and long
  filenames are truncated, so the list no longer looks ragged.
- **Save / Load project stay in the main window** as two buttons; Save is now
  disabled (not hidden) when the list is empty.

## v1.7 — 2026-07-11

- **NEW: free-space indicator in the GUI.** A progress bar shows exactly how
  much flash the current list uses — it runs the REAL allocator as a dry run,
  so MG1/MG2 save-sector footprints, sub-placement of small games and the
  reserved launcher/directory units are all accounted for. It updates live as
  you add/remove/reorder ROMs or change the flash size, turns red when games
  don't fit (listing which ones), and **disables Build** until they do.
- **NEW: game titles up to 39 characters.** The on-flash directory entry grew
  from 32 to 48 bytes (name field 24 → 40 bytes), spanning the whole menu row.
  Titles are edited per row (with a live character counter) and are uppercased/
  ASCII-folded identically by both builders. Directory capacity is now 170
  entries (was 255) — still far above any real collection.
- **NEW: manual menu ordering.** The menu shows games in YOUR order: drag rows
  by the ≡ handle in the GUI (plus a "Sort A-Z" convenience button), or order
  the `[[games]]` entries in the TOML for the CLI. The alphabetical auto-sort
  is gone from both builders.
- **NEW: save/load builder projects.** "Save project…" writes the full GUI
  state (ROM paths, titles, mappers, order, colours, tile, marquee, flash
  size…) as a TOML that "Load project…" restores — and plain/k4/k5/scc entries
  build identically with the Python CLI from the same file. The CLI gained the
  matching `[launcher]` keys: `show_splash`, `tile`, `scroll_dir`,
  `tile_color`, `flash_size`.
- **NEW: live Z80/R800 toggle.** On a turbo R, pressing '8' in the menu now
  switches the CPU immediately (the turbo LED follows), same as the live
  50/60Hz toggle.
- **Format note:** images built with v1.7 use the 48-byte directory format and
  embed the matching launcher — reflash the whole image as usual; old images
  in flash keep working until you do.

## v1.6 — 2026-07-11

- **Fix: Konami-4 games on real hardware.** K4 titles (Metal Gear, Penguin
  Adventure, Gradius/Nemesis, …) black-screened on the physical Yamanooto while
  working in openMSX. Two causes, both addressed:
  - **The cartridge needs the `ziggy1beta7` FPGA core (or later).** Older cores
    ignore the K4 mapper selection entirely (the CFGR K4 bit is not even
    stored) — update with `YAMACORE` and power-cycle. This also un-mutes the
    Konami Synthesizer (DAC support ships with the newer cores).
  - **The launcher now drives K4 launches through the official Ziggy
    master-offset protocol** (offset written to 0x7FFE with `ENAR.MSTEN=1`,
    mapper OFFR kept at 0, banks primed raw — the same sequence as the official
    YAMABOOT). The single offset write is also read correctly by openMSX's
    old-firmware model, so images keep working in the emulator. The launcher
    init additionally clears both offsets on boot (stale values survive a soft
    reset on real hardware).
- **NEW: `probe/` K4-PROBE diagnostic ROM.** A self-contained 128KB probe pair
  with positional bank signatures and a RAM experiment engine that prints how
  the cartridge's mapper actually behaves (register readbacks, canonical vs
  K5 decode, master-offset test, step-by-step trampoline replay). One flash
  tells an old core from a new one — see `probe/EXPECTED.md`.

## v1.00 — 2026-07-02

- **NEW: configurable menu colours.** Text, background and title-box colours are
  now selectable from the packager. New bytes in the `YMNTCFG!` config block
  (`cfg_col_text` / `cfg_col_bg` / `cfg_col_box`, MSX palette 1–15); the launcher
  derives the SCREEN 2 colour-table bytes at boot (`init_colors`): text rows =
  `text<<4|bg`, selection bar = `bg<<4|text` (inverse, automatic), title box =
  `box<<4|bg`. Set via CLI `--color-text` / `--color-bg` / `--color-box`
  (palette index or name, e.g. `cyan`), `[launcher].color_*` in the TOML, or the
  three MSX-palette dropdowns in the GUI. The launch protocol is untouched.
- **NEW: live menu preview in the GUI.** A small simulation drawn with the real
  `font6x8` shows the title box, list, inverse selection bar and marquee, and
  recolours as you pick colours.
- **Fix: softdb titles now decode XML entities.** Names like
  `Konami&apos;s Boxing` now read `Konami's Boxing` in the list/title.
- **GUI mapper dropdown offers ASCII8 / ASCII16.** For ROMs whose SHA1 is not in
  the softdb, choosing ASCII8/ASCII16 runs the K5 converter on the pristine ROM.

## v0.99 — 2026-07-01

- **NEW: graphical SCREEN 2 in-cart menu.** The launcher (`launcher/launcher.asm`)
  was rewritten from monochrome SCREEN 0 text to a SCREEN 2 GUI, still
  MSX1-compatible (runs on every Yamanooto host):
  - Proportional pixel font from a custom `font6x8.png` — converter
    `packager/font_to_bin.py` → `launcher/font6x8.bin` (incbin-ed into the ROM).
  - Centred title inside a **rounded red box** that auto-fits the title width.
  - Inverse selection bar hugging just the game title.
  - **Pixel-smooth scrolling marquee** that keeps moving while you navigate.
  - **Jump-to-letter (A–Z)** navigation plus cursor/paging and a **"PAG x/y"**
    page counter in the bottom-right corner.
  - **Konami-style boot jingle** on the internal PSG.
  The game-launch protocol (trampoline, ASCII16/SCC helpers, on-flash directory
  format) is unchanged — existing images still pack and games still boot.
- **NEW: configurable menu title** — `--title` / `[launcher].title` on the CLI
  and a "Menu title" field in the GUI. The red box auto-fits the text.
- **Marquee: empty means empty.** With no marquee set (empty GUI field, or no
  `--marquee`/`[launcher].marquee`) the marquee is now BLANK instead of showing
  the default placeholder. The Python CLI and the Rust GUI behave identically.
- The GUI now embeds the new SCREEN 2 launcher (`gui-rs/data/launcher.bin`).

## v0.95 — 2026-05-22

- **NEW: native cross-platform GUI builder** (`gui-rs/`, Rust + egui).
  Single static binary; drag-and-drop ROMs, mapper auto-detect against an
  embedded `softwaredb.xml`, ASCII8/ASCII16 conversion on the fly, marquee
  customization, splash toggle, build and save. No Python needed.
- Pre-built binaries for **macOS** (arm64 + x64), **Linux** (x64), and
  **Windows** (x64) attached to this release.
- **Marquee redesign**: the anti-scam notice no longer prefixes the
  marquee — it's already on the boot splash. The marquee is now a single
  128-char buffer (×2 for the no-wrap display trick), fully customizable.
- **Boot splash toggle**: new packager-rewritable config block
  (`YMNTCFG!` magic + flag bytes) in `launcher.bin` lets the GUI checkbox
  "Show boot splash" enable or disable the splash without recompiling.
- The Python packager (`packager/yamanooto_pack.py`) stays as historical
  reference / CLI alternative. Both share `launcher.asm` + `launcher.bin`
  and use the same on-flash directory format.

## v0.94 — 2026-05-22

- **`--marquee "your text"`** flag on `build` and `pack-folder` lets you
  customize the scrolling marquee text at the bottom of the in-cart menu
  *without recompiling the launcher*. The hardcoded anti-scam notice
  (`ESTA HERRAMIENTA ES GRATUITA · SI HAS PAGADO POR ESTA ROM, TE HAN
  ESTAFADO`) is always shown; only the trailing 64-char buffer is
  replaced. TOML config can set `[launcher].marquee = "..."` instead.
- `launcher.bin` now reserves a 64-byte custom buffer (×2 for the no-wrap
  trick) immediately after the anti-scam prefix. Default value points
  users to the toolkit's GitHub repo.

## v0.93 — 2026-05-22

- **ASCII8 and ASCII16 conversion validated end-to-end** in openMSX 21 with
  real GoodMSX dumps:
  - ASCII8: **1942** (Capcom, 1987) — 23 patches applied, boots and plays.
  - ASCII16: **Golvellius** (Compile, 1987) — 2 helper installs + 11 bank
    switches patched, boots and plays.
  - Both packed together into a single 2MB image via `pack-folder
    --auto-convert --flash-size 2MB` in one command.
- ASCII16 → K5 path no longer marked "experimental" in the docs.
- Catalog of known clean GoodMSX SHA1s for ASCII8/ASCII16 dumps now
  acknowledged in the README's "Validated games" section.

## v0.92 — 2026-05-22

- **`pack-folder --auto-convert`**: detects ASCII8/ASCII16 ROMs and runs the
  K5 conversion in memory automatically, so a folder full of mixed mappers
  packs in a single command.
- More flat mapper aliases recognized as `plain` (Normal, 0x0000, 0x4000,
  0x8000, 8kB, 16kb, Page2, Page12, Mirrored4000).
- Explicit "not yet supported" tagging for ASCII8 SRAM / ASCII16 SRAM /
  KoeiSRAM / GameMaster2 / Page23 / R-Type / Cross Blaim — the packer now
  prints a useful message instead of silently dropping.
- New explainer doc: [`docs/SCC_ALIGNMENT.md`](docs/SCC_ALIGNMENT.md) walks
  through the openMSX 21.0 bug and the 16-OFFR alignment math.

## v0.91 — 2026-05-22

- **New: `--flash-size` option** (`2MB` or `8MB`) on `build` and `pack-folder`.
  Some early Yamanooto units shipped with 2MB flash; this lets the toolkit
  produce images sized for either model.
- Docs cleanup: removed references to a specific ASCII8 ROM dump that was an
  outlier (canonical Konami dumps are K4, not ASCII8). The conversion path is
  still documented and supported.

## v0.9 — 2026-05-22

First public release.

### Working
- Z80 launcher with menu, splash, and scrolling anti-scam marquee
- `pack-folder` builds an 8MB image from any folder of ROMs, auto-detecting
  the mapper via SHA1 lookup against openMSX's `softwaredb.xml`
- `build` reads a TOML config for explicit selection / per-game overrides
- `detect` identifies one or more ROMs (mapper, size, canonical title)
- ASCII8 → K5 converter (`ascii8_to_k5.py`)
- ASCII16 → K5 converter (`ascii16_to_k5.py`, experimental)
- SCC enable patcher (`scc_patch.py`)
- 16-OFFR alignment for SCC games (workaround for openMSX 21.0
  `Yamanooto::isSCCAccess()` bug — uses `bankRegs[]` instead of `rawBanks[]`)
- 8KB wrap-mirror for SCC games < 512K (saves 376K vs full 4× mirror)
- BIOS warm-boot fallback path for hook-based games (Metal Gear 2's H.CHGE)
- Short canonical titles for the in-cart menu (e.g. "Solid Snake" instead of
  "Metal Gear 2 - Solid Snake")
- Alphabetical sort in the menu
- MSX1/MSX2 disambiguation suffix (e.g. "King's Valley 2 MSX2")
- Page-2 slot setup at launcher INIT (BIOS leaves it as RAM)
- Trampoline lock of `ENAR.REGEN=0` so games can't accidentally clobber
  Yamanooto config

### Validated games
End-to-end tested in openMSX 21 with the `Yamanooto` mapper:
- 35+ Konami Mirrored 16/32K (Ping-Pong, Road Fighter, Antarctic Adventure,
  King's Valley, Knightmare 1, etc.)
- 7 Konami K4 (Vampire Killer, Penguin Adventure, Maze of Galious, Metal Gear,
  Usas, Firebird, Ganbare Goemon, Shalom)
- 14 Konami SCC including Salamander, Nemesis 1/2/3, F1 Spirit, Parodius,
  Space Manbow, Quarth, Gryzor (Contra), Gekitotsu Pennant Race 1/2,
  King's Valley 2 (MSX1 + MSX2), Hai no Majutsushi (Mahjong 2)
- 1 Konami SCC 512K with H.CHGE hook (Metal Gear 2: Solid Snake)
- ASCII8 → K5 conversion path (`ascii8_to_k5.py` + `mapper = "k5"`)

A typical mega-image with 59 Konami MSX cartridge titles fits in 5.3MB of the
8MB flash, leaving ~2.25MB spare for additional games.

### Known limitations / future work
- ASCII16 conversion is experimental (works in theory but unproven with a
  real ASCII16 SCC game)
- Some non-Konami publishers (Compile, Hudson) not in the catalog yet
- No tests / CI

### Credits
- **MFides** + **The SCC Alliance**: Yamanooto cartridge hardware + FPGA
- **Genami Retro Prototypes** (genami.shop): distribution
- **openMSX project**: emulator, Yamanooto extension, `softwaredb.xml`
- **Konami**: the games themselves (not redistributed here — bring your own)

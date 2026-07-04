# Development handoff — SRAM saves (per-game 64KB, read-modify-write)

> Continuation notes for picking the work up on another machine (incl. Windows 11).
> Snapshot: 2026-07-04, at commit `9e04a80` on `main`.

## Where we are

Goal of this line of work: **emulate cartridge SRAM saves on the Yamanooto flash**
(it has no battery SRAM; its AMD flash is writable at runtime via the ENAR `WREN` bit).

Verified & pushed:
- **Metal Gear 2 (MG2)** saves to flash — DONE, verified in openMSX (save + clean-quit
  persistence + reload load; flash byte-checked).
- Game Master 2 (GM2) saves — DONE earlier (bespoke driver, its own scheme). Not yet on
  the new per-game model below.

### The save architecture (decided 2026-07-03)

**One 64KB flash sector per SRAM game, updated read-modify-write. No accumulation.**
- Flash can only flip 1→0; to change a byte you must erase, and erase clears a whole 64KB
  sector. So you **cannot overwrite in place**. The model is: read the game's few save
  bytes into RAM, **erase the 64KB sector, rewrite** them. Always the current save set,
  never a growing log — the sector never "fills", so there is no compaction/GC.
- Per-game (not a shared pool) because MSX RAM is tiny (the launcher has ~8KB free): a
  game only ever handles **its own** small save set, which always fits in RAM. Each game's
  sector is **relative to its own ROM** (reached with the game's own OFFR — no OFFR change,
  no cross-game index, no `game_id`).

### MG2 specifics (the reference implementation)
- MG2 has exactly 3 save files: SNAK1/2/3. They live in ONE 64KB sector at relative bank
  `0x48`, at fixed window offsets: slot `i` at `0xA000 + i*0x100`.
  Record = `[marker 0xA5 | len(2, LE) | data(len)]`; `marker != 0xA5` = empty slot.
- `packager/yamanooto_pack.py`: MG2 `footprint_units = 20` (640KB = 512KB ROM + 8KB driver
  at rel bank 0x40 + one 64KB save sector at 0x48). Was 24 (3×64KB). Placed 16-OFFR-aligned
  (keeps the sector 64KB-aligned in absolute flash).
- `launcher/mg2_driver.asm` (org 0x8000, one 8KB bank, appended to the MG2 ROM as rel bank
  0x40): `fn_read` reads slot by offset; `fn_write` does RMW — stages the 3 records in RAM
  (STAGE=0xE5D0), the changed one from MG2's buffer (0xC700), the other two read back from
  flash, then calls the engine. Every function returns **A=0** (MG2 judges success only by A).
- `launcher/mg2_engine.asm` (org 0xE500, runs from RAM because flash is unreadable during
  erase/program): map bank 0x48 → WREN on → erase sector → reprogram the 3 staged records
  → WREN off. 181 bytes.
- RAM map (all inside MG2-free RAM 0xE500–0xE749, found by a RAM dump): engine 0xE500 (181B),
  driver scratch 0xE5C0, STAGE 0xE5D0 (3×118B).
- MG2 ROM patch: `packager/mg2_to_yamanooto.py` (validates the GoodMSX RC-767 512KB dump,
  patches GM2-detection + the inter-slot call helper, appends `launcher/mg2_driver.bin`).

## Build & test recipe (cross-platform)

Tools: `pasmo` (Z80 asm), `python3`, `rust`/`cargo` (only for the GUI), `openMSX`.

1. **Assemble the MG2 save code** (order matters — the driver `incbin`s the engine):
   ```
   cd launcher
   pasmo --bin mg2_engine.asm mg2_engine.bin
   pasmo --bin mg2_driver.asm mg2_driver.bin
   ```
   ⚠️ **pasmo gotcha**: a negative `ds` (buffer overrun) makes pasmo emit an EMPTY .bin
   with exit 0. ALWAYS check the size: `mg2_engine.bin` must be ~181 B, `mg2_driver.bin`
   must be exactly 8192 B. (Windows: `for %I in (mg2_driver.bin) do @echo %~zI`.)
2. **Patch your MG2 ROM** (your own legally-dumped GoodMSX RC-767 512KB dump — ROMs are
   NOT in the repo; `.gitignore` blocks `*.rom`):
   ```
   python packager/mg2_to_yamanooto.py "<your MG2>.rom" mg2_patched.rom
   ```
3. **Pack** `mg2_patched.rom` with `mapper = "mg2"` into a Yamanooto image (via a TOML
   config + `python packager/yamanooto_pack.py build config.toml -o image.rom`, or a small
   inline script that calls `build_image`).
4. **Run** (ALWAYS `-romtype Yamanooto`):
   ```
   openmsx -cart image.rom -romtype Yamanooto
   ```
   Save in-game (SNAK1/2/3), then to test persistence **quit openMSX cleanly** (it flushes
   the 8MB flash on clean quit), reopen, and load.

### openMSX flash persistence (path differs per OS)
The whole 8MB flash is persisted to `<openMSX>/persistent/roms/<rom-name>/<rom-name>.SRAM`.
- macOS: `~/.openMSX/persistent/roms/...`
- Windows: `%APPDATA%\openMSX\persistent\roms\...` (or the openMSX "user directory").
You can byte-check a save without looking at the screen: the save sector is at
`game.flash_offset + 0x48*0x2000` in that `.SRAM`; slot `i` record at `+i*0x100`.

### Gate + commit (forja)
`.forja/gate.json` defines the gate (pasmo launcher, py-compile, cargo build/test). A
commit-guard blocks `git commit` until the gate is GREEN and FRESH; run it first:
`python3 <forja>/scripts/forensic-gate.py run` (the forja plugin may not be installed on
the Windows box — if the guard isn't there, just make sure those 4 commands pass).
Push target: `origin` = `github.com/antxiko/msx-yamanooto-npackr` (use the `antxiko` gh
account). **Releases fire ONLY on pushing a `v*` tag** — pushing commits to `main` never
makes a release.

## What's next (pending)

- **Optional**: full MG2 test — save 3 distinct states to SNAK1/2/3 and confirm each loads
  its own (no cross-contamination). SNAK1 round-trip is already verified.
- **Fase C — generalize the per-game 64KB RMW model to the other SRAM games**: migrate GM2
  (currently on its own bespoke scheme) and add ASCII8-SRAM (Xanadu) / ASCII16-SRAM2
  (Hydlide) — each gets its own 64KB sector, same RMW technique. You'll need those dumps.
- The GUI (`gui-rs/`) has **no** save-system code yet; the save system is Python-only. If
  the save flow must work from the GUI, it needs porting.

## Load-bearing gotchas
- Two copies of `launcher.bin` normally need syncing, but the MG2 save bins
  (`mg2_driver.bin`/`mg2_engine.bin`) are single files embedded into the MG2 ROM — not part
  of `launcher.bin`.
- Absolute-bank access needs OFFR juggling, but the **per-game save sectors do NOT** (they
  are relative to the game) — this is the big simplification over the earlier shared-pool idea.
- openMSX workflow: launching is fine; **only a human should look at the screen** (don't
  screenshot/analyze it). Debugger console dumps (PC/regs/RAM to a file) are OK when asked.

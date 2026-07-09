# Metal Gear 1 (RC750) — cassette saves → Yamanooto flash: design study

> **STATUS: IMPLEMENTED AND USER-VERIFIED (2026-07-05).** Save at an elevator
> with items in hand → VERIFY OK → clean quit → relaunch → load → all back.
> Implementation: `launcher/mg1_engine.asm` + `launcher/mg1_driver.asm` +
> `launcher/mg1_shim.asm` + `packager/mg1_to_yamanooto.py` + `MAPPER_MG1`.
>
> **Checkpoint semantics (original game behaviour, NOT a driver bug):** the
> tape save writes `GameProgressBuffer`, which is a CHECKPOINT SNAPSHOT that
> `StoreGameStat` (logic/checkpoints.asm, driven by `ChkSaveGameStatus` at
> Banks0123.asm:8661/:11867 against a room list) refreshes only in checkpoint
> rooms — the elevators. Saving right after picking items WITHOUT passing a
> checkpoint loses them on load, exactly like a real cassette. `RestoreGameStat`
> (Banks0123.asm:11820) applies the snapshot after load.

> Study produced 2026-07-05 from the annotated disassembly
> [GuillianSeed/MetalGear](https://github.com/GuillianSeed/MetalGear) (Manuel Pazos, 2017).
> **Every ROM offset below was verified by assembling the disasm with Sjasm 0.39j and
> byte-checking the output** (CRC32 `E85C5731` = English ROM, `JAPANESE equ 0`).
> Target model: same per-game 64KB read-modify-write sector as MG2 (see HANDOFF).
> Nothing here is implemented yet — this is the map for `mg1_driver.asm` +
> `mg1_to_yamanooto.py`.

## Game facts (verified)

- Mapper: **Konami-4** (bank regs 0x6000/0x8000/0xA000, 0x4000-0x5FFF fixed), 16×8KB = 128KB.
- Save/load lives in `logic/saveload.asm`, assembled into **bank 0x0F** (mapped at 0xA000
  by `GS_Pause` via `SetBankInA0_F` before calling `LoadSaveLogic`).
- In-game UI: pause (F1) → **F4 = LOAD, F5 = SAVE**; load also possible from Game Over.
  Player types a **free filename of up to 6 chars** (0-9/A-Z); `SearchFile` compares all
  6 bytes and shows SKIP/FOUND per tape block. No slot menu — names ARE the slots.
- Save payload: **0x300 bytes from `GameProgressBuffer` = 0xCA00** (the buffer is declared
  0x220 — the extra 0xE0 bytes overspill into `GfxPitfallBuffer`; harmless, must be
  preserved as-is) **+ `TailDataByte` (0xC166) checksum = 769 bytes total**.
  (Note: an earlier pass said 0xC9FF/0xC6A7 — off by one; assembly-verified values are
  `GameProgressBuffer=0xCA00`, `Filename=0xC6A8`.)
- Result contract: the game checks **CARRY after each BIOS tape call (NC = success)** —
  NOT A=0 like MG2's GM2 protocol. `TAPIN` must return the byte in A.

## Intercept points — 20 `call TAP*` sites in bank 0x0F (all verified)

ROM offset = 0x1E000 + (CPU addr − 0xA000). Patch = rewrite the 2 operand bytes of each
`CD xx xx` after validating the original 3 bytes (`CD E1 00` TAPION / `CD E4 00` TAPIN /
`CD E7 00` TAPIOF / `CD EA 00` TAPOON / `CD ED 00` TAPOUT / `CD F0 00` TAPOOF).

| # | Routine | BIOS | CPU | ROM offset |
|---|---------|------|-----|------------|
| 1 | SaveFilename | TAPOON | 0xB985 | 0x1F985 |
| 2 | SaveFilename2 | TAPOUT | 0xB98D | 0x1F98D |
| 3 | SaveFilename3 | TAPOUT | 0xB99D | 0x1F99D |
| 4 | SaveError | TAPOOF | 0xB9A9 | 0x1F9A9 |
| 5 | SaveGameData | TAPOON | 0xB9C0 | 0x1F9C0 |
| 6 | SaveGameData2 | TAPOUT | 0xB9CE | 0x1F9CE |
| 7 | SaveGameData tail | TAPOUT | 0xB9DE | 0x1F9DE |
| 8 | SaveGameData | TAPOOF | 0xB9E3 | 0x1F9E3 |
| 9 | SaveVerify2 | TAPIN | 0xBA39 | 0x1FA39 |
| 10 | SaveVerify tail | TAPIN | 0xBA49 | 0x1FA49 |
| 11 | SaveVerify | TAPIOF | 0xBA55 | 0x1FA55 |
| 12 | LoadData2 | TAPIN | 0xBB16 | 0x1FB16 |
| 13 | LoadData tail | TAPIN | 0xBB24 | 0x1FB24 |
| 14 | LoadData | TAPIOF | 0xBB2C | 0x1FB2C |
| 15 | TapeError | TAPIOF | 0xBB47 | 0x1FB47 |
| 16 | SearchFile | TAPION | 0xBB9A | 0x1FB9A |
| 17 | SearchFile2 | TAPIN | 0xBBA2 | 0x1FBA2 |
| 18 | SearchFile3 | TAPIN | 0xBBB5 | 0x1FBB5 |
| 19 | SearchFile4 | TAPION | 0xBBD7 | 0x1FBD7 |
| 20 | PrintSkipName | TAPION | 0x1FBDE (CPU 0xBBDE) | 0x1FBDE |

`STMOTR` is defined but never called. Anchors: `LoadSaveLogic`=0xB948 (ROM 0x1F948);
`GS_Pause` caller at 0x6819 with `call SetBankInA0_F` @ ROM 0x2828 and
`call LoadSaveLogic` @ ROM 0x282B.

## RAM map (verified)

- Bank-register shadows: `BankIn60`=0xF0F1, `BankIn80`=0xF0F2, `BankInA0`=0xF0F3,
  `*Fixed`=0xF0F4-0xF0F6. During saveload: 0x6000=bank1, 0x8000=bank2, 0xA000=bank0x0F.
- **DANGER**: `InterruptTick` (0x41AC) remaps banks 4/5 into 0x6000/0x8000 for sound and
  restores from the shadows → the driver must run under **DI the whole time** (same need
  as the flash engine anyway).
- Truly free RAM: **0xF0FA-0xF37F (646 bytes)** → engine at **0xF100** (≤0x200B) + driver
  state at 0xF300.
- Staging for the 64KB RMW: **0xD800 (`EnemyListCopy`, 0x800)** — only used by binoculars
  backup and by LOAD itself as scratch; dead during the save commit. If more is needed,
  continue into **0xE000 (`RoomTileBuffer`, 0x500)** — rebuilt by `RenderRoom` on every
  exit from save/load. Contiguous D800-E4FF = 3328 bytes. Do NOT touch 0xE500+
  (`PasswordBuffer`/`KeyboardRow*` — saveload reads them for Y/N prompts).

## Design: "virtual tape" via per-CALL patch (chosen over full-routine shims)

Bank 0x0F has only **89 free bytes** (0xFF fill at ROM 0x1FFA7-0x1FFFF) — enough for
6 stubs + a common shim (~67B), not for reimplementing the tape state machine. Keeping
the original logic means filename entry, SKIP/FOUND, VERIFY and RETRY all keep working.

Shim flow (contract: A=data in/out, carry=error, preserves BC/DE/HL):
1. `di` (InterruptTick, see above), push regs, C = function id (0..5).
2. Map driver: `ld a,0x10 / ld (0x8000),a` (Konami-4 reg, same one the game uses).
3. `call 0x8000` → driver entry; returns A + carry.
4. Restore: `ld a,(BankIn80) / ld (0x8000),a` (=2 during saveload).
5. pop regs, `ei`, `ret`.

Driver (bank 0x10 in window 0x8000): maps the save sector's bank into **0xA000**
(displacing bank 0x0F while the driver — not the game — executes; restore `(BankInA0)`
before returning). Erase/program run from the engine copied to **0xF100** (with WREN on,
banking freezes — pattern validated in mg2_engine.asm:31-34).

Virtual tape semantics: tape = concatenation of non-empty slots, each as two blocks
(header = 10×0xEA sync + 6-char name; data = 0x301 bytes). `TAPION` advances the block
cursor (carry when exhausted → game shows LOAD ERROR); `TAPIN` serves bytes; `TAPOON`
A=1 starts header capture, A=0 assigns the slot (matching name → overwrite; else first
empty; none → carry → game shows SAVE ERROR via SaveGameData:117); `TAPOUT` accumulates
into staging; the data-block `TAPOOF` triggers the RMW commit; `TAPIOF`/`TAPOOF` reset
the cursor so the game's VERIFY re-reads real flash.

## Flash layout (proposal)

Packed footprint 256KB (`footprint_units = 8`, even OFFR like the SRAM pass):
banks 0x00-0x0F game | **0x10 driver** (ROM offset 0x20000) | 0x11-0x17 pad 0xFF |
**0x18-0x1F save sector 64KB** (ROM offset 0x30000, 64KB-aligned).

Slot record in the sector's first bank, stride 0x400:
`[marker 0xA5 | name 6 | len 2 LE (=0x0301) | data 0x301]` = 778 bytes; 0xFF marker =
empty. **3 slots** (staging 2334B fits D800 comfortably; symmetric with MG2's model).

## UNKNOWNS — verify before implementing

1. Yamanooto in K4 mode: (a) does writing ENAR (0x7FFF) side-affect the 0x6000 bank reg?
   Mitigation: engine rewrites reg 0x6000 from `(BankIn60)` after clearing ENAR. (b) Does
   the WREN banking freeze behave the same as in SCC mode? (AMD unlock addresses
   0xAAAA/0xA555 fall in K4 register zone.)
2. Effective width of the K4 bank register on Yamanooto (driver needs value 0x10, save
   0x18+ → ≥5 bits). Works in openMSX; confirm on hardware.
3. Can the player pause+save during binoculars mode (GameMode 8)? If yes the D800 staging
   clashes with the binoculars backup — verify, or cap staging/move a slot to F0FA zone.
4. Exact stub addresses inside 0x1FFA7-0x1FFFF (fix when writing mg1_driver.asm).
5. The game ignores carry from TAPOOF (saveload.asm:141) — commit failures must be
   signalled via TAPOON/TAPOUT or swallowed (VERIFY catches them from real flash).
6. **The dump currently in the user's KONAMIS/ folder does NOT match the disasm
   target**: `Metal Gear - Konami (1987) [English] [RC-750] [6873].rom` has CRC32
   `5F3BB2F1`, not `E85C5731` (likely a fan-translation of the JP ROM rather than
   the European English release). Before implementing: either source the exact
   `E85C5731` dump or verify all 20 intercept offsets against this one (the
   patcher must validate the original `CD xx 00` bytes at each offset regardless
   — refuse loudly on mismatch, never patch blind).

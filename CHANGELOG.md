# Changelog

## v0.9 — 2026-05-22

First public release.

### Working
- Z80 launcher with menu, splash, and scrolling anti-scam marquee
- `pack-folder` builds an 8MB image from any folder of ROMs, auto-detecting
  the mapper via SHA1 lookup against openMSX's `softwaredb.xml`
- `build` reads a TOML config for explicit selection / per-game overrides
- `detect` identifies one or more ROMs (mapper, size, canonical title)
- ASCII8 → K5 converter (`ascii8_to_k5.py`) — validated with Penguin Adventure
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
- 1 ASCII8 conversion via patcher (Penguin Adventure ASCII8 variant)

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

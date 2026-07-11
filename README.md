# Yamanooto nPackR

Build multi-game ROM images for the [Yamanooto](https://genami.shop) MSX flash
cartridge from your own legally-obtained Konami ROMs.

> **This is a toolkit, not a ROM compilation.** No game data ships with this
> repository. You supply your own ROMs; the scripts pack them into a single
> 8MB image that the Yamanooto's `YAMAFX.com` utility can flash.
>
> If anyone is selling you a pre-built ROM made with this tool — **you have
> been scammed**. The whole point of the toolkit is that the work to build
> it is free.

## Two ways to use it

**Native GUI (recommended)** — single binary for macOS / Linux / Windows.
Download the latest [release](https://github.com/antxiko/msx-yamanooto-npackr/releases),
launch the binary, drag-and-drop your ROMs, set a marquee + flash size, click
**Build ROM**. No Python or other deps required. Raw Metal Gear 1 / Metal Gear 2
dumps are auto-patched on the fly so they **save to the cartridge flash** (no
cassette, no Game Master 2 needed).

> **⚠ Cartridge core requirement.** Konami-4 games (Metal Gear, Penguin
> Adventure, Gradius/Nemesis, …), native ASCII8/16 and the PCM DAC
> (Synthesizer, Majutsushi) need the **`ziggy1beta7` FPGA core or later** on
> your Yamanooto (this toolkit is validated on real hardware with
> `yimmi8beta2`). On older cores the K4 mapper selection is silently ignored
> and those games boot to a black screen. Update with `YAMACORE <CORE>.BIN
> /Sx` from MSX-DOS/Nextor and **power-cycle** (a warm reset does not load the
> new core). Cores live in the official
> [GitLab](https://gitlab.com/mfides/msx_dma_sw/-/tree/main/modules/yamanooto/release/core).
> The `probe/` diagnostic ROM in this repo tells an old core from a new one in
> one flash if you are unsure.

**Python CLI (historical)** — the original `packager/yamanooto_pack.py`
still works for users who prefer scripting. It does the same job as the
GUI, sharing the same `launcher.asm` and on-flash directory format.

## What's in here

| Path | Purpose |
| --- | --- |
| `gui-rs/` | **Rust GUI builder** (Rust + egui). Cross-platform single binary. Embeds `launcher.bin` and `softwaredb.xml`. |
| `launcher/launcher.asm` | Z80 launcher that draws the in-cart menu and dispatches games. Assembled with [Pasmo](http://pasmo.speccy.org/). Used by both builders. |
| `packager/yamanooto_pack.py` | Python CLI builder (alternative). Auto-detects mapper by SHA1 against openMSX's `softwaredb.xml`. |
| `packager/ascii8_to_k5.py` | Stand-alone ASCII8 → K5 converter (the GUI does this in memory). |
| `packager/ascii16_to_k5.py` | Stand-alone ASCII16 → K5 converter (the GUI does this in memory). |
| `packager/mg1_to_yamanooto.py` / `mg2_to_yamanooto.py` | Metal Gear 1 / 2 patchers: redirect cassette / Game Master 2 saves to a 64KB flash sector on the cartridge (the GUI applies them automatically to raw dumps). |
| `probe/` | **K4-PROBE diagnostic ROM**: prints how the cartridge's mapper really behaves (register readbacks, K4 vs K5 decode, master offset). One flash distinguishes an old FPGA core from a current one. See `probe/EXPECTED.md`. |
| `catalog/konami_catalog.toml` | Reference list of Konami MSX cartridge dumps with their mappers (informational). |

## Requirements

- **GUI**: nothing — single binary in the [Releases page](https://github.com/antxiko/msx-yamanooto-npackr/releases).
- **Yamanooto core `ziggy1beta7` or later** (validated with `yimmi8beta2`) on the cartridge (see the warning
  above — older cores have no working Konami-4 mapper selection).
- **Python CLI** (optional): Python 3.11+ (or 3.10 with `tomli`).
- **Pasmo** (only if you want to rebuild the launcher from source): `brew install pasmo` on macOS.
- **openMSX 21+** (optional, for testing — the Yamanooto extension is built in.
  Note: openMSX emulates the OLD cartridge firmware; see the SCC alignment and
  DAC notes below).

## Quick start

### 1. Assemble the launcher

```sh
cd launcher && pasmo --bin launcher.asm launcher.bin
```

Produces `launcher/launcher.bin` (~6.2 KB). **Always size-check the output**:
pasmo emits an empty binary with exit code 0 if an internal `ds` guard goes
negative.

### 2. List your games in TOML

Create `games.toml`:

```toml
[launcher]
file = "launcher/launcher.bin"

# Mapper is auto-detected from openMSX softwaredb on first run.
# Add `mapper = "scc"|"k4"|"plain"|"ascii16_k5"` to override.

[[games]]
title = "Konami's Ping-Pong"
file  = "Konami's Ping-Pong.rom"

[[games]]
title = "Salamander"
file  = "Salamander.rom"

# ASCII8 ROMs (e.g. some MSX games dumped from ROM cards with the wrong
# header) must be converted first:
#   python3 packager/ascii8_to_k5.py game.rom game_k5.rom
[[games]]
title = "Some ASCII8 Game"
file  = "game_k5.rom"
mapper = "k5"           # converter output: K5 mapper, no SCC sound
```

### 3. Build the image

```sh
python3 packager/yamanooto_pack.py build games.toml -o yamanooto.rom
```

You get `yamanooto.rom` (exactly 8 MB).

#### Customize the scrolling marquee

The bottom row of the in-cart menu scrolls a marquee. The first half is a
hardcoded anti-scam notice (always shown). The second half is a 64-char
buffer you can rewrite without recompiling the launcher:

```sh
python3 packager/yamanooto_pack.py pack-folder ROMs/ \
    --marquee "Mi coleccion Konami — Yamanooto rules" \
    -o yamanooto.rom
```

Or in the TOML:

```toml
[launcher]
file = "launcher/launcher.bin"
marquee = "Mi coleccion Konami — Yamanooto rules"
```

The MSX font is uppercase-only; text is uppercased automatically. Centered
if shorter than 64 chars, truncated if longer.

### 4. Flash to the Yamanooto

Per the cartridge's user manual:

0. **First time / K4 games black-screen**: update the FPGA core to
   `ziggy1beta7` or later (`YAMACORE <CORE>.BIN /Sx`; validated with
   `yimmi8beta2`) and **power-cycle** — the new core only loads on a cold boot.
1. Hold **DEL** during MSX boot to bypass any current ROM on the cart.
2. Boot MSX-DOS from your MegaFlashROM SCC+ SD / Carnivore / SD Mapper / floppy.
3. Put `yamanooto.rom` and `YAMAFX.com` in the **root** (subdirectories don't work).
4. Run `YAMAFX.com yamanooto.rom /S1` (or `/S2` if the Yamanooto is in slot 2).
5. Choose **option 1** in the YAMAFX menu (delete + save + verify).
6. Power-cycle the MSX. Your menu appears, then any selected game runs.

## Detecting the mapper of a ROM

```sh
python3 packager/yamanooto_pack.py detect path/to/rom.rom
```

Looks up the SHA1 against openMSX's `softwaredb.xml` (downloaded on first
use and cached at `~/.cache/yamanooto_pack/softwaredb.xml`). Tells you whether
the mapper is supported natively or whether you need a converter.

## Supported mappers

| ROM mapper (softwaredb name) | Yamanooto handling | Notes |
| --- | --- | --- |
| `KonamiSCC`                 | Native K5/SCC, packed **sequentially** (since v1.7) | Games < 512K get an 8KB wrap-mirror placed at flash bank `OFFR*4 + 63` so the `0x3F` SCC-enable trick lands on the game's music driver. The old 512KB alignment was only ever an openMSX 21.0 workaround — re-enable it with `--scc-align` / `[launcher].scc_align = true` (Python builder) if you still test there. |
| `Konami` (Konami-4)         | Native K4 — **requires the `ziggy1beta7`+ core** | Any OFFR. No mirror needed. The launcher feeds the offset through the core's master-offset register (official YAMABOOT protocol), which openMSX's old-firmware model also accepts. |
| `Mirrored` (8KB/16KB carts) | Native via K4+MDIS, bank pattern `0,0,0,0` / `0,1,0,1` | Stays its original size in flash; mirror happens in the mapper. |
| `0x4000` (16KB at page 1)   | Same as Mirrored  | |
| `ASCII8`                    | Convert via `ascii8_to_k5.py` (use `mapper = "k5"` in TOML after conversion) | Rewrites `LD (nn),A` opcodes that hit the ASCII8 switch zone. Note: if a "GoodMSX" K4 dump of the same game exists, prefer that — most Konami carts dumped as ASCII8 are re-packs of an originally K4 cart. |
| `ASCII16`                   | Convert via `ascii16_to_k5.py` (mapper = "ascii16_k5") | Installs a RAM helper at 0xF000 that the patched ROM CALLs. Validated with Golvellius. |
| `Synthesizer`               | Loaded as plain 32K. The Yamanooto FPGA emulates the PCM DAC **with a current core** (verified on real hardware with `yimmi8beta2`; older cores stay mute). **openMSX gotcha:** `Yamanooto.cc` (21.0 and master) does not implement the DAC — the cart runs but stays silent in the emulator. |
| `Majutsushi`                | Loaded as Konami-4 (K4). The cart is a normal K4 with an extra 8-bit DAC at `0x5000-0x5FFF` (Hai no Majutsushi - Mahjong 2). Same core requirement and openMSX gotcha as Synthesizer. |
| `GameMaster2`, `keyboardmaster` | Not supported | Hardware-specific. |

### Mapper kinds in TOML

| `mapper` value | Use for |
| --- | --- |
| `scc` | KonamiSCC ROMs with SCC sound (needs OFFR alignment) |
| `k5`  | K5 mapper hardware but **no SCC sound** (e.g. ASCII8 conversions where the original game didn't have SCC) — no alignment needed |
| `k4`  | Konami non-SCC |
| `plain` | Mirrored 8/16/32KB carts |
| `ascii16_k5` | Output of `ascii16_to_k5.py` |

## How the launcher works

```
Power on
  ├─ BIOS scans cart slots, finds "AB" header at the launcher in flash bank 0
  ├─ BIOS calls launcher INIT
  │   ├─ Sets page 2 = cart slot (BIOS leaves page 2 = RAM by default)
  │   ├─ Resets cartridge config (master offset, mapper OFFR, CFGR except the
  │   │  user's Echo bit) — on real hardware these SURVIVE a soft reset
  │   ├─ Pages directory bank (15) at 0xA000-0xBFFF
  │   ├─ Shows splash with copyright/scam notice
  │   ├─ Draws menu + scrolling marquee + status-row toggles:
  │   │  TAB = 50/60Hz (applied LIVE to VDP R#9, MSX2+),
  │   │  F1 = Z80/R800 (turbo R only), HOME = PSG Echo (cartridge feature)
  │   └─ Polls keyboard
  └─ On ENTER:
      ├─ Copies the directory entry to RAM
      ├─ Copies the trampoline (<256 bytes) to 0xC000
      ├─ Optionally copies the ASCII16 / SRAM helpers to 0xF000+
      ├─ Trampoline at 0xC000:
      │   ├─ ENAR.REGEN = 1 (plus MSTEN for plain K4 games)
      │   ├─ CFGR = SUBOFF|ECHO (clean K5, MDIS=0, so bank writes work)
      │   ├─ 0x7FFE = game offset — plain K4 games write it with MSTEN=1 so
      │   │  current cores load the MASTER offset (official YAMABOOT protocol);
      │   │  openMSX's old-firmware model reads the same write as its OFFR
      │   ├─ Writes 4 bank registers (K5 regs; commits the offset in openMSX)
      │   ├─ CFGR = final value (K4 / MDIS / SUBOFF as required)
      │   ├─ ENAR = 0 (lock — game can't accidentally clobber CFGR)
      │   ├─ K4 games: re-prime windows 1-3 via 0x6000/0x8000/0xA000
      │   └─ CALLs the game's INIT vector
      └─ If the game's INIT returns (hook-based games like Metal Gear 2):
          └─ Falls through to a JP 0x0000 BIOS warm-boot.
             OFFR/CFGR/banks survive (they're cartridge hardware), so BIOS
             rebooting sees the game's AB header and re-runs INIT through
             its full post-INIT flow that ultimately fires the game's
             H.CHGE hook.
```

## Validated games

**On real hardware (2026-07, Yamanooto with `yimmi8beta2` core):** full
collection image built with the GUI — launcher, Konami-4 (Metal Gear, Penguin
Adventure, Gradius/Nemesis, …), SCC games with music (sequential packing, no
alignment), **Metal Gear 1 & 2 saving and loading from cartridge flash**, and
Synthesizer with working PCM audio.

End-to-end tested in openMSX 21 with the `Yamanooto` mapper:

- **Mirrored 16K**: Konami's Ping-Pong, Road Fighter, ~30 more
- **Konami-4 (K4)**: Vampire Killer (Akumajou Dracula), Penguin Adventure, Maze of Galious, Usas, Metal Gear, Firebird, Ganbare Goemon, Knightmare III - Shalom (512K)
- **Konami-SCC (K5) small (128K)**: Salamander, Quarth, F1 Spirit, Gekitotsu Pennant Race 1/2, Gryzor, Hai no Majutsushi, King's Valley 2 (×2), Gradius 2 (SCC music validated)
- **Konami-SCC 256K**: Parodius, Space Manbow, Gofer no Yabou (Nemesis 3)
- **Konami-SCC 512K**: Metal Gear 2: Solid Snake (uses H.CHGE hook — warm-boot fallback path)
- **ASCII8 → K5 conversion**: validated with **1942** (Capcom, 1987 — GoodMSX dump, 23 patches). Used when a game has only ASCII8 dumps available and no K4 GoodMSX equivalent.
- **ASCII16 → K5 conversion**: validated with **Golvellius** (Compile, 1987 — GoodMSX dump, 2+11 patches). Installs a RAM helper at 0xF000 that the patched ROM CALLs to perform the bank switch.

**Full mega-image**: 59 of 62 Konami MSX cartridge games packed into a single
5.3MB image (out of 8MB available); the 3 not included are unsupported
mapper variants (one ASCII8
Konami Game Master 2 that hasn't been converted). 2.25MB of flash spare for
more games.

## Gotchas the hard way

These are documented because we hit them and they cost time.

1. **BIOS leaves page 2 in RAM at cart-INIT time.** The Yamanooto bank
   registers live in page 2 (0x9000, 0xB000), so the launcher must
   `OUT (0xA8), A` to copy page 1's slot bits to page 2 before writing
   any bank register. Otherwise the writes go to RAM and silently do
   nothing.

2. **Trampoline ordering matters.** Bank writes only fire when the
   cartridge is in K5 mode with MDIS=0. So the trampoline must:
   set CFGR=0 first → set OFFR → write banks → THEN set the game's
   real CFGR (which may have K4/MDIS).

3. **Lock REGEN after configuration.** Many games inadvertently write to
   0x7FFD/0x7FFE/0x7FFF during normal operation. With REGEN=1 those writes
   clobber CFGR/OFFR. Symptom: SCC music dies after a few seconds while
   graphics keep running. Setting REGEN=0 after setup blocks the clobber.

4. **Konami SCC bank wrapping + openMSX 21.0 SCC enable bug.** Real Konami
   SCC carts mask the bank value to the ROM's bank count (a 128K cart →
   `value & 0xF`). Salamander writes `0x3F` which wraps to bank 15 (last
   bank, where the music driver lives) AND simultaneously enables the SCC
   chip. The Yamanooto doesn't auto-mask, AND openMSX 21.0 checks
   `bankRegs[2]` (the offset-adjusted value) instead of `rawBanks[2]`.
   On REAL hardware the raw value is checked, so no alignment is needed —
   verified 2026-07 on a physical cartridge. Since v1.7 packing is
   sequential by default; the 512KB-aligned mode survives as an opt-in
   (`--scc-align` / TOML) purely for openMSX 21.0 users. Full write-up in
   [`docs/SCC_ALIGNMENT.md`](docs/SCC_ALIGNMENT.md).

5. **Wrap-mirror is just 8KB**, not 512KB. For SCC games < 512K, the
   packer copies the game's last bank (8KB, where the music driver lives)
   to flash bank `OFFR*4 + 63` — the spot the `0x3F`-bankwrite lands on.
   The rest of the 512K SCC slot (up to 376KB per 128K game) is reused
   to pack K4/plain games. This is a huge save vs the "full 4x mirror"
   approach.

6. **Hook-based games (Metal Gear 2) need `JP 0x0000` warm-boot.** MG2's
   INIT installs an H.CHGE hook at 0xFEDA and `RET`s, expecting BIOS to
   call CHGMOD later as part of its post-INIT flow. The trampoline pushes
   the RAM address of its `tramp_warmboot` routine before `jp (hl)`-ing to
   game INIT: if the game RETs, control falls through to `jp 0x0000`, BIOS
   reboots and runs the standard cart-init flow which fires the hook.
   Games that take over the CPU directly (Salamander, Vampire Killer, …)
   skip this path and load instantly.

7. **Konami-4 needs a current core (`ziggy1beta7`+) — the hard way.** Two full days
   of black screens on real hardware, one diagnostic ROM (`probe/`) and one
   read of the official YAMABOOT source later: older FPGA cores simply do
   not store the CFGR K4 mapper bit (the same write DOES store MDIS), so
   the cartridge silently stays in K5 mode and every Konami-4 bank write
   lands on dead addresses. openMSX never reproduces it because it models
   the old firmware where the bit works. If K4 games black-screen on your
   cartridge: update the core first, ask questions later.

## Build verification

To rebuild everything and produce a test image with bundled dummy games
(no real ROMs needed):

```sh
make -C launcher                                # if you add a Makefile
# or
cd launcher && pasmo --bin launcher.asm launcher.bin && cd ..
python3 packager/yamanooto_pack.py test         # produces test_image.rom
openmsx -machine "C-BIOS_MSX2+" -cart test_image.rom -romtype Yamanooto
```

## Credits

- **Yamanooto cartridge**: MFides (FPGA + board), Pablibiris / MSX Calamar
  (assembly), knm1983 (audio), FX (YAMAFX software), erpirao, Jorito.
  Distributed by Genami Retro Prototypes.
- **openMSX** project for the emulator, the Yamanooto extension config, and
  `softwaredb.xml`.
- **Konami** for the games. ROMs are not redistributed here — bring your own.

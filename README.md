# YAMENAMI — Yamanooto MSX cartridge toolkit

Build multi-game ROM images for the [Yamanooto](https://genami.shop) MSX flash
cartridge from your own legally-obtained Konami ROMs.

> **This is a toolkit, not a ROM compilation.** No game data ships with this
> repository. You supply your own ROMs; the scripts pack them into a single
> 8MB image that the Yamanooto's `YAMAFX.com` utility can flash.
>
> If anyone is selling you a pre-built ROM made with this tool — **you have
> been scammed**. The whole point of the toolkit is that the work to build
> it is free.

## What's in here

| Path | Purpose |
| --- | --- |
| `launcher/launcher.asm` | Z80 launcher that draws the in-cart menu and dispatches games. Assembled with [Pasmo](http://pasmo.speccy.org/). |
| `packager/yamanooto_pack.py` | Builds the 8MB flash image (launcher + game directory + games). Auto-detects mapper by SHA1 against openMSX's `softwaredb.xml`. |
| `packager/ascii8_to_k5.py` | Converts ASCII8 ROMs (e.g. some Penguin Adventure dumps) to Konami-SCC (K5) so the Yamanooto can run them. Validated working with Penguin Adventure 128K. |
| `packager/ascii16_to_k5.py` | Converts ASCII16 ROMs to K5 using a small RAM helper installed by the launcher. Less proven — best-effort. |
| `catalog/konami_catalog.toml` | Reference list of Konami MSX cartridge dumps with their mappers (informational). |

## Requirements

- **Pasmo** (Z80 assembler) — `brew install pasmo` on macOS
- **Python 3.11+** (for `tomllib`; on 3.10 install `tomli`)
- **openMSX 21+** (optional, for testing — the Yamanooto extension is built in)

## Quick start

### 1. Assemble the launcher

```sh
cd launcher && pasmo --bin launcher.asm launcher.bin
```

Produces `launcher/launcher.bin` (~1.3 KB).

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

# ASCII8 games (e.g. some Penguin Adventure dumps) must be converted first:
#   python3 packager/ascii8_to_k5.py penguin.rom penguin_k5.rom
[[games]]
title = "Penguin Adv (K5 patch)"
file  = "penguin_k5.rom"
mapper = "scc"          # converter output is K5
```

### 3. Build the image

```sh
python3 packager/yamanooto_pack.py build games.toml -o yamanooto.rom
```

You get `yamanooto.rom` (exactly 8 MB).

### 4. Flash to the Yamanooto

Per the cartridge's user manual:

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
| `KonamiSCC`                 | Native K5/SCC, **OFFR aligned to multiples of 16** (512KB boundary) | See "openMSX 21.0 SCC bug" below. Games < 512K get an 8KB wrap-mirror placed at flash bank `OFFR*4 + 63` so the `0x3F` SCC-enable trick lands on the game's music driver. The rest of the 512K slot is reusable for K4/plain games. |
| `Konami` (Konami-4)         | Native K4         | Any OFFR. No mirror needed. |
| `Mirrored` (8KB/16KB carts) | Native via K4+MDIS, bank pattern `0,0,0,0` / `0,1,0,1` | Stays its original size in flash; mirror happens in the mapper. |
| `0x4000` (16KB at page 1)   | Same as Mirrored  | |
| `ASCII8`                    | Convert via `ascii8_to_k5.py` (use `mapper = "k5"` in TOML after conversion) | Rewrites `LD (nn),A` opcodes that hit the ASCII8 switch zone. Validated: Penguin Adventure. Note: many "ASCII8" Penguin dumps online are re-packs; the canonical **GoodMSX dump is K4** — prefer that if available. |
| `ASCII16`                   | Convert via `ascii16_to_k5.py` (experimental, mapper = "ascii16_k5") | Installs a RAM helper at 0xF000 that the patched ROM CALLs. |
| `GameMaster2`, `Synthesizer`, `keyboardmaster` | Not supported | Hardware-specific. |

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
  │   ├─ Pages directory bank (15) at 0xA000-0xBFFF
  │   ├─ Shows splash with copyright/scam notice
  │   ├─ Draws menu + scrolling marquee
  │   └─ Polls keyboard
  └─ On ENTER:
      ├─ Copies the directory entry to RAM
      ├─ Copies the trampoline (≈90 bytes) to 0xC000
      ├─ Optionally copies the ASCII16 helper to 0xF000
      ├─ Trampoline at 0xC000:
      │   ├─ ENAR.REGEN = 1
      │   ├─ CFGR = 0 (clean K5 with MDIS=0 so bank writes work)
      │   ├─ OFFR = game offset
      │   ├─ Writes 4 bank registers (commits OFFR)
      │   ├─ CFGR = final value (K4 / MDIS / SUBOFF as required)
      │   ├─ ENAR = 0 (lock — game can't accidentally clobber CFGR)
      │   └─ CALLs the game's INIT vector
      └─ If the game's INIT returns (hook-based games like Metal Gear 2):
          └─ Falls through to a JP 0x0000 BIOS warm-boot.
             OFFR/CFGR/banks survive (they're cartridge hardware), so BIOS
             rebooting sees the game's AB header and re-runs INIT through
             its full post-INIT flow that ultimately fires the game's
             H.CHGE hook.
```

## Validated games

End-to-end tested in openMSX 21 with the `Yamanooto` mapper:

- **Mirrored 16K**: Konami's Ping-Pong, Road Fighter, ~30 more
- **Konami-4 (K4)**: Vampire Killer (Akumajou Dracula), Penguin Adventure, Maze of Galious, Usas, ~6 more (incl. Knightmare III - Shalom 512K)
- **Konami-SCC (K5) small (128K)**: Salamander, Quarth, F1 Spirit, Gekitotsu Pennant Race 1/2, Gryzor, Hai no Majutsushi, King's Valley 2 (×2), Gradius 2 (SCC music validated)
- **Konami-SCC 256K**: Parodius, Space Manbow, Gofer no Yabou (Nemesis 3)
- **Konami-SCC 512K**: Metal Gear 2: Solid Snake (uses H.CHGE hook — warm-boot fallback path)
- **ASCII8 → K5 conversion**: ASCII8 Penguin Adventure ROM (518 patches) using `ascii8_to_k5.py` + `mapper = "k5"`

**Full mega-image**: 59 of 62 Konami MSX cartridge games packed into a single
5.3MB image (out of 8MB available); the 3 not included are unsupported
mapper variants (Konami's Synthesizer with custom hardware, and one ASCII8
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
   chip. The Yamanooto doesn't auto-mask.

   On top of that, **openMSX 21.0** (current public release) has a known
   bug in `Yamanooto::isSCCAccess()`: it checks `(bankRegs[2] & 0x3F)`
   instead of `(rawBanks[2] & 0x3F)`. Fix is in master but unreleased.

   Consequence: for `(0x3F + OFFR*4) & 0x3F == 0x3F` to be true,
   `OFFR*4 mod 64 == 0` → **OFFR must be a multiple of 16** (= 512KB
   boundary). The packager places SCC games at those positions. The real
   hardware works either way; this alignment is also safe.

5. **Wrap-mirror is just 8KB**, not 512KB. For SCC games < 512K, the
   packer copies the game's last bank (8KB, where the music driver lives)
   to flash bank `OFFR*4 + 63` — the spot the `0x3F`-bankwrite lands on.
   The rest of the 512K SCC slot (up to 376KB per 128K game) is reused
   to pack K4/plain games. This is a huge save vs the "full 4x mirror"
   approach.

6. **Metal Gear 2 needs `JP 0x0000` warm-boot.** MG2's INIT installs a
   hook at H.CHGE (0xFEDA) and `RET`s, expecting BIOS to call CHGMOD
   later. The trampoline pushes the RAM address of its `tramp_warmboot`
   routine before `jp (hl)`-ing to game INIT. If game RETs, control
   falls through to `jp 0x0000`, BIOS reboots and runs the standard
   cart-init flow which triggers the hook. Salamander and other games
   that take over the CPU directly skip this path entirely.

5. **Hook-based games (Metal Gear 2).** MG2's INIT installs an H.CHGE
   hook at 0xFEDA and `RET`s, expecting BIOS to call CHGMOD later as part
   of its post-INIT flow. Our launcher calls INIT directly, so the hook
   never fires unless we fall through to a `JP 0x0000` warm-boot. The
   launcher uses warm-boot only when INIT returns; games that take over
   the CPU directly (Salamander, Vampire Killer, etc.) avoid it and load
   instantly.

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

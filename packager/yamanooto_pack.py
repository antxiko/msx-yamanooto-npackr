#!/usr/bin/env python3
"""
yamanooto_pack.py — Build a Yamanooto 8MB ROM image.

Layout:
  0x000000  launcher.bin (padded to 32KB, banks 0-3, OFFR=0)
  0x008000  free / reserved for launcher extra data
  0x01E000  game directory (bank 15, 8KB)
  0x020000  games pool (each game aligned to 32KB / OFFR units)
  0x7FFFFF  end of flash (8MB)

Usage:
  yamanooto_pack.py build config.toml -o yamanooto.rom
  yamanooto_pack.py test                                # build a tiny test image
  yamanooto_pack.py detect path/to/rom                  # detect mapper from openMSX softdb
"""

import argparse
import hashlib
import os
import re
import struct
import sys
import urllib.request
from pathlib import Path

# Constants matching launcher.asm
# Yamanooto models exist with 2 MB or 8 MB of flash. The packager defaults to
# 8 MB but `--flash-size` lets the user select either.
FLASH_SIZE_8MB   = 8 * 1024 * 1024
FLASH_SIZE_2MB   = 2 * 1024 * 1024
FLASH_SIZE       = FLASH_SIZE_8MB   # default; can be overridden by CLI
BANK_SIZE        = 8 * 1024        # 8 KB per Konami bank
OFFR_UNIT        = 32 * 1024       # OFFR steps in 32 KB
LAUNCHER_BANKS   = 4               # banks 0-3, 32 KB
LAUNCHER_OFFSET  = 0x000000
LAUNCHER_SIZE    = LAUNCHER_BANKS * BANK_SIZE   # 32 KB
DIR_BANK         = 15
DIR_OFFSET       = DIR_BANK * BANK_SIZE         # 0x01E000
DIR_HDR_SIZE     = 32
DIR_ENTRY_SIZE   = 32
DIR_MAX_ENTRIES  = (BANK_SIZE - DIR_HDR_SIZE) // DIR_ENTRY_SIZE   # 255
GAMES_POOL_START = 0x020000        # 128 KB in, first OFFR-aligned slot after dir
FILL_BYTE        = 0xFF            # erased flash state


def _max_offr_units() -> int:
    """Total OFFR units available given the current FLASH_SIZE."""
    return FLASH_SIZE // OFFR_UNIT

# Directory entry FLAGS (must match launcher.asm)
FLAG_K4         = 0x01
FLAG_MDIS       = 0x02
FLAG_PSGMUTE    = 0x04
FLAG_ASCII16    = 0x08
FLAG_SCC_HELPER = 0x10
FLAG_SRAM       = 0x20             # SRAM-emulation game (launcher installs helper)
FLAG_COLDBOOT   = 0x40             # launch via BIOS reboot (resident carts, e.g. GM2)

# SRAM emulation: per-game 64KB save sector + lookup table in flash bank 14.
# Table format ("YSRT"): +0 magic, +4 ver, +8 entries of 8 bytes indexed by
# DIRECTORY position: u16 sector_bank(8KB units), u8 type, u8 enable_bit,
# u8 slot_banks, 3 reserved 0xFF. Non-SRAM entries = 8x 0xFF.
# Sector layout: banks 0..5 save slots, bank 7 META ("YSAV" hdr + commit log).
SRAM_TABLE_BANK   = 14
SRAM_TABLE_OFFSET = SRAM_TABLE_BANK * BANK_SIZE    # 0x1C000
SAVE_SECTOR_SIZE  = 0x10000        # one AMD 64KB sector per SRAM game
SRAM_TYPE_GM2         = 1
SRAM_TYPE_ASCII8SRAM  = 2
SRAM_TYPE_ASCII16SRAM = 3
SRAM_TYPE_ASCII8SRAM2 = 4

# Mapper kinds recognized by the packager (sourced from konami_catalog.toml etc.)
MAPPER_SCC        = 'scc'          # KonamiSCC, K4=0, banks 0,1,2,3 — assumes SCC sound
MAPPER_K5         = 'k5'           # K5 mapper but no SCC sound (e.g. ASCII8 conversion).
                                    # Same hw config as 'scc' but no OFFR alignment needed.
MAPPER_K4         = 'k4'           # Konami (no SCC), K4=1, banks 0,1,2,3
MAPPER_PLAIN      = 'plain'        # Mirrored/0x4000, K4=1, MDIS=1, mirror banks
MAPPER_ASCII16_K5 = 'ascii16_k5'   # ROM patched by ascii16_to_k5.py — needs helper
MAPPER_ASCII8_SRAM = 'ascii8_sram' # ASCII8+SRAM patched by ascii8sram_to_k5.py —
                                    # launcher installs the SRAM-emulation helper
                                    # and a 64KB flash save sector is reserved.
MAPPER_GM2         = 'gm2'         # Game Master 2 patched by gm2_to_yamanooto.py —
                                    # GM2 SRAM helper variant + 64KB save sector.
MAPPER_MG2         = 'mg2'         # Metal Gear 2 patched by mg2_to_yamanooto.py —
                                    # KonamiSCC + appended micro save-driver +
                                    # three 64KB save sectors (SNAK1/2/3).
MAPPER_MG1         = 'mg1'         # Metal Gear 1 patched by mg1_to_yamanooto.py —
                                    # Konami-4 + appended virtual-tape driver bank +
                                    # one 64KB save sector at relative bank 0x18.

# -----------------------------------------------------------------------------
# Mapper auto-detection via openMSX softwaredb (SHA1 -> mapper type)
# -----------------------------------------------------------------------------
SOFTWAREDB_URL = "https://raw.githubusercontent.com/openMSX/openMSX/master/share/softwaredb.xml"
SOFTWAREDB_CACHE = Path.home() / ".cache" / "yamanooto_pack" / "softwaredb.xml"

# Mapping from openMSX mapper type names to our internal mapper kinds.
# None means "not supported natively by Yamanooto" — caller may try a
# conversion (e.g. ASCII8->K5 via ascii8_to_k5.py).
SOFTDB_TO_YAMA = {
    "KonamiSCC": MAPPER_SCC,
    "Konami":    MAPPER_K4,
    "Mirrored":  MAPPER_PLAIN,
    "Normal":    MAPPER_PLAIN,
    "0x0000":    MAPPER_PLAIN,
    "0x4000":    MAPPER_PLAIN,
    "0x8000":    MAPPER_PLAIN,
    "8kB":       MAPPER_PLAIN,
    "16kb":      MAPPER_PLAIN,
    "Page2":     MAPPER_PLAIN,
    "Page12":    MAPPER_PLAIN,
    "Mirrored4000": MAPPER_PLAIN,
    "ASCII8":    None,
    "ASCII16":   None,
    "ASCII8SRAM8":  None,    # SRAM variants not yet supported
    "ASCII16SRAM2": None,
    "ASCII8SRAM2":  None,
    "KoeiSRAM32":   None,
    "GameMaster2":  None,
    "Synthesizer":  MAPPER_PLAIN,  # Konami's Synthesizer (RC-741): 32K linear cart.
                                    # The Yamanooto's FPGA emulates the DAC, so the
                                    # cart's audio works without special handling.
    "Majutsushi":   MAPPER_K4,     # Hai no Majutsushi - Mahjong 2: K4 banks + DAC
                                    # writes at 0x5000-0x5FFF. Same story as the
                                    # Synthesizer — FPGA emulates the DAC on real
                                    # hardware; openMSX 21 Yamanooto.cc does not.
    "keyboardmaster": None,
    "Page23":    None,       # 32K cart at CPU 0x8000-0xFFFF (page 2+3) — needs special trampoline
    "R-Type":    None,       # Irem-specific bankswitching
    "Cross Blaim": None,     # game-specific
}


def _ensure_softwaredb(force: bool = False) -> Path:
    """Download openMSX softwaredb.xml to local cache if missing."""
    if SOFTWAREDB_CACHE.exists() and not force:
        return SOFTWAREDB_CACHE
    SOFTWAREDB_CACHE.parent.mkdir(parents=True, exist_ok=True)
    print(f"Fetching {SOFTWAREDB_URL} ...", file=sys.stderr)
    urllib.request.urlretrieve(SOFTWAREDB_URL, SOFTWAREDB_CACHE)
    return SOFTWAREDB_CACHE


_softdb_cache = None  # lazily populated

def _load_softdb() -> dict:
    """Return dict: lowercase_sha1 -> (softdb_type, title, system) for all entries."""
    global _softdb_cache
    if _softdb_cache is not None:
        return _softdb_cache
    path = _ensure_softwaredb()
    db = {}
    title = "?"
    system = "?"
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            mt = re.search(r'<software\s+title="([^"]+)"', line)
            if mt:
                title = mt.group(1)
                ms = re.search(r'system="([^"]+)"', line)
                system = ms.group(1) if ms else "?"
                continue
            mr = re.search(r'sha1="([0-9a-fA-F]+)"\s+type="([^"]+)"', line)
            if mr:
                sha = mr.group(1).lower()
                typ = mr.group(2)
                if sha not in db or 'status="GoodMSX"' in line:
                    db[sha] = (typ, title.replace("&apos;", "'"), system)
    _softdb_cache = db
    return db


def detect_mapper(rom_data: bytes) -> tuple[str | None, str | None, str, str]:
    """Detect mapper for a ROM. Returns (yama_mapper, softdb_type, title, system)."""
    sha = hashlib.sha1(rom_data).hexdigest().lower()
    db = _load_softdb()
    if sha not in db:
        return None, None, "(unknown SHA1)", "?"
    softdb_type, title, system = db[sha]
    yama = SOFTDB_TO_YAMA.get(softdb_type)
    return yama, softdb_type, title, system


def pad(data: bytes, size: int, fill: int = FILL_BYTE) -> bytes:
    if len(data) > size:
        raise ValueError(f"Data size {len(data)} exceeds limit {size}")
    return data + bytes([fill]) * (size - len(data))


# --- Marquee customization ----------------------------------------------------
# The launcher's scrolling marquee is a single 128-byte buffer (stored twice
# in launcher.bin for the no-wrap display trick). The anti-scam notice now
# only shows on the boot splash, so the marquee is fully customizable.
# We locate both copies of the buffer by searching for the default placeholder
# string and overwrite them in place.
MARQUEE_ANCHOR = (
    b"                                        "
    b"THIS TEXT CAN BE REPLACED, PLEASE READ THE DOCS"
    b"                                         "
)
MARQUEE_CUSTOM_SIZE = 128
assert len(MARQUEE_ANCHOR) == MARQUEE_CUSTOM_SIZE


def _apply_marquee(launcher_bytes: bytes, custom: str | None) -> bytes:
    """Overwrite the custom marquee buffer in both copies. `None` keeps the
    baked-in default placeholder; an empty string BLANKS the marquee (fills it
    with spaces) so nothing scrolls — matching the GUI. The MSX font is
    uppercase-only, so text is uppercased and padded to MARQUEE_CUSTOM_SIZE."""
    if custom is None:
        return launcher_bytes

    custom_up = custom.upper()
    if len(custom_up) > MARQUEE_CUSTOM_SIZE:
        custom_up = custom_up[:MARQUEE_CUSTOM_SIZE]
    else:
        pad_total = MARQUEE_CUSTOM_SIZE - len(custom_up)
        left = pad_total // 2
        right = pad_total - left
        custom_up = (" " * left) + custom_up + (" " * right)
    # Best-effort ASCII encode; non-ASCII chars become "?" (still 1 byte).
    custom_bytes = custom_up.encode("ascii", errors="replace")
    assert len(custom_bytes) == MARQUEE_CUSTOM_SIZE

    data = bytearray(launcher_bytes)
    positions = []
    start = 0
    while True:
        idx = data.find(MARQUEE_ANCHOR, start)
        if idx < 0:
            break
        positions.append(idx)
        start = idx + 1
    if len(positions) != 2:
        raise RuntimeError(
            f"--marquee: expected 2 marquee copies in launcher.bin, found "
            f"{len(positions)}. Is launcher.bin from a version that supports "
            f"custom marquees? Rebuild it with pasmo."
        )
    for idx in positions:
        data[idx:idx + MARQUEE_CUSTOM_SIZE] = custom_bytes
    return bytes(data)


# --- Title customization ------------------------------------------------------
# The launcher's title is a fixed 32-byte buffer (text + NUL + padding) located
# by its default string. Keep TITLE_ANCHOR in sync with launcher.asm's msg_title.
TITLE_ANCHOR = b"YAMANOOTO KONAMI COLLECTION"
TITLE_BUF_SIZE = 32


def _apply_title(launcher_bytes: bytes, title: str | None) -> bytes:
    """Overwrite the title buffer. No-op if title is None/empty. The MSX font is
    uppercase-only, so the text is uppercased; it is NUL-terminated and padded to
    TITLE_BUF_SIZE. Longer titles are truncated (they'd overflow the screen/box)."""
    if not title:
        return launcher_bytes
    t = title.upper()
    maxlen = TITLE_BUF_SIZE - 1          # leave room for the NUL terminator
    if len(t) > maxlen:
        print(f"--title: truncated to {maxlen} chars (was {len(t)})", file=sys.stderr)
        t = t[:maxlen]
    buf = t.encode("ascii", errors="replace") + b"\x00"
    buf = buf + b"\x00" * (TITLE_BUF_SIZE - len(buf))
    assert len(buf) == TITLE_BUF_SIZE

    data = bytearray(launcher_bytes)
    idx = data.find(TITLE_ANCHOR)
    if idx < 0:
        raise RuntimeError(
            "--title: title anchor not found in launcher.bin. Is it from a "
            "version that supports a custom title? Rebuild it with pasmo.")
    if data.find(TITLE_ANCHOR, idx + 1) >= 0:
        raise RuntimeError("--title: title anchor found more than once in launcher.bin.")
    data[idx:idx + TITLE_BUF_SIZE] = buf
    return bytes(data)


# --- Menu colours ------------------------------------------------------------
# The colour nibbles live in the "YMNTCFG!" config block of launcher.bin:
#   anchor (8 bytes) | +8 splash flag | +9 text | +10 bg | +11 box
# (see launcher.asm cfg_col_*). Each is an MSX palette index; init_colors in the
# launcher derives the SCREEN 2 colour-table bytes from them at boot.
CFG_ANCHOR = b"YMNTCFG!"
CFG_COL_TEXT_OFF = 9   # offsets from the anchor start
CFG_COL_BG_OFF = 10
CFG_COL_BOX_OFF = 11
CFG_MUSIC_OFF = 12     # boot jingle enable (see launcher.asm cfg_music_enable)
CFG_TILE_OFF = 13      # 8-byte background tile (launcher.asm cfg_tile)

# MSX1 (TMS9918) palette. Index 0 is transparent; menu colours use 1-15.
MSX_COLORS = {
    "transparent": 0, "black": 1, "medium-green": 2, "light-green": 3,
    "dark-blue": 4, "light-blue": 5, "dark-red": 6, "cyan": 7,
    "medium-red": 8, "light-red": 9, "dark-yellow": 10, "light-yellow": 11,
    "dark-green": 12, "magenta": 13, "gray": 14, "grey": 14, "white": 15,
}


def _parse_color(value) -> int:
    """Accept an int (1-15) or an MSX colour name; return the palette index."""
    if isinstance(value, int):
        idx = value
    else:
        s = str(value).strip().lower()
        if s in MSX_COLORS:
            return MSX_COLORS[s]
        try:
            idx = int(s)
        except ValueError:
            names = ", ".join(sorted(k for k in MSX_COLORS if k != "grey"))
            raise ValueError(f"colour must be 1-15 or a name ({names}); got {value!r}")
    if not 1 <= idx <= 15:
        raise ValueError(f"colour index must be 1-15; got {idx}")
    return idx


def _apply_colors(launcher_bytes: bytes, text=None, bg=None, box=None) -> bytes:
    """Patch the menu colour nibbles (text/background/title-box). Each arg is an
    MSX palette index 1-15 (or a name), or None to keep the launcher default.
    No-op when all three are None."""
    if text is None and bg is None and box is None:
        return launcher_bytes
    data = bytearray(launcher_bytes)
    idx = data.find(CFG_ANCHOR)
    if idx < 0:
        raise RuntimeError(
            "--color-*: 'YMNTCFG!' config anchor not found in launcher.bin. "
            "Rebuild it with pasmo from a version that supports colours.")
    if data.find(CFG_ANCHOR, idx + 1) >= 0:
        raise RuntimeError("--color-*: config anchor found more than once in launcher.bin.")
    for off, val in ((CFG_COL_TEXT_OFF, text), (CFG_COL_BG_OFF, bg), (CFG_COL_BOX_OFF, box)):
        if val is None:
            continue
        data[idx + off] = _parse_color(val)
    return bytes(data)


def _apply_music(launcher_bytes: bytes, enable) -> bytes:
    """Patch the boot-jingle flag in the YMNTCFG! block (byte +12). None keeps
    the launcher default (jingle plays); True/False force it on/off."""
    if enable is None:
        return launcher_bytes
    data = bytearray(launcher_bytes)
    idx = data.find(CFG_ANCHOR)
    if idx < 0:
        raise RuntimeError(
            "boot_music: 'YMNTCFG!' config anchor not found in launcher.bin. "
            "Rebuild it with pasmo from a version that supports the music flag.")
    if data.find(CFG_ANCHOR, idx + 1) >= 0:
        raise RuntimeError("boot_music: config anchor found more than once in launcher.bin.")
    data[idx + CFG_MUSIC_OFF] = 1 if enable else 0
    return bytes(data)


def round_up_to_32k(n: int) -> int:
    return (n + OFFR_UNIT - 1) & ~(OFFR_UNIT - 1)


SCC_MIRROR_TARGET = 512 * 1024   # 64 banks. Validated working for Salamander 128K.
                                  # Larger games (>=512K) get NO mirror — they already
                                  # have all 64 banks, so bank value 0x3F (SCC enable +
                                  # "last bank") naturally hits the game's last bank.

# Module-level SCC strategy. Options:
#   "auto"   — try to patch ROM (no mirror needed); fall back to mirror if no
#              SCC-enable patterns found. DEFAULT.
#   "mirror" — always mirror 4x (Salamander-proven; safest, biggest).
#   "patch"  — always patch; if no patterns found, FAIL loudly (game won't
#              get music since neither strategy is in effect).
#   "none"   — neither patch nor mirror; SCC music may not work but game runs.
_scc_strategy = "auto"


class Game:
    """One game to be placed in the flash."""

    def _apply_scc_strategy(self, data: bytes) -> bytes:
        """Resolve the SCC <512KB game into either a patched ROM (+flag) or
        a 4x mirror. Sets self.flags accordingly. Returns the new data."""
        import scc_patch
        strategy = _scc_strategy
        if strategy in ("auto", "patch"):
            patched, n = scc_patch.convert(data)
            if n > 0:
                self.flags |= FLAG_SCC_HELPER
                return patched
            if strategy == "patch":
                raise RuntimeError(
                    f"SCC strategy=patch but no SCC-enable patterns found in "
                    f"{self.title!r}. Try strategy='auto' to fall back to mirror, "
                    f"or strategy='mirror' to force the 4x mirror.")
            # auto + no patches -> fall through to mirror
        if strategy in ("auto", "mirror"):
            copies = SCC_MIRROR_TARGET // len(data)
            return data * copies
        # strategy == "none": leave as-is. SCC music likely won't work.
        return data

    def __init__(self, title: str, data: bytes, mapper: str):
        self.title = title[:23]               # max 23 chars (24 incl NUL)
        self.mapper = mapper
        self.offr = None                      # filled by packer
        self.suboff = 0                       # bits 4-5 of CFGR
        self.flags = 0                        # FLAGS byte
        self.banks = (0, 1, 2, 3)             # default
        # If set, the packer places this game in a 16-OFFR-aligned slot and
        # writes a copy of the game's last bank at flash bank (OFFR*4 + 63)
        # so the SCC enable trick (LD A,0x3F : LD (0x9000),A) lands on music.
        self.needs_wrap_mirror = False
        # SRAM emulation (FLAG_SRAM games only)
        self.sram_type = None                 # SRAM_TYPE_* or None
        self.sram_enbit = 0                   # bank-value bit that selects SRAM
        self.sram_slot_banks = 1              # 8KB banks per save slot
        self.save_sector_bank = None          # filled by packer (8KB bank units)
        # Override the reserved flash footprint (in OFFR/32KB units). Used by
        # mappers that append driver + save sectors beyond the ROM data (mg2).
        self.footprint_units = None

        size = len(data)
        if mapper == MAPPER_SCC:
            # K5/SCC games write 0x3F to bank 2 to enable SCC + "switch to
            # last bank" (where the music driver lives). Yamanooto doesn't
            # wrap the bank value, AND openMSX 21.0 checks (bankRegs & 0x3F)
            # so OFFR must be multiple of 16 to keep the SCC enable bits set.
            # If the game is smaller than 512K, we also copy its last bank to
            # flash bank (OFFR*4 + 63) so the music driver reads real data
            # when the game triggers the SCC-enable trick.
            self.banks = (0, 1, 2, 3)
            if size < 512 * 1024:
                self.needs_wrap_mirror = True
        elif mapper == MAPPER_K5:
            # K5 mapper hardware but the game does NOT use SCC sound (typically
            # an ASCII8 conversion). No 16-OFFR alignment needed, no wrap mirror.
            self.banks = (0, 1, 2, 3)
        elif mapper == MAPPER_K4:
            # K4 games never need 0x3F semantics; no SCC chip.
            self.banks = (0, 1, 2, 3)
            self.flags = FLAG_K4
        elif mapper == MAPPER_PLAIN:
            self.flags = FLAG_K4 | FLAG_MDIS
            if size <= 8 * 1024:
                self.banks = (0, 0, 0, 0)     # 8K mirrored
            elif size <= 16 * 1024:
                self.banks = (0, 1, 0, 1)     # 16K mirrored
            else:
                self.banks = (0, 1, 2, 3)     # 32K plain
        elif mapper == MAPPER_ASCII16_K5:
            # ROM already patched by ascii16_to_k5.py (CALLs to 0xF000/0xF010).
            self.banks = (0, 1, 2, 3)
            self.flags = FLAG_ASCII16
            if size < 512 * 1024:
                self.needs_wrap_mirror = True
        elif mapper == MAPPER_ASCII8_SRAM:
            # ROM already patched by ascii8sram_to_k5.py (all bank writes ->
            # CALL 0xF030+3n). Runs in K5 mode; the launcher installs the SRAM
            # helper via FLAG_SRAM and the packer reserves a 64KB save sector
            # right after the game data (64KB-aligned).
            self.banks = (0, 1, 2, 3)
            self.flags = FLAG_SRAM
            self.sram_type = SRAM_TYPE_ASCII8SRAM
            # openMSX RomAscii8_8: enable bit = number of 8KB banks (pow2, >= 0x10)
            nbanks = max(1, (size + BANK_SIZE - 1) // BANK_SIZE)
            bit = 1
            while bit < nbanks:
                bit <<= 1
            self.sram_enbit = max(bit, 0x10)
            self.sram_slot_banks = 1
        elif mapper == MAPPER_MG2:
            # Metal Gear 2, patched by mg2_to_yamanooto.py (ROM 520KB = 512KB +
            # 8KB driver at relative bank 0x40). Runs as native KonamiSCC. Its
            # save driver appends SNAK1/2/3 into ONE 64KB sector at relative bank
            # 0x48 (banks 0x48-0x4F, left 0xFF here), so we reserve a 640KB
            # (20-unit) footprint and place it 16-OFFR-aligned like any SCC game
            # (no wrap mirror). The 16-alignment keeps that sector 64KB-aligned
            # in absolute flash. (Was 3x64KB=768KB before the append rewrite.)
            self.banks = (0, 1, 2, 3)
            self.footprint_units = 20
        elif mapper == MAPPER_MG1:
            # Metal Gear 1, patched by mg1_to_yamanooto.py (128KB K4 ROM +
            # 8KB virtual-tape driver at relative bank 0x10). Its cassette
            # save/load is redirected to ONE 64KB sector at relative bank
            # 0x18 (banks 0x18-0x1F, left 0xFF here). Footprint = 256KB
            # (8 units), placed at an even OFFR so the sector stays
            # 64KB-aligned in absolute flash. Plain K4 launch (no helper).
            self.banks = (0, 1, 2, 3)
            self.flags = FLAG_K4
            self.footprint_units = 8
        elif mapper == MAPPER_GM2:
            # Game Master 2, bespoke-patched by gm2_to_yamanooto.py. Runs in
            # NATIVE K4 mode (GM2's bank regs are Konami4's) with its SRAM-disk
            # driver redirected to a RAM shadow + flash save image at relative
            # bank 0x10 (start of the reserved 64KB sector). No resident helper
            # is installed (FLAG_SRAM off): GM2 is a resident cart that owns
            # high RAM, so everything lives in its own patched ROM instead.
            # sram_type is kept so the packer reserves the save sector.
            self.banks = (0, 1, 2, 3)
            # FLAG_COLDBOOT: GM2 is a resident cart; boot it via BIOS reboot so
            # its INIT gets the standard slot context (a direct CALL INIT leaves
            # pages mapped to the wrong slot and hangs).
            self.flags = FLAG_K4 | FLAG_COLDBOOT
            self.sram_type = SRAM_TYPE_GM2
            self.sram_enbit = 0x10
            self.sram_slot_banks = 1
        else:
            raise ValueError(f"Unknown mapper {mapper!r}")

        self.data = data
        self.size_blocks_32k = max(1, (len(data) + OFFR_UNIT - 1) // OFFR_UNIT)


SCC_OFFR_ALIGN = 16   # openMSX 21.0 bug: SCC enable check uses (bankRegs[2] & 0x3F)
                       # instead of rawBanks[2]. For (0x3F + OFFR*4) & 0x3F == 0x3F
                       # we need OFFR ≡ 0 mod 16. Applies to all SCC games.


def _align_up(value: int, align: int) -> int:
    return (value + align - 1) // align * align


def _sub_slots_needed(g):
    """8KB sub-placement eligibility (CFGR SUBOFF, bits 4-5).

    Returns how many 8KB slots the game needs inside a shared 32KB OFFR unit
    (1 for <=8KB, 2 for <=16KB), or None if it must keep taking whole OFFR
    units (SCC/ASCII16/MG2 need 16-OFFR alignment + wrap mirror + the 0x3F
    trick; SRAM games reserve save sectors; footprint overrides reserve extra
    flash). openMSX resolves banks as (value + OFFR*4 + suboff) & 0x3FF, so a
    game at suboff=2 with mirrored banks never touches its neighbour's banks.
    """
    if g.mapper not in (MAPPER_K4, MAPPER_PLAIN):
        return None
    if g.footprint_units or g.sram_type is not None or g.needs_wrap_mirror:
        return None
    size = len(g.data)
    if size <= BANK_SIZE:
        return 1
    if size <= 2 * BANK_SIZE:
        return 2
    return None


def pack_games(games, *, skip_overflow=False):
    """Assign OFFR positions efficiently.

    Strategy:
      1. SCC games need OFFR ≡ 0 mod 16 (512K-aligned). They occupy only their
         data size plus reserve 1 OFFR slot at (start + 15) for the wrap mirror
         (one 8K bank of music driver placed at bank OFFR*4 + 63).
      2. K4 / plain games can go in ANY free OFFR slot, including the gaps
         between an SCC game's data and its wrap-mirror reservation.

    With skip_overflow=True, drop games that don't fit; returns dropped list.
    """
    placed = []
    dropped = []

    # Bitmap of occupied OFFR slots, sized for current FLASH_SIZE.
    n_slots = _max_offr_units()    # 256 (8MB) or 64 (2MB)
    occupied = [False] * n_slots
    # OFFR slots beyond flash size — treat as occupied so we never place there.
    # (occupied is already sized to n_slots, so any range() up to that is fine)
    for i in range(GAMES_POOL_START // OFFR_UNIT):
        if i < n_slots:
            occupied[i] = True

    # Partition games
    scc_games  = [g for g in games if g.mapper in (MAPPER_SCC, MAPPER_ASCII16_K5, MAPPER_MG2)]
    sram_games = [g for g in games
                  if g.sram_type is not None or g.mapper == MAPPER_MG1]
    non_scc    = [g for g in games
                  if g.mapper not in (MAPPER_SCC, MAPPER_ASCII16_K5, MAPPER_MG2, MAPPER_MG1)
                  and g.sram_type is None]

    # Sort SCC games by size descending (place biggest first to avoid fragmentation).
    scc_games.sort(key=lambda g: -len(g.data))

    # First pass: SCC games at 16-OFFR-aligned slots.
    for g in scc_games:
        # footprint_units overrides the data size for mappers that reserve extra
        # flash after the ROM (mg2: driver + save sectors).
        size_offr = g.footprint_units or ((len(g.data) + OFFR_UNIT - 1) // OFFR_UNIT)
        # We also reserve 1 OFFR unit for the wrap mirror (at offset 15 from slot start).
        # Game must fit in OFFR 0..(15 - mirror_units) = 0..14 inside the slot.
        if g.needs_wrap_mirror and size_offr > 15:
            # 512K-1 game doesn't fit; would clobber the mirror slot.
            if skip_overflow:
                dropped.append(g); continue
            raise RuntimeError(f"{g.title!r}: {len(g.data)}B too big for SCC slot with wrap mirror")

        # Find a free 16-aligned slot big enough for the whole footprint.
        span = max(16, size_offr)
        start = _align_up(GAMES_POOL_START // OFFR_UNIT, SCC_OFFR_ALIGN)
        placed_here = False
        while start + span <= n_slots:
            # Check the OFFR units we actually need: [start..start+size_offr-1]
            # plus the mirror unit at start+15 (if needs_wrap_mirror).
            need_units = list(range(start, start + size_offr))
            if g.needs_wrap_mirror:
                need_units.append(start + 15)
            if all(not occupied[i] for i in need_units):
                for i in need_units:
                    occupied[i] = True
                g.offr = start
                g.flash_offset = start * OFFR_UNIT
                placed.append(g)
                placed_here = True
                break
            start += SCC_OFFR_ALIGN
        if not placed_here:
            if skip_overflow:
                dropped.append(g)
            else:
                raise RuntimeError(f"No 16-aligned slot free for {g.title!r}")

    # Pass 1b: SRAM games. Data footprint rounded up to 64KB (2 OFFR units)
    # so the 64KB save sector right after it is sector-aligned in flash.
    # Total reservation = data + 1 sector; start OFFR must be even.
    sram_games.sort(key=lambda g: -len(g.data))
    for g in sram_games:
        size_units = max(1, (len(g.data) + OFFR_UNIT - 1) // OFFR_UNIT)
        data_units = _align_up(size_units, 2)
        # footprint_units (mg1: 8 = ROM+driver+pad+sector, sector position
        # baked into its driver) overrides the data+sector computation.
        total_units = g.footprint_units or (data_units + 2)
        placed_here = False
        start = _align_up(GAMES_POOL_START // OFFR_UNIT, 2)
        while start + total_units <= n_slots:
            if all(not occupied[i] for i in range(start, start + total_units)):
                for i in range(start, start + total_units):
                    occupied[i] = True
                g.offr = start
                g.flash_offset = start * OFFR_UNIT
                if g.sram_type is not None:
                    # sector base in 8KB banks (launcher SECREL games only;
                    # mg1's driver reaches its sector relatively on its own)
                    g.save_sector_bank = (start + data_units) * 4
                placed.append(g)
                placed_here = True
                break
            start += 2
        if not placed_here:
            if skip_overflow:
                dropped.append(g)
            else:
                raise RuntimeError(f"Out of flash placing SRAM game {g.title!r}")

    # Second pass: non-SCC games (K4/plain) in any free OFFR slot.
    # Sort by size descending so big K4 games (512K Shalom!) get placed first.
    # Small games (<=16KB) are sub-placed at 8KB granularity inside a shared
    # 32KB unit via CFGR SUBOFF: one unit holds 2x16KB or 4x8KB games.
    # subunits tracks the free 8KB slots of every opened shared unit.
    non_scc.sort(key=lambda g: -len(g.data))
    subunits = {}   # offr -> [bool]*4, True = 8KB slot used
    for g in non_scc:
        sub_n = _sub_slots_needed(g)
        if sub_n is not None:
            slot = None
            # Try already-opened units first. sorted() keeps this deterministic
            # (parity with the Rust port's BTreeMap iteration order).
            for offr in sorted(subunits):
                bmp = subunits[offr]
                for s in ((0, 2) if sub_n == 2 else (0, 1, 2, 3)):
                    if all(not bmp[i] for i in range(s, s + sub_n)):
                        slot = (offr, s)
                        break
                if slot:
                    break
            if slot is None:
                # Open a new shared unit at the first free OFFR.
                for start in range(n_slots):
                    if not occupied[start]:
                        occupied[start] = True
                        subunits[start] = [False] * 4
                        slot = (start, 0)
                        break
            if slot is not None:
                offr, s = slot
                for i in range(s, s + sub_n):
                    subunits[offr][i] = True
                g.offr = offr
                g.suboff = s << 4          # CFGR bits 4-5; entry[25]-ready
                g.flash_offset = (offr * 4 + s) * BANK_SIZE
                # A sub-placed game must never map banks beyond its own slots:
                # give small K4 games the same mirrored pattern PLAIN already
                # gets in __init__ (with banks (0,1,2,3) a suboff=0 game would
                # read its neighbour's 8KB banks through windows 2-3).
                if g.mapper == MAPPER_K4:
                    g.banks = (0, 0, 0, 0) if sub_n == 1 else (0, 1, 0, 1)
                placed.append(g)
                continue
            if skip_overflow:
                dropped.append(g)
                continue
            raise RuntimeError(f"Out of flash placing {g.title!r}")
        size_offr = max(1, (len(g.data) + OFFR_UNIT - 1) // OFFR_UNIT)
        placed_here = False
        for start in range(n_slots - size_offr + 1):
            if all(not occupied[i] for i in range(start, start + size_offr)):
                for i in range(start, start + size_offr):
                    occupied[i] = True
                g.offr = start
                g.flash_offset = start * OFFR_UNIT
                placed.append(g)
                placed_here = True
                break
        if not placed_here:
            if skip_overflow:
                dropped.append(g)
            else:
                raise RuntimeError(f"Out of flash placing {g.title!r}")

    placed.sort(key=lambda g: g.offr)
    games[:] = placed
    return dropped


def build_directory(games) -> bytes:
    """Build the directory bank (8KB) with header + entries."""
    if len(games) > DIR_MAX_ENTRIES:
        raise RuntimeError(f"Too many games ({len(games)}) > {DIR_MAX_ENTRIES}")
    # Header: magic + count + reserved
    hdr = b"YMNT" + struct.pack("<H", len(games)) + b"\x00" * (DIR_HDR_SIZE - 6)
    entries = bytearray()
    for g in games:
        name = g.title.encode("ascii", errors="replace")[:23]
        name = name + b"\x00" * (24 - len(name))
        entry = bytearray(DIR_ENTRY_SIZE)
        entry[0:24] = name
        entry[24]   = g.offr & 0xFF                   # DIR_OFFR
        entry[25]   = g.suboff & 0x30                 # DIR_SUBOFF (bits 4-5)
        entry[26]   = g.flags & 0xFF                  # DIR_FLAGS
        entry[27]   = min(255, g.size_blocks_32k)     # DIR_SIZE32 (informational)
        entry[28:32] = bytes(g.banks)                  # DIR_BANKS
        entries += bytes(entry)
    block = hdr + bytes(entries)
    return pad(block, BANK_SIZE)


def build_image(launcher: bytes, games, *, skip_overflow=False) -> tuple[bytes, list]:
    """Compose the full 8MB image. Returns (image_bytes, dropped_games)."""
    image = bytearray([FILL_BYTE]) * FLASH_SIZE
    if len(launcher) > LAUNCHER_SIZE:
        raise RuntimeError(f"Launcher too big: {len(launcher)} > {LAUNCHER_SIZE}")
    image[LAUNCHER_OFFSET:LAUNCHER_OFFSET + len(launcher)] = launcher
    dropped = pack_games(games, skip_overflow=skip_overflow)
    # Sort the directory entries alphabetically for the in-cart menu. The
    # physical placement (g.flash_offset) is independent of menu order.
    dir_games = sorted(games, key=lambda g: g.title.lower())
    image[DIR_OFFSET:DIR_OFFSET + BANK_SIZE] = build_directory(dir_games)
    for g in games:
        image[g.flash_offset:g.flash_offset + len(g.data)] = g.data
        # Write the SCC wrap mirror: copy game's last bank (8K) to the flash
        # position the game will hit when it writes 0x3F to bank-2 register.
        if g.needs_wrap_mirror:
            last_bank = g.data[-BANK_SIZE:]
            mirror_bank_idx = g.offr * 4 + 63
            mirror_offset = mirror_bank_idx * BANK_SIZE
            image[mirror_offset:mirror_offset + BANK_SIZE] = last_bank

    # SRAM emulation plumbing: YSRT lookup table (bank 14) + META header in
    # each game's save sector. The table is indexed by DIRECTORY position
    # (the launcher looks the game up by its menu index).
    if any(g.sram_type is not None for g in dir_games):
        table = bytearray(b"YSRT" + bytes([1]) + b"\xFF" * 3)
        for g in dir_games:
            if g.sram_type is not None:
                table += struct.pack("<HBBB", g.save_sector_bank,
                                     g.sram_type, g.sram_enbit,
                                     g.sram_slot_banks) + b"\xFF" * 3
            else:
                table += b"\xFF" * 8
        if len(table) > BANK_SIZE:
            raise RuntimeError("SRAM table overflows bank 14")
        image[SRAM_TABLE_OFFSET:SRAM_TABLE_OFFSET + len(table)] = table
        for g in dir_games:
            if g.sram_type is None:
                continue
            # META = bank 7 of the sector: "YSAV", ver, type, slot_banks.
            # Commit log (+0x10) stays erased (0xFF) = no saves yet.
            meta_off = (g.save_sector_bank + 7) * BANK_SIZE
            hdr = b"YSAV" + bytes([1, g.sram_type, g.sram_slot_banks])
            image[meta_off:meta_off + len(hdr)] = hdr
    return bytes(image), dropped


# -----------------------------------------------------------------------------
# Command-line interface
# -----------------------------------------------------------------------------
def _apply_flash_size(arg: str):
    global FLASH_SIZE
    arg = arg.upper().replace(" ", "")
    if arg in ("2MB", "2M", "2"):
        FLASH_SIZE = FLASH_SIZE_2MB
    elif arg in ("8MB", "8M", "8"):
        FLASH_SIZE = FLASH_SIZE_8MB
    else:
        raise SystemExit(f"--flash-size must be 2MB or 8MB, got {arg!r}")


def cmd_build(args):
    try:
        import tomllib
    except ImportError:
        import tomli as tomllib  # type: ignore

    _apply_flash_size(args.flash_size)
    global _scc_strategy
    _scc_strategy = args.scc_strategy

    with open(args.config, "rb") as f:
        cfg = tomllib.load(f)

    launcher_path = Path(cfg["launcher"]["file"])
    launcher_data = launcher_path.read_bytes()

    # Custom marquee: CLI --marquee overrides TOML [launcher].marquee. If neither
    # is set, the marquee is BLANKED (nothing scrolls), matching the GUI.
    marquee = args.marquee if args.marquee is not None else cfg.get("launcher", {}).get("marquee")
    launcher_data = _apply_marquee(launcher_data, marquee if marquee is not None else "")

    # Custom title: CLI --title overrides; otherwise [launcher].title from TOML.
    title = args.title if args.title else cfg.get("launcher", {}).get("title")
    launcher_data = _apply_title(launcher_data, title)

    # Menu colours: CLI --color-* overrides TOML [launcher].color_{text,bg,box}.
    lcfg = cfg.get("launcher", {})
    col_text = args.color_text if args.color_text is not None else lcfg.get("color_text")
    col_bg = args.color_bg if args.color_bg is not None else lcfg.get("color_bg")
    col_box = args.color_box if args.color_box is not None else lcfg.get("color_box")
    launcher_data = _apply_colors(launcher_data, col_text, col_bg, col_box)

    # Boot jingle: CLI --no-boot-music overrides TOML [launcher].boot_music.
    boot_music = False if args.no_boot_music else lcfg.get("boot_music")
    launcher_data = _apply_music(launcher_data, boot_music)

    config_dir = Path(args.config).resolve().parent
    games = []
    for entry in cfg.get("games", []):
        path = Path(entry["file"])
        if not path.is_absolute():
            path = config_dir / path
        data = path.read_bytes()

        mapper = entry.get("mapper")
        if mapper is None:
            # Auto-detect via openMSX softwaredb
            yama, softdb_type, title, system = detect_mapper(data)
            if yama is None:
                if softdb_type:
                    raise RuntimeError(
                        f"Game {path.name!r}: mapper {softdb_type!r} (from softdb) "
                        f"is not natively supported by Yamanooto. Use a converter "
                        f"(e.g. ascii8_to_k5.py) or specify mapper manually."
                    )
                raise RuntimeError(
                    f"Game {path.name!r}: SHA1 not in openMSX softdb and no "
                    f"explicit mapper field. Add `mapper = \"scc\"|\"k4\"|\"plain\"`."
                )
            mapper = yama
            print(f"  [auto] {path.name} -> {softdb_type} -> {mapper}", file=sys.stderr)
        games.append(Game(entry["title"], data, mapper))

    image, dropped = build_image(launcher_data, games)
    Path(args.output).write_bytes(image)
    print(f"Wrote {args.output} ({len(image)} bytes)")
    print(f"  Launcher: {len(launcher_data)} bytes at 0x000000")
    for g in games:
        print(f"  [{g.mapper:5s}] OFFR=0x{g.offr:02X} ({g.offr*32:4d}K)  SUB=0x{g.suboff:02X}  "
              f"banks={g.banks}  flags=0x{g.flags:02X}  size={len(g.data):>7} {g.title}")


def cmd_test(args):
    """Build a minimal test image (launcher + dummy games) AND self-test the
    packer: asserts the SUBOFF sub-placement against hand-computed positions.
    Dummy games have a stub 'AB' header that just DI+HALTs."""
    here = Path(__file__).resolve().parent.parent
    launcher_data = (here / "launcher" / "launcher.bin").read_bytes()

    # Build a tiny dummy game: AB header + INIT at 0x4010 = DI / HALT
    def make_dummy_game(size=0x8000):
        rom = bytearray(size)
        rom[0]   = ord('A')
        rom[1]   = ord('B')
        rom[2:4] = (0x4010).to_bytes(2, 'little')   # INIT
        rom[0x10] = 0xF3                     # DI
        rom[0x11] = 0x76                     # HALT (just freeze; user resets)
        return bytes(rom)

    g16a = Game("TEST 16K A", make_dummy_game(16 * 1024), MAPPER_PLAIN)
    g16b = Game("TEST 16K B", make_dummy_game(16 * 1024), MAPPER_PLAIN)
    g16c = Game("TEST 16K C", make_dummy_game(16 * 1024), MAPPER_PLAIN)
    g8d  = Game("TEST 8K D",  make_dummy_game(8 * 1024),  MAPPER_PLAIN)
    games = [
        Game("TEST GAME 1 (SCC)", make_dummy_game(), MAPPER_SCC),
        Game("TEST GAME 2 (K4)",  make_dummy_game(), MAPPER_K4),
        g16a, g16b, g16c, g8d,
    ]

    image, dropped = build_image(launcher_data, games)
    assert not dropped, f"dropped in self-test: {[g.title for g in dropped]}"

    # --- SUBOFF self-test (hand-computed; pool starts at OFFR 4) ------------
    # SCC dummy -> 16-aligned slot 16; K4 32KB dummy -> first free OFFR 4.
    # 16K A opens shared unit 5 (suboff 0), 16K B fills its upper half
    # (suboff 0x20), 16K C opens unit 6, 8K D takes unit 6 slot 2 (0x20).
    expected = {
        "TEST 16K A": (5, 0x00), "TEST 16K B": (5, 0x20),
        "TEST 16K C": (6, 0x00), "TEST 8K D":  (6, 0x20),
    }
    for g in (g16a, g16b, g16c, g8d):
        want = expected[g.title]
        got = (g.offr, g.suboff)
        assert got == want, f"{g.title}: placed at {got}, expected {want}"
        # The game data must live at the suboff-shifted flash offset...
        base = (g.offr * 4 + (g.suboff >> 4)) * BANK_SIZE
        assert g.flash_offset == base, (g.title, g.flash_offset, base)
        # ...and the image must actually contain its AB header there.
        assert image[base:base + 2] == b"AB", f"{g.title}: no AB at 0x{base:06X}"
    # 16KB sub-placed PLAIN keeps mirrored banks (never maps the neighbour).
    assert g16a.banks == (0, 1, 0, 1) and g8d.banks == (0, 0, 0, 0)
    print("SUBOFF self-test: 4/4 placements OK")

    out = here / "test_image.rom"
    out.write_bytes(image)
    print(f"Wrote {out} ({len(image)} bytes)")
    for g in games:
        print(f"  [{g.mapper:5s}] OFFR=0x{g.offr:02X}  SUB=0x{g.suboff:02X}  "
              f"banks={g.banks}  flags=0x{g.flags:02X}  {g.title}")
    print()
    print("Run in openMSX:")
    print(f"  openmsx -cart {out} -romtype Yamanooto")


def cmd_detect(args):
    """Identify a ROM via SHA1 against openMSX softwaredb."""
    for path in args.roms:
        data = Path(path).read_bytes()
        sha = hashlib.sha1(data).hexdigest()
        yama, softdb_type, title, system = detect_mapper(data)
        size_kb = len(data) // 1024
        if softdb_type is None:
            print(f"  ???    {sha}  {size_kb:>4}K  {path}  (unknown)")
        else:
            yama_str = yama if yama else "UNSUPPORTED"
            print(f"  {yama_str:6s} {sha}  {size_kb:>4}K  {path}")
            print(f"           softdb: {softdb_type:12s}  {title}")


def _clean_title(filename: str) -> str:
    """Strip cruft from a ROM filename to produce a short display title."""
    name = Path(filename).stem
    # Drop common suffixes: " - Konami (year) [stuff]"
    for sep in (" - Konami", " (Konami", " [", " ("):
        idx = name.find(sep)
        if idx > 0:
            name = name[:idx]
            break
    return name.strip()[:23]


# Mapping from openMSX softdb canonical title to short display name.
# Used for the in-cart menu so games show with their well-known short titles
# instead of long fully-qualified names.
SHORT_TITLES = {
    "Metal Gear 2 - Solid Snake": "Solid Snake",
    "Metal Gear 2 - Solid Snake (Demo)": "Solid Snake (Demo)",
    "Gradius - Nemesis": "Nemesis",
    "Gradius 2 - Nemesis 2": "Nemesis 2",
    "Gofer no Yabou Episode 2 - Nemesis 3 The Eve Of Destruction": "Nemesis 3",
    "Gekitotsu Pennant Race": "Pennant Race 1",
    "Gekitotsu Pennant Race 2": "Pennant Race 2",
    "The Maze of Galious - Knightmare II": "Maze of Galious",
    "Knightmare III - Shalom": "Shalom",
    "Knightmare - Majyo Densetsu": "Knightmare",
    "Knightmare Gold": "Knightmare Gold",
    "Gryzor - Contra": "Contra",
    "F1 Spirit - The Way To Formula 1": "F1 Spirit",
    "F1-Spirit - The Way To Formula 1": "F1 Spirit",
    "A1 Spirit - The Way To Formula 1": "F1 Spirit (A1)",
    "Penguin Adventure - Yumetairiku Adventure": "Penguin Adventure",
    "Vampire Killer - Akumajō Dracula": "Vampire Killer",
    "Vampire Killer - Akumajou Dracula": "Vampire Killer",
    "Firebird - Hi no Tori Hououhen": "Firebird",
    "Ganbare Goemon - Samurai": "Ganbare Goemon",
    "Hai no Majutsushi - Mahjong 2": "Mahjong 2",
    "Konami's Ping-Pong": "Ping-Pong",
    "Konami's Tennis": "Tennis",
    "Konami's Golf": "Golf",
    "Konami's Baseball": "Baseball",
    "Konami's Boxing": "Boxing",
    "Konami's Soccer": "Soccer",
    "Konami's Mahjong Dojo": "Mahjong Dojo",
    "Konami's Game Master": "Game Master",
    "Konami's Game Master 2": "Game Master 2",
    "Konami's Synthesizer": "Synthesizer",
    "King's Valley": "King's Valley",
    "King's Valley 2 - The Seal Of El Giza": "King's Valley 2",
    "King's Valley 2 - The Seal Of El Giza - Edit Contest Version": "King's Valley 2 Edit",
    "The Maze of Galious - Knightmare II": "Maze of Galious",
    "Parodius - Tako Saves Earth": "Parodius",
    "The Treasure Of Usas": "Usas",
    "The Goonies": "Goonies",
    "Computer Billiards - VideoHustler": "Video Hustler",
    "Video Hustler - Konami Billiards": "Video Hustler",
    "Hyper Olympic 1": "Hyper Olympic 1",
    "Hyper Olympic 2": "Hyper Olympic 2",
    "Hyper Olympic 3": "Hyper Olympic 3",
    "Hyper Sports 1": "Hyper Sports 1",
    "Hyper Sports 2": "Hyper Sports 2",
    "Hyper Sports 3": "Hyper Sports 3",
    "Yie Ar Kung-Fu": "Yie Ar Kung-Fu",
    "Yie Ar Kung-Fu II - The Emperor Yie-Gah": "Yie Ar Kung-Fu 2",
}


def _short_title(softdb_title: str, system: str | None = None,
                  fallback: str = "") -> str:
    """Map softdb canonical title to a short display name. Disambiguates same-title
    dumps using the MSX system version when needed (e.g. MSX1 vs MSX2)."""
    base = SHORT_TITLES.get(softdb_title)
    if base is None:
        return (fallback or softdb_title)[:23]
    return base[:23]


def _filename_mapper_hint(path: Path) -> str | None:
    """Heuristic mapper override from filename suffix for converted ROMs."""
    stem = path.stem.lower()
    if stem.endswith("_k5"):
        # Default for `_k5` is K5 mapper *without* SCC sound (typical for
        # ASCII8 conversions). Use `_scc` suffix if the converted ROM does
        # use SCC sound (then it needs 16-OFFR alignment).
        return MAPPER_K5
    if stem.endswith("_scc"):
        return MAPPER_SCC
    if stem.endswith("_k4"):
        return MAPPER_K4
    if stem.endswith("_ascii16k5") or stem.endswith("_a16k5"):
        return MAPPER_ASCII16_K5
    if stem.endswith("_plain") or stem.endswith("_mirrored"):
        return MAPPER_PLAIN
    return None


def cmd_pack_folder(args):
    """Build an image directly from a folder of ROMs, auto-detecting everything.
    Unsupported ROMs are skipped with a warning. If both the original ASCII8
    ROM and its `_k5.rom` converted counterpart exist, only the converted one
    is included."""
    _apply_flash_size(args.flash_size)
    global _scc_strategy
    _scc_strategy = args.scc_strategy
    folder = Path(args.folder)
    launcher_path = Path(args.launcher) if args.launcher else (
        Path(__file__).resolve().parent.parent / "launcher" / "launcher.bin")
    launcher_data = launcher_path.read_bytes()
    launcher_data = _apply_marquee(launcher_data, args.marquee if args.marquee is not None else "")
    launcher_data = _apply_title(launcher_data, args.title)
    launcher_data = _apply_colors(launcher_data, args.color_text, args.color_bg, args.color_box)
    launcher_data = _apply_music(launcher_data, False if args.no_boot_music else None)

    rom_paths = sorted(folder.glob("*.rom")) + sorted(folder.glob("*.ROM"))

    # If both `foo.rom` (ASCII8) and `foo_k5.rom` exist, drop the original.
    converted_stems = {p.stem[:-3] for p in rom_paths
                       if p.stem.lower().endswith(("_k5", "_k4", "_scc"))}
    rom_paths = [p for p in rom_paths if p.stem not in converted_stems]

    games = []
    skipped = []
    seen_titles = {}   # short_title -> list of (game_index, system)
    for path in rom_paths:
        data = path.read_bytes()
        yama, softdb_type, sdb_title, system = detect_mapper(data)
        # Auto-convert ASCII8 / ASCII16 in memory if user opted in.
        if yama is None and args.auto_convert and softdb_type in ("ASCII8", "ASCII16"):
            if softdb_type == "ASCII8":
                import ascii8_to_k5
                data, patches_list = ascii8_to_k5.convert(data)
                n_patches = len(patches_list)
                if n_patches > 0:
                    print(f"  [conv] ASCII8 -> K5 ({n_patches} patches): {path.name}")
                    yama = MAPPER_K5
                else:
                    print(f"  [skip] ASCII8 with no patchable bank writes: {path.name}")
                    skipped.append((path, softdb_type))
                    continue
            else:  # ASCII16
                import ascii16_to_k5
                data, seg0, seg1 = ascii16_to_k5.convert(data)
                if (seg0 + seg1) > 0:
                    print(f"  [conv] ASCII16 -> K5 ({seg0}+{seg1} patches): {path.name}")
                    yama = MAPPER_ASCII16_K5
                else:
                    print(f"  [skip] ASCII16 with no patchable bank writes: {path.name}")
                    skipped.append((path, softdb_type))
                    continue
        if yama is None:
            hint = _filename_mapper_hint(path)
            if hint:
                display = _clean_title(path.name)
                games.append(Game(display, data, hint))
                print(f"  [+] {hint:6s} {display:24s}  (filename hint)")
                continue
            skipped.append((path, softdb_type or "unknown"))
            continue
        display = _short_title(sdb_title, fallback=_clean_title(path.name))
        # Disambiguate duplicate titles by appending the MSX system.
        if display in seen_titles:
            # Retitle this entry with the system suffix.
            new_display = f"{display[:18]} {system}"
            # Also retitle the FIRST entry if not yet disambiguated.
            first_idx, first_sys = seen_titles[display][0]
            if not games[first_idx].title.endswith(f" {first_sys}"):
                games[first_idx].title = f"{display[:18]} {first_sys}"
            display = new_display
        seen_titles.setdefault(display, []).append((len(games), system))
        games.append(Game(display, data, yama))
        print(f"  [+] {yama:6s} {display:24s}  ({softdb_type})")

    if skipped:
        print()
        print("Skipped (mapper unsupported; convert manually first):")
        for path, typ in skipped:
            print(f"  [-] {typ:12s}  {path.name}")
            if typ == "ASCII8":
                k5_name = path.stem + "_k5.rom"
                print(f"          -> run: ascii8_to_k5.py \"{path}\" "
                      f"\"{path.parent / k5_name}\" then re-run pack-folder "
                      f"(or move the original out of the folder).")

    if not games:
        print("No supported ROMs found.", file=sys.stderr)
        sys.exit(1)

    # Sort: bigger games first so they place in the available space; small
    # games (16K Mirrored) easily fit in remaining gaps.
    games.sort(key=lambda g: -len(g.data))

    image, dropped = build_image(launcher_data, games, skip_overflow=True)
    Path(args.output).write_bytes(image)
    print()
    print(f"Wrote {args.output} ({len(image)} bytes, {len(games)} games placed)")
    used_kb = sum(round_up_to_32k(len(g.data)) for g in games) // 1024
    print(f"  Flash used by games: {used_kb} KB / {(FLASH_SIZE - GAMES_POOL_START) // 1024} KB available")
    if dropped:
        print()
        print(f"Dropped (no space): {len(dropped)} games")
        for g in dropped:
            print(f"  [-] {g.mapper:6s} {len(g.data)//1024:>4}K  {g.title}")
        print()
        print("Tip: remove unused .rom files from the folder, or pack a subset via TOML.")


def main():
    p = argparse.ArgumentParser(prog="yamanooto_pack")
    sub = p.add_subparsers(dest="cmd")

    pb = sub.add_parser("build", help="Build full image from TOML config")
    pb.add_argument("config")
    pb.add_argument("-o", "--output", default="yamanooto.rom")
    pb.add_argument("--flash-size", choices=("2MB", "8MB"), default="8MB",
                    help="Target Yamanooto flash size. 8MB is the standard model; "
                         "2MB exists for some early units. Default: 8MB.")
    pb.add_argument("--scc-strategy", choices=("auto", "patch", "mirror", "none"),
                    default="auto",
                    help="How to handle <512K SCC games: auto (patch then mirror), "
                         "patch (require patch, error if none), mirror (always mirror 4x), "
                         "none (no SCC fix, music may break). Default: auto.")
    pb.add_argument("--marquee", default=None,
                    help="Custom text for the scrolling marquee (max 64 chars, uppercased). "
                         "Replaces the default repo-URL portion; the anti-scam notice "
                         "before it is always shown. Can also be set via [launcher].marquee "
                         "in the TOML.")
    pb.add_argument("--title", default=None,
                    help="Custom menu title (max 31 chars, uppercased). Also settable via "
                         "[launcher].title in the TOML. The red title box auto-fits.")
    pb.add_argument("--color-text", type=_parse_color, default=None, metavar="COLOR",
                    help="Menu text colour: MSX palette index 1-15 or a name (e.g. white, "
                         "cyan, light-yellow). Also [launcher].color_text in the TOML.")
    pb.add_argument("--color-bg", type=_parse_color, default=None, metavar="COLOR",
                    help="Menu background colour (1-15 or name). Also [launcher].color_bg.")
    pb.add_argument("--color-box", type=_parse_color, default=None, metavar="COLOR",
                    help="Title-box colour (1-15 or name). Also [launcher].color_box.")
    pb.add_argument("--no-boot-music", action="store_true",
                    help="Silence the boot jingle (also [launcher].boot_music = false "
                         "in the TOML). Default: jingle plays.")
    pb.set_defaults(func=cmd_build)

    pt = sub.add_parser("test", help="Build minimal test image with dummy entries")
    pt.set_defaults(func=cmd_test)

    pd = sub.add_parser("detect", help="Detect mapper of one or more ROMs via SHA1")
    pd.add_argument("roms", nargs="+", help="Paths to .rom files")
    pd.set_defaults(func=cmd_detect)

    pf = sub.add_parser("pack-folder",
                        help="Build image from every .rom in a folder, auto-detecting mappers")
    pf.add_argument("folder", help="Folder containing .rom files")
    pf.add_argument("-o", "--output", default="yamanooto.rom")
    pf.add_argument("--launcher", help="Path to launcher.bin (defaults to launcher/launcher.bin)")
    pf.add_argument("--flash-size", choices=("2MB", "8MB"), default="8MB",
                    help="Target Yamanooto flash size. 8MB is the standard model; "
                         "2MB exists for some early units. Default: 8MB.")
    pf.add_argument("--scc-strategy", choices=("auto", "patch", "mirror", "none"),
                    default="auto",
                    help="How to handle <512K SCC games. Default: auto (patch first, "
                         "fall back to mirror per-game).")
    pf.add_argument("--auto-convert", action="store_true",
                    help="Automatically convert ASCII8 / ASCII16 ROMs in memory "
                         "(equivalent to running ascii8_to_k5.py / ascii16_to_k5.py).")
    pf.add_argument("--marquee", default=None,
                    help="Custom text for the scrolling marquee (max 64 chars, uppercased). "
                         "Replaces the default repo-URL portion; the anti-scam notice "
                         "before it is always shown.")
    pf.add_argument("--title", default=None,
                    help="Custom menu title (max 31 chars, uppercased). The red title "
                         "box auto-fits.")
    pf.add_argument("--color-text", type=_parse_color, default=None, metavar="COLOR",
                    help="Menu text colour: MSX palette index 1-15 or a name (e.g. white, "
                         "cyan, light-yellow).")
    pf.add_argument("--color-bg", type=_parse_color, default=None, metavar="COLOR",
                    help="Menu background colour (1-15 or name).")
    pf.add_argument("--color-box", type=_parse_color, default=None, metavar="COLOR",
                    help="Title-box colour (1-15 or name).")
    pf.add_argument("--no-boot-music", action="store_true",
                    help="Silence the boot jingle. Default: jingle plays.")
    pf.set_defaults(func=cmd_pack_folder)

    args = p.parse_args()
    if not args.cmd:
        p.print_help()
        sys.exit(1)
    args.func(args)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
gm2_to_yamanooto.py — Convert Konami's Game Master 2 for the Yamanooto
SRAM-emulation helper (GameMaster2 variant).

GM2's mapper writes go to 0x6000-0x6FFF / 0x8000-0x8FFF / 0xA000-0xAFFF with
address bit 12 clear. Every `LD (nn),A` (opcode 0x32) hitting those windows is
rewritten into a CALL to the resident helper entry for that region:

  0x6xxx (region 1, 0x6000-0x7FFF)  -> CALL 0xF033
  0x8xxx (region 2, 0x8000-0x9FFF)  -> CALL 0xF036
  0xAxxx (region 3, 0xA000-0xBFFF)  -> CALL 0xF039

The bank value stays in A: bit4 = SRAM select, bit5 = SRAM page, bits 0-3 =
8KB ROM bank. The launcher installs the GM2 helper variant when the directory
entry has FLAG_SRAM and the SRAM table types the game as GM2 (type 1).

Known dumps (expected patch counts r1/r2/r3):
  fe74b4df9698a61dffd3ac88f47619675514ba1c  (GameMaster2)         4/20/50
A count mismatch on a known dump aborts; unknown dumps only warn.

Usage:
  gm2_to_yamanooto.py in.rom out.rom
"""

import sys
from pathlib import Path

SRAM_HELPER_BASE = 0xF030   # must match SRAM_HELPER_DST in launcher.asm

KNOWN_COUNTS = {
    "fe74b4df9698a61dffd3ac88f47619675514ba1c": (4, 20, 50),
}


def convert(rom: bytes) -> tuple[bytes, list]:
    """Patch every GM2 bank-register write into a helper CALL.
    Returns (patched_rom, patches) with patches = [(offset, old_nn, region)]."""
    out = bytearray(rom)
    patches = []
    i = 0
    while i < len(out) - 2:
        if out[i] == 0x32:                      # LD (nn), A
            hi = out[i + 2]
            if (hi & 0x10) == 0:                # GM2 regs need bit12 clear
                region = None
                if 0x60 <= hi <= 0x6F:
                    region = 1
                elif 0x80 <= hi <= 0x8F:
                    region = 2
                elif 0xA0 <= hi <= 0xAF:
                    region = 3
                if region is not None:
                    target = SRAM_HELPER_BASE + 3 * region
                    old_nn = (hi << 8) | out[i + 1]
                    out[i] = 0xCD               # CALL nn
                    out[i + 1] = target & 0xFF
                    out[i + 2] = target >> 8
                    patches.append((i, old_nn, region))
        i += 1
    return bytes(out), patches


def check_counts(rom: bytes, patches: list) -> None:
    import hashlib
    sha = hashlib.sha1(rom).hexdigest()
    counts = [0, 0, 0, 0]
    for _, _, r in patches:
        counts[r] += 1
    got = (counts[1], counts[2], counts[3])
    if sha in KNOWN_COUNTS:
        if got != KNOWN_COUNTS[sha]:
            raise RuntimeError(
                f"GM2 dump {sha[:12]}: patch counts {got} != expected "
                f"{KNOWN_COUNTS[sha]} — converter or dump mismatch")
    else:
        print(f"[gm2] unknown dump {sha[:12]}: patched r1/r2/r3 = {got} "
              f"(no reference counts, verify in-game)", file=sys.stderr)


def main():
    if len(sys.argv) != 3:
        print("Usage: gm2_to_yamanooto.py in.rom out.rom", file=sys.stderr)
        sys.exit(1)
    src = Path(sys.argv[1]).read_bytes()
    dst, patches = convert(src)
    check_counts(src, patches)
    Path(sys.argv[2]).write_bytes(dst)
    print(f"Patched {len(patches)} GM2 bank-register writes into helper CALLs")
    print("Pack with `mapper = \"gm2\"`.")


if __name__ == "__main__":
    main()

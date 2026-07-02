#!/usr/bin/env python3
"""
ascii8sram_to_k5.py — Convert an ASCII8+SRAM MSX ROM for the Yamanooto
SRAM-emulation helper.

Unlike the plain ASCII8 converter (which rewrites the bank-switch address in
place), SRAM games need EVERY bank-register write routed through the resident
helper so it can track mapper state, detect the SRAM-enable bit, flip page 2
to system RAM and flush saves to flash. So each

    LD (nn), A          ; 32 lo hi, nn in an ASCII8 register window

becomes

    CALL 0xF030 + 3*region

with the bank value still in A. The launcher installs the helper (launcher.asm
sram_a8_src) at 0xF030 when the directory entry has FLAG_SRAM (0x20).

ASCII8 register windows (2KB each):
  0x6000-0x67FF  region 0 (0x4000-0x5FFF)   -> CALL 0xF030
  0x6800-0x6FFF  region 1 (0x6000-0x7FFF)   -> CALL 0xF033
  0x7000-0x77FF  region 2 (0x8000-0x9FFF)   -> CALL 0xF036
  0x7800-0x7FFF  region 3 (0xA000-0xBFFF)   -> CALL 0xF039

The SRAM-enable bit is NOT constant for ASCII8 carts: openMSX's RomAscii8_8
derives it as rom_size / 8KB (number of 8KB banks; e.g. 128K -> 0x10,
256K -> 0x20). The packager stores it in the SRAM table for the launcher.

Limitations (same class as the other converters):
- Only the `LD (nn),A` pattern (opcode 0x32) is caught. Bank switching via
  LD HL,addr / LD (HL),A is not detected.
- A stray 0x32 in data whose "address" lands in a register window gets
  patched too (false positive). The helper degrades gracefully for impossible
  values, but the 3 bytes are still rewritten. Audit per game if it breaks.

Usage:
  ascii8sram_to_k5.py in.rom out.rom
"""

import sys
from pathlib import Path

SRAM_HELPER_BASE = 0xF030   # must match SRAM_HELPER_DST in launcher.asm


def enable_bit(rom_size: int) -> int:
    """SRAM-enable bit for an ASCII8+SRAM cart: number of 8KB banks,
    rounded up to a power of two, minimum 0x10 (openMSX RomAscii8_8)."""
    nbanks = max(1, (rom_size + 0x1FFF) // 0x2000)
    bit = 1
    while bit < nbanks:
        bit <<= 1
    return max(bit, 0x10)


def convert(rom: bytes) -> tuple[bytes, list]:
    """Patch every ASCII8 bank-register write into a helper CALL.
    Returns (patched_rom, patches) where patches = [(offset, old_nn, region)]."""
    out = bytearray(rom)
    patches = []
    i = 0
    while i < len(out) - 2:
        if out[i] == 0x32:                  # LD (nn), A
            lo = out[i + 1]
            hi = out[i + 2]
            if 0x60 <= hi < 0x80:           # 0x6000-0x7FFF register area
                region = (hi - 0x60) >> 3   # 2KB windows -> 0..3
                target = SRAM_HELPER_BASE + 3 * region
                old_nn = (hi << 8) | lo
                out[i] = 0xCD               # CALL nn
                out[i + 1] = target & 0xFF
                out[i + 2] = target >> 8
                patches.append((i, old_nn, region))
        i += 1
    return bytes(out), patches


def main():
    if len(sys.argv) != 3:
        print("Usage: ascii8sram_to_k5.py in.rom out.rom", file=sys.stderr)
        sys.exit(1)
    src = Path(sys.argv[1]).read_bytes()
    dst, patches = convert(src)
    Path(sys.argv[2]).write_bytes(dst)
    counts = [0, 0, 0, 0]
    for _, _, region in patches:
        counts[region] += 1
    print(f"Patched {len(patches)} bank-register writes into helper CALLs "
          f"(r0={counts[0]} r1={counts[1]} r2={counts[2]} r3={counts[3]})")
    print(f"SRAM enable bit for this ROM size: 0x{enable_bit(len(src)):02X}")
    print("Pack with `mapper = \"ascii8_sram\"` so the launcher installs the "
          "helper and reserves the save sector.")


if __name__ == "__main__":
    main()

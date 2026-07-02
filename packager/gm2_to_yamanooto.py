#!/usr/bin/env python3
"""
gm2_to_yamanooto.py — bespoke Yamanooto patch for Konami's Game Master 2.

GM2 is a RESIDENT cartridge: it owns high RAM (0xF0xx-0xF3xx) and uses the
RAM under page 2 as its workspace, which makes it incompatible with the
generic SRAM helper. Instead, this converter patches GM2 itself:

- ROM banking runs NATIVELY in the Yamanooto's K4 mode (GM2's registers
  0x6000/0x8000/0xA000 are Konami4's). No CALL rewriting, no resident code.
- All SRAM traffic flows through GM2's own "SRAM disk" driver (ROM bank 4,
  0x8000-0x8679, entered only via the trampoline at ROM 0x0020). We patch:
    1. The trampoline: instead of enabling cart SRAM, it maps bank 4 into the
       0x6000 window and calls our stage-1 (ROM 0x8680 = CPU 0x6680).
    2. Stage 1 switches page 2 to the system RAM slot (GM2 keeps its RAM slot
       id at 0xF2A0), copies the whole patched bank 4 to RAM 0x8000-0x9FFF
       and jumps to stage 2 in that copy.
    3. Stage 2 (ROM 0x8700+, runs in RAM): loads an 8KB SRAM shadow from the
       save flash bank (relative bank 0x10, right after the 128KB ROM), calls
       the driver (which now reads/writes the shadow), and for write-class
       functions flushes the shadow back to flash (AMD sector erase + program,
       possible because the code runs from RAM).
    4. Driver patches: every `LD (0xA000),A` page-select/enable is NOPped
       (page 2 is RAM during the driver — those writes would corrupt the
       shadow); the two computed data-pointer bases (`LD DE,0xB000` at ROM
       0x840E and 0x854D) become CALL 0x8700 (fix: page 0 -> 0xB000, page 1 ->
       0xA000, the mirror the driver never touches — so the 2x4KB SRAM lives
       linearly in the shadow); FORMAT's two-page clear becomes one linear
       8KB clear.

Verified against dump SHA1 fe74b4df9698a61dffd3ac88f47619675514ba1c
(GameMaster2 type in the openMSX softdb). Other dumps: patched with warnings.

Usage:
  gm2_to_yamanooto.py in.rom out.rom
(needs launcher/gm2_part1.bin and gm2_part2.bin, built from the .asm sources)
"""

import sys
from pathlib import Path

KNOWN_SHA1 = "fe74b4df9698a61dffd3ac88f47619675514ba1c"

BANK4 = 0x8000                # ROM offset of the driver bank
BANK4_CODE_END = 0x8680       # driver code ends 0x8679; blob starts 0x8680
BLOB1_OFF = 0x8680            # stage 1 (CPU 0x6680 via the 0x6000 window)
BLOB2_OFF = 0x8700            # fix2 + stage 2 (CPU 0x8700 in the RAM copy)

# trampoline patch @ROM 0x002E (16 bytes, replaces bank4@0x8000 + SRAM-enable
# + CALL 0x8000):  bank4@window / pop bc,de / push de / CALL 0x6680 /
# EX AF,AF' (recovers driver status stashed by stage 2) / 4x NOP
TRAMP_OFF = 0x002E
TRAMP_OLD = bytes.fromhex("3e 04 32 00 80 3e 10 32 00 a0 c1 d1 d5 cd 00 80".replace(" ", ""))
TRAMP_NEW = bytes.fromhex("3e 04 32 00 60 c1 d1 d5 cd 80 66 08 00 00 00 00".replace(" ", ""))

# the two computed page-select data-pointer bases -> CALL 0x8700 (fix2)
PTR_SITES = (0x840E, 0x854D)  # both: 11 00 B0 (LD DE,0xB000)

# FORMAT clear rewrite @0x84C1: one linear 8KB clear of the shadow
FMT_OFF = 0x84C1
FMT_OLD = bytes.fromhex("3e 10 cd c8 84 3e 30 32 00 a0 21 00 b0 11 01 b0".replace(" ", ""))
FMT_NEW = bytes.fromhex("21 00 a0 11 01 a0 01 ff 1f 36 00 ed b0 c9 ff ff".replace(" ", ""))
# note: FMT_NEW ends the routine at its RET; trailing old bytes (LDIR tail of
# the original, unreachable) are replaced by 0xFF filler up to 0x84D1, and the
# original 01 FF 0F / 36 00 / ED B0 / C9 at 0x84D1-0x84D8 stay but are dead.


def convert(rom: bytes, part1: bytes, part2: bytes) -> tuple[bytes, dict]:
    if len(rom) != 128 * 1024:
        raise RuntimeError(f"GM2 ROM must be 128KB, got {len(rom)}")
    out = bytearray(rom)
    stats = {}

    # --- 1. trampoline ---
    if bytes(out[TRAMP_OFF:TRAMP_OFF + 16]) != TRAMP_OLD:
        raise RuntimeError("trampoline bytes at 0x002E don't match — wrong dump?")
    out[TRAMP_OFF:TRAMP_OFF + 16] = TRAMP_NEW
    stats["trampoline"] = 1

    # --- 2. NOP every LD (0xA000),A store inside the driver bank code ---
    n = 0
    i = BANK4
    while i < BANK4 + 0x679:
        if out[i] == 0x32 and out[i + 1] == 0x00 and out[i + 2] == 0xA0:
            out[i:i + 3] = b"\x00\x00\x00"
            n += 1
            i += 3
        else:
            i += 1
    stats["enables_nopped"] = n

    # --- 3. data-pointer bases -> CALL fix2 (0x8700) ---
    for off in PTR_SITES:
        if bytes(out[off:off + 3]) != b"\x11\x00\xB0":
            raise RuntimeError(f"expected LD DE,0xB000 at 0x{off:04X}")
        out[off:off + 3] = b"\xCD\x00\x87"
    stats["ptr_fixes"] = len(PTR_SITES)

    # --- 4. FORMAT clear rewrite (enables inside already NOPped by step 2;
    #        re-check the region against the post-step-2 expectation) ---
    expect = bytearray(FMT_OLD)
    expect[7:10] = b"\x00\x00\x00"          # step 2 NOPped the 32 00 A0
    if bytes(out[FMT_OFF:FMT_OFF + 16]) != bytes(expect):
        raise RuntimeError("FORMAT region at 0x84C1 doesn't match — wrong dump?")
    out[FMT_OFF:FMT_OFF + 16] = FMT_NEW
    stats["format_rewrite"] = 1

    # --- 5. embed the blob in bank 4 free space ---
    if any(b != 0xFF for b in out[BLOB1_OFF:BLOB1_OFF + len(part1)]):
        raise RuntimeError("bank-4 free space at 0x8680 is not empty")
    if any(b != 0xFF for b in out[BLOB2_OFF:BLOB2_OFF + len(part2)]):
        raise RuntimeError("bank-4 free space at 0x8700 is not empty")
    if BLOB1_OFF + len(part1) > BLOB2_OFF:
        raise RuntimeError("stage 1 blob overlaps stage 2")
    out[BLOB1_OFF:BLOB1_OFF + len(part1)] = part1
    out[BLOB2_OFF:BLOB2_OFF + len(part2)] = part2
    stats["blob"] = len(part1) + len(part2)

    return bytes(out), stats


def load_blobs(base: Path) -> tuple[bytes, bytes]:
    p1 = (base / "gm2_part1.bin").read_bytes()
    p2 = (base / "gm2_part2.bin").read_bytes()
    return p1, p2


def main():
    if len(sys.argv) != 3:
        print("Usage: gm2_to_yamanooto.py in.rom out.rom", file=sys.stderr)
        sys.exit(1)
    import hashlib
    src = Path(sys.argv[1]).read_bytes()
    sha = hashlib.sha1(src).hexdigest()
    if sha != KNOWN_SHA1:
        print(f"[gm2] WARNING: dump {sha[:12]} is not the verified one "
              f"({KNOWN_SHA1[:12]}); byte checks may abort.", file=sys.stderr)
    here = Path(__file__).resolve().parent.parent / "launcher"
    part1, part2 = load_blobs(here)
    dst, stats = convert(src, part1, part2)
    Path(sys.argv[2]).write_bytes(dst)
    print(f"GM2 bespoke patch applied: {stats}")
    print("Pack with `mapper = \"gm2\"` (runs in native K4 mode; save image at "
          "relative flash bank 0x10).")


if __name__ == "__main__":
    main()

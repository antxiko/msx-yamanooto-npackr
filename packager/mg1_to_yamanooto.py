#!/usr/bin/env python3
"""Patch Metal Gear 1 (RC750, 128KB Konami-4) so its cassette saves go to
Yamanooto flash.

Redirects the 20 `call TAP*` sites in the game's saveload code (bank 0x0F) to
six stubs written into that bank's free 0xFF tail (mg1_shim.bin at ROM
0x1FFA7), and appends the 8KB virtual-tape driver (mg1_driver.bin) as
game-relative bank 0x10. Pack the result with `mapper = "mg1"`: the packer
reserves a 256KB footprint whose 64KB save sector sits at relative bank 0x18.

Design + verified intercept table: docs/MG1_SAVES.md. The offsets were
assembly-verified against the GuillianSeed disassembly (CRC32 E85C5731) and
byte-verified against a fan-translation dump (CRC32 5F3BB2F1) — this script
validates the ORIGINAL 3 bytes at every site and refuses on any mismatch, so
it can never corrupt an unknown dump.

Usage:
    python packager/mg1_to_yamanooto.py "Metal Gear.rom" mg1_yama.rom
"""
import sys
import zlib
from pathlib import Path

ROM_SIZE = 0x20000
SHIM_OFFSET = 0x1FFA7          # bank F free tail (CPU 0xBFA7), 89 bytes of 0xFF
SHIM_MAX = 0x20000 - SHIM_OFFSET
STUB_BASE = 0xBFA7             # CPU address of stub 0; stubs are 5 bytes each
STUB_STRIDE = 5

# BIOS vector -> stub function id (order must match mg1_shim.asm / mg1_driver.asm)
FN_ID = {0x00E1: 0, 0x00E4: 1, 0x00E7: 2, 0x00EA: 3, 0x00ED: 4, 0x00F0: 5}
BIOS_NAME = {0x00E1: "TAPION", 0x00E4: "TAPIN", 0x00E7: "TAPIOF",
             0x00EA: "TAPOON", 0x00ED: "TAPOUT", 0x00F0: "TAPOOF"}

# (routine, bios vector, ROM offset of the `call` opcode) — docs/MG1_SAVES.md
SITES = [
    ("SaveFilename",   0x00EA, 0x1F985), ("SaveFilename2", 0x00ED, 0x1F98D),
    ("SaveFilename3",  0x00ED, 0x1F99D), ("SaveError",     0x00F0, 0x1F9A9),
    ("SaveGameData",   0x00EA, 0x1F9C0), ("SaveGameData2", 0x00ED, 0x1F9CE),
    ("SaveGameDataT",  0x00ED, 0x1F9DE), ("SaveGameDataF", 0x00F0, 0x1F9E3),
    ("SaveVerify2",    0x00E4, 0x1FA39), ("SaveVerifyT",   0x00E4, 0x1FA49),
    ("SaveVerify",     0x00E7, 0x1FA55), ("LoadData2",     0x00E4, 0x1FB16),
    ("LoadDataT",      0x00E4, 0x1FB24), ("LoadData",      0x00E7, 0x1FB2C),
    ("TapeError",      0x00E7, 0x1FB47), ("SearchFile",    0x00E1, 0x1FB9A),
    ("SearchFile2",    0x00E4, 0x1FBA2), ("SearchFile3",   0x00E4, 0x1FBB5),
    ("SearchFile4",    0x00E1, 0x1FBD7), ("PrintSkipName", 0x00E1, 0x1FBDE),
]


def patch(rom: bytes, shim: bytes, driver: bytes) -> bytes:
    if len(rom) != ROM_SIZE:
        raise SystemExit(f"ROM must be {ROM_SIZE} bytes (128KB), got {len(rom)}")
    if len(shim) > SHIM_MAX:
        raise SystemExit(f"shim too big: {len(shim)} > {SHIM_MAX}")
    if len(driver) != 0x2000:
        raise SystemExit(f"driver must be 8192 bytes, got {len(driver)}")

    # The shim area must be pristine 0xFF filler.
    tail = rom[SHIM_OFFSET:ROM_SIZE]
    if set(tail) != {0xFF}:
        raise SystemExit("bank F free tail is not 0xFF filler — unknown dump, refusing")

    data = bytearray(rom)
    patched = 0
    for name, bios, off in SITES:
        want = bytes([0xCD, bios & 0xFF, bios >> 8])
        got = bytes(data[off:off + 3])
        if got != want:
            raise SystemExit(
                f"{name} @0x{off:05X}: expected {want.hex()} (call {BIOS_NAME[bios]}), "
                f"found {got.hex()} — unknown dump, refusing (nothing written)")
        stub = STUB_BASE + FN_ID[bios] * STUB_STRIDE
        data[off + 1] = stub & 0xFF
        data[off + 2] = stub >> 8
        patched += 1

    data[SHIM_OFFSET:SHIM_OFFSET + len(shim)] = shim
    return bytes(data) + driver


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    rom_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
    here = Path(__file__).resolve().parent.parent / "launcher"
    rom = rom_path.read_bytes()
    shim = (here / "mg1_shim.bin").read_bytes()
    driver = (here / "mg1_driver.bin").read_bytes()

    print(f"input : {rom_path.name}  CRC32={zlib.crc32(rom):08X}")
    out = patch(rom, shim, driver)
    out_path.write_bytes(out)
    print(f"output: {out_path} ({len(out)} bytes = 128KB game + 8KB driver)")
    print(f"  {len(SITES)} tape calls -> stubs @0x{STUB_BASE:04X}, shim {len(shim)}B "
          f"@ROM 0x{SHIM_OFFSET:05X}, driver = relative bank 0x10")
    print('Pack with mapper = "mg1" (256KB footprint, save sector at rel bank 0x18).')


if __name__ == "__main__":
    main()

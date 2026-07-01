#!/usr/bin/env python3
"""font_to_bin.py — convert a 6x8 (in 8x8 cell) font sheet PNG into a raw
512-byte font table for the Yamanooto SCREEN 2 launcher.

Sheet layout: 16 columns x 4 rows = 64 glyphs, each in an 8x8 pixel cell,
covering ASCII 0x20..0x5F in reading order (glyph 0 = space = 0x20).

Output: 512 bytes = 64 glyphs x 8 rows. Each byte is one 8-pixel row,
bit 7 = leftmost pixel, 1 = ink. The 6px-wide glyph sits in the top bits
(bits 7..2 typically), leaving the 2px advance gap as 0 — so the same table
works both cell-aligned (8px advance) and proportional (6px advance, shifted).

No PIL required: falls back to `sips` (macOS) to transcode PNG -> BMP, then
parses the BMP by hand. Ink is auto-detected as the minority luminance class,
so a white-on-black or black-on-white sheet both work.
"""
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

CELL = 8            # pixel cell pitch (glyph is 6 wide inside it)
COLS, ROWS = 16, 4  # grid of glyphs
NGLYPH = COLS * ROWS


def load_rgb(png_path: Path):
    """Return (width, height, pixels) where pixels[y][x] = (r, g, b)."""
    try:
        from PIL import Image  # type: ignore
        im = Image.open(png_path).convert("RGB")
        w, h = im.size
        px = list(im.getdata())
        return w, h, [px[y * w:(y + 1) * w] for y in range(h)]
    except Exception:
        pass
    try:
        return _decode_png(png_path.read_bytes())
    except Exception as e:
        # Last resort: sips emits headerless raw RGB (w*h*3) for "bmp".
        with tempfile.TemporaryDirectory() as td:
            raw = Path(td) / "f.raw"
            subprocess.run(["sips", "-s", "format", "bmp", str(png_path),
                            "--out", str(raw)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            b = raw.read_bytes()
            raise RuntimeError(f"native PNG decode failed ({e}); sips raw "
                               f"is {len(b)} bytes, needs known w/h to parse")


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _decode_png(b: bytes):
    """Minimal non-interlaced PNG decoder. Handles grayscale/rgb/palette/alpha
    at bit depths 1/2/4/8. Returns (w, h, rows[y][x] = (r, g, b))."""
    if b[:8] != bytes([137, 80, 78, 71, 13, 10, 26, 10]):
        raise ValueError("not a PNG")
    i = 8
    width = height = depth = ctype = None
    plte = b""
    idat = bytearray()
    while i < len(b):
        ln = struct.unpack_from(">I", b, i)[0]
        typ = b[i + 4:i + 8]
        data = b[i + 8:i + 8 + ln]
        if typ == b"IHDR":
            width, height, depth, ctype, comp, filt, interlace = \
                struct.unpack(">IIBBBBB", data)
            if interlace:
                raise ValueError("interlaced PNG unsupported")
        elif typ == b"PLTE":
            plte = data
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            break
        i += 12 + ln

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    bits_pp = depth * channels
    bppf = max(1, bits_pp // 8)           # filter unit in bytes
    row_bytes = (bits_pp * width + 7) // 8
    raw = zlib.decompress(bytes(idat))

    # Unfilter scanlines.
    recon = []
    prev = bytearray(row_bytes)
    pos = 0
    for _ in range(height):
        ftype = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos + row_bytes]); pos += row_bytes
        for x in range(row_bytes):
            a = line[x - bppf] if x >= bppf else 0
            u = prev[x]
            c = prev[x - bppf] if x >= bppf else 0
            if ftype == 0:   v = line[x]
            elif ftype == 1: v = line[x] + a
            elif ftype == 2: v = line[x] + u
            elif ftype == 3: v = line[x] + (a + u) // 2
            elif ftype == 4: v = line[x] + _paeth(a, u, c)
            else: raise ValueError(f"bad filter {ftype}")
            line[x] = v & 0xFF
        recon.append(line)
        prev = line

    # Expand pixels -> (r,g,b).
    def samples(line):
        if depth == 8:
            return list(line)
        out = []
        for byte in line:
            if depth == 4:
                out += [(byte >> 4) & 0xF, byte & 0xF]
            elif depth == 2:
                out += [(byte >> s) & 0x3 for s in (6, 4, 2, 0)]
            elif depth == 1:
                out += [(byte >> s) & 0x1 for s in range(7, -1, -1)]
        return out

    rows = []
    for line in recon:
        s = samples(line)
        row = []
        for x in range(width):
            if ctype == 3:                       # palette index -> PLTE
                idx = s[x]
                row.append((plte[idx*3], plte[idx*3+1], plte[idx*3+2]))
            elif ctype in (0, 4):                # gray (+alpha)
                g = s[x * channels]
                if depth < 8:
                    g = g * 255 // ((1 << depth) - 1)
                row.append((g, g, g))
            else:                                # rgb / rgba
                o = x * channels
                row.append((s[o], s[o + 1], s[o + 2]))
        rows.append(row)
    return width, height, rows


def lum(px):
    r, g, b = px
    return (299 * r + 587 * g + 114 * b) // 1000


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path(__file__).resolve().parent.parent / "launcher" / "font6x8.png"
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else \
        src.with_suffix(".bin")

    w, h, rows = load_rgb(src)
    if w < COLS * CELL or h < ROWS * CELL:
        raise SystemExit(f"font sheet {w}x{h} too small for {COLS*CELL}x{ROWS*CELL}")

    # Auto-detect ink = minority luminance class (threshold at mid-gray).
    dark = sum(1 for line in rows for p in line if lum(p) < 128)
    light = w * h - dark
    ink_is_dark = dark < light

    def is_ink(x, y):
        d = lum(rows[y][x]) < 128
        return d if ink_is_dark else (not d)

    out = bytearray()
    for gy in range(ROWS):
        for gx in range(COLS):
            x0, y0 = gx * CELL, gy * CELL
            for r in range(8):
                byte = 0
                for c in range(8):
                    if is_ink(x0 + c, y0 + r):
                        byte |= 1 << (7 - c)
                out.append(byte)

    dst.write_bytes(bytes(out))
    print(f"wrote {dst} ({len(out)} bytes), ink={'dark' if ink_is_dark else 'light'}")

    # Sanity: render a few glyphs as ASCII art.
    def show(ch):
        idx = ord(ch) - 0x20
        if not (0 <= idx < NGLYPH):
            return
        print(f"--- '{ch}' (0x{ord(ch):02X}, glyph {idx}) ---")
        base = idx * 8
        for r in range(8):
            byte = out[base + r]
            print("".join('#' if byte & (1 << (7 - c)) else '.' for c in range(8)))

    for ch in "AKY0":
        show(ch)


if __name__ == "__main__":
    main()

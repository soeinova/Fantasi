#!/usr/bin/env python3
"""
Convert a 128x64 PNG to a 1bpp ST7565 page-format bitmap.

The output is a raw 1024-byte file suitable for copying to the device's
LittleFS volume via MSC as /splash.bin.

Usage:
    python3 platforms/flipper/gen_splash.py <input.png> <output.bin>
"""

import sys
import struct
import zlib

DISPLAY_WIDTH = 128
DISPLAY_HEIGHT = 64
DISPLAY_PAGES = DISPLAY_HEIGHT // 8

def _read_png(path):
    with open(path, 'rb') as file:
        data = file.read()

        # consume file format (e.g. signature + chunks)
        signature = b"\x89PNG\r\n\x1a\n"

        if data[:8] == signature:
            print("file is PNG")

        # set data read pointer index
        idx = 8

        # chunk data
        idat = b''
        palette = None
        width = height = bitdepth = colortype = interlace = None

        # chunks
        while idx < len(data):
            length = struct.unpack(">I", data[idx:idx + 4])[0]
            chunk_type = data[idx + 4:idx + 8]
            chunk_data = data[idx + 8:idx + 8 + length]
            idx += 12 + length

            # parse chunk type/data
            if chunk_type == b'IHDR':
                width, height, bitdepth, colortype, _, _, interlace = struct.unpack('>IIBBBBB', chunk_data)
            elif chunk_type == b'PLTE':
                palette = chunk_data
            elif chunk_type == b'IDAT':
                idat += chunk_data
            elif chunk_type == b'IEND':
                break

        if interlace != 0:
            raise ValueError("interlaced PNGs are not supported")
        if bitdepth not in (1, 8):
            raise ValueError(f"only 1-bit and 8-bit PNGs are supported (got {bitdepth}-bit)")

        raw = zlib.decompress(idat)

        if colortype:
            channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
        else:
            raise ValueError("cannot determine colortype")

        # bytes per row
        if width and height:
            if bitdepth == 8:
                stride = width * channels
            else:
                stride = (width * channels + 7) // 8

            unfiltered = bytearray(height * stride)
            prev_row = bytearray(stride)
            src_pos = 0
            for y in range(height):
                filter_type = raw[src_pos]
                src_pos += 1
                row = bytearray(raw[src_pos:src_pos + stride])
                src_pos += stride

                bpp = max(1, channels * bitdepth // 8)
                for x in range(len(row)):
                    a = row[x - bpp] if x >= bpp else 0
                    b = prev_row[x]
                    c = prev_row[x - bpp] if x >= bpp else 0

                    if filter_type == 0:
                        pass
                    elif filter_type == 1:
                        row[x] = (row[x] + a) & 0xFF
                    elif filter_type == 2:
                        row[x] = (row[x] + b) & 0xFF
                    elif filter_type == 3:
                        row[x] = (row[x] + (a + b) // 2) & 0xFF
                    elif filter_type == 4:
                        p = a + b - c
                        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                        pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                        row[x] = (row[x] + pr) & 0xFF
                    else:
                        raise ValueError(f"unknown filter type {filter_type}")

                unfiltered[y * stride:(y + 1) * stride] = row
                prev_row = row

            return width, height, bitdepth, colortype, unfiltered, palette
        else:
            raise ValueError("IDAT chunk missing")


def _to_bilevel(width, height, bitdepth, colortype, pixels, palette):
    """
    Returns a flat bytearray of one value per pixel: 0x00 or 0xFF
    """
    out = bytearray(width * height)

    if bitdepth == 1:
        stride = (width + 7) // 8
        for y in range(height):
            row_off = y * stride
            for x in range(width):
                byte = pixels[row_off + x // 8]
                bit = (byte >> (7 - (x % 8))) & 1
                if colortype == 3:
                    if palette is None:
                        raise ValueError("palette PNG missing PLTE chunk")
                    r = palette[bit * 3]
                    out[y * width + x] = 255 if r >= 128 else 0
                else:
                    out[y * width + x] = 255 if bit else 0
        return out

    # bitdepth == 8
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    stride = width * channels
    if colortype == 3 and palette is None:
        raise ValueError("palette PNG missing PLTE chunk")

    for i in range(width * height):
        base = i * channels
        if colortype == 3:
            idx = pixels[base]
            v = palette[idx * 3]
        else:
            v = pixels[base]
        out[i] = 255 if v >= 128 else 0

    return out


def png_to_st7565(path):
    width, height, bitdepth, colortype, pixels, palette = _read_png(path)
    bw = _to_bilevel(width, height, bitdepth, colortype, pixels, palette)

    buf = bytearray(DISPLAY_PAGES * DISPLAY_WIDTH)
    for page in range(DISPLAY_PAGES):
        for col in range(DISPLAY_WIDTH):
            byte = 0
            for bit in range(8):
                y = page * 8 + bit
                if bw[y * DISPLAY_WIDTH + col] < 128:
                    byte |= 1 << bit
            buf[page * DISPLAY_WIDTH + col] = byte
    return bytes(buf)


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <input.png> <output.bin>", file=sys.stderr)
        sys.exit(1)
    splash = png_to_st7565(sys.argv[1])
    with open(sys.argv[2], "wb") as f:
        f.write(splash)
    print(f"{sys.argv[2]}: {len(splash)} bytes (1bpp ST7565 page format)")


if __name__ == "__main__":
    main()

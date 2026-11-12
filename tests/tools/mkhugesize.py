#!/usr/bin/env python3
"""mkhugesize.py OUTDIR: one small file of each RIFF/IFF/FLIC format whose
chunk declares a size of nearly 4 GB (FLC: nearly 2 GB). In a 32-bit
SizeInt such a size wraps negative, or offset + size does, and a parser
that keeps it there reads before its buffer (an access violation on
Windows x86, found with an ANI of the sample corpus). PAIA must take them
as bytes, without an internal error."""
import os, struct, sys

o = sys.argv[1]
os.makedirs(o, exist_ok=True)


def riff(form, body):
    return b'RIFF' + struct.pack('<I', 4 + len(body)) + form + body


def chunk(t, b):
    return t + struct.pack('<I', len(b)) + b + (b'\0' if len(b) & 1 else b'')


def write(name, data):
    with open(os.path.join(o, name), 'wb') as f:
        f.write(data)


# ANI: anih, then a LIST fram with an empty icon and a chunk of ~4 GB
anih = struct.pack('<9I', 36, 1, 1, 0, 0, 0, 0, 10, 1)
fram = (b'fram' + chunk(b'icon', b'\0' * 16) + b'\0\0\0i'
        + struct.pack('<I', 0xFE6E6F63) + b'x' * 32)
write('ani.ani', riff(b'ACON', chunk(b'anih', anih) + b'LIST'
                      + struct.pack('<I', len(fram)) + fram))
# WebP: VP8X, then an ANMF of ~4 GB
vp8x = bytes([2, 0, 0, 0]) + (15).to_bytes(3, 'little') + (15).to_bytes(3, 'little')
write('webp.webp', riff(b'WEBP', chunk(b'VP8X', vp8x) + b'ANMF'
                        + struct.pack('<I', 0xFFFFFFF0) + b'y' * 40))
# IFF ANIM: a FORM ILBM with its BMHD, then a BODY of ~4 GB
bmhd = struct.pack('>HHhhBBBBHBBhh', 16, 16, 0, 0, 1, 0, 0, 0, 0, 1, 1, 16, 16)
ilbm = (b'ILBM' + b'BMHD' + struct.pack('>I', len(bmhd)) + bmhd
        + b'BODY' + struct.pack('>I', 0xFFFFFFF0) + b'z' * 40)
write('anim.anim', b'FORM' + struct.pack('>I', 4 + 8 + len(ilbm)) + b'ANIM'
      + b'FORM' + struct.pack('>I', len(ilbm)) + ilbm)
# FLC: the 128-byte header, then a frame of nearly 2 GB (128 + it wraps)
hdr = bytearray(128)
struct.pack_into('<IHHHHH', hdr, 0, 0, 0xAF12, 1, 16, 16, 8)
write('flc.flc', bytes(hdr) + struct.pack('<IH', 0x7FFFFFF0, 0xF1FA) + b'w' * 40)

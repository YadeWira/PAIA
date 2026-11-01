"""Writes the synthetic ANI test samples of tests/ani: animated cursors (a
RIFF "ACON" with anih, rate, seq and a LIST "fram" of icon chunks) whose
frames are DIBs of 32, 24, 4 and 1 bits, a CUR with hotspots, a frame kept
as PNG (which PAIA leaves as bytes), and a truncated file.

    python3 -I tests/tools/mkani.py tests/ani
"""
import struct, sys, os, zlib

def pixel(x, y, k, w):
    cx, cy = (k * 3) % w, (k * 5) % w
    inside = (x - cx) ** 2 + (y - cy) ** 2 < (w // 4) ** 2
    return (255, 40 + k * 20, 40, 255) if inside else (x * 255 // w, y * 255 // w, 128, 200 if x > 2 else 0)

def dib(w, h, bpp, k):
    stride = ((w * bpp + 31) // 32) * 4; mstride = ((w + 31) // 32) * 4
    pal = b''
    if bpp <= 8:
        n = 1 << bpp
        pal = b''.join(struct.pack('<BBBB', (i * 37) & 255, (i * 91) & 255, (i * 13) & 255, 0) for i in range(n))
    rows = bytearray(); mask = bytearray()
    for y in range(h - 1, -1, -1):          # bottom-up
        row = bytearray(); bits = 0; nb = 0; mrow = bytearray(); mb = 0; mn = 0
        for x in range(w):
            r, g, b, a = pixel(x, y, k, w)
            if bpp == 32: row += bytes([b, g, r, a])
            elif bpp == 24: row += bytes([b, g, r])
            else:
                v = ((r >> 4) ^ (g >> 5)) & ((1 << bpp) - 1)
                bits = (bits << bpp) | v; nb += bpp
                if nb == 8: row.append(bits); bits = 0; nb = 0
            mb = (mb << 1) | (1 if a == 0 else 0); mn += 1
            if mn == 8: mrow.append(mb); mb = 0; mn = 0
        if nb: row.append(bits << (8 - nb))
        if mn: mrow.append(mb << (8 - mn))
        rows += row + bytes(stride - len(row)); mask += mrow + bytes(mstride - len(mrow))
    hdr = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, bpp, 0, len(rows) + len(mask), 0, 0, 0, 0)
    return hdr + pal + bytes(rows) + bytes(mask)

def png(w, h, k):
    raw = b''.join(b'\0' + b''.join(bytes(pixel(x, y, k, w)) for x in range(w)) for y in range(h))
    def ch(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b'')

def icon(images, cur):
    out = struct.pack('<HHH', 0, 2 if cur else 1, len(images)); off = 6 + 16 * len(images); dirs = b''; data = b''
    for w, h, bpp, img in images:
        p1, p2 = ((w // 2, h // 2) if cur else (1, bpp))
        dirs += struct.pack('<BBBBHHII', w & 255, h & 255, 0, 0, p1, p2, len(img), off + len(data))
        data += img
    return out + dirs + data

def riff(cid, data):
    return cid + struct.pack('<I', len(data)) + data + (b'\0' if len(data) % 2 else b'')

def ani(path, frames, cur=False):
    n = len(frames)
    anih = struct.pack('<IIIIIIIII', 36, n, n, 0, 0, 0, 0, 6, 1)
    fram = b'LIST' + struct.pack('<I', 4 + sum(8 + len(f) + len(f) % 2 for f in frames)) + b'fram'
    fram += b''.join(riff(b'icon', f) for f in frames)
    body = b'ACON' + riff(b'anih', anih) + riff(b'rate', struct.pack('<%dI' % n, *([6] * n))) \
         + riff(b'seq ', struct.pack('<%dI' % n, *range(n))) + fram
    open(path, 'wb').write(b'RIFF' + struct.pack('<I', len(body)) + body)

out = sys.argv[1]
ani(os.path.join(out, 'cursor32.ani'), [icon([(32, 32, 32, dib(32, 32, 32, k))], True) for k in range(6)], True)
ani(os.path.join(out, 'icons_mixed.ani'), [icon([(32, 32, 24, dib(32, 32, 24, k)), (16, 16, 4, dib(16, 16, 4, k)),
                                                   (32, 32, 1, dib(32, 32, 1, k))], False) for k in range(4)])
ani(os.path.join(out, 'with_png.ani'), [icon([(24, 24, 32, png(24, 24, k) if k % 2 else dib(24, 24, 32, k))], False) for k in range(4)])
# repeated frames (the same bitmap again, as many cursors do): A B A C, so
# that what follows a repeat looks back past it; and a second shape
rep = [icon([(32, 32, 32, dib(32, 32, 32, k))], False) for k in (0, 1, 0, 2)] + \
      [icon([(16, 16, 24, dib(16, 16, 24, 0))], False) for k in range(2)]
ani(os.path.join(out, 'repeated.ani'), rep)
d = open(os.path.join(out, 'cursor32.ani'), 'rb').read()
open(os.path.join(out, 'truncated.ani'), 'wb').write(d[:len(d) * 3 // 5])

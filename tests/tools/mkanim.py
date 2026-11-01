"""Writes the synthetic IFF ANIM test samples of tests/anim: a FORM ANIM of
FORM ILBMs, the first with a BODY (ByteRun1, or not compressed), the others
with Byte Vertical Delta (method 5) DLTAs, double buffered as Amiga players
draw them (a delta changes the frame two back); one in XOR mode, and a
truncated file.

    python3 -I tests/tools/mkanim.py tests/anim
"""
import struct, sys, os

def chunk(cid, data):
    return cid + struct.pack('>I', len(data)) + data + (b'\0' if len(data) % 2 else b'')

def form(kind, body):
    return chunk(b'FORM', kind + body)

def frame_pixels(w, h, k):
    img = [[(x // 8 + y // 8 + k) % 4 for x in range(w)] for y in range(h)]
    for y in range(4 + k * 2, min(h, 14 + k * 2)):
        for x in range(6 + k * 3, min(w, 18 + k * 3)):
            img[y][x] = 5 + k % 3
    return img

def planes(img, w, h, np):
    rb = ((w + 15) // 16) * 2
    out = [[bytearray(rb) for _ in range(h)] for _ in range(np)]
    for y in range(h):
        for x in range(w):
            for p in range(np):
                if (img[y][x] >> p) & 1: out[p][y][x // 8] |= 0x80 >> (x % 8)
    return out

def byterun1(row):
    out = bytearray(); i = 0
    while i < len(row):
        r = 1
        while i + r < len(row) and row[i + r] == row[i] and r < 128: r += 1
        if r >= 2: out += bytes([257 - r, row[i]]); i += r
        else:
            s = i
            while i < len(row) and i - s < 128 and not (i + 1 < len(row) and row[i + 1] == row[i]): i += 1
            if i == s: i += 1
            out += bytes([i - s - 1]) + row[s:i]
    return bytes(out)

def body(pl, h, np, rle):
    out = bytearray()
    for y in range(h):
        for p in range(np):
            out += byterun1(pl[p][y]) if rle else pl[p][y]
    return bytes(out)

def delta5(old, new, h, np, rb, xor):
    ptrs = [0] * 16; data = bytearray()
    for p in range(np):
        pd = bytearray()
        for x in range(rb):
            ops = []; y = 0
            while y < h:
                a = old[p][y][x]; b = new[p][y][x]
                if a == b:
                    s = y
                    while y < h and old[p][y][x] == new[p][y][x] and y - s < 127: y += 1
                    ops.append(bytes([y - s]))
                else:
                    v = (a ^ b) if xor else b; s = y; vals = bytearray()
                    while y < h and old[p][y][x] != new[p][y][x] and y - s < 127:
                        vals.append((old[p][y][x] ^ new[p][y][x]) if xor else new[p][y][x]); y += 1
                    if len(set(vals)) == 1 and len(vals) > 2: ops.append(bytes([0, len(vals), vals[0]]))
                    else: ops.append(bytes([0x80 | len(vals)]) + vals)
            pd += bytes([len(ops)]) + b''.join(ops)
        ptrs[p] = 64 + len(data); data += pd
    return struct.pack('>16I', *ptrs) + bytes(data)

def anim(path, w, h, np, n, rle=True, xor=False):
    rb = ((w + 15) // 16) * 2
    frames = [planes(frame_pixels(w, h, k), w, h, np) for k in range(n)]
    bmhd = struct.pack('>HHhhBBBBHBBhh', w, h, 0, 0, np, 0, 1 if rle else 0, 0, 0, 10, 11, w, h)
    cmap = bytes((i * 40) & 255 for i in range(3 << np))
    out = form(b'ILBM', chunk(b'BMHD', bmhd) + chunk(b'CMAP', cmap) + chunk(b'BODY', body(frames[0], h, np, rle)))
    buf = [frames[0], frames[0]]
    for k in range(1, n):
        t = k & 1
        anhd = struct.pack('>BBHHhhIIBBI16s', 5, 0, w, h, 0, 0, 0, 1, 0, 0, 2 if xor else 0, bytes(16))
        out += form(b'ILBM', chunk(b'ANHD', anhd) + chunk(b'DLTA', delta5(buf[t], frames[k], h, np, rb, xor)))
        buf[t] = frames[k]
    open(path, 'wb').write(form(b'ANIM', out))

o = sys.argv[1]
anim(os.path.join(o, 'delta5.anim'), 64, 40, 3, 8)
anim(os.path.join(o, 'delta5_xor.anim'), 48, 32, 4, 6, xor=True)
anim(os.path.join(o, 'body_raw.anim'), 40, 24, 2, 5, rle=False)
d = open(os.path.join(o, 'delta5.anim'), 'rb').read()
open(os.path.join(o, 'truncated.anim'), 'wb').write(d[:len(d) * 2 // 3])

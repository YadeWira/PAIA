"""Writes the synthetic IFF ANIM test samples of tests/anim: a FORM ANIM of
FORM ILBMs, the first with a BODY (ByteRun1, or not compressed), the others
with DLTAs, double buffered as Amiga players draw them (a delta changes the
frame two back): method 5 (Byte Vertical Delta, one in XOR mode), 3, 7 and
8 (short and long), 74 ("J", both of its types, one in XOR mode, one under
320 pixels wide), 100, 101 and 108; and a truncated file. As FFmpeg's
iff.c reads each (tests/tools/check_anim.py checks it does).

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

# ---- the other methods. old and new: planes [p][y] -> bytearray(rb) ----

def changed_units(old, new, p, x, h, n):
    """the rows where the n bytes at column x of plane p differ"""
    return [y for y in range(h) if old[p][y][x:x + n] != new[p][y][x:x + n]]

def unit(pl, p, y, x, n):
    b = bytes(pl[p][y][x:x + n])
    return b + bytes(n - len(b))

def vertical_ops(old, new, p, x, h, n, xor, wide, maxrun):
    """a column's opcodes down the rows: (kind, count, [units]); kind 0 a
    run of one unit, 1 a skip, 2 literal units"""
    ops = []; y = 0
    def val(yy):
        u = unit(new, p, yy, x, n)
        return bytes(a ^ b for a, b in zip(u, unit(old, p, yy, x, n))) if xor else u
    while y < h:
        if unit(old, p, y, x, n) == unit(new, p, y, x, n):
            s = y
            while y < h and unit(old, p, y, x, n) == unit(new, p, y, x, n) and y - s < maxrun: y += 1
            ops.append((1, y - s, []))
        else:
            s = y
            while y < h and unit(old, p, y, x, n) != unit(new, p, y, x, n) and y - s < maxrun: y += 1
            vals = [val(yy) for yy in range(s, y)]
            if len(vals) > 2 and len(set(vals)) == 1: ops.append((0, len(vals), vals[:1]))
            else: ops.append((2, len(vals), vals))
    while ops and ops[-1][0] == 1: ops.pop()
    return ops

def delta7(old, new, w, h, np, long, xor):
    """method 7: 8 opcode lists (bytes), then 8 data lists (words or longs)"""
    rb = ((w + 15) // 16) * 2
    cb = 4 if long else 2
    ncol = (w + 31) >> 5 if long else (w + 15) >> 4
    half = long and rb != ncol * 4
    oplists = []; datalists = []
    for p in range(np):
        o = bytearray(); d = bytearray()
        for j in range(ncol):
            n = 2 if half and j == ncol - 1 else cb
            ops = vertical_ops(old, new, p, j * cb, h, n, xor, 1, 127)
            o.append(len(ops))
            for k, c, vals in ops:
                if k == 1: o.append(c)
                elif k == 0: o += bytes([0, c]); d += vals[0] + bytes(cb - n)
                else:
                    o.append(0x80 | c)
                    for v in vals: d += v + bytes(cb - n)
        oplists.append(o); datalists.append(d)
    body = bytearray(); ptrs = [0] * 16
    for p in range(np):
        ptrs[p] = 64 + len(body); body += oplists[p]
        if len(body) % 2: body.append(0)
    for p in range(np):
        ptrs[8 + p] = 64 + len(body); body += datalists[p]
    return struct.pack('>16I', *ptrs) + bytes(body)

def delta8(old, new, w, h, np, long, xor):
    """method 8: per plane one list, counts and opcodes as wide as the data"""
    rb = ((w + 15) // 16) * 2
    cb = 4 if long else 2
    ncol = (w + 31) >> 5 if long else (w + 15) >> 4
    half = long and rb != ncol * 4
    W = '>I' if long else '>H'
    body = bytearray(); ptrs = [0] * 16
    for p in range(np):
        ptrs[p] = 64 + len(body)
        for j in range(ncol):
            last_half = half and j == ncol - 1
            n = 2 if last_half else cb
            top = 0x8000 if (last_half or not long) else 0x80000000
            ops = vertical_ops(old, new, p, j * cb, h, n, xor, 2, 120)
            body += struct.pack(W, len(ops))
            for k, c, vals in ops:
                if k == 1: body += struct.pack(W, c)
                elif k == 0:
                    body += struct.pack(W, 0)
                    body += (struct.pack('>H', c) + vals[0]) if last_half else (struct.pack(W, c) + vals[0])
                else:
                    body += struct.pack(W, top | c)
                    for v in vals: body += v
    return struct.pack('>16I', *ptrs) + bytes(body)

def delta3(old, new, w, h, np):
    """method 3: per plane, single words at offsets, and runs of words"""
    rb = ((w + 15) // 16) * 2
    body = bytearray(); ptrs = [0] * 16
    for p in range(np):
        words = [i for i in range(0, rb * h, 2)
                 if old[p][i // rb][i % rb:i % rb + 2] != new[p][i // rb][i % rb:i % rb + 2]]
        if not words: continue
        ptrs[p] = 64 + len(body); pos = 0; i = 0
        while i < len(words):
            j = i
            while j + 1 < len(words) and words[j + 1] == words[j + 2 - 2] + 2 and j - i < 50: j += 1
            if j > i and words[i] >= pos + 2:
                off = -((words[i] - pos - 2) // 2) - 2
                body += struct.pack('>hH', off, j - i + 1)
                for t in words[i:j + 1]:
                    body += bytes(new[p][t // rb][t % rb:t % rb + 2])
                pos = words[j]; i = j + 1
            else:
                t = words[i]
                body += struct.pack('>H', (t - pos) // 2) + bytes(new[p][t // rb][t % rb:t % rb + 2])
                pos = t; i += 1
        body += b'\xff\xff'
    return struct.pack('>16I', *ptrs) + bytes(body)

def deltaJ(old, new, w, h, np, xor, kind):
    """method 74 ("J"): type 1, vertical runs through the planes at a byte
    column; type 2, rectangles of rows of bytes"""
    rb = ((w + 15) // 16) * 2
    kludge = (320 - w) // 16 if w < 320 else 0
    ppb = 40 if kludge else (w + 7) // 8
    def ofs(y, x): return y * ppb + x + kludge
    def v(p, y, x): return (old[p][y][x] ^ new[p][y][x]) if xor else new[p][y][x]
    def rowdiff(y, x): return any(old[p][y][x] != new[p][y][x] for p in range(np))
    out = bytearray()
    if kind == 1:
        runs = {}
        for x in range(rb):
            y = 0
            while y < h:
                if rowdiff(y, x):
                    s = y
                    while y < h and rowdiff(y, x) and y - s < 30: y += 1
                    runs.setdefault(y - s, []).append((s, x))
                else: y += 1
        for cols, groups in sorted(runs.items()):
            out += struct.pack('>HHHH', 1, 1 if xor else 0, cols, len(groups))
            for s, x in groups:
                out += struct.pack('>H', ofs(s, x))
                for yy in range(s, s + cols):
                    for p in range(np): out.append(v(p, yy, x))
                if (cols * np) % 2: out.append(0)
    else:
        rects = []
        for y in range(0, h, 4):
            for x in range(0, rb, 2):
                if any(rowdiff(yy, xx) for yy in range(y, min(h, y + 4)) for xx in (x, x + 1)):
                    rects.append((y, x))
        rows = 4; nb = 2
        full = [(y, x) for y, x in rects if y + rows <= h]
        if full:
            out += struct.pack('>HHHHH', 2, 1 if xor else 0, rows, nb, len(full))
            for y, x in full:
                out += struct.pack('>H', ofs(y, x))
                for yy in range(y, y + rows):
                    for p in range(np): out += bytes(v(p, yy, xx) for xx in (x, x + 1))
                if (rows * nb * np) % 2: out.append(0)
    out += struct.pack('>H', 0)
    return bytes(out)

def deltaDE(old, new, w, h, np, long):
    """methods 100 (longwords) and 101 (words): per plane, entries of
    (opcode, offset): a run of one value down the rows, or literal values"""
    rb = ((w + 15) // 16) * 2
    n = 4 if long else 2
    ppb = (w + 7) // 8
    lists = []
    for p in range(np):
        ents = []
        for x in range(0, rb - n + 1, n):
            ops = vertical_ops(old, new, p, x, h, n, False, 1, 200)
            y = 0
            for k, c, vals in ops:
                if k == 1: y += c; continue
                if k == 0: ents.append(struct.pack('>i' if long else '>h', c) + struct.pack('>I', y * ppb + x) + vals[0])
                else: ents.append(struct.pack('>i' if long else '>h', -c) + struct.pack('>I', y * ppb + x) + b''.join(vals))
                y += c
        lists.append(struct.pack('>I' if long else '>H', len(ents)) + b''.join(ents))
    body = bytearray(); ptrs = [0] * 16
    for p in range(np):
        ptrs[p] = 64 + len(body); body += lists[p]
        if len(body) % 2: body.append(0)
    return struct.pack('>16I', *ptrs) + bytes(body)

def deltaL(old, new, w, h, np, vertical):
    """method 108: per plane, (offset, count) pairs and their data words
    apart; down the rows (vertical, ANHD bits 0 clear) or across"""
    rb = ((w + 15) // 16) * 2
    ppb = (w + 7) // 8
    assert ppb == rb
    dpairs = []; dwords = []
    for p in range(np):
        o = bytearray(); d = bytearray()
        if vertical:
            for x in range(0, rb, 2):
                y = 0
                for k, c, vals in vertical_ops(old, new, p, x, h, 2, False, 1, 100):
                    if k == 1: y += c; continue
                    o += struct.pack('>Hh', (y * ppb + x) // 2, -c if k == 0 else c)
                    d += vals[0] if k == 0 else b''.join(vals)
                    y += c
        else:
            for y in range(h):
                x = 0
                while x < rb:
                    if new[p][y][x:x + 2] != old[p][y][x:x + 2]:
                        s = x
                        while x < rb and new[p][y][x:x + 2] != old[p][y][x:x + 2]: x += 2
                        o += struct.pack('>Hh', (y * ppb + s) // 2, (x - s) // 2)
                        d += bytes(new[p][y][s:x])
                    else: x += 2
        o += b'\xff\xff'
        dpairs.append(o); dwords.append(d)
    body = bytearray(); t0 = [0] * 8; t1 = [0] * 8
    for p in range(np):
        t0[p] = (64 + len(body)) // 2; body += dwords[p]
        t1[p] = (64 + len(body)) // 2; body += dpairs[p]
    return struct.pack('>8I', *t0) + struct.pack('>8I', *t1) + bytes(body)

def anim2(path, w, h, np, n, method, bits=0, xor=False, jkind=1):
    """an ANIM whose deltas are of `method`"""
    rb = ((w + 15) // 16) * 2
    frames = [planes(frame_pixels(w, h, k), w, h, np) for k in range(n)]
    bmhd = struct.pack('>HHhhBBBBHBBhh', w, h, 0, 0, np, 0, 1, 0, 0, 10, 11, w, h)
    cmap = bytes((i * 40) & 255 for i in range(3 << np))
    out = form(b'ILBM', chunk(b'BMHD', bmhd) + chunk(b'CMAP', cmap) + chunk(b'BODY', body(frames[0], h, np, True)))
    buf = [frames[0], frames[0]]
    for k in range(1, n):
        t = k & 1
        old, new = buf[t], frames[k]
        long = bool(bits & 1)
        if method == 7: d = delta7(old, new, w, h, np, long, xor)
        elif method == 8: d = delta8(old, new, w, h, np, long, xor)
        elif method == 3: d = delta3(old, new, w, h, np)
        elif method == 74: d = deltaJ(old, new, w, h, np, xor, jkind)
        elif method in (100, 101): d = deltaDE(old, new, w, h, np, method == 100)
        elif method == 108: d = deltaL(old, new, w, h, np, not long)
        anhd = struct.pack('>BBHHhhIIBBI16s', method, 0, w, h, 0, 0, 0, 1, 0, 0, bits | (2 if xor else 0), bytes(16))
        out += form(b'ILBM', chunk(b'ANHD', anhd) + chunk(b'DLTA', d))
        buf[t] = new
    open(path, 'wb').write(form(b'ANIM', out))

o = sys.argv[1]
anim(os.path.join(o, 'delta5.anim'), 64, 40, 3, 8)
anim(os.path.join(o, 'delta5_xor.anim'), 48, 32, 4, 6, xor=True)
anim(os.path.join(o, 'body_raw.anim'), 40, 24, 2, 5, rle=False)
d = open(os.path.join(o, 'delta5.anim'), 'rb').read()
open(os.path.join(o, 'truncated.anim'), 'wb').write(d[:len(d) * 2 // 3])
anim2(os.path.join(o, 'delta3.anim'), 64, 40, 3, 7, 3)
anim2(os.path.join(o, 'delta7_short.anim'), 64, 40, 3, 7, 7)
anim2(os.path.join(o, 'delta7_long.anim'), 80, 40, 3, 7, 7, bits=1)
anim2(os.path.join(o, 'delta8_short.anim'), 64, 40, 3, 7, 8)
anim2(os.path.join(o, 'delta8_long.anim'), 80, 40, 3, 7, 8, bits=1)
anim2(os.path.join(o, 'deltaJ_cols.anim'), 320, 32, 3, 6, 74)
anim2(os.path.join(o, 'deltaJ_rows_xor.anim'), 320, 32, 2, 6, 74, xor=True, jkind=2)
anim2(os.path.join(o, 'deltaJ_narrow.anim'), 288, 24, 2, 5, 74)
anim2(os.path.join(o, 'delta100.anim'), 64, 40, 3, 7, 100)
anim2(os.path.join(o, 'delta101.anim'), 64, 40, 3, 7, 101)
anim2(os.path.join(o, 'delta108.anim'), 64, 40, 3, 7, 108)

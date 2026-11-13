"""Writes the synthetic FLI/FLC test samples of tests/fli: small animations
(a gradient with a moving square) with every pixel chunk PAIA takes:
BYTE_RUN, DELTA_FLI (LC), DELTA_FLC (SS2, with the last-byte word of an odd
width), COPY, BLACK, palettes, and an unknown chunk; a prefix chunk with a
postage stamp; 16-bit FLCs (magic 0xAF44 and 0xAF12) with DTA_BRUN, DTA_LC
and DTA_COPY (one of an odd width); and an FLI with a sound chunk ("DS",
16-bit samples) in each frame. tests/tools/check_flic.py checks FFmpeg's
reading of them.

    python3 -I tests/tools/mkflic.py tests/fli
"""
import struct, sys, os

def frames(w, h, n):
    out = []
    for k in range(n):
        img = bytearray((x * 3 + y * 5) & 63 for y in range(h) for x in range(w))
        sx, sy = 4 + k * 3, 3 + (k % 4) * 2
        for y in range(sy, min(h, sy + 9)):
            for x in range(sx, min(w, sx + 9)):
                img[y * w + x] = 200 + k % 7
        out.append(bytes(img))
    return out

def chunk(t, data):
    if len(data) % 2: data += b'\0'
    return struct.pack('<IH', 6 + len(data), t) + data

def brun(img, w, h):
    out = bytearray()
    for y in range(h):
        row = img[y * w:(y + 1) * w]; pk = bytearray(); n = 0; x = 0
        while x < w:
            r = 1
            while x + r < w and row[x + r] == row[x] and r < 127: r += 1
            if r >= 3:
                pk += struct.pack('<bB', r, row[x]); x += r
            else:
                s = x
                while x < w and x - s < 127:
                    r = 1
                    while x + r < w and row[x + r] == row[x] and r < 3: r += 1
                    if r >= 3: break
                    x += 1
                pk += struct.pack('<b', -(x - s)) + row[s:x]
            n += 1
        out += bytes([n & 255]) + pk
    return bytes(out)

def lc(prev, img, w, h):
    lines = [y for y in range(h) if prev[y*w:(y+1)*w] != img[y*w:(y+1)*w]]
    if not lines: return struct.pack('<HH', 0, 0)
    y0, y1 = lines[0], lines[-1]
    out = bytearray(struct.pack('<HH', y0, y1 - y0 + 1))
    for y in range(y0, y1 + 1):
        a, b = prev[y*w:(y+1)*w], img[y*w:(y+1)*w]; pk = bytearray(); n = 0; x = 0; last = 0
        while x < w:
            if a[x] == b[x]: x += 1; continue
            s = x
            while x < w and a[x] != b[x] and x - s < 120: x += 1
            skip = s - last
            while skip > 255: pk += struct.pack('<Bb', 255, 0); n += 1; skip -= 255
            run = b[s:x]
            if len(set(run)) == 1 and len(run) > 2: pk += struct.pack('<Bb', skip, -len(run)) + run[:1]
            else: pk += struct.pack('<Bb', skip, len(run)) + run
            n += 1; last = x
        out += bytes([n]) + pk
    return bytes(out)

def ss2(prev, img, w, h):
    out = bytearray(); nl = 0; skip = 0
    for y in range(h):
        a, b = prev[y*w:(y+1)*w], img[y*w:(y+1)*w]
        if a == b: skip += 1; continue
        if skip: out += struct.pack('<H', (65536 - skip) & 0xFFFF); skip = 0
        if w % 2: out += struct.pack('<H', 0x8000 | b[w - 1])
        pk = bytearray(); n = 0; x = 0; last = 0; ww = w - (w % 2)
        while x < ww:
            if a[x:x+2] == b[x:x+2]: x += 2; continue
            s = x
            while x < ww and a[x:x+2] != b[x:x+2] and x - s < 200: x += 2
            pk += struct.pack('<Bb', s - last, (x - s) // 2) + b[s:x]; n += 1; last = x
        out += struct.pack('<H', n) + pk; nl += 1
    return struct.pack('<H', nl) + bytes(out)

def flic(path, flc, w, h, n, kinds):
    fr = frames(w, h, n); body = bytearray(); prev = bytes(w * h)
    for k in range(n):
        subs = []
        if k == 0:
            pal = bytes((c % 64) if not flc else ((c * 4) & 255) for c in range(768))
            # one packet: skip 0, count 0 (= 256 colours)
            subs.append(chunk(4 if flc else 11, struct.pack('<HBB', 1, 0, 0) + pal))
        kind = kinds[k % len(kinds)] if k else kinds[0]
        if kind == 'brun': subs.append(chunk(15, brun(fr[k], w, h)))
        elif kind == 'copy': subs.append(chunk(16, fr[k]))
        elif kind == 'black': subs.append(chunk(13, b'')); fr[k] = bytes(w * h)
        elif kind == 'lc': subs.append(chunk(12, lc(prev, fr[k], w, h)))
        elif kind == 'ss2': subs.append(chunk(7, ss2(prev, fr[k], w, h)))
        elif kind == 'unknown': subs.append(chunk(0x5344, b'not a pixel chunk')); fr[k] = prev
        data = b''.join(subs)
        body += struct.pack('<IHHH', 16 + len(data), 0xF1FA, len(subs), 0) + bytes(6) + data
        prev = fr[k]
    hdr = struct.pack('<IHHHHHHI', 128 + len(body), 0xAF12 if flc else 0xAF11, n, w, h, 8, 3, 5)
    hdr += bytes(128 - len(hdr))
    open(path, 'wb').write(hdr + body)

# ---- 16-bit FLCs, stamps, sound ----

def frames16(w, h, n):
    out = []
    for k in range(n):
        px = [((x * 2 + k) & 31) << 11 | ((y * 3) & 63) << 5 | ((x + y) & 31) for y in range(h) for x in range(w)]
        sx, sy = 3 + k * 3, 2 + (k % 3) * 2
        for y in range(sy, min(h, sy + 7)):
            for x in range(sx, min(w, sx + 7)):
                px[y * w + x] = 0xF800 | (k * 5 & 63) << 5
        out.append(px)
    return out

PW = 2   # bytes a pixel of the deep FLIC being written

def words(px): return b''.join(v.to_bytes(PW, 'little') for v in px)

def dbrun(px, w, h):
    out = bytearray()
    for y in range(h):
        row = px[y * w:(y + 1) * w]; pk = bytearray(); n = 0; x = 0
        while x < w:
            r = 1
            while x + r < w and row[x + r] == row[x] and r < 127: r += 1
            if r >= 2: pk += struct.pack('<b', r) + words([row[x]]); x += r
            else:
                s = x
                while x < w and x - s < 127 and not (x + 1 < w and row[x + 1] == row[x]): x += 1
                if x == s: x += 1
                pk += struct.pack('<b', -(x - s)) + words(row[s:x])
            n += 1
        out += bytes([n & 255]) + pk
    return bytes(out)

def dlc(prev, px, w, h):
    out = bytearray(); nl = 0; skip = 0
    for y in range(h):
        a, b = prev[y*w:(y+1)*w], px[y*w:(y+1)*w]
        if a == b: skip += 1; continue
        if skip: out += struct.pack('<h', -skip); skip = 0
        pk = bytearray(); n = 0; x = 0; last = 0
        while x < w:
            if a[x] == b[x]: x += 1; continue
            s = x
            while x < w and a[x] != b[x] and x - s < 100: x += 1
            run = b[s:x]
            if len(set(run)) == 1 and len(run) > 2: pk += struct.pack('<Bb', s - last, -len(run)) + words(run[:1])
            else: pk += struct.pack('<Bb', s - last, len(run)) + words(run)
            n += 1; last = x
        out += struct.pack('<H', n) + pk; nl += 1
    return struct.pack('<H', nl) + bytes(out)

def dcopy(px, w, h):
    out = bytearray()
    for y in range(h):
        out += words(px[y * w:(y + 1) * w])
        if w % 2: out += bytes(PW)
    return bytes(out)

def frames24(w, h, n):
    return [[((v & 31) << 19) | (((v >> 5) & 63) << 10) | ((v >> 11) << 3) for v in fr] for fr in frames16(w, h, n)]

def flic16(path, magic, w, h, n, kinds, depth=16):
    global PW
    PW = 3 if depth == 24 else 2
    fr = (frames24 if depth == 24 else frames16)(w, h, n); body = bytearray(); prev = [0] * (w * h)
    for k in range(n):
        kind = kinds[k % len(kinds)] if k else kinds[0]
        if kind == 'dbrun': c = chunk(25, dbrun(fr[k], w, h))
        elif kind == 'dcopy': c = chunk(26, dcopy(fr[k], w, h))
        elif kind == 'dlc': c = chunk(27, dlc(prev, fr[k], w, h))
        elif kind == 'black': c = chunk(13, b''); fr[k] = [0] * (w * h)
        body += struct.pack('<IHHH', 16 + len(c), 0xF1FA, 1, 0) + bytes(6) + c
        prev = fr[k]
    hdr = struct.pack('<IHHHHHHI', 128 + len(body), magic, n, w, h, depth, 3, 5)
    hdr += bytes(128 - len(hdr))
    open(path, 'wb').write(hdr + body)

def stamped(path, w, h, n):
    """an FLC with a prefix chunk holding a postage stamp (a BYTE_RUN image)"""
    flic(path, True, w, h, n, ['brun', 'ss2'])
    d = bytearray(open(path, 'rb').read())
    sw, sh = w // 4, h // 4
    st = bytes((x * 9 + y * 7) & 255 for y in range(sh) for x in range(sw))
    sub = brun(st, sw, sh)
    ps = struct.pack('<HHH', sh, sw, 1) + struct.pack('<IH', 6 + len(sub), 15) + sub
    pre = chunk(18, ps)
    prefix = struct.pack('<IHHH', 16 + len(pre), 0xF100, 1, 0) + bytes(6) + pre
    d[128:128] = prefix
    struct.pack_into('<I', d, 0, len(d))
    open(path, 'wb').write(bytes(d))

def sounded(path, w, h, n):
    """an FLI whose frames each carry a sound chunk: a sine of 16-bit samples"""
    import math
    fr = frames(w, h, n); body = bytearray(); prev = bytes(w * h); t = 0
    for k in range(n):
        subs = []
        if k == 0: subs.append(chunk(11, struct.pack('<HBB', 1, 0, 0) + bytes(c % 64 for c in range(768))))
        subs.append(chunk(15, brun(fr[k], w, h)) if k == 0 else chunk(12, lc(prev, fr[k], w, h)))
        smp = []
        for i in range(400):
            smp.append(int(9000 * math.sin(t / 7.3) + 2500 * math.sin(t / 2.1))); t += 1
        subs.append(chunk(0x5344, b''.join(struct.pack('<h', v) for v in smp)))
        data = b''.join(subs)
        body += struct.pack('<IHHH', 16 + len(data), 0xF1FA, len(subs), 0) + bytes(6) + data
        prev = fr[k]
    hdr = struct.pack('<IHHHHHHI', 128 + len(body), 0xAF11, n, w, h, 8, 3, 5)
    hdr += bytes(128 - len(hdr))
    open(path, 'wb').write(hdr + body)

out = sys.argv[1]
flic(os.path.join(out, 'synth_lc.fli'), False, 64, 40, 8, ['brun', 'lc'])
flic(os.path.join(out, 'synth_ss2.flc'), True, 63, 41, 8, ['brun', 'ss2'])
flic(os.path.join(out, 'synth_mixed.flc'), True, 52, 30, 10, ['copy', 'ss2', 'black', 'lc', 'unknown', 'brun'])
d = open(os.path.join(out, 'synth_ss2.flc'), 'rb').read()
open(os.path.join(out, 'truncated.flc'), 'wb').write(d[:len(d) * 2 // 3])
flic16(os.path.join(out, 'dta16.flc'), 0xAF44, 48, 32, 8, ['dcopy', 'dlc', 'dbrun', 'dlc'])
flic16(os.path.join(out, 'dta16_odd.flc'), 0xAF12, 37, 23, 6, ['dbrun', 'dlc', 'black', 'dcopy'])
stamped(os.path.join(out, 'stamp.flc'), 64, 40, 5)
sounded(os.path.join(out, 'sound.fli'), 64, 40, 6)
flic16(os.path.join(out, 'dta24_odd.flc'), 0xAF44, 33, 21, 6, ['dcopy', 'dlc', 'dbrun'], depth=24)

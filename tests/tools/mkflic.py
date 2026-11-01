"""Writes the synthetic FLI/FLC test samples of tests/fli: small animations
(a gradient with a moving square) with every pixel chunk PAIA takes:
BYTE_RUN, DELTA_FLI (LC), DELTA_FLC (SS2, with the last-byte word of an odd
width), COPY, BLACK, plus palettes and a stamp-like unknown chunk.

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

out = sys.argv[1]
flic(os.path.join(out, 'synth_lc.fli'), False, 64, 40, 8, ['brun', 'lc'])
flic(os.path.join(out, 'synth_ss2.flc'), True, 63, 41, 8, ['brun', 'ss2'])
flic(os.path.join(out, 'synth_mixed.flc'), True, 52, 30, 10, ['copy', 'ss2', 'black', 'lc', 'unknown', 'brun'])
d = open(os.path.join(out, 'synth_ss2.flc'), 'rb').read()
open(os.path.join(out, 'truncated.flc'), 'wb').write(d[:len(d) * 2 // 3])

"""check_flic.py DIR: each synthetic FLIC of mkflic.py, decoded by FFmpeg,
gives the frames mkflic.py meant: palette indices for 8-bit FLICs, the
pixels' words for 16-bit ones (RGB565 for magic 0xAF44, RGB555 for an
0xAF12 of depth 16, as FFmpeg reads Autodesk's FLX).

    python3 -I tests/tools/check_flic.py tests/fli
"""
import os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def frames(w, h, n):   # as mkflic.py
    out = []
    for k in range(n):
        img = bytearray((x * 3 + y * 5) & 63 for y in range(h) for x in range(w))
        sx, sy = 4 + k * 3, 3 + (k % 4) * 2
        for y in range(sy, min(h, sy + 9)):
            for x in range(sx, min(w, sx + 9)):
                img[y * w + x] = 200 + k % 7
        out.append(bytes(img))
    return out

def frames16(w, h, n):   # as mkflic.py
    out = []
    for k in range(n):
        px = [((x * 2 + k) & 31) << 11 | ((y * 3) & 63) << 5 | ((x + y) & 31) for y in range(h) for x in range(w)]
        sx, sy = 3 + k * 3, 2 + (k % 3) * 2
        for y in range(sy, min(h, sy + 7)):
            for x in range(sx, min(w, sx + 7)):
                px[y * w + x] = 0xF800 | (k * 5 & 63) << 5
        out.append(px)
    return out

SPEC = {  # name: (w, h, n, bits, black frames)
    'synth_lc.fli': (64, 40, 8, 8, ()), 'synth_ss2.flc': (63, 41, 8, 8, ()),
    'stamp.flc': (64, 40, 5, 8, ()), 'sound.fli': (64, 40, 6, 8, ()),
    'dta16.flc': (48, 32, 8, 565, ()), 'dta16_odd.flc': (37, 23, 6, 555, (2,)),
}

d = sys.argv[1]; bad = 0
for name, (w, h, n, bits, black) in sorted(SPEC.items()):
    fmt = {8: 'pal8', 565: 'rgb565le', 555: 'rgb555le'}[bits]
    r = subprocess.run(['ffmpeg', '-v', 'error', '-i', os.path.join(d, name), '-fps_mode', 'passthrough',
                        '-f', 'rawvideo', '-pix_fmt', fmt, '-'], capture_output=True)
    if bits == 8:
        size = w * h + 1024
        got = [r.stdout[i:i + w * h] for i in range(0, len(r.stdout), size)]
        want = frames(w, h, n)
    else:
        size = w * h * 2
        raw = [r.stdout[i:i + size] for i in range(0, len(r.stdout), size)]
        mask = 0x7FFF if bits == 555 else 0xFFFF
        got = [[(f[2 * i] | f[2 * i + 1] << 8) & mask for i in range(w * h)] for f in raw]
        want = [[v & mask for v in fr] for fr in frames16(w, h, n)]
        for k in black: want[k] = [0] * (w * h)
    ok = len(got) >= n and all(got[k] == want[k] for k in range(n))
    if ok: print('ok', name)
    else:
        bad += 1
        print('DIFFERS', name, 'frames:', len(got), 'differing:',
              [k for k in range(min(n, len(got))) if got[k] != want[k]], r.stderr.decode()[:200])
sys.exit(1 if bad else 0)

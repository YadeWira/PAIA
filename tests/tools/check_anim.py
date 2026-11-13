"""check_anim.py DIR: each synthetic IFF ANIM of mkanim.py, decoded by
FFmpeg, gives the frames mkanim.py meant (its palette indices): the
samples are what real players read, not only what PAIA's walks expect.

    python3 -I tests/tools/check_anim.py tests/anim
"""
import os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
SPEC = {   # name: (w, h, frames)
    'delta5.anim': (64, 40, 8), 'delta5_xor.anim': (48, 32, 6), 'body_raw.anim': (40, 24, 5),
    'delta3.anim': (64, 40, 7), 'delta7_short.anim': (64, 40, 7), 'delta7_long.anim': (80, 40, 7),
    'delta8_short.anim': (64, 40, 7), 'delta8_long.anim': (80, 40, 7),
    'deltaJ_cols.anim': (320, 32, 6), 'deltaJ_rows_xor.anim': (320, 32, 6), 'deltaJ_narrow.anim': (288, 24, 5),
    'delta100.anim': (64, 40, 7), 'delta101.anim': (64, 40, 7), 'delta108.anim': (64, 40, 7),
}

def frame_pixels(w, h, k):   # as mkanim.py
    img = [[(x // 8 + y // 8 + k) % 4 for x in range(w)] for y in range(h)]
    for y in range(4 + k * 2, min(h, 14 + k * 2)):
        for x in range(6 + k * 3, min(w, 18 + k * 3)):
            img[y][x] = 5 + k % 3
    return img

# FFmpeg does not keep two buffers for XOR deltas as it does for the
# others: from the third frame on it XORs into another frame. Those two
# are checked up to their second frame.
XOR = {'delta5_xor.anim', 'deltaJ_rows_xor.anim'}

d = sys.argv[1]; bad = 0
for name, (w, h, n) in sorted(SPEC.items()):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-i', os.path.join(d, name), '-fps_mode', 'passthrough', '-f', 'rawvideo',
                        '-pix_fmt', 'pal8', '-'], capture_output=True)
    size = w * h + 1024
    got = [r.stdout[i:i + w * h] for i in range(0, len(r.stdout), size)]
    np_ = {'delta5_xor.anim': 4, 'body_raw.anim': 2, 'deltaJ_rows_xor.anim': 2, 'deltaJ_narrow.anim': 2}.get(name, 3)
    want = [bytes(v & ((1 << np_) - 1) for row in frame_pixels(w, h, k) for v in row) for k in range(n)]
    m = 2 if name in XOR else n
    ok = len(got) >= n and all(got[k] == want[k] for k in range(m))
    if not ok:
        bad += 1
        diff = [k for k in range(min(m, len(got))) if got[k] != want[k]]
        print('DIFFERS', name, 'frames from ffmpeg:', len(got), 'differing:', diff, r.stderr.decode()[:200])
    else:
        print('ok', name)
sys.exit(1 if bad else 0)

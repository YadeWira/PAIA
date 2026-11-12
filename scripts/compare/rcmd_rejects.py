#!/usr/bin/env python3
"""rcmd_rejects.py PLUGIN SETS OUT: the files of each format that PAIA's
zpaq-std codec does not take, to measure +rcmd's fallback on (the family's
template: measured per codec, on what it does not take).

From every distinct file of SETS/<format>/, the first the plugin's own
detect (zpaqstd_detect_v1) does not take (answers other than 1) of: the
file itself, three single-bit flips in its first 4 KB, and truncations to
50, 10 and 2 %. One a file at most: copies of the same file would share
most of their bytes, which a method that sees them all together exploits
and a file not taken in the wild does not offer."""
import ctypes, hashlib, os, random, sys

so = ctypes.CDLL(os.path.abspath(sys.argv[1]))
detect = so.zpaqstd_detect_v1
detect.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
detect.restype = ctypes.c_int
CODEC = {'gif': b'paiagif1', 'flic': b'paiaflc1', 'ani': b'paiaani1',
         'anim': b'paiaanim1', 'webp': b'paiawebp1'}
src, dst = sys.argv[2], sys.argv[3]
rnd = random.Random(1)
seen = set()
for fmt, codec in CODEC.items():
    os.makedirs(os.path.join(dst, fmt), exist_ok=True)
    for name in sorted(os.listdir(os.path.join(src, fmt))):
        with open(os.path.join(src, fmt, name), 'rb') as f:
            d = f.read()
        h = hashlib.sha1(d).digest()
        if h in seen:
            continue
        seen.add(h)
        vs = {'orig': d}
        for j in range(3):
            b = bytearray(d)
            i = rnd.randrange(12, min(len(b), 4096))
            b[i] ^= 1 << rnd.randrange(8)
            vs['flip%d' % j] = bytes(b)
        for pc in (50, 10, 2):
            vs['cut%d' % pc] = d[:max(16, len(d) * pc // 100)]
        for v, b in vs.items():
            if detect(codec, b, len(b)) != 1:
                with open(os.path.join(dst, fmt, v + '_' + name), 'wb') as f:
                    f.write(b)
                break

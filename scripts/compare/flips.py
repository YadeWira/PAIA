# flips.py TOOL N: N single-bit flips in each sample's compressed file;
# counts how each decompression ends: refused (error or no output), the
# original, or a wrong file given back without an error.
import os, random, subprocess, sys, tempfile, concurrent.futures as cf
T = os.environ['TOOLS']
PAIA = os.environ['PAIA']
S = os.path.join(os.environ['SETS'], 'gif')
FILES = ['input.gif', 'athome.gif', '062669.gif', '591fw30.gif', '89aillus.gif']
tool, n = sys.argv[1], int(sys.argv[2])
def comp(src, out):
    if tool == 'paia': cmd = [PAIA, 'a', '-q', '--no-sync', src, '-o', out]
    elif tool == 'precomp': cmd = [T + '/precomp-cpp/build/precomp', '-o' + out, src]
    else: cmd = [T + '/paq8px/build/paq8px', '-8', src, out]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=os.path.dirname(out))
    assert os.path.exists(out)
def decomp(c, out):
    if tool == 'paia': cmd = [PAIA, 'x', '-q', '--no-sync', c, '-o', out]
    elif tool == 'precomp': cmd = [T + '/precomp-cpp/build/precomp', '-r', '-o' + out, c]
    else: cmd = [T + '/paq8px/build/paq8px', '-d', c, out]
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120, stdin=subprocess.DEVNULL, cwd=os.path.dirname(out)).returncode
    except subprocess.TimeoutExpired:
        return -1
def one(args):
    d, orig, comp_bytes, bit = args
    with tempfile.TemporaryDirectory(dir=d) as w:
        b = bytearray(comp_bytes); b[bit // 8] ^= 1 << (bit % 8)
        c = os.path.join(w, 'c.' + {'paia': 'paia', 'precomp': 'pcf', 'paq8px': 'p'}[tool])
        open(c, 'wb').write(b)
        out = os.path.join(w, 'back.gif')
        rc = decomp(c, out)
        if not os.path.exists(out): return 'refused'
        got = open(out, 'rb').read()
        if got == orig: return 'original' if rc == 0 else 'original, rc %d' % rc
        return 'wrong' if rc == 0 else 'wrong, but rc %d' % rc
base = tempfile.mkdtemp(dir=os.environ['WORK'])
jobs = []
rnd = random.Random(1)
for f in FILES:
    src = os.path.join(base, f)
    orig = open(os.path.join(S, f), 'rb').read(); open(src, 'wb').write(orig)
    c = os.path.join(base, f + '.c')
    comp(src, c)
    cb = open(c, 'rb').read()
    for _ in range(n): jobs.append((base, orig, cb, rnd.randrange(len(cb) * 8)))
counts = {}
with cf.ThreadPoolExecutor(12) as ex:
    for r in ex.map(one, jobs): counts[r] = counts.get(r, 0) + 1
print(tool, len(jobs), counts)

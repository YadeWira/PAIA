# fuzz.py TOOL N: N damaged GIFs (1 to 8 random bytes changed in one of the
# small samples): compressed and decompressed; counts those taken (rc 0)
# that do not come back byte for byte.
import os, random, subprocess, sys, tempfile, concurrent.futures as cf
T = os.environ['TOOLS']
PAIA = os.environ['PAIA']
S = os.path.join(os.environ['SETS'], 'gif')
FILES = ['input.gif', 'athome.gif', '062669.gif', '591fw30.gif', '89aillus.gif', 'bugs.gif', 'congrats.gif']
tool, n = sys.argv[1], int(sys.argv[2])
def run(cmd, cwd):
    try: return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                               timeout=300, cwd=cwd).returncode
    except subprocess.TimeoutExpired: return -1
def one(k):
    rnd = random.Random(k)
    d = bytearray(open(os.path.join(S, FILES[k % len(FILES)]), 'rb').read())
    for _ in range(rnd.randint(1, 8)): d[rnd.randrange(len(d))] = rnd.randrange(256)
    with tempfile.TemporaryDirectory(dir=os.environ['WORK']) as w:
        src = os.path.join(w, 'f.gif'); open(src, 'wb').write(d)
        c = os.path.join(w, 'c'); back = os.path.join(w, 'back.gif')
        if tool == 'paia':
            rc = run([PAIA, 'a', '-q', '--no-sync', src, '-o', c], w)
            if rc == 0: run([PAIA, 'x', '-q', '--no-sync', c, '-o', back], w)
        elif tool == 'precomp':
            rc = run([T + '/precomp-cpp/build/precomp', '-o' + c, src], w); c += '.pcf'
            if os.path.exists(c): rc = 0; run([T + '/precomp-cpp/build/precomp', '-r', '-o' + back, c], w)
        else:
            rc = run([T + '/paq8px/build/paq8px', '-8', src, c], w)
            if rc == 0: run([T + '/paq8px/build/paq8px', '-d', c, back], w)
        if rc != 0: return 'refused'
        if os.path.exists(back) and open(back, 'rb').read() == bytes(d): return 'back'
        return 'NOT BACK'
counts = {}
with cf.ThreadPoolExecutor(12) as ex:
    for r in ex.map(one, range(n)): counts[r] = counts.get(r, 0) + 1
print(tool, n, counts)

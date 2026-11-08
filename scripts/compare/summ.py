import sys, collections
rows = [l.rstrip('\n').split('\t') for f in sys.argv[1:] for l in open(f) if l.strip()]
tot = collections.defaultdict(lambda: [0, 0, 0.0, 0.0, 0, 0])
for s, f, t, i, o, c, d, ok in rows:
    r = tot[(s, t)]; r[0] += int(i); r[1] += int(o); r[2] += float(c); r[3] += float(d); r[4] += 1; r[5] += int(ok)
tools = ['paia', 'precomp', 'paq8px', 'xz', '7z', 'zstd', 'brotli', 'bzip3', 'zpaq']
for s in ['gif', 'flic', 'ani', 'anim', 'webp']:
    line = [s]
    for t in tools:
        if (s, t) in tot:
            r = tot[(s, t)]
            line.append('%s %.2f%% (%d/%d ok) c%.0fs d%.0fs' % (t, 100 * r[1] / r[0], r[5], r[4], r[2], r[3]))
    print('\n  '.join(line))

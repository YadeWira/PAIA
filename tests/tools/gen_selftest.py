"""Writes pas/paiaselftest.inc: the samples `paia selftest` carries inside
the binary, and the .paia each has to give (made by the paia binary given,
which must be a build whose output is current: every build writes the same
bytes, which the tests check).

    python3 -I tests/tools/gen_selftest.py PAIA_BINARY

The samples are small ones of tests/, one or more a format: a GIF
animation, a FLIC with every chunk kind, an ANI with repeated frames, an
IFF ANIM in XOR mode, and a lossy WebP with lossless alpha (VP8 and VP8L).
Run it again only when the codec stream changes, and say so in CODEC.md.
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SAMPLES = [
    ('gif', 'tests/gif/anim_optimized.gif'),
    ('flic', 'tests/fli/synth_mixed.flc'),
    ('ani', 'tests/ani/repeated.ani'),
    ('anim', 'tests/anim/delta5_xor.anim'),
    ('webp', 'tests/webp/sprite_lossy_alpha.webp'),
]


def pascal_bytes(name, data):
    lines = []
    for i in range(0, len(data), 24):
        lines.append('    ' + ', '.join('$%02X' % b for b in data[i:i + 24]))
    return '  %s: array[0..%d] of Byte = (\n%s);\n' % (name, len(data) - 1, ',\n'.join(lines))


def main():
    paia = os.path.abspath(sys.argv[1])
    out = []
    names, exts = [], []
    with tempfile.TemporaryDirectory() as tmp:
        for k, (name, rel) in enumerate(SAMPLES):
            src = os.path.join(ROOT, rel)
            data = open(src, 'rb').read()
            subprocess.run([paia, 'a', '-q', '-f', '-o', tmp + '/', src], check=True)
            base = os.path.splitext(os.path.basename(src))[0]
            want = open(os.path.join(tmp, base + '.paia'), 'rb').read()
            out.append(pascal_bytes('SAMPLE%d' % k, data))
            out.append(pascal_bytes('EXPECT%d' % k, want))
            names.append(name + ' (' + os.path.basename(src) + ')')
            exts.append(os.path.splitext(src)[1][1:])
    n = len(SAMPLES)
    text = ['{ The samples of paia selftest and the .paia each has to give.',
            '  Written by tests/tools/gen_selftest.py: do not edit. }',
            'const',
            '  SELFTEST_COUNT = %d;' % n,
            '  SELFTEST_NAMES: array[0..%d] of string = (%s);' % (n - 1, ', '.join("'%s'" % s for s in names)),
            '  SELFTEST_EXTS: array[0..%d] of string = (%s);' % (n - 1, ', '.join("'%s'" % s for s in exts)),
            ''.join(out),
            'procedure SelftestSample(k: Integer; out data, want: TBytes);',
            '  procedure Take(const a: array of Byte; out b: TBytes);',
            '  begin',
            '    b := nil; SetLength(b, Length(a));',
            '    if Length(a) > 0 then Move(a[0], b[0], Length(a));',
            '  end;',
            'begin',
            '  case k of']
    for k in range(n):
        text.append('    %d: begin Take(SAMPLE%d, data); Take(EXPECT%d, want); end;' % (k, k, k))
    text += ['  else begin data := nil; want := nil; end;', '  end;', 'end;', '']
    open(os.path.join(ROOT, 'pas', 'paiaselftest.inc'), 'w').write('\n'.join(text))


if __name__ == '__main__':
    main()

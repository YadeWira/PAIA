#!/bin/bash
# The paia command, from the outside: round trips, and each refusal with
# nothing written where it must not be. From PJA's pas/tests/cli.sh (the
# same family): the same cases, with PAIA's formats.
#
#   tests/cli.sh <paia binary> <work directory>
set -uo pipefail
PAIA=$(realpath "$1"); W=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cells=0; failures=0
check() {   # check <description> <command...>: the command has to succeed
  local what=$1; shift
  cells=$((cells + 1))
  if "$@" > /dev/null 2>&1; then printf '  %-70s ok\n' "$what"
  else printf '  %-70s FAIL\n' "$what"; failures=$((failures + 1)); fi
}
rc() { "$@" > /dev/null 2>&1; echo $?; }

rm -rf "$W"; mkdir -p "$W/in" "$W/out"
# one name a file: truncated.gif and truncated.ani would both be truncated.paia
for d in gif fli ani anim webp; do
  for f in "$ROOT/tests/$d"/*; do b=$(basename "$f"); cp "$f" "$W/in/${b%.*}_$d.${b##*.}"; done
done
n=$(ls "$W/in" | wc -l)
check "samples: $n files" test "$n" -ge 30
G=$W/in/ffmpeg_anim_gif.gif

echo "--- round trip of every sample"
check "a, all at once, into a directory" "$PAIA" a -q "$W"/in/* -o "$W/paia/"
check "  one .paia per input" test "$(ls "$W/paia" | wc -l)" -eq "$n"
check "x, all at once" "$PAIA" x -q "$W"/paia/*.paia -o "$W/out/"
same=0
for f in "$W"/in/*; do cmp -s "$f" "$W/out/$(basename "$f")" && same=$((same + 1)); done
check "  every file back byte for byte, with its extension ($same of $n)" test "$same" -eq "$n"
check "the same .paia with 1 thread and with 4" bash -c "
  '$PAIA' a -q -th 1 '$W'/in/* -o '$W/t1/' && '$PAIA' a -q --threads=4 '$W'/in/* -o '$W/t4/' &&
  for f in '$W'/t1/*.paia; do cmp -s \"\$f\" '$W/t4/'\$(basename \"\$f\") || exit 1; done"
check "with -th 4 and several files, the lines follow the input order" bash -c "
  '$PAIA' a -th 4 -f '$W'/in/*.gif -o '$W/ord/' | sed 's/ ->.*//' > '$W/ord.txt' &&
  ls '$W'/in/*.gif > '$W/ord_in.txt' && cmp -s '$W/ord.txt' '$W/ord_in.txt'"
check "--no-verify: the very same .paia" bash -c "
  '$PAIA' a -q -f '$G' -o '$W/v1.paia' && '$PAIA' a -q -f --no-verify '$G' -o '$W/v2.paia' && cmp -s '$W/v1.paia' '$W/v2.paia'"
check "--no-verify with x: rc 2" test "$(rc "$PAIA" x --no-verify "$W/v1.paia" -o "$W/nv.gif")" -eq 2
head -c 3000 /dev/urandom > "$W/noise.bin"
check "a file the codec cannot shrink is stored as is, and says so" bash -c "
  '$PAIA' a -f '$W/noise.bin' -o '$W/st.paia' | grep -q 'stored as is' && '$PAIA' list '$W/st.paia' | grep -q 'stored as is' &&
  '$PAIA' x -q '$W/st.paia' -o '$W/st.bin' && cmp -s '$W/noise.bin' '$W/st.bin'"
check "the line says what the codec took" bash -c "'$PAIA' a -f '$G' -o '$W/r.paia' | grep -q '(5 of 5 GIF images)'"
check "the extension comes back as written (Anim.GIF, x.Webp)" bash -c "
  cp '$G' '$W/Anim.GIF' && cp '$W/in/sprite_lossless_webp.webp' '$W/x.Webp' &&
  '$PAIA' a -q -f '$W/Anim.GIF' '$W/x.Webp' -o '$W/ext/' && '$PAIA' x -q '$W'/ext/*.paia -o '$W/extx/' &&
  cmp -s '$G' '$W/extx/Anim.GIF' && cmp -s '$W/in/sprite_lossless_webp.webp' '$W/extx/x.Webp'"
check "an extension the format does not keep: by the content (.gif, .flc, .ani, .anim, .webp)" bash -c "
  for s in ffmpeg_anim_gif.gif synth_mixed_fli.flc repeated_ani.ani delta5_anim.anim sprite_lossless_webp.webp; do
    cp '$W/in/'\$s '$W/odd.x.y z' && '$PAIA' a -q -f '$W/odd.x.y z' -o '$W/odd.paia' &&
    rm -rf '$W/oddx' && '$PAIA' x -q '$W/odd.paia' -o '$W/oddx/' && cmp -s '$W/in/'\$s '$W/oddx/odd.'\${s#*.} || exit 1
  done"
check "an empty file, both ways" bash -c "
  : > '$W/empty.gif' && '$PAIA' a -q -f '$W/empty.gif' && '$PAIA' list '$W/empty.paia' &&
  rm '$W/empty.gif' && '$PAIA' x -q '$W/empty.paia' && [ -e '$W/empty.gif' ] && [ ! -s '$W/empty.gif' ]"
check "list shows the original size" bash -c "'$PAIA' list '$W/paia/ffmpeg_anim_gif.paia' | grep -q 'original $(wc -c < "$G" | tr -d ' ') B'"

echo "--- existing outputs"
cp "$W/paia/grad_gif.paia" "$W/g.paia"
echo old > "$W/g.gif"
check "x over an existing file: refused (rc 1)" test "$(rc "$PAIA" x "$W/g.paia")" -eq 1
check "  and the file is untouched" test "$(cat "$W/g.gif")" = old
check "with -f: replaced" "$PAIA" x -q -f "$W/g.paia"
check "  by the original" cmp -s "$W/g.gif" "$W/in/grad_gif.gif"
echo victim > "$W/victim"; rm -f "$W/g.gif"; ln -s "$W/victim" "$W/g.gif"
check "a symbolic link with the output's name: refused" test "$(rc "$PAIA" x "$W/g.paia")" -eq 1
check "  with -f, the link is replaced" bash -c "'$PAIA' x -q -f '$W/g.paia' && [ ! -L '$W/g.gif' ]"
check "  and its target never written through" test "$(cat "$W/victim")" = victim
rm -f "$W/g.gif"; ln -s "$W/nowhere" "$W/g.gif"
check "a dangling link also takes the name" test "$(rc "$PAIA" x "$W/g.paia")" -eq 1
check "  and nothing is created where it points" test ! -e "$W/nowhere"
rm -f "$W/g.gif"
check "cut short while writing (ulimit -f): nothing under the output's name" bash -c "
  rm -rf '$W/cut'; mkdir '$W/cut'; (ulimit -f 1; trap '' XFSZ; '$PAIA' x -q '$W/paia/interlaced_gif.paia' -o '$W/cut/') ; [ -z \"\$(ls -A '$W/cut')\" ]"
check "-n with an existing output: refused like the real run (rc 1)" test "$(rc "$PAIA" a -n "$W/in/grad_gif.gif" -o "$W/g.paia")" -eq 1

echo "--- two inputs, one output"
mkdir -p "$W/dup"; cp "$W/in/grad_gif.gif" "$W/dup/a.gif"; cp "$G" "$W/dup/a.GIF"
check "a -f a.gif a.GIF: the later one fails, rc 1" bash -c "
  '$PAIA' a -q -f '$W/dup/a.gif' '$W/dup/a.GIF' 2> '$W/dup.txt'; [ \$? -eq 1 ] && grep -q 'also the output of' '$W/dup.txt'"
check "  and a.paia holds a.gif" bash -c "'$PAIA' list '$W/dup/a.paia' | grep -q 'original $(wc -c < "$W/in/grad_gif.gif" | tr -d ' ') B'"
mkdir -p "$W/dup2"; cp "$W/in/grad_gif.gif" "$W/dup2/a.gif"
check "--output-dir with the same name from two folders: rc 1, one written" bash -c "
  '$PAIA' a -q -f '$W/dup/a.gif' '$W/dup2/a.gif' --output-dir='$W/dupo'; [ \$? -eq 1 ] && [ \$(ls '$W/dupo' | wc -l) -eq 1 ]"
check "x -f with the same output twice: rc 1" test "$(rc "$PAIA" x -f "$W/paia/grad_gif.paia" "$W/paia/grad_gif.paia" -o "$W/dupx/")" -eq 1
check "an output that is another input (a GIF named q.paia): refused" bash -c "
  cp '$W/in/grad_gif.gif' '$W/q.paia' && cp '$W/in/grad_gif.gif' '$W/q.gif' &&
  ! '$PAIA' a -f -th 1 '$W/q.gif' '$W/q.paia' 2> '$W/q.txt' && grep -q 'q.paia: also an input' '$W/q.txt'"
check "x -th 8 of 24 files into one folder, 5 times: no job trips on another's temporary" bash -c "
  mkdir -p '$W/many' && for i in \$(seq 24); do cp '$W/paia/ffmpeg_anim_gif.paia' '$W/many/m'\$i.paia; done &&
  for r in 1 2 3 4 5; do '$PAIA' x -q -f -th 8 '$W'/many/*.paia -o '$W/manyx/' || exit 1; done &&
  [ \$(ls '$W/manyx' | wc -l) -eq 24 ] && [ -z \"\$(ls -A '$W/manyx' | grep tmp)\" ]"
check "a backslash is part of the name on Unix: a\\x.gif and b\\x.gif" bash -c "
  cp '$W/in/grad_gif.gif' '$W/a\\x.gif' && cp '$G' '$W/b\\x.gif' && '$PAIA' a -q -f '$W/a\\x.gif' '$W/b\\x.gif' &&
  [ -e '$W/a\\x.paia' ] && [ -e '$W/b\\x.paia' ]"

echo "--- what does not verify"
python3 -I -c "
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
h = bytearray(d); h[16] ^= 1; open(sys.argv[2], 'wb').write(h)
p = bytearray(d); p[-5] ^= 0x10; open(sys.argv[3], 'wb').write(p)" "$W/paia/ffmpeg_anim_gif.paia" "$W/h.paia" "$W/p.paia"
check "a .paia with one hash bit changed: rc 1" test "$(rc "$PAIA" x "$W/h.paia")" -eq 1
check "  nothing written under the name" test ! -e "$W/h.gif"
check "with --keep-corrupt: still rc 1" test "$(rc "$PAIA" x --keep-corrupt "$W/h.paia")" -eq 1
check "  kept as h.gif.corrupt, not as h.gif" bash -c "[ -e '$W/h.gif.corrupt' ] && [ ! -e '$W/h.gif' ]"
check "one bit in the stream: rc 1, nothing written" bash -c "! '$PAIA' x '$W/p.paia' 2>/dev/null && [ ! -e '$W/p.gif' ]"
check "x -n on a .paia whose hash does not match: rc 1" test "$(rc "$PAIA" x -n "$W/h.paia")" -eq 1
check "--max-output below the original: refused" test "$(rc "$PAIA" x --max-output=100 "$W/g.paia" -o "$W/m.gif")" -eq 1
check "  nothing written" test ! -e "$W/m.gif"
check "--max-output=1K is enough for an 804-byte original" "$PAIA" x -q --max-output=1K "$W/g.paia" -o "$W/m.gif"
python3 -I -c "
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[8:16] = (1 << 40).to_bytes(8, 'little'); open(sys.argv[2], 'wb').write(d)" "$W/g.paia" "$W/bomb.paia"
check "a .paia declaring 1 TB in 250 bytes: refused at once" bash -c "
  ! timeout 10 '$PAIA' x --max-output=0 '$W/bomb.paia' -o '$W/bomb.gif' 2>/dev/null && [ ! -e '$W/bomb.gif' ]"

echo "--- interrupted runs, and the disk"
mkdir -p "$W/sig"
for i in $(seq 24); do cp "$W/paia/interlaced_gif.paia" "$W/sig/c$i.paia"; done
HOLD=0
if command -v strace > /dev/null 2>&1 &&
   strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:delay_enter=1ms true > /dev/null 2>&1; then HOLD=1; fi
cat > "$W/sig.py" <<'EOF'
import glob, os, signal, subprocess, sys, time
paia, d, sig, hold, ignore = sys.argv[1], sys.argv[2], getattr(signal, sys.argv[3]), sys.argv[4] == '1', sys.argv[5] == '1'
out = os.path.join(d, 'o')
files = sorted(glob.glob(os.path.join(d, 'c*.paia')))[:1 if ignore else None]
cmd = [paia, 'x', '-q', '-f', '-th', '1'] + files + ['-o', out + '/']
if hold:
    cmd = ['strace', '-f', '-qq', '-o', '/dev/null', '-e', 'trace=fsync', '-e', 'inject=fsync:delay_enter=3s'] + cmd
def pre():
    signal.signal(sig, signal.SIG_IGN if ignore else signal.SIG_DFL)
p = subprocess.Popen(cmd, preexec_fn=pre)
def state(pid):
    try: return open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()[0]
    except (OSError, IndexError): return ''
seen, t0 = False, time.time()
while time.time() - t0 < 120 and p.poll() is None:
    if glob.glob(os.path.join(out, '.paia-tmp-*')): seen = True; break
    time.sleep(0.005)
target = p.pid
if hold and seen and p.poll() is None:
    target = int(open('/proc/%d/task/%d/children' % (p.pid, p.pid)).read().split()[0])
    run, t1 = 0, time.time()
    while run < 5 and time.time() - t1 < 60 and p.poll() is None:
        run = run + 1 if state(target) == 't' else 0
        time.sleep(0.02)
if p.poll() is None: os.kill(target, sig)
rc = p.wait()
rc = 128 - rc if rc < 0 else rc
left = glob.glob(os.path.join(out, '.paia-tmp-*'))
print(rc, 'seen' if seen else 'missed', len(left))
EOF
sigcheck() {   # sigcheck <signal> <rc> [ignore]: no temporary left, and the conventional rc
  rm -rf "$W/sig/o"
  local r; r=$(python3 -I "$W/sig.py" "$PAIA" "$W/sig" "$1" "$HOLD" "${3:-0}") || return 1
  set -- $r "$2"
  [ "$3" -eq 0 ] || return 1
  if [ "$HOLD" = 1 ]; then [ "$2" = seen ] && [ "$1" -eq "$4" ]
  else [ "$1" -eq "$4" ] || [ "$1" -eq 0 ]; fi
}
if [ "$HOLD" = 1 ]; then how="held at its fsync"; else how="strace not here: racy"; fi
check "SIGINT while a temporary is written: deleted, rc 130 ($how)" sigcheck SIGINT 130
check "SIGTERM: the same, rc 143" sigcheck SIGTERM 143
check "SIGHUP: the same, rc 129" sigcheck SIGHUP 129
check "SIGPIPE: the same, rc 141" sigcheck SIGPIPE 141
if [ "$HOLD" = 1 ]; then
  check "a SIGINT ignored by whoever started it (nohup) stays ignored: rc 0" bash -c "
    r=\$(python3 -I '$W/sig.py' '$PAIA' '$W/sig' SIGINT 1 1) && [ \"\$r\" = '0 seen 0' ] && [ -e '$W/sig/o/c1.gif' ]"
  check "the data and then the directory reach the disk: fsync, rename, fsync" bash -c "
    strace -f -qq -o '$W/sync.txt' -e trace=fsync,rename,renameat2,link '$PAIA' a -q -f '$G' -o '$W/sync.paia' &&
    grep -oE '^[0-9]+ +(fsync|rename|renameat2|link)\(' '$W/sync.txt' | sed -E 's/^[0-9]+ +//; s/renameat2|link/rename/' | tr -d '(' |
      tr '\n' ' ' | grep -qx 'fsync rename fsync '"
  check "the directory flush fails: rc 1, and the message says the file is there" bash -c "
    rm -f '$W/sync4.paia'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=2 '$PAIA' a -q '$G' -o '$W/sync4.paia' 2> '$W/sync4.txt' &&
    grep -q 'sync4.paia: written, but its directory could not be flushed to the disk' '$W/sync4.txt' && [ -s '$W/sync4.paia' ]"
  check "  the data flush fails: rc 1, nothing left, not even a temporary" bash -c "
    rm -rf '$W/sync5'; mkdir '$W/sync5'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=1 '$PAIA' a -q '$G' -o '$W/sync5/g.paia' 2> '$W/sync5.txt' &&
    grep -q 'could not write it' '$W/sync5.txt' && [ -z \"\$(ls -A '$W/sync5')\" ]"
  check "--no-sync: no fsync at all, and the file comes back" bash -c "
    strace -f -qq -o '$W/sync3.txt' -e trace=fsync,fdatasync '$PAIA' a -q -f --no-sync '$G' -o '$W/sync3.paia' &&
    ! grep -qE 'fsync|fdatasync' '$W/sync3.txt' && '$PAIA' x -q -f '$W/sync3.paia' -o '$W/sync3.gif' && cmp -s '$W/sync3.gif' '$G'"
else
  check "--no-sync: the file comes back" bash -c "
    '$PAIA' a -q -f --no-sync '$G' -o '$W/sync3.paia' && '$PAIA' x -q -f --no-sync '$W/sync3.paia' -o '$W/sync3.gif' &&
    cmp -s '$W/sync3.gif' '$G'"
fi
L="$W/left"; rm -rf "$L"; mkdir -p "$L"; cp "$W/in/grad_gif.gif" "$L/g.gif"
sh -c 'exit 0' & wait $!; DEAD=$!
while kill -0 "$DEAD" 2> /dev/null; do DEAD=$((DEAD + 1)); done
mk() { echo left > "$L/$1"; touch -d "${2:-2 hours ago}" "$L/$1"; }
mk ".paia-tmp-$DEAD-0"                                # old, of a dead run
mk ".paia-tmp-$DEAD-1" now                            # fresh: maybe still being written
mk ".paia-tmp-$$-0"                                   # old, but its process (this shell) lives
mk ".paia-tmp-$DEAD-x"; mk ".paia-tmp4"               # not PAIA's pattern
echo victim > "$W/left_victim"; ln -s "$W/left_victim" "$L/.paia-tmp-$DEAD-2"; touch -h -d '2 hours ago' "$L/.paia-tmp-$DEAD-2"
check "a run that writes there names the leftover, rc 0, deletes nothing" bash -c "
  '$PAIA' a -q '$L/g.gif' 2> '$W/left.txt' && grep -q 'found 1 leftover temporar' '$W/left.txt' &&
  grep -q -- '--clean-temps' '$W/left.txt' && [ -e '$L/.paia-tmp-$DEAD-0' ]"
check "--clean-temps deletes the old one of a dead pid" bash -c "
  '$PAIA' a -q -f --clean-temps '$L/g.gif' 2> '$W/left2.txt' && grep -q 'deleted 1 leftover temporar' '$W/left2.txt' &&
  [ ! -e '$L/.paia-tmp-$DEAD-0' ]"
check "  not a fresh one, not a live process's, not another name" bash -c "
  [ -e '$L/.paia-tmp-$DEAD-1' ] && [ -e '$L/.paia-tmp-$$-0' ] && [ -e '$L/.paia-tmp-$DEAD-x' ] && [ -e '$L/.paia-tmp4' ]"
check "  not a symbolic link with the name, nor its target" bash -c "
  [ -L '$L/.paia-tmp-$DEAD-2' ] && [ \"\$(cat '$W/left_victim')\" = victim ]"
check "a run with nothing left there says nothing" bash -c "
  '$PAIA' a -q -f --clean-temps '$L/g.gif' 2> '$W/left3.txt' && [ ! -s '$W/left3.txt' ]"
check "--clean-temps with list: rc 2" test "$(rc "$PAIA" list --clean-temps "$W/g.paia")" -eq 2
check "--no-sync with list: rc 2" test "$(rc "$PAIA" list --no-sync "$W/g.paia")" -eq 2

echo "--- what is not for this command"
check "a on a .paia: rc 1" test "$(rc "$PAIA" a "$W/g.paia" -o "$W/gg.paia")" -eq 1
check "x on a GIF: rc 1" test "$(rc "$PAIA" x "$W/in/grad_gif.gif" -o "$W/xx.gif")" -eq 1
check "one bad among good ones: rc 1" test "$(rc "$PAIA" x "$W/in/grad_gif.gif" "$W/g.paia" -o "$W/mix/")" -eq 1
check "  and the good one is written" test -e "$W/mix/g.gif"
check "a directory as input: rc 1" test "$(rc "$PAIA" a "$W/in")" -eq 1
check "a missing input: rc 1" test "$(rc "$PAIA" a "$W/missing.gif")" -eq 1

echo "--- options"
check "-n writes nothing" bash -c "'$PAIA' a -q -n '$W/in/grad_gif.gif' -o '$W/dry.paia' && [ ! -e '$W/dry.paia' ]"
cp "$W/in/grad_gif.gif" "$W/-dash.gif"
check "-- and a file that starts with a dash" bash -c "cd '$W' && '$PAIA' a -q -- -dash.gif && [ -e '-dash.paia' ]"
check "-o with several inputs and no directory: rc 2" test "$(rc "$PAIA" a "$W/in/grad_gif.gif" "$G" -o "$W/one.paia")" -eq 2
cp "$G" "$W/動画ñ.gif"
check "a non-ASCII name, both ways" bash -c "'$PAIA' a -q '$W/動画ñ.gif' -o '$W/u.paia' && '$PAIA' x -q '$W/u.paia' -o '$W/動画ñ2.gif' &&
  cmp -s '$W/動画ñ2.gif' '$G'"
check "--output-dir" bash -c "'$PAIA' a -q '$W/in/grad_gif.gif' --output-dir='$W/od' && [ -e '$W/od/grad_gif.paia' ]"
check "-o and --output-dir together: rc 2" test "$(rc "$PAIA" a "$G" -o "$W/a.paia" --output-dir="$W/od")" -eq 2
check "an unknown option: rc 2" test "$(rc "$PAIA" a --frobnicate "$G")" -eq 2
check "a glued -th4: rc 2, naming the spelling" bash -c "'$PAIA' a -th4 x.gif 2>&1 | grep -q 'write -th 4'"
check "-th 0: rc 2" test "$(rc "$PAIA" a -th 0 "$G")" -eq 2
check "an unknown command: rc 2" test "$(rc "$PAIA" mix "$G")" -eq 2
check "no files: rc 2" test "$(rc "$PAIA" a)" -eq 2
check "nothing at all: rc 2" test "$(rc "$PAIA")" -eq 2
check "--help: rc 0" "$PAIA" --help

echo "--- version, selftest, --cpu"
check "--version: the build, the compilers, the model's path" bash -c "
  '$PAIA' --version > '$W/v.txt' && grep -q '^paia [0-9]' '$W/v.txt' && grep -q '^fpc: ' '$W/v.txt' &&
  grep -q '^c_compiler: ' '$W/v.txt' && grep -q '^cpu_path: ' '$W/v.txt'"
check "-V: the same" bash -c "[ \"\$('$PAIA' -V)\" = \"\$('$PAIA' --version)\" ]"
check "selftest: every check passed, rc 0" bash -c "'$PAIA' selftest | grep -q 'checks passed'"
check "selftest -q: the summary alone" bash -c "[ \$('$PAIA' selftest -q | wc -l) -eq 1 ]"
PATHS=$("$PAIA" --version | sed -n 's/^cpu_paths_supported: //p')
check "--cpu: every path here ($PATHS) gives the very same .paia, and x takes it back" bash -c "
  for p in $PATHS; do
    '$PAIA' --cpu=\$p a -q -f '$W'/in/*.gif -o '$W/cpu_'\$p/ || exit 1
    for f in '$W'/cpu_\$p/*.paia; do cmp -s \"\$f\" '$W/paia/'\$(basename \"\$f\") || exit 1; done
    '$PAIA' x -q --cpu=\$p '$W'/cpu_\$p/*.paia -o '$W/cpux_'\$p/ || exit 1
  done"
check "selftest --cpu=pascal: that path alone" bash -c "'$PAIA' selftest --cpu=pascal -q | grep -q 'on 1 path(s) (pascal)'"
check "--cpu with a path that is no path: rc 2" test "$(rc "$PAIA" --cpu=avx512 selftest)" -eq 2
check "--cpu c (a space): rc 2, naming --cpu=c" bash -c "'$PAIA' selftest --cpu c 2>&1 | grep -q 'write --cpu=c'"
check "selftest with a file: rc 2" test "$(rc "$PAIA" selftest "$G")" -eq 2
check "--no-sync with selftest: rc 2" test "$(rc "$PAIA" selftest --no-sync)" -eq 2

echo "--- t"
mkdir -p "$W/t"; cp "$W/paia/grad_gif.paia" "$W/paia/ffmpeg_anim_gif.paia" "$W/t/"; cp "$W/p.paia" "$W/t/damaged.paia"
check "t: OK for each good .paia, rc 0" bash -c "
  [ \$('$PAIA' t '$W/t/grad_gif.paia' '$W/t/ffmpeg_anim_gif.paia' | grep -c ': OK ') -eq 2 ]"
check "t -q -th 4: nothing printed, rc 0" bash -c "[ -z \"\$('$PAIA' t -q -th 4 '$W/t/grad_gif.paia' '$W/t/ffmpeg_anim_gif.paia')\" ]"
check "t on a damaged .paia: FAILED, rc 1" bash -c "
  '$PAIA' t '$W/t/damaged.paia' 2> '$W/td.txt'; [ \$? -eq 1 ] && grep -q 'FAILED' '$W/td.txt'"
check "  and t wrote nothing" test "$(ls "$W/t" | wc -l)" -eq 3
check "t on a GIF: rc 1" test "$(rc "$PAIA" t "$W/in/grad_gif.gif")" -eq 1
check "t -o: rc 2 (t writes nothing)" test "$(rc "$PAIA" t -o "$W/t/x" "$W/t/grad_gif.paia")" -eq 2
check "t --max-output below the original: rc 1" test "$(rc "$PAIA" t --max-output=100 "$W/t/grad_gif.paia")" -eq 1

echo "--- info"
check "info on a GIF: its images, and that PAIA takes it" bash -c "
  '$PAIA' info '$G' > '$W/i.txt' && grep -q 'format: GIF' '$W/i.txt' && grep -q 'images: 5' '$W/i.txt' && grep -q 'paia: takes it' '$W/i.txt'"
check "info on a FLC: its chunks by type" bash -c "'$PAIA' info '$W/in/synth_mixed_fli.flc' | grep -q 'DELTA_FLC: 2'"
check "info on an ANI, an IFF ANIM, a WebP" bash -c "
  '$PAIA' info '$W/in/repeated_ani.ani' | grep -q 'format: ANI' && '$PAIA' info '$W/in/delta5_anim.anim' | grep -q 'format: IFF ANIM' &&
  '$PAIA' info '$W/in/sprite_lossy_alpha_webp.webp' | grep -q 'vp8_frames: '"
check "info on a .paia: the container and its stream" bash -c "
  '$PAIA' info '$W/g.paia' > '$W/ip.txt' && grep -q 'container:' '$W/ip.txt' && grep -q 'extracts it' '$W/ip.txt'"
check "info on a damaged .paia: does not extract it, rc 0" bash -c "'$PAIA' info '$W/t/damaged.paia' | grep -q 'does not extract it'"
check "info on a .paia declaring more than --max-output: not decoded, at once" bash -c "
  timeout 10 '$PAIA' info '$W/bomb.paia' > /dev/null"
check "info on a missing file: rc 1" test "$(rc "$PAIA" info "$W/missing.gif")" -eq 1

echo "--- report"
cp "$G" "$W/private.gif"
check "report: the system, the file's hash, its structure, what PAIA does" bash -c "
  '$PAIA' report '$W/private.gif' > '$W/rep.txt' && grep -q '^== PAIA and the system' '$W/rep.txt' &&
  grep -q 'blake3_128: ' '$W/rep.txt' && grep -q 'format: GIF' '$W/rep.txt' && grep -q 'github.com/YadeWira/PAIA/issues/new' '$W/rep.txt'"
check "  privacy: the file's name, never its folders" bash -c "! grep -q '$W' '$W/rep.txt'"
check "report -o: the report in that file, the link on the screen" bash -c "
  '$PAIA' report '$W/private.gif' -o '$W/r.txt' > '$W/r_screen.txt' && grep -q '^== PAIA and the system' '$W/r.txt' &&
  grep -q 'issues/new' '$W/r_screen.txt'"
check "  an existing report is not replaced: rc 1" test "$(rc "$PAIA" report "$W/private.gif" -o "$W/r.txt")" -eq 1
check "report --with-file: the file copied beside the report, byte for byte" bash -c "
  rm -rf '$W/rw'; mkdir '$W/rw' && '$PAIA' report '$W/private.gif' -o '$W/rw/r.txt' --with-file > /dev/null &&
  f=\$(ls '$W/rw' | grep -v r.txt) && cmp -s '$W/rw/'\$f '$G'"
check "report with no file: rc 0" bash -c "'$PAIA' report | grep -q '^== PAIA and the system'"
check "report with two files: rc 2" test "$(rc "$PAIA" report "$W/private.gif" "$G")" -eq 2
check "--with-file is for report: rc 2" test "$(rc "$PAIA" a --with-file "$W/private.gif")" -eq 2
check "report --with-file without a file: rc 2" test "$(rc "$PAIA" report --with-file)" -eq 2

echo "--- --stats and --json"
mkdir -p "$W/st"
check "a --stats: each stage and a summary" bash -c "
  '$PAIA' a -f --stats '$G' -o '$W/st/' > '$W/sta.txt' && grep -q 'stats: .*encode' '$W/sta.txt' && grep -q 'file(s)' '$W/sta.txt'"
check "x --stats: decode and hash" bash -c "'$PAIA' x -f --stats '$W/st/ffmpeg_anim_gif.paia' -o '$W/st/' | grep -q 'decode .*hash'"
check "-q --stats: each stats line under its file's name" bash -c "
  '$PAIA' t -q --stats '$W/st/ffmpeg_anim_gif.paia' | head -1 | grep -q 'ffmpeg_anim_gif.paia:'"
check "--stats is not for list: rc 2" test "$(rc "$PAIA" list --stats "$W/g.paia")" -eq 2
JS='
import json, sys
lines = [json.loads(l) for l in sys.stdin.read().splitlines()]
want = int(sys.argv[1])
assert "summary" in lines[-1] and len(lines) == want + 1, lines
'
mkdir -p "$W/js"
check "a --json: a JSON object a file and a summary" bash -c "
  '$PAIA' a -f --json '$G' '$W/in/repeated_ani.ani' -o '$W/js/' | python3 -I -c \"\$1\" 2" _ "$JS"
check "  with the failure as ok false and its error" bash -c "
  '$PAIA' a -f --json '$G' '$W/missing.gif' -o '$W/js/' 2>/dev/null | python3 -I -c \"\$1
assert lines[1]['ok'] is False and 'error' in lines[1]\" 2" _ "$JS"
check "x --json" bash -c "'$PAIA' x -f --json '$W'/js/*.paia -o '$W/js/' | python3 -I -c \"\$1\" 2" _ "$JS"
check "t --json" bash -c "'$PAIA' t --json '$W/t/grad_gif.paia' '$W/t/damaged.paia' 2>/dev/null | python3 -I -c \"\$1\" 2" _ "$JS"
check "list --json" bash -c "'$PAIA' list --json '$W'/js/*.paia | python3 -I -c \"\$1\" 2" _ "$JS"
check "info --json, every format and a .paia" bash -c "
  '$PAIA' info --json '$G' '$W/in/synth_mixed_fli.flc' '$W/in/repeated_ani.ani' '$W/in/delta5_anim.anim' '$W/in/anim_m6_webp.webp' '$W/g.paia' |
  python3 -I -c \"\$1\" 6" _ "$JS"
check "--json: original_size and paia_size in a, x, t, list" bash -c "
  for c in 'a -f' 'x -f' t list; do
    case \$c in a*) f='$G' ;; *) f='$W/js/ffmpeg_anim_gif.paia' ;; esac
    '$PAIA' \$c --json \$f -o '$W/js/' 2>/dev/null || '$PAIA' \$c --json \$f
  done | python3 -I -c \"
import json, sys
for l in sys.stdin.read().splitlines():
    o = json.loads(l)
    if 'summary' in o: continue
    assert 'original_size' in o and 'paia_size' in o, o\""
check "--json is not for bench: rc 2" test "$(rc "$PAIA" bench --json "$G")" -eq 2

echo "--- bench"
mkdir -p "$W/bench"; cp "$G" "$W/bench/"
check "bench: a, a --no-verify and x, each with MB/s, rc 0" bash -c "
  '$PAIA' bench -r 1 '$W/bench/ffmpeg_anim_gif.gif' > '$W/b.txt' && grep -q 'a --no-verify' '$W/b.txt' && grep -q ' x ' '$W/b.txt'"
check "  and nothing written beside the inputs" test "$(ls "$W/bench" | wc -l)" -eq 1
check "bench -r 0: rc 2" test "$(rc "$PAIA" bench -r 0 "$W/bench/ffmpeg_anim_gif.gif")" -eq 2
check "-r for a: rc 2" test "$(rc "$PAIA" a -r 2 "$G")" -eq 2
check "--clean-temps with bench: rc 2" test "$(rc "$PAIA" bench --clean-temps "$G")" -eq 2

echo "--- a bug in PAIA"
check "an internal error (a range check): its own exit code, 3, and what to do" bash -c "
  PAIA_TEST_CRASH=range '$PAIA' a -f '$G' -o '$W/bug.paia' 2> '$W/bug.txt'; [ \$? -eq 3 ] &&
  grep -q 'internal error' '$W/bug.txt' && grep -q 'paia report' '$W/bug.txt'"
check "  and nothing written" test ! -e "$W/bug.paia"
check "an access violation, in a worker thread: rc 3" bash -c "
  PAIA_TEST_CRASH=access '$PAIA' a -f -th 4 '$G' '$W/in/grad_gif.gif' -o '$W/bugs/' 2> /dev/null; [ \$? -eq 3 ]"
check "an internal error during x: rc 3, no temporary left" bash -c "
  mkdir -p '$W/bugx' && PAIA_TEST_CRASH=range '$PAIA' x -f '$W/g.paia' -o '$W/bugx/' 2> /dev/null; [ \$? -eq 3 ] &&
  [ -z \"\$(ls -A '$W/bugx')\" ]"
check "a file that fails as a file is not a bug: rc 1" bash -c "
  '$PAIA' x '$W/in/grad_gif.gif' -o '$W/nb/' 2> '$W/nb.txt'; [ \$? -eq 1 ] && ! grep -q 'bug' '$W/nb.txt'"

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ]

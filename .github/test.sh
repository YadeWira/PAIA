#!/bin/sh
# The check every platform runs (CI): the paia command built three ways (the
# release build with the C pixel model, the same without C, and the checked
# build with range and overflow checks), BLAKE3 against the official
# vectors, every sample of the repository compressed by the three (the same
# .paia from each) and extracted (each must come back byte for byte), and
# the SHA-256 of all the .paia files written to hash.txt: the format makes
# the same bytes on every platform, which the last CI job checks. Then the
# zpaq-std plugin, built (pas/plugin/build.sh).
#
#   FPC=<compiler> CC=<C compiler> PAIA_OUT=<dir> sh .github/test.sh
set -eu
FPC=${FPC:-fpc}
OUT=${PAIA_OUT:-build/ci}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
rm -rf "$OUT"; mkdir -p "$OUT/c" "$OUT/uf" "$OUT/up" "$OUT/uk"

echo "== the frozen decoder of stream version 8 (doc/STABILITY.md)"
(cd pas && $SHA -c ../tests/frozen8.sha256 > /dev/null) || { echo "FAIL: pas/paia8* changed: version 8 must decode as 0.2.0 did"; exit 1; }
echo "pas/paia8*: unchanged"

echo "== build"
# the commit the command names in --version and report (release.yml sets
# it; '' where there is no git)
PAIA_COMMIT=${PAIA_COMMIT:-$(git rev-parse --short=7 HEAD 2>/dev/null || true)}
export PAIA_COMMIT
# A C compiler given by its full path (MSYS2's MinGW-w64 on Windows) needs its
# own folder on PATH for its DLLs and its cc1/as; without it, it fails
# without a word.
case ${CC:-} in /*) PATH=$(dirname "$CC"):$PATH; export PATH ;; esac
sh pas/build_c.sh "$OUT/c" || { echo "the C part did not build (CC=${CC:-cc})"; exit 1; }
build() {
  # $1: output name, $2: unit dir, the rest: options
  name=$1; units=$2; shift 2
  # shellcheck disable=SC2086
  $FPC "$@" -Fupas -Fipas -FU"$OUT/$units" -o"$OUT/$name$EXE" pas/paiacli.pas > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; echo "FAIL: $name did not build"; exit 1; }
}
build paia uf -O3 -dPAIA_FAST -Fo"$OUT/c" -Fl"$OUT/c"
build paia-pure up -O3 -dPAIA_FAST -dPAIA_PURE
build paia-checked uk -O2
"$OUT/paia$EXE" --version
$FPC -O2 -Fupas -Fipas -FU"$OUT/uk" -o"$OUT/test_blake3$EXE" pas/tests/test_blake3.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; echo "FAIL: test_blake3 did not build"; exit 1; }

echo "== selftest: the samples inside each binary, on every path it has"
for v in paia paia-pure paia-checked; do
  "$OUT/$v$EXE" selftest -q > "$OUT/selftest.log" 2>&1 || { cat "$OUT/selftest.log"; echo "FAIL: $v selftest"; exit 1; }
  echo "$v: $(tail -1 "$OUT/selftest.log")"
done

echo "== BLAKE3"
"$OUT/test_blake3$EXE" pas/tests/kat.txt > "$OUT/blake3.txt" || { cat "$OUT/blake3.txt"; echo "FAIL: BLAKE3"; exit 1; }
tail -1 "$OUT/blake3.txt"

echo "== every sample: compressed three ways, extracted, compared"
n=0
for dir in tests/*/; do
  d=$(basename "$dir")
  case "$d" in tools|paia010) continue ;; esac
  for f in "$dir"*; do
    [ -f "$f" ] || continue
    case "$f" in *.md) continue ;; esac
    n=$((n + 1))
    b=$(basename "$f")
    p="${b%.*}.paia"
    for v in paia paia-pure paia-checked; do
      mkdir -p "$OUT/p/$v/$d"
      "$OUT/$v$EXE" a -f -o "$OUT/p/$v/$d" "$f" > "$OUT/a.log" 2>&1 || { cat "$OUT/a.log"; echo "FAIL: $v a $f"; exit 1; }
      if grep -q 'codec failed' "$OUT/a.log"; then cat "$OUT/a.log"; echo "FAIL: $v stored $f after an error of its own"; exit 1; fi
    done
    cmp -s "$OUT/p/paia/$d/$p" "$OUT/p/paia-pure/$d/$p" || { echo "FAIL: $f: C and Pascal differ"; exit 1; }
    cmp -s "$OUT/p/paia/$d/$p" "$OUT/p/paia-checked/$d/$p" || { echo "FAIL: $f: the checked build differs"; exit 1; }
    mkdir -p "$OUT/x/$d"
    "$OUT/paia$EXE" x -q -f -o "$OUT/x/$d" "$OUT/p/paia/$d/$p" || { echo "FAIL: x $p"; exit 1; }
    cmp -s "$f" "$OUT/x/$d/$b" || { echo "FAIL: $f does not come back"; exit 1; }
  done
done
[ "$n" -ge 30 ] || { echo "FAIL: only $n samples"; exit 1; }
echo "$n samples: the same .paia three ways, and back byte for byte"

echo "== files written by 0.1.0, extracted by this version"
m=0
for p in tests/paia010/*/*.paia; do
  d=$(basename "$(dirname "$p")")
  mkdir -p "$OUT/old/$d"
  "$OUT/paia$EXE" x -q -f -o "$OUT/old/$d" "$p" || { echo "FAIL: 0.1.0's $p does not extract"; exit 1; }
  for f in "$OUT/old/$d"/*; do
    cmp -s "$f" "tests/$d/$(basename "$f")" || { echo "FAIL: 0.1.0's $p: not the sample"; exit 1; }
    m=$((m + 1))
  done
  rm -f "$OUT/old/$d"/*
done
[ "$m" -ge 9 ] || { echo "FAIL: only $m files of 0.1.0"; exit 1; }
echo "$m files written by 0.1.0: extracted byte for byte"

echo "== a name in UTF-8, in what the command writes to a file"
# --json, list and report, to a file, carry the name as UTF-8 on every system
# (on Windows the console's code page would turn it into "?": paiaconsole)
U="$OUT/u8"; rm -rf "$U"; mkdir -p "$U"
name='señal 動画.gif'
cp tests/gif/anim.gif "$U/$name"
"$OUT/paia$EXE" a -q --json -o "$U/" "$U/$name" > "$U/a.json" || { echo "FAIL: a on a UTF-8 name"; exit 1; }
"$OUT/paia$EXE" list "$U/señal 動画.paia" > "$U/list.txt" || { echo "FAIL: list on a UTF-8 name"; exit 1; }
"$OUT/paia$EXE" report "$U/$name" > "$U/report.txt" || { echo "FAIL: report on a UTF-8 name"; exit 1; }
for f in a.json list.txt report.txt; do
  LC_ALL=C grep -q "$(printf 'se\303\261al \345\213\225\347\224\273')" "$U/$f" \
    || { echo "FAIL: $f does not carry the name in UTF-8"; cat "$U/$f"; exit 1; }
done
"$OUT/paia$EXE" x -q -f -o "$U/back.gif" "$U/señal 動画.paia" && cmp -s tests/gif/anim.gif "$U/back.gif" \
  || { echo "FAIL: the UTF-8 name does not come back"; exit 1; }
echo "a.json, list and report: the name in UTF-8"

echo "== the streams"
(cd "$OUT/p/paia" && for f in */*.paia; do $SHA "$f"; done | sed 's/ [ *]/  /' | sort) > "$OUT/streams.txt"
$SHA "$OUT/streams.txt" | cut -c1-64 > hash.txt
echo "$(wc -l < "$OUT/streams.txt" | tr -d ' ') .paia files, SHA-256 of their list: $(cat hash.txt)"

echo "== the zpaq-std plugin"
FPC="$FPC" bash pas/plugin/build.sh "$OUT/plugin" > "$OUT/plugin.log" 2>&1 \
  || { cat "$OUT/plugin.log"; echo "FAIL: the plugin did not build"; exit 1; }
tail -1 "$OUT/plugin.log"

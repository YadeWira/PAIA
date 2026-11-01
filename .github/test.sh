#!/bin/sh
# The check every platform runs (CI): the paia command built three ways (the
# release build with the C pixel model, the same without C, and the checked
# build with range and overflow checks), BLAKE3 against the official
# vectors, every sample of the repository compressed by the three (the same
# .paia from each) and extracted (each must come back byte for byte), and
# the SHA-256 of all the .paia files written to hash.txt: the format makes
# the same bytes on every platform, which the last CI job checks.
#
#   FPC=<compiler> CC=<C compiler> PAIA_OUT=<dir> sh .github/test.sh
set -eu
FPC=${FPC:-fpc}
OUT=${PAIA_OUT:-build/ci}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
rm -rf "$OUT"; mkdir -p "$OUT/c" "$OUT/uf" "$OUT/up" "$OUT/uk"

echo "== build"
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

echo "== BLAKE3"
"$OUT/test_blake3$EXE" pas/tests/kat.txt > "$OUT/blake3.txt" || { cat "$OUT/blake3.txt"; echo "FAIL: BLAKE3"; exit 1; }
tail -1 "$OUT/blake3.txt"

echo "== every sample: compressed three ways, extracted, compared"
n=0
for dir in tests/*/; do
  d=$(basename "$dir")
  [ "$d" = tools ] && continue
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

echo "== the streams"
(cd "$OUT/p/paia" && for f in */*.paia; do $SHA "$f"; done | sed 's/ [ *]/  /' | sort) > "$OUT/streams.txt"
$SHA "$OUT/streams.txt" | cut -c1-64 > hash.txt
echo "$(wc -l < "$OUT/streams.txt" | tr -d ' ') .paia files, SHA-256 of their list: $(cat hash.txt)"

#!/bin/bash
# Every test: BLAKE3 against the official vectors, then every sample of
# tests/ through both builds: compressed, tested, extracted and compared
# with the original; the two builds have to write the same .paia; and a
# damaged .paia has to be refused or still give the original (the hash).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
bash "$HERE/pas/build.sh"
B="$HERE/pas/build"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

echo "== BLAKE3"
fpc -O2 -Fu"$HERE/pas" -FU"$B/checked" "$HERE/pas/tests/test_blake3.pas" -o"$B/test_blake3" >/dev/null
"$B/test_blake3" "$HERE/pas/tests/kat.txt" | tail -1

echo "== samples"
fail=0; n=0
for f in "$HERE"/tests/gif/*; do
  b=$(basename "$f"); n=$((n+1))
  mkdir -p "$T/c" "$T/f" "$T/x" "$T/bad"
  "$B/paia-checked" a -q -f -o "$T/c" "$f"
  "$B/paia" a -q -f -o "$T/f" "$f"
  p="${b%.*}.paia"
  if ! cmp -s "$T/c/$p" "$T/f/$p"; then echo "  $b: the two builds differ"; fail=1; fi
  "$B/paia" t -q "$T/f/$p"
  "$B/paia-checked" x -q -f -o "$T/x" "$T/f/$p"
  if ! cmp -s "$f" "$T/x/$b"; then echo "  $b: does not come back"; fail=1; fi
  printf '  %-22s %7d -> %7d\n' "$b" "$(stat -c %s "$f")" "$(stat -c %s "$T/f/$p")"
  # damage: change one byte in the middle of the payload; refused, or (if it
  # only touched the coder's padding) still the original, which the hash proves
  sz=$(stat -c %s "$T/f/$p")
  if [ "$sz" -gt 48 ]; then
    cp "$T/f/$p" "$T/bad.paia"
    off=$(( 40 + (sz - 44) / 2 ))
    old=$(od -An -tu1 -j$off -N1 "$T/bad.paia" | tr -d ' ')
    printf "\\x$(printf %02x $(( old ^ 0x5a )))" | dd of="$T/bad.paia" bs=1 seek=$off conv=notrunc 2>/dev/null
    if "$B/paia-checked" x -q -f -o "$T/bad" "$T/bad.paia" 2>/dev/null; then
      if ! cmp -s "$f" "$T/bad/$b"; then echo "  $b: a damaged .paia gave a wrong file"; fail=1; fi
    fi
  fi
done
echo "  $n samples"
[ $fail = 0 ] && echo "all green" || { echo "FAILED"; exit 1; }

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
for f in "$HERE"/tests/gif/* "$HERE"/tests/fli/* "$HERE"/tests/ani/* "$HERE"/tests/anim/* "$HERE"/tests/webp/*; do
  b=$(basename "$f"); n=$((n+1))
  mkdir -p "$T/c" "$T/f" "$T/x" "$T/bad"
  # a codec error falls back to storing the file, and the command says it
  # is a bug (exit 3)
  rc=0; "$B/paia-checked" a -q -f -o "$T/c" "$f" > "$T/a.log" 2>&1 || rc=$?
  if [ $rc -ne 0 ]; then echo "  $b: a ended with $rc: $(cat "$T/a.log")"; fail=1; fi
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
    rc=0; "$B/paia-checked" x -q -f -o "$T/bad" "$T/bad.paia" 2>/dev/null || rc=$?
    if [ $rc = 0 ]; then
      if ! cmp -s "$f" "$T/bad/$b"; then echo "  $b: a damaged .paia gave a wrong file"; fail=1; fi
    elif [ $rc != 1 ]; then echo "  $b: a damaged .paia ended with $rc, not 1"; fail=1; fi
  fi
done
echo "  $n samples"
echo "== files written by 0.1.0"
for p in "$HERE"/tests/paia010/*/*.paia; do
  d=$(basename "$(dirname "$p")")
  rm -rf "$T/old"; mkdir -p "$T/old"
  "$B/paia-checked" x -q -f -o "$T/old" "$p" || { echo "  $p: does not extract"; fail=1; continue; }
  for f in "$T"/old/*; do
    cmp -s "$f" "$HERE/tests/$d/$(basename "$f")" || { echo "  $p: not the sample"; fail=1; }
  done
done
echo "  $(ls "$HERE"/tests/paia010/*/*.paia | wc -l) files of 0.1.0 extracted"
echo "== the command (tests/cli.sh)"
bash "$HERE/tests/cli.sh" "$B/paia-checked" "$T/cli" > "$T/cli.log" 2>&1 || { grep FAIL "$T/cli.log"; fail=1; }
echo "  $(tail -1 "$T/cli.log")"
[ $fail = 0 ] && echo "all green" || { echo "FAILED"; exit 1; }

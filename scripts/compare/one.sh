#!/bin/bash
# one.sh TOOL FILE OUTDIR: compress, decompress, compare; prints
export LC_ALL=C
# set<TAB>file<TAB>tool<TAB>in<TAB>out<TAB>ctime<TAB>dtime<TAB>ok
T=${TOOLS:?TOOLS: where precomp-cpp/build/precomp and paq8px/build/paq8px are}
PAIA=${PAIA:?PAIA: the paia binary}
tool=$1; f=$2; O=$3
set_=$(basename "$(dirname "$f")"); b=$(basename "$f")
w=$(mktemp -d -p "$O"); cp "$f" "$w/in.${b##*.}"; src="$w/in.${b##*.}"
now() { date +%s.%N; }
t0=$(now)
case $tool in
  paia)    "$PAIA" a -q -th 1 --no-sync "$src" -o "$w/c.paia" ;;
  precomp) (cd "$w" && "$T/precomp-cpp/build/precomp" -o"$w/c.pcf" "$src" > /dev/null) ;;
  paq8px)  "$T/paq8px/build/paq8px" -8 "$src" "$w/c.p" > /dev/null ;;
  xz)      xz -9e -k -c "$src" > "$w/c.xz" ;;
  7z)      7z a -mx9 -bso0 -bsp0 "$w/c.7z" "$src" > /dev/null ;;
  zstd)    zstd -q --ultra -22 --long=27 "$src" -o "$w/c.zst" ;;
  brotli)  brotli -q 11 -w 24 "$src" -o "$w/c.br" ;;
  bzip3)   bzip3 -e -c "$src" > "$w/c.bz3" ;;
  zpaq)    (cd "$w" && zpaq a c.zpaq "in.${b##*.}" -m5 > /dev/null 2>&1) ;;
esac
t1=$(now)
c=$(ls "$w"/c.* 2>/dev/null | head -1)
case $tool in
  paia)    "$PAIA" x -q -th 1 --no-sync "$c" -o "$w/back" ;;
  precomp) (cd "$w" && "$T/precomp-cpp/build/precomp" -r -o"$w/back" "$c" > /dev/null) ;;
  paq8px)  "$T/paq8px/build/paq8px" -d "$c" "$w/back" > /dev/null ;;
  xz)      xz -d -c "$c" > "$w/back" ;;
  7z)      7z e -so "$c" > "$w/back" 2>/dev/null ;;
  zstd)    zstd -q -d --long=27 "$c" -o "$w/back" ;;
  brotli)  brotli -d "$c" -o "$w/back" ;;
  bzip3)   bzip3 -d -c "$c" > "$w/back" ;;
  zpaq)    (mkdir "$w/z" && cd "$w/z" && zpaq x ../c.zpaq > /dev/null 2>&1 && mv "in.${b##*.}" ../back) ;;
esac
t2=$(now)
ok=0; cmp -s "$src" "$w/back" && ok=1
printf '%s\t%s\t%s\t%s\t%s\t%.3f\t%.3f\t%s\n' "$set_" "$b" "$tool" "$(stat -c %s "$src")" "$(stat -c %s "$c" 2>/dev/null || echo 0)" \
  "$(echo "$t1 - $t0" | bc)" "$(echo "$t2 - $t1" | bc)" "$ok"
rm -rf "$w"

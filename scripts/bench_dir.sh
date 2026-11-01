#!/bin/bash
# Compresses every file of a directory with paia, extracts it, compares it
# with the original, and adds up the sizes against xz -9 and 7z (LZMA2, -mx9).
# usage: scripts/bench_dir.sh PAIA_BINARY DIR WORKDIR
set -euo pipefail
export LC_ALL=C
PAIA=$1; DIR=$2; W=$3
rm -rf "$W"; mkdir -p "$W/p" "$W/x"
tin=0; tp=0; txz=0; t7=0; bad=0; n=0
start=$(date +%s.%N)
for f in "$DIR"/*; do
  [ -f "$f" ] || continue
  n=$((n+1))
  b=$(basename "$f"); s=$(stat -c %s "$f")
  "$PAIA" a -q -f -o "$W/p" "$f"
  pf="$W/p/${b%.*}.paia"
  "$PAIA" x -q -f -o "$W/x" "$pf"
  if ! cmp -s "$f" "$W/x/$b"; then echo "MISMATCH: $b"; bad=$((bad+1)); fi
  ps=$(stat -c %s "$pf")
  xs=$(xz -9e -c "$f" | wc -c)
  7z a -mx9 -bso0 -bsp0 "$W/t.7z" "$f" >/dev/null; zs=$(stat -c %s "$W/t.7z"); rm -f "$W/t.7z"
  printf '%10d %10d %10d %10d  %s\n' "$s" "$ps" "$xs" "$zs" "$b"
  tin=$((tin+s)); tp=$((tp+ps)); txz=$((txz+xs)); t7=$((t7+zs))
done
end=$(date +%s.%N)
printf '%10s %10s %10s %10s\n' input paia xz-9e 7z-mx9
printf '%10d %10d %10d %10d  total, %d files, %d mismatches\n' $tin $tp $txz $t7 $n $bad
awk -v a=$tp -v b=$txz -v c=$t7 -v i=$tin 'BEGIN{printf "           %9.2f%% %9.2f%% %9.2f%%\n", 100*a/i, 100*b/i, 100*c/i}'
awk -v s=$start -v e=$end 'BEGIN{printf "paia a+x and the others: %.1f s\n", e-s}'

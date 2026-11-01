#!/bin/bash
# Total compressed size of a directory with paia, every file checked
# (extracted and compared); for trying model changes quickly.
# usage: scripts/quick.sh PAIA_BINARY DIR
set -euo pipefail
export LC_ALL=C
P=$1; D=$2; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# each file in a directory of its own: a.gif and a.fli would both be a.paia
t0=$(date +%s.%N)
i=0
for f in "$D"/*; do i=$((i+1)); mkdir -p "$W/$i"; "$P" a -q -f -o "$W/$i" "$f"; done
t1=$(date +%s.%N)
i=0
for f in "$D"/*; do
  i=$((i+1)); mkdir -p "$W/$i/x"
  "$P" x -q -f -o "$W/$i/x" "$W/$i"/*.paia
  cmp -s "$f" "$W/$i/x/$(basename "$f")" || echo "MISMATCH $(basename "$f")"
done
in=$(cat "$D"/* | wc -c); out=$(cat "$W"/*/*.paia | wc -c)
echo "$in -> $out ($(echo "scale=3; 100*$out/$in" | bc)%)  compress $(echo "$t1 - $t0" | bc) s"

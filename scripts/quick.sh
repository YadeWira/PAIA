#!/bin/bash
# Total compressed size of a directory with paia, every file checked
# (extracted and compared); for trying model changes quickly.
# usage: scripts/quick.sh PAIA_BINARY DIR
set -euo pipefail
export LC_ALL=C
P=$1; D=$2; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
t0=$(date +%s.%N)
"$P" a -q -f -o "$W" "$D"/*
t1=$(date +%s.%N)
mkdir "$W/x"; "$P" x -q -f -o "$W/x" "$W"/*.paia
for f in "$D"/*; do cmp -s "$f" "$W/x/$(basename "$f")" || echo "MISMATCH $(basename "$f")"; done
in=$(cat "$D"/* | wc -c); out=$(cat "$W"/*.paia | wc -c)
echo "$in -> $out ($(echo "scale=3; 100*$out/$in" | bc)%)  compress $(echo "$t1 - $t0" | bc) s"

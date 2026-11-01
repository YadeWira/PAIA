#!/bin/bash
# Times paia on a directory: compress all (which also verifies), then extract
# all; the best of N rounds, pinned to one core, so that other work running
# on the machine weighs less. Prints total input, total output, and times.
# usage: scripts/speed.sh PAIA_BINARY DIR [ROUNDS] [CPU]
set -euo pipefail
export LC_ALL=C
PAIA=$1; DIR=$2; R=${3:-3}; CPU=${4:-2}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
best_a=999999; best_x=999999
for r in $(seq "$R"); do
  rm -rf "$W"/*; mkdir -p "$W/p" "$W/x"
  t0=$(date +%s.%N)
  taskset -c "$CPU" "$PAIA" a -q -f -o "$W/p" "$DIR"/*
  t1=$(date +%s.%N)
  taskset -c "$CPU" "$PAIA" x -q -f -o "$W/x" "$W"/p/*.paia
  t2=$(date +%s.%N)
  a=$(echo "$t1 - $t0" | bc); x=$(echo "$t2 - $t1" | bc)
  best_a=$(echo "if ($a < $best_a) $a else $best_a" | bc)
  best_x=$(echo "if ($x < $best_x) $x else $best_x" | bc)
done
for f in "$DIR"/*; do cmp -s "$f" "$W/x/$(basename "$f")" || echo "MISMATCH $(basename "$f")"; done
in=$(cat "$DIR"/* | wc -c); out=$(cat "$W"/p/*.paia | wc -c)
mb=$(echo "scale=3; $in / 1000000" | bc)
printf 'in %d  out %d (%.2f%%)  compress %.2f s (%.2f MB/s)  extract %.2f s (%.2f MB/s)\n' \
  "$in" "$out" "$(echo "scale=4; 100*$out/$in" | bc)" "$best_a" "$(echo "scale=3; $mb/$best_a" | bc)" \
  "$best_x" "$(echo "scale=3; $mb/$best_x" | bc)"

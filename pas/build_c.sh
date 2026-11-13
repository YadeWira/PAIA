#!/bin/sh
# The C part of PAIA (the GIF pixel model, paiapix.c) as an object for
# FreePascal to link: paiamodel.pas takes it with {$L paiapix.o}, found
# through -Fo<dir>.
#
#   pas/build_c.sh <out dir> [extra C flags]
#
# CC picks the compiler (cc by default): gcc or clang, native or a cross
# compiler (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc, "gcc -m32").
#
# The object calls no library and needs no runtime: no stack protector, no
# loop turned into memset or memcpy (gcc's -fno-tree-loop-distribute-patterns,
# clang's -fno-builtin), no position-independent code where the executable is
# not (32-bit x86). -fwrapv and -ffp-contract=off keep the arithmetic the
# same everywhere. (The same flags as PJA's.)
set -eu
OUT=${1:?usage: build_c.sh <out dir> [extra C flags]}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-cc}
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
if $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-builtin"
else
  FLAGS="$FLAGS -fno-builtin -fno-tree-loop-distribute-patterns"
fi
case "$CC $*" in
  *-m32*|*i686*|*i386*) FLAGS="$FLAGS -fno-pic" ;;
esac
mkdir -p "$OUT"
# shellcheck disable=SC2086
$CC $FLAGS "$@" -c "$HERE/paiapix.c" -o "$OUT/paiapix.o"
# the frozen pixel model of codec stream version 8 (paia8model.pas)
# shellcheck disable=SC2086
$CC $FLAGS "$@" -c "$HERE/paia8pix.c" -o "$OUT/paia8pix.o"

#!/bin/bash
# PAIA as a zpaq-std plugin (paia_zpaqstd.pas): the shared library for this
# platform, with the C pixel model (pas/build_c.sh) built position-
# independent where it has to be.
#
#   pas/plugin/build.sh <out dir>   -> <out dir>/paia.so (Linux), paia.dylib
#                                      (macOS) or paia.dll (Windows)
#
# zpaq-std looks for codecs/paia.so (or codecs\paia.dll) next to its binary.
set -euo pipefail
FPC=${FPC:-fpc}
# absolute paths as the compiler takes them: on Windows (MSYS2, Git bash)
# pwd gives /d/a/..., which a Windows FreePascal does not read; pwd -W gives D:/a/...
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) PWD_=(pwd -W) ;; *) PWD_=(pwd) ;; esac
PAS=$(cd "$(dirname "$0")/.." && "${PWD_[@]}"); OUT=${1:?usage: build.sh <out dir>}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && "${PWD_[@]}"); B=$OUT/build
rm -rf "$B"; mkdir -p "$B/u" "$B/c"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIB=paia.dll; PIC=; CPIC= ;;
  Darwin) LIB=paia.dylib; PIC=-Cg; CPIC=-fPIC ;;
  *) LIB=paia.so; PIC=-Cg; CPIC=-fPIC ;;
esac
run() { "$@" > "$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; exit 1; }; }
# shellcheck disable=SC2086
run sh "$PAS/build_c.sh" "$B/c" $CPIC
# shellcheck disable=SC2086
run $FPC -O3 -dPAIA_FAST $PIC -Fu"$PAS" -Fi"$PAS" -Fu"$PAS/plugin" -Fo"$B/c" -Fl"$B/c" -FU"$B/u" \
  -o"$OUT/$LIB" "$PAS/plugin/paia_zpaqstd.pas"
ls -l "$OUT/$LIB"

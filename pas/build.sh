#!/bin/bash
# Builds the paia command: the checked build (range and overflow checks on,
# the reference) as build/paia-checked, and the release build as build/paia.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
mkdir -p build/checked build/fast build/pure
rm -f build/paia build/paia-checked build/paia-pure
# the C model (the release build only): no library, no runtime
sh ./build_c.sh build/fast
# warnings are shown: an uninitialized variable once made the two sides of
# the codec disagree
fpc -O2 -vw -FUbuild/checked paiacli.pas -obuild/paia-checked | grep -E 'Warning|Error' || true
fpc -O3 -vw -dPAIA_FAST -FUbuild/fast -Flbuild/fast -Fobuild/fast paiacli.pas -obuild/paia | grep -E 'Warning|Error' || true
# the release build without C: the same bytes, for comparing speeds
fpc -O3 -vw -dPAIA_FAST -dPAIA_PURE -FUbuild/pure paiacli.pas -obuild/paia-pure | grep -E 'Warning|Error' || true
if [ ! -x build/paia ] || [ ! -x build/paia-checked ] || [ ! -x build/paia-pure ]; then
  echo "BUILD FAILED" >&2; exit 1
fi
echo "built pas/build/paia (Pascal + C), paia-pure (Pascal) and paia-checked"

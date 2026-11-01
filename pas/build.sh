#!/bin/bash
# Builds the paia command: the checked build (range and overflow checks on,
# the reference) as build/paia-checked, and the release build as build/paia.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
mkdir -p build/checked build/fast build/pure
# the C model (the release build only); no libc, so the same .o can go into
# a library later
${CC:-gcc} -O3 -fno-builtin -fno-stack-protector -fPIC -c paiapix.c -o build/fast/paiapix.o
# warnings are shown: an uninitialized variable once made the two sides of
# the codec disagree
fpc -O2 -vw -FUbuild/checked paiacli.pas -obuild/paia-checked | grep -E 'Warning|Error' || true
fpc -O3 -vw -dPAIA_FAST -FUbuild/fast -Flbuild/fast -Fobuild/fast paiacli.pas -obuild/paia | grep -E 'Warning|Error' || true
# the release build without C: the same bytes, for comparing speeds
fpc -O3 -vw -dPAIA_FAST -dPAIA_PURE -FUbuild/pure paiacli.pas -obuild/paia-pure | grep -E 'Warning|Error' || true
[ -x build/paia ] && [ -x build/paia-checked ] && [ -x build/paia-pure ]
echo "built pas/build/paia (Pascal + C), paia-pure (Pascal) and paia-checked"

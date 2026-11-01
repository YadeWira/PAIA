#!/bin/bash
# Builds the paia command: the checked build (range and overflow checks on,
# the reference) as build/paia-checked, and the release build as build/paia.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
mkdir -p build/checked build/fast
fpc -O2 -FUbuild/checked paiacli.pas -obuild/paia-checked >/dev/null
fpc -O3 -dPAIA_FAST -FUbuild/fast paiacli.pas -obuild/paia >/dev/null
echo "built pas/build/paia and pas/build/paia-checked"

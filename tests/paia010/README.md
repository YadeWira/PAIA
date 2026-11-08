# Files written by PAIA 0.1.0

`.paia` files made by the PAIA 0.1.0 release (the published Linux x86-64
binary, not a rebuild) from samples of `tests/`: one or more a format,
and a file that is not one. Every later version must extract each of
them, byte for byte, into the sample it came from (`tests/<dir>/<name>`
with the extension the `.paia` keeps): what a release has published is
read forever (`doc/STABILITY.md`). `.github/test.sh` and `run_tests.sh`
check it. Never regenerate them with a later version.

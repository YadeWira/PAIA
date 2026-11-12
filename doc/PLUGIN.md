# PAIA in zpaq-std

`pas/plugin/paia_zpaqstd.pas` is PAIA as a
[zpaq-std](https://github.com/YadeWira/zpaq-std) plugin for codecs for
specific formats (plugin ABI 1, `compressors/plug/zs_codec.h`):

```sh
pas/plugin/build.sh out       # out/paia.so (paia.dylib, paia.dll)
# next to zpaq-std, as codecs/paia.so; then
zpaq-std a test.zpaq files -sat:paia:paiagif1:paiaflc1:paiaani1:paiaanim1:paiawebp1
```

One codec a format, each taking a file by its bytes (the format's header,
a GIF's within the first 4 KB, after a MacBinary header for instance, and
something PAIA takes in it): `paiagif1`, `paiaflc1` (FLI and FLC),
`paiaani1`, `paiaanim1` (IFF ANIM), `paiawebp1`. The names carry a
version, as every codec of the family does: a new stream, or another
ZPAQL decoder for the same one, comes as a new name (`paiagif2`...)
beside the old one, never as a change to it; no name ends in `z`, `o` or
`8`, which zpaq-std reads as other families' variants. They are frozen
when a release first ships them with a ZPAQL decoder. Their stream is PAIA's codec
stream (version 8), which keeps every byte of the block zpaq-std hands
over, the list of fragments after the file included. zpaq-std decodes
every block with the plugin and compares before writing it.

**Status: experimental, `-sat` only.** There is no ZPAQL decoder yet, so
the blocks open only with this plugin, and `-sae` (archives any zpaq
reads) is not possible; PAIA's stream also changes until 1.0.0.

Measured on 10/11/2026 with zpaq-std 2.7.0 (Linux x86-64, 8 threads),
the same method on both sides, on a mixed folder: 124 animated files
(88.4 MB: GIF, FLI/FLC, ANI, IFF ANIM, WebP) among 105 other files of the
sample corpus (23.4 MB):

| method | alone | with `-sat:paia:...` |
|---|---|---|
| `-m1` | 81,019,489 (1.2 s) | **52,094,134** (105.1 s) |
| `-m5` | 70,186,333 (224.5 s) | **48,536,056** (174.3 s) |

Each set alone, and how it was measured: the wiki's Benchmarks page and
`scripts/compare/archivers.sh`. Every file extracted identical. And 300 damaged and truncated copies of
the test samples went through `-sat` with no failure (the plugin took
195 of them, every one decoded back), all extracted identical.

## `+rcmd`: what PAIA does not take

With `-sa:...+rcmd` or `-rcmd` (zpaq-std 2.9.0), the files of a codec's
format that it does not take go with the method its card recommends, the
rest with the user's `-m`/`-ma`. PAIA's cards carry only `fallback_m`:
ZPAQ's own methods beat every `-ma` codec on all five formats, and
zpaq-std would take a `fallback_ma` entry before them.

Measured on 11/11/2026 with zpaq-std 2.8.0 (Linux x86-64, 8 threads). The
sample corpus has only three files of these formats the plugin refuses
(two small GIFs and an ANI), so the files are those three and the
truncated (50, 10, 2 %) and bit-flipped copies of the corpus's files the
plugin refuses (`scripts/compare/rcmd_rejects.py`, `rcmd.sh`); every file
extracted identical. Size, seconds to write / extract:

| format | files | in | best `-m` | best `-ma` | `fallback_m` |
|---|---|---|---|---|---|
| GIF | 81 | 10,853,946 | `-m4` 8,762,006 (0.6 / 0.3), `-m5` 8,534,168 (38.7 / 36.5) | `flzma2:10` 8,747,517 (2.2 / 0.4), `kanzi:9` 8,654,504 (11.6 / 12.4) | 4,5,1,2,3 |
| FLI/FLC | 49 | 598,413 | `-m5` 179,736 (1.4 / 1.5), `-m4` 188,591 (0.5 / 0.5) | `lzma:9` 208,387 (0.1 / 0.2) | 5,4,3,2,1 |
| ANI | 89 | 8,131,337 | `-m5` 547,612 (13.3 / 12.2) | `kanzi:9` 570,121 (3.2 / 3.2), `lzma:9` 629,667 (1.6 / 0.2) | 5,4,3,2,1 |
| IFF ANIM | 15 | 305,830 | `-m5` 97,566 (0.8 / 0.8), `-m4` 99,655 (0.3 / 0.3) | `lz:9` 100,121 (0.1 / 0.2) | 5,4,3,2,1 |
| WebP | 24 | 10,048,960 | `-m4` 5,470,849 (0.4 / 0.2), `-m5` 5,458,106 (26.7 / 28.9) | `flzma2:10` 5,869,337 (0.6 / 0.2) | 4,5,2,3,1 |

GIF and WebP put `-m4` first: `-m5` is 2.6 % and 0.2 % smaller there, but
about 70 times slower.

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
format that it does not take (its detect answers 2: the format's header,
nothing PAIA takes in it) go with the method its card recommends, the
rest with the user's `-m`/`-ma`. PAIA's cards carry only `fallback_m`: no
`-ma` codec is worth it on any of the five formats, and zpaq-std would
take a `fallback_ma` entry first. Older zpaq-std reads the 2 as 0: with
2.7.2 and 2.8.0 the archive is byte for byte the one the plugin made
before it answered 2 (checked on 13/11/2026, 124 files, `-timestamp`
fixed). With 2.9.0 as published, the same as with its rc5.

Measured on 12/11/2026 with zpaq-std 2.9.0-rc2 (Linux x86-64, 8 threads).
The sample corpus has only three files of these formats the plugin
refuses (two small GIFs and an ANI), so the files are, for each distinct
file of the corpus, the first refused of: the file, a bit flipped in its
first 4 KB, the file cut to 50, 10 or 2 % (`scripts/compare/rcmd_rejects.py`,
`rcmd.sh`). One a file: copies of the same file would share most of their
bytes, which a method that sees them together exploits and a file not
taken in the wild does not offer. Every file extracted identical. Size,
seconds to write / extract:

| format | files | in | `-m` | best `-ma` | `fallback_m` |
|---|---|---|---|---|---|
| GIF | 27 | 8,745,597 | `-m1` 8,755,912 (0.1 / 0.1), `-m5` 8,527,298 (42.4 / 44.1) | `bzip3:9` 8,683,411 (1.8 / 1.9) | 1,5 |
| FLI/FLC | 29 | 521,695 | `-m5` 177,145 (1.5 / 1.5), `-m4` 186,152 (0.4 / 0.5) | `lz:9` 206,105 (0.2 / 0.1) | 5,4,3 |
| ANI | 28 | 6,484,077 | `-m5` 540,613 (15.1 / 12.9), `-m4` 698,401 (4.0 / 4.2) | `kanzi:9` 563,661 (3.2 / 3.4), `lzma:9` 623,660 (1.5 / 0.2) | 5,4,3 |
| IFF ANIM | 10 | 291,027 | `-m5` 96,830 (1.0 / 1.0), `-m4` 98,970 (0.3 / 0.3) | `lz:9` 99,632 (0.1 / 0.1) | 5,4,3 |
| WebP | 8 | 5,458,379 | `-m1` 5,464,748 (0.1 / 0.1), `-m5` 5,453,703 (24.9 / 25.9) | `lzma:9` 5,464,736 (1.2 / 0.1) | 1,5 |

What PAIA does not take of a GIF or a WebP is compressed data already (LZW,
VP8): `-m5` gains 2.5 % and 0.2 % there, at 300 times `-m1`'s time.

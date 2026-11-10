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

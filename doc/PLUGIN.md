# PAIA in zpaq-std

`pas/plugin/paia_zpaqstd.pas` is PAIA as a
[zpaq-std](https://github.com/YadeWira/zpaq-std) plugin for codecs for
specific formats (plugin ABI 1, `compressors/plug/zs_codec.h`):

```sh
pas/plugin/build.sh out       # out/paia.so (paia.dylib, paia.dll)
# next to zpaq-std, as codecs/paia.so; then
zpaq-std a test.zpaq files -sat:paia:paiagif:paiaflc:paiaani:paiaanim:paiawebp
```

One codec a format, each taking a file by its bytes (the format's header,
and something PAIA takes in it): `paiagif`, `paiaflc` (FLI and FLC),
`paiaani`, `paiaanim` (IFF ANIM), `paiawebp`. Their stream is PAIA's codec
stream (version 8), which keeps every byte of the block zpaq-std hands
over, the list of fragments after the file included. zpaq-std decodes
every block with the plugin and compares before writing it.

**Status: experimental, `-sat` only.** There is no ZPAQL decoder yet, so
the blocks open only with this plugin, and `-sae` (archives any zpaq
reads) is not possible; PAIA's stream also changes until 1.0.0.

Measured on 01/11/2026 with zpaq-std 2.0.3 (Linux x86-64):

| 27 real files (8.6 MB: GIF, FLI/FLC, WebP, IFF ANIM, ANI) | archive |
|---|---|
| `-m1` | 6,104,186 |
| `-m3` | 5,513,191 |
| `-m5` | 5,293,241 |
| `-m3 -sat:paia:...` | **3,972,081** |

Every file extracted identical. And 300 damaged and truncated copies of
the test samples went through `-sat` with no failure (the plugin took
195 of them, every one decoded back), all extracted identical.

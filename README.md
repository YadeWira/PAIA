# PAIA

**packAnimatedImage Algorithm**: lossless recompression of **GIF**,
**FLI/FLC**, **ANI**, **IFF ANIM** and **WebP** files, in FreePascal, with
GIF's pixel model also in C; no libraries. A new member of the family, with
no predecessor: its own codec and format, verified before anything is
written.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

```sh
paia a anim.gif          # -> anim.paia, about 55% smaller
paia x anim.paia         # -> anim.gif, the same file byte for byte
```

The original comes back **byte for byte**, and nothing is written under an
output's name unless it verified: compressing decompresses the result and
compares it with the input before writing, and extracting checks the size
and the BLAKE3 hash stored in the `.paia`.

No format is frozen yet (that comes with a 0.9.x), but every `.paia` a
release has written opens in every later one
([doc/STABILITY.md](doc/STABILITY.md)).

PAIA belongs to a family of recompressors that share that rule: the
original comes back byte for byte, and nothing is written unless it
verified.

| Sibling | Formats | Successor of |
|---|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |
| [POA](https://github.com/YadeWira/POA) | Ogg (Vorbis, Opus, FLAC, Speex, Theora) | (new) |
| **PAIA** | animated images (GIF, WebP, FLI/FLC, ANI, IFF ANIM) | (new) |

## What it handles

- **GIF**: every image of every GIF stream in a file, from any LZW encoder,
  rebuilt bit for bit from its pixels, each animation's canvas composed
  (offsets, transparency, disposal, interlacing).
- **FLI and FLC** (8 bits): BYTE_RUN, DELTA_FLI, DELTA_FLC, COPY and BLACK
  chunks, field by field.
- **ANI**: the bitmaps of its cursor and icon frames, 1 to 32 bits.
- **IFF ANIM**: the first frame and the Byte Vertical Delta (method 5)
  frames.
- **WebP**: lossless (VP8L) frames and the lossless alpha of lossy ones,
  still or animated; lossy (VP8) key frames.

A frame that repeats an earlier one is kept once. Files are recognized by
their content, never by their name; anything else goes through as bytes,
and `paia a` says what it took ([details][wHandles]).

## Install

Download the command for your platform from the [latest release][relLink]:
Linux (x86-64, x86, arm64), macOS (Apple silicon) or Windows (x64, x86).
Each build is tested by CI on its own platform, and a `.paia` made on one
opens on any other ([installing][wInstall], [platforms][wPlat]).

```sh
paia a *.gif --output-dir=packed     # compress many
paia x packed/*.paia -o restored/    # and back
paia list packed/*.paia              # sizes and hashes
```

The command's manual is [doc/CLI.md](doc/CLI.md).

## Against other compressors

One file at a time, against [precomp](https://github.com/schnaader/precomp-cpp)
0.4.8 (which recompresses the GIFs whose LZW it can rebuild) and
[paq8px](https://github.com/hxim/paq8px) v217 `-8` (a context-mixing
compressor with a GIF model), both of which give every file back byte for
byte, and the general-purpose compressors at their strongest. Each set's
whole output against its input; every file was extracted and compared
([how, and the details][wComp]). The sets are the sample corpus's files of
each format, recognized by their content.

| set | files | size | precomp | paq8px | xz -9e | 7-Zip -mx9 | zpaq -m5 | PAIA |
|---|---|---|---|---|---|---|---|---|
| GIF | 39 | 36.9 MB | 84.72% | 48.68% | 96.72% | 96.70% | 94.99% | **44.74%** |
| FLI/FLC | 28 | 18.0 MB | 50.66% | 33.18% | 46.44% | 46.44% | 38.53% | **31.00%** |
| ANI | 26 | 12.9 MB | 19.12% | **4.50%** | 14.69% | 14.61% | 12.15% | 8.16% |
| IFF ANIM | 14 | 6.1 MB | 55.04% | **43.85%** | 52.22% | 52.30% | 50.10% | 45.08% |
| WebP | 17 | 14.4 MB | 95.48% | 94.93% | 95.45% | 95.45% | 95.37% | **85.45%** |

Speed on all five sets (88.4 MB), one thread a file, 16 files at once on
two Xeon E5-2697A v4, in MB/s of the original:

| | precomp | paq8px | xz -9e | 7-Zip -mx9 | zpaq -m5 | PAIA |
|---|---|---|---|---|---|---|
| compress | 2.36 | 0.003 | 1.45 | **4.89** | 0.13 | 0.13 |
| decompress | 11.47 | 0.003 | **27.39** | 22.10 | 0.13 | 0.27 |

PAIA is the smallest on the GIFs, the FLICs and the WebPs. paq8px is
smaller on the cursors and the IFF ANIMs, but about 50 times slower than PAIA to compress and 90
times to extract, and needs 2.5 GB of memory a file. precomp is fast, and
saves on a GIF only when it can rebuild its LZW, 15% here. Neither checks
what it gives back ([below](#safe-by-design)).

## Safe by design

PAIA's first rule is that the original comes back byte for byte, or nothing
is written. Measured against the other two tools that recompress GIF, on
the same small GIFs and the same damage ([how][wSafe]):

| | PAIA | precomp | paq8px |
|---|---|---|---|
| 1,000 single-bit flips in the compressed file: a wrong GIF given back without an error | **0** | 198 | 960 |
| the same flips: a wrong GIF left under the output's name, error or not | **0** | 971 | 996 |
| 1,000 damaged GIFs taken that do not come back | **0** | 0 | 0 |
| checks the original's size and hash when extracting | **yes** (BLAKE3) | no | no |
| decompresses its whole output and compares before writing | **yes** | no (only each stream it rebuilds) | no |
| writes through a symbolic link at the output's name | **no** | no | yes |
| killed while writing: a file under the output's name | **no** | yes (empty) | yes (empty) |
| written promise that its files keep opening | **yes** ([STABILITY](doc/STABILITY.md)) | no | no |

It is design, not luck: a stored hash and size, a decode-and-compare before
writing, a temporary that takes the output's name only when it is complete
and on the disk (and is deleted on Ctrl-C), and refusing a declared size
above `--max-output` before decoding. What it does not do: repair a
damaged `.paia` (keep backups, or use an archiver with recovery records) or
authenticate it (the hash catches accidents, not tampering).

## Against archivers

One archive per folder, 8 threads; every file extracted and compared.
Size, then the time to write / extract. zpaq-std 2.7.0 with each method
alone and with PAIA's plugin added (`-sat:paia:...`), the same method on
both sides; 7-Zip 25.01 `-mx9` for reference. The mixed folder is the five
sets (124 files, 88.4 MB) among 105 other files of the sample corpus
(text, documents, images, audio, programs: 23.4 MB). There is no 7-Zip
plugin yet.

| folder | zpaq-std -m1 | -m1 + PAIA | zpaq-std -m5 | -m5 + PAIA | 7-Zip -mx9 |
|---|---|---|---|---|---|
| mixed (229 files, 111.8 MB) | 72.49%, 1.2 / 0.4 s | 46.61%, 105.1 / 29.2 s | 62.79%, 224.5 / 238.1 s | **43.42%**, 174.3 / 85.9 s | 65.55%, 14.3 / 1.7 s |
| GIF (39) | 100.07%, 0.4 / 0.2 s | 44.82%, 44.2 / 17.0 s | 94.53%, 159.9 / 160.8 s | **44.82%**, 44.2 / 16.8 s | 96.61%, 3.8 / 0.7 s |
| FLI/FLC (28) | 62.63%, 0.9 / 0.3 s | 32.42%, 18.2 / 8.3 s | 38.69%, 53.4 / 54.1 s | **31.44%**, 19.5 / 8.5 s | 46.41%, 2.9 / 0.4 s |
| ANI (26) | 17.79%, 0.4 / 0.1 s | 8.63%, 16.8 / 8.9 s | 7.90%, 22.5 / 22.0 s | **6.80%**, 20.4 / 8.3 s | 9.15%, 2.5 / 0.1 s |
| IFF ANIM (14) | 63.46%, 0.3 / 0.2 s | 45.23%, 7.3 / 4.0 s | 49.76%, 18.7 / 19.7 s | **45.23%**, 7.2 / 3.7 s | 52.17%, 0.9 / 0.2 s |
| WebP (17) | 95.54%, 0.3 / 0.3 s | 85.55%, 25.7 / 9.9 s | 95.21%, 56.7 / 62.5 s | **85.55%**, 25.5 / 10.5 s | 95.44%, 1.2 / 0.2 s |

With PAIA, zpaq-std's archive of the mixed folder is 36% smaller with
`-m1` and 31% with `-m5`, and `-m5` with PAIA writes it faster than `-m5`
alone: what PAIA takes skips `-m5`'s slow model. Beside `-m1` it costs
time (105 s against 1 s), as PAIA's model is slow. Every set gets
smaller with either method; on the GIFs, the archive is less than half of
7-Zip's or zpaq-std's.

## In 7-Zip and zpaq-std

**7-Zip**: not yet. A library with a 7-Zip codec, as PJA has, is next
([details][wLib]).

**[zpaq-std](https://github.com/YadeWira/zpaq-std)**: PAIA's plugin
(`pas/plugin/`, built from source for now) gives it five codecs,
`paiagif1`, `paiaflc1`, `paiaani1`, `paiaanim1` and `paiawebp1`:

```sh
zpaq-std a anims.zpaq anims/ -sat:paia:paiagif1:paiaflc1:paiaani1:paiaanim1:paiawebp1
```

Experimental: the codecs have no ZPAQL decoder yet, so such an archive
opens only with the plugin ([details][wPlugin]).

## Reporting a bug

```sh
paia report anim.gif -o report.txt   # what happened, on which machine
```

It writes a plain-text report (PAIA's build, the system, the command line,
and the file's size, hash and structure, but no pixels, no metadata
contents and no folder names) and prints a link that opens a [new
issue][issues] with it filled in. `--with-file` puts a copy of the file
beside it, to attach if you choose to ([details][wBugs],
[doc/CLI.md](doc/CLI.md#checking-and-reporting)).

## More

The [wiki][wiki] has the rest: [benchmarks][wComp], [what PAIA
handles][wHandles], the [zpaq-std plugin][wPlugin], [building and
testing][wBuild], [how it works][wHow], the [source layout][wLayout],
[FreePascal pitfalls][wFpc] and the [release history][wRel]. The codec's
full notes, with every measurement, are in [doc/CODEC.md](doc/CODEC.md),
the formats in scope in [doc/FORMATS.md](doc/FORMATS.md), what does not
change in [doc/STABILITY.md](doc/STABILITY.md).

## Building

FreePascal 3.2 and a C compiler (gcc or clang):

```sh
pas/build.sh          # pas/build/paia (Pascal + C), paia-pure, paia-checked
./run_tests.sh        # every test
```

CI builds and tests every commit on the six platforms, and checks that the
`.paia` files are the same bytes on all of them.

## License

MIT, see `LICENSE`; credits in `NOTICE`.

[ciBadge]: https://github.com/YadeWira/PAIA/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PAIA/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/PAIA "Latest release"
[relLink]: https://github.com/YadeWira/PAIA/releases/latest
[wiki]: https://github.com/YadeWira/PAIA/wiki
[wComp]: https://github.com/YadeWira/PAIA/wiki/Benchmarks
[wSafe]: https://github.com/YadeWira/PAIA/wiki/Safety-and-robustness
[wHandles]: https://github.com/YadeWira/PAIA/wiki/What-PAIA-handles
[wInstall]: https://github.com/YadeWira/PAIA/wiki/Installing
[wPlat]: https://github.com/YadeWira/PAIA/wiki/Platforms
[wLib]: https://github.com/YadeWira/PAIA/wiki/Library-and-7-Zip
[wPlugin]: https://github.com/YadeWira/PAIA/wiki/The-zpaq-std-plugin
[wBuild]: https://github.com/YadeWira/PAIA/wiki/Building
[wHow]: https://github.com/YadeWira/PAIA/wiki/How-it-works
[wLayout]: https://github.com/YadeWira/PAIA/wiki/Source-layout
[wFpc]: https://github.com/YadeWira/PAIA/wiki/FreePascal-pitfalls
[wRel]: https://github.com/YadeWira/PAIA/wiki/Releases
[wBugs]: https://github.com/YadeWira/PAIA/wiki/Reporting-bugs
[issues]: https://github.com/YadeWira/PAIA/issues

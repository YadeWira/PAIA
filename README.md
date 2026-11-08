# PAIA

[![CI](https://github.com/YadeWira/PAIA/actions/workflows/ci.yml/badge.svg)](https://github.com/YadeWira/PAIA/actions/workflows/ci.yml)

**packAnimatedImage Algorithm**: lossless recompression of animated images,
in FreePascal with C and embedded assembly; no libraries.

> **Status: proof of concept.** GIF, FLI/FLC, ANI, IFF ANIM and WebP work;
> the first release is 0.1.0. No format is frozen yet (that comes in a
> 0.9.x), but whatever a release has written is read by every later one:
> [doc/STABILITY.md](doc/STABILITY.md).

```sh
paia a anim.gif          # -> anim.paia
paia x anim.paia         # -> anim.gif, the same file byte for byte
paia t anim.paia         # extract in memory and check
```

On the 62 GIF files of the sample corpus: **42.07%** of their size, against
95.60% for xz -9e and 7-Zip; on its 29 FLI/FLC animations, **31.07%**
against 46.45%; on its 26 ANI cursors, **8.16%** against 14.69%; on its 14 IFF ANIMs,
**45.08%** against 52.22%; on 11 animated WebPs, **77.23%** against 88.99%;
every file coming back the same
([doc/CODEC.md](doc/CODEC.md)).

PAIA belongs to a family of recompressors that share that rule: the
original comes back byte for byte, and nothing is written unless it
verified. Compressing decompresses the result and compares it with the
input before writing; anything that would not come back exactly is
stored as it is.

| Sibling | Formats | Successor of |
|---|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| **PAIA** | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG and JPEG-LS | [packJPG](https://github.com/YadeWira/packJPG) |

Unlike its siblings, PAIA has no predecessor to succeed: it starts from
scratch.

## Formats

The animated formats PAIA aims to take ([doc/FORMATS.md](doc/FORMATS.md)):

| Format | Extension | Coding | PAIA |
|---|---|---|---|
| GIF | `.gif` | LZW, palette of up to 256 colours | works |
| Animated WebP | `.webp` | VP8 / VP8L in RIFF | works (VP8, VP8L, lossless alpha) |
| Animated AVIF | `.avif`, `.avifs` | AV1 in ISOBMFF | |
| HEIF image sequence | `.heics`, `.heic` | HEVC in ISOBMFF | |
| BPG | `.bpg` | HEVC | |
| FLI / FLC | `.fli`, `.flc` | RLE and frame deltas, palette | works (8 bits) |
| ANI | `.ani` | ICO/CUR frames in RIFF | works (bitmap frames) |
| FLIF | `.flif` | MANIAC | |
| IFF ANIM | `.anim`, `.iff` | ByteRun and frame deltas | works (delta method 5) |

APNG, MNG and JNG belong to PPA; JPEG XL is left aside.

## Install

Download the command for your platform from the [latest
release](https://github.com/YadeWira/PAIA/releases/latest): Linux (x86-64,
arm64, x86), macOS (Apple silicon) or Windows (x64, x86); `SHA256SUMS`
there has every archive's hash. The command's manual is
[doc/CLI.md](doc/CLI.md).

## More

The [wiki](https://github.com/YadeWira/PAIA/wiki) has the rest: [what PAIA
handles](https://github.com/YadeWira/PAIA/wiki/What-PAIA-handles),
[benchmarks](https://github.com/YadeWira/PAIA/wiki/Benchmarks) and [how it
works](https://github.com/YadeWira/PAIA/wiki/How-it-works). The codec's
full notes, with every measurement, are in [doc/CODEC.md](doc/CODEC.md).
PAIA in [zpaq-std](https://github.com/YadeWira/zpaq-std) archives, as an
experimental plugin: [doc/PLUGIN.md](doc/PLUGIN.md).

## Building

CI builds and tests every commit on Linux (x86-64, arm64, x86), macOS
(Apple silicon) and Windows (x64, x86), and checks that the `.paia` files
are the same bytes on all of them.

FreePascal 3.2 and a C compiler (gcc or clang):

```sh
pas/build.sh          # pas/build/paia (Pascal + C), paia-pure, paia-checked
./run_tests.sh        # every test
```

## License

MIT, see `LICENSE`; credits in `NOTICE`.

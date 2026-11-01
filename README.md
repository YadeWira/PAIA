# PAIA

**packAnimatedImage Algorithm**: lossless recompression of animated images,
in FreePascal with C and embedded assembly; no libraries.

> **Status: proof of concept.** GIF and FLI/FLC work; nothing to download yet. The
> format is not frozen: no file written by an early build is promised to
> open later.

```sh
paia a anim.gif          # -> anim.paia
paia x anim.paia         # -> anim.gif, the same file byte for byte
paia t anim.paia         # extract in memory and check
```

On the 62 GIF files of the sample corpus: **44.79%** of their size, against
95.60% for xz -9e and 7-Zip; on its 29 FLI/FLC animations, **32.43%**
against 46.45%; every file coming back the same
([doc/CODEC.md](doc/CODEC.md)).

PAIA belongs to a family of recompressors that share one rule: the original
comes back **byte for byte**, and nothing is written unless it verified.
Compressing decompresses the result and compares it with the input before
writing; anything that would not come back exactly is stored as it is.

| Sibling | Formats |
|---|---|
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TGA, PCX, ...) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) |
| [PJA](https://github.com/YadeWira/PJA) | JPEG and JPEG-LS |

Unlike its siblings, PAIA has no predecessor to succeed: it starts from
scratch.

## Formats

The animated formats PAIA aims to take ([doc/FORMATS.md](doc/FORMATS.md)):

| Format | Extension | Coding | PAIA |
|---|---|---|---|
| GIF | `.gif` | LZW, palette of up to 256 colours | works |
| Animated WebP | `.webp` | VP8 / VP8L in RIFF | |
| Animated AVIF | `.avif`, `.avifs` | AV1 in ISOBMFF | |
| HEIF image sequence | `.heics`, `.heic` | HEVC in ISOBMFF | |
| BPG | `.bpg` | HEVC | |
| FLI / FLC | `.fli`, `.flc` | RLE and frame deltas, palette | works (8 bits) |
| ANI | `.ani` | ICO/CUR frames in RIFF | |
| FLIF | `.flif` | MANIAC | |
| IFF ANIM | `.anim`, `.iff` | ByteRun and frame deltas | |

APNG, MNG and JNG belong to PPA; JPEG XL is left aside.

## Building

FreePascal 3.2 and a C compiler (gcc or clang):

```sh
pas/build.sh          # pas/build/paia (Pascal + C), paia-pure, paia-checked
./run_tests.sh        # every test
```

## License

MIT, see `LICENSE`; credits in `NOTICE`.

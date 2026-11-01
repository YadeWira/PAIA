# PAIA

**packAnimatedImage Algorithm**: lossless recompression of animated images,
in FreePascal with C and embedded assembly; no libraries.

> **Status: proof of concept.** Nothing to download yet; the format is not
> frozen and no file written by an early build is promised to open later.

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

| Format | Extension | Coding |
|---|---|---|
| GIF | `.gif` | LZW, palette of up to 256 colours |
| Animated WebP | `.webp` | VP8 / VP8L in RIFF |
| Animated AVIF | `.avif`, `.avifs` | AV1 in ISOBMFF |
| HEIF image sequence | `.heics`, `.heic` | HEVC in ISOBMFF |
| BPG | `.bpg` | HEVC |
| FLI / FLC | `.fli`, `.flc` | RLE and frame deltas, palette |
| ANI | `.ani` | ICO/CUR frames in RIFF |
| FLIF | `.flif` | MANIAC |
| IFF ANIM | `.anim`, `.iff` | ByteRun and frame deltas |

APNG, MNG and JNG belong to PPA; JPEG XL is left aside.

## License

MIT, see `LICENSE`; credits in `NOTICE`.

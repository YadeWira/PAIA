# Formats

What PAIA takes, and what it leaves to others.

## In scope

| # | Format | Extension | Coding | Standing |
|---|---|---|---|---|
| 1 | GIF | `.gif` | LZW, palette of up to 256 colours | widespread |
| 2 | Animated WebP | `.webp` | VP8 / VP8L in RIFF | widespread |
| 3 | Animated AVIF | `.avif`, `.avifs` | AV1 in ISOBMFF | growing |
| 4 | HEIF image sequence | `.heics`, `.heic` | HEVC in ISOBMFF | Apple |
| 5 | BPG | `.bpg` | HEVC | niche |
| 6 | FLI / FLC | `.fli`, `.flc` | RLE and frame deltas, palette | legacy |
| 7 | ANI | `.ani` | ICO/CUR frames in RIFF | legacy (Windows) |
| 8 | FLIF | `.flif` | MANIAC | dead |
| 9 | IFF ANIM | `.anim`, `.iff` | ByteRun and frame deltas (Amiga) | legacy, niche |

## Out of scope

| Format | Why |
|---|---|
| APNG, MNG, JNG | the PNG family: [PPA](https://github.com/YadeWira/PPA) |
| JPEG XL | set aside; if ever needed, with help from [PJA](https://github.com/YadeWira/PJA) |
| Lottie, TGS | vector animation (JSON), not pixels |
| Animated SVG | vector (SMIL), not pixels |
| Motion JPEG 2000 | video, not an image |
| Ugoira | a ZIP of separate images, not a format |

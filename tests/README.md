# Test samples

All generated for PAIA (ImageMagick 7 and ffmpeg), none taken from
elsewhere: gradients, noise, a checkerboard, an interlaced plasma, a
1-pixel image, animations (plain, layer-optimized, ffmpeg's encoder with and without
its transparent differences, small sprites at an offset with each
disposal),
and the odd cases: a truncated GIF, a GIF inside other bytes, two GIFs one
after the other, and a file that is not a GIF.

`fli/`: FLI and FLC files written by `tools/mkflic.py` (no encoder of
ours, nor ffmpeg nor ImageMagick, writes FLICs): every pixel chunk PAIA
takes (BYTE_RUN, DELTA_FLI, DELTA_FLC with an odd width's last-byte word,
COPY, BLACK), palettes, an unknown chunk, a prefix chunk with a postage
stamp, 16-bit FLCs of magic 0xAF44 and 0xAF12 (DTA_BRUN, DTA_LC, DTA_COPY,
one of an odd width), an FLI with sound in each frame, and a truncated
file. `tools/check_flic.py` checks that FFmpeg decodes each to the frames
meant.

`ani/`: animated cursors written by `tools/mkani.py` (none of the tools at
hand writes ANI): frames of 32, 24, 4 and 1 bits a pixel, a CUR with
hotspots, rate and sequence chunks, a frame kept as PNG, repeated frames
(A B A C: what follows a repeat looks back past it), and a truncated
file. Each frame, taken out, is a valid ICO or CUR for ImageMagick.

`anim/`: IFF ANIMs written by `tools/mkanim.py`: a ByteRun1 BODY and an
uncompressed one, frames double buffered as Amiga players draw them with
every delta method: 5 (Byte Vertical Delta, one in XOR mode), 3, 7 and 8
(short and long), a BODY with a mask plane, 74 ("J": both types, one in XOR mode, one under 320
pixels wide), 100, 101 and 108; and a truncated file.
`tools/check_anim.py` checks that FFmpeg decodes each to the frames
meant.

`webp/`: WebPs made with gif2webp and cwebp from the GIF samples above:
lossless animations (one with `-m 6`), a lossy one with lossless alpha,
a mixed one, a still lossless image, lossy stills with four segments and
with one (no spatial noise shaping, no filter), and a truncated file.

`run_tests.sh` also fails when the codec falls back to storing a sample
because of an error of its own: the fallback is right for users, but it
would hide a bug (it hid one: a repeated frame made the two sides see
different previous frames).

`hugesize/`: written by `tools/mkhugesize.py`: an ANI, an IFF ANIM, a WebP
and a FLC, each with a chunk that declares a size of nearly 4 GB (2 GB for
the FLC). On 32-bit builds the parsers kept such a size in a SizeInt,
where it wrapped negative, and read before their buffer.

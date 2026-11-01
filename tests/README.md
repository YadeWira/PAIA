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
COPY, BLACK), palettes, an unknown chunk, and a truncated file. ffmpeg
decodes all of them.

`ani/`: animated cursors written by `tools/mkani.py` (none of the tools at
hand writes ANI): frames of 32, 24, 4 and 1 bits a pixel, a CUR with
hotspots, rate and sequence chunks, a frame kept as PNG, and a truncated
file. Each frame, taken out, is a valid ICO or CUR for ImageMagick.

`anim/`: IFF ANIMs written by `tools/mkanim.py`: a ByteRun1 BODY and an
uncompressed one, Byte Vertical Delta frames double buffered as Amiga
players draw them, one in XOR mode, and a truncated file. ffmpeg decodes
all of them.

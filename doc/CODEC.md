# PAIA codec

Status: **proof of concept**, stream version 1, not frozen.

## GIF

A GIF's images are LZW streams. PAIA decodes each one to its palette
indices, codes the indices with a context-mixing model, and rebuilds the LZW
from them on extraction, **bit for bit**.

### Rebuilding the LZW exactly (`pas/paiagif.pas`)

Given the pixels, an LZW encoder has little freedom: almost every GIF
encoder emits, at each step, the longest string already in its dictionary.
So the codes follow from the pixels, and what has to be stored is only what
an encoder chooses:

| choice | stored as |
|---|---|
| a clear code at the start | a flag |
| when it clears the dictionary | the dictionary's next code at which it does (`clearAt`), chosen among those seen in the stream as the one that leaves the fewest exceptions |
| any code the rules above and greedy matching do not predict | an exception: its position and the code |
| the end code | a flag |
| the unused bits of the last byte, and bytes after the end | as they are |
| the sub-block lengths | one size (all blocks but the last), or the list |

So any LZW stream comes back, whatever the encoder: an unusual one only
costs more exceptions. `Analyse` rebuilds every stream and compares it with
the original before taking the image; one that does not come back stays as
bytes.

Images are found by their content, not by the file's name: every GIF
stream in the file (after a MacBinary header, two GIFs one after the
other...), and only images whose sub-blocks are complete.

### The models (`pas/paiamodel.pas`)

- **The canvas.** Each GIF stream's images are composed as a viewer
  composes them: each at its offset, transparent pixels leaving the
  canvas as it was, and the previous image's disposal applied before the
  next one (2: cleared, 3: put back as it was). Interlaced images are put
  in place row by row. So each pixel has, under it, what the canvas
  showed before this image, and what the previous image had at the same
  place (or that it was transparent there): animations whose frames are
  small rectangles at an offset, as most optimized GIFs are, get their
  previous frame as context too.
- **Pixels**: first a flag, "it is the candidate": the canvas under it,
  or this image's transparent index if the image has used it more than
  the canvas's value so far (or else the left pixel, or the one above), from six contexts
  of which pixels around equal the candidate, the run of hits so far, and
  the values around; most pixels of a GIF end there, with one binary
  decision. When it is not the candidate: its bits from the top, with the
  neighbours as they are seen (a transparent one replaced by the canvas
  under it), nine contexts (order 0; left;
  up; left and up; left, up, up-left, up-right; left, left-left, up,
  up-up; the previous frame's pixel with left and up; the previous frame's
  pixel, right and below; up-left, up, up-right), mixed by a logistic mixer
  chosen by the bit's position and whether left = up, the previous frame's
  pixel = left, up = up-right; then two adaptive probability maps (on left
  and on up). "The previous frame's pixel" is the canvas under it.
- **Everything else** (headers, palettes, extensions, the side
  information): orders 0 to 3, mixed.

The counters of a context sit in slots of 16 (a 64-byte cache line), one
for the high bits of a pixel and one for the low four (as lpaq does); the
tables are sized from the input (2^12 to 2^22 counters each), and a
zeroed table is the initial state, so nothing has to be filled.

Integer arithmetic only: the same bytes on every platform.

### Pascal and C

The pixel model's loop is in C as well (`pas/paiapix.c`), operation for
operation the same as `TPixelModel.CodeImagePascal`: the release build uses
the C, the checked build (range and overflow checks) the Pascal, and the
tests demand the same `.paia` from both. `-dPAIA_PURE` makes a release
build without C. C came in after measuring: with callgrind, the pixel
model was 94% of the instructions, the LZW analysis 4%.

### Measurements

The 62 `.gif` files of the sample corpus (25.96 MB; some are not GIF:
MacBinary, Maya, Paint Shop Pro, text), each compressed, extracted and
compared, all 62 coming back the same:

| | total | |
|---|---|---|
| PAIA 0.0.1, first version | 12,155,500 | 46.82% |
| PAIA 0.0.2 (the candidate flag) | 11,855,109 | 45.67% |
| PAIA 0.0.3 (the canvas) | 11,636,648 | **44.82%** |

The canvas matters most for optimized animations (frames as small
rectangles at an offset, with transparency): earthmorph3.gif 58.1% ->
44.1%, aol.gif 51.5% -> 39.7%, and on 8 GIFs made with ffmpeg and
ImageMagick's `-layers Optimize` from videos of the sample corpus (13.1
MB): 57.45% -> 54.79% (xz -9e: 98.15%).
| xz -9e | 24,817,388 | 95.60% |
| 7z -mx9 (LZMA2) | 24,817,882 | 95.60% |

Every image found in the corpus came back exactly; on the largest files,
59 exceptions in 5.9 MB (`example.gif`) and none in most.

**Speed** is per pixel, not per byte: a GIF holds its pixels compressed
10 to 50 times, so a 0.8 MB file can be 11 million pixels. On 10 files of
the corpus (1.86 MB, 20.9 million pixels; best of 2, one core, other work
on the machine), compressing (which also decodes, to verify) and
extracting:

| version | compress | extract | size |
|---|---|---|---|
| 0.0.1, Pascal | 61.3 s | 30.8 s | 41.19% |
| counters in one word, in cache-line slots, sized tables | 53.3 s | 24.7 s | 41.19% |
| the candidate flag | 31.3 s | 13.8 s | 40.06% |
| the pixel model in C | 22.4 s | 9.1 s | 40.06% |
| contexts hashed only when the flag misses; gcc -O3 | 19.4 s | 7.9 s | 40.06% |
| fewer passes choosing the clear rule | 18.7 s | 7.7 s | 40.06% |
| the canvas | **20.1 s** | **8.1 s** | **35.64%** |

That is 2.6 million pixels a second extracting, 1.0 compressing; 3x and
3.8x faster than the first version. The Pascal-only build: 29.7 s and 12.6 s.

Not yet good:
- **Files that are not GIF** (or the non-GIF part of one): orders 0-3 lose
  to xz on some (an Inventor file, a Windows resource).

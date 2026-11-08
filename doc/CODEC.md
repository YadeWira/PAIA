# PAIA codec

Status: **proof of concept**, stream version 8 (written since 0.1.0, and
read forever: [STABILITY.md](STABILITY.md)).

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
  information): orders 0 to 3 and a match model, mixed.

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
| PAIA 0.0.3 (the canvas) | 11,636,648 | 44.82% |
| PAIA 0.0.4 (a match model for the plain bytes) | 11,628,335 | 44.79% |
| PAIA 0.0.10 (learning rates) | 10,921,800 | **42.07%** |

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

### Learning rates (0.0.10)

The mixers had kept the rates they were given first. Swept on the 10
files of the speed set, one setting at a time: the pixel bits' and the
flag's mixers learning at 1/2^11 instead of 4/2^10 (-5.5%), counters that
stop slowing down sooner (their rate floors at 1/32 instead of 1/257) and
faster adaptive probability maps (-1%). 661,669 -> 619,078 bytes (-6.4%).
On files the sweep did not see: the GIF corpus 44.79% -> 42.07%, the
optimized GIFs 54.78% -> 52.13%. The C model takes the mixer's shift
from the Pascal side too, and gives the same bytes.

The same sweep, model by model, on files of their own formats (0.0.11):

| model | what it codes | change | set | gain |
|---|---|---|---|---|
| FLIC pixels and tokens | FLI/FLC chunks | both mixers at 1/2^11, a faster APM | 6 FLICs, 2.6 MB | -3.7% |
| bitmap bytes (`TDibModel`) | ANI bitmaps, IFF ANIM planes, VP8L literals | mixer at 1/2^11 | 4 ANIs, 4 ANIMs, 4 WebPs, 10.3 MB | -3.5% |
| VP8L tokens | VP8L structure and symbols | mixer at 1/2^11 | 4 lossless WebPs | -0.7% |
| IFF ANIM tokens | ANIM structure | mixer at 1/2^11 | the 14 ANIMs | -0.7% |
| plain bytes | headers, palettes, other files | mixer at 2/2^10 | 21 files that are not FLICs | -1.8% |

Counters that stop slowing down sooner, or later, did not help any of
them (unlike GIF's).

## FLI and FLC (`pas/paiafli.pas`)

Autodesk Animator's FLICs (8 bits a pixel) keep their frames as chunks of
simple codes: BYTE_RUN (a whole frame, run-length coded), DELTA_FLI (byte
runs against the previous frame), DELTA_FLC (the same in 16-bit words),
COPY and BLACK. These are not decoded and rebuilt as GIF's LZW is: each
chunk's bytes are coded **in their own order, field by field**, the coder
knowing at every byte what it is:

- a field of the structure (a line's packet count, a skip, a run length,
  a line count, SS2's opcodes) goes to a token model: its kind, and the
  same kind's last value or the room left on the line, as contexts;
- a pixel goes to a pixel model that sees the image as the chunks build
  it: its neighbours there, and what was at its place (and right of it,
  below it) before this chunk changed it;
- both also have a match model: an animation that loops, or repeats a
  stretch, finds it again however far back it is.

So any chunk comes back exactly, whatever its encoder did (a wrong packet
count in a BYTE_RUN line, padding, runs past the edge): there is nothing to
predict about the encoder and nothing to check but the whole file. A
BYTE_RUN line's packet count, which decoders ignore, is coded after the
line's packets, knowing how many there were. Palettes, stamps, prefix
chunks, 16-bit FLICs and unknown chunks stay with the plain bytes.

| 29 FLICs of the sample corpus (18.1 MB) | total | |
|---|---|---|
| PAIA 0.0.4 | 5,860,651 | 32.43% |
| PAIA 0.0.11 (learning rates) | 5,614,008 | **31.07%** |
| xz -9e | 8,394,672 | 46.45% |

Each came back the same (and the 22 files named `.fli`/`.flc` there that
are not FLICs: 88.35%, xz 87.23%). The model is Pascal only for now: a
2.8 MB FLIC (306 frames of 160x100) takes 8 s to compress and verify.

## ANI (`pas/paiadib.pas`)

A Windows animated cursor is a RIFF "ACON" whose frames are ICO or CUR
files, and their images are device-independent bitmaps, not compressed
(PNG ones stay as bytes). As for FLICs, each bitmap's rows (the colour
bitmap, then the 1-bit AND mask) are coded byte by byte in their own
order, each byte knowing its channel and its place, so they come back
exactly by construction. The contexts: the same channel's left, up and
diagonal neighbours, a gradient (left + up - up-left), the channel coded
before in the same pixel and how it changed from the left one (B -> G ->
R), the same byte of the previous frame of the same shape, and a match
model.

| 26 ANIs of the sample corpus (12.9 MB) | total | |
|---|---|---|
| PAIA 0.0.5 | 1,160,270 | 8.98% |
| PAIA 0.0.7 (repeated frames as references) | 1,161,523 | 8.98% |
| PAIA 0.0.11 (learning rates) | 1,055,316 | **8.16%** |
| xz -9e | 1,899,296 | 14.69% |

Each came back the same; so did the 40 files named `.ani` there that are
not ANIs (107 MB: 63.82%, xz 65.75%).

## IFF ANIM (`pas/paiaiff.pas`)

An Amiga ANIM is a FORM ANIM of FORM ILBMs: the first frame as a BODY
(bitplanes, row by row and plane by plane, ByteRun1-compressed or not),
each other as a DLTA. The deltas taken are method 5, Byte Vertical Delta,
by far the most used: for each plane a pointer, and for each column of
bytes a list of operations going down the rows (skip rows, repeat a byte,
take bytes as they are), setting or, in XOR mode, flipping the bits.

As for FLICs, a BODY's and a DLTA's bytes are coded in their own order,
field by field: the structure (pointers, operation counts, operations,
repeat counts, ByteRun1 headers) to a token model, the bitplane bytes to
a model that sees the bitmaps as the frames build them: what the byte
replaces, the frame shown before, the bytes above and to the left in its
plane, the plane below at the same place, and a match model. The frames
are double buffered, as Amiga players draw them: a delta changes the
frame two back (unless its ANHD says one back). The other reading, one
back, compresses worse on every file tried, as it should.

| 14 ANIMs of the sample corpus (6.1 MB) | total | |
|---|---|---|
| PAIA 0.0.5 (everything as plain bytes) | 3,336,322 | 54.47% |
| PAIA 0.0.6 | 2,842,474 | 46.41% |
| PAIA 0.0.11 (learning rates) | 2,760,975 | **45.08%** |
| xz -9e | 3,198,248 | 52.22% |

Each came back the same. Not taken yet: delta methods 3 and 74 ("J"),
0.9 MB of the corpus, on whose two files xz is still smaller.

## WebP (`pas/paiawebp.pas`): VP8L

Lossless WebP frames (VP8L chunks) and the lossless alpha of lossy ones
(ALPH chunks, compression 1: a VP8L stream without its header) are taken.
A VP8L encoder chooses a great deal (transforms, prefix codes, matches,
cache), and none of it is guessed: the stream is walked field by field as
a decoder reads it (the header, the transforms and their sub-images, the
colour cache, the meta prefix codes, each prefix code as its code lengths
were written, simple or not, with the repeat codes and the maximum
symbol) and each field's value is coded; the pixels as what they are: a
literal (green, red, blue, alpha: through a pixel model with the
neighbours in the same image, the green of the same pixel, and the
previous frame's image of the same size), a copy (length and distance,
prefix symbols and extra bits) or a cache reference. Extracting walks the
same fields and writes each symbol with its own code, under the same code
lengths: the same bits, by construction.

One walk checks a stream (a stream it refuses stays as bytes), encodes it
and decodes it, so the three cannot disagree. The pixel values are
context only (the transforms are not undone): an error there would cost
compression, never exactness.

Records whose data is the same as an earlier record's of the same kind
(a repeated frame: an animation that holds still, a cursor that comes
back) are coded as how far back that record is, for every format taken.

| 11 animated WebPs (6.0 MB: 7 lossless; 4 lossy with lossless alpha) | total | |
|---|---|---|
| PAIA 0.0.6 (everything as plain bytes) | 5,349,438 | 89.61% |
| PAIA 0.0.7 | 4,948,533 | **82.90%** |
| xz -9e | 5,312,648 | 88.99% |

Made with gif2webp (lossless, lossy, mixed, `-m 6`) and ffmpeg's libwebp
from the GIFs and videos of the sample corpus, plus its two animated
WebPs; each came back the same. The lossless frames are 4 to 15% smaller
than VP8L made them.

### A canvas for VP8L frames

Animated WebPs made from GIFs are palette images, a frame at an offset,
blended over the ones before, with what did not change made transparent.
So, as for GIF, the frames are composed on a canvas, in colours: each
frame's palette (the colour-indexing transform's table, its entries
differences from the one before) gives its colours, a transparent pixel
of a blended frame leaves the canvas as it was, and a disposed frame's
rectangle is cleared before the next one. Each pixel then has, as
context, which index of this frame's palette the canvas shows there
(packed as the pixel packs its indices), together with the palette's
transparent index; and the choice of a literal, a copy or a cache
reference sees whether the canvas has an index there, and whether it is
the transparent one or the left pixel's.

On 4 lossless animated WebPs (1.2 MB): 1,071,624 -> 1,031,558 (-3.7%);
on the 11 animated WebPs, 81.00% -> 78.46%. (The predictor transform's
mode as a context too: these frames have none, so it changed nothing
there.)

## WebP (`pas/paiavp8.pas`): VP8

Lossy frames are VP8 key frames: a header and partitions, each a
boolean-coded stream (binary arithmetic coding with 8-bit probabilities):
the first with the frame header, the coefficient probabilities and each
macroblock's modes, the others with the coefficients' tokens. A boolean
decoder given the right probabilities and an encoder given the same
decisions with the same probabilities are exact inverses. So each decision
is read with its probability, as libwebp reads it, and coded by a model
that mixes that probability with what VP8 does not look at: the
coefficients at the same place in the blocks above and to the left (the
idea of Lepton and packJPG), how many are non-zero so far in the block,
the last one's size, its place. Extracting writes the decisions again with
libwebp's own boolean writer: the bytes come back equal up to each
partition's end, and on libwebp's streams usually to the last byte; what
differs there (another writer's flush, bytes past the end) is kept.

A wrong context, or a wrong table, could only make a decision be read with
another probability and written again with that same one: it would cost
compression, never exactness.

| 11 animated WebPs | total | |
|---|---|---|
| PAIA 0.0.7 (VP8L) | 4,948,533 | 82.90% |
| PAIA 0.0.8 (and VP8) | 4,835,369 | 81.00% |
| PAIA 0.0.9 (VP8 contexts, a canvas for VP8L) | 4,683,816 | 78.46% |
| PAIA 0.0.11 (learning rates) | 4,610,306 | **77.23%** |
| xz -9e | 5,312,648 | 88.99% |

Lossy frames come out 4 to 9% smaller (sample1.webp, a still: 9.1%).

Then, on 7 WebPs with lossy frames (3.3 MB), measured one change at a
time: the neighbours' non-zero counts, the magnitudes above and to the
left apart rather than summed, and the macroblock's quantizer as contexts
(-1.25%); a mixer chosen also by the non-zeros so far, and a second
adaptive probability map (-0.3%); the mixer learning at a quarter of the
rate (-0.6%). In all 2,466,668 -> 2,420,168 bytes (-1.9%). A slower rate
still, or counters adapting more slowly or faster, did not help. The
8 WebPs of the sample corpus, stills included: 86.96%, xz 93.89%.

Not yet good:
- **Files that are not GIF** (or the non-GIF part of one): orders 0-3 lose
  to xz on some (an Inventor file, a Windows resource).

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

- **Pixels**: one bit at a time from the top, nine contexts (order 0; left;
  up; left and up; left, up, up-left, up-right; left, left-left, up,
  up-up; the previous frame's pixel with left and up; the previous frame's
  pixel, right and below; up-left, up, up-right), mixed by a logistic mixer
  chosen by the bit's position and whether left = up, the previous frame's
  pixel = left, up = up-right; then two adaptive probability maps (on left
  and on up). "The previous frame" is the last image of the same width.
- **Everything else** (headers, palettes, extensions, the side
  information): orders 0 to 3, mixed.

Integer arithmetic only: the same bytes on every platform.

### First measurements (01/11/2026)

The 62 `.gif` files of the sample corpus (25.96 MB; some are not GIF:
MacBinary, Maya, Paint Shop Pro, text), each compressed, extracted and
compared, all 62 coming back the same:

| | total | |
|---|---|---|
| PAIA 0.0.1 | 12,155,500 | **46.82%** |
| xz -9e | 24,817,388 | 95.60% |
| 7z -mx9 (LZMA2) | 24,817,882 | 95.60% |

Every image found in the corpus came back exactly; on the largest files,
59 exceptions in 5.9 MB (`example.gif`) and none in most.

Not yet good:
- **Speed**: about 0.1 MB/s compressing (which decodes to verify) and 0.2
  MB/s extracting, all in Pascal, one thread. 5.9 MB: 55 s / 29 s.
- **Small files**: the model's tables (about 90 MB) are cleared for every
  file, 0.3 s each.
- **Files that are not GIF** (or the non-GIF part of one): orders 0-3 lose
  to xz on some (an Inventor file, a Windows resource).

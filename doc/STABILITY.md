# What does not change

No format of PAIA is frozen yet: as in the whole family, a format is
frozen in a 0.9.x release, once it is mature, and 1.0.0 comes with 7-Zip
method IDs of PAIA's own. Until a format is frozen, a release may write
it differently, but **whatever a release has published is read by every
release after it**: a `.paia` written by 0.1.0 opens, byte for byte, in
every later version. A change to what PAIA writes comes as a new version
beside the old one (a new codec stream version, a new codec name), never
as a change to one that a release has written.

What may change at any time: speed, the encoder's choices within a
format, and the files PAIA takes (more, never fewer).

## The `.paia` file

`pas/paiacli.pas` (the layout is in its header comment). Magic `PAIA`,
version 1 (written since 0.1.0): the stored flag; the original's size,
BLAKE3-128 and extension. Read forever.

## The codec stream

`pas/paiacodec.pas` (layout) and `doc/CODEC.md` (models).

| version | written by | what |
|---|---|---|
| 8 | 0.1.0, 0.2.0 (the command, and the zpaq-std plugin's codecs) | a file's bytes without the image data it takes, and the records: GIF images (kind 0), FLIC chunks (1), ANI bitmaps (2), IFF ANIM chunks (3), WebP VP8L streams (4), WebP VP8 frames (5), and records repeating an earlier one |
| 9 | the next release (not published yet: may still change) | version 8's layout and models, as the work towards the next release changes them |

Version 8 as 0.1.0 writes it is read forever: its layout, the records'
fields, and the models that code them (contexts, counters, mixers,
maps, tables and constants), bit for bit. A later model or layout is a
new version (9 and up), and the decoder for version 8 stays. That decoder is a
frozen copy of the codec as 0.2.0 has it, in its own units
(`pas/paia8*.pas` and `pas/paia8pix.c`), which are never changed: the
live codec can change its models freely, and version 8 keeps decoding
exactly as it did. Versions 1
to 7 were only written by builds before 0.1.0, never by a release, and
are not read.

A release refuses a stream version it does not know before decoding it
("unknown stream version"), never reads it as another.

`tests/paia010/` holds files that the 0.1.0 release wrote, one or more
for each kind of record; `.github/test.sh` (on every CI platform) and
`run_tests.sh` extract them with the version being tested and compare
them with the samples they came from.

## The zpaq-std codecs

`doc/PLUGIN.md`. Experimental, for `-sat` only, without a ZPAQL decoder
yet: `paiagif1`, `paiaflc1`, `paiaani1`, `paiaanim1`, `paiawebp1`, all
writing codec stream version 8. A name is frozen (its index, its stream,
what it takes and its ZPAQL decoder, byte for byte, forever) when a
release first ships it with a ZPAQL decoder; a new stream or another
decoder is a new name (`paiagif2`...). No name ends in `z`, `o` or `8`.

## 7-Zip

No library or 7-Zip method yet. PAIA's experimental method IDs, when it
has them, are `03 7F 40` to `03 7F 4F` (the family's decade for PAIA),
until 1.0.0 brings IDs of its own.

# paia: the command

```
paia a [options] FILE...    compress each FILE into FILE's name with .paia
paia x [options] FILE...    extract each .paia into its name with the original's extension
paia t [options] FILE...    test: extract in memory and check, write nothing
paia --version
```

| option | |
|---|---|
| `-o DIR` | write into DIR instead of next to each input |
| `-f` | overwrite an output that exists (otherwise it is an error) |
| `-q` | quiet: only errors |

```sh
paia a anim.gif                 # -> anim.paia
paia x anim.paia                # -> anim.gif, the same file byte for byte
paia a -o packed *.gif *.webp   # many at once, into packed/
paia t packed/*.paia            # check them
```

Any file can be given: PAIA finds by their content the GIF images, FLIC
chunks, ANI bitmaps, IFF ANIM frames and WebP streams in it (whatever its
name), and codes everything else as plain bytes. A file it would not make
smaller is stored as it is (37 bytes more and its extension's).

**Nothing is written unless it verified.** `a` decompresses its own result
and compares it with the input before writing; if they differ (a bug), the
file is stored as it is and `a` says `codec failed`. `x` and `t` check the
size and the BLAKE3-128 hash the `.paia` carries, and refuse a damaged
file. Outputs are written under a temporary name and renamed: never a half
file under the final name.

`a` prints, for each file, its size before and after and what it found
(GIF images taken / found, FLIC chunks, ANI bitmaps, IFF chunks, VP8L
streams, VP8 frames).

Exit status: 0 if every file went well, 1 if any failed, 2 for a wrong
command line.

**Compatibility:** until PAIA 1.0.0 the format may change between
versions: a `.paia` made by a 0.x version may not open in a later one
(it is refused, as an unknown version, rather than misread). From 1.0.0
on, every `.paia` will open in every later version.

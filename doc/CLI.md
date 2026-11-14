# The `paia` command

```
paia a [options] FILE...     compress:  anim.gif -> anim.paia, intro.flc -> intro.paia
paia x [options] FILE...     extract:   anim.paia -> anim.gif (the original's extension)
paia list FILE...            what each .paia holds: original size, stored size, hash
paia t FILE...               test each .paia: extract and verify in memory, write nothing
paia info FILE...            the structure of each file, and what PAIA does with it
paia report [FILE]           a bug report (no pixels, no metadata) and a link to open an issue
paia bench FILE...           how fast this machine runs a, a --no-verify and x on them
paia selftest                the samples inside the binary, on every path of the model here
paia --version, paia -V      the build, the compilers, the system and the model's path
```

The command is the family's (PJA's `pja`, PPA's `ppa`): the same
switches, exit codes, `--json` fields and guarantees, with PAIA's formats.

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory, and nothing else |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | threads; by default the processors, up to 8. Several files at once, one a thread, the largest first; each file's lines still come out in the order of the inputs. Threads change no output |
| `--max-output=SIZE` | `x`, `t`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit) |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` (`paia.corrupt` beside it if that name would be too long) |
| `--no-verify` | `a`: do not decompress the stream to check it before writing. About twice as fast; a codec bug would then only show when extracting, where the hash catches it. The `.paia` is the same byte for byte |
| `--no-sync` | `a`, `x`, `report`, `bench`: do not wait for each output to reach the disk before it takes its name. A few percent faster on a real disk, but after a power cut an output may be empty or missing ([below](#interrupted-runs)) |
| `--clean-temps` | `a`, `x`: delete the temporaries an interrupted run left in the directories this run writes to: only PAIA's (`.paia-tmp-PID-N`), only regular files, only older than an hour, and never one whose process is still running ([below](#interrupted-runs)) |
| `-n`, `--dry-run` | do everything but write: an output that exists, or that two inputs share, or (`x`) a `.paia` whose size or hash does not match, fails as it would for real |
| `-q`, `--quiet` | only errors (`--stats` lines still come out, each under its file's name) |
| `--stats` | `a`, `x`, `t`: after each file, where its time went (below); then a line for the run: files, bytes in and out, time, MB/s of the originals |
| `--json` | `a`, `x`, `t`, `info`, `list`: one JSON object a line for each file, in the order of the inputs, then `{"summary": ...}`; errors still go to stderr as well |
| `--cpu=PATH` | the model's path: `pascal` or `c`, before or after the command (`--cpu c`, with a space, is refused naming `--cpu=c`). A path this build lacks is refused (exit 2) naming those it has. Both write and read the same bytes: only the speed changes (`selftest` proves it) |
| `-o REPORT` | `report`: the file the report goes to (never over an existing one) |
| `--with-file` | `report`: also copy the file beside the report as `paia-report-NAME`, to attach if you choose to (without FILE it is refused: exit 2) |
| `-r N` | `bench`: runs of each measure, the best one counts (3 by default) |
| `--` | everything after it is a file, even if it starts with a dash |

```sh
paia a anim.gif                     # -> anim.paia
paia x anim.paia                    # -> anim.gif, the same file byte for byte
paia a -o packed/ *.gif *.webp      # many at once, into packed/
paia t packed/*.paia                # check them
```

Any file can be given: PAIA finds by their content the GIF images, FLIC
chunks, ANI bitmaps, IFF ANIM frames and WebP streams in it (whatever its
name), and codes everything else as plain bytes. `a`'s line says what it
took: `(5 of 5 GIF images)`, `(9 FLIC chunks)`, `(nothing PAIA models)`.

All warnings and errors go to stderr.

| exit status | when |
|---|---|
| 0 | every file went through (`t`: every `.paia` verified; `selftest`: every check passed) |
| 1 | a file failed: it is not what the command takes, it is damaged, it could not be read or written (each with its line on stderr); the command's own output could not be written (`paia: could not write the output: ...`); `selftest`: a check failed |
| 2 | usage error: an unknown command or option, a value out of range, an option for another command, `--cpu` with a path not here |
| 3 | a bug in PAIA: an exception that is not about the file or the system (a range check, an access violation; not a read or a write the system refused, nor memory it did not give), or a stream of `a`'s own that did not come back (the file is then stored as it is, so nothing is lost). The run ends with `This is a bug in PAIA. Please run: paia report FILE and open an issue at https://github.com/YadeWira/PAIA/issues` |
| 130, 143, 129, 141 | ended by SIGINT (Ctrl-C), SIGTERM, SIGHUP or SIGPIPE, after deleting the temporaries it was writing ([below](#interrupted-runs)); `STATUS_CONTROL_C_EXIT` on Windows |

## Checking and reporting

### `paia t FILE...`

What `x` does, without writing: the format, the declared size against
`--max-output`, decoding, then the size and the BLAKE3-128. A line
`NAME: OK` for each one that verifies, `paia: NAME: FAILED: why` on stderr
for each that does not (exit 1). `-o`, `-f`, `-n` and `--keep-corrupt` are
refused (exit 2).

### `paia info FILE...`

Any file: what it is and what PAIA does with it, as the codec's own
finders see it (`pas/paiainfoimg.pas`): sizes, places and shapes only,
never pixels, nor what the metadata says.

- **GIF**: the canvas, the images (each with its size, place, LZW bytes,
  disposal, interlacing, transparency; the first 64 listed, the rest
  counted), how many GIF streams the file holds (a GIF after a header too).
- **FLI/FLC**: the frame size, the depth, the frames, the pixel chunks and
  their bytes, by type (`DELTA_FLC`, `DELTA_FLI`, `BLACK`, `BYTE_RUN`,
  `COPY`).
- **ANI**: its bitmaps, each with its size, bits and bytes.
- **IFF ANIM**: the frame size, the planes, the bodies and byte-vertical
  deltas PAIA takes.
- **WebP**: the canvas, the VP8L streams (and lossless alpha) and the VP8
  frames, with their bytes.
- **`.paia`**: the container (version, original size, hash, extension,
  stored or not) and the stream (version, table sizes).

Then `paia:` what `a` would do (a dry run, with `a`'s verification):
`takes it: stream version 8, 9524 B -> 690 B (7.24%); 9 FLIC chunk(s)`,
or `stores it as is (no smaller)`; for a `.paia`, whether `x` extracts it.
Exit 1 only for a file that cannot be read. `--json` gives the same tree.

### `paia report [FILE] [-o REPORT.txt] [--with-file]`

A plain-text bug report, to stdout or to `-o`'s file: PAIA's version,
commit, build date, the compilers, the target, the system, the processor,
the model's path, the threads; the command line, each path cut to its name;
for FILE its size, BLAKE3-128, structure and what PAIA does with it, as
`info` gives them (up to 64 MB; above, the structure alone). No pixels, no
metadata contents, no folder names. A report on a file that hits a bug
says so (`internal_error`) instead of ending.

Then a link that opens a new issue on GitHub with the report in it; a
report too long for a link (about 6000 characters) keeps its start and its
end, says how many lines were cut, and asks to paste the whole report.
`--with-file` copies FILE beside the report as `paia-report-NAME` (never
over an existing file): it goes nowhere unless you attach it; GitHub takes
a `.gif` as it is, anything else zipped. Without FILE, the system part
alone.

### `paia bench FILE... [-r N] [-th N]`

The system part of the report, then for each file the best of N runs of
`a`, `a --no-verify` and `x`, in milliseconds and MB/s of the original,
with where `a`'s and `x`'s time went, and the write of the `.paia` alone;
then the totals. Everything is in memory but that write, which goes to a
folder of its own in the system's temporary folder and is deleted. A
`.paia` given is only extracted.

### `paia selftest`

The binary carries five small samples (a GIF animation, a FLIC with every
chunk kind, an ANI with repeated frames, an IFF ANIM in XOR mode, a lossy
WebP with lossless alpha: `pas/paiaselftest.inc`, written by
`tests/tools/gen_selftest.py`) and the `.paia` each one has to give. On
every path of the model this build has, each is compressed, compared byte
for byte with its expected `.paia` (whose BLAKE3-128 it prints), and
extracted back. `--cpu=PATH` checks that path alone. Exit 0 only if every
check passed. CI runs it on every platform, for the three builds.

### `paia --version`

```
paia 0.2.0
commit: 41129dd
built: 2026/11/07
fpc: 3.2.2
c_compiler: gcc 14.2.0
target: x86_64-linux
system: Linux 6.12.115 x86_64
cpu: Intel(R) Xeon(R) CPU E5-2697A v4 @ 2.60GHz
cpu_path: c
cpu_paths_supported: pascal c
processors: 64
default_threads: 8
```

The commit comes from `PAIA_COMMIT` at build time: `pas/build.sh` and
`.github/test.sh` set it from git when it is not set, `release.yml` from
the tag's commit; a build without it says `commit:` and nothing. The C
compiler names itself (`paiapix.c`).

### `--cpu=PATH`

GIF's pixel model exists in Pascal and, in the release build, in C
(`pas/paiapix.c`): the same bits, the C one faster. `c` is the default
where it is linked in; `--cpu=pascal` takes the Pascal one, to compare
speeds or to rule the C one out when chasing a bug. The builds without C
(`paia-pure`, the checked build) have `pascal` alone.

### `--stats`

```
anim.gif -> anim.paia  5235 B -> 1694 B  32.36%  (5 of 5 GIF images)
  stats: read 0.04 ms, encode 61.20 ms, verify 30.11 ms, hash 0.01 ms, write 0.10 ms; total 91.50 ms
```

The stages: `read` the input; `encode` the model; `verify` decoding the
stream to compare it with the input; `decode` (`x`, `t`); `hash` BLAKE3;
`write` the output, verified, flushed to the disk (unless `--no-sync`) and
renamed; `other` what falls between.

### `--json`

One object a line:

```
{"file":"anim.gif","output":"anim.paia","original_size":5235,"paia_size":1694,"ratio_percent":32.36,"stored":false,"records":"5 of 5 GIF images","ok":true}
{"summary":{"command":"a","files":1,"failed":0,"bugs":0,"bytes_in":5235,"bytes_out":1694,"seconds":0.09,"threads":8}}
```

| command | fields of each file (after `"file"`) |
|---|---|
| every one | `ok` (`true`: it went through; for `info`, it was read and described); `error` (what failed, as on stderr) when it did not; `internal_error` when it met a bug |
| `a` | `output`, `original_size`, `paia_size`, `ratio_percent`, `stored`, `records` (what the codec took, in words; `""` for nothing) |
| `x` | `output`, `original_size`, `paia_size` |
| `t` | `original_size`, `paia_size` |
| `list` | `original_size`, `paia_size`, `ratio_percent`, `stored`, `extension`, `blake3_128` |
| `info` | the tree the text shows: `format`, `size`, and the format's own; then `paia`: `command` (`a` or `x`), `ok`, `summary` (the line of the text), and for `a`: `takes`, `records` (`gif_images`, `gif_images_taken`, `flic_chunks`, `ani_bitmaps`, `iff_chunks`, `vp8l_streams`, `vp8_frames`, `flif_streams`, and `plain_bytes`: the bytes outside them, coded one by one), `stream`, `stream_version` (0 for stored as is), `paia_size`, `ratio_percent`, or `error`; for `x`: `original_size` or `error` |
| `--stats` (`a`, `x`, `t`) | `stats`: each stage's `NAME_ms`, `total_ms` |

The summary: `command`, `files`, `failed`, `bugs`, `bytes_in`, `bytes_out`,
`seconds`, `threads`.

## Nothing written that did not verify

- `a` writes the `.paia` only after the codec has decompressed its own
  stream and compared it with the input (unless `--no-verify`). A stream
  that does not come back is a bug: the original is stored as it is, and
  the run ends with 3. A file the codec would not make smaller is stored as
  it is (33 bytes more and its extension's), and `a` and `list` say so.
- `x` does, in order: validate the format; refuse a declared size above
  `--max-output` (and one above 65536 times the stream's size) **before**
  decoding; decode with that size as the cap; check the size **and** the
  hash; and only then write.
- Writing creates the file without following links, always as a temporary
  in the same directory (`.paia-tmp-PID-N`) that takes the output's name
  only once it is complete **and on the disk** (`fsync`; `FlushFileBuffers`
  on Windows), and on Unix the directory is flushed after the name is
  given: after a power cut the output is either whole or not there. If only
  that last flush fails, the run fails (rc 1) with `written, but its
  directory could not be flushed to the disk`: the output is in place and
  whole. Without `-f` the name is only taken if it is still free; with
  `-f` the temporary is renamed on top: what was there is only replaced by
  something that verified. Nothing that fails deletes a file this run did
  not write.

## Interrupted runs

- **Ctrl-C, `kill`, a closed terminal, a closed pipe**: SIGINT, SIGTERM,
  SIGHUP and SIGPIPE (on Windows Ctrl-C, Ctrl-Break and closing the
  console) delete the temporaries the run is still writing, and it ends as
  the signal would have ended it (130, 143, 129, 141). Outputs already
  written stay: each one verified. A signal ignored by whoever started
  `paia` (`nohup`) stays ignored.
- **`kill -9`, a crash, a power cut**: a `.paia-tmp-PID-N` may stay. The
  next run that writes in that directory names them on stderr (`found 1
  leftover temporary of an interrupted run: ...; --clean-temps deletes
  them`) and deletes nothing unless `--clean-temps` is given; then only
  PAIA's own names, only regular files, only older than an hour, and never
  one whose process is still running on this machine (so do not use it in
  a directory another machine may be writing to).
- **The flush beside the work**: each flush waits on the disk, so `a` and
  `x` hand each file's write, flush and rename to a thread of their own and
  go on with the next file; the same files, lines, `--json` and exit code.
  Not with `--no-sync`, `-n` or `--stats`; `PAIA_SYNC_INLINE=1` writes in
  the file's own thread.

## Choices, and why

- **An existing output is refused without `-f`.** Otherwise
  `paia a -o a.paia b.gif` silently replaces `a.paia`.
- **`-o` behaves like the destination of `cp`**: an existing directory or a
  path ending in `/` is a directory, anything else a name. With more than
  one input, a destination that is not a directory is an error.
- **Two inputs with the same output in one run: the second fails**, with or
  without `-f` (`a.gif` and `a.GIF`, `d1/p.gif` and `d2/p.gif` with
  `--output-dir`), naming the input that took it; so does an output that is
  another input of the run.
- **On Unix a backslash is part of the name**, not a separator.
- **Values with `=` or a space, never glued**: `-th 4` or `--threads=4`.
- **`a` and `x` are filters**: `a` refuses a `.paia`, `x` anything that is
  not one.
- **The output keeps the original's extension**, as it was written:
  `Anim.GIF` comes back as `Anim.GIF`. When there is none to keep (an
  extension the format does not take: more than 15 characters, or anything
  but letters, digits, `_` and `-`), the content decides: `.gif`, `.fli`,
  `.flc`, `.ani`, `.anim`, `.webp`, or `.bin`.
- **On Windows, `paia` expands `*` and `?` itself**, because neither `cmd`
  nor PowerShell does it for a program: `paia a anims\*.gif` takes every
  file that matches, in order of name. A pattern that matches nothing fails
  as `no file matches`. Names are read in UTF-16 and kept in UTF-8.
- **What `paia` prints is UTF-8, and every character shows on a Windows
  console.** To a console it writes UTF-16 (`WriteConsoleW`), without
  changing the console's code page; to a file or a pipe, UTF-8, so `--json`
  and `report` read the same on every system. Standard output and error
  are decided apart: `2> err.txt` with the output on the console works.
- **A write the system refuses is reported in its own words**, with the
  error number.

**Compatibility:** every `.paia` a release has written opens in every
later version ([STABILITY.md](STABILITY.md)); a version refuses, as
"unknown stream version", a stream written by a later one that it does not
know, rather than misreading it.

Tested by `tests/cli.sh` (133 cells: round trips, existing outputs, links,
damage, `--keep-corrupt`, `--max-output`, threads, outputs shared by two
inputs, a write cut short, signals, leftovers, every usage error; `t`,
`info`, `report` and its privacy, `bench`, `selftest`, `--cpu` on every
path here, `--stats`, `--json`, and the end of a run that meets a bug).

# Comparing PAIA with other tools

The scripts behind the README's tables and the wiki's Benchmarks and
Safety pages. They need the other tools built (precomp-cpp, paq8px), xz,
7z, zstd, brotli, bzip3 and zpaq on the PATH, and these variables:

| variable | |
|---|---|
| `PAIA` | the paia binary |
| `TOOLS` | a folder with `precomp-cpp/build/precomp` and `paq8px/build/paq8px` |
| `SETS` | a folder with one folder a set (`gif`, `flic`, `ani`, `anim`, `webp`), the files recognized by their content |
| `WORK` | a scratch folder |
| `ZPAQSTD` | `archivers.sh`: zpaq-std, with PAIA's plugin as `codecs/paia.so` beside it; `rcmd.sh`: with the `-ma` codecs too |
| `REJ` | `rcmd.sh`: the output of `rcmd_rejects.py` |

- `one.sh TOOL FILE OUTDIR`: one file through one tool (compress,
  decompress, compare); a line of tab-separated fields. Run it for every
  file and tool (`xargs -P`), then `summ.py` on the lines.
- `flips.py TOOL N`: N single-bit flips in each small GIF's compressed
  file; how each decompression ends.
- `fuzz.py TOOL N`: N damaged GIFs through the tool; those taken that do
  not come back.
- `archivers.sh`: one archive a set with 7-Zip, zpaq-std `-m5` and
  zpaq-std with PAIA's codecs; size, times, and the files compared.
- `rcmd_rejects.py PLUGIN SETS OUT`: the files of each format the plugin
  does not take (the corpus's own, and truncated or bit-flipped copies).
- `rcmd.sh`: every `-ma` codec and `-m1`..`-m5` on those files, a format at
  a time, for the `fallback_ma` / `fallback_m` lists of zpaq-std's `+rcmd`.

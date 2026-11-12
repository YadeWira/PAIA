#!/bin/bash
# rcmd.sh: the candidates for +rcmd's fallback_ma / fallback_m, on the
# files each of PAIA's codecs does not take (REJ/<format>/, from
# rcmd_rejects.py): one archive a format and candidate, its size, the time
# to write and to extract, and every file compared. ZPAQSTD: zpaq-std with
# the -ma codecs (its plugins download) in codecs/ beside it.
export LC_ALL=C
Z=${ZPAQSTD:?}; R=${REJ:?}; W=${WORK:?}
C=${CANDIDATES:-zstd:19 zstd:22 lzma:9 flzma2:10 uflzma2:11 brotli:11 bzip3:9 bsc:9 ppmd:6 ppmd:16 kanzi:9 lz:9 lzh:4 lz6:15 bzip2:9 deflate:12 lizard:49 zxc:7 m1 m2 m3 m4 m5}
now() { date +%s.%N; }
for k in gif flic ani anim webp; do
  dir=$R/$k; in=$(find "$dir" -type f -exec cat {} + | wc -c)
  for c in $C; do
    w=$W/rcmd_$k; rm -rf "$w"; mkdir -p "$w/x"
    case $c in m*) opt=-$c ;; *) opt=-ma:$c ;; esac
    t0=$(now); "$Z" a "$w/a.zpaq" "$dir/" $opt -t8 > /dev/null 2>&1; t1=$(now)
    (cd "$w/x" && "$Z" x ../a.zpaq -t8 -to . > /dev/null 2>&1); t2=$(now)
    out=$(stat -c %s "$w/a.zpaq")
    got=$(find "$w/x" -type d -name $k | head -1)
    ok=$(diff -r "$dir" "$got" > /dev/null 2>&1 && echo ok || echo DIFF)
    printf '%s\t%s\t%s\t%s\t%.2f\t%.2f\t%s\n' $k $c $in $out $(echo "$t1-$t0" | bc) $(echo "$t2-$t1" | bc) $ok
    rm -rf "$w"
  done
done

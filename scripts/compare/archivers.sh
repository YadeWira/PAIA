#!/bin/bash
# archivers.sh: one archive a folder, as the family measures zpaq-std with
# a codec (pack-algorithm's template): the same method on both sides
# (-m1 against -m1 with PAIA, -m5 against -m5 with PAIA), and 7-Zip -mx9
# for reference. Size, the time to write / extract, and every file
# compared. Folders: each set of SETS, and MIXED (the animated files
# among others).
export LC_ALL=C
W=${WORK:?}; S=${SETS:?}; Z=${ZPAQSTD:?zpaq-std, with codecs/paia.so beside it}
PAIA_SA=-sat:paia:paiagif1:paiaflc1:paiaani1:paiaanim1:paiawebp1
now() { date +%s.%N; }
for dir in ${FOLDERS:-$S/gif $S/flic $S/ani $S/anim $S/webp $MIXED}; do
  in=$(find "$dir" -type f -exec cat {} + | wc -c)
  for t in 7z m1 m1paia m5 m5paia; do
    w=$W/arch_$t; rm -rf $w; mkdir -p $w/x
    t0=$(now)
    case $t in
      7z) 7z a -mx9 -mmt8 -bso0 -bsp0 $w/a.7z "$dir/" > /dev/null ;;
      m1) "$Z" a $w/a.zpaq "$dir/" -m1 -t8 > /dev/null 2>&1 ;;
      m1paia) "$Z" a $w/a.zpaq "$dir/" -m1 -t8 $PAIA_SA > /dev/null 2>&1 ;;
      m5) "$Z" a $w/a.zpaq "$dir/" -m5 -t8 > /dev/null 2>&1 ;;
      m5paia) "$Z" a $w/a.zpaq "$dir/" -m5 -t8 $PAIA_SA > /dev/null 2>&1 ;;
    esac
    t1=$(now)
    case $t in
      7z) (cd $w/x && 7z x -mmt8 -bso0 -bsp0 ../a.7z > /dev/null) ;;
      *) (cd $w/x && "$Z" x ../a.zpaq -t8 -to . > /dev/null 2>&1) ;;
    esac
    t2=$(now)
    out=$(stat -c %s $w/a.* | head -1)
    got=$(find $w/x -type d -name "$(basename "$dir")" | head -1)
    ok=$(diff -r "$dir" "$got" > /dev/null 2>&1 && echo ok || echo DIFF)
    printf '%s\t%s\t%s\t%s\t%.1f\t%.1f\t%s\n' "$(basename "$dir")" $t $in $out $(echo "$t1-$t0" | bc) $(echo "$t2-$t1" | bc) $ok
    rm -rf $w
  done
done

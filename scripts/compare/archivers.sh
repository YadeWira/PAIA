#!/bin/bash
export LC_ALL=C
A=${WORK:?}; S=${SETS:?}; Z=${ZPAQSTD:?zpaq-std, with codecs/paia.so beside it}
now() { date +%s.%N; }
for s in gif flic ani anim webp; do
  in=$(cat $S/$s/* | wc -c)
  for t in 7z zpaq5 zpaqpaia; do
    w=$A/w_$s_$t; rm -rf $w; mkdir -p $w/x; cd $A
    t0=$(now)
    case $t in
      7z) 7z a -mx9 -mmt8 -bso0 -bsp0 $w/a.7z $S/$s/ > /dev/null ;;
      zpaq5) "$Z" a $w/a.zpaq $S/$s/ -m5 -t8 > /dev/null 2>&1 ;;
      zpaqpaia) "$Z" a $w/a.zpaq $S/$s/ -m3 -t8 -sat:paia:paiagif1:paiaflc1:paiaani1:paiaanim1:paiawebp1 > /dev/null 2>&1 ;;
    esac
    t1=$(now)
    case $t in
      7z) (cd $w/x && 7z x -mmt8 -bso0 -bsp0 ../a.7z > /dev/null) ;;
      *) (cd $w/x && "$Z" x ../a.zpaq -t8 -to . > /dev/null 2>&1) ;;
    esac
    t2=$(now)
    out=$(stat -c %s $w/a.* | head -1)
    ok=$(diff -r $S/$s $(find $w/x -type d -name $s | head -1) > /dev/null 2>&1 && echo ok || echo DIFF)
    printf '%s\t%s\t%s\t%s\t%.1f\t%.1f\t%s\n' $s $t $in $out $(echo "$t1-$t0"|bc) $(echo "$t2-$t1"|bc) $ok
    rm -rf $w
  done
done

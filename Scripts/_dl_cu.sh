#!/usr/bin/env bash
set -u
cd /d/WimMount/Updates || exit 1
F=windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu
URL='https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/4225b261-8248-43e5-a808-34f3faafe3f6/public/windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu'
TOTAL=5308811935
HAVE=$(stat -c%s "$F")
echo "have=$HAVE total=$TOTAL"
[ "$HAVE" -ge "$TOTAL" ] && { echo "already complete"; exit 0; }
REST=$(( TOTAL - HAVE ))
N=6
CH=$(( REST / N ))
rm -f part_*.bin
pids=""
for i in $(seq 0 $((N-1))); do
  S=$(( HAVE + i * CH ))
  if [ "$i" -eq $((N-1)) ]; then E=$(( TOTAL - 1 )); else E=$(( HAVE + (i+1) * CH - 1 )); fi
  curl.exe -sS --fail --retry 5 --retry-delay 2 -r "$S-$E" -o "part_$i.bin" "$URL" &
  pids="$pids $!"
done
fail=0
for p in $pids; do wait "$p" || fail=1; done
echo "curl fail=$fail"
for i in $(seq 0 $((N-1))); do
  sz=$(stat -c%s "part_$i.bin" 2>/dev/null || echo 0)
  S=$(( HAVE + i * CH ))
  if [ "$i" -eq $((N-1)) ]; then E=$(( TOTAL - 1 )); else E=$(( HAVE + (i+1) * CH - 1 )); fi
  want=$(( E - S + 1 ))
  echo "part_$i size=$sz want=$want"
  [ "$sz" -eq "$want" ] || fail=1
done
if [ "$fail" -ne 0 ]; then echo "INCOMPLETE"; exit 1; fi
for i in $(seq 0 $((N-1))); do cat "part_$i.bin" >> "$F"; done
rm -f part_*.bin
echo "final=$(stat -c%s "$F")"

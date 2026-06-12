#!/bin/zsh
# capture.sh <out.png> [refgallery args...] — launch the reference app in
# --hold mode and screenshot its window (window-server pixels, so Liquid
# Glass renders for real). Requires Screen Recording permission for the
# invoking terminal.
set -e
out=$1; shift
dir=${0:a:h}
log=$(mktemp)
"$dir/refgallery" --hold "$@" > "$log" 2>&1 &
pid=$!
for i in {1..50}; do
  grep -q WINDOWID "$log" && break
  sleep 0.2
done
wid=$(grep WINDOWID "$log" | awk '{print $2}')
sleep 0.6   # let overlay animations settle
screencapture -o -x -l "$wid" "$out"
kill $pid 2>/dev/null || true
echo "captured $out"

#!/usr/bin/env bash
# WHERE does the RSS go, mapping class by mapping class, with no valgrind in the way?
#
# massif says the memory the program holds through malloc stays ~109 MB (it grew 1.9 MB while RSS grew
# 15 MB), and pinning glibc's mmap threshold changed nothing (base +41 vs pinned +37 MB in 5 min). So the
# question is no longer "which allocator knob" but "which mapping": [heap] (brk, malloc's arena),
# anonymous mmaps (thread stacks, arena mmaps, a library mapping memory directly), or a file mapping.
#
# Usage: bash sdi-rss-map.sh [seconds]
set -uo pipefail
DURATION="${1:-300}"
TS="${TS:-/home/blackgate/.hermes/cache/scratch/int1080i-v.ts}"
CPUS="${CPUS:-4-6}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
A="$WORK/smaps-start.txt"; B="$WORK/smaps-end.txt"
SRC="multifilesrc location=$TS loop=true caps=video/mpegts"
Q2="queue2 use-buffering=false max-size-buffers=0 max-size-bytes=0 max-size-time=5000000000"
CHAIN="$SRC ! tsdemux ! $Q2 ! h264parse ! avdec_h264 ! fakesink sync=false"

echo "chain: decode-only, no valgrind, pinned to cores $CPUS for $DURATION s"
trap 'kill ${GPID:-} 2>/dev/null' EXIT INT TERM
taskset -c "$CPUS" gst-launch-1.0 -e -q $CHAIN >"$WORK/rss-map.log" 2>&1 &
GPID=$!
sleep 20
kill -0 "$GPID" 2>/dev/null || { echo "FAIL: died at startup"; tail -3 "$WORK/rss-map.log"; exit 3; }

stat() { awk '/VmRSS/{r=$2} /VmData/{d=$2} END{printf "%d %d", r/1024, d/1024}' "/proc/$GPID/status"; }
read -r RSS0 DATA0 <<<"$(stat)"
rm -f "$A"; cp "/proc/$GPID/smaps" "$A" || { echo "FAIL: cannot write $A"; exit 4; }; chmod u+w "$A"
echo "  start: rss=$RSS0 MB vmdata=$DATA0 MB threads=$(ls /proc/$GPID/task | wc -l)"

t=0
while [ "$t" -lt "$DURATION" ]; do
  kill -0 "$GPID" 2>/dev/null || break
  sleep 60; t=$(( t + 60 ))
  read -r r d <<<"$(stat)"
  printf '  t=%-4s rss=%s MB  vmdata=%s MB  threads=%s\n' "${t}s" "$r" "$d" "$(ls /proc/$GPID/task | wc -l)"
done
read -r RSS1 DATA1 <<<"$(stat)"
rm -f "$B"; cp "/proc/$GPID/smaps" "$B"; chmod u+w "$B" 2>/dev/null
kill "$GPID" 2>/dev/null; sleep 2; kill -9 "$GPID" 2>/dev/null

echo
echo "  end:   rss=$RSS1 MB vmdata=$DATA1 MB   delta rss=$(( RSS1 - RSS0 )) MB   delta vmdata=$(( DATA1 - DATA0 )) MB"
echo
echo "=== RSS per kelas mapping (MB) ==="
python3 - "$A" "$B" <<'PY'
import re, sys, collections
def read(p):
    rows, cur = [], None
    for line in open(p):
        m = re.match(r"^([0-9a-f]+)-[0-9a-f]+ (\S+) \S+ \S+ \S+\s*(.*)$", line)
        if m:
            cur = [m.group(3).strip() or "[anon]", 0]
            rows.append(cur)
        elif cur is not None and line.startswith("Rss:"):
            cur[1] = int(line.split()[1])
    return [(n, rss) for n, rss in rows]
def klass(n):
    if n == "[heap]": return "[heap] (brk/malloc)"
    if n == "[stack]": return "[stack]"
    if n.startswith("["): return n
    if ".so" in n: return "shared library"
    return "[anon] mmap"
def agg(rows):
    d = collections.Counter()
    for n, rss in rows: d[klass(n)] += rss
    return d
a, b = agg(read(sys.argv[1])), agg(read(sys.argv[2]))
print(f"  {'kelas':24} {'awal':>9} {'akhir':>9} {'delta':>9}")
total = 0
for k in sorted(set(a) | set(b), key=lambda x: -(b[x] - a[x])):
    d = b[k] - a[k]; total += d
    if abs(d) < 512 and b[k] < 2048: continue
    print(f"  {k:24} {a[k]/1024:8.1f}M {b[k]/1024:8.1f}M {d/1024:+8.1f}M")
print(f"  {'TOTAL tercatat':24} {total/1024:+8.1f}M")
heap = a["[heap] (brk/malloc)"] if "[heap] (brk/malloc)" in a else 0
heapN = b["[heap] (brk/malloc)"] if "[heap] (brk/malloc)" in b else 0
anonGrow = (b["[anon] mmap"] - a["[anon] mmap"]) / 1024
heapGrow = (heapN - heap) / 1024
print()
print(f"  pertumbuhan [heap] brk : {heapGrow:+.1f} MB")
print(f"  pertumbuhan anon mmap  : {anonGrow:+.1f} MB")
if heapGrow > 2 and heapGrow >= anonGrow * 0.6:
    print("  => memori tumbuh di heap malloc (brk): alokator/fragmentasi, bukan alokasi langsung pustaka")
else:
    print("  => memori tumbuh di mmap anonim: dipetakan langsung oleh pustaka (bukan lewat malloc)")
PY

#!/usr/bin/env bash
# Read-only census of a LIVE engine's mappings, twice, to see which ones grow.
#
# The probe says the decode path grows ~8 MB/min at full speed and that no malloc knob touches it. This
# looks at the real engine instead of a synthetic chain: if growth shows up as new ~3 MB anonymous
# mappings, those are individual 1920x1080 frames being held; if it shows up as one growing 64 MB block,
# it is an arena.
#
# Touches nothing: only /proc/<pid>/smaps is read.
# Usage: bash live-smaps-census.sh [route-prefix] [seconds]
set -uo pipefail
ROUTE="${1:-52adcad6}"
GAP="${2:-240}"
WORK="${WORK:-/home/blackgate/.hermes/cache/scratch}"
PID=$(pgrep -f "blackgate-engine $ROUTE" | head -1)
[ -n "${PID:-}" ] || PID=$(for p in $(pgrep -f "blackgate-engine"); do tr '\0' ' ' < /proc/$p/cmdline | grep -q "$ROUTE" && echo $p; done | head -1)
[ -n "${PID:-}" ] || { echo "FAIL: no engine for route $ROUTE"; exit 2; }
echo "route $ROUTE  pid $PID"

snap() {
  local out="$1"
  rm -f "$out"
  cp "/proc/$PID/smaps" "$out" && chmod u+w "$out"
  awk '/VmRSS/{printf "  rss=%d MB\n",$2/1024}' "/proc/$PID/status"
}
snap "$WORK/live-smaps-a.txt"
echo "  menunggu ${GAP}s ..."
sleep "$GAP"
snap "$WORK/live-smaps-b.txt"

echo
python3 - "$WORK/live-smaps-a.txt" "$WORK/live-smaps-b.txt" <<'PY'
import re, sys, collections
def read(p):
    out, cur = [], None
    for line in open(p):
        m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)$", line)
        if m:
            cur = {"lo": int(m.group(1), 16), "hi": int(m.group(2), 16),
                   "name": m.group(4).strip() or "[anon]", "rss": 0}
            out.append(cur)
        elif cur is not None and line.startswith("Rss:"):
            cur["rss"] = int(line.split()[1])
    return out
a, b = read(sys.argv[1]), read(sys.argv[2])
def bucket(mb):
    for lo, hi, tag in [(0,0.05,"<50KB"),(0.05,0.5,"50-500KB"),(0.5,1.5,"0.5-1.5MB"),
                        (1.5,4,"1.5-4MB (frame 1080p)"),(4,10,"4-10MB"),(10,40,"10-40MB"),
                        (40,80,"40-80MB (arena)"),(80,1e9,">80MB")]:
        if lo <= mb < hi: return tag
    return "?"
def census(rows):
    d = collections.Counter(); r = collections.Counter()
    for m in rows:
        if m["name"] != "[anon]": continue
        k = bucket((m["hi"]-m["lo"])/1048576)
        d[k] += 1; r[k] += m["rss"]
    return d, r
da, ra = census(a); db, rb = census(b)
print(f"  {'bucket anon':24} {'jml awal':>9} {'jml akhir':>10} {'rss awal':>10} {'rss akhir':>10} {'delta':>9}")
for k in sorted(set(da)|set(db), key=lambda x: -(rb[x]-ra[x])):
    print(f"  {k:24} {da[k]:9} {db[k]:10} {ra[k]/1024:9.1f}M {rb[k]/1024:9.1f}M {(rb[k]-ra[k])/1024:+8.1f}M")
tot = sum(m["rss"] for m in b) - sum(m["rss"] for m in a)
print(f"  {'TOTAL RSS semua mapping':24} {'':9} {'':10} {'':9} {'':9} {tot/1024:+8.1f}M")
# spesifik: mapping ~3 MB yang baru muncul
new3 = [m for m in b if m["name"]=="[anon]" and 2.5 <= (m["hi"]-m["lo"])/1048576 <= 3.5]
old3 = [m for m in a if m["name"]=="[anon]" and 2.5 <= (m["hi"]-m["lo"])/1048576 <= 3.5]
print(f"\n  mapping anonim ~3 MB (satu frame 1080p YUV420): awal {len(old3)} -> akhir {len(new3)}")
if new3:
    print(f"  RSS di mapping itu: awal {sum(m['rss'] for m in old3)/1024:.1f} MB -> akhir {sum(m['rss'] for m in new3)/1024:.1f} MB")
PY

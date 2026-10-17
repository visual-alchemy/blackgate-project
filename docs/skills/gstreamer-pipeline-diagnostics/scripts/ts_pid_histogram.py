#!/usr/bin/env python3
"""PID histogram + PAT/PMT decode for an MPEG-TS capture.

Usage: ts_pid_histogram.py <capture.ts>

Answers "which PIDs are really in this stream and what does the PSI say" in one shot,
without a GStreamer debugging session. Byte layout: references/mpegts-psi-parsing.md.
"""

import sys
from collections import Counter

TS = 188


def packets(data):
    for off in range(0, len(data) - TS + 1, TS):
        pkt = data[off:off + TS]
        if pkt[0] == 0x47:
            yield pkt


def pid_of(pkt):
    return ((pkt[1] & 0x1F) << 8) | pkt[2]


def section(pkt):
    """Return the PSI section bytes, or None when the packet carries no payload."""
    afc = (pkt[3] >> 4) & 0x3
    if afc not in (1, 3):
        return None
    off = 4
    if afc == 3:
        off += 1 + pkt[4]
    if off >= TS:
        return None
    payload = pkt[off:]
    return payload[1 + payload[0]:]  # skip pointer_field


def decode_pat(pkt):
    sec = section(pkt)
    if not sec or sec[0] != 0x00:
        return None
    length = ((sec[1] & 0x0F) << 8) | sec[2]
    end = 3 + length - 4  # exclude CRC
    out, i = [], 8  # +8 = past tsid/version/section numbers
    while i + 4 <= end:
        prog = (sec[i] << 8) | sec[i + 1]
        out.append((prog, ((sec[i + 2] & 0x1F) << 8) | sec[i + 3]))
        i += 4
    return out


def decode_pmt(pkt):
    sec = section(pkt)
    if not sec or sec[0] != 0x02:
        return None
    length = ((sec[1] & 0x0F) << 8) | sec[2]
    pcr = ((sec[8] & 0x1F) << 8) | sec[9]
    program_info_length = ((sec[10] & 0x0F) << 8) | sec[11]
    end = 3 + length - 4  # exclude CRC
    streams, i = [], 12 + program_info_length
    while i + 5 <= end:
        es_info_length = ((sec[i + 3] & 0x0F) << 8) | sec[i + 4]
        streams.append((sec[i], ((sec[i + 1] & 0x1F) << 8) | sec[i + 2]))
        i += 5 + es_info_length
    return {"pcr_pid": pcr, "program_info_length": program_info_length, "streams": streams}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    data = open(sys.argv[1], "rb").read()
    print(f"bytes={len(data)}")
    counts = Counter(pid_of(p) for p in packets(data))
    print("PID histogram:", counts.most_common(15))

    for pkt in packets(data):
        if pid_of(pkt) != 0:
            continue
        entries = decode_pat(pkt)
        if entries:
            print("PAT:", [(f"program {prog}", f"pmt_pid {pid}") for prog, pid in entries])
            pmt_pids = {pid for _, pid in entries}
            for cand in packets(data):
                if pid_of(cand) in pmt_pids:
                    pmt = decode_pmt(cand)
                    if pmt:
                        print(f"PMT (pid {pid_of(cand)}):", pmt)
                    break
            break
    print("stream_type: video H.264=0x1B HEVC=0x24 MPEG-2=0x02; "
          "audio MPEG-1=0x03 MPEG-2=0x04 AAC-ADTS=0x0F AAC-LATM=0x11 AC-3=0x81 E-AC-3=0x87")


if __name__ == "__main__":
    main()

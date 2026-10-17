#!/usr/bin/env python3
"""Objective artifact metrics for a preview JPEG, optionally against a control frame.

Usage:
    python3 preview_artifact_metrics.py preview.jpg [control.jpg] [WxH]

Decodes each file to raw RGB with ffmpeg and reports:
  * mean RGB and the green share (pixels with G > R+20 and G > B+20) -- a large green
    share with a flat chroma spread is the classic never-decoded-chroma artifact;
  * the edge-step profile: mean |pixel(x) - pixel(x+step)| for step 1..24.

Always pass a control frame decoded from the SAME source (e.g. ffmpeg -frames:v 1 -vf
scale=WxH). A monotonically rising profile is content structure; a spike at a multiple of
16 that the control does not have is a macroblock grid. Without the control the step
number alone misreads good content as blocky.
"""

import re
import subprocess
import sys


def load(path):
    if path == "-":
        return sys.stdin.buffer.read()
    return subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True,
    ).stdout


def metrics(data, width, height):
    n = len(data) // 3
    if n == 0:
        return None
    r, g, b = data[0::3][:n], data[1::3][:n], data[2::3][:n]
    green = sum(1 for i in range(n) if g[i] > r[i] + 20 and g[i] > b[i] + 20)
    profile = []
    for step in range(1, 25):
        total = count = 0
        for y in range(0, height, 4):
            for x in range(0, width - step, 4):
                i = y * width + x
                total += abs(data[3 * i] - data[3 * (i + step)])
                count += 1
        profile.append(total / max(count, 1))
    return {
        "mean": (sum(r) // n, sum(g) // n, sum(b) // n),
        "green": green * 100 // n,
        "profile": profile,
        "size": (width, height, n),
    }


def show(label, m):
    if m is None:
        print(f"{label}: EMPTY or undecodable")
        return
    w, h, n = m["size"]
    warn = "" if n == w * h else f"  <-- pixel count {n} != {w}x{h}, pass the real WxH"
    print(f"{label}: meanRGB={m['mean']} green%={m['green']}{warn}")
    print("  step1..24: " + " ".join(f"{v:.0f}" for v in m["profile"]))
    peak = max(range(1, 25), key=lambda s: m["profile"][s - 1])
    print(f"  peak step={peak}")


def main(argv):
    size = (320, 180)
    files = []
    for arg in argv or ["-"]:
        if re.fullmatch(r"\d+x\d+", arg):
            w, h = arg.split("x")
            size = (int(w), int(h))
        else:
            files.append(arg)

    for path in files:
        show(path, metrics(load(path), *size))
    if len(files) > 1:
        print(
            "compare: identical profiles -> no artifact; a 16/32-step spike present only in "
            "the suspect frame -> macroblocks"
        )


if __name__ == "__main__":
    main(sys.argv[1:])

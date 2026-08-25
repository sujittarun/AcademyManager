#!/usr/bin/env python3
"""Trim, crossfade and encode the shots recorded by record.js into the
90-second international cut.

Durations are hand-balanced to land on 90s after the crossfades are subtracted
(each xfade eats XF seconds of runtime). The trim-start on every app shot skips
the navigation and settle time Playwright records before the page is ready; the
landing shot skips its ~5s intro overlay outright.

Shot 0 is the AI-generated opener (Seedance, 720p24). It is upscaled and
retimed by the same normalise chain as everything else, and its audio track is
dropped on purpose: the rest of the film is silent, and five seconds of ambience
at the top reads as a mistake rather than a choice.
"""
import glob
import subprocess

OUT = "/tmp/vid/academy-manager-international-90s.mp4"
XF = 0.6          # crossfade seconds
TARGET = 90.0

# (source, trim-start, length).  A bare path is used as-is; a bare id is
# resolved to the newest webm Playwright wrote for that shot.
PLAN = [
    ("/tmp/vid/cards/opener.mp4", 0.15,  4.8),
    ("01-title",                  0.50,  5.0),
    ("02-brand",                  6.00, 13.5),
    ("03-dash",                   1.00, 14.0),
    ("04-members",                1.00, 12.8),
    ("05-attend",                 1.00, 12.4),
    ("06-fees",                   1.00, 13.0),
    ("07-alerts",                 1.00, 11.3),
    ("08-end",                    0.50,  8.0),
]


def dur(path):
    return float(subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", path]).strip())


srcs = []
for src, ss, length in PLAN:
    if src.startswith("/"):
        path = src
    else:
        found = sorted(glob.glob(f"/tmp/vid/shots/{src}/*.webm"))
        assert found, f"no recording for {src} — run record.js first"
        path = found[0]
    have = dur(path)
    # Fail loudly rather than silently shipping a short shot: ffmpeg would
    # happily hand back fewer frames and the runtime would drift.
    assert ss + length <= have + 0.05, \
        f"{src}: want {ss}+{length}s but the clip is only {have:.2f}s"
    srcs.append((path, ss, length))

runtime = sum(l for _, _, l in srcs) - XF * (len(srcs) - 1)
print(f"  {len(srcs)} shots -> {runtime:.1f}s (target {TARGET:.0f}s)")
assert abs(runtime - TARGET) < 2.0, f"runtime {runtime:.1f}s has drifted from {TARGET}s"

cmd = ["ffmpeg", "-y", "-v", "error", "-stats"]
for path, ss, length in srcs:
    cmd += ["-ss", str(ss), "-t", str(length), "-i", path]

fc = []
for i in range(len(srcs)):
    # one normalise chain for every input, so xfade never sees a mismatch in
    # size, rate, sar or pixel format
    fc.append(
        f"[{i}:v]fps=30,scale=1920:1080:force_original_aspect_ratio=decrease,"
        f"pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=#05070f,setsar=1,"
        f"format=yuv420p[v{i}]")

prev, acc = "v0", srcs[0][2]
for i in range(1, len(srcs)):
    out = f"x{i}"
    fc.append(f"[{prev}][v{i}]xfade=transition=fade:duration={XF}:"
              f"offset={acc - XF:.3f}[{out}]")
    prev, acc = out, acc + srcs[i][2] - XF
fc.append(f"[{prev}]format=yuv420p[vout]")

cmd += ["-filter_complex", ";".join(fc), "-map", "[vout]", "-an",
        "-c:v", "libx264", "-preset", "slow", "-crf", "20",
        "-profile:v", "high", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", "-r", "30", OUT]
subprocess.check_call(cmd)
print(f"  wrote {OUT}")

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

OUT = "/tmp/vid/academy-manager-international-90s-4k.mp4"
TIMING = "/tmp/vid/shots.json"     # written for sync_vo.py to read
XF = 0.6          # crossfade seconds
TARGET = 90.0

# (source, trim-start, length).  A bare path is used as-is; a bare id is
# resolved to the newest webm Playwright wrote for that shot.
# Playwright's clip lengths vary run to run (it records setup time too), so
# these are checked against the real files below rather than trusted.
PLAN = [
    ("/tmp/vid/cards/opener.mp4", 0.15,  4.80),
    ("01-title",                  0.50,  5.00),
    ("02-brand",                  5.40, 10.50),
    ("03-dash",                   1.00, 13.85),
    ("04-members",                1.00, 12.60),
    ("05-attend",                 1.00, 13.30),
    ("06-fees",                   1.00, 14.00),
    ("07-alerts",                 1.00, 11.40),
    ("08-end",                    0.50,  8.80),
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

# Where each shot BEGINS in the finished cut. Every crossfade overlaps the
# outgoing shot by XF, so shot n starts XF earlier than a naive sum implies.
# sync_vo.py reads this: the first version hardcoded these numbers, they drifted
# from the real edit, and a third of the narration played over the wrong shots.
starts, at = [], 0.0
for i, (_, _, length) in enumerate(srcs):
    starts.append(round(at, 3))
    at += length - (XF if i < len(srcs) - 1 else 0)
import json
with open(TIMING, "w") as fh:
    json.dump({"xfade": XF, "runtime": round(runtime, 3),
               "shots": [{"id": PLAN[i][0], "start": starts[i],
                          "length": srcs[i][2]} for i in range(len(srcs))]}, fh, indent=1)
print(f"  shot starts: {', '.join(f'{x:.1f}' for x in starts)}")

cmd = ["ffmpeg", "-y", "-v", "error", "-stats"]
for path, ss, length in srcs:
    cmd += ["-ss", str(ss), "-t", str(length), "-i", path]

fc = []
for i in range(len(srcs)):
    # one normalise chain for every input, so xfade never sees a mismatch in
    # size, rate, sar or pixel format
    fc.append(
        # The AI opener is 1280x720; everything else is native 3840x2160.
        # Upscaling it is unavoidable, so it gets a light unsharp pass to stop
        # it reading as soft next to genuinely crisp UI.
        (f"[{i}:v]fps=30,scale=3840:2160:flags=lanczos,unsharp=5:5:0.8,"
         f"setsar=1,format=yuv420p[v{i}]" if i == 0 else
         f"[{i}:v]fps=30,scale=3840:2160:force_original_aspect_ratio=decrease,"
         f"pad=3840:2160:(ow-iw)/2:(oh-ih)/2:color=#05070f,setsar=1,"
         f"format=yuv420p[v{i}]"))

prev, acc = "v0", srcs[0][2]
for i in range(1, len(srcs)):
    out = f"x{i}"
    fc.append(f"[{prev}][v{i}]xfade=transition=fade:duration={XF}:"
              f"offset={acc - XF:.3f}[{out}]")
    prev, acc = out, acc + srcs[i][2] - XF
fc.append(f"[{prev}]format=yuv420p[vout]")

cmd += ["-filter_complex", ";".join(fc), "-map", "[vout]", "-an",
        "-c:v", "libx264", "-preset", "medium", "-crf", "19",
        "-profile:v", "high", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", "-r", "30", OUT]
subprocess.check_call(cmd)
print(f"  wrote {OUT}")

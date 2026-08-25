#!/usr/bin/env python3
"""Place one narration line per shot, add a quiet ambience bed, and mux.

WHY THIS IS NOT ONE LONG READ ANY MORE
--------------------------------------
The first attempt generated the whole script as a single 63.6s file and split
it at its seven largest silences, assuming those were the sentence groups. They
were not: the first "segment" came out 28.8s long, so a third of the narration
played over the opener, the title and the brand shot. The voice was audibly
describing the wrong screen.

Now each line is generated as its own file and placed at the shot it describes,
and the shot start times are READ FROM shots.json, which assemble.py writes
from the real edit. Nothing here restates a timing that lives somewhere else —
that duplication is what drifted.
"""
import json
import subprocess

VID = "/tmp/vid/academy-manager-international-90s-4k.mp4"
OUT = "/tmp/vid/academy-manager-international-90s-4k-voiceover.mp4"
BED = "/tmp/vid/opener_amb.wav"     # the AI opener's own room tone
TIMING = "/tmp/vid/shots.json"

# line N narrates shot N. Line 1 covers the cinematic opener AND the title
# card, which is why its slot spans both.
LINES = [("line1", 0, 2), ("line2", 2, 3), ("line3", 3, 4), ("line4", 4, 5),
         ("line5", 5, 6), ("line6", 6, 7), ("line7", 7, 8), ("line8", 8, 9)]


def dur(p):
    return float(subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", p]).strip())


timing = json.load(open(TIMING))
shots, runtime = timing["shots"], timing["runtime"]

placed = []
for name, a, b in LINES:
    src = f"/tmp/vid/vo/{name}.wav"
    trimmed = f"/tmp/vid/vo/{name}_t.wav"
    # TTS pads both ends; trim it so a line starts on its shot, not after it
    subprocess.check_call([
        "ffmpeg", "-y", "-v", "error", "-i", src, "-af",
        "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,"
        "areverse,"
        "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,"
        "areverse", "-ar", "48000", "-ac", "2", trimmed])

    start = shots[a]["start"]
    slot = (shots[b]["start"] if b < len(shots) else runtime) - start
    d = dur(trimmed)

    # A line longer than its shot is a script problem, not a mixing problem, so
    # say so. A small overrun is fine — speech carrying over a cut is normal —
    # but anything past ~1.5s means the copy needs shortening or regenerating.
    if d > slot + 1.5:
        raise SystemExit(
            f"{name} is {d:.2f}s but its slot is only {slot:.2f}s. Shorten the "
            f"line and regenerate it rather than time-stretching the voice.")
    if d > slot:
        print(f"  note: {name} runs {d - slot:.2f}s past its cut (acceptable)")

    placed.append((trimmed, start, d))
    print(f"  {name}  {d:5.2f}s at {start:5.1f}s  (slot {slot:5.2f}s)")

end = max(s + d for _, s, d in placed)
assert end < runtime + 0.5, f"narration ends at {end:.1f}s, past the {runtime:.1f}s picture"

# ── the ambience bed ────────────────────────────────────────────────────────
# There is no music model available here (this toolset does speech only), so
# the bed is the opener's own room tone: looped, low-passed to remove anything
# that competes with the voice, and sat 26 dB under it. It reads as air in a
# room rather than as a backing track, which is the point — a demo with an
# obvious loop under it sounds cheaper than one with nothing.
cmd = ["ffmpeg", "-y", "-v", "error",
       "-stream_loop", "-1", "-t", str(runtime), "-i", BED]
for f, _, _ in placed:
    cmd += ["-i", f]

fc = [f"[0:a]lowpass=f=900,volume=0.055,afade=t=in:st=0:d=1.5,"
      f"afade=t=out:st={runtime - 2.5:.2f}:d=2.5[bed]"]
for i, (_, at, _) in enumerate(placed, start=1):
    fc.append(f"[{i}:a]adelay={int(at * 1000)}|{int(at * 1000)}[v{i}]")
fc.append("".join(f"[v{i}]" for i in range(1, len(placed) + 1)) +
          f"amix=inputs={len(placed)}:normalize=0:duration=longest[speech]")
# loudnorm last: a raw gain boost peaked at -0.5 dB, close enough to clipping
# to distort on a phone speaker. -16 LUFS / -1.5 dBTP is the web standard.
fc.append(f"[speech][bed]amix=inputs=2:normalize=0:duration=first,"
          f"apad=whole_dur={runtime},atrim=0:{runtime},"
          f"loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[aout]")

cmd += ["-filter_complex", ";".join(fc), "-map", "[aout]",
        "-c:a", "pcm_s16le", "/tmp/vid/mix.wav"]
subprocess.check_call(cmd)
print("  mixed narration + ambience bed")

subprocess.check_call([
    "ffmpeg", "-y", "-v", "error", "-i", VID, "-i", "/tmp/vid/mix.wav",
    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac",
    "-b:a", "192k", "-ar", "48000", "-ac", "2", "-shortest",
    "-movflags", "+faststart", OUT])
print(f"  wrote {OUT}")

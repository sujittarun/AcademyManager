"""Spread the 63.6s narration across the 90s cut so it tracks the shots.

The alternative was `atempo` to stretch it, which at the required 0.74x sounds
draggy. Instead: split the read at its own natural pauses and place each
segment at the shot it describes, keeping the pauses as breathing room.
"""
import re, subprocess, json

VO, VID, OUT = "/tmp/vid/vo.wav", "/tmp/vid/academy-manager-international-90s.mp4", "/tmp/vid/vo-mixed.wav"
VDUR = 90.0

# where each shot begins in the final cut (cumulative, minus crossfades)
SHOT_STARTS = [1.0, 9.0, 22.0, 35.5, 47.5, 59.5, 72.0, 82.3]

raw = subprocess.run(["ffmpeg","-v","info","-i",VO,"-af","silencedetect=noise=-38dB:d=0.30","-f","null","-"],
                     capture_output=True, text=True).stderr
starts = [float(m) for m in re.findall(r"silence_start: ([\d.]+)", raw)]
ends   = [float(m) for m in re.findall(r"silence_end: ([\d.]+)", raw)]
dur = float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",VO]).strip())

gaps = []
for s, e in zip(starts, ends):
    if s > 0.5 and e < dur - 0.2:
        gaps.append((e - s, s, e))
gaps.sort(reverse=True)
cuts = sorted(g[1] + (g[2]-g[1])/2 for g in gaps[:len(SHOT_STARTS)-1])   # 7 cuts -> 8 segments
print(f"  {len(gaps)} pauses found; splitting at {len(cuts)}")

bounds = [0.0] + cuts + [dur]
segs = []
for i in range(len(bounds)-1):
    a, b = bounds[i], bounds[i+1]
    f = f"/tmp/vid/vo_{i}.wav"
    subprocess.check_call(["ffmpeg","-y","-v","error","-ss",str(a),"-to",str(b),"-i",VO,
                           "-ar","48000","-ac","2",f])
    segs.append((f, b-a))

# place each segment at its shot, never overlapping the previous one
place, cursor = [], 0.0
for i, (f, d) in enumerate(segs):
    at = max(SHOT_STARTS[i], cursor + 0.25)
    place.append((f, at, d)); cursor = at + d
end = cursor
print(f"  narration spans {place[0][1]:.1f}s -> {end:.1f}s of {VDUR:.0f}s")
assert end < VDUR - 0.3, f"narration overruns the video by {end - VDUR:.1f}s"

cmd = ["ffmpeg","-y","-v","error"]
for f,_,_ in place: cmd += ["-i", f]
fc = []
for i,(_,at,_) in enumerate(place):
    fc.append(f"[{i}:a]adelay={int(at*1000)}|{int(at*1000)},volume=1.35[a{i}]")
fc.append("".join(f"[a{i}]" for i in range(len(place))) +
          f"amix=inputs={len(place)}:normalize=0:duration=longest,"
          f"apad=whole_dur={VDUR},atrim=0:{VDUR},aresample=48000[aout]")
cmd += ["-filter_complex",";".join(fc),"-map","[aout]","-c:a","pcm_s16le",OUT]
subprocess.check_call(cmd)
print(f"  wrote {OUT}")

#!/usr/bin/env python3
"""The README's GIFs (docs/media/CREDITS.md) from a `simctl io recordVideo` file.

The recorder writes a frame only when it notices a change, and it can miss a web view's (the
lookup popup), so seeking or resampling the video lands on the wrong frames. Instead every
recorded frame is decoded with its timestamp, the steps are picked by frame number, and the GIF
is sampled at a fixed rate from those frames with their real durations. A popup the recorder
missed is held from one of the screenshots `scripts/record-readme-gif.sh` takes alongside.

  scripts/readme-gif.py dump  <raw.mp4> <dir> [width]   every frame as <dir>/f0001.png…, times in times.txt
  scripts/readme-gif.py strip <dir> <first> <last> <step> <out.png>   every <step>th frame, to pick steps
  scripts/readme-gif.py build <dir> <out.gif> <fps> <spec>…
      spec: <first>-<last>@<cap> (frames in that range, stills cut to <cap> seconds)
            or hold:<frame>@<seconds> (e.g. a screenshot saved as <dir>/f9999.png, in RGB)
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile


def dump(raw, folder, width="600"):
    os.makedirs(folder, exist_ok=True)
    run = subprocess.run(["ffmpeg", "-loglevel", "info", "-y", "-i", raw, "-vf", f"scale={width}:-2:flags=lanczos,showinfo",
                          "-fps_mode", "passthrough", os.path.join(folder, "f%04d.png")], capture_output=True, text=True)
    times = re.findall(r"pts_time:([0-9.]+)", run.stderr)
    with open(os.path.join(folder, "times.txt"), "w") as out:
        out.write("\n".join(times) + "\n")
    print(len(times), "frames, last at", times[-1] if times else None)


def times(folder):
    return [float(t) for t in open(os.path.join(folder, "times.txt")).read().split()]


def strip(folder, first, last, step, out):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-start_number", first, "-i", os.path.join(folder, "f%04d.png"),
                    "-frames:v", str((int(last) - int(first)) // int(step) + 1),
                    "-vf", f"select='not(mod(n,{step}))',scale=80:-2,tile={(int(last) - int(first)) // int(step) + 1}x1:padding=2",
                    "-frames:v", "1", out], check=True)
    print(f"tiles are frames {first}, {int(first) + int(step)}, … every {step}")


def build(folder, out, fps, specs):
    t = times(folder)
    timeline, clock = [], 0.0          # (frame number, start on the GIF's clock)
    for spec in specs:
        if spec.startswith("hold:"):
            frame, seconds = spec[5:].split("@")
            timeline.append((int(frame), clock)); clock += float(seconds)
            continue
        span, cap = spec.split("@")
        a, b = (int(x) for x in span.split("-"))
        for n in range(a, b + 1):      # frame n (1-based) lasts until frame n+1 is recorded
            timeline.append((n, clock))
            clock += max(min(t[n] - t[n - 1], float(cap)), 1 / 60)
    fps = int(fps)
    seq = tempfile.mkdtemp(prefix="gifseq-")
    count = round(clock * fps)
    for k in range(count):
        now = k / fps
        frame = [n for n, start in timeline if start <= now + 1e-9][-1]
        os.symlink(os.path.abspath(os.path.join(folder, f"f{frame:04d}.png")), os.path.join(seq, f"{k + 1:05d}.png"))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(fps), "-i", os.path.join(seq, "%05d.png"),
                    "-vf", "format=rgb24,split[x][y];[x]palettegen=max_colors=128:stats_mode=diff[p];"
                           "[y][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle", out], check=True)
    shutil.rmtree(seq)
    print(f"{out}: {count} frames, {clock:.2f} s, {os.path.getsize(out) / 1e6:.2f} MB")


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("dump", "strip", "build"):
        sys.exit(__doc__)
    command, args = sys.argv[1], sys.argv[2:]
    if command == "build":
        build(args[0], args[1], args[2], args[3:])
    else:
        {"dump": dump, "strip": strip}[command](*args)

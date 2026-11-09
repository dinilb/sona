#!/usr/bin/env python3
"""Captures the iPhone screens for the App Store set from the Debug build in a simulator of your own.

    python3 design/app-store/capture.py <iPhone udid> <notes folder> <out dir> [screen ...]

Each screen relaunches Sona with its launch arguments (ios/README.md, "Launch arguments") and takes a few
screenshots at set times, so one lands after the animation and before playback or the recording moves on. Pick the
best of `<screen>-<n>.png` and copy it to design/app-store/captures/. The notes come from sample-notes/make-notes.py
(made up); the recording plays recording.wav beside the notes folder, never the simulator's mic.
"""
import os
import subprocess
import sys
import time

BUNDLE = "com.dinilb.sona"
BASE = ["-debugSkipOnboarding", "-debugNoModelDownload"]


def screens(notes):
    clip = os.path.join(os.path.dirname(notes), "recording.wav")
    folder = ["-debugNotesFolder", notes]
    return {
        "home": (BASE + folder, [2, 4]),
        "note": (BASE + folder + ["-debugOpenNote", "latest", "-debugPlayNote"], [1.5, 2.5, 3.5, 5]),
        # Not playing: the page stays at the top (playing, it follows the line and scrolls on a 6.3" phone).
        "note-still": (BASE + folder + ["-debugOpenNote", "latest"], [3, 5]),
        "search": (BASE + folder + ["-debugSearch", "budget"], [2, 4]),
        "place": (BASE + folder + ["-debugPlace", "88 Queen St"], [2, 4]),
        "recording": (BASE + folder + ["-debugRecordFile", clip, "-debugAutoRecordSeconds", "45"], [3, 5, 7]),
        "welcome": (["-debugOnboardingStep", "1", "-debugNoModelDownload"], [2, 4]),
    }


def main():
    udid, notes, out = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
    os.makedirs(out, exist_ok=True)
    table = screens(notes)
    for name in sys.argv[4:] or list(table):
        args, times = table[name]
        subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
        subprocess.run(["xcrun", "simctl", "launch", udid, BUNDLE] + args, check=True, capture_output=True)
        # The times count from the first frame with something on it: a launch on a busy Mac can take 30 s to draw.
        probe = os.path.join(out, f".{name}-probe.png")
        for _ in range(120):
            subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", probe], check=True, capture_output=True)
            if os.path.getsize(probe) > 120_000:  # a blank launch screen is about 83 KB
                break
            time.sleep(0.5)
        os.remove(probe)
        start = time.monotonic()
        for i, at in enumerate(times, 1):
            time.sleep(max(0, at - (time.monotonic() - start)))
            path = os.path.join(out, f"{name}-{i}.png")
            subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", path], check=True, capture_output=True)
            print(f"{path}  at {time.monotonic() - start:.1f} s")
    # KEEP=1 leaves the app running (the Lock Screen shot of a recording is taken after this, by hand).
    if not os.environ.get("KEEP"):
        subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Writes the made-up notes the App Store screenshots show, in the format the iPhone app writes.

Every name, place and word here is invented for the screenshots. Each note's audio is made with macOS `say`, so
the player's wave and the words line up with what the note says. The .md and .json follow NotesKit's NoteWriter
(first-words title, `[mm:ss] Speaker N:` lines, the sidecar with every word's time), with the keys the iPhone adds
afterwards (ai_title, place, geo) where PlaceStamps and PhoneTitles put them.

    python3 design/app-store/sample-notes/make-notes.py /tmp/sona-shots/notes

Also writes `recording.wav` (16 kHz mono) beside the folder, for the recording screen's `-debugRecordFile`.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import wave
from datetime import datetime, timedelta, timezone

ZONE = timezone(timedelta(hours=10))  # Brisbane, no summer time
RATE = 16000
GAP = 0.55  # seconds of quiet between turns
LEAD = 0.3  # quiet before the first word

VOICES = {"Alex": "Karen", "Jordan": "Daniel", "Sam": "Samantha", "Lecturer": "Daniel"}

NOTES = [
    {
        "start": "2026-11-09 09:02:14",
        "ai_title": "Deck quote with Jordan",
        "place": "88 Queen St", "geo": "-27.4697,153.0254",
        "turns": [
            ("Alex", "Hi Jordan, thanks for calling back. I wanted to go over the deck quote before you order the timber."),
            ("Jordan", "No problem. The quote is for a six by four metre deck in spotted gum, with one step down to the garden."),
            ("Alex", "That sounds right. Is the budget still around eighteen thousand?"),
            ("Jordan", "Close. Timber went up a little, so it's about nineteen and a half, with the council approval included."),
            ("Alex", "Okay. And how long does the build take once you start?"),
            ("Jordan", "Two weeks if the weather holds. We could start on Monday the twenty third."),
            ("Alex", "Great. Can you email the updated quote today?"),
            ("Jordan", "Will do. I'll add a few photos of the timber so you can pick the colour."),
            ("Alex", "Perfect. Thanks Jordan, talk soon."),
        ],
    },
    {
        "start": "2026-11-09 08:14:40",
        "ai_title": "Cold brew stall idea",
        "place": "88 Queen St", "geo": "-27.4699,153.0249",
        "turns": [
            ("Alex", "An idea for the Saturday market. Sell cold brew in glass bottles, and take a dollar off when people bring the bottle back."),
            ("Alex", "Start small, maybe forty bottles a week, and keep the first month's budget under five hundred dollars."),
            ("Alex", "Ask Sam about borrowing the big fridge, and check what the market charges for a stall."),
        ],
    },
    {
        "start": "2026-11-08 17:40:05",
        "ai_title": "December budget with Sam",
        "place": "88 Queen St", "geo": "-27.4701,153.0257",
        "turns": [
            ("Alex", "Okay Sam, let's do the budget for December before we forget."),
            ("Sam", "Sure. Rent stays the same, so that's two thousand two hundred for the month."),
            ("Alex", "Groceries were about six hundred last month. Can we aim for five hundred and fifty?"),
            ("Sam", "We can if we cook on weeknights. The takeaway is what blows it out."),
            ("Alex", "Fair. And for the trip to the coast, we said four hundred each?"),
            ("Sam", "Four hundred each, and we book the place this week while it's cheap."),
            ("Alex", "Deal. I'll put it all in the shared sheet tonight."),
        ],
    },
    {
        "start": "2026-11-08 07:15:32",
        "ai_title": "Pick up the dry cleaning",
        "source": "Apple Watch",
        "turns": [
            ("Alex", "Remind me to pick up the dry cleaning before six, and grab milk on the way home."),
        ],
    },
    {
        "start": "2026-11-07 11:30:18",
        "ai_title": "Birthday ideas for Sam",
        "place": "61 Adelaide St", "geo": "-27.4682,153.0267",
        "turns": [
            ("Alex", "Birthday ideas for Sam, it's on the twentieth. A good chef's knife, because the old one is hopeless."),
            ("Alex", "Or tickets to the jazz night at the botanic gardens. Maybe both, if the budget stretches that far."),
        ],
    },
    {
        "start": "2026-11-06 10:03:47",
        "ai_title": "Interest rates lecture",
        "place": "35 Edward St", "geo": "-27.4712,153.0279",
        "turns": [
            ("Lecturer", "Okay everyone, let's get started. Today we're looking at how interest rates move through the economy."),
            ("Lecturer", "When the central bank raises the cash rate, banks pay more to borrow, and they pass that on to home loans and business loans."),
            ("Lecturer", "People with a mortgage have less to spend, so demand slows down, and businesses put off new projects."),
            ("Lecturer", "Over a year or two, that takes the pressure off prices. The catch is the delay."),
            ("Lecturer", "The rate changes today, but the effect on inflation shows up much later. So the bank has to guess where the economy will be next year, not where it is now."),
            ("Lecturer", "For next week, read chapter seven and try the three practice questions at the end."),
        ],
    },
    {
        "start": "2026-11-05 18:20:09",
        "ai_title": "Poster feedback from Sam",
        "place": "140 Ann St", "geo": "-27.4664,153.0281",
        "turns": [
            ("Sam", "The poster's close. I'd make the date bigger, it's the first thing people look for."),
            ("Alex", "Good call. What about the photo, is it too dark?"),
            ("Sam", "A little. Try the one from the beach, it's brighter and the faces are clearer."),
            ("Alex", "Okay, I'll swap it and send you a new version tomorrow morning."),
        ],
    },
    {
        "start": "2026-11-04 07:05:51",
        "ai_title": "Plan for the week",
        "turns": [
            ("Alex", "Plan for the week. Finish the essay draft by Wednesday, gym on Tuesday and Thursday, and call the bank about the card."),
        ],
    },
]

# What the recording screen plays in place of the mic (never the simulator's mic).
RECORDING = [
    ("Alex", "Quick note before the meeting. The new menu goes to print on Thursday, so any changes need to reach Sam by Wednesday night."),
    ("Alex", "Also, we still need a photo for the front page, and someone to check the prices on the back."),
]

FILLERS = set("""um umm uh uhh erm hmm mm mhm ah oh okay ok so yeah yep yes no nah like well right hey hi hello and but
alright cool sure anyway anyways basically just""".split())


def clean(word):
    kept = "".join(c for c in word if c.isalnum() or c in "'$%&-")
    return kept.strip("'-")


def first_words_title(lines):
    """NotesKit's Title.make: the first sentence with 3+ words after leading filler, its first 6 words."""
    early = " ".join(text for start, _, text in lines if start < 120)
    for sentence in re.split(r"[.?!]", early):
        words = [w for w in (clean(w) for w in sentence.split(" ")) if w]
        while words and words[0].lower() in FILLERS:
            words.pop(0)
        if len(words) < 3:
            continue
        title = " ".join(words[:6])
        return title[:1].upper() + title[1:]
    return "Conversation"


def file_safe(title):
    cleaned = "".join(" " if c in '/\\:*?"<>|#^[]\n\r\t' else c for c in title)
    return " ".join(cleaned.split())[:60].strip()


def yaml_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def clock(seconds):
    s = max(0, int(seconds))
    return f"{s // 3600}:{(s % 3600) // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def duration_text(seconds):
    s = max(0, round(seconds))
    if s >= 3600:
        return f"{s // 3600}h {(s % 3600) // 60}m"
    return f"{s // 60}m {s % 60}s" if s >= 60 else f"{s}s"


def r3(x):
    return round(x * 1000) / 1000


def say(voice, text, out):
    subprocess.run(["say", "-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000", "-o", out, text], check=True)
    with wave.open(out, "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes())


def render(turns, tmp):
    """The note's audio (16-bit PCM) and its words, each word timed inside the span its turn takes in the audio."""
    pcm = bytearray(b"\0\0" * int(LEAD * RATE))
    words = []
    speakers = {}
    for i, (who, text) in enumerate(turns):
        label = speakers.setdefault(who, f"Speaker {len(speakers) + 1}")
        frames = say(VOICES[who], text, os.path.join(tmp, f"part{i}.wav"))
        start = len(pcm) / 2 / RATE
        seconds = len(frames) / 2 / RATE
        # Words share the turn's span by length (say leaves a little quiet at each end).
        tokens = text.split()
        span_start, span_end = start + 0.05, start + max(0.1, seconds - 0.15)
        weights = [len(t) + 1 for t in tokens]
        total = sum(weights)
        t = span_start
        for token, weight in zip(tokens, weights):
            step = (span_end - span_start) * weight / total
            words.append({"word": token, "start": r3(t), "end": r3(t + step * 0.85), "speaker": label})
            t += step
        pcm += frames
        pcm += b"\0\0" * int(GAP * RATE)
    return bytes(pcm), words


def lines_from(words):
    """NotesKit's Lines.from: a new line at a change of speaker, a pause of 3 s, or the first sentence end past 30 s."""
    lines, current = [], []
    for w in words:
        long = current and current[-1]["end"] - current[0]["start"] >= 30 and current[-1]["word"][-1:] in ".?!"
        if current and (w["speaker"] != current[-1]["speaker"] or w["start"] - current[-1]["end"] >= 3.0 or long):
            lines.append(current)
            current = []
        current.append(w)
    if current:
        lines.append(current)
    return [(ws[0]["start"], ws[0]["speaker"], " ".join(w["word"] for w in ws)) for ws in lines]


def turns_from(words):
    turns = []
    for w in words:
        if turns and turns[-1]["speaker"] == w["speaker"]:
            turns[-1]["end"] = w["end"]
        else:
            turns.append({"end": w["end"], "speaker": w["speaker"], "start": w["start"]})
    return turns


def write_wav(path, pcm):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)


def write_note(note, root, tmp):
    pcm, words = render(note["turns"], tmp)
    duration = len(pcm) / 2 / RATE
    started = datetime.strptime(note["start"], "%Y-%m-%d %H:%M:%S").replace(tzinfo=ZONE)
    ended = started + timedelta(seconds=duration)
    lines = lines_from(words)
    title = first_words_title([(s, None, text) for s, _, text in lines])
    speakers = list(dict.fromkeys(w["speaker"] for w in words))
    text = " ".join(w["word"] for w in words)
    source = note.get("source", "iPhone")

    day = os.path.join(root, "Conversations", started.strftime("%Y-%m-%d"))
    os.makedirs(day, exist_ok=True)
    stem = os.path.join(day, f"{started.strftime('%H-%M')} {file_safe(title)}")

    tags = ["sona"]
    if re.search(r"\bremind(?:er)?s? me\b|\breminders?\b|\bdon'?t (?:let me )?forget\b", text, re.I):
        tags.append("reminder")
    md = "---\n"
    md += f"title: {yaml_string(title)}\n"
    md += f"date: {started.strftime('%Y-%m-%d')}\n"
    md += f"start: \"{started.strftime('%H:%M:%S')}\"\n"
    md += f"end: \"{ended.strftime('%H:%M:%S')}\"\n"
    md += f"duration: {duration_text(duration)}\n"
    md += f"speakers: [{', '.join(yaml_string(s) for s in speakers)}]\n"
    md += "model: parakeet-tdt-0.6b-v2\n"
    md += f"source: {yaml_string(source)}\n"
    # Added after the note is written, just before `tags:` (NoteFrontMatter.order).
    md += f"ai_title: {yaml_string(note['ai_title'])}\n"
    if "place" in note:
        md += f"place: {yaml_string(note['place'])}\n"
        md += f"geo: {note['geo']}\n"
    md += f"tags: [{', '.join(tags)}]\n"
    md += "---\n\n"
    md += f"# {title}\n\n"
    for start, speaker, line in lines:
        md += f"[{clock(start)}] {speaker}: {line}\n\n"
    with open(stem + ".md", "w") as f:
        f.write(md)

    asr = r3(duration / 38)
    diar = r3(duration / 90)
    sidecar = {
        "diarizer": "pyannote-community-1 + VBx (FluidAudio offline)",
        "durationSeconds": r3(duration),
        "model": "parakeet-tdt-0.6b-v2",
        "source": source,
        "speakers": speakers,
        "startedAt": started.isoformat(),
        "text": text,
        "timing": {"asrSeconds": asr, "diarizationSeconds": diar, "realTimeFactor": r3(duration / (asr + diar)),
                   "totalSeconds": r3(asr + diar)},
        "turns": turns_from(words),
        "words": words,
    }
    with open(stem + ".json", "w") as f:
        json.dump(sidecar, f, indent=2, sort_keys=True, separators=(",", " : "))

    wav = os.path.join(tmp, "note.wav")
    write_wav(wav, pcm)
    # AudioCompressor's format: AAC in an m4a, 16 kHz mono, about 32 kbps.
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "32000", wav, stem + ".m4a"], check=True)
    print(f"{os.path.relpath(stem, root)}  {duration_text(duration)}  {len(lines)} lines")


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "/tmp/sona-shots/notes")
    os.makedirs(root, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for note in NOTES:
            write_note(note, root, tmp)
        pcm, _ = render(RECORDING, tmp)
        clip = os.path.join(os.path.dirname(root), "recording.wav")
        # Said six times (about 86 s), so the live wave is still moving whenever a busy simulator gets to the shot.
        write_wav(clip, pcm * 6)
        print(f"recording clip {clip}  {duration_text(len(pcm) / 2 / RATE)}")


if __name__ == "__main__":
    main()

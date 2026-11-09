#!/usr/bin/env -S python3 -I
"""Scores a conversation sidecar (.json) against the turn table from make-test-clip.sh.

usage: scripts/score.py <note.json> <turns.tsv> [--offset seconds]

Prints: word error rate (rough: "forty thousand" vs "40,000" counts as errors), speakers found, and
speaker accuracy: the share of words whose speaker (mapped to the voice it matches most) is the voice
actually talking at that moment.
"""
import json
import re
import sys
from collections import Counter, defaultdict


def norm(text):
    return [w for w in re.sub(r"[^a-z0-9' ]", " ", text.lower().replace("-", " ")).split() if w]


def wer(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(hyp) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (ref[i - 1] != hyp[j - 1]))
            prev = cur
    return d[len(hyp)] / max(1, len(ref))


def main():
    args = sys.argv[1:]
    offset = 0.0
    if "--offset" in args:
        i = args.index("--offset")
        offset = float(args[i + 1])
        del args[i : i + 2]
    side = json.load(open(args[0]))
    turns = []
    for line in open(args[1]):
        start, end, voice, text = line.rstrip("\n").split("\t")
        turns.append((float(start) + offset, float(end) + offset, voice, text))

    ref = [w for t in turns for w in norm(t[3])]
    hyp = [w for word in side["words"] for w in norm(word["word"])]

    def voice_at(t):
        best, dist = None, 1e9
        for s, e, v, _ in turns:
            d = 0 if s <= t <= e else min(abs(t - s), abs(t - e))
            if d < dist:
                best, dist = v, d
        return best

    pairs = [(w["speaker"], voice_at((w["start"] + w["end"]) / 2)) for w in side["words"]]
    by_label = defaultdict(Counter)
    for label, voice in pairs:
        by_label[label][voice] += 1
    mapping = {label: c.most_common(1)[0][0] for label, c in by_label.items()}
    correct = sum(1 for label, voice in pairs if mapping[label] == voice)

    print(f"words: ref {len(ref)}, hyp {len(hyp)}; WER {wer(ref, hyp) * 100:.1f}% (numbers written as digits count as errors)")
    print(f"speakers found: {len(by_label)} ({', '.join(f'{k} -> {v}' for k, v in sorted(mapping.items()))}); expected {len(set(t[2] for t in turns))}")
    print(f"speaker accuracy: {correct}/{len(pairs)} words = {correct / max(1, len(pairs)) * 100:.1f}%")
    wrong = [(w["start"], w["word"], w["speaker"]) for w, (label, voice) in zip(side["words"], pairs) if mapping[label] != voice]
    if wrong:
        print("misattributed words: " + ", ".join(f"{s:.1f}s '{word}' ({spk})" for s, word, spk in wrong[:20]))


main()

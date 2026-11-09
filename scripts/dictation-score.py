#!/usr/bin/env -S python3 -I
"""Scores a LIVE_DICTATE run (dictations-test.jsonl) against the table from dictation-bench.sh.

usage: scripts/dictation-score.py <dictate.tsv> <run.jsonl> [--quiet]

Per dictation: whether the first and last words were kept, word error rate against the sentence, and release to
text (from the key-up time in the table to when that text was ready). Then a summary for each text the run recorded:
`text` is what was pasted; `live` (the live words) and `clip...` (the clip pass, with its tail) when the run has them.
"Leaked" counts dictations whose text starts with words said before the press (the table's last column).
"""
import json
import re
import sys


def norm(text):
    return [w for w in re.sub(r"[^a-z0-9' ]", " ", text.lower().replace("-", " ")).split() if w]


def edits(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(hyp) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (ref[i - 1] != hyp[j - 1]))
            prev = cur
    return d[len(hyp)]


def pct(xs):
    return f"{100 * sum(xs) / max(1, len(xs)):.0f}%"


def median(xs):
    xs = sorted(xs)
    if not xs:
        return float("nan")
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    quiet = "--quiet" in sys.argv
    table = []
    for line in open(args[0]):
        cols = line.rstrip("\n").split("\t")
        said = cols[7] if len(cols) > 7 and cols[7] != "-" else ""
        table.append(dict(down=float(cols[0]), up=float(cols[1]), start=float(cols[2]), end=float(cols[3]), text=cols[5], said=said))
    runs = [json.loads(l) for l in open(args[1]) if l.strip()]

    # Each result belongs to the scheduled press nearest its own.
    matched = [None] * len(table)
    for r in runs:
        i = min(range(len(table)), key=lambda k: abs(table[k]["down"] - r["down"]))
        if abs(table[i]["down"] - r["down"]) < 1.0 and matched[i] is None:
            matched[i] = r

    fields = ["text"] + sorted({k for r in runs for k in r if (k == "live" or k.startswith("clip")) and not k.endswith("_done")})
    stats = {f: dict(first=[], last=[], err=0, words=0, ms=[], leaked=[]) for f in fields}
    if not quiet:
        print(f"{'#':>2} {'down':>6} {'up':>6} {'down':>4} {'up':>5}  " + "  ".join(f"{f[:12]:>12} 1st last  WER    ms" for f in fields))
    for i, (t, r) in enumerate(zip(table, matched)):
        ref = norm(t["text"])
        cells = []
        for f in fields:
            s = stats[f]
            hyp = norm(r.get(f, "")) if r else []
            e = edits(ref, hyp)
            first = bool(hyp) and hyp[0] == ref[0]
            last = bool(hyp) and hyp[-1] == ref[-1]
            s["first"].append(first)
            s["last"].append(last)
            s["err"] += e
            s["words"] += len(ref)
            if t["said"]:
                before = norm(t["said"])
                s["leaked"].append(bool(hyp) and hyp[0] != ref[0] and hyp[0] in before)
            done = r.get(f + "_done", r.get("done")) if r else None
            ms = (done - t["up"]) * 1000 if done is not None else None
            if ms is not None:
                s["ms"].append(ms)
            cells.append(f"{'':>12} {'y' if first else 'N':>3} {'y' if last else 'N':>4} {e / len(ref) * 100:4.0f}% {ms if ms is not None else float('nan'):5.0f}")
        if not quiet:
            print(f"{i + 1:2d} {t['down']:6.2f} {t['up']:6.2f} {t['down'] - t['start']:+4.1f} {t['up'] - t['end']:+5.2f}  " + "  ".join(cells))
    missing = sum(1 for r in matched if r is None)
    outcomes = {}
    for r in runs:
        outcomes[r.get("outcome", "?")] = outcomes.get(r.get("outcome", "?"), 0) + 1
    print(f"dictations: {len(table)}, results: {len(runs)}, missing: {missing}, outcomes: {outcomes}")
    for f in fields:
        s = stats[f]
        ms = s["ms"]
        leaked = f", said-before leaked {sum(s['leaked'])}/{len(s['leaked'])}" if s["leaked"] else ""
        print(
            f"{f}: first word kept {pct(s['first'])}, last word kept {pct(s['last'])}, WER {100 * s['err'] / max(1, s['words']):.1f}%{leaked}, "
            f"release to text median {median(ms):.0f} ms, worst {max(ms) if ms else float('nan'):.0f} ms"
        )


main()

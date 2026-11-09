# Prints the <rect> bars of the website's voice wave (site/index.html, design/site/og.html).
# Speech-like: bursts for words with quiet gaps between, the same every run. Paste the output into the SVG.
# Run: python3 design/site/wave.py
import math
import random

random.seed(7)
W, H, BAR, PITCH = 1200, 160, 6, 14
count = (W - BAR) // PITCH + 1
words = [(5, 3), (13, 4), (24, 4), (31, 2), (41, 5), (53, 3), (61, 4), (73, 4), (81, 2)]  # (centre bar, half-width)

for i in range(count):
    loud = max(math.exp(-abs((i - c) / w) ** 3) for c, w in words)
    h = 6 + loud * (H - 16) * (0.45 + 0.55 * random.random())
    h = max(6, round(h / 2) * 2)
    print(f'<rect x="{4 + i * PITCH}" y="{(H - h) / 2:g}" width="{BAR}" height="{h}" rx="3" style="--i:{i}"/>')

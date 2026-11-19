"""Generate original Cliphoard copy cues. Python 3.13+, no external assets."""
import math
from pathlib import Path
import struct
import sys
import wave

if sys.version_info < (3, 13):
    raise SystemExit("Python 3.13 or newer is required")

RATE = 44100
DEST = Path(__file__).resolve().parents[1] / "ports/windows/Cliphoard.Windows/Assets/Sounds"
# Frequency, onset, decay. Short, gently enveloped tones avoid harsh edges.
PRESETS = {
    "tick": [(2100, 0, .018)],
    "click": [(1450, 0, .025), (3200, 0, .012)],
    "pop": [(420, 0, .045)],
    "bubble": [(680, 0, .08)],
    "glass": [(1800, 0, .14), (2700, 0, .09)],
    "bell": [(880, 0, .22), (1760, 0, .12), (2640, 0, .07)],
    "chime": [(1046.5, 0, .14), (1318.5, .065, .16)],
    "pluck": [(660, 0, .11), (1320, 0, .04)],
    "drop": [(1000, 0, .07)],
    "ripple": [(740, 0, .09), (988, .07, .10), (1175, .14, .12)],
    "wood": [(540, 0, .035), (810, 0, .02)],
    "sparkle": [(1568, 0, .10), (2093, .045, .11), (2637, .09, .12)],
}
DEST.mkdir(parents=True, exist_ok=True)
for name, tones in PRESETS.items():
    duration = min(.65, max(start + decay * 3 for _, start, decay in tones))
    samples = []
    for i in range(round(duration * RATE)):
        t = i / RATE
        value = 0.0
        for frequency, start, decay in tones:
            age = t - start
            if age < 0:
                continue
            phase = frequency * age
            if name == "bubble":
                phase += 160 * age * age
            elif name in {"pop", "drop"}:
                phase += 160 * .025 * (1 - math.exp(-age / .025))
            envelope = min(1, age / .003) * math.exp(-age / decay)
            value += math.sin(2 * math.pi * phase) * envelope
        fade = min(1, (duration - t) / .012)
        samples.append(round(32767 * .24 * value / len(tones) * fade))
    with wave.open(str(DEST / f"copy-{name}.wav"), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    print(f"copy-{name}.wav: {duration:.3f}s")

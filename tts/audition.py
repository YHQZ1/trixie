#!/usr/bin/env python3
"""Play the same sentence in several Kokoro voices so you can pick one.

Usage: .venv/bin/python audition.py [voice ...]
"""
import os
import subprocess
import sys
import tempfile

import soundfile as sf
from kokoro_onnx import Kokoro

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import HERE, synthesize, trim  # noqa: E402

TEXT = (
    "Hey Uttkarsh, I looked through your folders. You've got three selected projects: "
    "Escrow, Hatch and Kprobe. Honestly, Hatch is the one I'd start with, if you're asking me."
)
DEFAULT = [
    ("af_heart", "en-us"), ("af_bella", "en-us"), ("af_nicole", "en-us"), ("af_sarah", "en-us"),
    ("am_michael", "en-us"), ("am_adam", "en-us"), ("bf_emma", "en-gb"), ("bm_george", "en-gb"),
]

kokoro = Kokoro(os.path.join(HERE, "kokoro-v1.0.onnx"), os.path.join(HERE, "voices-v1.0.bin"))
picks = [(v, "en-gb" if v.startswith("b") else "en-us") for v in sys.argv[1:]] or DEFAULT

for i, (voice, lang) in enumerate(picks, 1):
    print(f"{i}. {voice}", flush=True)
    samples, rate = synthesize(kokoro, TEXT, voice=voice, speed=1.0, lang=lang)
    path = tempfile.mkstemp(suffix=".wav")[1]
    sf.write(path, trim(samples, rate), rate)
    subprocess.run(["/usr/bin/afplay", path])
    os.remove(path)

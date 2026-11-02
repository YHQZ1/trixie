#!/usr/bin/env python3
"""A/B: the same answer written like text vs. said like a person. Usage: .venv/bin/python compare.py"""
import os, subprocess, sys, tempfile
import soundfile as sf
from kokoro_onnx import Kokoro
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import HERE, synthesize, trim

WRITTEN = ("Hatch is your deploy tool, similar to Render, but it places applications into the user's own "
           "AWS account instead of hosting them. It includes cost guardrails so that people do not receive "
           "unexpected cloud bills. It is currently in Phase 2 of the roadmap.")
SPOKEN = ("Oh, Hatch? Yeah, it's your deploy thing. Kind of like Render, but everything goes into your own "
          "AWS account, not theirs. And it's got these cost guardrails, so you don't wake up to some crazy bill. "
          "Right now it's in phase two. Want me to dig into what's next?")

k = Kokoro(os.path.join(HERE, "kokoro-v1.0.onnx"), os.path.join(HERE, "voices-v1.0.bin"))
clips = [
    ("1. written text, default pacing   (af_heart)", WRITTEN, "af_heart", 1.0, 0.25, 0.10),
    ("2. said like a person, tighter    (af_heart)", SPOKEN, "af_heart", 1.08, 0.14, 0.06),
    ("3. said like a person             (af_jessica)", SPOKEN, "af_jessica", 1.08, 0.14, 0.06),
    ("4. said like a person             (af_nova)", SPOKEN, "af_nova", 1.08, 0.14, 0.06),
    ("5. said like a person             (af_river)", SPOKEN, "af_river", 1.08, 0.14, 0.06),
]
for label, text, voice, speed, sp, cp in clips:
    print(label, flush=True)
    samples, rate = synthesize(k, text, voice, speed, "en-us", sentence_pause=sp, clause_pause=cp)
    path = tempfile.mkstemp(suffix=".wav")[1]; sf.write(path, trim(samples, rate), rate)
    subprocess.run(["/usr/bin/afplay", path]); os.remove(path)

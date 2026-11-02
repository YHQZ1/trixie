#!/usr/bin/env python3
"""Play original vs. shaped sentence endings. Usage: .venv/bin/python ab_prosody.py [voice]"""
import os, subprocess, sys, tempfile, time
import soundfile as sf
from kokoro_onnx import Kokoro
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import HERE, synthesize, shape_end, trim

voice = sys.argv[1] if len(sys.argv) > 1 else "af_heart"
k = Kokoro(os.path.join(HERE, "kokoro-v1.0.onnx"), os.path.join(HERE, "voices-v1.0.bin"))
LINES = ["Does that sound like a good plan to you?",
         "Oh, the weather? Yeah, it's looking nice today.",
         "You want me to dig into what's next?",
         "Okay, so it's in phase two right now."]
def play(x, sr):
    p = tempfile.mkstemp(suffix=".wav")[1]; sf.write(p, x, sr); subprocess.run(["/usr/bin/afplay", p]); os.remove(p)
print(f"voice: {voice}", flush=True)
for text in LINES:
    s, sr = synthesize(k, text, voice, 1.06, "en-us"); s = trim(s, sr)
    print(f"\n  {text}", flush=True)
    print("    original", flush=True); play(s, sr); time.sleep(0.4)
    print("    shaped  ", flush=True); play(shape_end(s, sr, text), sr); time.sleep(0.9)

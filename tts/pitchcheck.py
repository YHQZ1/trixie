#!/usr/bin/env python3
"""How does the pitch of the last word move? (+ rises, - falls, in semitones.) Usage: .venv/bin/python pitchcheck.py"""
import os, sys
from kokoro_onnx import Kokoro
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import HERE, synthesize, shape_end, trim, last_word

k = Kokoro(os.path.join(HERE, "kokoro-v1.0.onnx"), os.path.join(HERE, "voices-v1.0.bin"))
pairs = [("statement", "You want me to dig into what's next."),
         ("question ", "You want me to dig into what's next?"),
         ("question ", "Does that sound like a good plan to you?"),
         ("statement", "That sounds like a good plan to me."),
         ("wh-quest.", "What do you want to look at first?"),
         ("statement", "Yeah, it's your deploy thing.")]
def shift(x, sr):
    r = last_word(x, sr); return "  n/a" if r is None else f"{r[2]:+5.1f}"
print("pitch movement across the last word, in semitones\n")
for voice in ("af_heart", "af_nova", "af_jessica"):
    print(voice)
    for label, text in pairs:
        s, sr = synthesize(k, text, voice, 1.06, "en-us"); s = trim(s, sr)
        print(f"   {label}  before {shift(s, sr)}   after {shift(shape_end(s, sr, text), sr)}   {text}")

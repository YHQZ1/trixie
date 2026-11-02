#!/usr/bin/env python3
"""A/B the cloud voice. Compares how the same text sounds with different settings, and how
sentence-by-sentence (what the app does) differs from one request (what the website does).
Usage: .venv/bin/python eleven_lab.py [voice|name]      costs ElevenLabs credits."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import CloudVoice, chars_used

SENTENCES = ["Oh, the forecast?", "Yeah, it's sunny all week.",
             "Kind of warm too, so you probably won't need a jacket at all.",
             "Want me to dig into what's next?"]
PARAGRAPH = " ".join(SENTENCES)

def play(path):
    subprocess.run(["/usr/bin/afplay", path]); os.remove(path); time.sleep(0.8)

def voice_with(**changes):
    cv = CloudVoice(); cv.cfg = {**cv.cfg, **changes}; cv.cfg["pronounce"] = {}; return cv

def one_request(label, **changes):
    print(f"\n{label}", flush=True)
    p = voice_with(**changes).clip(PARAGRAPH, None)
    if p: play(p)

def sentence_by_sentence(label, **changes):
    print(f"\n{label}", flush=True)
    cv = voice_with(**changes); prev = None
    for s in SENTENCES:
        p = cv.clip(s, prev); prev = s
        if p: play(p)

mode = sys.argv[1] if len(sys.argv) > 1 else "voice"
if mode == "voice":
    one_request("A. one request, like the website   (stability 45%)")
    sentence_by_sentence("B. sentence by sentence, like the app does now   (stability 45%)")
    one_request("C. one request   (stability 30%, looser and more expressive)", stability=0.30)
    one_request("D. one request   (stability 30% + style 25%)", stability=0.30, style=0.25)
else:
    for spelling in ("Utkarsh", "Ootkarsh", "Ootkursh", "Uutkarsh"):
        print(f"\nname spelled: {spelling}", flush=True)
        p = voice_with().clip(f"Hey {spelling}, welcome back.", None)
        if p: play(p)
print(f"\n(used {chars_used()} characters this month)")

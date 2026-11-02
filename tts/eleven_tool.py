#!/usr/bin/env python3
"""Helper for the ElevenLabs voice.

  .venv/bin/python eleven_tool.py --find Jessica          list matching voices and their IDs
  .venv/bin/python eleven_tool.py --use Jessica           save that voice's ID into voice.json
  .venv/bin/python eleven_tool.py --say "Hello there."    speak a line with the current settings
  .venv/bin/python eleven_tool.py --usage                 characters used this month

The API key is read from the macOS Keychain (item: elevenlabs-api-key).
"""
import argparse, json, os, subprocess, sys, urllib.error, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import CONFIG_PATH, CloudVoice, chars_used, get_api_key, load_config  # noqa: E402


def voices(key: str) -> list[dict]:
    req = urllib.request.Request("https://api.elevenlabs.io/v1/voices", headers={"xi-api-key": key})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)["voices"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--find"); ap.add_argument("--use"); ap.add_argument("--say"); ap.add_argument("--usage", action="store_true")
    a = ap.parse_args()
    if a.usage:
        cfg = load_config(); print(f"{chars_used()} / {cfg.get('monthly_character_cap', '∞')} characters this month"); return
    key = get_api_key()
    if not key:
        sys.exit("No key found. Add it to the Keychain first:\n  security add-generic-password -a \"$USER\" -s elevenlabs-api-key -w")
    try:
        if a.find or a.use:
            name = (a.find or a.use).lower()
            hits = [v for v in voices(key) if name in v["name"].lower()]
            if not hits: sys.exit(f"No voice matching '{name}' in your account.")
            for v in hits:
                print(f"{v['name']:<34} {v['voice_id']}   [{v.get('category', '?')}]")
            if a.use:
                v = hits[0]; cfg = load_config(); cfg["voice_id"] = v["voice_id"]; cfg["voice_name"] = v["name"].split(" - ")[0]
                json.dump(cfg, open(CONFIG_PATH, "w"), indent=2); print(f"\nSaved {v['name']} to voice.json")
        if a.say:
            cv = CloudVoice()
            if not cv.enabled: sys.exit("Set a voice first:  eleven_tool.py --use Jessica")
            path = cv.clip(a.say, None)
            if not path: sys.exit("The cloud voice didn't answer (see the event above).")
            subprocess.run(["/usr/bin/afplay", path]); os.remove(path)
            print(f"used {chars_used()} characters this month")
    except urllib.error.HTTPError as e:
        sys.exit(f"ElevenLabs said HTTP {e.code}: {e.read().decode()[:200]}")

main()

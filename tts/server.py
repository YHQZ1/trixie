#!/usr/bin/env python3
"""Kokoro voice helper for claude.

Started once by the Swift app. It loads the model a single time, then reads one
JSON command per line on stdin and answers with one JSON event per line on stdout.

  {"cmd": "say", "text": "...", "voice": "af_heart", "speed": 1.0, "lang": "en-us"}
  {"cmd": "stop"}      stop talking now and forget anything queued
  {"cmd": "quit"}

  {"event": "ready", "engine": "elevenlabs" | "kokoro"}   the model is loaded
  {"event": "cloud_down", "reason": ...}   the cloud voice failed; using Kokoro for now
  {"event": "speaking"} a clip has just started playing
  {"event": "idle"}    everything queued has been spoken

Speech is produced one chunk ahead of playback, so the next sentence is already
being made while the current one plays.
"""
import datetime
import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

HERE = os.path.dirname(os.path.abspath(__file__))

# Words the model tends to get wrong, spelled the way they should be said.
PRONUNCIATIONS = {
    r"\bUttkarsh\b": "Utkarsh",
    r"\beBPF\b": "E B P F",
    r"\bkubectl\b": "kube control",
    r"\bK8s\b": "Kubernetes",
    r"\bGitHub\b": "Git Hub",
    r"\bPostgres\b": "Postgres",
    r"\bnpm\b": "N P M",
    r"\bAPI\b": "A P I",
    r"\bCLI\b": "C L I",
    r"\bSIP\b": "S I P",
}


def say_it_right(text: str) -> str:
    for pattern, spoken in PRONUNCIATIONS.items():
        text = re.sub(pattern, spoken, text)
    return text


# Fixes at the level of sounds (IPA), applied after the text has been turned into
# phonemes. Use this when respelling a word can't produce the sound you want.
PHONEME_FIXES = {
    # "Utkarsh": the U is a short "oo" as in "put" (ʊ), not the "uh" in "cut" (ʌ).
    "ʌtkɑːɹʃ": "ʊtkɑːɹʃ",
}


# How long the voice pauses, in seconds. Shorter pauses sound more like chat than like reading.
SENTENCE_PAUSE = 0.14
CLAUSE_PAUSE = 0.06


def synthesize(kokoro: Kokoro, text: str, voice: str, speed: float, lang: str, fixes: bool = True,
               sentence_pause: float = SENTENCE_PAUSE, clause_pause: float = CLAUSE_PAUSE):
    """Text in, (samples, sample_rate) out, with our pronunciation fixes applied."""
    text = say_it_right(text)
    phonemes = kokoro.tokenizer.phonemize(text, lang)
    if fixes:
        for wrong, right in PHONEME_FIXES.items():
            phonemes = phonemes.replace(wrong, right)
    return kokoro.create(phonemes, voice=voice, speed=speed, lang=lang, is_phonemes=True,
                         sentence_pause=sentence_pause, clause_pause=clause_pause)


# --- Prosody: make the end of each sentence follow its punctuation ----------------------
# The voice model barely reacts to "?" (and some statements end on a rise, which sounds
# unsure). So we find the last voiced word of the sentence, measure how its pitch moves,
# and gently bend that word: up for questions, down for statements.

QUESTION_WORDS = {"who", "whom", "whose", "what", "which", "when", "where", "why", "how"}
HOP = 0.01  # seconds between pitch measurements


def f0_track(x: np.ndarray, sr: int, fmin: int = 75, fmax: int = 400, frame: float = 0.04) -> np.ndarray:
    """A simple pitch tracker (autocorrelation). NaN where the sound isn't voiced."""
    n, h = int(frame * sr), int(HOP * sr)
    lo, hi = int(sr / fmax), int(sr / fmin)
    out = []
    for i in range(0, len(x) - n, h):
        seg = x[i:i + n] - np.mean(x[i:i + n])
        if np.sqrt(np.mean(seg ** 2)) < 0.01:
            out.append(np.nan); continue
        ac = np.correlate(seg, seg, "full")[n - 1:]
        ac = ac / (ac[0] + 1e-9)
        k = lo + int(np.argmax(ac[lo:hi]))
        out.append(sr / k if ac[k] > 0.4 else np.nan)
    f = np.array(out)
    if np.any(~np.isnan(f)):                      # throw away octave-jump glitches
        med = np.nanmedian(f)
        f[(f < med * 0.65) | (f > med * 1.5)] = np.nan
    return f


def last_word(x: np.ndarray, sr: int, ms: int = 300):
    """(start, end, shift): the final stretch of voiced speech and how its pitch moves, in semitones."""
    f = f0_track(x, sr)
    voiced = np.where(~np.isnan(f))[0]
    if len(voiced) < 25:
        return None
    h = int(HOP * sr)
    end = min(len(x), voiced[-1] * h + int(0.04 * sr))
    start = max(0, end - int(sr * ms / 1000))
    seg = f[start // h: voiced[-1] + 1]
    seg = seg[~np.isnan(seg)]
    if len(seg) < 10:
        return None
    return start, end, float(12 * np.log2(np.median(seg[-4:]) / np.median(seg[:4])))


def bend(x: np.ndarray, start: int, end: int, semitones: float, sr: int) -> np.ndarray:
    """Bend the pitch of x[start:end] so it ends `semitones` higher (or lower) than it began."""
    seg = x[start:end]
    n = len(seg)
    out_len = max(8, int(n / 2 ** (semitones / 24)))
    rate = 2 ** ((semitones / 12) * np.linspace(0, 1, out_len))   # reading speed ramps from 1
    pos = np.cumsum(rate) - rate[0]
    pos = pos[pos <= n - 1]
    bent = np.interp(pos, np.arange(n), seg).astype(x.dtype)
    return np.concatenate([x[:start], bent, x[end:]])


def shape_end(x: np.ndarray, sr: int, text: str) -> np.ndarray:
    """End the sentence the way its punctuation says: rise for questions, settle for statements."""
    t = text.strip()
    if not t or t[-1] not in "?.":
        return x
    info = last_word(x, sr)
    if info is None:
        return x
    start, end, shift = info
    if t[-1] == "?":
        words = re.findall(r"[a-z']+", t.lower())
        target = 1.0 if (words and words[0] in QUESTION_WORDS) else 4.0
    else:
        target = -2.5
    delta = float(np.clip(target - shift, -7.0, 7.0))
    if abs(delta) < 0.8:
        return x
    return bend(x, start, end, delta, sr)


def trim(samples: np.ndarray, rate: int, keep_ms: int = 70) -> np.ndarray:
    """Cut the long silence the model leaves at both ends, keep a short natural gap."""
    loud = np.where(np.abs(samples) > 0.01)[0]
    if loud.size == 0:
        return samples
    pad = int(rate * keep_ms / 1000)
    return samples[max(0, loud[0] - pad): min(len(samples), loud[-1] + pad)]


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


# --- Cloud voice (ElevenLabs) -----------------------------------------------------------
# Used when a key is in the Keychain and tts/voice.json has a voice_id. Falls back to the
# local Kokoro voice if the internet is down, the key is rejected, or the monthly
# character cap is reached, so it never goes silent and never runs up a bill.

CONFIG_PATH = os.path.join(HERE, "voice.json")
USAGE_PATH = os.path.expanduser("~/.claude-pet/usage.json")


def load_config() -> dict:
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def get_api_key() -> str | None:
    """From the environment, or from the macOS Keychain (item: elevenlabs-api-key)."""
    key = os.environ.get("ELEVENLABS_API_KEY")
    if key:
        return key.strip()
    try:
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "elevenlabs-api-key", "-w"],
            capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip() or None if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def _month() -> str:
    return datetime.date.today().strftime("%Y-%m")


def chars_used() -> int:
    try:
        with open(USAGE_PATH) as f:
            data = json.load(f)
        return int(data.get("chars", 0)) if data.get("month") == _month() else 0
    except (OSError, json.JSONDecodeError, ValueError):
        return 0


def add_chars(n: int) -> None:
    os.makedirs(os.path.dirname(USAGE_PATH), exist_ok=True)
    total = chars_used() + n          # read the old total BEFORE opening the file (opening it empties it)
    tmp = USAGE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"month": _month(), "chars": total}, f)
    os.replace(tmp, USAGE_PATH)       # swap in whole, so a crash can't leave a half-written file


class CloudVoice:
    def __init__(self) -> None:
        self.cfg = load_config()
        self.key = get_api_key()
        self.down_until = 0.0
        self.enabled = bool(self.key and self.cfg.get("voice_id"))
        self.recent_ids: list[str] = []        # ids of the last clips, so each sentence continues the last
        self.stitch = True

    def available(self, text: str) -> bool:
        if not self.enabled or time.time() < self.down_until:
            return False
        cap = int(self.cfg.get("monthly_character_cap", 0))
        return not cap or chars_used() + len(text) <= cap

    def speakable(self, text: str) -> str:
        for word, spoken in self.cfg.get("pronounce", {}).items():
            text = re.sub(rf"\b{re.escape(word)}\b", spoken, text)
        return text

    def clip(self, text: str, previous: str | None) -> str | None:
        """Make an mp3 of `text`. Returns its path, or None if the cloud can't be used right now."""
        text = self.speakable(text)
        body = {
            "text": text,
            "model_id": self.cfg.get("model", "eleven_multilingual_v2"),
            "voice_settings": {
                "stability": self.cfg.get("stability", 0.45),
                "similarity_boost": self.cfg.get("similarity_boost", 0.75),
                "style": self.cfg.get("style", 0.0),
                "use_speaker_boost": self.cfg.get("use_speaker_boost", True),
                "speed": self.cfg.get("speed", 1.0),
            },
        }
        if self.stitch and self.recent_ids:
            body["previous_request_ids"] = self.recent_ids[-3:]   # continue from the actual audio before
        elif previous:
            body["previous_text"] = previous      # otherwise at least tell it what came before
        url = (f"https://api.elevenlabs.io/v1/text-to-speech/{self.cfg['voice_id']}/stream"
               "?output_format=mp3_44100_128")
        req = urllib.request.Request(
            url, data=json.dumps(body).encode(),
            headers={"xi-api-key": self.key, "Content-Type": "application/json", "Accept": "audio/mpeg"},
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                audio = r.read()
                rid = r.headers.get("request-id")
                if rid:
                    self.recent_ids = (self.recent_ids + [rid])[-3:]
        except urllib.error.HTTPError as e:
            if e.code == 400 and self.stitch and "previous_request_ids" in body:
                self.stitch = False                # this model doesn't support stitching: carry on without it
                self.recent_ids = []
                return self.clip(text, previous)
            # 401 bad key, 402/429 out of credits or too many requests: stop trying for a while
            self.down_until = time.time() + (600 if e.code in (401, 402, 403, 429) else 30)
            emit({"event": "cloud_down", "reason": f"HTTP {e.code}"})
            return None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            self.down_until = time.time() + 30
            emit({"event": "cloud_down", "reason": str(e)[:80]})
            return None
        add_chars(len(text))
        fd, path = tempfile.mkstemp(suffix=".mp3", prefix="claude-tts-")
        with os.fdopen(fd, "wb") as f:
            f.write(audio)
        return path


class Voice:
    def __init__(self) -> None:
        self.kokoro = Kokoro(
            os.path.join(HERE, "kokoro-v1.0.onnx"),
            os.path.join(HERE, "voices-v1.0.bin"),
        )
        self.jobs: "queue.Queue[dict]" = queue.Queue()
        self.clips: "queue.Queue[str]" = queue.Queue()
        self.generation = 0          # bumped by stop() so old work is thrown away
        self.pending = 0
        self.lock = threading.Lock()
        self.cloud = CloudVoice()
        self.last_text: str | None = None
        self.player: subprocess.Popen | None = None
        threading.Thread(target=self._make, daemon=True).start()
        threading.Thread(target=self._play, daemon=True).start()

    def say(self, job: dict) -> None:
        with self.lock:
            self.pending += 1
            job["gen"] = self.generation
        self.jobs.put(job)

    def stop(self) -> None:
        with self.lock:
            self.generation += 1
            self.pending = 0
            self.last_text = None
            self.cloud.recent_ids = []
            if self.player and self.player.poll() is None:
                self.player.terminate()
        emit({"event": "idle"})

    def _make(self) -> None:
        while True:
            job = self.jobs.get()
            if job["gen"] != self.generation:
                continue
            if self.cloud.available(job["text"]):
                path = self.cloud.clip(job["text"], self.last_text)
                if path:
                    self.last_text = job["text"]
                    self.clips.put((job["gen"], path))
                    continue
            try:
                samples, rate = synthesize(
                    self.kokoro,
                    job["text"],
                    voice=job.get("voice", "af_heart"),
                    speed=float(job.get("speed", 1.0)),
                    lang=job.get("lang", "en-us"),
                )
                samples = shape_end(trim(samples, rate), rate, job["text"])
                fd, path = tempfile.mkstemp(suffix=".wav", prefix="claude-tts-")
                os.close(fd)
                sf.write(path, samples, rate)
                self.clips.put((job["gen"], path))
            except Exception as e:  # keep going if one sentence fails
                emit({"event": "error", "message": str(e)})
                self._finished_one(job["gen"])

    def _play(self) -> None:
        while True:
            gen, path = self.clips.get()
            if gen == self.generation:
                emit({"event": "speaking"})
                self.player = subprocess.Popen(["/usr/bin/afplay", path])
                self.player.wait()
            try:
                os.remove(path)
            except OSError:
                pass
            self._finished_one(gen)

    def _finished_one(self, gen: int) -> None:
        with self.lock:
            if gen != self.generation:
                return
            self.pending = max(0, self.pending - 1)
            done = self.pending == 0
        if done:
            emit({"event": "idle"})


def main() -> None:
    voice = Voice()
    emit({"event": "ready", "engine": "elevenlabs" if voice.cloud.enabled else "kokoro"})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = msg.get("cmd")
        if cmd == "say":
            voice.say(msg)
        elif cmd == "stop":
            voice.stop()
        elif cmd == "quit":
            break
    voice.stop()


if __name__ == "__main__":
    main()

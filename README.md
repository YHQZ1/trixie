# Trixie

A little desktop pet you talk to. Native Swift, no web. Built on the `claude` CLI so it uses your own subscription.

## Where it is

| Step | What | Status |
|---|---|---|
| 1 | Text brain: type, Claude answers, reply is spoken | done |
| 2 | Voice in: hold a hotkey, speak, speech becomes text | done |
| 3 | The pet window: pixel creature with listening / thinking / working / talking / happy / sleeping moods | done |
| 3b | Natural voice: ElevenLabs (cloud) with Kokoro (local) as the fallback | done |
| 4 | Tools: music, Mac control, calendar and mail, each behind a confirmation | next |
| 5 | Wake word ("hey claude") | |

## Run it

```
./scripts/run.sh        # builds the app, starts it, shows its log. Hold Option+Space and talk.
swift run trixie-talk   # the text-only version (step 1)
```

It must run as an app (`build/Trixie.app`) so macOS asks for microphone and speech permission.
macOS Dictation has to be switched on (System Settings > Keyboard) for speech recognition to work.

### Voice

- Cloud: ElevenLabs. Voice and settings are in `tts/voice.json`. The API key lives in the Keychain: `security add-generic-password -a "$USER" -s elevenlabs-api-key -w`. A monthly character cap (default 8000) keeps it free; past it, or if the network fails, the local Kokoro voice takes over.
- Local: Kokoro via `tts/.venv` (model files `tts/kokoro-v1.0.onnx` and `tts/voices-v1.0.bin` are not in git).
- Tools: `tts/eleven_tool.py` (find a voice, test a line, show usage), `tts/eleven_lab.py` (A/B settings), `tts/audition.py` (Kokoro voices).

Optional settings: `CLAUDE_VOICE=Samantha`, `CLAUDE_RATE=190`, `CLAUDE_MUTE=1`, `CLAUDE_CWD=~/Developer`.
Type `/new` for a fresh chat and `/quit` to leave. List voices with `say -v '?'`.

## How it works

- `ClaudeKit/ClaudeSession.swift` starts the `claude` CLI per question, streams its answer, and keeps the conversation going with `--resume`.
- It runs with a slim setup (only Read, Glob and Grep, no MCP servers, no skills) so each question costs about 5k tokens instead of 20k+. Read-only on purpose until confirmations exist.
- `ClaudeKit/SpeechText.swift` cuts the stream into sentences and cleans markdown so it sounds natural.
- `ClaudeKit/Speaker.swift` speaks sentences through macOS `say`.
- Usage (5-hour and 7-day) comes back with every answer and is shown after each reply.

## Notes

- Don't use `claude --bare` here: it never reads your subscription login and would need an API key.
- The pet is called Trixie. The pixel creature is a placeholder design; give it a distinct look before this goes public.

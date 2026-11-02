#!/bin/bash
# Build the app, start it, and show what it prints. Ctrl-C stops it.
# Settings such as CLAUDE_VOICE or CLAUDE_HOTKEY are passed through.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
LOG=/tmp/trixie.log
pkill -f "Trixie.app/Contents/MacOS/trixie" 2>/dev/null || true
: > "$LOG"
ENVARGS=()
for v in $(env | grep -oE '^CLAUDE_[A-Z_]+' || true); do ENVARGS+=(--env "$v=${!v}"); done
open "${ENVARGS[@]}" --stdout "$LOG" --stderr "$LOG" build/Trixie.app
trap 'pkill -f "Trixie.app/Contents/MacOS/trixie" 2>/dev/null || true; exit 0' INT TERM
tail -f "$LOG"

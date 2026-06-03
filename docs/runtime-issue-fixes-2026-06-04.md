# Runtime issue fixes, 2026-06-04

## Duplicate auto-apply / clipboard paste

Symptom: while both the settings page and the background watcher are active, the same Codex transcription can be observed by two independent polling loops. Each loop can call `/api/auto-apply-codex-transcription`, causing repeated clipboard writes or repeated paste attempts.

Fix: `scripts/Serve-ReviewPanel.ps1` now keeps `.codex-tmp/voice-feedback/auto-apply-handled.json`. Once a transcription id has been successfully copied/applied, later auto-apply requests for the same transcription return `duplicate_transcription_already_auto_applied` and do not write the clipboard or send paste keys again.

## Neural voice timeout false fallback

Symptom: `say-neural.ps1` can generate audio and start playback, but the PowerShell process remains alive until playback finishes. If Codex calls it with a short command timeout, the caller can mislabel the successful playback as a failure and then call `say.ps1`, causing duplicate speech.

Operational rule: call `say-neural.ps1` with a timeout long enough for generation and playback, normally at least 90-120 seconds for final summaries. If a neural call times out, inspect `%TEMP%\codex-voice-recent\*.json` first. When a recent marker for the same message has state `started`, `generated`, `playing`, or `played`, do not call the local SAPI fallback.

This project must not add a new TTS wrapper. Reply speech remains owned by the caller's separate local voice-reply workflow, not by this voice-input bridge.

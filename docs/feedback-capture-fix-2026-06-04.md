# 2026-06-04 feedback capture fix

Problem: background auto-apply read Codex transcription history, polished the text, and pasted it into the Codex composer. If the user then edited the composer text directly and sent it without returning to the calibration page, the correction was not written to `.codex-tmp/voice-feedback/yyyy-MM-dd.jsonl`.

Fix:

1. `Start-CodexVoiceCalibrationWatcher.ps1` now performs a background sent-text confirmation after successful auto-apply when sent-text monitoring is enabled.
2. The service defaults support sent-text monitoring, while the published settings file keeps opt-in safety defaults for learning, auto-apply, and startup.
3. The watcher calls `api/latest-codex-sent-text` to read local Codex session JSONL files and match the actual sent user message against the auto-applied text.
4. When the sent text differs from the polished text, the watcher calls `api/feedback` to write a local difference sample.

Privacy boundary: this still only reads Codex transcription history and local Codex session JSONL. It does not monitor keyboard, mouse, or screen activity.

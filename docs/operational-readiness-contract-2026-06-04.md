# Operational readiness contract

Use this contract before saying the voice-input workflow is "usable".

## Wording rules

- "Implemented" means code or configuration was changed.
- "Configured" means settings are enabled.
- "Running" means the local service and watcher process are currently alive.
- "Usable" means the runtime checks pass and there is recent transcription evidence, or the user has just completed a live voice test.

Do not say auto-start, auto-learning, auto-sample capture, or auto-apply is truly usable based only on configuration files.

## Required check

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Test-CodexVoiceReadiness.ps1"
```

Interpretation:

- `usable_with_recent_transcription_evidence`: safe to call usable.
- `configured_but_needs_live_voice_test`: configuration and services look ready, but ask for a short voice test before calling transcription usable.
- `not_ready`: do not call usable; report the failed checks.

## Boundary

This readiness check does not record audio and does not monitor keyboard, mouse, or screen activity. It checks local settings, startup registration, service health, watcher state, Windows audio services, recent Codex transcription history, and feedback-log presence.

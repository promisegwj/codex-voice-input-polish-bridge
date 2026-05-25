# Release Manifest

## Included

- `scripts/`: local service, bridge invocation, feedback learning iteration, cleanup, and optional task registration scripts.
- `web/`: review panel and calibration/settings page.
- `config/`: safe default settings and onboarding calibration topics.
- `.github/`: issue templates, pull request template, and validation workflow.
- `tools/CodexVoicePromptBridge/`: source for the local text polishing bridge.
- `tools/TypeWhisperT2S/`: character table and legacy helper source needed by the bridge project.
- `docs/`, `CONTRIBUTING.md`, `ROADMAP.md`, `CHANGELOG.md`, `SECURITY.md`, `SUPPORT.md`, and `TypeWhisper-Codex-Workflow.md`: workflow, oral-to-standard text rules draft, and maintenance documentation with local paths sanitized.

## Excluded

- `.codex-tmp/`: feedback samples, generated profiles, logs, and local runtime data.
- `downloads/`: downloaded installers and test audio.
- `typewhisper-win/`: upstream TypeWhisper working copy.
- `tools/**/bin`, `tools/**/obj`, `tools/**/publish*`: generated build and publish output.
- `app-main-*.js`, `preload.js`: local investigation artifacts from Codex desktop bundle inspection.
- `AGENTS.md`: local Codex collaboration rules containing workspace-specific behavior.

## Before Publishing

1. Review `config/voice-feedback-settings.json`; keep learning and auto-apply disabled for public defaults.
2. Confirm `LICENSE` remains Apache-2.0 and README links to it.
3. Run `git status --short` inside this directory and confirm only intended files are tracked.
4. Build from source if you need a release binary; do not commit generated publish output unless you intentionally attach it to a GitHub Release artifact.

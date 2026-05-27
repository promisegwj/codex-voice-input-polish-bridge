# Release Checklist

Run this before creating a public release or pushing to a new remote.

## Repository Hygiene

- [ ] `git status --short` contains only intended files.
- [ ] No `.codex-tmp/`, `downloads/`, `bin/`, `obj/`, `publish/`, or `publish-self-contained/` files are tracked.
- [ ] No personal paths, usernames, API keys, tokens, or private workflow details are present.
- [ ] `config/voice-feedback-settings.json` keeps safe defaults:
  - [ ] `feedbackLearning.enabled = false`
  - [ ] `activeCalibration.autoApplyEnabled = false`
  - [ ] `activeCalibration.sentTextMonitorEnabled = false`
  - [ ] `activeCalibration.macOsBestEffortPasteEnabled = false`
  - [ ] `fixedEntry.autoStartWithCodex = false`

## Validation

```powershell
Get-ChildItem ".\config" -Filter *.json | ForEach-Object {
  Get-Content -Raw -Encoding UTF8 $_.FullName | ConvertFrom-Json | Out-Null
}

Get-ChildItem ".\scripts" -Filter *.ps1 | ForEach-Object {
  $errors = $null
  [System.Management.Automation.PSParser]::Tokenize(
    (Get-Content -Raw -Encoding UTF8 $_.FullName),
    [ref]$errors
  ) | Out-Null
  if ($errors.Count -gt 0) { throw $_.FullName }
}

dotnet build ".\tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tests\Run-VoiceBridgeGoldenCases.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Publish-CodexVoiceBridge.ps1" -Runtime all
dotnet build ".\tools\TypeWhisperT2S\TypeWhisperT2S.csproj" -c Release
```

## Publishing

- [ ] Confirm `LICENSE` is Apache-2.0 and README links to it.
- [ ] Update `CHANGELOG.md`.
- [ ] For v0.3, explicitly note whether macOS was validated on a real machine or only by cross-publish/build checks.
- [ ] Create a commit.
- [ ] Add remote.
- [ ] Push branch and tags.

# Release Checklist

Run this before creating a public release or pushing to a new remote.

## Repository Hygiene

- [ ] `git status --short` contains only intended files.
- [ ] No `.codex-tmp/`, `downloads/`, `bin/`, `obj/`, `publish/`, or `publish-self-contained/` files are tracked.
- [ ] No personal paths, usernames, API keys, tokens, or private workflow details are present.
- [ ] `config/voice-feedback-settings.json` keeps safe defaults:
  - [ ] `feedbackLearning.enabled = false`
  - [ ] `activeCalibration.autoApplyEnabled = false`
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
dotnet build ".\tools\TypeWhisperT2S\TypeWhisperT2S.csproj" -c Release
```

## Publishing

- [ ] Decide whether to keep `LICENSE` as all-rights-reserved or replace it with an open-source license.
- [ ] Update `CHANGELOG.md`.
- [ ] Create a commit.
- [ ] Add remote.
- [ ] Push branch and tags.

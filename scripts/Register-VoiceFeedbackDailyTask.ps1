[CmdletBinding()]
param(
    [string]$TaskName = 'Codex Voice Feedback Daily Iteration',

    [string]$SettingsPath = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $projectRoot 'config\voice-feedback-settings.json'
}

$settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $SettingsPath | ConvertFrom-Json
$timeText = if ($settings.feedbackLearning.dailyIterationTime -match '^\d{2}:\d{2}$') {
    [string]$settings.feedbackLearning.dailyIterationTime
}
else {
    '00:00'
}

$at = [datetime]::ParseExact($timeText, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
$iterationScript = (Resolve-Path -LiteralPath (Join-Path $scriptRoot 'Invoke-VoiceFeedbackDailyIteration.ps1')).Path
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$iterationScript`""

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Daily -At $at
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $taskSettings `
    -Description 'Generate local Codex voice feedback learning candidates from saved web review differences.' `
    -Force | Out-Null

Write-Output "Registered scheduled task '$TaskName' at $timeText."

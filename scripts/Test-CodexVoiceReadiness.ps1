[CmdletBinding()]
param(
    [int]$Port = 8793,

    [int]$RecentTranscriptionHours = 24,

    [string]$SettingsPath = '',

    [string]$StatePath = '',

    [string]$TranscriptionHistoryPath = ''
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

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $projectRoot '.codex-tmp\voice-feedback\background-auto-apply-state.json'
}

if ([string]::IsNullOrWhiteSpace($TranscriptionHistoryPath)) {
    $homePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    $TranscriptionHistoryPath = Join-Path $homePath '.codex\transcription-history.jsonl'
}

function New-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Ok,
        [string]$Status = '',
        [object]$Details = $null
    )

    [pscustomobject]@{
        name = $Name
        ok = $Ok
        status = if ([string]::IsNullOrWhiteSpace($Status)) { if ($Ok) { 'ok' } else { 'failed' } } else { $Status }
        details = $Details
    }
}

function Test-HttpHealth {
    param([string]$Uri)

    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 2
        return [pscustomobject]@{
            ok = ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'ok')
            statusCode = $response.StatusCode
            content = $response.Content.Trim()
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false
            error = $_.Exception.Message
        }
    }
}

function Get-RecentTranscription {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            exists = $false
            recent = $false
            path = $Path
        }
    }

    $item = Get-Item -LiteralPath $Path
    $lastLine = ''
    try {
        $lastLine = Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 1
    }
    catch {
        $lastLine = ''
    }

    $latest = $null
    if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
        try {
            $latest = $lastLine | ConvertFrom-Json
        }
        catch {
            $latest = $null
        }
    }

    $createdAtLocal = $null
    if ($latest -and $latest.createdAtMs) {
        $createdAtLocal = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$latest.createdAtMs).LocalDateTime
    }

    $ageHours = if ($createdAtLocal) {
        [Math]::Round(((Get-Date) - $createdAtLocal).TotalHours, 2)
    }
    else {
        [Math]::Round(((Get-Date) - $item.LastWriteTime).TotalHours, 2)
    }

    [pscustomobject]@{
        exists = $true
        recent = ($ageHours -le $RecentTranscriptionHours)
        path = $Path
        length = $item.Length
        lastWriteTime = $item.LastWriteTime.ToString('o')
        latestCreatedAt = if ($createdAtLocal) { $createdAtLocal.ToString('o') } else { '' }
        latestTextPreview = if ($latest -and $latest.text) { ([string]$latest.text).Substring(0, [Math]::Min(80, ([string]$latest.text).Length)) } else { '' }
        ageHours = $ageHours
    }
}

$checks = @()

$settings = $null
if (Test-Path -LiteralPath $SettingsPath) {
    try {
        $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $SettingsPath | ConvertFrom-Json
        $checks += New-Check -Name 'settings_json' -Ok $true -Details @{ path = $SettingsPath }
    }
    catch {
        $checks += New-Check -Name 'settings_json' -Ok $false -Details @{ path = $SettingsPath; error = $_.Exception.Message }
    }
}
else {
    $checks += New-Check -Name 'settings_json' -Ok $false -Details @{ path = $SettingsPath; error = 'missing' }
}

if ($settings) {
    $checks += New-Check -Name 'feedback_learning_enabled' -Ok ([bool]$settings.feedbackLearning.enabled) -Details @{
        enabled = [bool]$settings.feedbackLearning.enabled
        storageDir = [string]$settings.feedbackLearning.storageDir
    }
    $checks += New-Check -Name 'auto_apply_enabled' -Ok ([bool]$settings.activeCalibration.autoApplyEnabled) -Details @{
        enabled = [bool]$settings.activeCalibration.autoApplyEnabled
        pollMilliseconds = [int]$settings.activeCalibration.autoApplyPollMilliseconds
    }
    $checks += New-Check -Name 'sent_text_monitor_enabled' -Ok ([bool]$settings.activeCalibration.sentTextMonitorEnabled) -Details @{
        enabled = [bool]$settings.activeCalibration.sentTextMonitorEnabled
        durationSeconds = [int]$settings.activeCalibration.sentTextMonitorDurationSeconds
        pollSeconds = [int]$settings.activeCalibration.sentTextMonitorPollSeconds
        minScore = [int]$settings.activeCalibration.sentTextMonitorMinScore
    }
}

$startup = $null
try {
    $startupJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'Register-VoiceCalibrationStartupTask.ps1') -Action status 2>$null
    $startup = ($startupJson | Out-String) | ConvertFrom-Json
    $checks += New-Check -Name 'startup_registered' -Ok ([bool]$startup.registered -and [bool]$startup.enabled) -Details $startup
}
catch {
    $checks += New-Check -Name 'startup_registered' -Ok $false -Details @{ error = $_.Exception.Message }
}

$health = Test-HttpHealth -Uri "http://127.0.0.1:$Port/health"
$checks += New-Check -Name 'calibration_server_health' -Ok ([bool]$health.ok) -Details $health

$watcherProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Start-CodexVoiceCalibrationWatcher.ps1' })
$checks += New-Check -Name 'watcher_process_running' -Ok ($watcherProcesses.Count -gt 0) -Details @{
    count = $watcherProcesses.Count
    processIds = @($watcherProcesses | ForEach-Object { $_.ProcessId })
}

$state = $null
if (Test-Path -LiteralPath $StatePath) {
    try {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $StatePath | ConvertFrom-Json
        $stateUpdatedAt = [DateTimeOffset]::Parse([string]$state.updatedAt)
        $stateAgeSeconds = [Math]::Round(([DateTimeOffset]::Now - $stateUpdatedAt).TotalSeconds, 1)
        $checks += New-Check -Name 'watcher_state_fresh' -Ok ($stateAgeSeconds -le 120) -Details @{
            path = $StatePath
            updatedAt = [string]$state.updatedAt
            ageSeconds = $stateAgeSeconds
            codexRunning = [bool]$state.codexRunning
            serverRunning = [bool]$state.serverRunning
            lastReason = if ($state.lastAutoApplyPollResult) { [string]$state.lastAutoApplyPollResult.reason } else { '' }
            lastHandledReason = if ($state.lastHandledAutoApplyResult) { [string]$state.lastHandledAutoApplyResult.reason } else { '' }
        }
    }
    catch {
        $checks += New-Check -Name 'watcher_state_fresh' -Ok $false -Details @{ path = $StatePath; error = $_.Exception.Message }
    }
}
else {
    $checks += New-Check -Name 'watcher_state_fresh' -Ok $false -Details @{ path = $StatePath; error = 'missing' }
}

$audioServices = @('Audiosrv', 'AudioEndpointBuilder') | ForEach-Object {
    Get-Service -Name $_ -ErrorAction SilentlyContinue
}
$audioOk = (@($audioServices | Where-Object { $_.Status -eq 'Running' }).Count -eq 2)
$checks += New-Check -Name 'windows_audio_services' -Ok $audioOk -Details @{
    services = @($audioServices | ForEach-Object { @{ name = $_.Name; status = [string]$_.Status; startType = [string]$_.StartType } })
}

$transcription = Get-RecentTranscription -Path $TranscriptionHistoryPath
$checks += New-Check -Name 'recent_transcription_evidence' -Ok ([bool]$transcription.recent) -Status $(if ([bool]$transcription.recent) { 'ok' } else { 'needs_live_voice_test' }) -Details $transcription

$feedbackRoot = if ($settings -and $settings.feedbackLearning.storageDir) {
    $dir = [string]$settings.feedbackLearning.storageDir
    if ([System.IO.Path]::IsPathRooted($dir)) { $dir } else { Join-Path $projectRoot $dir }
}
else {
    Join-Path $projectRoot '.codex-tmp\voice-feedback'
}

$latestFeedback = Get-ChildItem -LiteralPath $feedbackRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$checks += New-Check -Name 'feedback_log_present' -Ok ($null -ne $latestFeedback) -Details @{
    root = $feedbackRoot
    latest = if ($latestFeedback) { $latestFeedback.FullName } else { '' }
    latestLastWriteTime = if ($latestFeedback) { $latestFeedback.LastWriteTime.ToString('o') } else { '' }
}

$requiredNames = @(
    'settings_json',
    'feedback_learning_enabled',
    'auto_apply_enabled',
    'sent_text_monitor_enabled',
    'startup_registered',
    'calibration_server_health',
    'watcher_process_running',
    'watcher_state_fresh',
    'windows_audio_services',
    'feedback_log_present'
)

$requiredFailures = @($checks | Where-Object { $_.name -in $requiredNames -and -not [bool]$_.ok })
$liveEvidence = @($checks | Where-Object { $_.name -eq 'recent_transcription_evidence' } | Select-Object -First 1)

$overallStatus = if ($requiredFailures.Count -gt 0) {
    'not_ready'
}
elseif (-not [bool]$liveEvidence.ok) {
    'configured_but_needs_live_voice_test'
}
else {
    'usable_with_recent_transcription_evidence'
}

[pscustomobject]@{
    status = $overallStatus
    checkedAt = (Get-Date).ToString('o')
    port = $Port
    note = 'Say usable only when required checks pass and recent transcription/live voice evidence exists.'
    checks = $checks
} | ConvertTo-Json -Depth 12

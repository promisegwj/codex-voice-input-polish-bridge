[CmdletBinding()]
param(
    [int]$Port = 8793,

    [string]$WebRoot = '',

    [int]$PollSeconds = 1,

    [int]$CooldownSeconds = 10,

    [string]$SettingsPath = '',

    [string]$StatePath = '',

    [switch]$DisableBackgroundAutoApply,

    [switch]$RunOnce
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

$openScript = (Resolve-Path -LiteralPath (Join-Path $scriptRoot 'Open-VoiceCalibrationCenter.ps1')).Path
$serverScript = (Resolve-Path -LiteralPath (Join-Path $scriptRoot 'Serve-ReviewPanel.ps1')).Path
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($WebRoot)) {
    $WebRoot = Join-Path $scriptRoot '..\web'
}

$resolvedWebRoot = (Resolve-Path -LiteralPath $WebRoot).Path
$url = "http://127.0.0.1:$Port/"

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $projectRoot 'config\voice-feedback-settings.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($SettingsPath)) {
    $SettingsPath = Join-Path $projectRoot $SettingsPath
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $projectRoot '.codex-tmp\voice-feedback\background-auto-apply-state.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($StatePath)) {
    $StatePath = Join-Path $projectRoot $StatePath
}

if ($PollSeconds -lt 1) {
    $PollSeconds = 1
}
elseif ($PollSeconds -gt 60) {
    $PollSeconds = 60
}

if ($CooldownSeconds -lt 1) {
    $CooldownSeconds = 1
}
elseif ($CooldownSeconds -gt 300) {
    $CooldownSeconds = 300
}

$lockPath = Join-Path ([System.IO.Path]::GetTempPath()) "codex-voice-calibration-watcher-$Port.lock"
$lockStream = $null

function Test-CodexDesktopProcess {
    try {
        $processes = Get-CimInstance Win32_Process -Filter "Name = 'Codex.exe'" -ErrorAction Stop
        return (@($processes).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Test-CalibrationServer {
    try {
        $response = Invoke-WebRequest -Uri "${url}health" -UseBasicParsing -TimeoutSec 1
        return ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'ok')
    }
    catch {
        return $false
    }
}

function Stop-StaleCalibrationServerProcesses {
    if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return
    }

    $serverScriptName = [System.IO.Path]::GetFileName($serverScript)
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -match [regex]::Escape($serverScriptName) } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    }
    catch {
        # Best effort only. The next start attempt will report if the port is still unusable.
    }
}

function Start-CalibrationServer {
    Stop-StaleCalibrationServerProcesses
    Start-Sleep -Milliseconds 250

    $arguments = @(
        '-STA',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$serverScript`"",
        '-Port', $Port,
        '-WebRoot', "`"$resolvedWebRoot`""
    )

    Start-Process `
        -FilePath 'powershell.exe' `
        -WindowStyle Hidden `
        -ArgumentList ($arguments -join ' ') `
        -WorkingDirectory $projectRoot | Out-Null
}

function Invoke-ServerJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [object]$Body = $null,
        [int]$TimeoutSec = 3
    )

    $uri = "${url}$Path"
    if ($Method -eq 'POST') {
        $json = if ($null -eq $Body) { '{}' } else { $Body | ConvertTo-Json -Depth 10 -Compress }
        return Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec $TimeoutSec
    }

    return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec
}

function Get-AutoApplyRuntimeSettings {
    try {
        if (-not (Test-Path -LiteralPath $SettingsPath)) {
            throw "Settings file was not found: $SettingsPath"
        }

        $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $SettingsPath | ConvertFrom-Json
        $active = $settings.activeCalibration
        $pollMilliseconds = if ($active -and $active.autoApplyPollMilliseconds) {
            [int]$active.autoApplyPollMilliseconds
        }
        else {
            500
        }

        if ($pollMilliseconds -lt 500) {
            $pollMilliseconds = 500
        }
        elseif ($pollMilliseconds -gt 5000) {
            $pollMilliseconds = 5000
        }

        return [pscustomobject]@{
            enabled = ($active -and [bool]$active.autoApplyEnabled -and -not $DisableBackgroundAutoApply)
            pollMilliseconds = $pollMilliseconds
            rewriteRule = if ($active -and $active.defaultRewriteRule) { [string]$active.defaultRewriteRule } else { '' }
            sentTextMonitorEnabled = ($active -and [bool]$active.sentTextMonitorEnabled)
            sentTextMonitorDurationSeconds = if ($active -and $active.sentTextMonitorDurationSeconds) { [int]$active.sentTextMonitorDurationSeconds } else { 60 }
            sentTextMonitorPollSeconds = if ($active -and $active.sentTextMonitorPollSeconds) { [int]$active.sentTextMonitorPollSeconds } else { 3 }
            sentTextMonitorMinScore = if ($active -and $active.sentTextMonitorMinScore) { [int]$active.sentTextMonitorMinScore } else { 70 }
            source = 'settings_file'
        }
    }
    catch {
        return [pscustomobject]@{
            enabled = $false
            pollMilliseconds = 1000
            rewriteRule = ''
            sentTextMonitorEnabled = $false
            sentTextMonitorDurationSeconds = 60
            sentTextMonitorPollSeconds = 3
            sentTextMonitorMinScore = 70
            source = 'settings_file_error'
            error = $_.Exception.Message
        }
    }
}

function Get-LatestTranscriptionBaseline {
    try {
        $latest = Invoke-ServerJson -Path 'api/latest-codex-transcription' -Method POST -Body @{ maxAgeSeconds = 0 }
        if ($latest.found -and $latest.createdAtMs) {
            return [int64]$latest.createdAtMs
        }
    }
    catch {
        return 0
    }

    return 0
}

function Invoke-BackgroundAutoApply {
    param(
        [ref]$BaselineCreatedAtMs,
        [ref]$Initialized
    )

    $runtime = Get-AutoApplyRuntimeSettings
    if (-not [bool]$runtime.enabled) {
        $Initialized.Value = $false
        return [pscustomobject]@{
            enabled = $false
            found = $false
            applied = $false
            reason = 'background_auto_apply_disabled'
            pollMilliseconds = [int]$runtime.pollMilliseconds
        }
    }

    if (-not [bool]$Initialized.Value) {
        $BaselineCreatedAtMs.Value = Get-LatestTranscriptionBaseline
        $Initialized.Value = $true
        return [pscustomobject]@{
            enabled = $true
            found = $false
            applied = $false
            reason = 'baseline_initialized'
            afterCreatedAtMs = [int64]$BaselineCreatedAtMs.Value
            pollMilliseconds = [int]$runtime.pollMilliseconds
        }
    }

    $result = Invoke-ServerJson `
        -Path 'api/auto-apply-codex-transcription' `
        -Method POST `
        -Body @{
            afterCreatedAtMs = [int64]$BaselineCreatedAtMs.Value
            rewriteRule = [string]$runtime.rewriteRule
        }

    $createdAtMs = 0
    if ($result.createdAtMs) {
        $createdAtMs = [int64]$result.createdAtMs
    }
    elseif ($result.latest -and $result.latest.createdAtMs) {
        $createdAtMs = [int64]$result.latest.createdAtMs
    }

    if ($createdAtMs -gt 0) {
        $BaselineCreatedAtMs.Value = $createdAtMs
    }

    $result | Add-Member -MemberType NoteProperty -Name backgroundAutoApply -Value $true -Force
    $result | Add-Member -MemberType NoteProperty -Name pollMilliseconds -Value ([int]$runtime.pollMilliseconds) -Force
    return $result
}

function Invoke-SentTextFeedbackCapture {
    param(
        [Parameter(Mandatory = $true)]$AutoApplyResult,
        [Parameter(Mandatory = $true)]$Runtime
    )

    if (-not [bool]$Runtime.sentTextMonitorEnabled) {
        return [pscustomobject]@{
            attempted = $false
            reason = 'sent_text_monitor_disabled'
        }
    }

    if (-not [bool]$AutoApplyResult.found -or -not [bool]$AutoApplyResult.applied) {
        return [pscustomobject]@{
            attempted = $false
            reason = 'auto_apply_not_applied'
        }
    }

    $expectedText = if ($AutoApplyResult.finalText) { [string]$AutoApplyResult.finalText } else { '' }
    $rawText = if ($AutoApplyResult.rawText) { [string]$AutoApplyResult.rawText } else { '' }
    $returnedAt = if ($AutoApplyResult.returnedAt) { [string]$AutoApplyResult.returnedAt } else { (Get-Date).ToString('o') }

    if ([string]::IsNullOrWhiteSpace($expectedText)) {
        return [pscustomobject]@{
            attempted = $false
            reason = 'empty_expected_text'
        }
    }

    $durationSeconds = [int]$Runtime.sentTextMonitorDurationSeconds
    if ($durationSeconds -lt 10) { $durationSeconds = 10 }
    elseif ($durationSeconds -gt 180) { $durationSeconds = 180 }

    $pollSeconds = [int]$Runtime.sentTextMonitorPollSeconds
    if ($pollSeconds -lt 1) { $pollSeconds = 1 }
    elseif ($pollSeconds -gt 10) { $pollSeconds = 10 }

    $minScore = [int]$Runtime.sentTextMonitorMinScore
    if ($minScore -lt 1) { $minScore = 1 }
    elseif ($minScore -gt 100) { $minScore = 100 }

    $deadline = (Get-Date).AddSeconds($durationSeconds)
    $confirmation = $null
    do {
        $confirmation = Invoke-ServerJson `
            -Path 'api/latest-codex-sent-text' `
            -Method POST `
            -TimeoutSec 15 `
            -Body @{
                expectedText = $expectedText
                afterTimestamp = $returnedAt
                maxAgeSeconds = ($durationSeconds + 30)
                minScore = $minScore
            }

        if ($confirmation.found) {
            $feedback = Invoke-ServerJson `
                -Path 'api/feedback' `
                -Method POST `
                -TimeoutSec 10 `
                -Body @{
                    source = 'codex_voice_active_calibration'
                    captureContext = 'codex_voice_input'
                    decision = 'background_auto_apply_auto_saved_after_sent_confirmation'
                    stage = 'background_auto_apply'
                    topicId = 'background-auto-apply'
                    topicTitle = '后台自动应用'
                    rewriteRule = [string]$Runtime.rewriteRule
                    rawText = $rawText
                    polishedText = $expectedText
                    finalText = [string]$confirmation.text
                    sentToCodexText = [string]$confirmation.text
                    finalTextMeaning = 'text_confirmed_for_codex_send'
                    notes = @("后台发送后旁路确认：$($confirmation.score)%")
                }

            return [pscustomobject]@{
                attempted = $true
                confirmed = $true
                confirmation = $confirmation
                feedback = $feedback
            }
        }

        if ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $pollSeconds
        }
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        attempted = $true
        confirmed = $false
        reason = if ($confirmation -and $confirmation.reason) { [string]$confirmation.reason } else { 'timeout' }
        confirmation = $confirmation
    }
}

function Write-WatcherState {
    param(
        [bool]$CodexRunning,
        [bool]$ServerRunning,
        [bool]$AutoApplyInitialized,
        [int64]$AutoApplyBaselineCreatedAtMs,
        $LastAutoApplyPollResult,
        $LastHandledAutoApplyResult,
        $LastServerStartResult
    )

    try {
        $parent = Split-Path -Parent $StatePath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }

        [pscustomobject]@{
            updatedAt = (Get-Date).ToString('o')
            codexRunning = $CodexRunning
            serverRunning = $ServerRunning
            backgroundAutoApplyDisabled = [bool]$DisableBackgroundAutoApply
            autoApplyInitialized = $AutoApplyInitialized
            autoApplyBaselineCreatedAtMs = $AutoApplyBaselineCreatedAtMs
            settingsPath = $SettingsPath
            port = $Port
            url = $url
            lastServerStartResult = $LastServerStartResult
            lastAutoApplyPollResult = $LastAutoApplyPollResult
            lastHandledAutoApplyResult = $LastHandledAutoApplyResult
        } | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath $StatePath
    }
    catch {
        # Diagnostics must never break the watcher loop.
    }
}

try {
    try {
        $lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch {
        Write-Output "A Codex voice calibration watcher is already running for port $Port."
        return
    }

    $lastStartAttempt = [datetime]::MinValue
    $lastAutoApplyPoll = [datetime]::MinValue
    $autoApplyBaselineCreatedAtMs = [int64]0
    $autoApplyInitialized = $false
    $lastAutoApplyPollResult = $null
    $lastHandledAutoApplyResult = $null
    $lastServerStartResult = $null

    while ($true) {
        $codexIsRunning = Test-CodexDesktopProcess
        $serverIsRunning = Test-CalibrationServer

        if ($codexIsRunning -and -not $serverIsRunning) {
            $now = Get-Date
            if (($now - $lastStartAttempt).TotalSeconds -ge $CooldownSeconds) {
                $lastStartAttempt = $now
                try {
                    Start-CalibrationServer
                    $lastServerStartResult = [pscustomobject]@{
                        attemptedAt = (Get-Date).ToString('o')
                        started = $true
                        reason = 'server_health_failed'
                    }
                }
                catch {
                    $lastServerStartResult = [pscustomobject]@{
                        attemptedAt = (Get-Date).ToString('o')
                        started = $false
                        reason = 'server_start_failed'
                        error = $_.Exception.Message
                    }
                    Write-Output "Failed to start calibration server: $($_.Exception.Message)"
                }
            }
        }
        elseif ($codexIsRunning -and $serverIsRunning) {
            $runtime = Get-AutoApplyRuntimeSettings
            $now = Get-Date
            if ([bool]$runtime.enabled -and (($now - $lastAutoApplyPoll).TotalMilliseconds -ge [int]$runtime.pollMilliseconds)) {
                $lastAutoApplyPoll = $now
                try {
                    $lastAutoApplyPollResult = Invoke-BackgroundAutoApply -BaselineCreatedAtMs ([ref]$autoApplyBaselineCreatedAtMs) -Initialized ([ref]$autoApplyInitialized)
                    if ([bool]$lastAutoApplyPollResult.found -and [bool]$lastAutoApplyPollResult.applied) {
                        $feedbackCapture = Invoke-SentTextFeedbackCapture -AutoApplyResult $lastAutoApplyPollResult -Runtime $runtime
                        $lastAutoApplyPollResult | Add-Member -MemberType NoteProperty -Name backgroundSentTextFeedbackCapture -Value $feedbackCapture -Force
                    }
                    if ([bool]$lastAutoApplyPollResult.found -or [string]$lastAutoApplyPollResult.reason -eq 'baseline_initialized') {
                        $lastHandledAutoApplyResult = $lastAutoApplyPollResult
                    }
                }
                catch {
                    $lastAutoApplyPollResult = [pscustomobject]@{
                        enabled = $true
                        found = $false
                        applied = $false
                        reason = 'background_auto_apply_failed'
                        error = $_.Exception.Message
                    }
                    $lastHandledAutoApplyResult = $lastAutoApplyPollResult
                }
            }
            elseif (-not [bool]$runtime.enabled) {
                $autoApplyInitialized = $false
            }
        }
        elseif (-not $codexIsRunning) {
            $autoApplyInitialized = $false
        }

        Write-WatcherState `
            -CodexRunning $codexIsRunning `
            -ServerRunning $serverIsRunning `
            -AutoApplyInitialized $autoApplyInitialized `
            -AutoApplyBaselineCreatedAtMs $autoApplyBaselineCreatedAtMs `
            -LastAutoApplyPollResult $lastAutoApplyPollResult `
            -LastHandledAutoApplyResult $lastHandledAutoApplyResult `
            -LastServerStartResult $lastServerStartResult

        if ($RunOnce) {
            [pscustomobject]@{
                codexRunning = $codexIsRunning
                serverRunning = (Test-CalibrationServer)
                backgroundAutoApplyDisabled = [bool]$DisableBackgroundAutoApply
                autoApplyInitialized = [bool]$autoApplyInitialized
                autoApplyBaselineCreatedAtMs = [int64]$autoApplyBaselineCreatedAtMs
                settingsPath = $SettingsPath
                lastAutoApplyPollResult = $lastAutoApplyPollResult
                lastHandledAutoApplyResult = $lastHandledAutoApplyResult
                lastServerStartResult = $lastServerStartResult
                statePath = $StatePath
                port = $Port
                url = $url
            } | ConvertTo-Json -Depth 3
            return
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}

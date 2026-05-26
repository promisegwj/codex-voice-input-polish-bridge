[CmdletBinding()]
param(
    [string]$Date = '',

    [switch]$Force,

    [string]$SettingsPath = '',

    [string]$FeedbackDir = '',

    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path

function Resolve-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return (Join-Path $projectRoot $PathValue)
}

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $projectRoot 'config\voice-feedback-settings.json'
}

$settings = if (Test-Path -LiteralPath $SettingsPath) {
    Get-Content -Raw -Encoding UTF8 -LiteralPath $SettingsPath | ConvertFrom-Json
}
else {
    [pscustomobject]@{
        version = 1
        feedbackLearning = [pscustomobject]@{
            enabled = $false
            storageDir = '.codex-tmp/voice-feedback'
            generatedProfilePath = '.codex-tmp/voice-feedback/generated/voice-feedback-learning.generated.json'
            retentionDays = 30
            maxTotalStorageMb = 20
            maxRecordsPerDay = 200
            cleanupAfterSave = $true
            cleanupAfterDailyIteration = $true
        }
    }
}

$learning = $settings.feedbackLearning
if (-not $learning.PSObject.Properties.Item('cleanupAfterDailyIteration')) {
    $learning | Add-Member -MemberType NoteProperty -Name cleanupAfterDailyIteration -Value $true
}

if (-not $Force -and -not [bool]$learning.enabled) {
    Write-Output 'Voice feedback learning is disabled. Nothing to iterate.'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($FeedbackDir)) {
    $FeedbackDir = Resolve-ProjectPath ([string]$learning.storageDir)
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Resolve-ProjectPath ([string]$learning.generatedProfilePath)
}

$sourceDate = if ([string]::IsNullOrWhiteSpace($Date)) {
    (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
}
else {
    ([datetime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd')
}

$logPath = Join-Path $FeedbackDir "$sourceDate.jsonl"
$records = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $logPath) {
    foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $logPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
            if ($record.source -in @('codex_voice_web_review', 'codex_voice_active_calibration') -and ($record.sentToCodexText -or $record.finalText)) {
                $records.Add($record)
            }
        }
        catch {
            # Keep iteration resilient when a partial line is present.
        }
    }
}

function Get-TextDelta {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )

    $fromText = $From.Trim()
    $toText = $To.Trim()

    if ($fromText -eq $toText) {
        return $null
    }

    $prefix = 0
    $maxPrefix = [Math]::Min($fromText.Length, $toText.Length)
    while ($prefix -lt $maxPrefix -and $fromText[$prefix] -eq $toText[$prefix]) {
        $prefix++
    }

    $suffix = 0
    while (
        $suffix -lt ($fromText.Length - $prefix) -and
        $suffix -lt ($toText.Length - $prefix) -and
        $fromText[$fromText.Length - 1 - $suffix] -eq $toText[$toText.Length - 1 - $suffix]
    ) {
        $suffix++
    }

    $fromLength = $fromText.Length - $prefix - $suffix
    $toLength = $toText.Length - $prefix - $suffix

    $autoFragment = if ($fromLength -gt 0) { $fromText.Substring($prefix, $fromLength).Trim() } else { '' }
    $preferredFragment = if ($toLength -gt 0) { $toText.Substring($prefix, $toLength).Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($autoFragment) -and -not [string]::IsNullOrWhiteSpace($preferredFragment)) {
        $contextLength = [Math]::Min(16, $fromText.Length - $prefix)
        if ($contextLength -gt 0) {
            $context = $fromText.Substring($prefix, $contextLength).Trim()
            $contextMatch = [System.Text.RegularExpressions.Regex]::Match($context, '^[^，,。！？；;\s]{1,16}')
            if ($contextMatch.Success) {
                $autoFragment = $contextMatch.Value
                $preferredFragment = "$preferredFragment$autoFragment"
            }
        }
    }

    if ($autoFragment.Length -gt 160 -or $preferredFragment.Length -gt 160) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($autoFragment) -and [string]::IsNullOrWhiteSpace($preferredFragment)) {
        return $null
    }

    return [pscustomobject]@{
        autoFragment = $autoFragment
        preferredFragment = $preferredFragment
    }
}

$candidateCounts = @{}
$rewriteRuleCounts = @{}
$changedEvents = 0

foreach ($record in $records) {
    if (-not [string]::IsNullOrWhiteSpace([string]$record.rewriteRule)) {
        $ruleKey = ([string]$record.rewriteRule).Trim()
        if (-not $rewriteRuleCounts.ContainsKey($ruleKey)) {
            $rewriteRuleCounts[$ruleKey] = [pscustomobject]@{
                rewriteRule = $ruleKey
                count = 0
            }
        }

        $rewriteRuleCounts[$ruleKey].count++
    }

    $autoText = if ($record.polishedText) { [string]$record.polishedText } else { [string]$record.rawText }
    $finalText = if ($record.sentToCodexText) { [string]$record.sentToCodexText } else { [string]$record.finalText }
    $delta = Get-TextDelta -From $autoText -To $finalText

    if ($null -eq $delta) {
        if ($autoText.Trim() -ne $finalText.Trim()) {
            $changedEvents++
        }
        continue
    }

    $changedEvents++
    $key = "$($delta.autoFragment)$([char]31)$($delta.preferredFragment)"
    if (-not $candidateCounts.ContainsKey($key)) {
        $candidateCounts[$key] = [pscustomobject]@{
            autoFragment = $delta.autoFragment
            preferredFragment = $delta.preferredFragment
            count = 0
        }
    }

    $candidateCounts[$key].count++
}

$replacementCandidates = @(
    $candidateCounts.Values |
        Sort-Object -Property @{ Expression = 'count'; Descending = $true }, autoFragment, preferredFragment |
        Select-Object -First 50
)

$rewriteRuleSamples = @(
    $rewriteRuleCounts.Values |
        Sort-Object -Property @{ Expression = 'count'; Descending = $true }, rewriteRule |
        Select-Object -First 20
)

$profile = [pscustomobject]@{
    version = 1
    generatedAt = (Get-Date).ToString('o')
    sourceDate = $sourceDate
    sourceLog = $logPath
    eventsSeen = $records.Count
    changedEvents = $changedEvents
    rewriteRuleSamples = $rewriteRuleSamples
    replacementCandidates = $replacementCandidates
    boundaries = [pscustomobject]@{
        source = 'codex_voice_web_review_or_active_calibration_only'
        keyboardMouseMonitoring = $false
        autoApplyToBridgeRules = $false
        autoApplyToPolish = $true
    }
    notes = @(
        'This generated profile is local and may contain short derived text fragments.',
        'Candidates are applied as conservative exact replacements during local polish after pressing update rules.',
        'Review candidates before turning them into permanent bridge rules.',
        'No keyboard or mouse activity is monitored by this workflow.'
    )
}

$outputParent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputParent) -and -not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent | Out-Null
}

$profile | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $OutputPath
Write-Output "Generated voice feedback profile: $OutputPath"

if ([bool]$learning.cleanupAfterDailyIteration) {
    $cleanupScript = Join-Path $scriptRoot 'Invoke-VoiceFeedbackCleanup.ps1'
    if (Test-Path -LiteralPath $cleanupScript) {
        $cleanupArgs = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $cleanupScript,
            '-SettingsPath', $SettingsPath
        )

        if (-not [string]::IsNullOrWhiteSpace($FeedbackDir)) {
            $cleanupArgs += @('-FeedbackDir', $FeedbackDir)
        }

        try {
            & powershell.exe @cleanupArgs
        }
        catch {
            Write-Output "Voice feedback cleanup failed: $($_.Exception.Message)"
        }
    }
}

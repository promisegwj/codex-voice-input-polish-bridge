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
$recordFingerprints = @{}

if (Test-Path -LiteralPath $logPath) {
    foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $logPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
            if ($record.source -in @('codex_voice_web_review', 'codex_voice_active_calibration') -and ($record.sentToCodexText -or $record.finalText)) {
                $autoText = if ($record.polishedText) { [string]$record.polishedText } else { [string]$record.rawText }
                $finalText = if ($record.sentToCodexText) { [string]$record.sentToCodexText } else { [string]$record.finalText }
                if ($autoText.Trim() -eq $finalText.Trim()) {
                    continue
                }

                $fingerprintSource = ([string]$record.rawText) + [char]31 + $autoText + [char]31 + $finalText
                $fingerprintBytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintSource)
                $fingerprintHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($fingerprintBytes)
                $fingerprint = [BitConverter]::ToString($fingerprintHash) -replace '-', ''
                if ($recordFingerprints.ContainsKey($fingerprint)) {
                    continue
                }

                $recordFingerprints[$fingerprint] = $true
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

function Test-ReplacementCandidate {
    param([Parameter(Mandatory = $true)]$Candidate)

    $autoFragment = if ($Candidate.PSObject.Properties.Item('autoFragment')) { [string]$Candidate.autoFragment } else { '' }
    $preferredFragment = if ($Candidate.PSObject.Properties.Item('preferredFragment')) { [string]$Candidate.preferredFragment } else { '' }

    if ([string]::IsNullOrWhiteSpace($autoFragment)) {
        return $false
    }

    if ($autoFragment.Trim() -eq $preferredFragment.Trim()) {
        return $false
    }

    if ($autoFragment.Length -lt 3 -or $autoFragment.Length -gt 40 -or $preferredFragment.Length -gt 80) {
        return $false
    }

    if ($autoFragment -match '[\r\n]' -or $preferredFragment -match '[\r\n]') {
        return $false
    }

    if ($autoFragment -match '(?i)(https?://|codex://|[a-z]:\\|\.jsonl|\.md\b)' -or $preferredFragment -match '(?i)(https?://|codex://|[a-z]:\\|\.jsonl|\.md\b)') {
        return $false
    }

    if ($autoFragment -match '^[\p{P}\p{S}\d\s]+$') {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($preferredFragment)) {
        if ($autoFragment -match '(\u4EE5\u5916|\u4E4B\u5916|\u53E6\u5916|\u9664\u5916|\u9664\u4E86|\u4E0D|\u4E0D\u8981|\u5FC5\u987B|\u5982\u679C|\u662F\u5426)') {
            return $false
        }

        return ($autoFragment -match '(\u55EF|\u5443|\u554A|\u8FD9\u4E2A|\u90A3\u4E2A|\u5C31\u662F|\u7136\u540E|\u8BA9\u6211|\u4E00\u4E0B)')
    }

    return $true
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

$candidateValues = @($candidateCounts.Values)
$replacementCandidates = @(
    $candidateValues |
        Where-Object { Test-ReplacementCandidate -Candidate $_ } |
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
    candidateReview = [pscustomobject]@{
        totalDerivedCandidates = $candidateValues.Count
        safeReplacementCandidates = $replacementCandidates.Count
        skippedCandidates = [Math]::Max(0, $candidateValues.Count - $replacementCandidates.Count)
        policy = 'layer_non_conflicting_exact_replacements; adapt_general_rule_when_samples_conflict_with_existing_boundaries'
    }
    ruleAdjustments = [pscustomobject]@{
        nonConflictingAdditions = @(
            'Keep conservative exact replacements local and context-bound.',
            'Preserve user-provided filenames, links, and titles only when they appear in the current text; do not learn them as global insertions.',
            'Remove filler fragments only when they do not carry scope, exclusion, condition, or object boundaries.'
        )
        conflictHandling = @(
            'Skip single-character replacements, short English fragments, URLs, thread links, filenames, and sentence-scale rewrites.',
            'When a learned fragment conflicts with fact preservation, prefer fact and boundary preservation over replacement.'
        )
    }
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

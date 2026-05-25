[CmdletBinding()]
param(
    [string]$SettingsPath = '',

    [string]$FeedbackDir = '',

    [switch]$Json
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

function Add-MissingProperty {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    if (-not $Target.PSObject.Properties.Item($Name)) {
        $Target | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Get-DefaultSettings {
    return [pscustomobject]@{
        version = 1
        feedbackLearning = [pscustomobject]@{
            storageDir = '.codex-tmp/voice-feedback'
            retentionDays = 30
            maxTotalStorageMb = 20
            maxRecordsPerDay = 200
            cleanupAfterSave = $true
            cleanupAfterDailyIteration = $true
        }
    }
}

function Read-Settings {
    $defaults = Get-DefaultSettings
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        $script:SettingsPath = Join-Path $projectRoot 'config\voice-feedback-settings.json'
    }

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return $defaults
    }

    try {
        $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $SettingsPath | ConvertFrom-Json
        if (-not $settings.feedbackLearning) {
            $settings | Add-Member -MemberType NoteProperty -Name feedbackLearning -Value $defaults.feedbackLearning
        }

        $learning = $settings.feedbackLearning
        foreach ($property in $defaults.feedbackLearning.PSObject.Properties) {
            Add-MissingProperty -Target $learning -Name $property.Name -Value $property.Value
        }

        return $settings
    }
    catch {
        return $defaults
    }
}

function Get-IntSetting {
    param(
        [Parameter(Mandatory = $true)]$Source,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Default,
        [Parameter(Mandatory = $true)][int]$Min,
        [Parameter(Mandatory = $true)][int]$Max
    )

    $value = $Default
    if ($Source.PSObject.Properties.Item($Name) -and $null -ne $Source.$Name) {
        try {
            $value = [int]$Source.$Name
        }
        catch {
            $value = $Default
        }
    }

    if ($value -lt $Min) {
        return $Min
    }

    if ($value -gt $Max) {
        return $Max
    }

    return $value
}

function Get-FeedbackLogFiles {
    param([Parameter(Mandatory = $true)][string]$TargetDir)

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($file in Get-ChildItem -LiteralPath $TargetDir -File -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
        if ($file.Name -notmatch '^(\d{4}-\d{2}-\d{2})\.jsonl$') {
            continue
        }

        try {
            $date = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $culture).Date
        }
        catch {
            continue
        }

        $entries.Add([pscustomobject]@{
            FullName = $file.FullName
            Name = $file.Name
            Date = $date
            Length = [int64]$file.Length
            LastWriteTime = $file.LastWriteTime
        })
    }

    return $entries.ToArray()
}

function Get-TotalBytes {
    param([object[]]$Entries)

    $total = [int64]0
    foreach ($entry in @($Entries)) {
        $total += [int64]$entry.Length
    }

    return $total
}

function Compact-JsonlFile {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][int]$MaxRecords
    )

    if ($MaxRecords -le 0 -or -not (Test-Path -LiteralPath $Entry.FullName)) {
        return $null
    }

    $lines = @(Get-Content -Encoding UTF8 -LiteralPath $Entry.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -le $MaxRecords) {
        return $null
    }

    $kept = @($lines | Select-Object -Last $MaxRecords)
    $kept | Set-Content -Encoding UTF8 -LiteralPath $Entry.FullName

    $updated = Get-Item -LiteralPath $Entry.FullName
    return [pscustomobject]@{
        path = $Entry.FullName
        reason = 'max_records_per_day'
        recordsBefore = $lines.Count
        recordsAfter = $kept.Count
        bytesBefore = [int64]$Entry.Length
        bytesAfter = [int64]$updated.Length
    }
}

$settings = Read-Settings
$learning = $settings.feedbackLearning

$retentionDays = Get-IntSetting -Source $learning -Name 'retentionDays' -Default 30 -Min 1 -Max 3650
$maxTotalStorageMb = Get-IntSetting -Source $learning -Name 'maxTotalStorageMb' -Default 20 -Min 1 -Max 1024
$maxRecordsPerDay = Get-IntSetting -Source $learning -Name 'maxRecordsPerDay' -Default 200 -Min 10 -Max 10000

$targetDir = if ([string]::IsNullOrWhiteSpace($FeedbackDir)) {
    Resolve-ProjectPath ([string]$learning.storageDir)
}
else {
    $FeedbackDir
}

$deletedFiles = New-Object System.Collections.Generic.List[object]
$compactedFiles = New-Object System.Collections.Generic.List[object]
$today = (Get-Date).Date
$cutoffDate = $today.AddDays(-($retentionDays - 1))
$maxTotalBytes = [int64]$maxTotalStorageMb * 1MB

if (-not (Test-Path -LiteralPath $targetDir)) {
    $result = [pscustomobject]@{
        cleaned = $true
        reason = 'storage_dir_missing'
        feedbackDir = $targetDir
        retentionDays = $retentionDays
        maxTotalStorageMb = $maxTotalStorageMb
        maxRecordsPerDay = $maxRecordsPerDay
        deletedFileCount = 0
        compactedFileCount = 0
        retainedLogFiles = 0
        totalBytesAfter = 0
        limitExceeded = $false
        deletedFiles = @()
        compactedFiles = @()
    }
}
else {
    $logs = @(Get-FeedbackLogFiles -TargetDir $targetDir)

    foreach ($entry in @($logs | Where-Object { $_.Date -lt $cutoffDate })) {
        Remove-Item -LiteralPath $entry.FullName -Force
        $deletedFiles.Add([pscustomobject]@{
            path = $entry.FullName
            reason = 'retention_days'
            date = $entry.Date.ToString('yyyy-MM-dd')
            bytes = [int64]$entry.Length
        })
    }

    $logs = @(Get-FeedbackLogFiles -TargetDir $targetDir)

    foreach ($entry in $logs) {
        $compactResult = Compact-JsonlFile -Entry $entry -MaxRecords $maxRecordsPerDay
        if ($null -ne $compactResult) {
            $compactedFiles.Add($compactResult)
        }
    }

    $logs = @(Get-FeedbackLogFiles -TargetDir $targetDir)
    $totalBytes = Get-TotalBytes -Entries $logs

    if ($totalBytes -gt $maxTotalBytes) {
        $capacityCandidates = @(
            $logs |
                Where-Object { $_.Date -lt $today } |
                Sort-Object Date, LastWriteTime, Name
        )

        foreach ($entry in $capacityCandidates) {
            if ($totalBytes -le $maxTotalBytes) {
                break
            }

            Remove-Item -LiteralPath $entry.FullName -Force
            $deletedFiles.Add([pscustomobject]@{
                path = $entry.FullName
                reason = 'max_total_storage_mb'
                date = $entry.Date.ToString('yyyy-MM-dd')
                bytes = [int64]$entry.Length
            })
            $totalBytes -= [int64]$entry.Length
        }
    }

    $logs = @(Get-FeedbackLogFiles -TargetDir $targetDir)
    $totalBytesAfter = Get-TotalBytes -Entries $logs

    $result = [pscustomobject]@{
        cleaned = $true
        reason = 'ok'
        feedbackDir = $targetDir
        retentionDays = $retentionDays
        maxTotalStorageMb = $maxTotalStorageMb
        maxRecordsPerDay = $maxRecordsPerDay
        deletedFileCount = $deletedFiles.Count
        compactedFileCount = $compactedFiles.Count
        retainedLogFiles = $logs.Count
        totalBytesAfter = $totalBytesAfter
        limitExceeded = ($totalBytesAfter -gt $maxTotalBytes)
        deletedFiles = $deletedFiles.ToArray()
        compactedFiles = $compactedFiles.ToArray()
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
}
else {
    Write-Output "Voice feedback cleanup: deleted $($result.deletedFileCount), compacted $($result.compactedFileCount), retained $($result.retainedLogFiles), bytes $($result.totalBytesAfter)."
}

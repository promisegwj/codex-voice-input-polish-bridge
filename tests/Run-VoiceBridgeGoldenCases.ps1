[CmdletBinding()]
param(
    [string]$CasePath = '',
    [string]$BridgeExe = '',
    [string]$DotNetPath = 'dotnet',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($CasePath)) {
    $CasePath = Join-Path $scriptRoot 'golden\voice-text-rule-cases.jsonl'
}

$casePathResolved = (Resolve-Path -LiteralPath $CasePath).Path
$bridgeProject = Join-Path $projectRoot 'tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj'
if ([string]::IsNullOrWhiteSpace($BridgeExe)) {
    $releaseExe = Join-Path $projectRoot 'tools\CodexVoicePromptBridge\bin\Release\net10.0\CodexVoicePromptBridge.exe'
    $publishedExe = Join-Path $projectRoot 'tools\CodexVoicePromptBridge\publish-self-contained\CodexVoicePromptBridge.exe'
    if (Test-Path -LiteralPath $releaseExe) {
        $BridgeExe = $releaseExe
    }
    elseif (Test-Path -LiteralPath $publishedExe) {
        $BridgeExe = $publishedExe
    }
}

function Invoke-Bridge {
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [switch]$DebugDecision
    )

    $inputFile = [System.IO.Path]::GetTempFileName()
    $outputFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($inputFile, $InputText, [System.Text.UTF8Encoding]::new($false))

        if (-not [string]::IsNullOrWhiteSpace($BridgeExe) -and (Test-Path -LiteralPath $BridgeExe)) {
            if ($DebugDecision) {
                return (& $BridgeExe --input-file $inputFile --debug-decision 2>&1 | Out-String).Trim()
            }

            & $BridgeExe --input-file $inputFile --output-file $outputFile | Out-Null
            return [System.IO.File]::ReadAllText($outputFile, [System.Text.Encoding]::UTF8)
        }

        $dotnetCommand = Get-Command $DotNetPath -ErrorAction SilentlyContinue
        if ($null -eq $dotnetCommand) {
            throw "No bridge executable found and dotnet command not found: $DotNetPath"
        }

        if ($DebugDecision) {
            return (& $DotNetPath run --project $bridgeProject -c Release -- --input-file $inputFile --debug-decision 2>&1 | Out-String).Trim()
        }

        & $DotNetPath run --project $bridgeProject -c Release -- --input-file $inputFile --output-file $outputFile | Out-Null
        return [System.IO.File]::ReadAllText($outputFile, [System.Text.Encoding]::UTF8)
    }
    finally {
        Remove-Item -LiteralPath $inputFile, $outputFile -Force -ErrorAction SilentlyContinue
    }
}

function Normalize-Comparable {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return ''
    }

    return ([regex]::Replace($Value, '\s+', '')).ToLowerInvariant()
}

function Test-ContainsRelaxed {
    param(
        [string]$Text,
        [string]$Needle
    )

    return (Normalize-Comparable $Text).Contains((Normalize-Comparable $Needle))
}

function Test-PreserveOrder {
    param(
        [string]$Text,
        [object[]]$Needles
    )

    $normalized = Normalize-Comparable $Text
    $lastIndex = -1
    foreach ($needle in $Needles) {
        $needleText = Normalize-Comparable ([string]$needle)
        $index = $normalized.IndexOf($needleText, [System.StringComparison]::Ordinal)
        if ($index -lt 0 -or $index -lt $lastIndex) {
            return $false
        }

        $lastIndex = $index
    }

    return $true
}

function Get-ListItemCount {
    param([string]$Text)
    return ([regex]::Matches($Text, '(?m)^\s*\d+[\.、．]\s*\S+')).Count
}

$results = New-Object System.Collections.Generic.List[object]
$lines = Get-Content -Encoding UTF8 -LiteralPath $casePathResolved
foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
        continue
    }

    $case = $line | ConvertFrom-Json
    $output = Invoke-Bridge -InputText ([string]$case.input)
    $decisionJson = Invoke-Bridge -InputText ([string]$case.input) -DebugDecision
    $decision = $decisionJson | ConvertFrom-Json
    $failures = New-Object System.Collections.Generic.List[string]
    $assert = $case.assert

    if ($assert.PSObject.Properties.Item('shouldList')) {
        $expectedShouldList = [bool]$assert.shouldList
        if ([bool]$decision.shouldList -ne $expectedShouldList) {
            $failures.Add("shouldList expected $expectedShouldList but got $($decision.shouldList)")
        }
    }

    if ($assert.PSObject.Properties.Item('itemCount')) {
        $expectedCount = [int]$assert.itemCount
        $actualCount = Get-ListItemCount -Text $output
        if ($actualCount -ne $expectedCount) {
            $failures.Add("itemCount expected $expectedCount but got $actualCount")
        }
    }

    if ($assert.PSObject.Properties.Item('containsAll')) {
        foreach ($needle in @($assert.containsAll)) {
            if (-not (Test-ContainsRelaxed -Text $output -Needle ([string]$needle))) {
                $failures.Add("missing text: $needle")
            }
        }
    }

    if ($assert.PSObject.Properties.Item('notContains')) {
        foreach ($needle in @($assert.notContains)) {
            if (Test-ContainsRelaxed -Text $output -Needle ([string]$needle)) {
                $failures.Add("unexpected text: $needle")
            }
        }
    }

    if ($assert.PSObject.Properties.Item('forbiddenRegex')) {
        foreach ($pattern in @($assert.forbiddenRegex)) {
            if ([regex]::IsMatch($output, [string]$pattern)) {
                $failures.Add("forbiddenRegex matched: $pattern")
            }
        }
    }

    if ($assert.PSObject.Properties.Item('mustPreserveOrder')) {
        if (-not (Test-PreserveOrder -Text $output -Needles @($assert.mustPreserveOrder))) {
            $failures.Add("order not preserved: $(@($assert.mustPreserveOrder) -join ' -> ')")
        }
    }

    if ($assert.PSObject.Properties.Item('expectedSkippedReason')) {
        $actualReason = if ($decision.PSObject.Properties.Item('pasteSkippedReason')) { [string]$decision.pasteSkippedReason } else { '' }
        if ($actualReason -ne [string]$assert.expectedSkippedReason) {
            $failures.Add("expectedSkippedReason expected $($assert.expectedSkippedReason) but got $actualReason")
        }
    }

    $results.Add([pscustomobject]@{
        id = [string]$case.id
        category = [string]$case.category
        passed = ($failures.Count -eq 0)
        failures = @($failures)
        output = $output
        decision = $decision
    })
}

$failed = @($results | Where-Object { -not $_.passed })
$summary = [pscustomobject]@{
    casePath = $casePathResolved
    total = [int]$results.Count
    passed = [int]($results.Count - $failed.Count)
    failed = [int]$failed.Count
    results = $results.ToArray()
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 12
}
else {
    foreach ($result in $results) {
        $mark = if ($result.passed) { 'PASS' } else { 'FAIL' }
        Write-Host ("[{0}] {1} - {2}" -f $mark, $result.id, $result.category)
        foreach ($failure in @($result.failures)) {
            Write-Host ("  - {0}" -f $failure)
        }
    }

    Write-Host ("Summary: {0}/{1} passed" -f $summary.passed, $summary.total)
}

if ($failed.Count -gt 0) {
    exit 1
}

[CmdletBinding()]
param(
    [int]$Port = 8793,

    [string]$WebRoot = '',

    [switch]$CopyUrl
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($WebRoot)) {
    $WebRoot = Join-Path $scriptRoot '..\web'
}

$serverScript = Join-Path $scriptRoot 'Serve-ReviewPanel.ps1'
$url = "http://127.0.0.1:$Port/"

function Test-CalibrationServer {
    try {
        $response = Invoke-WebRequest -Uri "${url}health" -UseBasicParsing -TimeoutSec 1
        if ($response.StatusCode -ne 200 -or $response.Content.Trim() -ne 'ok') {
            return $false
        }

        $featureResponse = Invoke-WebRequest `
            -Uri "${url}api/features" `
            -UseBasicParsing `
            -TimeoutSec 1

        if ($featureResponse.StatusCode -ne 200) {
            return $false
        }

        $features = $featureResponse.Content | ConvertFrom-Json
        return (
            [int]$features.version -ge 8 -and
            @($features.features) -contains 'generated-profile-polish' -and
            @($features.features) -contains 'auto-apply-codex-transcription'
        )
    }
    catch {
        return $false
    }
}

function Stop-StaleCalibrationServers {
    $serverScriptName = [System.IO.Path]::GetFileName($serverScript)
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match 'powershell' -and
            $_.CommandLine -match [regex]::Escape($serverScriptName)
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

if (-not (Test-CalibrationServer)) {
    Stop-StaleCalibrationServers
    Start-Sleep -Milliseconds 300

    $resolvedServerScript = (Resolve-Path -LiteralPath $serverScript).Path
    $resolvedWebRoot = (Resolve-Path -LiteralPath $WebRoot).Path
    $arguments = "-STA -NoProfile -ExecutionPolicy Bypass -File `"$resolvedServerScript`" -Port $Port -WebRoot `"$resolvedWebRoot`""
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arguments | Out-Null

    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-CalibrationServer) {
            break
        }

        Start-Sleep -Milliseconds 150
    }
}

if (-not (Test-CalibrationServer)) {
    throw "Calibration center did not become ready on $url."
}

if ($CopyUrl) {
    Set-Clipboard -Value $url
}

Write-Output $url

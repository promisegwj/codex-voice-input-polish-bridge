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

$script:IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

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
            [int]$features.version -ge 10 -and
            @($features.features) -contains 'generated-profile-polish' -and
            @($features.features) -contains 'auto-apply-codex-transcription' -and
            @($features.features) -contains 'platform-capabilities'
        )
    }
    catch {
        return $false
    }
}

function Stop-StaleCalibrationServers {
    if (-not $script:IsWindowsPlatform) {
        return
    }

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
    if ($script:IsWindowsPlatform) {
        $arguments = "-STA -NoProfile -ExecutionPolicy Bypass -File `"$resolvedServerScript`" -Port $Port -WebRoot `"$resolvedWebRoot`""
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arguments | Out-Null
    }
    else {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) {
            throw 'PowerShell 7 (pwsh) is required to start the macOS calibration center.'
        }

        Start-Process `
            -FilePath $pwsh.Source `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $resolvedServerScript,
                '-Port', $Port,
                '-WebRoot', $resolvedWebRoot
            ) | Out-Null
    }

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
    if ($script:IsWindowsPlatform) {
        Set-Clipboard -Value $url
    }
    else {
        $pbcopy = Get-Command pbcopy -ErrorAction SilentlyContinue
        if ($null -eq $pbcopy) {
            throw 'pbcopy was not found; cannot copy the calibration URL.'
        }

        $url | & $pbcopy.Source
    }
}

Write-Output $url

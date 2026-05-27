[CmdletBinding()]
param(
    [ValidateSet('current', 'win-x64', 'osx-x64', 'osx-arm64', 'all')]
    [string]$Runtime = 'current',

    [string]$DotnetExe = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path
$bridgeProject = Join-Path $projectRoot 'tools/CodexVoicePromptBridge/CodexVoicePromptBridge.csproj'
$publishRoot = Join-Path $projectRoot 'tools/CodexVoicePromptBridge/publish-self-contained'

function Resolve-Dotnet {
    if (-not [string]::IsNullOrWhiteSpace($DotnetExe) -and (Test-Path -LiteralPath $DotnetExe)) {
        return (Resolve-Path -LiteralPath $DotnetExe).Path
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $localWindowsDotnet = Join-Path $env:USERPROFILE 'AppData/Local/Microsoft/dotnet/dotnet.exe'
        if (Test-Path -LiteralPath $localWindowsDotnet) {
            return (Resolve-Path -LiteralPath $localWindowsDotnet).Path
        }
    }

    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnetCommand) {
        return $dotnetCommand.Source
    }

    throw 'dotnet SDK was not found. Install .NET SDK 10 or pass -DotnetExe.'
}

function Resolve-CurrentRuntime {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $suffix = if ($arch -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'x64' }

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return "win-$suffix"
    }

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        return "osx-$suffix"
    }

    throw 'Only Windows and macOS publish targets are supported by this project.'
}

$dotnet = Resolve-Dotnet
$runtimes = switch ($Runtime) {
    'current' { @(Resolve-CurrentRuntime) }
    'all' { @('win-x64', 'osx-x64', 'osx-arm64') }
    default { @($Runtime) }
}

foreach ($rid in $runtimes) {
    $outputDir = if ($runtimes.Count -eq 1) {
        $publishRoot
    }
    else {
        Join-Path $publishRoot $rid
    }

    & $dotnet publish $bridgeProject `
        -c Release `
        -r $rid `
        --self-contained true `
        -p:PublishSingleFile=true `
        -o $outputDir

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for $rid."
    }

    Write-Output "Published CodexVoicePromptBridge for $rid to $outputDir"
}

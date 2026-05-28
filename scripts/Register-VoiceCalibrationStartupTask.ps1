[CmdletBinding()]
param(
    [ValidateSet('status', 'enable', 'disable')]
    [string]$Action = 'status',

    [string]$TaskName = 'Codex Voice Calibration Center Startup',

    [int]$Port = 8793,

    [string]$WebRoot = ''
)

$ErrorActionPreference = 'Stop'

$isWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
if (-not $isWindowsPlatform) {
    [pscustomobject]@{
        supported = $false
        platform = 'non-windows'
        taskName = $TaskName
        registered = $false
        enabled = $false
        state = 'unsupported'
        message = 'Startup registration is currently implemented for Windows sign-in only.'
    } | ConvertTo-Json -Depth 5
    return
}

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path
$openScript = (Resolve-Path -LiteralPath (Join-Path $scriptRoot 'Open-VoiceCalibrationCenter.ps1')).Path
$startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$shortcutPath = Join-Path $startupFolder "$TaskName.lnk"

function Get-OpenScriptArguments {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$openScript`"",
        '-Port', $Port
    )

    if (-not [string]::IsNullOrWhiteSpace($WebRoot)) {
        $resolvedWebRoot = (Resolve-Path -LiteralPath $WebRoot).Path
        $arguments += @('-WebRoot', "`"$resolvedWebRoot`"")
    }

    return $arguments
}

function New-StartupShortcut {
    if (-not (Test-Path -LiteralPath $startupFolder)) {
        New-Item -ItemType Directory -Path $startupFolder | Out-Null
    }

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath)) {
        $powerShellPath = 'powershell.exe'
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = (Get-OpenScriptArguments) -join ' '
    $shortcut.WorkingDirectory = $projectRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Start the local Codex voice calibration center after Windows sign-in.'
    $shortcut.Save()
}

function Remove-StartupShortcut {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}

function Get-StartupTaskStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Message = ''
    )

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    }
    catch {
        $task = $null
    }

    $hasShortcut = Test-Path -LiteralPath $shortcutPath
    if ($null -eq $task) {
        if ($hasShortcut) {
            return [pscustomobject]@{
                supported = $true
                platform = 'windows'
                taskName = $Name
                registered = $true
                enabled = $true
                state = 'startup-shortcut'
                trigger = 'StartupFolder'
                startupKind = 'startup-folder-shortcut'
                shortcutPath = $shortcutPath
                message = if ([string]::IsNullOrWhiteSpace($Message)) { 'Startup folder shortcut is registered.' } else { $Message }
            }
        }

        return [pscustomobject]@{
            supported = $true
            platform = 'windows'
            taskName = $Name
            registered = $false
            enabled = $false
            state = 'not-registered'
            trigger = 'AtLogOn'
            startupKind = 'none'
            message = if ([string]::IsNullOrWhiteSpace($Message)) { 'Startup task is not registered.' } else { $Message }
        }
    }

    $info = $null
    try {
        $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
    }
    catch {
        $info = $null
    }

    $state = if ($null -ne $task.State) { [string]$task.State } else { 'unknown' }
    $enabled = $true
    if ($task.Settings -and $null -ne $task.Settings.Enabled) {
        $enabled = [bool]$task.Settings.Enabled
    }

    return [pscustomobject]@{
        supported = $true
        platform = 'windows'
        taskName = $Name
        registered = $true
        enabled = $enabled
        state = $state
        trigger = 'AtLogOn'
        startupKind = 'scheduled-task'
        shortcutPath = if ($hasShortcut) { $shortcutPath } else { '' }
        lastRunTime = if ($info) { $info.LastRunTime.ToString('o') } else { '' }
        nextRunTime = if ($info) { $info.NextRunTime.ToString('o') } else { '' }
        message = if ([string]::IsNullOrWhiteSpace($Message)) { 'Startup task is registered.' } else { $Message }
    }
}

if ($Action -eq 'enable') {
    try {
        $actionDefinition = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument ((Get-OpenScriptArguments) -join ' ') `
            -WorkingDirectory $projectRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $actionDefinition `
            -Trigger $trigger `
            -Settings $settings `
            -Description 'Start the local Codex voice calibration center after Windows sign-in.' `
            -Force | Out-Null

        Remove-StartupShortcut

        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        }
        catch {
            # The task is registered; starting it immediately is a best-effort convenience.
        }

        Get-StartupTaskStatus -Name $TaskName -Message 'Startup task is registered and will run at Windows sign-in.' |
            ConvertTo-Json -Depth 5
    }
    catch {
        New-StartupShortcut
        Get-StartupTaskStatus -Name $TaskName -Message "Task Scheduler registration was blocked; startup folder shortcut was created instead. $($_.Exception.Message)" |
            ConvertTo-Json -Depth 5
    }

    return
}

if ($Action -eq 'disable') {
    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    catch {
        $task = $null
    }

    if ($null -ne $task) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
        catch {
            # A startup folder shortcut can still be removed even if Task Scheduler is blocked.
        }
    }

    Remove-StartupShortcut

    Get-StartupTaskStatus -Name $TaskName -Message 'Startup task has been removed.' |
        ConvertTo-Json -Depth 5
    return
}

Get-StartupTaskStatus -Name $TaskName | ConvertTo-Json -Depth 5

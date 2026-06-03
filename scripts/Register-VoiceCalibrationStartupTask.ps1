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
        startupMode = 'unsupported'
        watchedProcess = 'Codex.exe'
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
$watcherScript = (Resolve-Path -LiteralPath (Join-Path $scriptRoot 'Start-CodexVoiceCalibrationWatcher.ps1')).Path
$startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$shortcutPath = Join-Path $startupFolder "$TaskName.lnk"

function Get-StartupProcessArguments {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$watcherScript`"",
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
    $shortcut.Arguments = (Get-StartupProcessArguments) -join ' '
    $shortcut.WorkingDirectory = $projectRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Watch for Codex and start the local voice calibration center.'
    $shortcut.Save()
}

function Remove-StartupShortcut {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
}

function Start-StartupProcessBestEffort {
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath)) {
        $powerShellPath = 'powershell.exe'
    }

    try {
        Start-Process `
            -FilePath $powerShellPath `
            -WindowStyle Hidden `
            -ArgumentList ((Get-StartupProcessArguments) -join ' ') `
            -WorkingDirectory $projectRoot | Out-Null
    }
    catch {
        # Registration can still be valid even if the immediate best-effort start fails.
    }
}

function Get-StartupTaskStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Message = ''
    )

    $hasShortcut = Test-Path -LiteralPath $shortcutPath
    $shortcutStartupMode = ''
    if ($hasShortcut) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcutStartupMode = if ($shortcut.Arguments -match [regex]::Escape([System.IO.Path]::GetFileName($watcherScript))) {
                'codex-process-watcher'
            }
            else {
                'legacy-direct-service-start'
            }
        }
        catch {
            $shortcutStartupMode = 'unknown'
        }
    }

    if ($hasShortcut) {
        $defaultShortcutMessage = if ($shortcutStartupMode -eq 'codex-process-watcher') {
            'Codex process watcher shortcut is registered.'
        }
        else {
            'Legacy startup shortcut is registered; enable again to migrate to the Codex process watcher.'
        }

        return [pscustomobject]@{
            supported = $true
            platform = 'windows'
            taskName = $Name
            registered = $true
            enabled = $true
            state = 'startup-shortcut'
            trigger = 'StartupFolder'
            startupKind = 'startup-folder-shortcut'
            startupMode = $shortcutStartupMode
            watchedProcess = 'Codex.exe'
            shortcutPath = $shortcutPath
            message = if ([string]::IsNullOrWhiteSpace($Message)) { $defaultShortcutMessage } else { $Message }
        }
    }

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    }
    catch {
        $task = $null
    }

    if ($null -eq $task) {
        return [pscustomobject]@{
            supported = $true
            platform = 'windows'
            taskName = $Name
            registered = $false
            enabled = $false
            state = 'not-registered'
            trigger = 'AtLogOn'
            startupKind = 'none'
            startupMode = 'none'
            watchedProcess = 'Codex.exe'
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

    $taskStartupMode = 'unknown'
    try {
        $taskArguments = @($task.Actions | ForEach-Object { $_.Arguments }) -join ' '
        $taskStartupMode = if ($taskArguments -match [regex]::Escape([System.IO.Path]::GetFileName($watcherScript))) {
            'codex-process-watcher'
        }
        else {
            'legacy-direct-service-start'
        }
    }
    catch {
        $taskStartupMode = 'unknown'
    }

    $defaultTaskMessage = if ($taskStartupMode -eq 'codex-process-watcher') {
        'Codex process watcher task is registered.'
    }
    else {
        'Legacy startup task is registered; enable again to migrate to the Codex process watcher.'
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
        startupMode = $taskStartupMode
        watchedProcess = 'Codex.exe'
        shortcutPath = if ($hasShortcut) { $shortcutPath } else { '' }
        lastRunTime = if ($info) { $info.LastRunTime.ToString('o') } else { '' }
        nextRunTime = if ($info) { $info.NextRunTime.ToString('o') } else { '' }
        message = if ([string]::IsNullOrWhiteSpace($Message)) { $defaultTaskMessage } else { $Message }
    }
}

if ($Action -eq 'enable') {
    try {
        $actionDefinition = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument ((Get-StartupProcessArguments) -join ' ') `
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
            -Description 'Watch for Codex and start the local voice calibration center.' `
            -Force | Out-Null

        Remove-StartupShortcut

        try {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        }
        catch {
            # The task is registered; starting it immediately is a best-effort convenience.
            Start-StartupProcessBestEffort
        }

        Get-StartupTaskStatus -Name $TaskName -Message 'Codex process watcher is registered and will run at Windows sign-in.' |
            ConvertTo-Json -Depth 5
    }
    catch {
        New-StartupShortcut
        Start-StartupProcessBestEffort
        Get-StartupTaskStatus -Name $TaskName -Message "Task Scheduler registration was blocked; startup folder watcher shortcut was created instead. $($_.Exception.Message)" |
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

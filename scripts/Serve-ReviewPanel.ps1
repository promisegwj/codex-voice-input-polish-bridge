[CmdletBinding()]
param(
    [int]$Port = 8793,

    [string]$WebRoot = '',

    [string]$SettingsPath = '',

    [string]$FeedbackDir = '',

    [string]$TranscriptionHistoryPath = '',

    [string]$CodexSessionsRoot = '',

    [int]$MaxTranscriptionAgeSeconds = 900
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

$script:IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$script:IsMacOSPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)

function Get-UserHomePath {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return $env:USERPROFILE
    }

    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        return $env:HOME
    }

    return [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}

if ([string]::IsNullOrWhiteSpace($WebRoot)) {
    $WebRoot = Join-Path $scriptRoot '..\web'
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path
$resolvedWebRoot = (Resolve-Path -LiteralPath $WebRoot).Path
$startupTaskScript = Join-Path $scriptRoot 'Register-VoiceCalibrationStartupTask.ps1'

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $projectRoot 'config\voice-feedback-settings.json'
}

if ([string]::IsNullOrWhiteSpace($TranscriptionHistoryPath)) {
    $TranscriptionHistoryPath = Join-Path (Get-UserHomePath) '.codex/transcription-history.jsonl'
}

if ([string]::IsNullOrWhiteSpace($CodexSessionsRoot)) {
    $CodexSessionsRoot = Join-Path (Get-UserHomePath) '.codex/sessions'
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

$script:LastPasteTarget = $null
$script:LastFeedbackDailyCheckAt = [datetime]::MinValue

function Ensure-FocusNativeMethods {
    if (-not $script:IsWindowsPlatform) {
        throw 'Windows focus native methods are only available on Windows.'
    }

    if ('CodexVoiceFocus.NativeMethods' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexVoiceFocus
{
    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextLengthW(IntPtr hWnd);
    }
}
'@
}

function Get-WindowTitle {
    param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)

    if (-not $script:IsWindowsPlatform) {
        return ''
    }

    Ensure-FocusNativeMethods
    $length = [CodexVoiceFocus.NativeMethods]::GetWindowTextLengthW($Hwnd)
    if ($length -le 0) {
        return ''
    }

    $builder = [System.Text.StringBuilder]::new($length + 1)
    $result = [CodexVoiceFocus.NativeMethods]::GetWindowTextW($Hwnd, $builder, $builder.Capacity)
    if ($result -le 0) {
        return ''
    }

    return $builder.ToString()
}

function Capture-PasteTarget {
    param([string]$Reason = 'manual')

    if ($script:IsMacOSPlatform) {
        $frontApp = ''
        $frontTitle = ''
        $osascript = Get-Command osascript -ErrorAction SilentlyContinue
        if ($null -ne $osascript) {
            try {
                $frontApp = (& $osascript.Source -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>$null | Out-String).Trim()
                $frontTitle = (& $osascript.Source -e 'tell application "System Events" to get name of front window of first application process whose frontmost is true' 2>$null | Out-String).Trim()
            }
            catch {
                $frontApp = ''
                $frontTitle = ''
            }
        }

        $target = [pscustomobject]@{
            hwnd = 0
            processId = 0
            processName = $frontApp
            title = $frontTitle
            platform = 'macos'
            capturedAt = (Get-Date).ToString('o')
            reason = $Reason
        }

        $script:LastPasteTarget = $target
        return $target
    }

    if (-not $script:IsWindowsPlatform) {
        return $null
    }

    Ensure-FocusNativeMethods
    $hwnd = [CodexVoiceFocus.NativeMethods]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) {
        return $null
    }

    $processId = [uint32]0
    [void][CodexVoiceFocus.NativeMethods]::GetWindowThreadProcessId($hwnd, [ref]$processId)

    $processName = ''
    if ($processId -gt 0) {
        try {
            $processName = (Get-Process -Id ([int]$processId) -ErrorAction Stop).ProcessName
        }
        catch {
            $processName = ''
        }
    }

    $target = [pscustomobject]@{
        hwnd = $hwnd.ToInt64()
        processId = [int64]$processId
        processName = $processName
        title = Get-WindowTitle -Hwnd $hwnd
        platform = 'windows'
        capturedAt = (Get-Date).ToString('o')
        reason = $Reason
    }

    $script:LastPasteTarget = $target
    return $target
}

function Get-PasteTargetSnapshot {
    if ($null -eq $script:LastPasteTarget) {
        return $null
    }

    return [pscustomobject]@{
        hwnd = $script:LastPasteTarget.hwnd
        processId = $script:LastPasteTarget.processId
        processName = $script:LastPasteTarget.processName
        title = $script:LastPasteTarget.title
        platform = if ($script:LastPasteTarget.PSObject.Properties.Item('platform')) { [string]$script:LastPasteTarget.platform } else { if ($script:IsMacOSPlatform) { 'macos' } elseif ($script:IsWindowsPlatform) { 'windows' } else { 'unknown' } }
        capturedAt = $script:LastPasteTarget.capturedAt
        reason = $script:LastPasteTarget.reason
    }
}

function Send-TextResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-JsonResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Value,
        [int]$StatusCode = 200
    )

    $json = $Value | ConvertTo-Json -Depth 10
    Send-TextResponse -Response $Response -Text $json -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Read-RequestBody {
    param([Parameter(Mandatory = $true)]$Request)

    $reader = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

function Resolve-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return (Join-Path $projectRoot $PathValue)
}

function Invoke-StartupTaskScript {
    param(
        [ValidateSet('status', 'enable', 'disable')]
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    if (-not (Test-Path -LiteralPath $startupTaskScript)) {
        return [pscustomobject]@{
            supported = $false
            platform = if ($script:IsWindowsPlatform) { 'windows' } elseif ($script:IsMacOSPlatform) { 'macos' } else { 'unknown' }
            taskName = 'Codex Voice Calibration Center Startup'
            registered = $false
            enabled = $false
            state = 'script-missing'
            message = 'Startup task script was not found.'
        }
    }

    $output = & $startupTaskScript -Action $Action -Port $Port -WebRoot $resolvedWebRoot
    $json = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'Startup task script returned no status.'
    }

    return ($json | ConvertFrom-Json)
}

function Get-StartupTaskStatus {
    try {
        return Invoke-StartupTaskScript -Action 'status'
    }
    catch {
        return [pscustomobject]@{
            supported = $script:IsWindowsPlatform
            platform = if ($script:IsWindowsPlatform) { 'windows' } elseif ($script:IsMacOSPlatform) { 'macos' } else { 'unknown' }
            taskName = 'Codex Voice Calibration Center Startup'
            registered = $false
            enabled = $false
            state = 'status-error'
            message = $_.Exception.Message
        }
    }
}

function Set-StartupTaskEnabled {
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    if ($Enabled) {
        return Invoke-StartupTaskScript -Action 'enable'
    }

    return Invoke-StartupTaskScript -Action 'disable'
}

function Get-FeedbackStorageDir {
    param([Parameter(Mandatory = $true)]$Settings)

    $storagePath = if ($Settings.feedbackLearning -and $Settings.feedbackLearning.storageDir) {
        [string]$Settings.feedbackLearning.storageDir
    }
    else {
        '.codex-tmp/voice-feedback'
    }

    return Resolve-ProjectPath $storagePath
}

function Get-FeedbackIterationStatePath {
    param([Parameter(Mandatory = $true)]$Settings)

    $profilePath = if ($Settings.feedbackLearning -and $Settings.feedbackLearning.generatedProfilePath) {
        Resolve-ProjectPath ([string]$Settings.feedbackLearning.generatedProfilePath)
    }
    else {
        Resolve-ProjectPath '.codex-tmp/voice-feedback/generated/voice-feedback-learning.generated.json'
    }

    return (Join-Path (Split-Path -Parent $profilePath) 'daily-iteration-state.json')
}

function Read-FeedbackIterationState {
    param([Parameter(Mandatory = $true)]$Settings)

    $statePath = Get-FeedbackIterationStatePath -Settings $Settings
    if (-not (Test-Path -LiteralPath $statePath)) {
        return [pscustomobject]@{}
    }

    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{}
    }
}

function Write-FeedbackIterationState {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)]$State
    )

    $statePath = Get-FeedbackIterationStatePath -Settings $Settings
    $stateParent = Split-Path -Parent $statePath
    if (-not [string]::IsNullOrWhiteSpace($stateParent) -and -not (Test-Path -LiteralPath $stateParent)) {
        New-Item -ItemType Directory -Path $stateParent | Out-Null
    }

    $State | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $statePath
}

function Get-LatestFeedbackLogDate {
    param([Parameter(Mandatory = $true)]$Settings)

    $feedbackRoot = Get-FeedbackStorageDir -Settings $Settings
    if (-not (Test-Path -LiteralPath $feedbackRoot)) {
        return ''
    }

    $today = (Get-Date).Date
    $dates = @(
        Get-ChildItem -LiteralPath $feedbackRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParseExact(
                    $_.BaseName,
                    'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$parsed
                ) -and $parsed.Date -le $today) {
                    $parsed.Date
                }
            } |
            Sort-Object -Descending
    )

    if ($dates.Count -eq 0) {
        return ''
    }

    return $dates[0].ToString('yyyy-MM-dd')
}

function Get-DefaultSettings {
    return [pscustomobject]@{
        version = 1
        feedbackLearning = [pscustomobject]@{
            enabled = $false
            captureOnlyWhenWebReviewSaves = $true
            dailyIterationTime = '00:00'
            storageDir = '.codex-tmp/voice-feedback'
            generatedProfilePath = '.codex-tmp/voice-feedback/generated/voice-feedback-learning.generated.json'
            maxTextLength = 4000
            retentionDays = 30
            maxTotalStorageMb = 20
            maxRecordsPerDay = 200
            cleanupAfterSave = $true
            cleanupAfterDailyIteration = $true
            allowKeyboardMouseMonitoring = $false
        }
        fixedEntry = [pscustomobject]@{
            enabled = $true
            url = "http://127.0.0.1:$Port/"
            autoStartWithCodex = $false
        }
        activeCalibration = [pscustomobject]@{
            voiceHotkey = '^+d'
            voiceHotkeyLabel = 'Ctrl+Shift+D'
            autoImportDelaySeconds = 8
            pasteDelaySeconds = 0
            autoApplyEnabled = $false
            autoApplyPollMilliseconds = 500
            sentTextMonitorEnabled = $false
            sentTextMonitorDurationSeconds = 60
            sentTextMonitorPollSeconds = 3
            sentTextMonitorMinScore = 70
            macOsBestEffortPasteEnabled = $false
            defaultRewriteRule = '先判断原始口述的真实意图和任务边界；保留事实、否定、时间、数字、路径、文件名、专有名词和条件，不新增原文没有的信息。删除不承载意义的口头禅、重复句、犹豫词和自我打断；对“不是 A，是 B”“不对，改成 B”以后者为准。将“你能不能/是不是可以”改为直接可执行请求，但真正的可行性询问要保留为问题。多件事按 1、2、3 拆分，每项写成“动作 + 对象 + 验证/交付要求”。长句按意图断句，使用规范中文标点；保留必要的语气和不确定性，关键歧义标为“需确认”。结合上下文纠正常见同音字、近音词和技术/对象名称，如 GitHub、网页、文件名和链接；但禁止把单字、短英文碎片、URL、线程链接或文件名当作跨场景全局替换。用户后补的链接、文件名、标题只在本次文本中明确出现时保留，不从历史样本自动补入。删除口头衔接和误触发短句时，必须确认它不承载范围、排除、条件或对象关系；与事实保留规则冲突时，以保留事实和边界为准。输出应简洁、清楚、可执行，适合直接发给 Codex；不要额外添加固定标题。'
        }
    }
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return Get-DefaultSettings
    }

    try {
        $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $SettingsPath | ConvertFrom-Json
        $defaults = Get-DefaultSettings

        if (-not $settings.feedbackLearning) {
            $settings | Add-Member -MemberType NoteProperty -Name feedbackLearning -Value $defaults.feedbackLearning
        }

        foreach ($property in $defaults.feedbackLearning.PSObject.Properties) {
            if (-not $settings.feedbackLearning.PSObject.Properties.Item($property.Name)) {
                $settings.feedbackLearning | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
            }
        }

        if (-not $settings.fixedEntry) {
            $settings | Add-Member -MemberType NoteProperty -Name fixedEntry -Value $defaults.fixedEntry
        }

        if (-not $settings.activeCalibration) {
            $settings | Add-Member -MemberType NoteProperty -Name activeCalibration -Value $defaults.activeCalibration
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('defaultRewriteRule')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name defaultRewriteRule -Value $defaults.activeCalibration.defaultRewriteRule
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('voiceHotkey')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name voiceHotkey -Value $defaults.activeCalibration.voiceHotkey
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('voiceHotkeyLabel')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name voiceHotkeyLabel -Value $defaults.activeCalibration.voiceHotkeyLabel
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('autoImportDelaySeconds')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name autoImportDelaySeconds -Value $defaults.activeCalibration.autoImportDelaySeconds
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('pasteDelaySeconds')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name pasteDelaySeconds -Value $defaults.activeCalibration.pasteDelaySeconds
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('autoApplyEnabled')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name autoApplyEnabled -Value $defaults.activeCalibration.autoApplyEnabled
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('autoApplyPollMilliseconds')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name autoApplyPollMilliseconds -Value $defaults.activeCalibration.autoApplyPollMilliseconds
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('sentTextMonitorEnabled')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name sentTextMonitorEnabled -Value $defaults.activeCalibration.sentTextMonitorEnabled
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('sentTextMonitorDurationSeconds')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name sentTextMonitorDurationSeconds -Value $defaults.activeCalibration.sentTextMonitorDurationSeconds
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('sentTextMonitorPollSeconds')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name sentTextMonitorPollSeconds -Value $defaults.activeCalibration.sentTextMonitorPollSeconds
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('sentTextMonitorMinScore')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name sentTextMonitorMinScore -Value $defaults.activeCalibration.sentTextMonitorMinScore
        }

        if (-not $settings.activeCalibration.PSObject.Properties.Item('macOsBestEffortPasteEnabled')) {
            $settings.activeCalibration | Add-Member -MemberType NoteProperty -Name macOsBestEffortPasteEnabled -Value $defaults.activeCalibration.macOsBestEffortPasteEnabled
        }

        return $settings
    }
    catch {
        return Get-DefaultSettings
    }
}

function Save-Settings {
    param([Parameter(Mandatory = $true)]$Settings)

    $parent = Split-Path -Parent $SettingsPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    $Settings | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath $SettingsPath
}

function Get-SettingsResponse {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        $StartupTaskStatus = $null
    )

    if ($null -eq $StartupTaskStatus) {
        $StartupTaskStatus = Get-StartupTaskStatus
    }

    $fixedEntry = $Settings.fixedEntry
    $autoStartWithCodex = [bool]$fixedEntry.autoStartWithCodex
    if ($StartupTaskStatus.supported -and $StartupTaskStatus.PSObject.Properties.Item('enabled')) {
        $autoStartWithCodex = [bool]$StartupTaskStatus.enabled
    }

    return [pscustomobject]@{
        version = $Settings.version
        feedbackLearning = $Settings.feedbackLearning
        fixedEntry = [pscustomobject]@{
            enabled = [bool]$fixedEntry.enabled
            url = [string]$fixedEntry.url
            autoStartWithCodex = $autoStartWithCodex
            startupTask = $StartupTaskStatus
        }
        activeCalibration = $Settings.activeCalibration
    }
}

function Get-ClampedInt {
    param(
        [object]$Value,
        [int]$Default,
        [int]$Min,
        [int]$Max
    )

    $parsed = $Default
    if ($null -ne $Value) {
        try {
            $parsed = [int]$Value
        }
        catch {
            $parsed = $Default
        }
    }

    if ($parsed -lt $Min) {
        return $Min
    }

    if ($parsed -gt $Max) {
        return $Max
    }

    return $parsed
}

function Merge-Settings {
    param([Parameter(Mandatory = $true)]$Incoming)

    $settings = Read-Settings
    $learning = $settings.feedbackLearning
    $fixedEntry = $settings.fixedEntry
    $activeCalibration = $settings.activeCalibration
    $requestedAutoStartWithCodex = $null
    $startupTaskStatus = $null

    if ($Incoming.feedbackLearning) {
        if ($null -ne $Incoming.feedbackLearning.enabled) {
            $learning.enabled = [bool]$Incoming.feedbackLearning.enabled
        }

        if ($Incoming.feedbackLearning.dailyIterationTime -match '^\d{2}:\d{2}$') {
            $learning.dailyIterationTime = [string]$Incoming.feedbackLearning.dailyIterationTime
        }

        if ($null -ne $Incoming.feedbackLearning.retentionDays) {
            $learning.retentionDays = Get-ClampedInt -Value $Incoming.feedbackLearning.retentionDays -Default 30 -Min 1 -Max 3650
        }

        if ($null -ne $Incoming.feedbackLearning.maxTotalStorageMb) {
            $learning.maxTotalStorageMb = Get-ClampedInt -Value $Incoming.feedbackLearning.maxTotalStorageMb -Default 20 -Min 1 -Max 1024
        }

        if ($null -ne $Incoming.feedbackLearning.maxRecordsPerDay) {
            $learning.maxRecordsPerDay = Get-ClampedInt -Value $Incoming.feedbackLearning.maxRecordsPerDay -Default 200 -Min 10 -Max 10000
        }
    }

    $learning.captureOnlyWhenWebReviewSaves = $true
    $learning.cleanupAfterSave = $true
    $learning.cleanupAfterDailyIteration = $true
    $learning.allowKeyboardMouseMonitoring = $false

    if ($Incoming.fixedEntry) {
        if ($null -ne $Incoming.fixedEntry.enabled) {
            $fixedEntry.enabled = [bool]$Incoming.fixedEntry.enabled
        }

        if ($null -ne $Incoming.fixedEntry.autoStartWithCodex) {
            $requestedAutoStartWithCodex = [bool]$Incoming.fixedEntry.autoStartWithCodex
        }
    }

    $fixedEntry.url = "http://127.0.0.1:$Port/"

    if ($Incoming.activeCalibration) {
        if ($null -ne $Incoming.activeCalibration.defaultRewriteRule) {
            $activeCalibration.defaultRewriteRule = Limit-Text -Value $Incoming.activeCalibration.defaultRewriteRule -MaxLength 1000
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$Incoming.activeCalibration.voiceHotkey)) {
            $activeCalibration.voiceHotkey = [string]$Incoming.activeCalibration.voiceHotkey
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$Incoming.activeCalibration.voiceHotkeyLabel)) {
            $activeCalibration.voiceHotkeyLabel = [string]$Incoming.activeCalibration.voiceHotkeyLabel
        }

        if ($null -ne $Incoming.activeCalibration.autoImportDelaySeconds) {
            $delaySeconds = [int]$Incoming.activeCalibration.autoImportDelaySeconds
            if ($delaySeconds -lt 2) {
                $delaySeconds = 2
            }
            elseif ($delaySeconds -gt 60) {
                $delaySeconds = 60
            }

            $activeCalibration.autoImportDelaySeconds = $delaySeconds
        }

        if ($null -ne $Incoming.activeCalibration.pasteDelaySeconds) {
            $pasteDelaySeconds = [int]$Incoming.activeCalibration.pasteDelaySeconds
            if ($pasteDelaySeconds -lt 0) {
                $pasteDelaySeconds = 0
            }
            elseif ($pasteDelaySeconds -gt 10) {
                $pasteDelaySeconds = 10
            }

            $activeCalibration.pasteDelaySeconds = $pasteDelaySeconds
        }

        if ($null -ne $Incoming.activeCalibration.autoApplyEnabled) {
            $activeCalibration.autoApplyEnabled = [bool]$Incoming.activeCalibration.autoApplyEnabled
        }

        if ($null -ne $Incoming.activeCalibration.autoApplyPollMilliseconds) {
            $pollMilliseconds = [int]$Incoming.activeCalibration.autoApplyPollMilliseconds
            if ($pollMilliseconds -lt 500) {
                $pollMilliseconds = 500
            }
            elseif ($pollMilliseconds -gt 5000) {
                $pollMilliseconds = 5000
            }

            $activeCalibration.autoApplyPollMilliseconds = $pollMilliseconds
        }

        if ($null -ne $Incoming.activeCalibration.sentTextMonitorEnabled) {
            $activeCalibration.sentTextMonitorEnabled = [bool]$Incoming.activeCalibration.sentTextMonitorEnabled
        }

        if ($null -ne $Incoming.activeCalibration.sentTextMonitorDurationSeconds) {
            $durationSeconds = [int]$Incoming.activeCalibration.sentTextMonitorDurationSeconds
            if ($durationSeconds -lt 10) {
                $durationSeconds = 10
            }
            elseif ($durationSeconds -gt 180) {
                $durationSeconds = 180
            }

            $activeCalibration.sentTextMonitorDurationSeconds = $durationSeconds
        }

        if ($null -ne $Incoming.activeCalibration.sentTextMonitorPollSeconds) {
            $pollSeconds = [int]$Incoming.activeCalibration.sentTextMonitorPollSeconds
            if ($pollSeconds -lt 1) {
                $pollSeconds = 1
            }
            elseif ($pollSeconds -gt 10) {
                $pollSeconds = 10
            }

            $activeCalibration.sentTextMonitorPollSeconds = $pollSeconds
        }

        if ($null -ne $Incoming.activeCalibration.sentTextMonitorMinScore) {
            $minScore = [int]$Incoming.activeCalibration.sentTextMonitorMinScore
            if ($minScore -lt 50) {
                $minScore = 50
            }
            elseif ($minScore -gt 100) {
                $minScore = 100
            }

            $activeCalibration.sentTextMonitorMinScore = $minScore
        }

        if ($null -ne $Incoming.activeCalibration.macOsBestEffortPasteEnabled) {
            $activeCalibration.macOsBestEffortPasteEnabled = [bool]$Incoming.activeCalibration.macOsBestEffortPasteEnabled
        }
    }

    if ($null -ne $requestedAutoStartWithCodex) {
        $startupTaskStatus = Set-StartupTaskEnabled -Enabled $requestedAutoStartWithCodex
        $fixedEntry.autoStartWithCodex = if ($startupTaskStatus.supported -and $startupTaskStatus.PSObject.Properties.Item('enabled')) {
            [bool]$startupTaskStatus.enabled
        }
        else {
            $false
        }
    }
    elseif ([bool]$fixedEntry.autoStartWithCodex) {
        $startupTaskStatus = Get-StartupTaskStatus
        if ($startupTaskStatus.supported -and $startupTaskStatus.PSObject.Properties.Item('enabled')) {
            $fixedEntry.autoStartWithCodex = [bool]$startupTaskStatus.enabled
        }
    }

    Save-Settings -Settings $settings
    return Get-SettingsResponse -Settings $settings -StartupTaskStatus $startupTaskStatus
}

function Limit-Text {
    param(
        [object]$Value,
        [int]$MaxLength
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($text.Length -le $MaxLength) {
        return $text
    }

    return $text.Substring(0, $MaxLength)
}

function Read-LatestCodexTranscription {
    param(
        [int64]$AfterCreatedAtMs = 0,
        [int]$MaxAgeSeconds = $MaxTranscriptionAgeSeconds
    )

    if (-not (Test-Path -LiteralPath $TranscriptionHistoryPath)) {
        return [pscustomobject]@{
            found = $false
            reason = 'history_file_missing'
            text = ''
            length = 0
            historyPath = $TranscriptionHistoryPath
            source = 'codex_transcription_history'
        }
    }

    $latest = $null
    foreach ($line in Get-Content -LiteralPath $TranscriptionHistoryPath -Encoding UTF8 -Tail 100) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        $text = if ($record.PSObject.Properties.Item('text')) { [string]$record.text } else { '' }
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $createdAtMs = if ($record.PSObject.Properties.Item('createdAtMs')) { [int64]$record.createdAtMs } else { 0 }
        if ($AfterCreatedAtMs -gt 0 -and $createdAtMs -le $AfterCreatedAtMs) {
            continue
        }

        if ($null -eq $latest -or $createdAtMs -gt [int64]$latest.createdAtMs) {
            $latest = [pscustomobject]@{
                id = if ($record.PSObject.Properties.Item('id')) { [string]$record.id } else { '' }
                createdAtMs = $createdAtMs
                text = $text
            }
        }
    }

    if ($null -eq $latest) {
        return [pscustomobject]@{
            found = $false
            reason = if ($AfterCreatedAtMs -gt 0) { 'no_new_transcription' } else { 'no_transcription_text' }
            text = ''
            length = 0
            afterCreatedAtMs = $AfterCreatedAtMs
            historyPath = $TranscriptionHistoryPath
            source = 'codex_transcription_history'
        }
    }

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $ageSeconds = if ($latest.createdAtMs -gt 0) {
        [int][Math]::Max(0, [Math]::Floor(($nowMs - $latest.createdAtMs) / 1000))
    }
    else {
        -1
    }

    $createdAtLocal = if ($latest.createdAtMs -gt 0) {
        [DateTimeOffset]::FromUnixTimeMilliseconds($latest.createdAtMs).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
    else {
        ''
    }

    $pasteTarget = if (-not ($MaxAgeSeconds -gt 0 -and $ageSeconds -gt $MaxAgeSeconds)) {
        Capture-PasteTarget -Reason 'latest_codex_transcription'
    }
    else {
        Get-PasteTargetSnapshot
    }

    return [pscustomobject]@{
        found = $true
        stale = ($MaxAgeSeconds -gt 0 -and $ageSeconds -gt $MaxAgeSeconds)
        text = Limit-Text -Value $latest.text -MaxLength 4000
        length = ([string]$latest.text).Length
        id = $latest.id
        createdAtMs = $latest.createdAtMs
        createdAtLocal = $createdAtLocal
        ageSeconds = $ageSeconds
        maxAgeSeconds = $MaxAgeSeconds
        afterCreatedAtMs = $AfterCreatedAtMs
        historyPath = $TranscriptionHistoryPath
        source = 'codex_transcription_history'
        monitoring = $false
        pasteTarget = $pasteTarget
    }
}

function Get-ComparableText {
    param([object]$Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $text = $text.Trim().ToLowerInvariant()
    return [System.Text.RegularExpressions.Regex]::Replace($text, '[^\p{L}\p{Nd}]', '')
}

function Get-TextTokenSet {
    param([string]$Text)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $set
    }

    if ($Text.Length -eq 1) {
        [void]$set.Add($Text)
        return $set
    }

    for ($i = 0; $i -lt ($Text.Length - 1); $i++) {
        [void]$set.Add($Text.Substring($i, 2))
    }

    return $set
}

function Get-TextMatchScore {
    param(
        [string]$ExpectedText,
        [string]$CandidateText
    )

    $expected = Get-ComparableText -Value $ExpectedText
    $candidate = Get-ComparableText -Value $CandidateText

    if ([string]::IsNullOrWhiteSpace($expected) -or [string]::IsNullOrWhiteSpace($candidate)) {
        return 0
    }

    if ($candidate -eq $expected -or $candidate.Contains($expected)) {
        return 100
    }

    if ($expected.Contains($candidate)) {
        return [int][Math]::Round(100 * ($candidate.Length / [double]$expected.Length))
    }

    $expectedSet = Get-TextTokenSet -Text $expected
    $candidateSet = Get-TextTokenSet -Text $candidate
    if ($expectedSet.Count -eq 0 -or $candidateSet.Count -eq 0) {
        return 0
    }

    $intersection = 0
    foreach ($token in $expectedSet) {
        if ($candidateSet.Contains($token)) {
            $intersection++
        }
    }

    $union = $expectedSet.Count + $candidateSet.Count - $intersection
    if ($union -le 0) {
        return 0
    }

    return [int][Math]::Round(100 * ($intersection / [double]$union))
}

function Get-RequestTextFromCodexMessage {
    param([object]$Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $marker = '## My request for Codex:'
    $index = $text.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
    if ($index -ge 0) {
        return $text.Substring($index + $marker.Length).Trim()
    }

    return $text.Trim()
}

function Get-CodexUserTextFromRecord {
    param([Parameter(Mandatory = $true)]$Record)

    if (-not $Record.PSObject.Properties.Item('payload')) {
        return ''
    }

    $payload = $Record.payload
    if ($Record.type -eq 'event_msg' -and $payload.type -eq 'user_message' -and $payload.PSObject.Properties.Item('message')) {
        return Get-RequestTextFromCodexMessage -Value $payload.message
    }

    if ($Record.type -eq 'response_item' -and $payload.type -eq 'message' -and $payload.role -eq 'user') {
        if ($payload.PSObject.Properties.Item('content')) {
            $parts = @()
            foreach ($part in @($payload.content)) {
                if ($part -is [string]) {
                    $parts += [string]$part
                }
                elseif ($part.PSObject.Properties.Item('text')) {
                    $parts += [string]$part.text
                }
                elseif ($part.PSObject.Properties.Item('content')) {
                    $parts += [string]$part.content
                }
            }

            return Get-RequestTextFromCodexMessage -Value ($parts -join "`n")
        }
    }

    return ''
}

function ConvertTo-DateTimeOffsetOrNull {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Read-LatestCodexSentText {
    param(
        [string]$ExpectedText = '',
        [string]$AfterTimestamp = '',
        [int]$MaxAgeSeconds = 120,
        [int]$MinScore = 70
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedText)) {
        return [pscustomobject]@{
            found = $false
            reason = 'empty_expected_text'
            text = ''
            length = 0
            source = 'codex_session_user_message'
        }
    }

    if (-not (Test-Path -LiteralPath $CodexSessionsRoot)) {
        return [pscustomobject]@{
            found = $false
            reason = 'sessions_root_missing'
            text = ''
            length = 0
            sessionsRoot = $CodexSessionsRoot
            source = 'codex_session_user_message'
        }
    }

    $after = ConvertTo-DateTimeOffsetOrNull -Value $AfterTimestamp
    if ($null -eq $after) {
        $after = [DateTimeOffset]::UtcNow.AddSeconds(-1 * [Math]::Max(1, $MaxAgeSeconds))
    }

    $cutoff = $after.UtcDateTime.AddSeconds(-10)
    $files = @(Get-ChildItem -LiteralPath $CodexSessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $cutoff } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 20)

    if ($files.Count -eq 0) {
        return [pscustomobject]@{
            found = $false
            reason = 'no_recent_session_files'
            text = ''
            length = 0
            afterTimestamp = $after.ToString('o')
            sessionsRoot = $CodexSessionsRoot
            source = 'codex_session_user_message'
        }
    }

    $best = $null
    foreach ($file in $files) {
        $lines = @()
        try {
            $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Tail 500)
        }
        catch {
            continue
        }

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $observedAt = ConvertTo-DateTimeOffsetOrNull -Value $record.timestamp
            if ($null -eq $observedAt -or $observedAt -le $after) {
                continue
            }

            if ($MaxAgeSeconds -gt 0 -and ([DateTimeOffset]::UtcNow - $observedAt).TotalSeconds -gt $MaxAgeSeconds) {
                continue
            }

            $text = Get-CodexUserTextFromRecord -Record $record
            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            $score = Get-TextMatchScore -ExpectedText $ExpectedText -CandidateText $text
            if ($score -lt $MinScore) {
                continue
            }

            if ($null -eq $best -or $score -gt [int]$best.score -or ($score -eq [int]$best.score -and $observedAt -gt $best.observedAtOffset)) {
                $best = [pscustomobject]@{
                    text = Limit-Text -Value $text -MaxLength 4000
                    fullLength = ([string]$text).Length
                    observedAt = $observedAt.ToString('o')
                    observedAtOffset = $observedAt
                    sessionPath = $file.FullName
                    score = $score
                }
            }
        }
    }

    if ($null -eq $best) {
        return [pscustomobject]@{
            found = $false
            reason = 'no_matching_sent_text'
            text = ''
            length = 0
            afterTimestamp = $after.ToString('o')
            minScore = $MinScore
            checkedFiles = $files.Count
            sessionsRoot = $CodexSessionsRoot
            source = 'codex_session_user_message'
        }
    }

    return [pscustomobject]@{
        found = $true
        reason = 'ok'
        text = $best.text
        length = $best.fullLength
        observedAt = $best.observedAt
        sessionPath = $best.sessionPath
        score = $best.score
        minScore = $MinScore
        afterTimestamp = $after.ToString('o')
        checkedFiles = $files.Count
        source = 'codex_session_user_message'
    }
}

function Normalize-BridgeOutput {
    param([string]$Text)

    $cleaned = if ($null -eq $Text) { '' } else { $Text.Trim() }
    $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '^\s*请执行[:：]\s*', '')
    $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '^\s*请根据以下口述内容理解我的需求，并直接执行[:：]\s*', '')
    return $cleaned.Trim()
}

function Invoke-TextBridge {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$RewriteRule = ''
    )

    $bridgeCandidates = @(
        (Join-Path $projectRoot 'tools\CodexVoicePromptBridge\publish-self-contained\CodexVoicePromptBridge.exe'),
        (Join-Path $projectRoot 'tools\CodexVoicePromptBridge\publish-self-contained\CodexVoicePromptBridge'),
        (Join-Path $projectRoot 'tools\CodexVoicePromptBridge\bin\Release\net10.0\CodexVoicePromptBridge.exe'),
        (Join-Path $projectRoot 'tools\CodexVoicePromptBridge\bin\Release\net10.0\CodexVoicePromptBridge')
    )
    $bridgeExe = ($bridgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    $bridgeProject = Join-Path $projectRoot 'tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj'

    $inputFile = [System.IO.Path]::GetTempFileName()
    $outputFile = [System.IO.Path]::GetTempFileName()

    try {
        [System.IO.File]::WriteAllText($inputFile, $Text, [System.Text.UTF8Encoding]::new($false))
        $bridgeArgs = @('--input-file', $inputFile, '--output-file', $outputFile)
        if (-not [string]::IsNullOrWhiteSpace($RewriteRule)) {
            $bridgeArgs += @('--rewrite-rule', $RewriteRule)
        }

        if (-not [string]::IsNullOrWhiteSpace($bridgeExe)) {
            & $bridgeExe @bridgeArgs
        }
        else {
            $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
            if ($null -eq $dotnetCommand) {
                throw "Bridge executable was not found and dotnet was not found on PATH. Checked: $($bridgeCandidates -join ', ')"
            }

            $dotnetArgs = @('run', '--project', $bridgeProject, '-c', 'Release', '--no-launch-profile', '--') + $bridgeArgs
            & $dotnetCommand.Source @dotnetArgs
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Bridge executable failed with exit code $LASTEXITCODE."
        }

        $outputText = [System.IO.File]::ReadAllText($outputFile, [System.Text.Encoding]::UTF8)
        return Normalize-BridgeOutput -Text $outputText
    }
    finally {
        Remove-Item -LiteralPath $inputFile, $outputFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-GeneratedFeedbackProfilePath {
    $settings = Read-Settings
    $profilePath = if ($settings.feedbackLearning -and $settings.feedbackLearning.generatedProfilePath) {
        [string]$settings.feedbackLearning.generatedProfilePath
    }
    else {
        '.codex-tmp/voice-feedback/generated/voice-feedback-learning.generated.json'
    }

    return Resolve-ProjectPath $profilePath
}

function Apply-GeneratedFeedbackProfile {
    param([Parameter(Mandatory = $true)][string]$Text)

    $profilePath = Get-GeneratedFeedbackProfilePath
    if (-not (Test-Path -LiteralPath $profilePath)) {
        return [pscustomobject]@{
            text = $Text
            applied = $false
            appliedCount = 0
            candidatesSeen = 0
            profilePath = $profilePath
            sourceDate = ''
        }
    }

    try {
        $profile = Get-Content -Raw -Encoding UTF8 -LiteralPath $profilePath | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            text = $Text
            applied = $false
            appliedCount = 0
            candidatesSeen = 0
            profilePath = $profilePath
            sourceDate = ''
            reason = 'profile_parse_failed'
        }
    }

    $candidates = @($profile.replacementCandidates)
    $updated = $Text
    $appliedCount = 0

    foreach ($candidate in ($candidates | Sort-Object -Property @{ Expression = { if ($_.autoFragment) { ([string]$_.autoFragment).Length } else { 0 } }; Descending = $true }, @{ Expression = 'count'; Descending = $true })) {
        $autoFragment = if ($candidate.PSObject.Properties.Item('autoFragment')) { [string]$candidate.autoFragment } else { '' }
        $preferredFragment = if ($candidate.PSObject.Properties.Item('preferredFragment')) { [string]$candidate.preferredFragment } else { '' }

        if ([string]::IsNullOrWhiteSpace($autoFragment)) {
            continue
        }

        if ($autoFragment.Length -gt 120 -or $autoFragment.Trim() -eq $preferredFragment.Trim()) {
            continue
        }

        if ($updated.IndexOf($autoFragment, [System.StringComparison]::Ordinal) -ge 0) {
            $updated = $updated.Replace($autoFragment, $preferredFragment)
            $appliedCount++
        }
    }

    return [pscustomobject]@{
        text = $updated
        applied = ($appliedCount -gt 0)
        appliedCount = $appliedCount
        candidatesSeen = $candidates.Count
        profilePath = $profilePath
        sourceDate = if ($profile.PSObject.Properties.Item('sourceDate')) { [string]$profile.sourceDate } else { '' }
    }
}

function Invoke-VoiceHotkey {
    param([bool]$DryRun = $false)

    $settings = Read-Settings
    $hotkey = if ($settings.activeCalibration.voiceHotkey) {
        [string]$settings.activeCalibration.voiceHotkey
    }
    else {
        '^+d'
    }

    if ($DryRun) {
        return [pscustomobject]@{
            sent = $false
            dryRun = $true
            hotkey = $hotkey
            label = [string]$settings.activeCalibration.voiceHotkeyLabel
            platform = if ($script:IsMacOSPlatform) { 'macos' } elseif ($script:IsWindowsPlatform) { 'windows' } else { 'unknown' }
        }
    }

    if (-not $script:IsWindowsPlatform) {
        return [pscustomobject]@{
            sent = $false
            dryRun = $false
            hotkey = $hotkey
            label = [string]$settings.activeCalibration.voiceHotkeyLabel
            platform = if ($script:IsMacOSPlatform) { 'macos' } else { 'unknown' }
            reason = 'voice_hotkey_not_supported_on_this_platform'
            message = 'macOS v0.3 does not send a global voice hotkey. Use Codex voice input, then import the latest transcription or use clipboard import.'
        }
    }

    $escapedHotkey = $hotkey.Replace("'", "''")
    $encodedCommand = "Add-Type -AssemblyName System.Windows.Forms; Start-Sleep -Milliseconds 200; [System.Windows.Forms.SendKeys]::SendWait('$escapedHotkey')"

    Start-Process `
        -FilePath 'powershell.exe' `
        -WindowStyle Hidden `
        -ArgumentList @(
            '-STA',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-Command', $encodedCommand
        ) | Out-Null

    return [pscustomobject]@{
        sent = $true
        hotkey = $hotkey
        label = [string]$settings.activeCalibration.voiceHotkeyLabel
    }
}

function Read-ClipboardText {
    if (-not $script:IsWindowsPlatform) {
        $pbpaste = Get-Command pbpaste -ErrorAction SilentlyContinue
        if ($null -eq $pbpaste) {
            throw 'pbpaste was not found. Clipboard import is unavailable on this platform.'
        }

        $output = & $pbpaste.Source 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw 'pbpaste failed to read the macOS clipboard.'
        }

        return ($output | Out-String).TrimEnd("`r", "`n")
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    $escapedTempFile = $tempFile.Replace("'", "''")
    $command = @(
        'Add-Type -AssemblyName System.Windows.Forms',
        '$text = if ([System.Windows.Forms.Clipboard]::ContainsText()) { [System.Windows.Forms.Clipboard]::GetText() } else { '''' }',
        "[System.IO.File]::WriteAllText('$escapedTempFile', `$text, [System.Text.UTF8Encoding]::new(`$false))"
    ) -join [Environment]::NewLine

    try {
        Start-Process `
            -FilePath 'powershell.exe' `
            -WindowStyle Hidden `
            -Wait `
            -ArgumentList @(
                '-STA',
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-Command', $command
            ) | Out-Null

        return [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8)
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-ClipboardText {
    param([Parameter(Mandatory = $true)][string]$Text)

    if (-not $script:IsWindowsPlatform) {
        $pbcopy = Get-Command pbcopy -ErrorAction SilentlyContinue
        if ($null -eq $pbcopy) {
            throw 'pbcopy was not found. Clipboard write is unavailable on this platform.'
        }

        $Text | & $pbcopy.Source
        if ($LASTEXITCODE -ne 0) {
            throw 'pbcopy failed to write the macOS clipboard.'
        }

        return
    }

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        Add-Type -AssemblyName System.Windows.Forms
        for ($i = 0; $i -lt 8; $i++) {
            try {
                [System.Windows.Forms.Clipboard]::SetText($Text)
                return
            }
            catch {
                Start-Sleep -Milliseconds 40
            }
        }
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    $escapedTempFile = $tempFile.Replace("'", "''")
    $command = @(
        'Add-Type -AssemblyName System.Windows.Forms',
        "`$text = [System.IO.File]::ReadAllText('$escapedTempFile', [System.Text.Encoding]::UTF8)",
        '[System.Windows.Forms.Clipboard]::SetText($text)'
    ) -join [Environment]::NewLine

    try {
        [System.IO.File]::WriteAllText($tempFile, $Text, [System.Text.UTF8Encoding]::new($false))
        Start-Process `
            -FilePath 'powershell.exe' `
            -WindowStyle Hidden `
            -Wait `
            -ArgumentList @(
                '-STA',
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-Command', $command
            ) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PasteTargetInfo {
    param($Target = $null)

    $targetHwnd = 0
    if ($null -ne $Target -and $Target.PSObject.Properties.Item('hwnd')) {
        $targetHwnd = [int64]$Target.hwnd
    }

    $targetProcessName = ''
    if ($null -ne $Target -and $Target.PSObject.Properties.Item('processName')) {
        $targetProcessName = [string]$Target.processName
    }

    $targetTitle = ''
    if ($null -ne $Target -and $Target.PSObject.Properties.Item('title')) {
        $targetTitle = [string]$Target.title
    }

    return [pscustomobject]@{
        hwnd = $targetHwnd
        processName = $targetProcessName
        title = $targetTitle
        platform = if ($null -ne $Target -and $Target.PSObject.Properties.Item('platform')) { [string]$Target.platform } else { if ($script:IsMacOSPlatform) { 'macos' } elseif ($script:IsWindowsPlatform) { 'windows' } else { 'unknown' } }
        requiresCodexComposerFocus = ($targetProcessName -ieq 'Codex' -or $targetTitle -eq 'Codex' -or $targetTitle -match 'Codex')
    }
}

function Focus-PasteTarget {
    param([Parameter(Mandatory = $true)]$Info)

    if ($script:IsMacOSPlatform) {
        if (-not ([string]$Info.processName -ieq 'Codex' -or [string]$Info.title -match 'Codex')) {
            return [pscustomobject]@{
                focused = $false
                skippedReason = 'macos_codex_target_not_captured'
                codexComposerFocusAttempted = $false
                platform = 'macos'
            }
        }

        return [pscustomobject]@{
            focused = $false
            skippedReason = 'macos_composer_focus_unconfirmed'
            codexComposerFocusAttempted = $true
            platform = 'macos'
        }
    }

    if ([int64]$Info.hwnd -le 0) {
        return [pscustomobject]@{
            focused = $false
            skippedReason = 'missing_paste_target'
            codexComposerFocusAttempted = $false
        }
    }

    Ensure-FocusNativeMethods
    [CodexVoiceFocus.NativeMethods]::SetForegroundWindow([IntPtr][int64]$Info.hwnd) | Out-Null
    Start-Sleep -Milliseconds 40

    if (-not [bool]$Info.requiresCodexComposerFocus) {
        return [pscustomobject]@{
            focused = $true
            skippedReason = ''
            codexComposerFocusAttempted = $false
        }
    }

    $codexComposerFocused = $false
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][int64]$Info.hwnd)
        if ($null -ne $root) {
            $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $best = $null
            $bestY = [double]::NegativeInfinity
            foreach ($element in $all) {
                try {
                    $className = $element.Current.ClassName
                    $rect = $element.Current.BoundingRectangle
                    if ($element.Current.IsKeyboardFocusable -and -not $element.Current.IsOffscreen -and $className -like 'ProseMirror*' -and $rect.Width -gt 100 -and $rect.Height -gt 20) {
                        if ($rect.Y -gt $bestY) {
                            $best = $element
                            $bestY = $rect.Y
                        }
                    }
                }
                catch {
                }
            }

            if ($null -ne $best) {
                $best.SetFocus()
                Start-Sleep -Milliseconds 50
                $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
                if ($null -ne $focused -and $focused.Current.ClassName -like 'ProseMirror*') {
                    $codexComposerFocused = $true
                }
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        focused = $codexComposerFocused
        skippedReason = if ($codexComposerFocused) { '' } else { 'codex_composer_focus_failed' }
        codexComposerFocusAttempted = $true
    }
}

function Send-PasteKeys {
    param([bool]$ReplaceExisting = $false)

    if ($script:IsMacOSPlatform) {
        $osascript = Get-Command osascript -ErrorAction SilentlyContinue
        if ($null -eq $osascript) {
            throw 'osascript was not found. Paste the copied text manually with Cmd+V.'
        }

        if ($ReplaceExisting) {
            & $osascript.Source -e 'tell application "Codex" to activate' -e 'tell application "System Events" to keystroke "a" using command down' -e 'delay 0.06' -e 'tell application "System Events" to keystroke "v" using command down' | Out-Null
            return
        }

        & $osascript.Source -e 'tell application "Codex" to activate' -e 'tell application "System Events" to keystroke "v" using command down' | Out-Null
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    if ($ReplaceExisting) {
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        Start-Sleep -Milliseconds 60
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        return
    }

    [System.Windows.Forms.SendKeys]::SendWait('^v')
}

function Start-DelayedPaste {
    param(
        [int]$DelaySeconds = 0,
        [bool]$ReplaceExisting = $false,
        $Target = $null
    )

    if ($DelaySeconds -lt 0) {
        $DelaySeconds = 0
    }
    elseif ($DelaySeconds -gt 10) {
        $DelaySeconds = 10
    }

    $delayMs = $DelaySeconds * 1000
    $targetInfo = Get-PasteTargetInfo -Target $Target

    if ($script:IsMacOSPlatform) {
        $settings = Read-Settings
        if (-not [bool]$settings.activeCalibration.macOsBestEffortPasteEnabled) {
            return [pscustomobject]@{
                started = $false
                pastedImmediately = $false
                mode = 'macos_best_effort_disabled'
                skippedReason = 'macos_best_effort_paste_disabled'
                focusResult = [pscustomobject]@{
                    focused = $false
                    skippedReason = 'macos_best_effort_paste_disabled'
                    codexComposerFocusAttempted = $false
                    platform = 'macos'
                }
            }
        }

        if (-not ([string]$targetInfo.processName -ieq 'Codex' -or [string]$targetInfo.title -match 'Codex')) {
            return [pscustomobject]@{
                started = $false
                pastedImmediately = $false
                mode = 'macos_applescript_best_effort'
                skippedReason = 'macos_codex_target_not_captured'
                focusResult = [pscustomobject]@{
                    focused = $false
                    skippedReason = 'macos_codex_target_not_captured'
                    codexComposerFocusAttempted = $false
                    platform = 'macos'
                }
            }
        }

        try {
            if ($DelaySeconds -gt 0) {
                Start-Sleep -Seconds $DelaySeconds
            }

            Send-PasteKeys -ReplaceExisting $ReplaceExisting
            return [pscustomobject]@{
                started = $true
                pastedImmediately = $true
                mode = 'macos_applescript_best_effort'
                skippedReason = ''
                focusResult = [pscustomobject]@{
                    focused = $true
                    skippedReason = ''
                    codexComposerFocusAttempted = $true
                    platform = 'macos'
                }
            }
        }
        catch {
            return [pscustomobject]@{
                started = $false
                pastedImmediately = $false
                mode = 'macos_applescript_best_effort'
                skippedReason = 'macos_accessibility_or_automation_failed'
                error = $_.Exception.Message
                focusResult = [pscustomobject]@{
                    focused = $false
                    skippedReason = 'macos_accessibility_or_automation_failed'
                    codexComposerFocusAttempted = $true
                    platform = 'macos'
                }
            }
        }
    }

    if (-not $script:IsWindowsPlatform) {
        return [pscustomobject]@{
            started = $false
            pastedImmediately = $false
            mode = 'unsupported_platform'
            skippedReason = 'paste_not_supported_on_this_platform'
            focusResult = [pscustomobject]@{
                focused = $false
                skippedReason = 'paste_not_supported_on_this_platform'
                codexComposerFocusAttempted = $false
                platform = 'unknown'
            }
        }
    }

    $requiresCodexComposerFocusLiteral = if ([bool]$targetInfo.requiresCodexComposerFocus) { '$true' } else { '$false' }

    if ($DelaySeconds -eq 0 -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        $focusResult = Focus-PasteTarget -Info $targetInfo
        if (-not [bool]$focusResult.focused) {
            return [pscustomobject]@{
                started = $false
                pastedImmediately = $false
                mode = 'direct_sta'
                skippedReason = [string]$focusResult.skippedReason
                focusResult = $focusResult
            }
        }

        Send-PasteKeys -ReplaceExisting $ReplaceExisting
        return [pscustomobject]@{
            started = $true
            pastedImmediately = $true
            mode = 'direct_sta'
            skippedReason = ''
            focusResult = $focusResult
        }
    }

    $sendKeys = if ($ReplaceExisting) {
        "[System.Windows.Forms.SendKeys]::SendWait('^a'); Start-Sleep -Milliseconds 60; [System.Windows.Forms.SendKeys]::SendWait('^v')"
    }
    else {
        "[System.Windows.Forms.SendKeys]::SendWait('^v')"
    }

    $focusCode = if ([int64]$targetInfo.hwnd -gt 0) {
        @"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexVoicePasteFocus
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
[CodexVoicePasteFocus]::SetForegroundWindow([IntPtr]$($targetInfo.hwnd)) | Out-Null
Start-Sleep -Milliseconds 40
`$requiresCodexComposerFocus = $requiresCodexComposerFocusLiteral
if (`$requiresCodexComposerFocus) {
    `$codexComposerFocused = `$false
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        `$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$targetHwnd)
        if (`$null -ne `$root) {
            `$all = `$root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            `$best = `$null
            `$bestY = [double]::NegativeInfinity
            foreach (`$element in `$all) {
                try {
                    `$className = `$element.Current.ClassName
                    `$rect = `$element.Current.BoundingRectangle
                    if (`$element.Current.IsKeyboardFocusable -and -not `$element.Current.IsOffscreen -and `$className -like 'ProseMirror*' -and `$rect.Width -gt 100 -and `$rect.Height -gt 20) {
                        if (`$rect.Y -gt `$bestY) {
                            `$best = `$element
                            `$bestY = `$rect.Y
                        }
                    }
                }
                catch {
                }
            }

            if (`$null -ne `$best) {
                `$best.SetFocus()
                Start-Sleep -Milliseconds 50
                `$focused = [System.Windows.Automation.AutomationElement]::FocusedElement
                if (`$null -ne `$focused -and `$focused.Current.ClassName -like 'ProseMirror*') {
                    `$codexComposerFocused = `$true
                }
            }
        }
    }
    catch {
    }

    if (-not `$codexComposerFocused) {
        exit 0
    }
}
"@
    }
    else {
        ''
    }

    $command = "Add-Type -AssemblyName System.Windows.Forms; Start-Sleep -Milliseconds $delayMs; $focusCode $sendKeys"
    Start-Process `
        -FilePath 'powershell.exe' `
        -WindowStyle Hidden `
        -ArgumentList @(
            '-STA',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-Command', $command
        ) | Out-Null

    return [pscustomobject]@{
        started = $true
        pastedImmediately = $false
        mode = 'background_powershell'
        skippedReason = ''
        focusResult = [pscustomobject]@{
            focused = $true
            skippedReason = ''
            codexComposerFocusAttempted = [bool]$targetInfo.requiresCodexComposerFocus
        }
    }
}

function Apply-FinalText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [bool]$SendPaste = $false,
        [int]$PasteDelaySeconds = 0,
        [bool]$ReplaceExisting = $false,
        [bool]$UseCapturedTarget = $true
    )

    $limitedText = Limit-Text -Value $Text -MaxLength 4000
    if ([string]::IsNullOrWhiteSpace($limitedText)) {
        return [pscustomobject]@{
            copied = $false
            pasteScheduled = $false
            pastedImmediately = $false
            pasteSkippedReason = 'empty_text'
            pasteMode = ''
            reason = 'empty_text'
            replaceExisting = $ReplaceExisting
            pasteDelaySeconds = $PasteDelaySeconds
            pasteTarget = $null
            codexComposerFocusAttempted = $false
            pasteResult = $null
            length = 0
            source = 'codex_voice_final_text'
        }
    }

    Write-ClipboardText -Text $limitedText
    $pasteTarget = if ($UseCapturedTarget) { Get-PasteTargetSnapshot } else { $null }
    $codexComposerFocusAttempted = $false
    if ($null -ne $pasteTarget) {
        $processName = if ($pasteTarget.PSObject.Properties.Item('processName')) { [string]$pasteTarget.processName } else { '' }
        $title = if ($pasteTarget.PSObject.Properties.Item('title')) { [string]$pasteTarget.title } else { '' }
        $codexComposerFocusAttempted = ($processName -ieq 'Codex' -or $title -eq 'Codex')
    }
    $pasteScheduled = $false
    $pastedImmediately = $false
    $pasteSkippedReason = ''
    $pasteMode = ''
    $pasteResult = $null
    if ($SendPaste -and $null -ne $pasteTarget) {
        $pasteResult = Start-DelayedPaste -DelaySeconds $PasteDelaySeconds -ReplaceExisting $ReplaceExisting -Target $pasteTarget
        $pasteMode = [string]$pasteResult.mode
        $pastedImmediately = [bool]$pasteResult.pastedImmediately
        $pasteScheduled = ([bool]$pasteResult.started -and -not $pastedImmediately)
        if (-not [bool]$pasteResult.started) {
            $pasteSkippedReason = [string]$pasteResult.skippedReason
        }
    }
    elseif ($SendPaste) {
        $pasteSkippedReason = 'missing_paste_target'
    }

    return [pscustomobject]@{
        copied = $true
        pasteScheduled = $pasteScheduled
        pastedImmediately = $pastedImmediately
        pasteSkippedReason = $pasteSkippedReason
        pasteMode = $pasteMode
        replaceExisting = $ReplaceExisting
        pasteDelaySeconds = $PasteDelaySeconds
        pasteTarget = $pasteTarget
        codexComposerFocusAttempted = $codexComposerFocusAttempted
        pasteResult = $pasteResult
        length = $limitedText.Length
        source = 'codex_voice_final_text'
    }
}

function Test-IsCalibrationPageCapture {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $normalized = $Text.ToLowerInvariant()
    $matches = 0
    foreach ($signature in @('codex', 'ctrl+shift+d', 'token', '127.0.0.1', '8793')) {
        if ($normalized.Contains($signature)) {
            $matches++
        }
    }

    return ($Text.Length -gt 800 -and $matches -ge 3)
}

function Invoke-VoiceAutoCapture {
    param([int]$DelaySeconds = 8)

    $settings = Read-Settings
    $hotkey = if ($settings.activeCalibration.voiceHotkey) {
        [string]$settings.activeCalibration.voiceHotkey
    }
    else {
        '^+d'
    }

    if ($DelaySeconds -lt 2) {
        $DelaySeconds = 2
    }
    elseif ($DelaySeconds -gt 60) {
        $DelaySeconds = 60
    }

    if (-not $script:IsWindowsPlatform) {
        $before = Read-LatestCodexTranscription -MaxAgeSeconds 0
        $beforeCreatedAtMs = if ($before.found -and $before.createdAtMs) { [int64]$before.createdAtMs } else { 0 }
        Start-Sleep -Seconds $DelaySeconds
        $latest = Read-LatestCodexTranscription -AfterCreatedAtMs $beforeCreatedAtMs -MaxAgeSeconds 0
        $latest | Add-Member -MemberType NoteProperty -Name rejected -Value (-not $latest.found) -Force
        $latest | Add-Member -MemberType NoteProperty -Name hotkey -Value $hotkey -Force
        $latest | Add-Member -MemberType NoteProperty -Name label -Value ([string]$settings.activeCalibration.voiceHotkeyLabel) -Force
        $latest | Add-Member -MemberType NoteProperty -Name delaySeconds -Value $DelaySeconds -Force
        $latest | Add-Member -MemberType NoteProperty -Name platform -Value (if ($script:IsMacOSPlatform) { 'macos' } else { 'unknown' }) -Force
        if (-not $latest.found) {
            $latest | Add-Member -MemberType NoteProperty -Name reason -Value 'macos_voice_hotkey_not_sent_no_new_transcription' -Force
            $latest | Add-Member -MemberType NoteProperty -Name message -Value 'macOS v0.3 does not send a global voice hotkey. Use Codex voice input, then import the latest transcription or use clipboard import.' -Force
        }
        return $latest
    }

    $before = Read-LatestCodexTranscription -MaxAgeSeconds 0
    $afterCreatedAtMs = if ($before.found -and $before.createdAtMs) { [int64]$before.createdAtMs } else { 0 }
    $escapedHotkey = $hotkey.Replace("'", "''")
    $encodedCommand = "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('$escapedHotkey')"

    Start-Process `
        -FilePath 'powershell.exe' `
        -WindowStyle Hidden `
        -ArgumentList @(
            '-STA',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-Command', $encodedCommand
        ) | Out-Null

    Start-Sleep -Seconds $DelaySeconds
    $latest = Read-LatestCodexTranscription -AfterCreatedAtMs $afterCreatedAtMs

    if (-not $latest.found) {
        $latest | Add-Member -MemberType NoteProperty -Name rejected -Value $true -Force
        $latest | Add-Member -MemberType NoteProperty -Name hotkey -Value $hotkey -Force
        $latest | Add-Member -MemberType NoteProperty -Name label -Value ([string]$settings.activeCalibration.voiceHotkeyLabel) -Force
        $latest | Add-Member -MemberType NoteProperty -Name delaySeconds -Value $DelaySeconds -Force
        $latest | Add-Member -MemberType NoteProperty -Name message -Value 'No new Codex transcription appeared in transcription-history.jsonl after sending the voice hotkey.' -Force
        return $latest
    }

    $latest | Add-Member -MemberType NoteProperty -Name rejected -Value $false -Force
    $latest | Add-Member -MemberType NoteProperty -Name hotkey -Value $hotkey -Force
    $latest | Add-Member -MemberType NoteProperty -Name label -Value ([string]$settings.activeCalibration.voiceHotkeyLabel) -Force
    $latest | Add-Member -MemberType NoteProperty -Name delaySeconds -Value $DelaySeconds -Force
    return $latest
}

function Invoke-AutoApplyCodexTranscription {
    param(
        [int64]$AfterCreatedAtMs = 0,
        [string]$RewriteRule = ''
    )

    $latest = Read-LatestCodexTranscription -AfterCreatedAtMs $AfterCreatedAtMs -MaxAgeSeconds 0
    if (-not $latest.found) {
        return [pscustomobject]@{
            found = $false
            applied = $false
            reason = if ($latest.PSObject.Properties.Item('reason')) { [string]$latest.reason } else { 'no_new_transcription' }
            afterCreatedAtMs = $AfterCreatedAtMs
            latest = $latest
            source = 'codex_voice_auto_apply'
        }
    }

    $rawText = Limit-Text -Value $latest.text -MaxLength 4000
    if ([string]::IsNullOrWhiteSpace($rawText)) {
        return [pscustomobject]@{
            found = $true
            applied = $false
            reason = 'empty_transcription_text'
            createdAtMs = $latest.createdAtMs
            rawText = ''
            polishedText = ''
            finalText = ''
            latest = $latest
            source = 'codex_voice_auto_apply'
        }
    }

    try {
        $polishedText = Invoke-TextBridge -Text $rawText -RewriteRule $RewriteRule
        $profileResult = Apply-GeneratedFeedbackProfile -Text $polishedText
        $finalText = Limit-Text -Value $profileResult.text -MaxLength 4000
        $applyResult = Apply-FinalText -Text $finalText -SendPaste $true -PasteDelaySeconds 0 -ReplaceExisting $true -UseCapturedTarget $true

        return [pscustomobject]@{
            found = $true
            applied = [bool]$applyResult.copied
            reason = if ([bool]$applyResult.copied) { 'ok' } else { if ($applyResult.PSObject.Properties.Item('reason')) { [string]$applyResult.reason } else { 'apply_failed' } }
            createdAtMs = $latest.createdAtMs
            id = $latest.id
            rawText = $rawText
            polishedText = $finalText
            finalText = $finalText
            profileApplied = [bool]$profileResult.applied
            profileAppliedCount = [int]$profileResult.appliedCount
            profileCandidateCount = [int]$profileResult.candidatesSeen
            latest = $latest
            applyResult = $applyResult
            source = 'codex_voice_auto_apply'
        }
    }
    catch {
        return [pscustomobject]@{
            found = $true
            applied = $false
            reason = 'auto_apply_failed'
            error = $_.Exception.Message
            createdAtMs = $latest.createdAtMs
            rawText = $rawText
            polishedText = ''
            finalText = ''
            latest = $latest
            source = 'codex_voice_auto_apply'
        }
    }
}

function Invoke-FeedbackCleanup {
    $cleanupScript = Join-Path $scriptRoot 'Invoke-VoiceFeedbackCleanup.ps1'
    if (-not (Test-Path -LiteralPath $cleanupScript)) {
        return [pscustomobject]@{
            cleaned = $false
            reason = 'cleanup_script_not_found'
        }
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $cleanupScript,
        '-SettingsPath', $SettingsPath,
        '-Json'
    )

    if (-not [string]::IsNullOrWhiteSpace($FeedbackDir)) {
        $arguments += @('-FeedbackDir', $FeedbackDir)
    }

    try {
        $output = & powershell.exe @arguments 2>&1
        $outputText = ($output | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{
                cleaned = $false
                reason = 'cleanup_failed'
                output = Limit-Text -Value $outputText -MaxLength 1000
            }
        }

        return ($outputText | ConvertFrom-Json)
    }
    catch {
        return [pscustomobject]@{
            cleaned = $false
            reason = 'cleanup_exception'
            output = Limit-Text -Value $_.Exception.Message -MaxLength 1000
        }
    }
}

function Write-FeedbackRecord {
    param([Parameter(Mandatory = $true)]$Payload)

    $settings = Read-Settings
    $learning = $settings.feedbackLearning
    $source = [string]$Payload.source

    if ($source -notin @('codex_voice_web_review', 'codex_voice_active_calibration')) {
        return [pscustomobject]@{
            recorded = $false
            reason = 'unsupported_source'
        }
    }

    if ($Payload.captureContext -ne 'codex_voice_input') {
        return [pscustomobject]@{
            recorded = $false
            reason = 'unsupported_context'
        }
    }

    if ($source -eq 'codex_voice_web_review' -and -not [bool]$learning.enabled) {
        return [pscustomobject]@{
            recorded = $false
            reason = 'disabled'
        }
    }

    $maxTextLength = if ($learning.maxTextLength) { [int]$learning.maxTextLength } else { 4000 }
    $targetDir = if ([string]::IsNullOrWhiteSpace($FeedbackDir)) {
        Resolve-ProjectPath ([string]$learning.storageDir)
    }
    else {
        $FeedbackDir
    }

    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir | Out-Null
    }

    $date = Get-Date -Format 'yyyy-MM-dd'
    $path = Join-Path $targetDir "$date.jsonl"
    $rawText = Limit-Text -Value $Payload.rawText -MaxLength $maxTextLength
    $polishedText = Limit-Text -Value $Payload.polishedText -MaxLength $maxTextLength
    $finalText = Limit-Text -Value $Payload.finalText -MaxLength $maxTextLength
    $sentToCodexText = if ($Payload.PSObject.Properties.Item('sentToCodexText')) {
        Limit-Text -Value $Payload.sentToCodexText -MaxLength $maxTextLength
    }
    else {
        $finalText
    }
    $changedFromPolished = ($polishedText.Trim() -ne $sentToCodexText.Trim())

    if (-not $changedFromPolished) {
        return [pscustomobject]@{
            recorded = $false
            reason = 'unchanged_from_polished'
            changedFromPolished = $false
            polishedLength = $polishedText.Length
            sentToCodexLength = $sentToCodexText.Length
        }
    }

    $record = [pscustomobject]@{
        version = 1
        source = $source
        captureContext = 'codex_voice_input'
        recordedAt = (Get-Date).ToString('o')
        decision = [string]$Payload.decision
        stage = [string]$Payload.stage
        topicId = [string]$Payload.topicId
        topicTitle = [string]$Payload.topicTitle
        rewriteRule = Limit-Text -Value $Payload.rewriteRule -MaxLength 1000
        rawText = $rawText
        polishedText = $polishedText
        finalText = $finalText
        sentToCodexText = $sentToCodexText
        finalTextMeaning = if ($Payload.PSObject.Properties.Item('finalTextMeaning')) { [string]$Payload.finalTextMeaning } else { 'text_confirmed_for_codex_send' }
        changedFromRaw = ($rawText.Trim() -ne $sentToCodexText.Trim())
        changedFromPolished = $changedFromPolished
        notes = @($Payload.notes)
    }

    ($record | ConvertTo-Json -Depth 8 -Compress) | Add-Content -Encoding UTF8 -LiteralPath $path

    $cleanup = $null
    if (-not $learning.PSObject.Properties.Item('cleanupAfterSave') -or [bool]$learning.cleanupAfterSave) {
        $cleanup = Invoke-FeedbackCleanup
    }

    return [pscustomobject]@{
        recorded = $true
        reason = 'ok'
        path = $path
        cleanup = $cleanup
    }
}

function Invoke-FeedbackLearningIteration {
    param([string]$Date = '')

    $iterationScript = Join-Path $scriptRoot 'Invoke-VoiceFeedbackDailyIteration.ps1'
    if (-not (Test-Path -LiteralPath $iterationScript)) {
        return [pscustomobject]@{
            generated = $false
            reason = 'iteration_script_not_found'
        }
    }

    $settings = Read-Settings
    $effectiveDate = ''
    if (-not [string]::IsNullOrWhiteSpace($Date)) {
        try {
            $effectiveDate = ([datetime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd')
        }
        catch {
            return [pscustomobject]@{
                generated = $false
                reason = 'invalid_iteration_date'
            }
        }
    }
    else {
        $effectiveDate = Get-LatestFeedbackLogDate -Settings $settings
    }

    if ([string]::IsNullOrWhiteSpace($effectiveDate)) {
        return [pscustomobject]@{
            generated = $false
            reason = 'no_feedback_log_found'
        }
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $iterationScript,
        '-Date', $effectiveDate,
        '-Force',
        '-SettingsPath', $SettingsPath
    )

    if (-not [string]::IsNullOrWhiteSpace($FeedbackDir)) {
        $arguments += @('-FeedbackDir', $FeedbackDir)
    }

    $shellCommand = if ($script:IsWindowsPlatform) {
        Get-Command powershell.exe -ErrorAction SilentlyContinue
    }
    else {
        Get-Command pwsh -ErrorAction SilentlyContinue
    }

    if ($null -eq $shellCommand) {
        return [pscustomobject]@{
            generated = $false
            reason = 'powershell_not_found'
        }
    }

    $output = & $shellCommand.Source @arguments 2>&1
    $outputText = ($output | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            generated = $false
            reason = 'iteration_failed'
            output = Limit-Text -Value $outputText -MaxLength 1000
        }
    }

    $settings = Read-Settings
    $profilePath = Resolve-ProjectPath ([string]$settings.feedbackLearning.generatedProfilePath)
    $profile = $null
    if (Test-Path -LiteralPath $profilePath) {
        try {
            $profile = Get-Content -Raw -Encoding UTF8 -LiteralPath $profilePath | ConvertFrom-Json
        }
        catch {
            $profile = $null
        }
    }

    $replacementCandidates = if ($null -ne $profile) { @($profile.replacementCandidates) } else { @() }
    $rewriteRuleSamples = if ($null -ne $profile) { @($profile.rewriteRuleSamples) } else { @() }
    $cleanup = $null
    if (
        $settings.feedbackLearning -and
        (-not $settings.feedbackLearning.PSObject.Properties.Item('cleanupAfterDailyIteration') -or [bool]$settings.feedbackLearning.cleanupAfterDailyIteration)
    ) {
        $cleanup = Invoke-FeedbackCleanup
    }

    return [pscustomobject]@{
        generated = (Test-Path -LiteralPath $profilePath)
        reason = 'ok'
        path = $profilePath
        sourceLog = if ($null -ne $profile -and $profile.PSObject.Properties.Item('sourceLog')) { [string]$profile.sourceLog } else { '' }
        sourceDate = if ($null -ne $profile -and $profile.PSObject.Properties.Item('sourceDate')) { [string]$profile.sourceDate } else { '' }
        eventsSeen = if ($null -ne $profile -and $profile.PSObject.Properties.Item('eventsSeen')) { [int]$profile.eventsSeen } else { 0 }
        changedEvents = if ($null -ne $profile -and $profile.PSObject.Properties.Item('changedEvents')) { [int]$profile.changedEvents } else { 0 }
        replacementCandidateCount = $replacementCandidates.Count
        rewriteRuleSampleCount = $rewriteRuleSamples.Count
        topReplacementCandidates = @($replacementCandidates | Select-Object -First 5)
        cleanup = $cleanup
        output = Limit-Text -Value $outputText -MaxLength 1000
    }
}

function Invoke-DueFeedbackLearningIteration {
    $now = Get-Date
    if (($now - $script:LastFeedbackDailyCheckAt).TotalSeconds -lt 30) {
        return $null
    }

    $script:LastFeedbackDailyCheckAt = $now
    $settings = Read-Settings
    if (-not $settings.feedbackLearning -or -not [bool]$settings.feedbackLearning.enabled) {
        return $null
    }

    $timeText = if ($settings.feedbackLearning.dailyIterationTime -match '^\d{2}:\d{2}$') {
        [string]$settings.feedbackLearning.dailyIterationTime
    }
    else {
        '00:00'
    }

    $timeParts = $timeText.Split(':')
    $dueAt = $now.Date.AddHours([int]$timeParts[0]).AddMinutes([int]$timeParts[1])
    if ($now -lt $dueAt) {
        return $null
    }

    $runKey = $now.ToString('yyyy-MM-dd')
    $state = Read-FeedbackIterationState -Settings $settings
    if ($state.PSObject.Properties.Item('lastRunKey') -and [string]$state.lastRunKey -eq $runKey) {
        return $null
    }

    $sourceDate = $now.Date.AddDays(-1).ToString('yyyy-MM-dd')
    $feedbackRoot = Get-FeedbackStorageDir -Settings $settings
    $sourceLog = Join-Path $feedbackRoot "$sourceDate.jsonl"
    $result = if (Test-Path -LiteralPath $sourceLog) {
        Invoke-FeedbackLearningIteration -Date $sourceDate
    }
    else {
        [pscustomobject]@{
            generated = $false
            reason = 'source_log_not_found'
            sourceDate = $sourceDate
            sourceLog = $sourceLog
        }
    }

    Write-FeedbackIterationState -Settings $settings -State ([pscustomobject]@{
        lastRunKey = $runKey
        lastCheckedAt = $now.ToString('o')
        scheduledTime = $timeText
        sourceDate = $sourceDate
        sourceLog = $sourceLog
        generated = [bool]$result.generated
        reason = [string]$result.reason
        changedEvents = if ($result.PSObject.Properties.Item('changedEvents')) { [int]$result.changedEvents } else { 0 }
        replacementCandidateCount = if ($result.PSObject.Properties.Item('replacementCandidateCount')) { [int]$result.replacementCandidateCount } else { 0 }
    })

    return $result
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $requestPath = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart('/'))
        try {
            Invoke-DueFeedbackLearningIteration | Out-Null
        }
        catch {
            # Keep the review service responsive even if local learning iteration fails.
        }

        if ([string]::IsNullOrWhiteSpace($requestPath)) {
            $requestPath = 'settings.html'
        }

        if ($requestPath -eq 'health') {
            Send-TextResponse -Response $context.Response -Text 'ok'
            continue
        }

        if ($requestPath -eq 'api/features') {
            Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{
                version = 11
                features = @(
                    'latest-codex-transcription',
                    'latest-codex-sent-text',
                    'rule-driven-polish',
                    'apply-final-text',
                    'direct-zero-delay-return',
                    'return-validation-panel',
                    'generated-profile-polish',
                    'replace-existing-on-return',
                    'auto-apply-codex-transcription',
                    'feedback-learning-iteration',
                    'separate-save-and-rule-update',
                    'feedback-retention-cleanup',
                    'cross-platform-macos-clipboard',
                    'platform-capabilities',
                    'startup-task-registration'
                )
            })
            continue
        }

        if ($requestPath -eq 'api/platform') {
            if ($context.Request.HttpMethod -ne 'GET') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{
                platform = if ($script:IsMacOSPlatform) { 'macos' } elseif ($script:IsWindowsPlatform) { 'windows' } else { 'unknown' }
                isWindows = $script:IsWindowsPlatform
                isMacOS = $script:IsMacOSPlatform
                transcriptionHistoryPath = $TranscriptionHistoryPath
                codexSessionsRoot = $CodexSessionsRoot
                clipboardAdapter = if ($script:IsMacOSPlatform) { 'pbcopy-pbpaste' } elseif ($script:IsWindowsPlatform) { 'windows-forms-sta' } else { 'none' }
                pasteTargetAdapter = if ($script:IsMacOSPlatform) { 'macos-applescript-best-effort-disabled-by-default' } elseif ($script:IsWindowsPlatform) { 'user32-uia-sendkeys' } else { 'none' }
                macOsBestEffortPasteEnabled = if ($script:IsMacOSPlatform) { [bool](Read-Settings).activeCalibration.macOsBestEffortPasteEnabled } else { $false }
            })
            continue
        }

        if ($requestPath -eq 'api/settings') {
            if ($context.Request.HttpMethod -eq 'GET') {
                Send-JsonResponse -Response $context.Response -Value (Get-SettingsResponse -Settings (Read-Settings))
                continue
            }

            if ($context.Request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-RequestBody -Request $context.Request
                    $incoming = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
                    Send-JsonResponse -Response $context.Response -Value (Merge-Settings -Incoming $incoming)
                }
                catch {
                    Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = $_.Exception.Message }) -StatusCode 500
                }

                continue
            }

            Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
            continue
        }

        if ($requestPath -eq 'api/onboarding-topics') {
            if ($context.Request.HttpMethod -ne 'GET') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $topicsPath = Join-Path $projectRoot 'config\onboarding-topic-prompts.json'
            if (-not (Test-Path -LiteralPath $topicsPath)) {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'topics not found' }) -StatusCode 404
                continue
            }

            $topics = Get-Content -Raw -Encoding UTF8 -LiteralPath $topicsPath | ConvertFrom-Json
            Send-JsonResponse -Response $context.Response -Value $topics
            continue
        }

        if ($requestPath -eq 'api/polish') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            $rawText = Limit-Text -Value $payload.rawText -MaxLength 4000
            $rewriteRule = Limit-Text -Value $payload.rewriteRule -MaxLength 1000

            if ([string]::IsNullOrWhiteSpace($rawText)) {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'empty rawText' }) -StatusCode 400
                continue
            }

            try {
                $polishedText = Invoke-TextBridge -Text $rawText -RewriteRule $rewriteRule
                $profileResult = Apply-GeneratedFeedbackProfile -Text $polishedText
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{
                    polishedText = [string]$profileResult.text
                    profileApplied = [bool]$profileResult.applied
                    profileAppliedCount = [int]$profileResult.appliedCount
                    profileCandidateCount = [int]$profileResult.candidatesSeen
                    profilePath = [string]$profileResult.profilePath
                    profileSourceDate = [string]$profileResult.sourceDate
                })
            }
            catch {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = $_.Exception.Message }) -StatusCode 500
            }

            continue
        }

        if ($requestPath -eq 'api/voice-hotkey') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            Send-JsonResponse -Response $context.Response -Value (Invoke-VoiceHotkey -DryRun ([bool]$payload.dryRun))
            continue
        }

        if ($requestPath -eq 'api/clipboard-text') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            try {
                $clipboardText = Limit-Text -Value (Read-ClipboardText) -MaxLength 4000
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{
                    text = $clipboardText
                    length = $clipboardText.Length
                    source = 'explicit_clipboard_import'
                    capturedAt = (Get-Date).ToString('o')
                    monitoring = $false
                })
            }
            catch {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = $_.Exception.Message }) -StatusCode 500
            }

            continue
        }

        if ($requestPath -eq 'api/apply-final-text') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            $text = if ($payload.PSObject.Properties.Item('text')) { [string]$payload.text } else { '' }
            $sendPaste = ($payload.PSObject.Properties.Item('sendPaste') -and [bool]$payload.sendPaste)
            $pasteDelaySeconds = if ($payload.PSObject.Properties.Item('pasteDelaySeconds')) { [int]$payload.pasteDelaySeconds } else { 0 }
            $replaceExisting = ($payload.PSObject.Properties.Item('replaceExisting') -and [bool]$payload.replaceExisting)
            $useCapturedTarget = -not ($payload.PSObject.Properties.Item('useCapturedTarget') -and -not [bool]$payload.useCapturedTarget)
            $result = Apply-FinalText -Text $text -SendPaste $sendPaste -PasteDelaySeconds $pasteDelaySeconds -ReplaceExisting $replaceExisting -UseCapturedTarget $useCapturedTarget
            Send-JsonResponse -Response $context.Response -Value $result
            continue
        }

        if ($requestPath -eq 'api/capture-paste-target') {
            if ($context.Request.HttpMethod -notin @('GET', 'POST')) {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{
                captured = $true
                pasteTarget = (Capture-PasteTarget -Reason 'manual_api')
            })
            continue
        }

        if ($requestPath -eq 'api/latest-codex-transcription') {
            if ($context.Request.HttpMethod -notin @('GET', 'POST')) {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $payload = [pscustomobject]@{}
            if ($context.Request.HttpMethod -eq 'POST') {
                $body = Read-RequestBody -Request $context.Request
                $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            }

            $afterCreatedAtMs = if ($payload.PSObject.Properties.Item('afterCreatedAtMs') -and $payload.afterCreatedAtMs) {
                [int64]$payload.afterCreatedAtMs
            }
            else {
                0
            }

            $maxAgeSeconds = if ($payload.PSObject.Properties.Item('maxAgeSeconds') -and $payload.maxAgeSeconds) {
                [int]$payload.maxAgeSeconds
            }
            else {
                $MaxTranscriptionAgeSeconds
            }

            Send-JsonResponse -Response $context.Response -Value (Read-LatestCodexTranscription -AfterCreatedAtMs $afterCreatedAtMs -MaxAgeSeconds $maxAgeSeconds)
            continue
        }

        if ($requestPath -eq 'api/latest-codex-sent-text') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            $settings = Read-Settings
            $expectedText = if ($payload.PSObject.Properties.Item('expectedText')) {
                Limit-Text -Value $payload.expectedText -MaxLength 4000
            }
            else {
                ''
            }
            $afterTimestamp = if ($payload.PSObject.Properties.Item('afterTimestamp')) { [string]$payload.afterTimestamp } else { '' }
            $maxAgeSeconds = if ($payload.PSObject.Properties.Item('maxAgeSeconds') -and $payload.maxAgeSeconds) {
                [int]$payload.maxAgeSeconds
            }
            elseif ($settings.activeCalibration.sentTextMonitorDurationSeconds) {
                [int]$settings.activeCalibration.sentTextMonitorDurationSeconds
            }
            else {
                60
            }
            $minScore = if ($payload.PSObject.Properties.Item('minScore') -and $payload.minScore) {
                [int]$payload.minScore
            }
            elseif ($settings.activeCalibration.sentTextMonitorMinScore) {
                [int]$settings.activeCalibration.sentTextMonitorMinScore
            }
            else {
                70
            }

            Send-JsonResponse -Response $context.Response -Value (Read-LatestCodexSentText -ExpectedText $expectedText -AfterTimestamp $afterTimestamp -MaxAgeSeconds $maxAgeSeconds -MinScore $minScore)
            continue
        }

        if ($requestPath -eq 'api/voice-auto-capture') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            $settings = Read-Settings
            $delaySeconds = if ($payload.delaySeconds) {
                [int]$payload.delaySeconds
            }
            elseif ($settings.activeCalibration.autoImportDelaySeconds) {
                [int]$settings.activeCalibration.autoImportDelaySeconds
            }
            else {
                8
            }

            if ([bool]$payload.dryRun) {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{
                    dryRun = $true
                    sent = $false
                    delaySeconds = $delaySeconds
                    hotkey = [string]$settings.activeCalibration.voiceHotkey
                    label = [string]$settings.activeCalibration.voiceHotkeyLabel
                    captureMode = 'send_hotkey_wait_then_read_codex_transcription_history'
                    monitoring = $false
                })
                continue
            }

            try {
                Send-JsonResponse -Response $context.Response -Value (Invoke-VoiceAutoCapture -DelaySeconds $delaySeconds)
            }
            catch {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = $_.Exception.Message }) -StatusCode 500
            }

            continue
        }

        if ($requestPath -eq 'api/auto-apply-codex-transcription') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            $afterCreatedAtMs = if ($payload.PSObject.Properties.Item('afterCreatedAtMs') -and $payload.afterCreatedAtMs) {
                [int64]$payload.afterCreatedAtMs
            }
            else {
                0
            }
            $rewriteRule = if ($payload.PSObject.Properties.Item('rewriteRule')) {
                Limit-Text -Value $payload.rewriteRule -MaxLength 1000
            }
            else {
                ''
            }

            Send-JsonResponse -Response $context.Response -Value (Invoke-AutoApplyCodexTranscription -AfterCreatedAtMs $afterCreatedAtMs -RewriteRule $rewriteRule)
            continue
        }

        if ($requestPath -eq 'api/feedback') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            $result = Write-FeedbackRecord -Payload $payload
            Send-JsonResponse -Response $context.Response -Value $result
            continue
        }

        if ($requestPath -eq 'api/feedback-learning-iteration') {
            if ($context.Request.HttpMethod -ne 'POST') {
                Send-JsonResponse -Response $context.Response -Value ([pscustomobject]@{ error = 'method not allowed' }) -StatusCode 405
                continue
            }

            $body = Read-RequestBody -Request $context.Request
            $payload = if ([string]::IsNullOrWhiteSpace($body)) { [pscustomobject]@{} } else { $body | ConvertFrom-Json }
            $requestedDate = if ($payload.PSObject.Properties.Item('date')) { [string]$payload.date } else { '' }
            Send-JsonResponse -Response $context.Response -Value (Invoke-FeedbackLearningIteration -Date $requestedDate)
            continue
        }

        if ($requestPath -eq 'index.html') {
            $requestPath = 'settings.html'
        }

        if ($requestPath -notin @('review-panel.html', 'settings.html')) {
            Send-TextResponse -Response $context.Response -Text 'not found' -StatusCode 404
            continue
        }

        $filePath = Join-Path $resolvedWebRoot $requestPath
        if (-not (Test-Path -LiteralPath $filePath)) {
            Send-TextResponse -Response $context.Response -Text 'page not found' -StatusCode 404
            continue
        }

        $html = Get-Content -Raw -Encoding UTF8 -LiteralPath $filePath
        Send-TextResponse -Response $context.Response -Text $html -ContentType 'text/html; charset=utf-8'
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }

    $listener.Close()
}

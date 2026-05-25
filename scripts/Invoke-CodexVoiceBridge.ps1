[CmdletBinding()]
param(
    [ValidateSet('ActiveInput', 'Clipboard', 'CodexHistory')]
    [string]$Mode = 'ActiveInput',

    [switch]$NoPaste,

    [switch]$PasteFinal,

    [switch]$Print,

    [switch]$Compare,

    [switch]$Review,

    [switch]$WebReview,

    [string]$ComparisonPath = '',

    [int]$DelayMs = 140,

    [string]$BridgeExe = '',

    [string]$ReviewPagePath = '',

    [int]$ReviewPort = 8793,

    [string]$ReviewServerScript = '',

    [string]$TranscriptionHistoryPath = '',

    [int]$MaxHistoryAgeSeconds = 900,

    [string]$DotnetExe = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($BridgeExe)) {
    $BridgeExe = Join-Path $scriptRoot '..\tools\CodexVoicePromptBridge\publish-self-contained\CodexVoicePromptBridge.exe'
}

if ([string]::IsNullOrWhiteSpace($ReviewPagePath)) {
    $ReviewPagePath = Join-Path $scriptRoot '..\web\review-panel.html'
}

if ([string]::IsNullOrWhiteSpace($ReviewServerScript)) {
    $ReviewServerScript = Join-Path $scriptRoot 'Serve-ReviewPanel.ps1'
}

if ([string]::IsNullOrWhiteSpace($TranscriptionHistoryPath)) {
    $TranscriptionHistoryPath = Join-Path $env:USERPROFILE '.codex\transcription-history.jsonl'
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Clipboard and SendKeys require STA. Run this script with: powershell -STA -NoProfile -ExecutionPolicy Bypass -File ...'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-ClipboardTextSafe {
    for ($i = 0; $i -lt 12; $i++) {
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                return [System.Windows.Forms.Clipboard]::GetText()
            }

            return ''
        }
        catch {
            Start-Sleep -Milliseconds 80
        }
    }

    throw 'Unable to read text from the clipboard.'
}

function Set-ClipboardTextSafe {
    param([Parameter(Mandatory = $true)][string]$Text)

    for ($i = 0; $i -lt 12; $i++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return
        }
        catch {
            Start-Sleep -Milliseconds 80
        }
    }

    throw 'Unable to write text to the clipboard.'
}

function Clear-ClipboardSafe {
    for ($i = 0; $i -lt 12; $i++) {
        try {
            [System.Windows.Forms.Clipboard]::Clear()
            return
        }
        catch {
            Start-Sleep -Milliseconds 80
        }
    }

    throw 'Unable to clear the clipboard.'
}

function Send-KeyChord {
    param([Parameter(Mandatory = $true)][string]$Keys)

    [System.Windows.Forms.SendKeys]::SendWait($Keys)
    Start-Sleep -Milliseconds $DelayMs
}

function Restore-ClipboardTextSafe {
    param(
        [bool]$HadText,
        [string]$Text
    )

    if ($HadText) {
        Set-ClipboardTextSafe -Text $Text
    }
    else {
        Clear-ClipboardSafe
    }
}

function Copy-FocusedInputText {
    param(
        [bool]$HadPreviousClipboardText,
        [string]$PreviousClipboardText
    )

    $captureMarker = "__CODEX_VOICE_BRIDGE_CAPTURE_$([Guid]::NewGuid().ToString('N'))__"
    Set-ClipboardTextSafe -Text $captureMarker

    Send-KeyChord '^a'
    Send-KeyChord '^c'

    $capturedText = ''
    $deadline = (Get-Date).AddMilliseconds([Math]::Max(900, $DelayMs * 8))
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-ClipboardTextSafe
        if ($candidate -ne $captureMarker) {
            $capturedText = $candidate
            break
        }

        Start-Sleep -Milliseconds 60
    }

    if ([string]::IsNullOrWhiteSpace($capturedText) -or $capturedText -eq $captureMarker) {
        Restore-ClipboardTextSafe -HadText $HadPreviousClipboardText -Text $PreviousClipboardText
        throw 'Unable to copy text from the focused input. Keep focus in the Codex voice/input text box, or use an upstream source that writes raw text to the clipboard and run with -Mode Clipboard -PasteFinal.'
    }

    return $capturedText
}

function Get-LatestCodexTranscriptionText {
    if (-not (Test-Path -LiteralPath $TranscriptionHistoryPath)) {
        throw "Codex transcription history was not found: $TranscriptionHistoryPath"
    }

    $latest = $null
    foreach ($line in Get-Content -LiteralPath $TranscriptionHistoryPath -Encoding UTF8 -Tail 80) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        $text = if ($record.PSObject.Properties['text']) { [string]$record.text } else { '' }
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $createdAtMs = if ($record.PSObject.Properties['createdAtMs']) { [int64]$record.createdAtMs } else { 0 }
        if ($null -eq $latest -or $createdAtMs -gt [int64]$latest.createdAtMs) {
            $latest = [pscustomobject]@{
                createdAtMs = $createdAtMs
                text = $text
            }
        }
    }

    if ($null -eq $latest) {
        throw 'No Codex transcription text was found in transcription-history.jsonl.'
    }

    if ($MaxHistoryAgeSeconds -gt 0 -and $latest.createdAtMs -gt 0) {
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $ageSeconds = [int][Math]::Floor(($nowMs - $latest.createdAtMs) / 1000)
        if ($ageSeconds -gt $MaxHistoryAgeSeconds) {
            throw "Latest Codex transcription is stale: $ageSeconds seconds old. Increase -MaxHistoryAgeSeconds if you still want to use it."
        }
    }

    return $latest.text
}

function Normalize-BridgeOutput {
    param([string]$Text)

    $cleaned = if ($null -eq $Text) { '' } else { $Text.Trim() }
    $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '^\s*请执行[:：]\s*', '')
    $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '^\s*请根据以下口述内容理解我的需求，并直接执行[:：]\s*', '')
    return $cleaned.Trim()
}

function Invoke-TextBridge {
    param([Parameter(Mandatory = $true)][string]$Text)

    $projectPath = Join-Path $scriptRoot '..\tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj'
    $inputFile = [System.IO.Path]::GetTempFileName()
    $outputFile = [System.IO.Path]::GetTempFileName()

    try {
        [System.IO.File]::WriteAllText($inputFile, $Text, [System.Text.UTF8Encoding]::new($false))

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true

        if (Test-Path -LiteralPath $BridgeExe) {
            $psi.FileName = (Resolve-Path -LiteralPath $BridgeExe).Path
            $psi.Arguments = "--input-file `"$inputFile`" --output-file `"$outputFile`""
        }
        else {
            $resolvedDotnetExe = ''
            if (-not [string]::IsNullOrWhiteSpace($DotnetExe) -and (Test-Path -LiteralPath $DotnetExe)) {
                $resolvedDotnetExe = $DotnetExe
            }
            else {
                $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
                if ($dotnetCommand) {
                    $resolvedDotnetExe = $dotnetCommand.Source
                }
            }

            if ([string]::IsNullOrWhiteSpace($resolvedDotnetExe)) {
                throw 'Bridge executable was not found, and dotnet SDK was not found on PATH. Publish the bridge executable or install the .NET SDK.'
            }

            $psi.FileName = $resolvedDotnetExe
            $resolvedProjectPath = (Resolve-Path -LiteralPath $projectPath).Path
            $psi.Arguments = "run --project `"$resolvedProjectPath`" --no-launch-profile -- --input-file `"$inputFile`" --output-file `"$outputFile`""
        }

        $process = [System.Diagnostics.Process]::Start($psi)
        $errorOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            throw "Codex voice prompt bridge failed with exit code $($process.ExitCode): $errorOutput"
        }

        $outputText = [System.IO.File]::ReadAllText($outputFile, [System.Text.Encoding]::UTF8)
        return Normalize-BridgeOutput -Text $outputText
    }
    finally {
        Remove-Item -LiteralPath $inputFile, $outputFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ComparisonNotes {
    param(
        [Parameter(Mandatory = $true)][string]$RawText,
        [Parameter(Mandatory = $true)][string]$PolishedText
    )

    $notes = New-Object System.Collections.Generic.List[string]

    if ($RawText -eq $PolishedText) {
        $notes.Add('未检测到明显改写。')
        return $notes
    }

    if ($RawText -match '[體臺灣語說識這個實準確轉輸優錯誤對會話還讓處後與為時長應現態內]' -and
        $PolishedText -notmatch '[體臺灣語說識這個實準確轉輸優錯誤對會話還讓處後與為時長應現態內]') {
        $notes.Add('繁体字已统一为简体字。')
    }

    $leadingFillerPattern = '^((嗯|呃|额|啊|那个|这个|就是|然后|好的|好|那)[，,\s]*)+'
    if ($RawText -match $leadingFillerPattern -and $PolishedText -notmatch $leadingFillerPattern) {
        $notes.Add('去掉了开头的口头禅或犹豫词。')
    }
    elseif ($RawText -match '(嗯|呃|额|啊|那个|这个|就是)' -and
        $PolishedText -notmatch '(嗯|呃|额|啊|那个|这个|就是)') {
        $notes.Add('去掉了常见口头禅或犹豫词。')
    }

    if ($RawText -match '(我希望你|我想让你|我想要你|你来帮我|帮我来|给我一个|给我一份|看一下)' -and
        $PolishedText -match '(请|给出|检查)') {
        $notes.Add('把口语化请求改成更直接的指令句。')
    }

    if (($RawText -match '(上下文|token|提示词|总结要点|节约|节省|高效)' -and
        $PolishedText -match '(节省|压缩|提示词工程|高效|总结要点)') -or
        ($PolishedText.Length -lt [Math]::Max(1, [int]($RawText.Length * 0.85)))) {
        $notes.Add('按提示词化方向压缩冗余表达，尽量节省上下文和 token。')
    }

    if ($RawText -match '(codex|wisper|whisper|type\s*whisper)' -and
        $PolishedText -match '(Codex|Whisper|TypeWhisper)') {
        $notes.Add('统一了产品名或英文术语大小写。')
    }

    if ($RawText -match '(然后另外|另外[，,]|还有[，,])' -or
        (($PolishedText -split '。').Count -gt ($RawText -split '。').Count)) {
        $notes.Add('把明显的多任务口述拆成更清楚的句子。')
    }

    if ($RawText -match '\s{2,}|[，,]\s+|。\s+' -or $PolishedText -match '[，。；：]') {
        $notes.Add('规范了空格、逗号、句号、分号或冒号。')
    }

    if ($notes.Count -eq 0) {
        $notes.Add('做了轻量清理，但没有命中可归类的变化。')
    }

    return $notes
}

function Format-ComparisonReport {
    param(
        [Parameter(Mandatory = $true)][string]$RawText,
        [Parameter(Mandatory = $true)][string]$PolishedText,
        [string]$FinalText = ''
    )

    $notes = Get-ComparisonNotes -RawText $RawText -PolishedText $PolishedText
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('=== Codex 原始识别文本 ===')
    [void]$builder.AppendLine($RawText.Trim())
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('=== 中介整理后文本 ===')
    [void]$builder.AppendLine($PolishedText.Trim())

    if (-not [string]::IsNullOrWhiteSpace($FinalText) -and $FinalText.Trim() -ne $PolishedText.Trim()) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('=== 用户确认后文本 ===')
        [void]$builder.AppendLine($FinalText.Trim())
    }

    [void]$builder.AppendLine()
    [void]$builder.AppendLine('=== 检测到的优化 ===')

    foreach ($note in $notes) {
        [void]$builder.AppendLine("- $note")
    }

    return $builder.ToString().TrimEnd()
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-ReviewServer {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$ReviewPort/health" -UseBasicParsing -TimeoutSec 1
        return ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'ok')
    }
    catch {
        return $false
    }
}

function Ensure-ReviewServer {
    if (Test-ReviewServer) {
        return
    }

    if (-not (Test-Path -LiteralPath $ReviewServerScript)) {
        throw "Review server script was not found: $ReviewServerScript"
    }

    $resolvedServerScript = (Resolve-Path -LiteralPath $ReviewServerScript).Path
    $resolvedWebRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..\web')).Path

    Start-Process `
        -FilePath 'powershell' `
        -WindowStyle Hidden `
        -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $resolvedServerScript,
            '-Port', $ReviewPort,
            '-WebRoot', $resolvedWebRoot
        ) | Out-Null

    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-ReviewServer) {
            return
        }

        Start-Sleep -Milliseconds 150
    }

    throw "Review server did not become ready on http://127.0.0.1:$ReviewPort/."
}

function Get-ReviewPageUrl {
    param(
        [Parameter(Mandatory = $true)][string]$RawText,
        [Parameter(Mandatory = $true)][string]$PolishedText
    )

    if (-not (Test-Path -LiteralPath $ReviewPagePath)) {
        throw "Review page was not found: $ReviewPagePath"
    }

    $payload = [pscustomobject]@{
        rawText = $RawText
        polishedText = $PolishedText
        finalText = $PolishedText
        notes = @(Get-ComparisonNotes -RawText $RawText -PolishedText $PolishedText)
        createdAt = (Get-Date).ToString('o')
    }

    $json = $payload | ConvertTo-Json -Depth 5 -Compress
    $encoded = ConvertTo-Base64Url -Text $json
    Ensure-ReviewServer
    return "http://127.0.0.1:$ReviewPort/review-panel.html#payload=$encoded"
}

function Show-ReviewDialog {
    param(
        [Parameter(Mandatory = $true)][string]$RawText,
        [Parameter(Mandatory = $true)][string]$PolishedText
    )

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Codex 语音输入确认'
    $form.StartPosition = 'CenterScreen'
    $form.Size = [System.Drawing.Size]::new(980, 760)
    $form.MinimumSize = [System.Drawing.Size]::new(760, 620)
    $form.TopMost = $true

    $font = [System.Drawing.Font]::new('Microsoft YaHei UI', 10)
    $form.Font = $font

    $table = [System.Windows.Forms.TableLayoutPanel]::new()
    $table.Dock = 'Fill'
    $table.Padding = [System.Windows.Forms.Padding]::new(12)
    $table.ColumnCount = 1
    $table.RowCount = 7
    $table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 28)) | Out-Null
    $table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 24)) | Out-Null
    $table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 28)) | Out-Null
    $table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 24)) | Out-Null
    $table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 28)) | Out-Null
    $table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent, 38)) | Out-Null
    $table.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute, 52)) | Out-Null
    $form.Controls.Add($table)

    function New-Label {
        param([string]$Text)
        $label = [System.Windows.Forms.Label]::new()
        $label.Text = $Text
        $label.Dock = 'Fill'
        $label.TextAlign = 'MiddleLeft'
        return $label
    }

    function New-TextBox {
        param(
            [string]$Text,
            [bool]$ReadOnly
        )

        $box = [System.Windows.Forms.TextBox]::new()
        $box.Multiline = $true
        $box.ScrollBars = 'Vertical'
        $box.AcceptsReturn = $true
        $box.AcceptsTab = $true
        $box.WordWrap = $true
        $box.Dock = 'Fill'
        $box.Text = $Text
        $box.ReadOnly = $ReadOnly
        return $box
    }

    $rawLabel = New-Label -Text 'Codex 原始识别文本'
    $rawBox = New-TextBox -Text $RawText -ReadOnly $true
    $polishedLabel = New-Label -Text '中介自动整理文本'
    $polishedBox = New-TextBox -Text $PolishedText -ReadOnly $true
    $finalLabel = New-Label -Text '最终要回填的文本（可编辑）'
    $finalBox = New-TextBox -Text $PolishedText -ReadOnly $false

    $buttonPanel = [System.Windows.Forms.FlowLayoutPanel]::new()
    $buttonPanel.Dock = 'Fill'
    $buttonPanel.FlowDirection = 'RightToLeft'
    $buttonPanel.WrapContents = $false

    $applyButton = [System.Windows.Forms.Button]::new()
    $applyButton.Text = '确认并回填'
    $applyButton.Width = 120
    $applyButton.Height = 34

    $copyButton = [System.Windows.Forms.Button]::new()
    $copyButton.Text = '只复制'
    $copyButton.Width = 100
    $copyButton.Height = 34

    $useRawButton = [System.Windows.Forms.Button]::new()
    $useRawButton.Text = '使用原文'
    $useRawButton.Width = 100
    $useRawButton.Height = 34

    $usePolishedButton = [System.Windows.Forms.Button]::new()
    $usePolishedButton.Text = '使用整理文本'
    $usePolishedButton.Width = 120
    $usePolishedButton.Height = 34

    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Text = '取消'
    $cancelButton.Width = 90
    $cancelButton.Height = 34

    $script:reviewAction = 'Cancel'
    $script:reviewText = $PolishedText

    $applyButton.Add_Click({
        $script:reviewAction = 'Apply'
        $script:reviewText = $finalBox.Text
        $form.Close()
    })

    $copyButton.Add_Click({
        $script:reviewAction = 'Copy'
        $script:reviewText = $finalBox.Text
        $form.Close()
    })

    $useRawButton.Add_Click({
        $finalBox.Text = $rawBox.Text
        $finalBox.Focus()
        $finalBox.SelectionStart = $finalBox.TextLength
    })

    $usePolishedButton.Add_Click({
        $finalBox.Text = $polishedBox.Text
        $finalBox.Focus()
        $finalBox.SelectionStart = $finalBox.TextLength
    })

    $cancelButton.Add_Click({
        $script:reviewAction = 'Cancel'
        $form.Close()
    })

    $buttonPanel.Controls.Add($applyButton)
    $buttonPanel.Controls.Add($copyButton)
    $buttonPanel.Controls.Add($useRawButton)
    $buttonPanel.Controls.Add($usePolishedButton)
    $buttonPanel.Controls.Add($cancelButton)

    $table.Controls.Add($rawLabel, 0, 0)
    $table.Controls.Add($rawBox, 0, 1)
    $table.Controls.Add($polishedLabel, 0, 2)
    $table.Controls.Add($polishedBox, 0, 3)
    $table.Controls.Add($finalLabel, 0, 4)
    $table.Controls.Add($finalBox, 0, 5)
    $table.Controls.Add($buttonPanel, 0, 6)

    $form.AcceptButton = $applyButton
    $form.CancelButton = $cancelButton
    $form.Add_Shown({ $finalBox.Focus(); $finalBox.SelectionStart = $finalBox.TextLength })

    [void]$form.ShowDialog()

    return [pscustomobject]@{
        Action = $script:reviewAction
        Text = $script:reviewText
    }
}

$hadPreviousClipboardText = $false
$previousClipboardText = ''

if ($Mode -eq 'ActiveInput') {
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $previousClipboardText = Get-ClipboardTextSafe
            $hadPreviousClipboardText = $true
        }
    }
    catch {
        $hadPreviousClipboardText = $false
        $previousClipboardText = ''
    }

    $rawText = Copy-FocusedInputText -HadPreviousClipboardText $hadPreviousClipboardText -PreviousClipboardText $previousClipboardText
}
elseif ($Mode -eq 'CodexHistory') {
    $rawText = Get-LatestCodexTranscriptionText
}
else {
    $rawText = Get-ClipboardTextSafe
}

if ([string]::IsNullOrWhiteSpace($rawText)) {
    throw 'No recognized text was found. Focus the Codex voice/input text box or copy text to the clipboard first.'
}

$polishedText = Invoke-TextBridge -Text $rawText
if ([string]::IsNullOrWhiteSpace($polishedText)) {
    throw 'The bridge returned empty text.'
}

$finalText = $polishedText
$shouldReplaceFocusedInput = ($Mode -eq 'ActiveInput' -and -not $NoPaste)
$shouldPasteFinalAtCursor = (($Mode -eq 'Clipboard' -or $Mode -eq 'CodexHistory') -and $PasteFinal -and -not $NoPaste)

if ($WebReview) {
    $reviewUrl = Get-ReviewPageUrl -RawText $rawText -PolishedText $polishedText
    Set-ClipboardTextSafe -Text $reviewUrl

    if ($Print -or -not $Compare) {
        Write-Output $reviewUrl
    }

    if ($Compare -or -not [string]::IsNullOrWhiteSpace($ComparisonPath)) {
        $comparisonReport = Format-ComparisonReport -RawText $rawText -PolishedText $polishedText

        if ($Compare) {
            Write-Output $comparisonReport
        }

        if (-not [string]::IsNullOrWhiteSpace($ComparisonPath)) {
            $resolvedComparisonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ComparisonPath)
            $comparisonParent = Split-Path -Parent $resolvedComparisonPath

            if (-not [string]::IsNullOrWhiteSpace($comparisonParent) -and -not (Test-Path -LiteralPath $comparisonParent)) {
                New-Item -ItemType Directory -Path $comparisonParent | Out-Null
            }

            Set-Content -LiteralPath $resolvedComparisonPath -Encoding UTF8 -Value $comparisonReport
        }
    }

    exit 0
}

if ($Review) {
    $reviewResult = Show-ReviewDialog -RawText $rawText -PolishedText $polishedText

    if ($reviewResult.Action -eq 'Cancel') {
        if ($Mode -eq 'ActiveInput') {
            Restore-ClipboardTextSafe -HadText $hadPreviousClipboardText -Text $previousClipboardText
        }

        exit 0
    }

    $finalText = ([string]$reviewResult.Text).Trim()
    if ([string]::IsNullOrWhiteSpace($finalText)) {
        throw 'The reviewed final text is empty.'
    }

    if ($reviewResult.Action -eq 'Copy') {
        $shouldReplaceFocusedInput = $false
        $shouldPasteFinalAtCursor = $false
    }
}

Set-ClipboardTextSafe -Text $finalText

if ($shouldReplaceFocusedInput) {
    Send-KeyChord '^a'
    Send-KeyChord '^v'
}
elseif ($shouldPasteFinalAtCursor) {
    Send-KeyChord '^v'
}

if ($Compare -or -not [string]::IsNullOrWhiteSpace($ComparisonPath)) {
    $comparisonReport = Format-ComparisonReport -RawText $rawText -PolishedText $polishedText -FinalText $finalText

    if ($Compare) {
        Write-Output $comparisonReport
    }

    if (-not [string]::IsNullOrWhiteSpace($ComparisonPath)) {
        $resolvedComparisonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ComparisonPath)
        $comparisonParent = Split-Path -Parent $resolvedComparisonPath

        if (-not [string]::IsNullOrWhiteSpace($comparisonParent) -and -not (Test-Path -LiteralPath $comparisonParent)) {
            New-Item -ItemType Directory -Path $comparisonParent | Out-Null
        }

        Set-Content -LiteralPath $resolvedComparisonPath -Encoding UTF8 -Value $comparisonReport
    }
}

if ($Print) {
    Write-Output $finalText
}

# Development Handbook

本文是当前项目 `语音输入提炼矫正` 的维护手册。

## 1. 项目定位

本项目当前主线是优化 Windows 上的 Codex 中文语音输入链路：

- 优先读取 Codex 本地语音历史 `%USERPROFILE%\.codex\transcription-history.jsonl`，该文件会记录 Codex 语音识别结果。
- 可控上游输入源作为备用，可以是 TypeWhisper、本地 Whisper/Sherpa、Windows 语音输入到受控草稿框，或其他可自动输出文本的工具。
- 整理内容包括繁转简、轻量纠错、去口头禅、常见英文术语音译纠正、要点总结、上下文压缩、节省 token 和提示词化。
- 把整理后的文本复制到剪贴板，并由用户显式切回有焦点的 Codex 输入框后粘贴或替换，尽量接近飞书语音输入那种“先识别、再整理”的体验。

本项目不追求复杂 UI，核心是把“Codex 本地语音历史/可控转写、整理、粘贴到 Codex”做成可验证、可替换、可维护的工作流。Codex 输入框草稿不能当作稳定可读取对象，但 Codex 语音历史文件可以作为当前优先入口。

TypeWhisper / Whisper 开源软件曾从主链路撤下；在“不能稳定读取 Codex 输入框”的前提下，它们重新成为可控上游输入源候选，但不应在用户未确认时自动启动或重配。

## 2. 设计原则

### 2.1 先尊重当前用户目标

工作优先级：

1. 用户当前对话里的明确要求。
2. 当前项目根目录的 `AGENTS.md`。
3. 当前项目文档和本地配置。
4. 历史 TypeWhisper 方案。

当这些规则冲突时，优先满足用户当前明确要求；涉及安全、隐私、不可逆改动或凭据时，先说明风险并请求确认。

### 2.2 Codex 语音历史优先

优先读取 Codex 本地语音历史。不要把 Codex 输入框当成可稳定读取的普通文本框；只有在用户明确保持焦点、并接受失败可能性时，才使用 `ActiveInput` 复制/替换路径。

当前默认链路是：

```text
Codex transcription-history.jsonl -> local bridge -> clipboard/web review -> focused Codex text field
```

2026-05-25 只读调查补充：`codex://new?prompt=<URL编码文本>&path=<可选目录>` 在协议注册、主进程路由和 composer `setPromptText` 代码里有证据链，可作为“新线程 composer 预填”的半可用入口；但它不写当前已有对话的 composer。未发现可公开、稳定、安全写入当前 composer 的 IPC、named pipe、本地服务或本地存储入口。

备用链路是：

```text
controllable upstream ASR/text source -> clipboard/file -> local bridge -> clipboard -> focused Codex text field
```

读取 Codex 输入框当前草稿仍只能作为实验/兼容路径：

```text
Codex built-in ASR -> focused Codex text field -> Ctrl+A/C attempt -> local bridge -> Ctrl+A/V attempt
```

不要把 `prompt-history`、Electron LevelDB、SQLite 线程表或 `\\.\pipe\codex-ipc` 当作回填入口。它们要么不是当前草稿状态，要么属于内部私有通道；真实写入这些位置需要关闭 Codex、完整备份并单独确认，当前不作为项目路线。

TypeWhisper 过去看起来能“自动填入 Codex 输入框”，本质不是 Codex 专用直写接口，而是通用 Windows 粘贴链路：开始录音时记录前台窗口，识别结束后把结果写入剪贴板，再 `SetForegroundWindow` 切回目标窗口并发送 `Ctrl+V`。本项目可以借用这条技术路线，但要继续把它描述为“窗口级焦点恢复 + 剪贴板粘贴”，不要描述成绕过焦点写当前 composer。

2026-05-25 已在 `scripts/Serve-ReviewPanel.ps1` 增加实验实现：`/api/latest-codex-transcription` 发现新转写时记录 `pasteTarget`，`/api/apply-final-text` 默认使用 `useCapturedTarget: true`，粘贴前先尝试把捕获窗口切回前台。用户实测表明，如果右侧审核页和 composer 位于同一个 Codex 桌面窗口，单纯 `SetForegroundWindow` 只会回到 Codex 窗口，焦点仍可能停在审核页；因此同日补充 UI Automation 焦点恢复：目标窗口是 Codex 时，先查找底部可聚焦 `ProseMirror` composer 并 `SetFocus()`，确认焦点落在 composer 后才发送 `Ctrl+A`、`Ctrl+V`。如果未找到或未成功聚焦 composer，应只保留剪贴板内容并跳过按键粘贴，避免改写审核页文本。服务以 `-STA` 启动且回填延迟为 0 秒时，优先在服务进程内直接写剪贴板、聚焦和发送按键，减少额外启动隐藏 PowerShell 的体感延迟。

### 2.3 本地、免费、低延迟优先

默认优先选择：

- 本地可运行。
- 免费或无需新增账号额度。
- 延迟低。
- 容易替换和回滚。

引入云端 API 前要明确说明：

- 是否需要 API key。
- 免费额度和速率限制可能变化。
- 文本会发送到第三方服务。
- 断网或额度耗尽时的降级路径。

### 2.4 不夸大中介能力

当前中介是规则级整理，不是语义级 LLM 改写。

它适合处理：

- 繁体转简体。
- 常见口头禅。
- 常见开头表达，如“我希望你就是”。
- 简单任务句改写，如“给我一个”改成“给出一个”。
- 常见英文术语音译纠正，如 Codex、Whisper、GitHub、PowerShell、token 等。
- 在保留核心意图的前提下压缩冗余口述；当整理规则要求“整体意图、重组、拆分、总结要点”时，优先保留 1、2、3 点的结构化表达，但不再自动添加 `请执行：` 这类标题前缀，也不把整理规则本身追加成“要求：...”。

它仍不能保证像 LLM 一样理解所有长段口述。当前压缩和结构化是规则级、启发式；要做到稳定的语义级总结，需要接入 LLM API，或等待 Codex 提供可编程的语音识别结果钩子。

### 2.5 该验证就验证

修改后至少做最小闭环验证，而不只是改文档：

- 整理器可以发布或运行。
- 示例中文输入输出不乱码。
- 剪贴板模式可以运行。
- 如果修改回填脚本，确认 `powershell -STA` 路径可用。
- 只有涉及 TypeWhisper 备用链路时，才需要验证 TypeWhisper API 状态。

## 3. 当前关键文件

- `AGENTS.md`：Codex 工作规则、项目边界和协作方法。
- `TypeWhisper-Codex-Workflow.md`：当前 Codex 自带语音识别中介工作流和方案取舍。
- `scripts/Invoke-CodexVoiceBridge.ps1`：读取 Codex 语音历史/剪贴板/尝试复制焦点文本、调用整理器、写回剪贴板、粘贴到输入框的中介脚本。
- `scripts/Serve-ReviewPanel.ps1`：本地审核页服务，供 Codex in-app browser 打开 `http://127.0.0.1:8793/review-panel.html`，同时提供校准中心 API，包括 `/api/latest-codex-transcription`、`/api/polish` 和 `/api/apply-final-text`。
- `scripts/Open-VoiceCalibrationCenter.ps1`：启动固定配置入口 `http://127.0.0.1:8793/` 的语音校准中心。
- `scripts/Invoke-VoiceFeedbackDailyIteration.ps1`：持续学习每日迭代脚本，读取本地差异记录并生成候选个人化规则。
- `scripts/Invoke-VoiceFeedbackCleanup.ps1`：持续学习本地日志清理脚本，按保留天数、总容量和单日样本数清理 `.codex-tmp\voice-feedback\yyyy-MM-dd.jsonl`。
- `scripts/Register-VoiceFeedbackDailyTask.ps1`：可选的 Windows 任务计划注册脚本；只有用户确认后才运行。
- `tools/CodexVoicePromptBridge/Program.cs`：Codex 语音输入文本整理器源码。
- `tools/CodexVoicePromptBridge/publish-self-contained/CodexVoicePromptBridge.exe`：当前可直接调用的本地整理器。
- `config/onboarding-topic-prompts.json`：安装期分层话题式自由口述提示，按轻松聊天、日常规划、工作任务和思考推理分层。
- `config/voice-feedback-settings.json`：持续学习开关、每日迭代时间、固定配置入口偏好、主动校准热键、自动应用开关、记录目录、清理保留策略和隐私边界设置，默认关闭持续学习和自动应用。
- `docs/onboarding-calibration.md`：安装期分层话题校准和个人语言习惯配置设计草案。
- `web/review-panel.html`：Codex 右侧浏览器可打开的本地审核面板，展示原始识别、自动整理和可编辑最终文本。
- `web/settings.html`：固定配置入口的语音校准中心，包含隐私说明、配置概览、持续学习、访问与启动、主动校准；“整理文本规则”会直接传给 `CodexVoicePromptBridge.exe`，保存后成为下次默认规则；“自动应用到输入框”开启后会持续轮询 Codex 最新语音历史，默认每 500ms 检查一次，发现新转写后调用 `/api/auto-apply-codex-transcription` 自动整理并尝试回填 Codex composer；页面顶部会显示发送保护提示，提醒用户等状态显示“可以发送”后再点击 Codex 发送；“开始校正”保留为手动校准流程，会在前台每 3 秒轮询 Codex 最新语音历史，发现新转写后自动导入整理；“保存样本”会写入本机 JSONL、触发自动清理并展示保存路径；“更新规则”会读取本机样本生成候选替换文件、触发自动清理并展示候选规则路径；后续 `/api/polish` 和自动应用接口会把候选替换作为精确替换应用到自动整理文本；“确认回填”会把发送给 Codex 的最终文本写入剪贴板，并尝试聚焦 Codex 底部 composer，成功后先全选原内容再粘贴；“发送后旁路确认”会在回填后短时间轮询 Codex 本地 `sessions\...\*.jsonl` 用户消息记录，命中相似新增消息后同步最终文本并保存样本；“回填校验结果”显示最近一次回填状态、路径、目标窗口、延迟和跳过原因；备用入口降级为默认收起的高级诊断工具。
- `tools/TypeWhisperT2S/`：旧 TypeWhisper 方案的繁转简和轻量整理工具，保留为参考。
- `typewhisper-win/`：上游 TypeWhisper 源码备份和可能的备用开发基础。

## 4. 推荐工作流

1. 先确认用户要解决的是识别速度、识别准确率、提示词整理质量，还是回填自动化。
2. 读取当前文档和相关脚本。
3. 先判断能否使用 Codex 本地语音历史；只有用户选择 TypeWhisper 或本地 Whisper 方案时才检查对应状态。
4. 小范围修改整理规则或回填脚本。
5. 跑最小验证。
6. 把重要结论写回项目文档。
7. 本项目产物不实现回复朗读/TTS；但 Codex 对用户的回复播报仍按 `外部 TTS 工作流` 项目的既有规则执行。需要播报时直接调用那个项目的脚本，不在本项目新增包装器或复制播报逻辑。

## 5. 验证清单

发布本地整理器：

```powershell
& "dotnet" publish "tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o "tools\CodexVoicePromptBridge\publish-self-contained"
```

验证整理器 UTF-8 文件输入输出：

```powershell
$inputFile = New-TemporaryFile
$outputFile = New-TemporaryFile
[System.IO.File]::WriteAllText($inputFile, "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。", [System.Text.UTF8Encoding]::new($false))
& "tools\CodexVoicePromptBridge\publish-self-contained\CodexVoicePromptBridge.exe" --input-file $inputFile --output-file $outputFile
[System.IO.File]::ReadAllText($outputFile, [System.Text.Encoding]::UTF8)
Remove-Item -LiteralPath $inputFile, $outputFile -Force
```

验证剪贴板模式：

```powershell
Set-Clipboard -Value "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Print
```

验证上游剪贴板文本粘贴路径：

```powershell
Set-Clipboard -Value "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -PasteFinal -NoPaste -Print
```

验证 Codex 本地语音历史读取：

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode CodexHistory -NoPaste -Print
```

验证原文/整理后对照：

```powershell
Set-Clipboard -Value "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Compare
```

人工验证确认窗口：

```powershell
Set-Clipboard -Value "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Review -Compare
```

确认窗口需要显示 Codex 原始识别文本、中介自动整理文本和可编辑的最终文本。用户点击“确认并回填”时写回剪贴板并按当前模式回填；点击“只复制”时只写剪贴板；点击“取消”时不提交文本。`ActiveInput` 模式下取消会尽量恢复打开窗口前的剪贴板文本。

验证网页审核链接：

```powershell
Set-Clipboard -Value "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -WebReview
```

该命令应启动本地审核页服务，输出一个 `http://127.0.0.1:8793/review-panel.html#payload=...` 链接，并把链接放入剪贴板。用 Codex in-app browser 打开后，页面应显示原始识别、整理结果、可编辑最终文本和保存按钮。

用户点击“保存选择”后，页面应把 JSON 写入隐藏字段 `#reviewResultJson`，供 Codex 读取。`localStorage.codexVoiceReviewResult` 只是辅助缓存，不作为唯一读回来源。

验证持续学习设置和差异记录：

```powershell
Invoke-WebRequest -Uri "http://127.0.0.1:8793/api/settings" -UseBasicParsing
```

固定校准中心地址：

```text
http://127.0.0.1:8793/
```

该页面最前面必须展示“隐私与数据使用”：本功能仅处理 Codex 语音输入链路中的文本，不监听键盘、鼠标或普通手动输入，不采集屏幕操作，也不把语音校准记录挪作语音输入优化以外的用途。页面随后提供“配置概览”，使首次使用者能够理解持续学习、访问与启动、主动校准分别负责什么。页面级“保存设置”不应归属到某个单独栏目。持续学习、差异记录和每日迭代时间是同一个功能组；每日时间输入应在持续学习关闭时禁用。访问与启动里的“固定配置入口”只负责固定配置网页地址；“随 Codex 启动”表示启动 Codex 时自动启动本地校准服务并打开固定配置网页，真正注册启动任务需要用户确认。主动校准由用户选择话题，可靠主路径是“开始校正”：页面记录当前最新语音历史时间戳，然后每 3 秒通过 `/api/latest-codex-transcription` 查询 `.codex\transcription-history.jsonl` 是否有新记录；发现新转写后自动导入并整理，最长等待 2 分钟。高级诊断工具保留“导入 Codex 最新语音历史”和“手动导入识别结果”等兜底能力，但主流程正常时默认收起。自动应用由用户明确开启：“自动应用到输入框”会按配置间隔调用 `/api/auto-apply-codex-transcription`，默认 500ms 检查一次，只读取 Codex 语音历史中的新记录，不复制当前焦点内容，不读取普通手动输入；发现新转写后由服务端完成整理、候选替换、剪贴板写入和 Codex composer 回填尝试。页面不能拦截 Codex 的发送按钮，也不能直接获知用户是否已经点击发送或最终发送了什么；因此自动应用开启时必须显示保护提示，提醒用户语音结束后等状态显示“可以发送”再点击 Codex 发送。校准样本以本页“发送给 Codex 的最终文本”为准；如果回填后又在 Codex 输入框里修改，保存样本前需要同步回本页。等待期间必须提示用户不要切换对话、跳转页面或移动焦点；如果语音窗口一直显示等待，先停在当前对话。导入后应自动生成整理文本，并在“发送给 Codex 的最终文本”为空时填入初稿。校准维护按钮只保留：“保存样本”写入本地 JSONL，“更新规则”基于已保存样本生成候选替换；更新后 `/api/polish` 和自动应用接口会读取候选规则文件，把候选作为保守的精确替换应用到自动整理文本，但不改写 `CodexVoicePromptBridge` 的永久源码规则。默认整理规则应强调：总结要点、压缩上下文、节省 token，并在不丢关键约束的前提下让文本更符合 AI 提示词工程；对“然后啊”等口头禅应尽量去除或归一化；对“是否按照……要求做到了”这类口语倒装句，应重组为“是否做到了……要求”；但不自动添加 `请执行：` 标题前缀，也不把整理规则本身追加成“要求：...”。回填到 Codex 输入框仍不能描述为后台直写当前 composer；自动应用和“确认回填”都是写入剪贴板后尝试聚焦 Codex 底部 composer，并在聚焦成功后发送一次 `Ctrl+A` + `Ctrl+V`。回填后应在本页展示服务返回的校验状态、路径、目标窗口、延迟和跳过原因。

持续学习必须默认关闭。开启后，只允许审核页保存事件和用户主动保存的校准样本写入 `.codex-tmp\voice-feedback\yyyy-MM-dd.jsonl`；不要新增键盘监听、鼠标监听或全局输入监控。保存样本和每日迭代后必须触发自动清理：默认保留最近 30 天、总量最多 20 MB、单日最多 200 条样本，只清理本项目 `voice-feedback` 目录下按日期命名的 JSONL 学习日志，不清理 Codex 自带 `transcription-history.jsonl`。验证语音热键接口时优先用 `/api/voice-hotkey` 或 `/api/voice-auto-capture` 的 `dryRun` 请求，避免测试过程抢占用户焦点；真实自动取回测试通过 Codex 语音历史文件完成，不应再依赖复制当前焦点。

验证持续学习清理脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-VoiceFeedbackCleanup.ps1" -Json
```

验证每日迭代脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-VoiceFeedbackDailyIteration.ps1" -Force -Date "2026-05-24"
```

脚本只生成候选个人化规则，不自动修改 `CodexVoicePromptBridge` 的永久规则。若未来要自动应用候选规则，必须先增加人工审核门槛和回滚方案。

可选注册每日计划任务：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Register-VoiceFeedbackDailyTask.ps1"
```

注册任务会改 Windows 任务计划程序，只有用户明确确认后才执行。

回填模式人工验证：

1. 使用 Codex 自带语音录入得到一段识别文本。
2. 打开 Codex 输入框，保持焦点在要插入的位置。
3. 运行 `scripts\Invoke-CodexVoiceBridge.ps1 -Mode CodexHistory -PasteFinal`。
4. 确认整理后的提示词被粘贴到 Codex 输入框。

`ActiveInput` 复制/替换模式只作为兼容验证：如果 Codex 输入框没有真的响应复制，脚本应报错，不得用旧剪贴板文本冒充识别结果。

网页回填接口验证：

```powershell
$json = @{ text = "回填接口测试文本"; sendPaste = $false; pasteDelaySeconds = 3 } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
Invoke-WebRequest -Uri "http://127.0.0.1:8793/api/apply-final-text" -Method POST -ContentType "application/json; charset=utf-8" -Body $bytes -UseBasicParsing
```

自动化测试只验证 `sendPaste = false` 的复制能力，避免测试过程向当前焦点发送粘贴按键。真实确认回填需要人工验证：点击“确认回填”后，确认服务会优先尝试切回此前捕获的 Codex 窗口，并在 Codex 窗口内用 UI Automation 聚焦底部 `ProseMirror` composer；如果聚焦失败，脚本应跳过按键粘贴并只保留剪贴板文本。0 秒延迟路径应优先返回 `pastedImmediately = true`，表示服务进程已直接尝试粘贴；人工验证时确认“发送给 Codex 的最终文本”进入 Codex 输入框，而不是回写到审核页 textarea。

## 6. 隐私和安全

不要把以下内容写进共享文档或可提交文件：

- API key、token、账号凭据。
- 私人工作流中的敏感内容。
- 大量历史转写内容。
- 不必要的本机日志。

当前中介默认本地处理，不把文本发送到第三方服务。未来如果接入 LLM API，必须先说明隐私边界和降级路径。

持续学习记录可能包含用户语音输入文本及用户确认后准备发送给 Codex 的最终文本，只能在用户开启后写入本地 `.codex-tmp\voice-feedback\`。发送后旁路确认只读 Codex 本机会话 JSONL 中回填后新增的用户消息，用来校准“最终文本”，不监听键盘、鼠标、屏幕或普通输入流。这些记录和生成的候选规则不应上传、共享、提交或挪作语音校准以外的用途。

## 7. 后续路线

优先级建议：

1. 先稳定 Codex 本地语音历史 + 网页“自动应用到输入框”链路。
2. 用真实口述样本补充 `CodexVoicePromptBridge` 的规则。
3. 做安装期分层话题校准：轻松生活、日常规划、工作任务和高负荷思考分别采样，避免把用户的语言习惯压成一种统一规则。
4. 做持续学习闭环：只在语音审核页保存时记录“原始识别/自动整理/最终文本”差异，并每日生成候选个人化规则。
5. 评估是否需要快捷方式、PowerToys 或 AutoHotkey 来绑定全局热键。
6. 如果规则整理不够聪明，再接入可开关的 LLM 重写层。
7. 如果未来出现明显优于 Codex 自带识别、且免费低延迟的开源 ASR，再重新评估 TypeWhisper/本地 ASR 技术路线。
8. 如果 Codex 后续提供语音识别结果 API 或插件钩子，再从剪贴板/按键模拟升级为事件驱动。

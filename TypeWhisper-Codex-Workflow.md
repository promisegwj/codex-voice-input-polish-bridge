# Codex 自带语音识别中介工作流

## 当前主线

2026-05-24 的测试结论：不能再把“自动读取 Codex 输入框里的未发送文本”当作稳定主路径。Codex 桌面端当前没有公开的当前 composer 写入 API、插件钩子或可嵌入网页的事件接口，能够稳定交给脚本处理的边界只有剪贴板、文件、显式热键和前台按键模拟。

2026-05-25 的只读复查结论：Windows 协议注册和前端 bundle 里存在 `codex://new?prompt=...` / `codex://threads/new?prompt=...` 到 `prefillPrompt` / `setPromptText` 的证据链，可作为“新线程 composer 预填”的半可用入口；但它不能写入当前已有对话的 composer，也没有替代剪贴板/焦点回填。IPC、named pipe、stdio app-server 和本地存储里没有发现可安全稳定写入当前 composer 的公开或半公开接口。

因此当前主线调整为：

```text
Codex 本地语音历史 / 可控上游输入源 -> 本地中介整理 -> 自动应用回填或网页审核 -> 聚焦 Codex 输入框后粘贴或替换
```

新的优先入口是 Codex 自己写入的本地语音历史：

```text
%USERPROFILE%\.codex\transcription-history.jsonl
```

该文件已验证会记录 Codex 语音识别结果，字段包含 `id`、`createdAtMs` 和 `text`。因此不再需要从 Codex 输入框抓草稿；本项目可以读取最新语音历史，把它导入网页或命令行整理链路。“可控上游输入源”仍可作为备用，比如 TypeWhisper、本地 Whisper/Sherpa、Windows 语音输入到受控草稿框，或其他能够把原始转写写入剪贴板/文件的工具。

## 已新增的中介

文本整理器：

```text
.\tools\CodexVoicePromptBridge\publish-self-contained\CodexVoicePromptBridge.exe
```

源码：

```text
.\tools\CodexVoicePromptBridge\Program.cs
```

回填脚本：

```text
.\scripts\Invoke-CodexVoiceBridge.ps1
```

它做的事：

1. 优先读取 Codex 本地语音历史或当前剪贴板中的上游原始语音文本；`ActiveInput` 模式下才尝试从当前焦点控件复制文本。
2. 调用本地 `CodexVoicePromptBridge.exe` 做繁转简、口头禅清理、常见表达修正、常见英文术语音译纠正、要点总结、上下文压缩和提示词化；网页“整理文本规则”会通过 `--rewrite-rule` 传入整理器，未传入时使用同一条默认规则。
3. 把整理后的文本写回剪贴板。
4. 在 `-PasteFinal` 或 `ActiveInput` 模式下先把结果写入剪贴板，再依赖当前有焦点的输入框执行前台粘贴；网页校准中心提供“自动应用到输入框”和“确认回填”。自动应用模式会轮询 Codex 语音历史，发现新转写后直接整理并尝试回填；确认回填用于把发送给 Codex 的最终文本写入剪贴板，并在聚焦 Codex 输入框后先全选原内容再粘贴这段最终文本。

## 推荐使用方式

推荐主路径：让上游语音工具把原始识别文本放入剪贴板，保持 Codex 输入框焦点在要插入的位置，然后运行：

```powershell
powershell -WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -PasteFinal
```

这条路径不读取 Codex 输入框，只把整理后的最终文本写入剪贴板，并由用户保持或切回 Codex 输入框焦点后粘贴进去，避免“复制 Codex 草稿失败”导致整条链路失效。

Codex 本地语音历史路径：使用 Codex 语音识别后，保持 Codex 输入框焦点在要插入的位置，然后运行：

```powershell
powershell -WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode CodexHistory -PasteFinal
```

校准网页新增“自动应用到输入框”开关：开启后，页面会按配置的检查间隔调用 `/api/auto-apply-codex-transcription`，默认每 500ms 检查一次，只读取 Codex 本地语音历史中的新记录；服务端发现新转写后会调用整理器、应用本地候选替换、写入剪贴板，并立即尝试切回捕获到的 Codex 窗口、聚焦底部 composer、发送 `Ctrl+A` + `Ctrl+V`。如果没有捕获到目标或聚焦失败，则只保留剪贴板文本，不误写审核页。这条路线是当前优先体验路线。页面会显示保护提示：自动应用开启时，语音结束后应等状态显示“可以发送”再点击 Codex 发送，否则可能先发出原始识别文本。

校准网页仍保留“开始校正”按钮：点击后记录当前最新语音历史位置，然后每 3 秒调用 `/api/latest-codex-transcription` 检查一次新记录；发现新转写后自动导入并整理，最多等待 2 分钟。页面也保留“导入 Codex 最新语音历史”按钮，供用户手动拉取最新记录。这些路径都不复制当前网页或输入框。原始识别文本区域只读，用于保持和导入的 Codex 语音文本一致。点击“确认回填”后，页面会把发送给 Codex 的最终文本写入剪贴板，并立即尝试切回此前捕获的 Codex 窗口、聚焦底部 composer，然后发送 `Ctrl+A` + `Ctrl+V`；如果没有捕获到目标或聚焦失败，则只保留剪贴板文本，不改写审核页。

实验/兼容路径：在 Codex 语音窗口识别完成后，保持焦点在识别结果/输入框内，然后运行：

```powershell
powershell -WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1"
```

建议把主路径命令做成 Windows 快捷方式，并给快捷方式绑定一个热键，例如 `Ctrl+Alt+D`。快捷方式的运行方式建议设为“最小化”或隐藏窗口，避免 PowerShell 窗口抢焦点。

只处理剪贴板、不自动粘贴时使用：

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Print
```

需要查看“Codex 原始识别文本”和“中介整理后文本”的对照时使用：

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Compare
```

需要像计划模式一样弹出确认窗口，让用户查看原始识别、自动整理结果，并手动调整最终文本时使用：

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Review
```

校准采集时推荐使用剪贴板 + 确认窗口：

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Review -Compare
```

如果要在 Codex 右侧浏览器里审核，而不是弹出 PowerShell 窗口，可以生成本地网页审核链接：

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -WebReview
```

该命令会把审核页链接放到剪贴板并输出。Codex 可以用 in-app browser 打开该链接；用户在页面里保存选择后，Codex 再读取页面里的 `reviewResultJson` 隐藏字段来取得最终文本。页面也会尽量写入 `localStorage.codexVoiceReviewResult`，但读回时不依赖它。

审核页通过本地服务打开，默认地址类似：

```text
http://127.0.0.1:8793/review-panel.html#payload=...
```

原因是 Codex in-app browser 不允许直接打开 `file://` 本地文件链接。

固定校准中心入口：

```text
http://127.0.0.1:8793/
```

也可以用脚本启动并输出固定配置入口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Open-VoiceCalibrationCenter.ps1"
```

校准中心同时包含两类校准：

1. 自动对比校准：默认关闭。持续学习、差异记录和每日自动迭代时间是同一个功能组；用户开启持续学习后，审核页只会在“保存选择”时记录当前语音审核链路的差异：Codex 原始识别文本、中介自动整理文本、用户确认后准备发送给 Codex 的最终文本。
2. 主动校准：用户在同一个网页里选择分层话题。可靠流程是点击“开始校正”，页面记录当前最新语音历史位置，然后每 3 秒检查一次 `.codex\transcription-history.jsonl` 是否出现新记录；用户在 Codex 里完成语音输入后，页面检测到新转写就自动导入并生成整理文本。该监听只在用户点击后前台运行，最长 2 分钟，不复制当前焦点内容。页面也保留“导入 Codex 最新语音历史”和“手动导入识别结果”作为高级诊断工具，主流程正常时默认收起。
3. 自动应用：用户明确开启“自动应用到输入框”后，页面会持续轮询 Codex 语音历史，默认检查间隔为 500ms；发现新记录就调用 `/api/auto-apply-codex-transcription` 完成读取、整理、候选替换、剪贴板写入和 Codex composer 回填尝试。它仍不监听键盘、鼠标或普通手动输入，也不读取当前 composer 草稿。页面不能拦截 Codex 的发送按钮，也不能直接获知用户是否已经点击发送或最终发送了什么，因此会用顶部保护提示提醒用户：语音结束后先等自动应用状态显示“可以发送”，再点击 Codex 发送。校准样本以本页“发送给 Codex 的最终文本”为准；如果回填后又在 Codex 输入框里修改，保存样本前需要把最终文本同步回本页。用户修改这段最终文本后，可点击“保存样本”写入本地 JSONL 校准样本，并在页面展示保存路径；“更新规则”会基于已保存样本生成候选替换文件，并在页面展示候选规则路径、样本数和候选数；更新后 `/api/polish` 和自动应用接口会把候选作为保守的精确替换应用到自动整理文本，但不会改写 `CodexVoicePromptBridge` 的永久源码规则。默认整理方向是在保留核心意图的前提下总结要点、压缩上下文、节省 token，并让输出更像清晰可执行的 AI 提示词；整理器会尽量去除或归一化“然后啊”等口头禅；遇到“是否按照……要求做到了”这类口语倒装句时，会重组为“是否做到了……要求”；当整理规则要求“整体意图、重组、拆分、总结要点”时，整理器会优先保留 1、2、3 点的结构化表达，但不再自动添加 `请执行：` 这类标题前缀，也不把整理规则本身追加成“要求：...”。

访问与启动是单独配置。“固定配置入口”开启后建议固定使用 `http://127.0.0.1:8793/`；“随 Codex 启动”表示启动 Codex 时自动启动本地校准服务并打开固定配置网页。真正注册启动任务需要用户明确确认后再执行。

校准中心顶部展示隐私与数据使用说明：项目只处理 Codex 语音输入链路中的文本，不监听键盘或鼠标，不记录普通手动输入，也不把语音校准记录挪作语音输入优化以外的用途。随后提供配置概览，帮助首次使用者理解持续学习、访问与启动、主动校准分别负责什么。

差异记录默认保存在：

```text
.\.codex-tmp\voice-feedback\yyyy-MM-dd.jsonl
```

持续学习日志有自动清理机制：保存样本和每日迭代后都会按配置清理本项目 `voice-feedback` 目录下按日期命名的 JSONL 学习日志。默认策略是保留最近 30 天、总量最多 20 MB、单日最多 200 条样本；超过单日上限时保留最新样本，超过天数或容量上限时删除最旧日期日志。该机制不清理 Codex 自带的 `%USERPROFILE%\.codex\transcription-history.jsonl`。

每日迭代脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-VoiceFeedbackDailyIteration.ps1"
```

该脚本读取前一天的本地差异记录，生成候选个人化规则到 `.codex-tmp\voice-feedback\generated\voice-feedback-learning.generated.json`。当前阶段只生成候选规则，不自动改写 `CodexVoicePromptBridge` 的永久规则。

如需把每日迭代注册到 Windows 任务计划程序，用户确认后再运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Register-VoiceFeedbackDailyTask.ps1"
```

## 当前能力边界

这个方案不依赖 TypeWhisper，也不需要 Whisper 模型常驻。

但目前 Codex 桌面端语音窗口没有公开的“识别完成后自动回调/读取/改写/回填当前 composer”钩子。旧的 `ActiveInput` 路径只能采用 Windows 剪贴板和按键模拟：

```text
Ctrl+A -> Ctrl+C -> 本地整理 -> 写入剪贴板 -> Ctrl+A -> Ctrl+V
```

2026-05-25 对“绕过焦点直写 Codex 输入端”的三线调查结论：

1. 深链/启动参数：`codex://new?prompt=<URL编码文本>&path=<可选目录>` 有只读证据表明可预填新线程 composer，属于半可用入口；未验证为长期稳定契约，也不写当前 composer。
2. IPC/服务入口：运行态未发现 Codex 自己公开监听的本地 HTTP API；`\\.\pipe\codex-ipc`、Electron IPC 和 `app-server --listen stdio://` 都是内部通道，未发现安全稳定的 composer 写入方法。
3. 本地存储：`.codex\state_5.sqlite`、Electron LevelDB/localStorage、VS Code `state.vscdb` 未发现当前 composer 草稿入口；`.codex-global-state.json` 里的 `prompt-history` 是历史提示召回，不等于当前输入框文本，写入风险高。

因此当前推荐路径调整为：`Codex transcription-history.jsonl -> local bridge -> clipboard -> captured/focused Codex text field`，并以网页“自动应用到输入框”作为优先体验入口。不要把“自动应用”“确认回填”“自动粘贴”理解成后台直写 Codex 输入框；它们仍然只是写入剪贴板，再通过窗口焦点恢复、UIA 聚焦和按键粘贴完成回填。

2026-05-25 已新增一条 TypeWhisper 式路线：本地审核服务在 `/api/latest-codex-transcription` 或 `/api/auto-apply-codex-transcription` 发现新转写时，会记录当时 Windows 前台窗口句柄作为 `pasteTarget`；网页“自动应用到输入框”和“确认回填”都会默认使用该目标。服务会立即尝试 `SetForegroundWindow(pasteTarget.hwnd)`。如果目标窗口是 Codex，服务还会通过 Windows UI Automation 查找底部可聚焦的 `ProseMirror` composer，并在确认焦点落到 composer 后再发送 `Ctrl+A`、`Ctrl+V`。当本地服务以 `-STA` 启动且回填延迟为 0 秒时，确认回填会优先在服务进程内直接完成聚焦和按键发送，减少额外启动隐藏 PowerShell 的延迟；非 0 秒延迟或旧启动方式才回退到后台 PowerShell。校准中心会在“回填校验结果”区域展示最近一次回填的状态、路径、目标窗口、延迟和跳过原因，便于用户判断是否符合预期。其本质仍是 TypeWhisper 的“记录录音开始/转写完成时的目标窗口 -> 写剪贴板 -> 切回窗口 -> Ctrl+V”思路，并额外处理 Codex 右侧审核页抢占内部焦点的问题。

这条路线的边界也要写清楚：它仍然不是后台直写 Codex composer，而是“窗口级焦点恢复 + UIA 聚焦 composer + 剪贴板粘贴”。如果 UIA 未找到或未成功聚焦 `ProseMirror` composer，脚本应跳过按键粘贴，只保留剪贴板文本，避免把最终文本误写回审核页。当前实现不写 Codex 本地存储、不调用未知 IPC、不绕过剪贴板。

脚本已加固为：复制前先写入一次性标记，如果 Codex 输入框没有真的把文本复制到剪贴板，就直接报错，不再拿旧剪贴板内容冒充识别结果。要做到真正像飞书那样识别完成后自动语义级改写，需要后续满足至少一个条件：

1. Codex 提供语音识别结果的本地 API、插件钩子或可监听事件。
2. 中介接入一个可用的 LLM API，在回填前做语义级重写。
3. 读取 Codex 本地 `transcription-history.jsonl`，由本项目获得原始转写文本，再把最终文本粘贴进 Codex。
4. 另写 UI 自动化监听器，稳定识别 Codex 语音窗口状态；这条路线维护成本更高，只能作为诊断或兜底实验。

当前版本优先保持免费、低延迟、可本地运行，所以只做规则级整理，不默认接入云端 API。规则整理会尽量压缩冗余表达和重复上下文；更新规则生成的候选替换会在本地 `/api/polish` 中按精确片段应用到后续自动整理文本，但不会像 LLM 一样可靠地理解所有长段语义；关键约束仍应保留在“发送给 Codex 的最终文本”里。

## 最小验证

重新发布整理器：

```powershell
& "dotnet" publish "tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o "tools\CodexVoicePromptBridge\publish-self-contained"
```

验证剪贴板模式：

```powershell
Set-Clipboard -Value "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Print
```

验证“上游剪贴板文本 -> 整理 -> 准备粘贴”路径：

```powershell
Set-Clipboard -Value "我希望你就是帮我看一下这个项目，然后另外不要先改代码，给我一个下一步怎么做的方案。"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -PasteFinal -NoPaste -Print
```

验证 Codex 语音历史读取：

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode CodexHistory -NoPaste -Print
```

期望输出类似：

```text
请检查这个项目。另外不要先改代码，给出一个下一步怎么做的方案。
```

## 后续增强路线

优先级建议：

1. 优先稳定 Codex 本地语音历史读取和网页“自动应用到输入框”，让原始转写从 `.codex\transcription-history.jsonl` 进入整理链路，并尽快回填到 Codex composer。
2. 收集 10 到 20 条真实口述文本，补充规则整理里的常见口头表达和识别误差。
3. 增加安装期分层话题校准流程：先给轻松宽泛的话题采集低思考负担下的表达，再进入日常规划、任务表达和高思考负荷话题，分别生成不同场景下的个人化词表、口头禅和替换规则；设计草案见 `docs/onboarding-calibration.md`。
4. 如果仍觉得“提示词化”不够聪明，再评估接入免费或低成本 LLM API。
5. 如果未来出现明显优于当前 Codex 自带语音识别、且免费低延迟的开源 ASR，再重新评估 TypeWhisper/本地 ASR 插件路线。
6. 如果 Codex 后续提供语音窗口插件/API，再把剪贴板/按键中介改成事件驱动中介。

# v0.3 跨平台适配方案：Windows 稳定保留，macOS 建立可用闭环

方案版本：v0.3.0
生成日期：2026-05-27
适用项目：`<repo-root>`
主负责人审批结论：有条件批准，先交付 macOS 稳定剪贴板闭环，再推进授权后的自动粘贴增强。

## 1. 多角色评审结论

本版规划经 5 个角色评审后收束：

- 跨平台架构负责人
- macOS 输入与自动化专家
- 产品经理 / 语音输入重度用户
- 隐私与安全负责人
- QA / 发布负责人

共同结论：v0.3 不应追求一版复刻 Windows 的自动回填体验。macOS 首要目标是稳定完成：

```text
~/.codex/transcription-history.jsonl
-> 本地整理器
-> 审核页 / 剪贴板
-> 用户 Cmd+V 回到 Codex
```

macOS 自动聚焦粘贴只能作为用户显式开启、授予系统权限后的 best-effort 增强；不能作为 MVP 成功标准，也不能描述成后台直写 Codex composer。

## 2. 平台边界

v0.3 将当前能力拆成以下边界，避免把 Windows PowerShell 自动化当成业务核心：

- `CoreEngine`：文本整理、繁转简、纠错、结构判断，保持平台无关。
- `CodexHistorySource`：发现并读取 `.codex/transcription-history.jsonl`，按最新有效记录增量读取。
- `ClipboardAdapter`：Windows 使用 STA / Windows Forms；macOS 使用 `pbcopy` / `pbpaste`。
- `PasteTargetAdapter`：Windows 使用 user32 + UI Automation + SendKeys；macOS 使用 AppleScript/System Events 且默认关闭。
- `ReviewServiceHost`：审核页 API 契约保持一致，宿主可由 Windows PowerShell 或 macOS `pwsh` 启动。
- `StartupScheduler`：Windows 任务计划与 macOS LaunchAgent 分开；v0.3 不默认安装 LaunchAgent。
- `Packaging`：整理器发布目标扩展到 `win-x64`、`osx-x64`、`osx-arm64`。

## 3. 已落地的 v0.3 MVP 范围

- 命令行桥接脚本和本地审核服务已增加 Windows / macOS 平台分支。
- macOS 默认读取 `$HOME/.codex/transcription-history.jsonl` 和 `$HOME/.codex/sessions`。
- macOS 剪贴板读写通过 `pbcopy` / `pbpaste`；不可用时返回明确错误。
- macOS 自动粘贴默认关闭；开启 `activeCalibration.macOsBestEffortPasteEnabled` 后，服务才会尝试 AppleScript 激活 Codex 并发送 `Cmd+V`。
- 回填失败或权限不足时，服务只保留剪贴板，并返回 `macos_best_effort_paste_disabled`、`macos_codex_target_not_captured`、`macos_accessibility_or_automation_failed` 等原因。
- 校准页面新增 macOS 实验自动粘贴开关，并将状态文案改为下一步导向。
- 发布脚本 `scripts/Publish-CodexVoiceBridge.ps1` 支持 `current`、`win-x64`、`osx-x64`、`osx-arm64`、`all`。

## 4. 隐私与安全规则

以下规则是实施门槛：

1. 本项目仍只处理输入侧语音转文字整理，不扩展为通用系统自动化平台。
2. `transcription-history.jsonl` 只读最新必要记录，不全量导入。
3. `sessions` 只能用于用户开启后的短时发送确认，不扫描、不索引、不复制完整会话。
4. 剪贴板只在用户显式导入、确认回填或当前语音链路需要时读写。
5. macOS 辅助功能/自动化权限必须先解释用途，再由用户手动授权；失败时降级为只复制到剪贴板。
6. LaunchAgent、随 Codex 启动、后台常驻和全局热键不默认安装。
7. 禁止监听键盘、鼠标、屏幕或普通手动输入。
8. 禁止写 Codex 私有数据库、未知 IPC、内部 pipe 或非公开 composer 状态。
9. 禁止默认接入云端 LLM/API、新 ASR 或上传语音历史。

## 5. 验收矩阵

阻断级验收项：

- Windows v0.2 主链路 `Clipboard`、`CodexHistory`、`WebReview`、`PasteFinal` 不退化。
- 整理器 golden case 在 Windows、macOS Intel、macOS Apple Silicon 上通过。
- macOS 能完成“读取语音历史 -> 整理 -> 审核页 -> 复制最终文本 -> 用户 Cmd+V”闭环。
- `/health`、`/api/features`、`/api/settings`、`/api/platform`、`/api/polish`、`/api/latest-codex-transcription`、`/api/apply-final-text` 可用。
- 缺少历史文件、坏 JSONL、剪贴板工具缺失、无辅助功能权限、Codex 未打开时不崩溃，并给出明确降级原因。
- 回填失败时不得误写审核页、错误窗口或普通手动输入区域。

## 6. 验证命令

发布当前平台整理器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Publish-CodexVoiceBridge.ps1" -Runtime current
```

发布所有目标：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Publish-CodexVoiceBridge.ps1" -Runtime all
```

运行 golden case：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tests\Run-VoiceBridgeGoldenCases.ps1"
```

macOS 最小闭环建议：

```powershell
pwsh -NoProfile -File ./scripts/Invoke-CodexVoiceBridge.ps1 -Mode CodexHistory -NoPaste -Print
pwsh -NoProfile -File ./scripts/Invoke-CodexVoiceBridge.ps1 -Mode CodexHistory -NoPaste -WebReview
```

## 7. 当前取舍

v0.3 的成功不在于自动得多像 Windows，而在于失败时用户是否始终拿得到整理后的文本并知道下一步。Windows 继续保留完整自动回填；macOS 先保证可读、可整理、可审核、可复制和手动粘贴，再在用户明确授权后提供实验自动粘贴。

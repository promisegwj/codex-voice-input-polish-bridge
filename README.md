# Codex Voice Input Polish Bridge

![Windows](https://img.shields.io/badge/Windows-local--first-0078D4)
![.NET](https://img.shields.io/badge/.NET-10.0-512BD4)
![PowerShell](https://img.shields.io/badge/PowerShell-automation-5391FE)
![No Cloud API](https://img.shields.io/badge/default-no%20cloud%20API-2E7D32)

A local-first Windows bridge for people who use voice input with Codex and want the raw spoken transcript to become a cleaner, shorter, more actionable prompt.

一个面向 Codex 桌面端的本地语音输入整理中介：读取 Codex 本地语音历史或剪贴板文本，把中文口述里的口头禅、重复、倒装、术语误识别和长句绕路整理成更适合直接发送给 Codex 的标准提示词，再通过剪贴板和前台焦点回填到输入框。

> This is an independent helper project, not an official Codex plugin. It does not bypass Codex internals; the current stable path is local transcript history -> local polishing -> clipboard/focused input field.

## Why This Exists

语音输入很快，但原始口述通常不适合直接发给 AI：

- 会有“嗯、呃、这个、那个、就是、然后”等填充词。
- 一句话里可能反复补充、否定、修正和改口。
- 中文口述常常是长句，任务边界和验证要求混在一起。
- 中英混合术语容易被识别成音译词或错误大小写。
- 直接把原始口述发给 Codex，会浪费上下文，也容易让任务变得含糊。

这个项目的目标是把“随口说出来的话”变成“Codex 能直接执行的清晰请求”。

## Who It Is For

适合这些人：

- 经常用 Codex、ChatGPT 或其他 AI 编程助手做长任务的人。
- 希望用中文语音快速表达需求，但不想手动整理提示词的人。
- 在 Windows 上工作，并希望语音链路尽量本地、低延迟、可替换的人。
- 需要把口述内容压缩成任务列表、检查清单、开发要求或 PR 反馈的人。
- 想研究“ASR 转写 -> 规则整理 -> AI prompt”的本地工作流的人。

暂时不适合这些场景：

- macOS/Linux 主力用户。
- 需要后台直写 Codex 当前 composer 的场景。
- 需要云端 LLM 语义级重写且无需人工核验的场景。
- 法律、医疗、保险等必须保留完整逐字语气证据的转写场景。

## Highlights

- **Local-first**: 默认不调用云端 API，不上传语音文本。
- **Codex-aware**: 优先读取 `%USERPROFILE%\.codex\transcription-history.jsonl` 中的 Codex 语音识别结果。
- **Prompt-oriented**: 默认把口述整理成更短、更清楚、更可执行的 Codex 请求。
- **Rule visible**: 网页里有专门的“整理文本规则”位置，规则会传给本地整理器。
- **Reviewable**: 提供本地校准网页，可以对照原始识别、自动整理和人工最终文本。
- **Safer defaults**: 持续学习、自动应用到输入框、随 Codex 启动都默认关闭。
- **Cleanup built in**: 本地学习样本有保留天数、容量和单日条数限制。
- **GitHub-ready**: 带发布清单、贡献指南、路线图、安全说明、issue/PR 模板和 Windows CI。

## How It Works

```text
Codex local transcription history
        or
controlled clipboard/file text
        |
        v
CodexVoicePromptBridge
  - traditional -> simplified Chinese
  - filler cleanup
  - common term correction
  - oral-to-standard rewrite rules
  - prompt-oriented compression
        |
        v
clipboard / local review page / focused Codex input field
```

The project deliberately avoids writing Codex private storage, unknown IPC, or internal Electron state. 回填本质上仍是“写剪贴板 -> 恢复窗口焦点 -> 尝试聚焦输入框 -> 粘贴”。

## What The Rewrite Rule Does

当前默认规则强调：

- 先判断原始口述的真实意图和任务边界。
- 保留事实、否定、时间、数字、路径、文件名、专有名词和条件。
- 删除不承载意义的口头禅、重复句、犹豫词和自我打断。
- 对“不是 A，是 B”“不对，改成 B”以后者为准。
- 将多件事拆成 `1、2、3`，每项尽量写成“动作 + 对象 + 验证/交付要求”。
- 遇到关键歧义时保留“需确认”，不编造用户没有说过的信息。

完整规则草案见 [docs/ORAL_TO_STANDARD_RULES_DRAFT.md](docs/ORAL_TO_STANDARD_RULES_DRAFT.md)。

## Quick Start

### Requirements

- Windows 10/11.
- Codex desktop app with voice transcription history available.
- .NET 10 SDK.
- PowerShell 5.1+ or PowerShell 7+.

### Build The Local Polisher

```powershell
dotnet publish ".\tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o ".\tools\CodexVoicePromptBridge\publish-self-contained"
```

### Open The Calibration Center

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Open-VoiceCalibrationCenter.ps1"
```

Then open:

```text
http://127.0.0.1:8793/
```

### Process Clipboard Text

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode Clipboard -NoPaste -Print
```

### Process Latest Codex Voice Transcript

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-CodexVoiceBridge.ps1" -Mode CodexHistory -NoPaste -Print
```

## Copy This Prompt Into Codex To Install

If you want Codex to install this helper for you, copy this prompt into Codex:

```text
请在当前 Windows 电脑上安装 Codex Voice Input Polish Bridge。仓库地址是：https://github.com/promisegwj/codex-voice-input-polish-bridge.git。请先选择一个合适的本地目录克隆仓库，然后阅读 README、SECURITY.md 和 docs/RELEASE_CHECKLIST.md，确认不会提交或上传个人语音样本、日志、API key 或本机私有路径。请检查本机是否有能构建 net10.0 的 .NET SDK；如果没有，请先告诉我缺少的依赖，不要自行下载未知来源安装包。依赖满足后，请运行 dotnet publish ".\tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o ".\tools\CodexVoicePromptBridge\publish-self-contained"，再运行 powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Open-VoiceCalibrationCenter.ps1" 启动本地校准中心。请打开或提示我打开 http://127.0.0.1:8793/。安装完成后，请报告发布器路径、服务地址、默认开关状态和验证结果。除非我明确确认，不要开启持续学习、自动应用到输入框或随 Codex 启动。
```

## Repository Layout

```text
.github/                        Issue/PR templates and GitHub Actions validation
config/                         Safe default settings and onboarding topics
docs/                           Design notes, workflow docs, release checklist
scripts/                        PowerShell service, bridge, cleanup, task helpers
tools/CodexVoicePromptBridge/   Main C# text polishing bridge
tools/TypeWhisperT2S/           Legacy helper and conversion table
web/                            Local review panel and settings page
TypeWhisper-Codex-Workflow.md   Current workflow and technical boundaries
```

## Safety And Privacy

- The default path is local processing.
- The project does not include a cloud API key or remote LLM call.
- It does not monitor keyboard, mouse, screen, or ordinary manual typing.
- It does not clean or modify Codex's own `transcription-history.jsonl`.
- Local feedback samples under `.codex-tmp/voice-feedback/` are ignored and should not be committed.
- Persistent learning is opt-in and default off.

See [SECURITY.md](SECURITY.md) for the security policy and [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) for publishing checks.

## Current Status

This is an early public release package. The core workflow is usable, but the project is still conservative by design:

- It is Windows-first.
- It uses rule-based text polishing, not full semantic LLM rewriting.
- It relies on clipboard/focus automation for input refill, because Codex does not currently expose a stable public composer write API.
- The license is currently an all-rights-reserved placeholder. Replace `LICENSE` with an explicit open-source license before treating this as an open-source project.

## Roadmap

- Stabilize the Codex transcript history -> local bridge -> review page workflow.
- Improve oral-to-standard rewrite rules with real anonymized examples.
- Add stronger installation-time calibration topics.
- Make persistent learning safer, more reviewable, and easier to roll back.
- Evaluate optional LLM rewriting only after privacy and cost tradeoffs are explicit.
- Replace clipboard/focus automation if Codex later exposes a supported voice transcript or composer API.

See [ROADMAP.md](ROADMAP.md) for details.

## Contributing

Contributions are welcome as issue reports, rule suggestions, workflow notes, and Windows validation results. Please avoid posting private transcripts, credentials, local machine paths, or personal workflow data.

Start with:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [docs/GIT_WORKFLOW.md](docs/GIT_WORKFLOW.md)
- [SUPPORT.md](SUPPORT.md)

## Documentation

- [Release Checklist](docs/RELEASE_CHECKLIST.md)
- [Release Manifest](docs/RELEASE_MANIFEST.md)
- [Oral To Standard Rules Draft](docs/ORAL_TO_STANDARD_RULES_DRAFT.md)
- [Development Handbook](docs/development-handbook.md)
- [Onboarding Calibration](docs/onboarding-calibration.md)
- [Changelog](CHANGELOG.md)
- [Security Policy](SECURITY.md)

## License

The current `LICENSE` is a conservative all-rights-reserved placeholder. Before public open-source collaboration, choose and replace it with a formal license such as MIT, Apache-2.0, GPL, or another license appropriate for the project.

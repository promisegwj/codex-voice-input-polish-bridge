# Codex Voice Input Polish Bridge

一个 Windows 本地语音输入中介：读取 Codex 本地语音历史或剪贴板文本，做中文口述整理、轻量纠错、上下文压缩和提示词化，再通过剪贴板/前台焦点回填到 Codex 输入框。

## 功能概览

- 读取 `%USERPROFILE%\.codex\transcription-history.jsonl` 中的 Codex 语音识别结果。
- 使用本地 C# 整理器做繁转简、口头禅清理、常见术语修正和提示词化压缩。
- 提供本地校准网页：`http://127.0.0.1:8793/`。
- 支持持续学习样本记录，但默认关闭，并带本地日志自动清理机制。
- 不包含云端 API，不默认上传文本，不监听键盘、鼠标或普通手动输入。

## 目录结构

```text
.github/                        Issue/PR 模板和 GitHub Actions 验证
config/                         默认配置和主动校准话题
docs/                           设计说明和维护手册
scripts/                        PowerShell 启动、服务、回填和清理脚本
tools/CodexVoicePromptBridge/   语音文本整理器源码
tools/TypeWhisperT2S/           繁简字符表和旧轻量整理工具源码
web/                            本地审核页和设置页
TypeWhisper-Codex-Workflow.md   当前工作流说明
```

## 快速开始

1. 安装能构建 `net10.0` 项目的 .NET SDK。
2. 发布本地整理器：

```powershell
dotnet publish ".\tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o ".\tools\CodexVoicePromptBridge\publish-self-contained"
```

3. 启动校准中心：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Open-VoiceCalibrationCenter.ps1"
```

4. 打开 `http://127.0.0.1:8793/`，按页面提示使用。

## 复制给 Codex 的安装提示词

把下面这段文字复制到 Codex 里，并把 `<repo-url>` 替换成实际 Git 仓库地址：

```text
请在当前 Windows 电脑上安装这个 Codex 语音输入整理中介。仓库地址是：<repo-url>。请先选择一个合适的本地目录克隆仓库，然后阅读 README、SECURITY.md 和 docs/RELEASE_CHECKLIST.md，确认不会提交或上传个人语音样本、日志、API key 或本机私有路径。请检查本机是否有能构建 net10.0 的 .NET SDK；如果没有，请先告诉我缺少的依赖，不要自行下载未知来源安装包。依赖满足后，请运行 dotnet publish ".\tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o ".\tools\CodexVoicePromptBridge\publish-self-contained"，再运行 powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Open-VoiceCalibrationCenter.ps1" 启动本地校准中心。请打开或提示我打开 http://127.0.0.1:8793/。安装完成后，请报告发布器路径、服务地址、默认开关状态和验证结果。除非我明确确认，不要开启持续学习、自动应用到输入框或随 Codex 启动。
```

## 维护文档

- [Contributing](CONTRIBUTING.md)：贡献和合并标准。
- [Git Workflow](docs/GIT_WORKFLOW.md)：分支、PR、合并和发布流程。
- [Release Checklist](docs/RELEASE_CHECKLIST.md)：发布前检查清单。
- [Oral to Standard Rules Draft](docs/ORAL_TO_STANDARD_RULES_DRAFT.md)：口语转标准文本的规则草案，确认后再落实到程序。
- [Roadmap](ROADMAP.md)：后续发展规划。
- [Changelog](CHANGELOG.md)：版本变化记录。
- [Security Policy](SECURITY.md)：隐私和安全边界。
- [Support](SUPPORT.md)：提问和求助时应提供的信息。
- [Release Manifest](docs/RELEASE_MANIFEST.md)：发布目录包含和排除的文件。

## 安全边界

- `.codex-tmp/voice-feedback/` 是本地学习样本目录，不应提交。
- `downloads/`、构建输出、发布 exe、语音音频、日志和个人样本不应提交。
- `config/voice-feedback-settings.json` 在发布目录中使用保守默认值：持续学习关闭、自动应用关闭、随 Codex 启动关闭。
- 当前 `LICENSE` 是保守的 all-rights-reserved 占位；公开开源前请由项目所有者决定并替换为正式许可证。

## 发布说明

本目录是从开发工作区整理出的 Git 发布目录。上游 TypeWhisper 源码备份、下载包、调查用 bundle、构建输出和个人临时数据已排除。

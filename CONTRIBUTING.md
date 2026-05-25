# Contributing

感谢你愿意改进这个项目。这个仓库的目标是维护一个本地、低延迟、隐私边界清晰的 Codex 中文语音输入整理链路。

## 开发原则

- 默认本地处理，不引入云端 API，除非变更说明里清楚写出隐私、额度、降级方案。
- 不提交个人语音样本、`.codex-tmp/`、构建输出、下载包、日志或凭据。
- 不把回填能力描述成后台直写 Codex composer；当前路线是剪贴板、窗口焦点恢复和按键粘贴。
- 持续学习默认关闭，保存样本后必须保留自动清理边界。

## 提交流程

1. 从 `main` 新建功能分支。
2. 小步提交，提交说明使用祈使句，例如 `Add feedback cleanup script`。
3. 跑基础验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-VoiceFeedbackCleanup.ps1" -Json
dotnet build ".\tools\CodexVoicePromptBridge\CodexVoicePromptBridge.csproj" -c Release
dotnet build ".\tools\TypeWhisperT2S\TypeWhisperT2S.csproj" -c Release
```

4. 如果修改了网页或服务 API，同步更新 `docs/development-handbook.md` 和 `TypeWhisper-Codex-Workflow.md`。
5. 开 PR，并填写 PR 模板里的风险、验证和隐私边界。

## 合并标准

- 至少一个维护者 review。
- 没有新增敏感路径、个人数据或构建产物。
- 配置默认值保持保守：持续学习关闭、自动应用关闭、随 Codex 启动关闭。
- 新功能必须有最小验证路径。

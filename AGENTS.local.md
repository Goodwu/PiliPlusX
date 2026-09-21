# PiliPlusX 本地执行约束

- 使用 Codex Agent Team：顶层 agent 开始任务时读取并遵守 `/Users/wuweiwei1/ConfigFiles/ai-longterm-repo/frameworks/agent-team/core/routing.md`，按该规则使用角色、任务包和模板。轻量角色只可处理日志摘录、版本清单、确定性脚本变换和文档结构同步；HDR 色彩/亮度、Surface 或 BufferQueue 生命周期、全屏竞态、播放根因和实机验收按共享路由选择标准或升级角色。原生角色返回不可用时，记录错误并停止该工作包；不得改用通用角色或 direct launcher。任务卡、native 错误、子会话路径和验收输出须记录在当前 task/conversation。
- 涉及代码、构建、平台适配、HDR 或运行验收前，先阅读 `docs/README.md`，从 `TASKS.md` 进入唯一有效的 conversation `Current State`。`Current State` 必须替换过期结论，不能依赖后文追加来否定前文；历史只保留证据。
- 播放器控制条会自动超时退出。通过 ADB/HDC 或 UI 自动化操作控制条时，必须以单个连续脚本完成：安全唤醒、重抓布局/目标、目标点击和结果复核；不得将第一次唤醒与后续点击拆到独立命令或试次，避免第二次点击落到已失效控件。

当前交付方向、任务范围、候选身份、实验顺序和验收硬门槛只维护在 `TASKS.md`；不得在本文件重复记录会随任务推进变化的状态。

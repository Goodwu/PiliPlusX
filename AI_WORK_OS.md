# PiliPlusX 的 AI Work OS 接入说明（代码开发项目）

本文记录当前代码项目的 AI Work OS 协作入口。项目自身的产品或业务说明由项目维护，初始化不会创建或修改 `README.md`。

---

## 分层结构

- 本目录：项目专属内容（代码、设计、测试、进度）
- 长期存储库：`~/ConfigFiles/ai-longterm-repo/`（仅通用资产，禁止项目信息与敏感信息）

---

## 接入目标与工作入口

- 在任务与 conversation 中记录本次工作的目标、边界与验收标准
- 建立代码任务文件化机制（仅 `TASKS.md`）
- 建立最小开发闭环（需求 -> 实现 -> 测试 -> 记录）
- 开工时按需执行 Context Intake：先由 TASKS 定位任务，再读取有效 conversation context；需要可复用经验时检索 active memory。

## Agent Team

`ai init` 默认接入 Codex；选择 Claude 使用 `--team-adapter claude`，跳过接入使用 `--no-team`。
角色通过 `ai team install` 安装到当前用户的原生 agent 目录；项目 `AGENTS.local.md` 只保留对应团队的协议读取指令及实际项目约束。
缺少角色配置时，安装后运行 `ai team enable . --adapter codex`（或 `claude`）；`ai team status .` 查看配置，不代表角色已运行验证。

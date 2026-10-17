# PiliPlusX 最新 media-kit 对接 / 2026-10-15

> 2026-10-15 分层约束更新：[App 分层解耦对接契约](media-kit-layering-integration-contract-20261015.md)，版本 `MK-ROUTING-20261011/LAYERING-20261015-r1`。后续普通 owner 工作包按库侧 L01—L12 与 App 的 APP-L01—APP-L08 验收；应用不管理 token/lease、不调用厂商 arm、不复制设备路由。本次仅更新文档。以下起点、执行步骤、pending 和测试结果是原计划历史，续接须使用最新 refs 与 PR 回执，不退回原阅读 SHA。

任务：MK-ROUTING-20261011。唯一 App 分支 `routing/MK-ROUTING-20261011` / Goodwu/PiliPlusX PR1；中央 Goodwu/media-kit PR4。不另起分支、不合并主 PR、不发布 Release、不改写用户本地 WIP。

## 本轮起点与已完成历史

实读 App HEAD `d128d36cf9844947f7d5cf965d0da6e2effb51b6`，库 HEAD `2276715a12617279ca993beadf8080ac10992de6`。旧 App d128d36 + 库 d07b46b 的 source run38571583665、293 Flutter / 519 Python / 1 Web DOM 均是旧组合证据，不替代本轮验证。

既有配置迁移、无 Player 查询、逐 DASH 源选择、不可变 options、Session/报告/诊断、静态 HDR 标签已经实现，不重复开发。native DV001 已在原构建仓 PR1 的 `device/MK-ROUTING-20261011/DV001` 实现 47075b6→8f1dd98；不要重做。新读取 native run38584797265 终态是 failure（build/package 步骤），尚需核对具体失败和后继源码。

## 新库边界

2276715 加入声明式 `pqPresentation{rgbSurface,yuvWindow}`、C2 RGB 可行性与 C4 YUV 载体推导、attempt-scoped YUV arm 和进程初始化互斥；删除两项旧 define。不能在 App 重新添加这些开关或按设备名决策。

库源码 `HdrYuvWindowArm` 明确普通生产调用没有 owner token 时早期失败，自动 owner 生命周期仍另包。LG lab 有 owner 的实机成功不证明 PiliPlusX 普通入口可执行。App 不伪造 `routeLocked/acceptNonConformant`、不从 report listener 预 arm，也不以随机 token 绕过 single-open/replan/bridge 生命周期。

HDR10+/Vivid 本期只做静态 PQ/HLG 兼容；动态 C1/C2/B1–B4 保持延期，routeNotImplemented 保持可见，不隐式把 HDR 失败降成 SDR。

## 执行步骤和验收

1. 将八个 Goodwu/media-kit overrides 统一到当前 2276715，清理过时依赖注释；沿用既有 bootstrap 的最新源码捕获、实际十包根核验和前后 freshness。不得手写假 resolved-ref 或借旧 JAR 验证。
2. 审查新能力经 App query→selection→Session→report 的传递。增加 LG/LYA 通道差异、Vivid 静态 C4、未实现/owner 缺失错误的回归；库仍负责路由和副作用，App 只适配展示与请求。
3. 严格 analyze、全套 Flutter/Python、Web DOM/编译、Linux/Windows/macOS bundle 与源码终检都在最终当前组合重跑。新字段导致的编译或行为失败按真实日志修复；不改断言来冒充设备通过，不漏跑测试。
4. 续核原 DV001 最新原生构建失败、来源/链接/manifest 门及当前产品输入；有可验证产物才进入 accepted ledger、APK/成员/ABI/签名/parity。缺失仍明确失败，不改成成功或 skip。
5. 同一候选的源码、原生产物、设备验证分别记录。最终结果写回本计划的后继回执与两个原 PR；源码通过不关闭 owner 生命周期/当前原生包/真机 HDR 阻塞。

## 初始状态

本文件与依赖更新先提交推送以保留接续点；本候选的新 CI、安装包和设备结论均 pending。Codex media-kit 工作区连接失败，本轮可通过 GitHub API/Actions 执行，不声称本地 Flutter/设备执行。下一接手先读取最新 refs 和 PR 终态回执，不从旧 main 重开工作。

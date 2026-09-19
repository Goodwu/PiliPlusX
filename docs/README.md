# PiliPlusX 文档索引

文档按用途分类；所有“已通过”均指有命令、日志或产物证据支持的状态。

## 当前状态与证据

- [HDR 后端状态矩阵](status/hdr-backend-status.md)：各平台原生 HDR、能力探测和 SDR 回退边界。
- [HDR 验证账本](status/hdr-verification.md)：可复核的 channel、依赖、测试和设备证据。
- [SDR 跨平台构建证据](status/platform-sdr-build-status.md)：平台构建、产物、ABI、运行门和工具链限制。
- [OHOS 开发总结](status/ohos-development-summary.md)：OHOS 3.44 兼容实现、HAP 产物和剩余运行验收。
- [OHOS HDR 实机调试基线](status/ohos-hdr-debug-baseline.md)：真机/模拟器边界、DV tone-map 证据、统一 HDR 画质门控和剩余 native HDR 验收。
- [OHOS 运行状态与近期回归记录](status/ohos-runtime-status.md)：白屏、图标、播放器触摸路径、签名 profile 和设备运行证据。

## 计划与设计

- [上游重建、功能迁移与社区贡献计划](plans/upstream-rebootstrap-and-contribution-plan.md)：旧 fork 归档、直接 fork 重建、功能盘点与迁移顺序、media-kit PR #1326 协作，以及 OHOS libmpv 可复现供应链的可执行任务设计。
- [非 HDR 全平台可用计划](plans/sdr-cross-platform-plan.md)：SDR 构建、启动、播放和资源释放的验收顺序。
- [全平台原生 HDR 计划](plans/native-hdr-development-plan.md)：原生 surface、色彩空间、解码器和真机证据要求。
- [media-kit 输出重建修复计划](plans/media-kit-output-rebuild-plan.md)：输出载体切换、dispose/create 完成屏障和应用侧重建事务。
- [跨平台播放器固定操作说明](plans/player-interaction-operation-sop.md)：macOS、OHOS 等自动隐藏控制条播放器的连续操作协议。
- [OHOS 视频区域点击修复计划](plans/ohos-video-area-tap-fix-plan.md)：实体机视频点击、PlatformView 输入边界、控制条交互与 HDR 保留约束。
- [播放器架构整改实施记录](plans/player-architecture-remediation-plan.md)：触控归属、输出生命周期、HDR 参数所有权、全屏状态和验收硬门槛。
- [macOS 产品 DV/HDR 固定测试操作说明](plans/macos-product-dv-test-sop.md)：唯一应用、BV 输入、目标条目确认和解码/输出证据采集顺序。

## 平台适配

- [OHOS 适配记录](platforms/ohos-adaptation.md)：工具链、插件边界、准备脚本和 fail-closed HDR 策略。
- [OHOS Emulator/hdc 排障记录](platforms/ohos-emulator-hdc.md)：Qt 启动修复、镜像准备和容器 hdc 限制。

## 评审与决策

- [HDR Issue #11 评审结论](reviews/hdr-issue-11-review.md)：HDR 解码与原生输出边界及合入原则。
- [media-kit PR #2 审查摘要](reviews/media-kit-pr-2-review.md)：依赖分支、CI 和生命周期变更审查。

## 依赖参考

- [media-kit 原生依赖来源与跟踪基线](reference/media-kit-native-dependencies.md)：官方与当前 fork 的 libmpv、ANGLE、mimalloc 下载链接、摘要、OHOS 缺口和持续审计规则。

## 示例

- [HDR 设备证据模板](examples/hdr-device-evidence.example.json)：真实设备记录格式；占位值不能作为验收证据。

历史文档若不再代表当前状态，统一放在 `docs/backup/`，不作为当前验收依据。

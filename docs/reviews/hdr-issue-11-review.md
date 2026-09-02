# HDR Issue #11 会话结论

> 决策记录（2026-09-02）。最新构建和运行阻塞以
> [OHOS 开发总结](../status/ohos-development-summary.md) 与
> [HDR 验证账本](../status/hdr-verification.md) 为准。

更新时间：2026-09-02

本文沉淀对 [PiliPlusX Issue #11](https://github.com/cnctem/PiliPlusX/issues/11)
及其实现 PR 的调查结论。Issue 的现象是：选择 HDR 画质后仍按 SDR 播放，系统
HDR/SDR ratio 保持 1.00。

## Issue、PR 与原始 media-kit 状态

- PiliPlusX 的实际实现 PR 是 [PR #26](https://github.com/cnctem/PiliPlusX/pull/26)，
  不是 issue 页面直接关联的 PR。它基于旧 `dev`，当前与 `dev-new` 已严重分叉，
  旧 CI 通过只证明旧基线可构建，不能证明当前分支可合入。
- 原始 `bggRGjQaUbCoE/media-kit` 没有针对该问题的独立修复 PR；真正上游的
  [media-kit #615](https://github.com/media-kit/media-kit/issues/615) 仍开放，已明确
  Flutter Texture 不能提供真正 HDR passthrough，只能通过 tone mapping 改善 SDR。
- [media-kit #1207](https://github.com/media-kit/media-kit/issues/1207) 仍开放，记录了
  Android HDR10 硬解输出异常；[#573](https://github.com/media-kit/media-kit/issues/573)
  已关闭但没有实现原生 HDR 后端。
- [PR #202](https://github.com/media-kit/media-kit/pull/202) 只暴露 `vo`/`hwdec`；
  [PR #962](https://github.com/media-kit/media-kit/pull/962) 只迁移到
  `SurfaceProducer`，均不能单独解决 Texture 到 HDR 显示的问题。
- 因此，完全不修改的原始 media-kit 可以提供 HDR 解码和 SDR tone-map，但不能满足
  “系统进入 HDR、ratio 大于 1”的验收口径。真正 HDR 需要原生 surface/layer 或等效
  原生输出路径。

## 合入原则

1. 从最新目标分支重建干净 PR，不直接合并旧 `hdr` 分支。
2. media-kit 依赖使用项目可控 fork，并在 `pubspec.yaml` 与 lockfile 中固定完整 SHA；
   不引用可移动的第三方分支。
3. 保持跨平台 Dart API 可编译，但按平台选择原生后端；HDR 初始化失败必须自动回退
   到可播放的 SDR tone-map。
4. Android 与 Android Pink 共用同一 arm64 原生库；Pink 只改变包名、更新通道和产物名。
5. iOS、macOS、Windows、Linux、OHOS 不应因 Android HDR 依赖变更而改变默认播放行为。

## 跨平台后端边界

| 平台 | 原生 HDR 目标 | 未满足条件时 |
| --- | --- | --- |
| Android / Pink | `SurfaceView + MediaCodec + mediacodec_embed`；API、显示 HDR 类型、codec profile、Vulkan/HCPP 均需检测 | SurfaceView 或 Texture tone-map |
| iOS | EDR-capable `UIView/CAMetalLayer`，验证设备与 profile | Texture tone-map |
| macOS | 窗口实际所在屏幕的 EDR layer，跨屏时重新探测 | Texture tone-map |
| Windows x64 | 原生 HDR swapchain/子窗口，检测 DXGI HDR 色彩空间 | `gpu-next` tone-map 或 SDR |
| Linux x64 | 仅在 Wayland compositor、驱动和输出协议均可证明时启用 | X11/普通 Wayland 使用 SDR |
| OHOS | XComponent/NativeWindow 能力与真机验证完成后启用 | Texture tone-map，并明确报告未证明 |

统一的能力状态应区分 `capable`、`active` 和 `fallbackReason`；检测到 HDR 显示器、
选中 HDR 画质或构建成功，均不能单独证明 `active=nativeHdr`。

## 当前仓库证据入口

- [HDR 后端状态矩阵](../status/hdr-backend-status.md)：记录各平台当前输出路径、能力探测和
  原生 HDR 解锁条件。
- [HDR 验证账本](../status/hdr-verification.md)：记录 media-kit 固定 SHA、channel 契约、CI、
  构建限制以及尚未完成的真机证据。
- [跨平台 SDR 构建证据](../status/platform-sdr-build-status.md)：记录各平台构建、ABI、发布
  manifest 和已知工具链限制。
- [OHOS 适配记录](../platforms/ohos-adaptation.md)：记录 OHOS 工具链、插件边界和 HDR 的
  fail-closed 策略。

## 合入前验收

- 所有发布 job（Android arm64、Pink、iOS、macOS、Windows x64、Linux x64，以及
  OHOS 分支 HAP）在目标分支重新执行；失败不得被 `continue-on-error` 隐藏。
- 至少一台 HDR 真机和一台 SDR/不支持设备验证 HDR10/HLG、SDR↔HDR 切换、离线播放、
  分 P、旋转、全屏、PiP、后台恢复、字幕、弹幕和截图。
- 原生 HDR 验收记录必须包含片源 primaries/transfer、实际输出色彩空间、解码器和
  HDR/SDR ratio；只有这些证据齐全后才把默认模式从 `off` 提升为 `auto`。
- 发布产物继续生成 SHA-256 manifest，并验证 APK/HAP 内 ABI、IPA/DMG framework
  架构及 Windows/Linux 可执行文件架构。

## 结论

Issue #11 的根因不是单一的 B 站画质参数，而是“HDR 解码”和“能够以 HDR 色彩空间
输出”被混为一谈。短期可用原始 media-kit 做 tone-map；要实现真正 HDR，必须维护
原生输出后端、能力探测和可靠回退。跨平台方案应允许各平台按能力逐步开启原生 HDR，
并始终保持普通 SDR 播放和其他架构产物可用。

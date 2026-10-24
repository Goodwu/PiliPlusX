# Goodwu/media-kit PR #2 审查摘要

> 历史审查快照（2026-09-02）。当前 PiliPlusX 构建状态请以
> [文档索引](../README.md) 中的 status 文档为准；本文件不代表 PR 的实时状态。

审查日期：2026-09-02
PR：[Goodwu/media-kit#2](https://github.com/Goodwu/media-kit/pull/2)

## 结论

当前不建议合并。PR 的代码方向基本合理，但仍处于 Draft 状态，且现有 CI 证据不足以证明完整兼容性。

## PR 基本信息

- 标题：`ci: validate pinned toolchains without redundant dispatch tests`
- base：`integration/piliplusx-hdr-08b`
- head：`validation/ohos-dart310-6393db1a`
- head commit：`cc7b62b239af113e1eb4d41ea0e7820128908b4b`
- GitHub 状态：Open、Draft、Mergeable
- 当前没有 code review 或 inline review comment

## 主要改动

1. 将 CI 中使用的 Flutter SDK 固定为 `3.47.2`，对应 Flutter commit：
   `d3b14c876900e553bc736ca19295fc09e3853e8e`。
2. 为 Android、native 和 OHOS video controller 增加
   `disposeForRebuild()`，用于同一 Player 在输出配置变化时释放旧 controller 和缓存。
3. 增加 `_disposed` 幂等保护，避免正常释放和重建释放重复执行。
4. 将 package 测试改为可通过 `workflow_dispatch` 的
   `run_package_tests` 输入选择执行，默认值为 `false`。

## 当前验证情况

已通过：

- OHOS arm64 unsigned HAP 构建。

尚未形成有效证据：

- Windows、Linux、macOS、Web 的 package 测试；
- 各平台构建测试；
- Android HDR controller 重建后的实机播放验证。

## 主要风险与阻塞项

### 1. PR 不会自动触发完整 Github Actions CI

当前 base 分支是 `integration/piliplusx-hdr-08b`，但
[`.github/workflows/ci.yml`](https://github.com/Goodwu/media-kit/blob/cc7b62b239af113e1eb4d41ea0e7820128908b4b/.github/workflows/ci.yml)
的 `pull_request.branches` 只包含 `main` 和 `dev`。

因此本 PR 当前实际自动执行的是 OHOS 构建检查，package 测试和标准平台构建没有完整覆盖本次变更。

### 2. 手动 CI 默认可能跳过 package 测试

`workflow_dispatch` 中 `run_package_tests` 默认是 `false`。如果手动验证时不显式设置为 `true`，Windows/Linux/macOS/Web 的长时间 package 测试会被跳过。

### 3. 重建接口缺少 media-kit 内部测试

`disposeForRebuild()` 由上层 PiliPlusX 使用，media-kit 仓库内目前没有看到对应调用方或专门测试。因此需要在消费者侧确认：HDR/SDR 或输出模式变化时，旧 controller 确实先释放，再创建新的 controller。

### 4. Darwin 输出重建的生命周期风险

本次 macOS 实机复现进一步暴露了该接口的生命周期风险。PiliPlusX 曾在
SDR、HLG、Dolby Vision 之间切换时错误触发输出重建；重建期间出现
`_videoController == null`、texture 注销/重新注册、`MPVHelpers` 错误和
Flutter native mutex 崩溃。该触发条件已在 PiliPlusX 侧禁止，但不能据此证明
media-kit 的重建实现安全。

从锁定的 Darwin 实现看，`disposeForRebuild()` 返回与旧输出完全销毁之间仍可能
存在异步窗口：render callback、worker、主线程 texture 注销和
`VideoOutputManager` 的 handle 映射没有统一的完成屏障。同一 handle 创建新输出时
也需要明确保证旧实例已停止并移除。该风险需要 media-kit 内部修复和测试，不能用
PiliPlusX 的延时或平台特判替代。

## 合并前置条件

1. 在当前 head commit `cc7b62b...` 上手动触发 Github Actions，并将 `run_package_tests=true`。
2. 确认 Windows、Linux、macOS、Web package 测试和标准平台构建全部通过。
3. 在 PiliPlusX 中确认 HDR 输出切换调用 `disposeForRebuild()`，并完成至少一次 Android 实机重建播放验证；同时补充 Darwin 重建完成屏障测试。
4. 将 PR 从 Draft 改为 Ready for review。
5. 上述检查通过后再合并；若 CI 仍无法覆盖 integration base，应补充触发规则或保留手动验证记录。

## 审查范围说明

本摘要基于 PR 元数据、PR diff、当前 head 的 workflow 和 controller 源码，以及已报告的 Github Actions 运行结果整理。OHOS unsigned HAP 构建成功不等同于 Android 真 HDR 输出或跨平台播放功能已经验收。

## 后续修复（2026-09-02）

PR #2 的上述信息保留为历史快照。Darwin 重建屏障的后续修复位于独立分支
`fix/darwin-video-output-rebuild-barrier`，提交
`73536efdda482f2d5eefe2feb7038db419944b96`：

- `VideoOutput` 使用 active/disposing/disposed 状态和 completion waiter，重复 dispose
  必须等待同一次 texture 注销完成；状态由锁保护。
- `VideoOutputManager` 对同一 player handle 的 Create/Dispose 排队，销毁完成前不创建
  替代输出。
- PiliPlusX 仅在 Texture/HCPP 载体变化时请求重建；dispose 未确认完成时中止重建。
- 新提交已通过 macOS debug、iOS device `--no-codesign` 编译以及 PiliPlusX HDR 22 项测试。

这些结果当时只证明 Apple 两端能够编译，并修复已知竞态；最新 macOS 连续换源
结果见状态账本，Android HDR 真机压力测试仍是独立运行门，均不能由编译结果替代。

## 当前处置结论（2026-09-03）

PR #2 的 head 仍停在 `cc7b62b239af113e1eb4d41ea0e7820128908b4b`，没有包含
Darwin 根因修复 `73536efdda482f2d5eefe2feb7038db419944b96`；它仍是 Draft，且
PR checks 只有 OHOS unsigned HAP。因此当前 PR 不应直接合并。

`73536ef...` 是 `cc7b62b...` 的后继，包含 PR #2 的全部有效提交。应先从
`fix/darwin-video-output-rebuild-barrier` 建立替代 PR，并确认目标分支、diff 和 CI；
替代 PR 建立后可将 PR #2 标记为 superseded 并关闭。也可以把旧 PR head 快进到
`73536ef...` 后重写标题与说明，但不得在缺少该提交时合并或直接删除唯一合并入口。

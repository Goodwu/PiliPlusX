# media-kit 输出重建修复计划

更新时间：2026-09-03

## 目标

让同一 Player 在输出后端确实变化时安全重建视频输出，并保证普通色彩元数据变化
不会销毁当前可用的 texture。最终要求 Android 原生 HDR 可以动态回退或切换，
macOS/Linux 等 Texture tone-map 平台保持连续播放稳定。

## 已确认的问题边界

- `_hdrOutputSignature()` 只是纯函数；问题在于签名变化被用来无条件触发
  `_rebuildVideoOutput()`。
- SDR、HLG、Dolby Vision tone-map 在 macOS 仍使用同一 Flutter Texture，不能因
  `output.name` 变化重建输出。
- media-kit Darwin 的销毁、回调、worker 和 texture 注销需要一个可等待的完成屏障；
  本计划已在 media-kit 提交 `73536efdda482f2d5eefe2feb7038db419944b96` 实现。

## 实施步骤

### 1. 分离重建判定（已实现）

- 将色彩参数变化与输出拓扑变化分开。
- 重建判定只比较 Texture、SurfaceView、HCPP 等实际输出载体及其必要配置。
- 同一 Texture 上的 SDR、PQ、HLG 和 tone-map 参数变化只调用 mpv 参数更新。
- Android dataspace 提交后确需重新绑定输出时，保留独立的重建触发路径。

### 2. 修复 media-kit Darwin 生命周期（已实现）

为 `disposeForRebuild()` 建立明确契约：返回前必须完成以下顺序：

```text
标记 disposing 并拒绝新 render callback
→ 将清理排到同一 worker 队列，等待此前任务结束
→ 在主线程同步完成 Flutter texture 注销
→ 释放 native texture（其析构解除 mpv render callback）
→ 标记 disposed 并完成全部 waiter
→ 返回 dispose complete
```

`VideoOutput.dispose(completion:)` 将清理排入同一 worker 队列，先同步注销
Flutter texture，再释放 native texture；`VideoOutputManager` 只有在完成回调后才
向 Dart 返回 Dispose/Create 结果。重复 handle 创建会先等待旧输出完成销毁。

同一 player handle 创建新 `VideoOutput` 前，必须确认旧实例已完成上述流程；回调还要
具备 disposed/generation 防护，避免访问已释放对象。

### 3. 完善上层重建事务

- 重建操作串行化，新的重建请求合并为最新配置。
- 重建期间视频与字幕组件均接受 nullable controller；最终失败时保留控制层并显示可重试错误。
- 视频缩放通过 `Video.fit/alignment` 使用统一的有限约束渲染路径，不保留 macOS
  专用布局分支。
- 同一 `Player` 持有播放位置、音量和播放状态；新 controller 绑定该 Player 后，
  由统一 `Video` 布局重新提交尺寸。HCPP dataspace 必须等新 controller 创建完成后
  在同一重建事务内提交，不能并发写入旧 Texture。
- HCPP → SurfaceView → Texture 回退时，每一级都等待上一级完全销毁。
- dispose 失败时保留旧 controller 并中止重建；所有新输出创建均失败时保留控制层、
  显示可重试错误并记录失败原因，避免静默永久黑屏或空值崩溃。

## 测试与验收

media-kit 生命周期验收项：

- 重复 `disposeForRebuild()` 由同一 disposing 状态收集 waiter，不提前完成。
- 同一 handle 的 dispose/create 由 `VideoOutputManager` 操作队列串行执行。
- dispose 请求后不再接收新 render callback；队列内已有任务先于销毁屏障完成。
- 输出创建失败后的回退测试。
- Darwin texture 注销完成后才允许下一输出创建；macOS/iOS 原生构建已覆盖接口编译，
  连续换源仍需运行时压力验证。

PiliPlusX 验收矩阵：

```text
SDR → HDR10/PQ → HLG → Dolby Vision → SDR
```

Android 真机必须同时记录 `nativeOutputActive`、实际 dataspace、输出 surface、
mpv 播放状态、texture 生命周期、画面、进度控制层和崩溃日志。没有这些证据时，
不得将 Android 动态重建标记为已验收。

## 当前安全策略

- macOS 继续使用 Flutter Texture tone-map；上层不再包含针对该问题的临时平台绕过。
- Android 重建仍保持 fail-closed；重建失败必须回退到可播放 Texture/SDR。
- 不通过增加固定延时来伪造销毁完成；完成状态必须由 media-kit native 生命周期
  明确确认。

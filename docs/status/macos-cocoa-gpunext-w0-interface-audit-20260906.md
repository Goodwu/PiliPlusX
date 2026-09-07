# macOS Cocoa gpu-next W0 接口审计

日期：2026-09-06

## 已检查的当前实现

检查范围：`/Users/wuweiwei1/src/media-kit` 当前 Darwin native-surface 工作树。

构建边界也已核对：macOS 的 `Package.swift`/podspec 编译
`macos/media_kit_video/Sources/media_kit_video/plugin`，其中 Darwin 共用实现通过
symlink 指向 `common/darwin/Classes/plugin`。因此 W0 新增的 registry 必须放在共用
Darwin source，再由 macOS plugin symlink 纳入；不能只在 macOS 目标目录旁边新建一个
未被 target 收集的文件。

- `NativeSurfaceViewFactory` 在 macOS 创建 `NativeSurfaceView`，并以 `handle` 保存
  surface owner；`onLayerReady` 只上报 `handle`、`generation` 和
  `rendererReady`。
- 原有 `NativeSurfaceViewRegistry` 仍只保存配置闭包和 display-metrics 闭包；新增加的
  `DarwinViewTokenRegistry` 才负责 macOS `NSView` identity、frame、attach 和 detach
  token，二者尚未与 mpv output owner 连接。
- `NativeSurfaceOutput` 的 channel 只维护 HDR 能力、generation、frame provider 和
  EDR 状态；其报告的 backend 仍是 `darwin-cametal-layer`。
- `NativeVideoController.createNativeOutput` 当前传递 player handle/generation，不能
  把 `windowHandle` 变成 mpv 的 `wid`。
- Flutter `PlatformViewVideo` 已经把 `handle/generation` 放入 macOS
  `AppKitView.creationParams`；但 `createNativeOutput()` 发生在 PlatformView 创建
  之前，所以它不能在 controller 初始化阶段完成 view attach。

## W0 结论

W0 的 token 层、Flutter PlatformView 的真实创建/销毁回调和当前 wrapper 的 native
frame bridge 验收已完成：最新真实运行
在明确 controller dispose 后观察到同一 handle/generation 的 `Detach`、factory
release 和 view deinit。尚未证明 mpv-owned Cocoa window 的 output-owner 生命周期，
也尚未完成 B2 child-window 的 renderer resize/reconfiguration。

不能把 player handle、Flutter view id、`CAMetalLayer` 指针或 OHOS surface id 当作
`wid`。必须新增由 native owner 管理的 opaque view token，并满足：

1. token 与真实 wrapper `NSView` 一一对应；
2. attach 前 wrapper 已创建且仍存活；
3. detach/dispose 先阻止 mpv 使用 view，再注销 token；
4. `generation` 与 token 一起校验，旧回调不能触碰新 view；
5. 先完成重复创建/销毁至少 20 次的无崩溃验证，再进入 W1。

## 最小实现和验证

已在 `common/darwin/Classes/plugin/NativeSurfaceViewRegistry.swift` 增加 macOS-only
`DarwinViewTokenRegistry`，并让现有 macOS `NativeSurfaceView` 在创建/销毁时注册和
注销 token。该 token 只存在 native 侧，不改变当前 `CAMetalLayer`/blitter owner，
也没有传入 mpv 或 Dart。

同时增加了 `NativeWindow.Attach`/`NativeWindow.Detach` 空壳 channel：Attach 只按
`handle/generation` 解析 token，返回 opaque token 和当前 view frame；Detach 使该
代 token 失效。两者都不创建 mpv player、不设置 `wid`、不切换 `vo`，因此不会把这次
W0 验证误报成 W1。

真实 Flutter 验收的正确时序是：`AppKitView` 创建 → macOS `NativeSurface.Ready` → Dart 校验
`handle/generation` → `NativeWindow.Attach` → 记录 token/frame → view dispose 时
`NativeWindow.Detach`。不能在 `createNativeOutput()` 中提前 attach。

2026-09-06 最新真实 Flutter 运行已完成上述 dispose 闭环：`dispose player` 后依次观察到
`NativeSurfaceView macOS deinit`、`NativeSurfaceViewFactory macOS released` 和
`NativeWindow.Detach ... detached=true`。该证据只覆盖当前 Texture/native-surface
空壳 owner；热重启只有 native reference disposal，没有 graceful Detach，不能混用。

同日新构建还观察到 `FrameReportingView` 报告 `frame=(0,0,3840,2160)`，并经
`NativeWindow.Frame` 发送给 Dart；`NativeWindow.State` 可按 token 身份读回 frame。
真实运行已确认同一 `handle/generation/token` 的 Attach、State、Frame、Detach 顺序。
这完成 W0 的 wrapper frame 观测，但不等于 B2 已经让 mpv 接管 `wid` 或验证了
child-window renderer resize。

现已完成 Dart 侧的 W0 接线：`NativeSurface.Ready` 仅在 macOS、generation 匹配、
`rendererReady` 时调用 Attach；`NativeVideoController`
的 dispose 路径先调用 Detach，再执行 `disposeNativeOutput`。Attach 结果只保存在
controller 的 native-window 临时状态中，尚未用于设置 mpv `wid`。

独立 macOS harness 已完成 20 次循环，覆盖：

- 正确 `handle/generation` 可解析到同一 `NSView`；
- 错误 generation 被拒绝；
- 注销后 token 不再解析；
- 最终 live entry 数为 0。

命令和结果：

```text
swiftc media_kit_video/common/darwin/Classes/plugin/NativeSurfaceViewRegistry.swift \
  /tmp/darwin-view-token-registry-test.swift \
  -o /tmp/darwin-view-token-registry-test
/tmp/darwin-view-token-registry-test
darwin-view-token-registry: 20 attach/resolve/stale/detach cycles passed
```

局部解析检查还覆盖了 `MediaKitVideoPlugin.swift` 和 `NativeSurfaceView.swift`；registry
类型检查通过。Dart format 通过，针对 controller 文件的 `dart analyze` 没有 error，
仅报告该文件原有的两条文档 info。

局部 `swiftc -typecheck`/`swiftc -parse` 通过。完整 SwiftPM target 当前不能作为本次
实现的通过证据：该工作树缺少 sibling `media_kit_libs_macos_video`，于是 Package.swift
选择 fallback stub，随后因缺少 Flutter 类型而失败；这与 token registry 无关，需在
真实 Flutter/CocoaPods 依赖环境中复验。

## 与 B2 的边界

这不是 B2 renderer 失败。B2 的独立 Cocoa host 已经证明 `wid=NSView*` 与
`vo=gpu-next` 可以初始化、播放并正常退出；本记录只说明当前 media-kit 尚未提供
把真实 Cocoa view 安全交给 mpv 的接口。

## 下一步

token registry、`NativeWindow.Attach/Detach/State`、Dart Ready/dispose 接线、真实
Flutter Attach/Detach、wrapper frame bridge 和 20 次生命周期 harness 已完成。证据见
`docs/status/macos-cocoa-gpunext-w0-flutter-runtime-20260906.md`。
下一步不是直接把 Attach token 交给 mpv，而是先在独立 mpv-owned backend 中完成
child-window renderer resize/reconfiguration，再把 Attach 的 token 与该 backend 绑定，保持现有
`NativeSurfaceView`/`TextureHW` 路径不变，再接入 `vo=null` → `wid` → `vo=gpu-next`。
在此之前不得修改生产默认 output mode。

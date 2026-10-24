# macOS Cocoa gpu-next 集成边界审计

日期：2026-09-06

## 现有 Darwin 链路

当前 media-kit Darwin native surface 不是 mpv-owned window：

1. `NativeVideoController.create` 默认写入 `vo=libmpv`。
2. `VideoOutputManager` 创建 `VideoOutput`，硬件路径创建 `TextureHW`。
3. `TextureHW` 用 `MPV_RENDER_API_TYPE_OPENGL` 创建
   `mpv_render_context`，并调用 `mpv_render_context_render`。
4. `NativeSurfaceView` 创建一个 `NSView + CAMetalLayer`，定时从
   `NativeFrameRegistry` 取 `CVPixelBuffer`，再用 `MetalSurfaceBlitter` 绘制到
   `CAMetalLayer`。
5. `createNativeOutput/configureHdrOutput` 当前只维护能力、generation、色彩空间和
   EDR 状态；没有把 `NSView*` 指针传给 mpv，也没有让 mpv 创建子窗口。

接口细节进一步确认：macOS `NativeSurfaceViewFactory` 的 `onLayerReady` 当前只上报
`handle/generation/rendererReady`，`NativeSurfaceViewRegistry` 只保存配置和显示指标
闭包，没有暴露 view identity；Dart `NativeVideoController.createNativeOutput` 也忽略
传入的 `windowHandle`，只把 player handle/generation 发给 channel。因此 B2 不能通过
复用现有 `NativeSurface.Ready` 或给 Dart 传一个 player handle 来完成，必须新增受
生命周期保护的 native view token/attach API。

因此现有链路是：

```text
libmpv vo=libmpv
  -> mpv_render_context(OpenGL)
  -> VideoOutput/TextureHW
  -> CVPixelBuffer
  -> NativeFrameRegistry
  -> MetalSurfaceBlitter
  -> CAMetalLayer
```

## B2 所需链路

已跑通的 B2 是：

```text
libmpv C API
  -> wid=(intptr_t) NSView*
  -> vo=gpu-next
  -> libplacebo/Vulkan/MoltenVK
  -> mpv-owned Cocoa child window/layer
```

它不调用 `mpv_render_context_create`，也不产生供 `NativeFrameRegistry`/`MetalSurfaceBlitter`
消费的 pixel buffer。因此不能在当前 `NativeSurfaceView` 上只修改 `vo` 字符串；如果
保留 CAMetalLayer/blitter，同时让 mpv 直接占用同一个 NSView，两个 producer 会竞争同一
显示区域和生命周期。

时序补充：mpv 0.41 的 `wid` option 在 `options/options.c` 中带有 `UPDATE_VO` 标记，
media-kit OHOS controller 已实际采用 `vo=null → wid → vo=gpu-next` 的运行时切换。
所以 B2 不被“player 已初始化”这一点本身阻塞；真正的边界是 macOS wrapper 的裸
`NSView*` 生命周期，以及切换前后 render-context owner 的互斥。

## 必须新增的接口边界

若选择 B2，至少需要：

- native surface 创建阶段把真实 `NSView*` 的 intptr handle 传到 mpv，而不是使用
  player handle 或 Flutter view id；
- 新的 macOS VideoOutput backend，明确不创建 `TextureHW` 和 render context；
- 明确 mpv child window 的 resize、screen change、detach、dispose 顺序；
- 停止当前 `NativeFrameRegistry`/`MetalSurfaceBlitter` producer，避免双重绘制；
- Flutter overlay 与 mpv child window 的 z-order、鼠标/键盘输入和全屏行为验收；
- HDR 配置不再只依赖 `CAMetalLayer` 的 `CAEDRMetadata`，而要记录 gpu-next 实际
  选择的 Vulkan surface format/color space 和 macOS layer 状态。

## 当前决策

B2 的 stock mpv renderer 已验证可以启动，但 stock macOS backend 不消费外部
`NSView*`，所以 B2 的 Flutter 嵌入路线尚未成立；现有 Flutter/native-surface 架构也
不具备直接接入条件。生产链路继续 A（render API + Texture/NativeSurface），直到完成
一个修改过 mpv macOS backend 的 native-window 设计和原型；不在现有
`NativeSurfaceView.swift` 中叠加临时 `wid` 或把 `CAMetalLayer` 当作 mpv gpu-next target。

源码纠偏（2026-09-06）：mpv 0.41 的 `MacCommon.config()` 无条件调用
`initView()`/`initWindow()`，`initWindow()` 创建 mpv 自己的 `NSWindow`。因此
`NativeWindow.Bind`/`wid` 写入不能作为外部 view 嵌入证据；若不 fork mpv backend，B2
只能保留为 standalone renderer 参考，不能进入 Flutter。

源码依据：

- `media_kit_video/macos/.../TextureHW.swift`
- `media_kit_video/common/darwin/Classes/plugin/VideoOutput.swift`
- `media_kit_video/common/darwin/Classes/plugin/NativeSurfaceView.swift`
- `media_kit_video/lib/src/video_controller/native_video_controller/real.dart`
- [mpv render API](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/render.h)
- [mpv Cocoa embedding example](https://github.com/mpv-player/mpv-examples/tree/master/libmpv/cocoa)

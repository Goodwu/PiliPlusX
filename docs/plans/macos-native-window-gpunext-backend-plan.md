# macOS native-window gpu-next backend 实施计划

更新时间：2026-09-06

本文只描述 B2（libmpv C API + Cocoa 外部窗口 + `vo=gpu-next`）的实现边界。
注意：源码审计已发现 stock mpv 0.41 macOS gpu-next backend 无外部 `NSView*` 嵌入路径；
本文后续实现前置条件是先修改/维护 mpv macOS backend，而不是继续堆叠 Dart `wid` bridge。
它不改变当前生产链路，也不把 B2 的 renderer 原型结果当作 HDR/DV 验收。

## 目标和非目标

目标：在隔离 media-kit/PiliPlusX 原型中，让 mpv 自己管理 Cocoa 视频输出，确认
`vo=gpu-next` 的实际画面可以嵌入 Flutter macOS PlatformView，并完成 resize、暂停、
seek、换源、前后台和销毁重建。

非目标：

- 不复用当前 `CAMetalLayer` 作为 gpu-next render target；
- 不同时运行 `TextureHW`/`MetalSurfaceBlitter` 和 mpv-owned window；
- 不因 `VO: [gpu-next]` 日志直接宣称 HDR、EDR、Dolby Vision 或 DV passthrough；
- 不先替换 universal `Mpv.framework`，也不改变当前 production lockfile。

## 所有权协议

```text
Flutter PlatformView
  owns wrapper NSView lifetime
  -> native backend captures stable NSView* while attached
  -> mpv receives wid=(intptr_t)NSView*
  -> mpv owns child video window/layer and gpu-next renderer
  -> Flutter only lays out the wrapper and controls Player
```

必须满足：

1. `wid` 必须是实际 Cocoa `NSView*`，不能是 player handle、Flutter view id、Metal
   layer 指针或 OHOS surface id。
2. wrapper 创建完成后才能设置 `wid`；在 wrapper detach/dispose 前必须先停止 mpv
   视频输出、设置 `vo=null` 或释放 player，再释放/注销 wrapper。
3. 一个 player 同时只能有一个 video output owner。进入 native-window 模式前，先
   串行销毁 `VideoOutput`/`TextureHW`/render context；回退 Texture 前反向执行：
   停止 mpv window VO → 清除 `wid` → 创建 Texture output → 重新注册 render context。
4. `generation`、player handle 和 native view identity 必须成组校验；旧 view 的回调
   不能修改新 output。

## 建议 API 形态

先在 media-kit 实验分支定义显式模式，不复用 `useNativeSurface` 的含义：

```text
VideoOutputMode.texture
VideoOutputMode.darwinBlitSurface
VideoOutputMode.darwinMpvWindow
```

原生 channel 至少需要：

```text
NativeWindow.Attach(handle, generation) -> {
  capable, nativeViewHandle, generation
}
NativeWindow.Detach(handle, generation) -> { detached, generation }
NativeWindow.Resize(handle, generation, width, height)
NativeWindow.State(handle, generation) -> {
  mode, vo, widBound, renderer, visibleFrame
}
NativeWindow.Frame(handle, generation) -> {
  frame
}
```

`nativeViewHandle` 只能在原生侧生成并在 wrapper 存活期间有效；Dart 不得自行构造或
缓存裸指针。若现有 channel 不适合传 intptr，使用原生侧按 player handle 保存的
opaque token，再由 native 侧完成 `wid` 绑定。

当前代码仍不具备 mpv-owned backend 所需的完整接口：W0 已实现 `Attach`、`Detach`、
只读 `State` 和真实 AppKit `Frame` 事件；这些接口只观察/管理 wrapper token，attach
状态尚未驱动 mpv，`createNativeOutput` 也仍忽略 `windowHandle`。源码审计还确认：
Darwin 的 Dart `NativeVideoController` 目前只能通过 `NativePlayer` 的 FFI context
调用 `mpv_set_property_string`，Swift 插件只持有 `NSView`，两侧没有现成的安全绑定
通道。因此不能把 W0 token 直接写入 `wid`，也不能照搬 OHOS 的“surface ID 进 Dart”
实现。下一步必须新增由 generation/handle 保护的 native-window binding bridge，在
view 存活期间把真实 `NSView*` 绑定到同一个 `mpv_handle*`，并在 native owner 侧完成
attach/detach。

时序约束：`createNativeOutput()` 早于 Flutter `AppKitView` 创建，不能在其中绑定
native window。当前 `PlatformViewVideo` 已传入 `handle/generation`，Dart 已由
`NativeSurface.Ready` 事件触发 Attach，并在 controller dispose 路径触发 Detach；该
空壳时序还需要真实 Flutter App 运行证据，之后才允许把 Attach 的 token 交给
mpv-owned backend。

## mpv 时序

### Attach

```text
create wrapper NSView
  -> stop/dispose existing VideoOutput render context
  -> mpv set vo=null
  -> mpv set wid=(intptr_t)wrapper NSView
  -> mpv set vo=gpu-next
  -> set gpu-api=vulkan / target color options
  -> wait VIDEO_RECONFIG + first visible frame
```

如果当前 libmpv 版本不能安全地在初始化后完成 `wid`/`vo` 切换，则原型必须改为
在 player 初始化前创建 wrapper 并传入选项；不能用反复 setProperty 或延时掩盖失败。

mpv 0.41 `options/options.c` 将 `wid` 标记为 `UPDATE_VO`；media-kit OHOS controller
也已经使用 `vo=null → wid → vo=gpu-next` 的运行时顺序。因此 B2 的核心时序在 mpv
选项层面是可行的，macOS 新增工作是取得真实 Cocoa `NSView*` 并保证旧 Darwin
render-context owner 已经停止，而不是假设 mpv 只能在初始化前接收 `wid`。

### Detach / fallback

```text
block new output operations
  -> vo=null
  -> clear wid / detach mpv child window
  -> wait render/output stopped
  -> release wrapper child ownership
  -> create Texture or Darwin blit output
  -> publish new generation
```

每个 await 后检查 player/source/generation/view identity；失败时保持 fail-closed，
返回 Texture/SDR fallback，不保留一个看似 active 但没有有效 owner 的 native 状态。

## 实施阶段

### W0：只读/空壳验证

- 原生 wrapper 返回真实 NSView token；不启动 mpv 视频。
- 验证 token 生命周期、窗口尺寸、Flutter PlatformView z-order 和销毁回调。
- 通过条件：token 不重复、不悬空，重复创建/销毁 20 次无崩溃。

当前审计状态：token 生命周期、`NativeWindow.Attach/Detach` 空壳、真实 Flutter Attach、
明确 controller dispose 后的 graceful Detach 和 20 次隔离 harness 已通过。真实
Flutter 当前 wrapper 已通过独立于 `VideoOutput.Resize` 的 AppKit frame bridge：
`FrameReportingView` 发出 `NativeWindow.Frame`，`NativeWindow.State` 可按
`handle/generation` 读回 token/frame。页面返回只有在本次运行确实触发 dispose 时才
计入 Detach 证据。B2 mpv-owned child-window 的 renderer resize/reconfiguration 仍未
验收。证据见
`docs/status/macos-cocoa-gpunext-w0-flutter-runtime-20260906.md`。现有 `NativeSurfaceViewFactory` 只上报
`handle/generation/rendererReady`；现有 `NativeSurfaceOutput` 仍是
`darwin-cametal-layer` 状态机；新增的 token channel 仍只做 token/frame 验证，不驱动
mpv。已补充 factory owner 的 release 路径以允许 Detach 真正释放 macOS view；仍不能把现有
player handle 或 `CAMetalLayer` 指针直接作为 `wid`。详细证据见
`docs/status/macos-cocoa-gpunext-w0-interface-audit-20260906.md`。

### W1：隔离 media-kit B2

- 复制官方 Cocoa libmpv 示例的 `wid` 设置方式到 media-kit 实验 backend。
- 使用 arm64 mpv 0.41 探针和固定 PQ 片。
- 通过条件：日志同时出现 `VO: [gpu-next]`、`file-loaded`、`VIDEO_RECONFIG`、可见
  首帧；不创建 `mpv_render_context`，不产生当前 blitter 所需的 pixel buffer。

当前进展：独立 Cocoa host 已完成 renderer 和播放后 graceful shutdown 的子集验证；
3 次运行均观察到 `VO: [gpu-next]`、`playback-restart`、`shutdown`，退出码均为 0。
证据见 `docs/status/macos-cocoa-gpunext-lifecycle-20260906.md`。这还不是 media-kit
或 Flutter PlatformView 集成，W1 的剩余工作是将同一所有权协议移植到隔离 media-kit
backend，并取得真实 visible frame 证据。

补充验证：在 `mpv_initialize()` 完成后再执行 `vo=null → wid → vo=gpu-next`，同样
取得 `VO: [gpu-next]`、libplacebo/MoltenVK 和 `playback-restart`。因此 media-kit
可以保留“先创建 player、后创建 native surface”的总体生命周期；实现时仍必须先
停止旧 render-context owner。证据见 `docs/status/macos-cocoa-gpunext-postinit-20260906.md`。

resize 探针暂不通过：父 Cocoa window 调整为 `640x360` 后，日志没有出现第二次
`Window size`/明确 resize reconfiguration。该结果不能证明 mpv resize 一定失败，但
证明 W2 需要显式 native resize API、child-window frame 读取和前后状态证据；记录见
`docs/status/macos-cocoa-gpunext-resize-20260906.md`。

2026-09-06 media-kit 接口审计补充：

- OHOS 的 `_attachNativeSurface` 可以直接把真实 surface ID 写入 `wid`，随后执行
  `vo=null -> wid -> vo=gpu-next`；这是 OHOS 专用 surface contract，不能迁移为
  macOS token contract。
- macOS W0 的 `NativeWindow.Attach` 返回的是防悬空的 opaque token，刻意不是
  `NSView*`，也不是 `CAMetalLayer*`。将 token 数值写成 `wid` 没有语义依据，属于
  错误绑定，即使日志出现 `VO: [gpu-next]` 也不能作为成功。
- media-kit 当前 `NativeVideoController` 的 `setProperty` 位于 Dart FFI，Swift
  `MediaKitVideoPlugin` 没有同一 `mpv_handle*` 的所有权；所以 W1 的最小新增接口
  必须选择以下一种明确方案：
  1. 在 media-kit native/FFI 边界新增一次性 `bind(handle,generation,NSView*)`
     操作，由 native 侧调用 `mpv_set_property` 并持有 binding 状态；或
  2. 在严格实验模式下返回经 generation 保护的 native view handle，Dart 立即完成
     `vo=null -> wid -> vo=gpu-next`，不缓存裸指针，并在 detach 前清除 `wid`。
- 默认配置、OHOS、现有 Darwin Texture/NativeSurface 路径均不得启用上述实验桥接。
  W1 先只验证同一个 player 的 `mpv_handle*` 与真实 Cocoa `NSView*` 是否完成绑定，
  再进入可见首帧和 resize；没有 binding 证据时不得把 W1 标为通过。

实现进展：media-kit 已加入默认关闭的 `useNativeWindow` 实验开关。开启时会创建无
`CAMetalLayer`/blitter/timer 的 `MpvWindowView` wrapper，并通过 generation 保护的
`nativeViewHandle` 立即执行 `vo=null -> wid -> gpu-api=vulkan -> vo=gpu-next`；普通
`useNativeSurface`、OHOS 和生产默认值未改变。Dart 静态分析及 Swift parse 检查通过，
此前测试宿主的 CocoaPods file list/插件模块环境不完整；依赖恢复后已取得 Debug
Flutter/Xcode 构建和真实 binding/detach 运行证据，但尚未取得
`VIDEO_RECONFIG`、可见首帧，不能把该实现标为 W1 整体通过。

 W1 运行复核已推进到 renderer 边界：依赖恢复后测试宿主 Debug 构建成功；隔离运行中
真实 `NSView*` 绑定成功，日志为 `NativeWindow.Bind: bound=true` 和
`Set property: wid="40331357440" -> 1`。随后当前 libmpv 返回
`Video output gpu-next not found!`，说明绑定链路已通过但当前 artifact 没有 gpu-next
VO。W1 的 binding 子门通过，renderer/可见首帧门失败；下一步是提供包含
mpv 0.41 + libplacebo + Vulkan/MoltenVK 的 macOS 实验 artifact，再复跑同一固定片，
不把当前黑屏归因于 Cocoa view 或把 B2 标成完成。

最新复核补充：同步 Dart FFI `mpv_set_property` 会在 Flutter 主线程进入 Cocoa VO
创建时等待 mpv rendezvous，造成属性切换后的假死。实验 bridge 已改用异步 command
切换，实际加载本地 mpv 0.41 后取得 `VO: [gpu-next]`、libplacebo/Vulkan/MoltenVK、
reconfig 和首帧日志；但隔离 app 截图仍为黑色，所以 W1 仍停在 visible-frame 子门。
后续验收必须同时包含截图/可见像素和 child-window 层级证据，不能用 renderer 日志替代。

源码纠偏（2026-09-06）：进一步检查同一 mpv 0.41 探针发现，`MacCommon.config()` 在
macOS gpu-next 初始化时无条件调用 `initView()` 与 `initWindow()`；后者创建新的 mpv
`NSWindow`，没有接收或附着外部 `NSView*`。因此 W1 的 `NativeWindow.Bind` 只证明
media-kit 把地址写入了 `wid`，不证明 mpv backend 消费了该地址。当前 B2 stock 路线
停止在“renderer 可启动但嵌入不可用”；若不先做 mpv backend fork，不能继续以 Flutter
PlatformView child-window 为实现目标。

### W2：Flutter PlatformView 集成

- 把 W1 wrapper 放入最小 Flutter macOS 页面。
- 验证 Flutter 控件覆盖、鼠标/键盘、resize、全屏和窗口跨屏。
- 通过条件：视频和控件均可见，mpv child window 不越界、不吞掉不属于视频的手势。

### W3：HDR/DV 证据

- 记录 gpu-next 实际 renderer、surface format/color space、Metal layer 状态、source
  transfer/primaries、DV profile/RPU/BL/EL 字段。
- 固定 PQ、真实 DV、同流 SDR 各跑一次；取得截图/可见帧和 EDR headroom。
- 只有真实 PQ/DV 播放、实际 EDR 输出和同构建产物证据齐全，才允许评估 native HDR。

当前 W3 复核：隔离 fork 已完成 PQ 输入、VideoToolbox、gpu-next 和可见窗口验证；
默认 SDR target 下 external layer 保持 `HDR=false`，而显式设置
`target-prim=bt.2020,target-trc=pq` 后进入 `HDR=true/wantsEDR=true` 和 PQ
colorspace；再按 NativeSurface 契约切换到 `target-trc=linear` 后，进入
`ExtendedLinearITUR_2020 + rgba16Float + CAEDRMetadata.hdr10 + wantsEDR=true`，
并在两轮 attach/recreate 中重复成立。这证明 target color contract、layer 配置和
重复生命周期诊断子门通过。进一步将 macOS Vulkan swapchain 从实际的
`bgr10a2Unorm` 约束到 `rgba16Float` 后，present 后 format 子门也通过；但这仍不等于
AppKit compositor 已激活。`headroom > 1`、可见高光和亮度证据仍未通过。下一步应
取得该 mpv layer 的实际 EDR/可见输出证据，不能把 `gpu-next`、PQ 解码、metadata、
`rgba16Float` 或 `wantsEDR=true` 当作 native HDR 证据。

DV 前置条件：本机现有 PQ/HLG/SDR 素材中没有确认的 Dolby Vision profile/RPU/BL/EL
输入。开始 W3-DV 前必须先取得已标注 profile 的确切 DV 样本；在此之前，HLG+BT.2020
只能作为 HDR 控制，不得提升为 Dolby Vision 证据。

macOS 26 补充：已在隔离 fork 中验证 `preferredDynamicRange=.high`、
`contentsHeadroom=10`、`rgba16Float`、extended-linear BT.2020、HDR10 metadata 和
`wantsEDR=true`。这些配置在初次及重建 attach 后均成立，但公开 API 仍只给出屏幕
maximum/potential EDR，未提供 mpv layer 的实际 compositor headroom。W3 不能因此
标记完成；下一步必须取得屏幕/窗口实际高光或亮度测量证据，或者明确记录当前环境
只能验证配置而不能验证物理输出。

## 回退和停止条件

### Artifact 注入验收纪律

`LIBMPV_LIBRARY_PATH` 不能替换已经由 Swift Package/CocoaPods 链接进 app 的
`Mpv.framework`。临时 mpv 0.41 试验必须在隔离 app 副本中直接替换
`Contents/Frameworks/Mpv.framework/Versions/A/Mpv`，重新签名，并用 `vmmap` 确认进程
同时加载该 framework、libplacebo 和 Vulkan/MoltenVK。只有在此证据成立后，才可以把
黑屏或 `Video output gpu-next not found!` 归因到新 artifact 的运行行为。

- 任一阶段失败，回到 `VideoOutputMode.texture` 或当前 Darwin blit path，不修改生产
  默认值。
- 如果 Flutter PlatformView 无法稳定承载 mpv child window，B2 只保留为独立 Cocoa
  播放 backend，不继续强行接入 Flutter。
- 如果 B2 能稳定播放但 surface/color space 仍为 SDR，结论只能是“gpu-next renderer
  集成成功、HDR 输出未验证”，不能用它替代 A 路线的 HDR 诊断。

## 2026-09-06 W1 可见输出复核更新

使用持续运动 BT.709 控制片和实际加载的 mpv 0.41 artifact 后，隔离宿主取得
`MPVPROP vo=gpu-next`、`hwdec-current=videotoolbox`、BT.709 `videoParams`，并在同一
进程的独立 `package:media_kit` 窗口中截到可见彩条。Flutter 主窗口的 PlatformView
目标区域仍是黑色。

因此 W1 的 renderer 子门和独立窗口 visible-frame 子门通过，但 Flutter 嵌入子门失败。
`NativeWindow.Bind`/`wid` 只能证明请求链路，不能证明 stock macOS backend 消费外部
`NSView*`。W2 必须暂停在当前 ownership 边界，先评估 mpv backend fork 或等价替代
host；继续改 Flutter token、frame 或手势层级不改变这个结论。

## 2026-09-06 fork 候选运行复核

在独立的 `/Users/wuweiwei1/src/ohos-native-build/mpv` 工作树中，对 mpv 0.41 macOS
`MacCommon` 增加了最小外部 `NSView` 绑定路径：`wid` 被解释为同进程的 `NSView*`，
mpv 自己的 `MetalLayer` 挂到该 view，并让 Vulkan macOS context 使用外部 view 的
drawable size。该补丁只用于候选验证，未进入 media-kit 或产品默认路径。

- `meson setup` 使用 `libmpv=true`、`cocoa=enabled`、`swift-build=enabled`、
  `vulkan=enabled`、`gl=disabled`；`ninja -C /tmp/mpv-macos-gpunext-embedded -j4`
  成功，产物为 arm64 `libmpv.dylib`。
- 首次启用 OpenGL 分支时失败于当前源码与本机 libplacebo 7.360 的 API 不匹配
  (`PL_SAMPLER_EXTERNAL_YUV`/`sampler_type`)，不是外部 view 补丁的编译错误；本轮
  只关闭不参与 Vulkan gpu-next 验证的 GL 分支，不把该依赖差异扩展为产品修复。
- 将该产物只替换到隔离 `media_kit_test.app` 并重新签名后，真实绑定日志为
  `NativeWindow.Attach ... capable=true`，Flutter 主窗口播放器区域出现持续运动
  彩条；同一进程的 on-screen window 列表只有 `media_kit_test` 主窗口，没有 stock
  路径中的独立 mpv 子窗口。
- 首次运行暴露了 AppKit backing scale/drawable resize 问题：视频只占目标区域约一半
  尺寸。随后让 external-view 路径参与 Vulkan resize，并明确设置 backing-pixel
  `drawableSize`；第二次运行已按完整 16:9 显示控制片，黑边符合比例，且同一进程仍
  只有 Flutter 主窗口。

因此 fork 候选已通过控制片嵌入和初始尺寸子门，但尚未通过完整 resize、detach 和
生产生命周期验收；下一道门是记录 resize 前后尺寸、detach 后无残留输出，再进入
HDR/DV 输入。OHOS 模拟器的“软件解码、RGBA”约束不参与这条 macOS fork 判定。

后续生命周期尝试观察到 native view deinit/init（token 1→2），但窗口仍为 `800x632`；
fullscreen 快捷键没有形成可测 resize，UI harness 的坐标拖拽也未稳定获得窗口控制权。
该尝试只作为“未通过/未证实”记录，不能替代窗口服务的前后尺寸证据。随后加入隔离
宿主的自动 resize 模式，实际取得 `CGWindowList` 的 `640x552` 窗口、仍可见的完整
Flutter/gpu-next 控制片，以及 `vo=gpu-next`/VideoToolbox 日志；因此初始 resize 子门
现已通过，但重复 resize、detach、销毁重建仍未通过。

随后自动模式在 resize 后 dispose player，取得 `MpvWindowView deinit`、
`NativeSurfaceViewFactory released`、`NativeWindow.Detach(... detached=true)`，且 detach
后进程仍只有 `640x552` 的 Flutter 主窗口。因此单次 detach 子门已通过；重复销毁重建、
新 generation 重新 attach 和完整导航生命周期仍未通过。

继续运行自动生命周期宿主后，第一轮 token 1/handle 完成 detach，第二轮页面重建取得
新 handle、token 2、重新 `NativeWindow.Attach`、`vo=gpu-next`、VideoToolbox 解码和
再次 detach。由此隔离 SDR 的销毁重建/重新 attach 子门通过；用户导航、前后台和 HDR/DV
验收仍待执行。

随后使用本地 HEVC Main10/P010/BT.2020/PQ 素材复跑：`video-params` 明确为 PQ，
`vo=gpu-next` 和 VideoToolbox 均通过，Flutter 内有可见帧；但 native output 仍为
`active=false`、`headroom=1.0`。因此 fork 路径的 PQ 解码/处理已验证，native HDR 输出
仍未验证；本机没有确切 DV 输入，不能把该结果扩展为 Dolby Vision 结论。

## 2026-09-06 旁路采集与下一道门

macOS 26 的 ScreenCaptureKit 已可作为独立证据源：`HDRLocalDisplay` + `64RGBAHalf`
能收到真实显示器 `RGhA` 帧，但 IOSurface `ContentHeadroom` 仍为 `1`。因此它可以
证明屏幕采集接口和 HDR 格式可用，不能单独证明 mpv layer 的 HDR 高光已经经过
WindowServer 输出。

下一道门不再是继续增加 fork layer 属性，而是先验证不 fork 的 A/B3 路线：现有
`mpv_render_context` OpenGL → half-float pixel buffer → `MetalSurfaceBlitter` →
`CAMetalLayer` 是否能在同一素材和显示器上取得真实色彩/EDR/可见帧证据。一次 fork
localhost PQ 联测虽确认 `p010`/BT.2020/PQ 输入，却在 Flutter 启动中出现
`vo=gpu-next: Failed initializing any suitable GPU context`；该结果不再作为优先
方向。stock mpv 独立窗口 overlay 可作为窗口级集成对照，但不等价于 PlatformView
嵌入。只有 A/B3 和 overlay 均不能满足目标时，才重新评估 fork。OHOS 的软件解码/
RGBA 模拟器约束仍不参与此 macOS 门。

## 2026-09-06 架构复核后的纠偏与执行顺序

独立架构复核后，B1/B3 的分类修正如下：

- B1（mpv 自建 Cocoa 窗口）可行，保留为 standalone renderer/输出对照；它不等于
  Flutter 内嵌方案，也不等于 HDR 已通过。
- stock B2（`wid` 直接交给 macOS `gpu-next`）在当前版本的外部 `NSView` 嵌入路径
  仍不成立。
- B2 fork（Flutter/media-kit 管理宿主 view，mpv backend 管理 MetalLayer、swapchain
  和色彩输出）技术上可行，但按当前决策只保留为最后备选，不是当前推荐路线。
- B3（`vo=libmpv`/`mpv_render_context_*`）不是“整体不可行”，但它是另一条传统
  render-context 路线，不提供独立的 gpu-next 结论；只有正确建立 render context
  后才能单独评价其 HDR 能力。不能用 `No render context set` 证明 libmpv 或 HDR
  不可行。

当前严格串行顺序调整为：

1. 先做捕获校准：在同一显示器和同类宿主层显示已知线性值 `0.5/1/2/4` 的 Metal
   色块，固定 display ID，记录 ScreenCaptureKit 帧的实际像素格式、色彩空间、
   IOSurface headroom，并确认采样区域确实对应目标 layer。
2. 再做 A/B3 输出对照：PQ 六分区素材同时记录 `video-target-params`、有效峰值/参考
   白、OpenGL FBO/half-float pixel buffer 的色彩空间和提交前的浮点像素；不能用普通
   截图或重新渲染的 screenshot 代替提交帧。只有 A/B3 失败后，才把同一测量项移植到
   fork 的 Vulkan surface。
3. 根据对照结果定位层级：提交前已被压缩则查 gpu-next target/tone mapping；提交前
   正确而 Metal/采集异常则查 swapchain 与 layer 色彩交接；两个对照都异常再查显示
   模式和采集配置。绝对 nits 最后用硬件亮度测量完成。
4. 在生产接入前补 native binding 串行事务：view 必须保持存活到 renderer 完成解绑，
   bind/detach 共享 generation 校验，排除 Dart 异步调用造成的过期绑定竞争。

特别注意：当前 backend 将 `linear`、PQ、HLG 汇总为 HDR 布尔值，并固定声明
`maxLuminance=1000`、`opticalOutputScale=100`、`contentsHeadroom=10`。这只是候选
配置，不是已经证明的数值契约；`target-trc=linear`、半浮点 swapchain 或
`wantsEDR=true` 都不能单独证明输出超过 SDR reference white。下一轮先验证数据流，
再决定是否修改这些生产外部层属性。

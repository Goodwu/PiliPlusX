# macOS Cocoa libmpv gpu-next W1 media-kit 边界审计

更新时间：2026-09-06

## 结论

W1 不能通过“把 OHOS 的 `wid` 代码复制到 Darwin”完成。OHOS 的 `wid` 是真实
surface ID；macOS W0 的 `NativeWindow.Attach` 返回的是 generation 保护的 opaque
view token。token 不是 `NSView*`，不能作为 mpv `wid`。

## 当前接口证据

- `media_kit_video/lib/src/video_controller/ohos_video_controller/real.dart` 的
  `_attachNativeSurface` 在锁内执行 `vo=null`、写入真实 surface ID、再设置
  `vo=gpu-next`。
- `media_kit_video/lib/src/video_controller/native_video_controller/real.dart` 的
  `setProperty` 通过 `NativePlayer` FFI context 调用 mpv 属性；当前 W0 的
  `attachNativeWindow` 只调用 `NativeWindow.Attach`、保存 token 并读取 State，
  没有绑定 mpv。
- `media_kit_video/common/darwin/Classes/plugin/NativeSurfaceViewRegistry.swift`
  的 `DarwinViewTokenRegistry` 只保存弱引用 `NSView`、handle 和 generation；
  `Attach` 返回 token/frame，未返回或绑定 `NSView*`。
- `MediaKitVideoPlugin.swift` 当前能访问 Cocoa view token，但没有 Dart
  `NativePlayer` 的 `mpv_handle*`；因此 Swift channel 目前不能直接替同一个 player
  调用 `mpv_set_property`。

## W1 不变量

1. 不把 token、Flutter view id、player handle 或 `CAMetalLayer*` 当作 `wid`。
2. 不改默认配置，不让 OHOS 或当前 Darwin Texture/Metal blit 路径进入实验 backend。
3. 只有在 `handle + generation + live NSView` 三者同时匹配时才允许绑定。
4. detach 顺序必须是 `vo=null -> 清除 wid/停止 child output -> 释放 binding -> 释放 view`。
5. `VO: [gpu-next]` 只证明 VO 选择；W1 还必须有真实绑定、`VIDEO_RECONFIG` 和可见首帧。

## 下一步

media-kit 已实现严格实验性兼容方案：`useNativeWindow` 默认关闭；Cocoa wrapper 只在
该开关下创建，返回 generation 保护的 `nativeViewHandle`，Dart 立即写入 `wid` 后不再
保存该地址；detach 先执行 `vo=null`、`wid=0`，再注销 view。该方案已取得 Debug
Xcode/Flutter 构建和真实运行的 binding 证据，但仍不能替代优先的 native-side
binding bridge；当前 renderer artifact 缺少 gpu-next，W1 尚未整体通过。

下一步是修复/准备隔离 macOS 测试宿主的 CocoaPods/插件模块环境，然后运行固定测试片：
必须同时记录同一 player/generation 的 `NativeWindow.Bind`、`VO: [gpu-next]`、
`VIDEO_RECONFIG`、可见首帧、resize 和 detach；任一项缺失都保持 W1 未通过。

## 当前验证记录

- `dart analyze`：目标 Dart 文件无 error，只有原有 doc-comment/info 提示。
- `swiftc -parse`：修改的 Swift 文件通过语法解析。
- `flutter build macos --debug --no-pub`（`media_kit_test`）：未进入插件有效编译，
  测试宿主报 `unable to resolve module dependency: file_picker` 和
  `path_provider_foundation`。
- 直接 `xcodebuild`：测试宿主缺少 CocoaPods 生成的
  `Pods-Runner-frameworks-Debug-{input,output}-files.xcfilelist`，因此没有完整的
  Swift plugin compile/runtime 证据。

## W1 运行结果（2026-09-06 19:15）

依赖恢复后，`flutter build macos --debug --no-pub` 成功，随后在隔离
`media_kit_test` 中显式开启 `useNativeWindow: true`，进入单播放器页面并播放本地
固定 H.264 片。结果：

1. Cocoa wrapper 创建成功：
   `MpvWindowView macOS init handle=40271548880 generation=1 token=1`。
2. 同一 handle/generation 的 `NSView*` 绑定成功：
   `NativeWindow.Bind: bound=true`。
3. mpv 确实收到真实 view 地址，而不是 token：
   `Set property: wid="40331357440" -> 1`。
4. 绑定后的 renderer 选择失败：
   `Video output gpu-next not found!`，随后
   `Error opening/initializing the selected video_out (--vo) device.`
5. 因此该次窗口保持黑屏；当前运行没有 `VO: [gpu-next]`、
   `VIDEO_RECONFIG` 或可见首帧证据。

第二次运行从页面返回时，观察到同一 generation 的
`MpvWindowView ... deinit`、`NativeSurfaceViewFactory ... released` 和
`NativeWindow.Detach ... detached=true`；Dart detach 路径在调用 channel 前执行
`vo=null`、`wid=0`。这证明当前实验 bridge 的销毁链路已被实际触发，但由于 renderer
本身未打开，仍不能算视频输出生命周期完整通过。

这次运行把问题分成了两个独立结论：

- B2 的 Flutter PlatformView、generation、真实 `NSView*` 和 `wid` 绑定链路已经通过
  第一条运行证据。
- 当前 media-kit 使用的 macOS libmpv artifact 不包含 `gpu-next` VO；这不是
  `NSView*` 绑定失败，也不能用该 artifact 继续验证 B2 renderer。下一步必须先替换
  为包含 mpv 0.41/libplacebo/Vulkan-MoltenVK 的实验 artifact，再重复同一测试。

## 追加复核：临时 mpv 0.41 注入未生效（2026-09-06 19:24）

为避免把现有 artifact 的失败误判为 mpv 0.41 的失败，使用本地 arm64 探针
`/tmp/piliplusx-mpv-probe.f8a55n/build-v2/libmpv.2.dylib` 设置
`LIBMPV_LIBRARY_PATH`，重新启动隔离 `media_kit_test`。该尝试不能作为 0.41 能力结论，
因为运行进程的 `vmmap` 只显示：

`.../media_kit_test.app/Contents/Frameworks/Mpv.framework/Versions/A/Mpv`

没有显示临时 `libmpv.2.dylib`、libplacebo、Vulkan 或 MoltenVK 映像。结论是：当前
macOS Swift Package/CocoaPods 链路在进程启动时已经链接并加载 `Mpv.framework`，
`LIBMPV_LIBRARY_PATH` 没有替换这个已链接 framework；这次运行仍然是旧 artifact，
不能据此再次宣称 `gpu-next` 不可用。

因此 W1 当前精确状态为：

- binding 子门：通过（真实 `NSView*`、同一 player/generation、`wid` 写入和 detach 顺序均有证据）。
- renderer 子门：未验证；当前 0.6.8 artifact 的 `Video output gpu-next not found!` 仍有效，
  但 0.41 注入尚未发生。
- visible-frame/HDR/DV 子门：未通过，不能从黑屏得出 B2 架构失败，也不能得出 HDR/DV 成功。

下一次试验必须直接替换隔离宿主实际链接的 `Mpv.framework`/XCFramework，或构建一个
明确链接本地 0.41 dylib 的最小 Cocoa host；继续设置环境变量而不检查 `vmmap` 没有意义。

代码状态补充：`bindExperimentalNativeWindow()` 现在只报告 attachment 和异步切换请求
已发出，不再把它直接写成 `nativeSurfaceActive=true`；W1 的 `NativeSurface.Ready` 或
HDR surface probe 也不会单独提升 mpv child-window 的 active 状态。必须有独立的
renderer、可见像素和生命周期证据后，才能增加对应的 active promotion。

## 追加运行复核：renderer 已出图，但出现在独立窗口（2026-09-06 20:21）

使用本地持续运动 BT.709 SDR 控制片，并直接替换隔离宿主实际加载的 `Mpv.framework`
为 mpv 0.41 arm64 后，取得：

- `NativeWindow.Bind: bound=true`；
- `MPVPROP vo=gpu-next`、`hwdec-current=videotoolbox`、`video-format=h264`；
- `VIDEOPARAMS` 为 1280×720、BT.709/BT.1886；
- `vmmap` 同时包含 app 内 `Mpv.framework`、libplacebo 和 Vulkan loader；
- 独立 `CGWindow` `26040`（`package:media_kit`，640×360）截图显示 testsrc2 彩条和时间码；
- Flutter 主窗口 `26019` 的播放器区域仍为黑色。

这次把证据边界收敛为：gpu-next renderer 和独立 mpv 窗口 visible-frame 通过，但
Flutter PlatformView 目标区域 visible-frame 未通过。它证明 stock backend 的窗口
所有权与 Flutter 目标 view 不一致，不证明 B2 Flutter 嵌入成功，也不构成 HDR/DV 结论。
详见 `docs/status/evidence/macos-w1-gpunext-visible-window-20260906/`。

## 追加复核：直接替换隔离 `Mpv.framework`（2026-09-06 19:31）

本次不再使用 `LIBMPV_LIBRARY_PATH`。在构建产物的临时副本中，将实际被应用链接的
`Contents/Frameworks/Mpv.framework/Versions/A/Mpv` 替换为本地 mpv 0.41 arm64 探针，
并对临时 app 重新签名。进程运行后的 `vmmap` 同时显示：

- 临时 app 内的 `Mpv.framework/Versions/A/Mpv`；
- `/opt/homebrew/Cellar/libplacebo/7.360.1/lib/libplacebo.360.dylib`；
- `/opt/homebrew/Cellar/vulkan-loader/1.4.357.0/lib/libvulkan.1.4.357.dylib`。

这证明新 artifact 已真正进入 media-kit 进程，解决了上一轮的注入无效问题。此时
测试页面仍显示黑色视频区域；进程没有观察到 MoltenVK 映像，且在重新创建播放器时
未捕获到 `mpv_create`/`mpv_initialize`/`mpv_set_property` 断点命中。因此本次结果的
边界是：artifact 加载门通过，但播放器调用/VO/`wid`/可见帧门尚未形成有效证据，不能
写成“mpv 0.41 的 gpu-next 在 media-kit 中失败”，也不能写成 B2 播放成功。

下一步应在临时宿主中加入 native-side 明确的 mpv 初始化/属性日志，或用最小 Cocoa
host 直接链接同一替换后的 framework，先取得 `mpv_create -> mpv_initialize ->
vo=null -> wid -> gpu-api=vulkan -> vo=gpu-next` 的完整调用链，再回到 Flutter 页面。

## 追加复核：直接替换 artifact 后的异步属性切换（2026-09-06 19:49）

本次在同一个隔离 app 副本中确认实际加载了本地 mpv 0.41 arm64 `Mpv.framework`，并将
`bindExperimentalNativeWindow` 的 `vo=null -> wid -> gpu-api=vulkan -> vo=gpu-next`
切换改为 `mpv_command_async` 路径。此前同步 `mpv_set_property` 的运行进程通过
`sample` 已显示主线程停在：

`mpv_set_property_string -> vo_create -> mp_rendezvous -> _pthread_cond_wait`

这解释了此前在 `NativeWindow.State` 之后无 `NativeWindow.Bind`、无 renderer 的黑屏：
不是 mpv 0.41 不支持 gpu-next，而是 Cocoa VO 创建等待 Flutter 主线程继续处理。

异步版本取得了以下新证据：

1. 同一 player/generation 的 `NativeWindow.Bind: bound=true`；
2. `Set property: gpu-api=vulkan -> 1`；
3. `VO: [gpu-next]`、libplacebo 7.360.1、Vulkan 1.4.357、MoltenVK 1.4.2；
4. gpu-next reconfig 日志、`first video frame after restart shown`；
5. 该次实际运行的是 H.264 SDR 测试片；其 ffprobe 记录为 BT.601/BT.1886，不能写成
   BT.709，也不能把“完成解码”写成“已经可见输出”。

但复查隔离 app 截图仍为黑色，尚未证明 mpv child window 的像素已经在 Flutter
`AppKitView` 层级中可见。因此本次只通过了 B2 的 renderer/VO 子门，不通过 visible-frame
子门，也不通过 HDR/DV 子门。下一步应专门检查 AppKit PlatformView 的 child-window
层级/可见性和截图证据；不得把 `VO: [gpu-next]` 或首帧日志单独写成画面验收通过。

## 源码纠偏：stock macOS gpu-next 不消费外部 NSView（2026-09-06）

对同一实际加载的 mpv 0.41 探针源码复核后，当前阻塞点进一步收敛：

- `video/out/mac_common.swift` 的 `MacCommon.config()` 无条件执行 `initView()` 和
  `initWindow()`；
- `video/out/mac/common.swift` 的 `initWindow()` 创建新的 mpv `Window`，并将 mpv 自己的
  `View` 加入该窗口；
- mpv 0.41 `--wid` 文档只描述“由具体 VO 支持时才生效”，并列出 X11、Win32、Android
  的句柄语义，没有 macOS `NSView*` 接入契约。

因此之前的 `NativeWindow.Bind` 和 `wid` 日志只能证明 media-kit 传入了一个地址，不能
证明 stock macOS gpu-next 将它作为外部 view 使用。异步属性切换修复了主线程死锁并
证明 renderer 可启动，但不能改变 backend 的窗口所有权。B2 的 Flutter 嵌入路线目前
应标为 **stock backend 的 Flutter 嵌入路径未成立**；若继续，下一阶段必须评估并实现
mpv macOS backend fork 或等价的替代 host，明确把外部 view/layer、resize、detach 和
z-order 纳入 backend 契约。若不接受这类维护面，则回到 A 路线。

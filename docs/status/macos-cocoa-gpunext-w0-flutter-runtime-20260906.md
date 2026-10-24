# macOS Cocoa gpu-next W0 Flutter 运行证据

日期：2026-09-06

## 环境和操作

- App：PiliPlusX macOS debug
- 启动命令：`flutter run -d macos --debug --no-pub`
- 构建结果：`build/macos/Build/Products/Debug/PiliPlusX.app`
- 依赖来源：`.dart_tool/package_config.json` 指向 `/Users/wuweiwei1/src/media-kit`
- 操作：启动 App，进入视频详情页，等待视频 PlatformView 创建和首帧，再关闭视频页并退出
  Flutter run。

## 通过证据

同一个 Flutter debug 进程 `PiliPlusX[69907]` 中观察到：

```text
NativeSurface.Ready ... generation: 1 ... handle: 42636205008
NativeSurface.Ready ... rendererReady: true ... generation: 1
NativeSurfaceView macOS token registered handle=42636205008 generation=1 token=1
NativeWindow.Attach handle=42636205008 generation=1 result=[
  "capable": true, "attached": true, "token": "1",
  "generation": 1, "frame": ["x": 0.0, "y": 0.0,
  "width": 0.0, "height": 0.0]
]
NativeSurfaceView macOS draw ... drawn=true ... size=1920x1080
```

这证明了真实链路已到达：

```text
AppKitView → NativeSurface.Ready → generation 校验 → NativeWindow.Attach
→ opaque token/frame 返回 → 当前 CAMetalLayer 继续绘制
```

Attach 仍是 W0 空壳：没有创建 mpv、没有设置 `wid`、没有切换 `vo`。

## 未通过/未观察项

- 关闭视频页后没有观察到 `NativeWindow.Detach` 日志。
- 随后退出 `flutter run` 也没有观察到 Detach 日志。
- 因此不能声称 Flutter PlatformView 的 detach/dispose 已通过；可能是视频路由复用
  controller，也可能是应用退出时异步 dispose 日志未完成，当前证据无法区分。
- 初始 Attach frame 为 `0x0`，之后 blit layer bounds 变为 `1920x1080`；这进一步说明
  W2 仍需要显式 resize/frame bridge，不能把初始 Attach 当作尺寸验收。

## 后续修正

源码审计发现 macOS `NativeSurfaceViewFactory` 以 `surfaces[handle]` 强持有 view，但
原先没有释放入口；这会让 controller/view 离开后不一定触发 `NativeSurfaceView.deinit`。
现已增加 factory owner 和 `NativeWindow.Detach` 释放路径：先失效 token，再移除该
handle 的 surface owner，并记录 deinit。此次修正后的完整 macOS debug build 已通过；
尚未重新取得 controller dispose 后的 `NativeWindow.Detach` 运行日志，因此仍不把
Detach 标为通过。

修正后的第二次真实运行再次观察到 `NativeWindow.Attach ... attached=true` 和持续
`drawn=true` 帧；关闭视频详情页后仍没有 Detach/release/deinit。源码路径显示页面返回
并不等价于 `NativeVideoController.disposeForRebuild` 或 `Player.dispose`，所以该结果
不能判定 release 路径失败。下一次运行必须触发 HDR/output rebuild 或明确的 controller
dispose，再验收 Detach 顺序。

## 最新运行：正常返回触发的 dispose/Detach

本次使用可控的 `flutter run` 会话（PID `75156`，启动后通过搜索历史打开
`BV1uZ4y1U7h8`），在 4K HDR/Dolby Vision 标记视频可见播放后按 `Escape` 正常返回搜索
结果。该次观察到新的 native surface `handle=41446022096`、`generation=1`，并出现：

```text
dispose player
NativeSurfaceView macOS deinit handle=41446022096 generation=1 token=2
NativeSurfaceViewFactory macOS released handle=41446022096
NativeWindow.Detach handle=41446022096 generation=1 result=[
  "generation": 1, "detached": true, "handle": 41446022096,
  "capable": true
]
```

因此，真实 Flutter App 的正常 controller dispose 已证明会完成
`dispose player -> view deinit -> factory release -> NativeWindow.Detach`，且同一
`handle/generation` 闭合。此前“Detach 未观察到”只适用于历史运行和热重启场景，不能
覆盖本次证据。

同一次运行还观察到当前 Texture/native-surface 路径从初始 `VideoOutput.Resize` 的
`0x0` 变为 `3840x2160`。这证明现有输出状态能收到 Flutter 尺寸事件，但它不是 B2
mpv-owned child window 的显式 `NativeWindow.Resize` 验收；B2 仍需要独立的 native
resize/frame bridge 及前后窗口 frame 证据。

热重启对照中只观察到 `NativeReferenceHolder Disposing`，没有上述 Detach 顺序；热重启
属于 Dart/引擎重置，不作为 graceful controller dispose 证据。

## 最新运行：真实 AppKit frame bridge

在修正后的 macOS debug 构建（可执行文件 SHA-256
`849afb639edf4e1f1349dbfc504581be217314ffe5a51356416ba01782e37223`）中再次打开
`BV1uZ4y1U7h8`，原生 view `handle=41926291408`、`generation=1` 产生了：

```text
NativeSurfaceView macOS frame changed frame=(0.0, 0.0, 3840.0, 2160.0)
NativeWindow.Frame {
  handle: 41926291408, generation: 1,
  frame: { x: 0.0, y: 0.0, width: 3840.0, height: 2160.0 }
}
```

该事件由 `FrameReportingView.setFrameSize` 产生，独立于
`VideoOutput.Resize { width: 3840, height: 2160 }`；后者仍表示视频/纹理尺寸。新增的
`NativeWindow.State(handle,generation)` 只读接口可读回同一 token 和 AppKit frame，
不会设置 mpv、改变 `vo` 或修改当前 renderer。

这证明当前 Flutter PlatformView wrapper 的 frame bridge 已能报告真实 native view
尺寸；尚未证明父 Cocoa window 缩放时 B2 mpv child-window 会完成 `VIDEO_RECONFIG` 或
renderer resize，因此不提升 W1/B2 的 mpv resize 验收等级。

随后包含 `NativeWindow.State` Dart 接线的新构建（可执行文件 SHA-256
`4d6fa6c670f419e7aebe99c7a897ccdaf7a1f2bbf8e64e9987150a0ad1fbbe2f`）进一步真实调用
`NativeWindow.State`，结果与 Attach 闭合：

```text
NativeWindow.Attach handle=30138143824 generation=1 token=1 frame=0x0
NativeWindow.State: handle=30138143824 generation=1 token=1 frame=0x0
NativeWindow.Frame: handle=30138143824 generation=1 frame=3840x2160
NativeWindow.Detach handle=30138143824 generation=1 detached=true
```

这完成了 W0 的 `Attach → State → Frame → Detach` 运行证据；仍只说明当前 wrapper
owner 生命周期，不说明 mpv 已绑定 `wid`。

## 结论

W0 的真实 Flutter Attach、graceful Detach 和当前 wrapper 的 native frame bridge 均已
通过；W0 仍不包含 mpv-owned child-window 的 renderer resize。W1 仍不得绑定 mpv `wid`；
下一步是在隔离 B2 backend 中验证父窗口缩放、child-window frame 和 renderer
reconfiguration，再进入 Flutter PlatformView 的 mpv-owned 集成。

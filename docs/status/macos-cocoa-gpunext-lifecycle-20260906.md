# macOS Cocoa libmpv gpu-next 生命周期证据

日期：2026-09-06

## 范围

在官方 `mpv-examples/libmpv/cocoa` 隔离副本中，使用本机 arm64 mpv 0.41 探针，
执行 B2：libmpv C API、Cocoa `NSView*` 作为 `wid`、`vo=gpu-next`、Vulkan/MoltenVK。
实验输入是固定 PQ 片，但本记录只验收 renderer 和生命周期，不验收 HDR/EDR 可见输出。

为避免过早退出，实验逻辑在 `MPV_EVENT_FILE_LOADED` 后等待 `MPV_EVENT_IDLE`，再调用
`quit`；收到 `MPV_EVENT_SHUTDOWN` 后退出 Cocoa App。每次都是独立进程。

## 结果

编译成功，运行 3 次，全部正常退出码 0：

```text
compile_status=0
run=1 exit=0
run=2 exit=0
run=3 exit=0
```

每次都观察到关键事件和 renderer：

```text
event: start-file
event: video-reconfig
[cplayer] info: VO: [gpu-next] 1920x1080 yuv420p10
event: playback-restart
event: video-reconfig
event: shutdown
```

没有使用 SIGTERM 结束进程；第一次早退脚本曾在首个 idle 直接 quit，已修正并不作为
本结果依据。

## 结论

- B2 的基本 `attach → gpu-next render → playback-restart → quit → shutdown` 生命周期
  在独立 Cocoa host 中通过。
- 这证明 mpv-owned window 路径不是只能够初始化 renderer，也能正常停止和销毁。
- 尚未覆盖 Flutter PlatformView、Flutter overlay/z-order、窗口 resize/跨屏、输入、
  seek/换源、真实 visible frame、EDR headroom 或 HDR/DV 输出；这些仍属于 W2/W3。
- 不能把本证据外推为当前 PiliPlusX production backend 已经支持 gpu-next。

## 后续源码纠偏（2026-09-06）

本记录中的“attach”是独立 Cocoa host 的 mpv renderer 生命周期，不等于 stock mpv
macOS gpu-next 将外部 `NSView*` 作为嵌入容器。对 mpv 0.41 源码复核后，
`MacCommon.config()` 仍会创建自己的 `NSWindow`/`View`；若目标是 Flutter 内嵌，必须
先维护 mpv macOS backend fork。该记录继续作为 B1/stock renderer 对照，不作为 B2
Flutter 嵌入通过证据。

对应实施计划：[macOS native-window gpu-next backend plan](../plans/macos-native-window-gpunext-backend-plan.md)。

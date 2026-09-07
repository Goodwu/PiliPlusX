# macOS Cocoa libmpv gpu-next 初始化后绑定证据

日期：2026-09-06

## 实验目的

验证 media-kit 当前生命周期假设：player 已完成 `mpv_initialize()` 后，才创建/取得
Cocoa native surface，再通过运行时属性执行：

```text
vo=null → wid=(intptr_t)NSView* → vo=gpu-next
```

实验使用官方 Cocoa libmpv 示例的隔离副本、本机 arm64 mpv 0.41 探针和固定 PQ 片，
不修改 PiliPlusX 或 media-kit 工作树。

## 结果

初始化前只设置 `vo=null`；`mpv_initialize()` 返回成功后调用：

```c
mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &wid);
mpv_set_property_string(mpv, "vo", "gpu-next");
mpv_set_property_string(mpv, "gpu-api", "vulkan");
mpv_set_property_string(mpv, "target-prim", "bt.2020");
mpv_set_property_string(mpv, "target-trc", "pq");
```

随后加载素材，日志确认：

```text
[vo/gpu-next/vulkan] Initializing GPU context 'macvk'
[vo/gpu-next/libplacebo] Initialized libplacebo v7.360.1
Driver ID: VK_DRIVER_ID_MOLTENVK
event: file-loaded
[cplayer] VO: [gpu-next] 1920x1080 yuv420p10
event: playback-restart
```

运行时还观察到 `Metal layer pixel format changed: bgr10a2Unorm`，但实际选择的
surface configuration 是 `A2R10G10B10_UNORM_PACK32 + VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`。

## 结论

- player 已初始化后再绑定 `wid`、再切换 `vo=gpu-next` 在 mpv 0.41 探针中可行；
  “必须在 mpv_initialize 前绑定”不是当前阻塞条件。
- 该结果支持 media-kit B2 的 attach 时序：先停止旧 render-context owner，再设置
  `vo=null`、绑定真实 Cocoa `NSView*`、设置 `vo=gpu-next`。
- 仍未验证 Flutter PlatformView、resize/detach、可见截图、EDR headroom 或 HDR/DV
  输出；SRGB surface 也不能作为 HDR 通过证据。

补充纠偏：该记录证明的是 mpv 0.41 stock macOS renderer 在属性切换时可以启动，
不是证明 stock gpu-next 消费了外部 `NSView*`。macOS backend 会创建自己的窗口；
Flutter 内嵌仍需 backend fork 或回到 A 路线。

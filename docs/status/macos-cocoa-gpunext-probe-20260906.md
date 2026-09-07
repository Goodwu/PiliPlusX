# macOS Cocoa libmpv gpu-next 原型证据

日期：2026-09-06

## 目的

验证“libmpv 是否完全不能使用 gpu-next”这一说法。实验不接入 PiliPlusX，使用
mpv 官方 `libmpv/cocoa` 示例，向 libmpv 传入 Cocoa `NSView*` 并链接本机 arm64
mpv 0.41 探针；同时区分“renderer 启动”与“外部 view 实际被 macOS backend 消费”。

## 实验配置

- 示例来源：[mpv-player/mpv-examples/libmpv/cocoa](https://github.com/mpv-player/mpv-examples/tree/master/libmpv/cocoa)。
- mpv 源码：`v0.41.0`，本机 arm64 探针构建。
- libmpv：`/tmp/piliplusx-mpv-probe.f8a55n/build-v2/libmpv.2.dylib`。
- 输入：`/Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4`。
- Cocoa 嵌入句柄：官方示例中的 `(intptr_t) self->wrapper`，即 `NSView *`。
- 额外设置：`vo=gpu-next`、`gpu-api=vulkan`、`target-prim=bt.2020`、`target-trc=pq`。
- 日志级别：libmpv `v`。

编译核心命令：

```sh
clang -I /tmp/piliplusx-mpv-probe.f8a55n/mpv-0.41.0/include \
  -o cocoabasic cocoabasic.m \
  -L /tmp/piliplusx-mpv-probe.f8a55n/build-v2 \
  -Wl,-rpath,/tmp/piliplusx-mpv-probe.f8a55n/build-v2 \
  -lmpv.2 -framework Cocoa -framework CoreVideo \
  -framework Metal -framework QuartzCore
```

## 观测结果

窗口嵌入和播放生命周期事件成功推进：

```text
event: start-file
event: file-loaded
event: video-reconfig
event: playback-restart
event: idle
```

renderer 日志确认：

```text
[vo/gpu-next] Probing for best GPU context.
[vo/gpu-next/vulkan] Initializing GPU context 'macvk'
[vo/gpu-next/libplacebo] Initialized libplacebo v7.360.1
GPU 0: Apple M4
Driver ID: VK_DRIVER_ID_MOLTENVK
[cplayer] VO: [gpu-next] 1920x1080 yuv420p10
[cplayer] VO: Description: Video output based on libplacebo
[vo/gpu-next/mac] Metal layer pixel format changed: bgr10a2Unorm
```

该运行在约 8 秒后由实验脚本终止，终止不是 mpv 播放错误。编译只有官方示例使用
旧 Cocoa 窗口常量产生的 deprecated warning，无链接或初始化错误。

## 结论

1. “libmpv 不支持 gpu-next”作为绝对说法不成立。libmpv 进程可以实际运行
   `vo=gpu-next`、libplacebo 和 Vulkan/MoltenVK。
2. 当前 PiliPlusX/macOS 仍不同：它的 Darwin native controller 默认 `vo=libmpv`，
   Flutter Texture 使用 `MPV_RENDER_API_TYPE_OPENGL` 的 `mpv_render_context`。这个
   render API 不会因为替换 libmpv 就自动切换到上面已经验证的 gpu-next/`wid` 路径。
3. 该实验只证明 B2 的 renderer 可启动；不能仅凭 `wid` 参数证明 stock macOS
   backend 已把外部 `NSView*` 作为输出容器，也不证明 HDR 已经输出到显示器：
   本次实际选择的 Vulkan surface configuration 仍是
   `A2R10G10B10_UNORM_PACK32 + VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`，没有截图、EDR
   headroom 或亮度计证据。因此不能把它报告为 native HDR/DV 通过。
4. 后续路线选择从“B 是否可行”变为“是否接受修改 mpv macOS backend 的维护代价”。
   若要保留当前 Flutter Texture/CAMetalLayer 所有权，则继续 A；若目标是 Flutter
   内嵌 gpu-next，则必须先给 mpv backend 增加外部 view/layer、尺寸、输入和生命周期
   契约，不能只继续修改 Dart `wid` bridge。

## B3 对照：`vo=libmpv`

在同一个官方 Cocoa 示例、同一个 libmpv 0.41 探针、同一个 `wid` 和同一个 PQ 输入
上，只把 VO 改为 `libmpv`，并保留详细日志，结果为：

```text
[vo/libmpv] fatal: No render context set.
[cplayer] fatal: Error opening/initializing the selected video_out (--vo) device.
```

这不是编译或窗口句柄错误，而是因为 `vo=libmpv` 要求先创建
`mpv_render_context`。因此 B3 不是绝对不可行：创建 render context 后它就是当前 A
路线；不可行的是把 B3 当作“不创建 render context 也能获得 gpu-next”的窗口路径。
该结果进一步确认当前 PiliPlusX Darwin 的 `vo=libmpv + MPV_RENDER_API_TYPE_OPENGL`
与 B2 的 `wid + vo=gpu-next` 是两条不同的输出架构。

## 来源边界

mpv 官方 render API 文档说明可绕过 render API 使用 `wid`，client API 明确 macOS
支持原生窗口嵌入；官方示例同时说明 native window embedding 与 render API 是两种
不同方法：[render.h](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/render.h)、
[client.h](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/client.h)、
[mpv-examples README](https://github.com/mpv-player/mpv-examples/blob/master/libmpv/README.md)。

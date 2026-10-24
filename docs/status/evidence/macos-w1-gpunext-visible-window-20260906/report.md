# macOS W1：gpu-next 可见输出与窗口归属

运行时间：2026-09-06 20:21–20:23

## 测试边界

- 隔离宿主：`media_kit_test`，默认关闭实验开关之外，本次仅在宿主中开启
  `useNativeWindow: true`。
- 片源：`luna-sdr-720p-bt709-control.mp4`，H.264、1280×720、yuv420p、BT.709、
  30fps、20 秒持续运动。
- 实际加载的 `Mpv.framework` 是本地 Homebrew mpv 0.41 arm64 `libmpv.2.dylib`；
  `vmmap` 同时看到 app 内 `Mpv.framework`、libplacebo 7.360.1 和 Vulkan loader。

## 运行证据

同一 player/generation 的日志包括：

```text
NativeWindow.Bind: bound=true
VIDEOPARAMS ... videotoolbox ... w: 1280, h: 720 ... bt.709 ... bt.1886
MPVPROP vo=gpu-next
MPVPROP hwdec-current=videotoolbox
MPVPROP video-format=h264
```

主 Flutter 窗口的播放器区域仍是黑色，但 `CGWindowList` 发现同一进程的独立窗口：

```text
kCGWindowNumber: 26040
kCGWindowName: package:media_kit
kCGWindowOwnerPID: 8906
kCGWindowBounds: X=769, Y=550, Width=640, Height=360
kCGWindowIsOnscreen: 1
```

该窗口截图中显示完整的 testsrc2 彩条和时间码；主窗口截图没有这些像素。

证据文件：

- [Flutter 主窗口黑色截图](./flutter-main-black.png)
- [mpv 独立窗口可见截图](./mpv-child-visible.png)
- [CGWindowList 窗口列表](./cgwindow-list.txt)
- [renderer 映像 vmmap](./vmmap-renderer.txt)

## 结论

1. 本轮证明了 mpv 0.41 的 `gpu-next` 在 libmpv 进程中实际初始化并产生了可见帧；
   不是“没有 gpu-next”，也不是“解码失败”。
2. `NativeWindow.Bind` 和 `wid` 写入只建立了请求链路；可见像素没有进入 Flutter
   PlatformView 的目标区域，而是出现在 mpv/窗口系统创建的独立 `package:media_kit`
   窗口中。
3. 因此 B2 的精确状态是：renderer 子门和独立窗口 visible-frame 子门通过；stock
   macOS backend 的 Flutter 嵌入子门未通过。不能把本轮写成 B2 Flutter 播放成功，
   也不能把它写成 HDR/DV 验收。
4. 下一步不再修改 Flutter token、frame 或手势层级；若要继续 B2，必须改变 mpv
   macOS backend/host 的窗口所有权并重新验证 attach、present、resize、detach 和
   z-order。否则回到 A 路线。

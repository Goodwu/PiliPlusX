# macOS Cocoa libmpv gpu-next resize 探针

日期：2026-09-06

## 实验

在已验证的官方 Cocoa B2 隔离 host 中，播放固定 PQ 片并在主线程定时执行：

```objc
[window setContentSize:NSMakeSize(640, 360)];
```

同时启用 libmpv verbose 日志，观察 `vo/gpu-next` 的 `Window size` 和
`video-reconfig`。

## 观测

编译、gpu-next 初始化、播放和 shutdown 均成功，但日志只出现初始尺寸：

```text
[cplayer] VO: [gpu-next] 1920x1080 yuv420p10
[vo/gpu-next] Window size: 1920x1080
event: video-reconfig
event: shutdown
```

没有观察到第二次 `Window size` 或明确的 resize reconfiguration。该探针没有足够的
mpv/Cocoa child-window instrumentation，因此不能区分“父窗口尺寸未传递”“mpv child
window 未跟随”或“日志没有在该路径报告变化”。

## 结论

- B2 的 renderer 和基本生命周期仍通过；resize 暂不验收。
- 不能把 `NSView*` 作为 `wid` 的初始绑定证据扩展成 Flutter PlatformView resize 已经
  支持。
- W2 必须增加显式 native resize API、child-window frame 读取和 resize 前后
  `Window size/video-reconfig` 证据。

## 源码边界补充

mpv 的 macOS Cocoa 输出源码在 `config()` 中根据 `auto_window_resize` 调用
`window.updateSize(wr.size)`；这属于 mpv 自己的窗口/视频尺寸管理。当前 media-kit
Darwin native-surface 链路没有把 Flutter/PlatformView 父 `NSView.bounds` 映射为
mpv-owned child window 的显式 `Resize` 调用。因此本次探针缺少第二次尺寸日志，不能被
解读为 B2 renderer 不支持 resize；它只证明 W2 的父子窗口尺寸桥接尚未实现和验收。

后续源码纠偏：同一 mpv 0.41 macOS `gpu-next` backend 的 `config()`/`initWindow()` 会
创建 mpv 自己的 `NSWindow`，并没有消费外部 `NSView*` 的嵌入分支。因此这里的 resize
结果只能作为 stock standalone renderer 的历史记录；要验收 Flutter 内嵌 resize，必须
先完成 mpv backend fork，再重新定义父 view 到 Metal layer 的尺寸契约。

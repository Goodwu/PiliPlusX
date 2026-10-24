# macOS PQ 对照播放器证据

日期：2026-09-06

## 输入

```text
/Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4
SHA-256 45da67b82cc14d0f903d6af6c416d205658840baff301361518c7e20827af931
```

## 独立 mpv

### Render API 边界复核

本轮直接核对 mpv 0.41.0 源码：`video/out/vo_libmpv.c` 的 render backend 列表只有
`render_backend_gpu` 和 `render_backend_sw`；`video/out/gpu/libmpv_gpu.c` 的 GPU
路径通过 `gl_video_init`/`gl_video_render_frame` 工作，OpenGL 是当前 libmpv render
API 的宿主接口。源码没有一个可由 `mpv_render_context_create` 直接选择的
`MPV_RENDER_API_TYPE_VULKAN`、`MPV_RENDER_API_TYPE_METAL` 或 gpu-next backend。

因此这里的独立命令使用的是 mpv 自己管理的 `vo=gpu-next`，而 PiliPlusX 当前
`TextureHW.swift` 使用的是 `MPV_RENDER_API_TYPE_OPENGL`。前者证明了主机 mpv 的
libplacebo/Vulkan/gpu-next 能力，不能证明后者升级同一 `Mpv.framework` 后会自动切换
到 gpu-next。当前 App 的下一步必须先在 A（传统 libmpv render API）与 B（mpv 直接
管理 `vo=gpu-next` 的隔离 Cocoa 原型）之间做路线选择，再做 universal artifact。

media-kit 平台配置也支持这个边界：Darwin `NativeVideoController.create` 默认写入
`vo=libmpv`，而 OHOS controller 在绑定 XComponent 后才显式写入 `vo=gpu-next`。
所以当前 macOS 日志若出现 `vo=libmpv`，并不与独立 mpv 的 `vo=gpu-next` 矛盾；它们
是不同的输出归属和 render API。B 路线不能通过修改一个共享 Dart 配置字段完成。

mpv 0.41 官方头文件给出了 B 路线的实际接口边界：render API 文档允许绕过
`mpv_render_context_*`，把原生窗口句柄传给 `wid`；client API 文档明确该嵌入方式支持
macOS，但也警告 GUI toolkit 和生命周期可能有问题。故 B 的第一版应使用独立 Cocoa
`NSView`/窗口句柄承载 mpv-owned `vo=gpu-next`，不把当前 `CAMetalLayer` 或 Flutter
Texture 当作已支持的 gpu-next target。参考：[render.h](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/render.h)、
[client.h](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/client.h)。

进一步边界：mpv 0.41 的 VO 文档把 macOS `vo=libmpv` 标为特殊的 `cocoa-cb` 路径，
所以 `wid` 的 macOS 支持不能直接证明 libmpv/cocoa-cb 使用 gpu-next。后续原型拆为
B1（独立 mpv/直接 `vo=gpu-next`）、B2（libmpv C API + `wid` + `vo=gpu-next`，先
验证 stock macOS backend 是否消费外部 view）和 B3（libmpv `vo=libmpv`/cocoa-cb
对照），分别记录实际 renderer；不能把 B3 的 cocoa-cb 名称写成 gpu-next。源码复核
后，B2 的 renderer 可以启动，但 stock macOS backend 无外部 `NSView*` 嵌入路径；若
要继续 B2，必须维护 mpv macOS backend fork。参考：[vo.rst](https://github.com/mpv-player/mpv/blob/v0.41.0/DOCS/man/vo.rst)。

执行：

```sh
/opt/homebrew/bin/mpv --no-config --vo=gpu-next --gpu-api=vulkan \
  --audio=no --frames=1 --osd-level=0 --msg-level=all=v \
  /Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4
```

实际版本：

```text
mpv v0.41.0
libplacebo v7.360.1
GPU: Apple M4 / MoltenVK 1.4.2
```

日志确认：

- `gpu-next` 成功初始化 libplacebo 和 Vulkan/MoltenVK；
- 解码格式为 `1920x1080 yuv420p10 bt.2020-ncl/bt.2020/pq/limited`；
- GPU 枚举包含 `VK_EXT_hdr_metadata`、`VK_COLOR_SPACE_BT2020_LINEAR_EXT` 和
  `VK_COLOR_SPACE_HDR10_ST2084_EXT`；
- 本次实际选择的 surface configuration 是
  `A2R10G10B10_UNORM_PACK32 + VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`，不是 HDR
  显示输出证明。

## 与 App 内嵌依赖的边界

当前 Debug App 内 `Mpv.framework` 为 arm64+x86_64 universal，字符串显示 mpv
`0.36.0`，构建选项含 `-Dlibplacebo=disabled`。因此独立 mpv 只提供了颜色处理
和渲染能力的参考基线，不能证明 App 内嵌 mpv 具备相同的 libplacebo 路径，也不能
证明当前 M27P20 显示器产生了 EDR/HDR 可见输出。

当前系统 `SPDisplaysDataType` 只报告 M27P20 3840x2160@60，没有 HDR/EDR 字段；
故同帧亮度比较仍未验收，不能报告绝对 nits 或“高光超过 SDR 白点”。

## media-kit macOS 测试应用实际播放

为补齐“固定 PQ 片确实进入 Flutter/media-kit 播放链路”的证据，使用
`/Users/wuweiwei1/src/media-kit/media_kit_test` 的 Debug macOS 测试应用，通过其
URI 输入加载同一文件。由于测试应用没有 macOS 文件访问 entitlement，直接访问
`Downloads` 被系统拒绝；将文件复制到该应用自己的容器后，容器内副本 hash 仍为
`45da67b82cc14d0f903d6af6c416d205658840baff301361518c7e20827af931`，URI 播放成功，
窗口显示可见视频帧，时长为 00:02。

这证明固定 PQ 文件可以实际进入 media-kit 的 macOS 视频输出链路，但该测试应用
默认使用 Flutter Texture，未配置 PiliPlusX 的 HDR 来源决策，也没有取得 native
surface 的 EDR/half-float 数值回读。因此它是“输入可播放/帧可见”证据，不是
PiliPlusX 原生 HDR 或同帧亮度通过证据；测试应用运行后已退出，原有测试工程改动
已恢复，仅保留 media-kit Darwin 工作树中的既有修改。

## 当前 native surface 参考应用

## PQ 单位诊断（2026-09-06）

本轮重新核对了实际打包的 `Mpv.framework`，而不是用 Homebrew 独立 mpv 的能力代替
产品依赖：

```text
mpv 0.36.0
-Dlibmpv=true -Dlibplacebo=disabled -Dvideotoolbox-gl=enabled
```

因此产品内嵌 mpv 不具备独立 mpv 0.41/libplacebo 的同一套 HDR tone-mapping 实现。
虽然二进制仍包含 `target-peak`、`tone-mapping` 等 mpv 属性字符串，但当前证据没有
证明 `target-peak` 在这条 `libplacebo=disabled` 的产品路径中实际参与渲染；不能把
独立 mpv 的默认值或行为移植过来，也不能用任意增益修正。

固定测试片生成器给出的 PQ 编码值为：

```text
100=0.50807842, 203=0.58068888, 400=0.65257860,
1000=0.75182710, 2000=0.82742464, 4000=0.90257239
```

这只是输入的 ST 2084 code value，不是线性 EDR buffer 的 nits。native 参考应用在
Metal blit 前后取得的六个 `rgba16Float` 区域最大值为
`0.37768555, 0.5527344, 0.7163086, 0.88720703, 0.9614258, 0.99316406`，且前后
一致。因此当前证据排除了 Metal blit 改变数值，但显示这些值的上游输出已被压在
约 `0..1` 范围；这指向 mpv/native render boundary 的输出映射，尚不足以单独断言
具体是 target peak、plain-gpu 色彩变换还是别的默认参数。

`NativeSurfaceView.swift` 当前使用 `CAEDRMetadata.hdr10(...,
opticalOutputScale: 100.0)`。Apple 文档规定，对于 display-referred linear
extended-range buffer，scale=100 表示 buffer 的 `1.0` 对应参考显示器 `100 nits`；
这与 `rgba16Float` extended-linear 输出契约一致，不应被当作随意的亮度增益。
若改成 `10000`，必须先证明 buffer 是 normalized pixel format；当前不是该证据。
参考：[Apple CAEDRMetadata opticalOutputScale](https://developer.apple.com/documentation/quartzcore/caedrmetadata/hdr10%28minluminance%3Amaxluminance%3Aopticaloutputscale%3A%29)。

当前结论：先保留 `opticalOutputScale=100`，不修改 gain；下一步应在同一内嵌 mpv
实例中记录 `target-peak` 的 set/readback、实际输出格式和同一帧的 source/render
数值，再决定是否需要修复上游输出映射。

### 当前产品二进制边界（2026-09-06）

从测试宿主实际加载的 `Mpv.framework` 中读到：

```text
mpv 0.36.0
-Dlibmpv=true
-Dlibplacebo=disabled
-Dgl=enabled -Dgl-cocoa=enabled
-Dvideotoolbox-gl=enabled
```

因此当前产品的 `vo=libmpv` 是旧 `vo_gpu`/OpenGL render API；本产品没有把 mpv 0.41
独立可执行文件的 libplacebo/gpu-next 行为带入这条结论。mpv 当前文档对
`target-peak` 的 nits 语义仍可作为方向参考，但不能代替 0.36 旧 renderer 的实测。
Apple 官方 `CAEDRMetadata` 定义则明确：`opticalOutputScale=100` 时，display-referred
linear buffer 的 `1.0` 被解释为参考显示器 `100 nits`。所以当前数值契约是：

```text
reference_display_nits ~= linear_half_float_value * 100
```

这是参考显示器光学输出的解释，不是当前面板的实测亮度。但源码级复核已确认，mpv
0.36 的旧 `vo_gpu` 在 `video/csputils.h` 中定义 `MP_REF_WHITE=203.0`，并在
`video_shaders.c` 中把 PQ 的 10000-nit 输出按 203 归一；`video.c` 再把显式
`target-peak` 转成 `target_peak / 203`。因此当前 `target-trc=linear` producer 的
mpv 语义是“`1.0 = 203 cd/m² reference white`”，不是天然的“`1.0 = 100 nits`”。

这使当前 `opticalOutputScale=100` 与 mpv 0.36 的 reference-white 单位成为明确的
候选不匹配：若中间没有重标定，单位一致的隔离实验值应是 `opticalOutputScale=203`，
而不是通过 shader/Metal gain 补偿。它仍不是面板实测亮度；必须先做 scale=100/203
同帧 A/B，再以固定显示设置观察 SDR-white 与高光关系。

源码依据：[mpv 0.36.0 `video/csputils.h`](https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/video/csputils.h)、
[旧 `vo_gpu` `video.c`](https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/video/out/gpu/video.c)、
[旧 `vo_gpu` `video_shaders.c`](https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/video/out/gpu/video_shaders.c)。

当前必须分开记录两种换算：

```text
mpv_reference_nits ~= linear_half_float_value * 203
Apple optical-output interpretation at scale=100 ~= linear_half_float_value * 100
```

不能继续把 `linear_half_float_value * 100` 当作 mpv 输出的真实参考光学值，也不能在
A/B 前把 `opticalOutputScale=203` 写入生产默认值。

### `opticalOutputScale` 隔离 A/B（2026-09-06）

已给测试宿主增加仅诊断用的 `MEDIA_KIT_AUTO_OPTICAL_OUTPUT_SCALE`，默认仍为 100，
并用同一个已构建的 macOS 宿主、同一 `luna-pq-six-bands.mp4`、同一
`target-peak=1000`、同一 `target-trc=linear` 和同一 reset/configure 时序运行两次：

| 项目 | scale=100 | scale=203 |
| --- | --- | --- |
| NativeSurface PQ metadata 日志 | `opticalOutputScale=100.0` | `opticalOutputScale=203.0` |
| active / rendererReady | `true / true` | `true / true` |
| pixel format | `rgba16Float` | `rgba16Float` |
| current headroom | `2.0304816` | `2.0304816` |
| 六区 half-float | `0.5034..4.8359` | `0.5034..4.8359` |
| Metal blit 前后 | 相同 | 相同 |

因此 scale 只改变显示侧的 CAEDRMetadata，不改变 mpv producer 或 Metal 数值；这是预期
的边界，也说明不能用 half-float A/B 单独证明哪一个 scale 在屏幕上正确。scale=203
运行仍能正常显示六区测试图，但尚未完成固定显示设置下的 SDR-white/高光视觉对照，
所以 `203` 仍是候选值，不进入生产默认。

### macOS 支持 Dolby Vision，但当前 B3 不能直接交给系统做原生 DV

Apple 官方说明兼容 Mac 的内置显示器和 Pro Display XDR 支持 Dolby Vision；其他
HDR10 外接显示器会将 Dolby Vision 转换为 HDR10。[Apple Mac HDR 文档](https://support.apple.com/en-au/102205)
Apple 的应用指南则要求原生 DV 使用 AVFoundation 的 `AVPlayer+AVPlayerLayer`，或向
`AVSampleBufferDisplayLayer` 提供保留逐帧 DV metadata 的 10-bit sample buffer。
[Apple Dolby Vision 指南](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)

当前 B3 在进入 `CAMetalLayer` 前已完成 P010 → linear RGB 渲染，`CAEDRMetadata` 只
描述 EDR 输出，不会让 macOS 从 RGB 重建 DV RPU。因此结论是：

```text
macOS 系统支持 DV 显示                 = 是
当前 libmpv B3 RGB surface 可直接交给系统原生 DV = 否
AVFoundation native playback 可借助系统 DV pipeline = 是，需单独实现并按 profile 验收
```

这不推翻 B3 的 HDR10/HLG/EDR 路线，只把“原生 DV”从 B3 的能力声明中剥离出来。

随后在相同窗口尺寸、相同素材和相同显示设置下分别查看两次测试宿主画面：scale=203
的右侧高亮区主观上比 scale=100 更亮、层次更容易拉开；两次都能看到六个灰阶区。
这是 compositor 截图/肉眼的相对观察，不是亮度计结果，也不能证明任意具体区间的
绝对 nits。它支持“scale=100 与 mpv 203 reference-white 可能不一致”的方向，但在
正式采用前仍需用户在目标显示器上确认没有白位过亮、黑位抬升或跨屏异常。

另外使用 `/tmp/luna_pq_macos_e5` 独立应用，将上述六分区素材复制进应用容器，调用
`createNativeOutput`、`configureHdrOutput` 后取得：

```text
videoParams: videotoolbox/p010, 1920x1080, bt.2020-ncl, gamma=pq
NativeSurface.Ready: active=true, rendererReady=true,
  outputEncoding=rgba16Float, headroom=2.0304815769195557,
  potentialHeadroom=10.1524076461792
NativeSurfaceView: drawn=true, pixelFormat=rgba16Float,
  drawableSize=3840x2160
```

六个垂直区域在窗口截图中可见。该参考应用可证明固定 PQ 输入和 Darwin native
surface 的可激活链路，但仍不能替代 PiliPlusX 真实 DV 页面、亮度计或跨状态验收。

在 `PILIPLUSX_HDR_SAMPLE=1 PILIPLUSX_HDR_SAMPLE_INTERVAL=10` 下，native surface
采样到的输入/输出均为 `rgba16Float`，同一帧六区域的归一化 `max(rgb)` 为：

```text
input  = [0.37768555, 0.5527344, 0.7163086, 0.88720703, 0.9614258, 0.99316406]
output = [0.37768555, 0.5527344, 0.7163086, 0.88720703, 0.9614258, 0.99316406]
```

这证明该参考链路在 Metal blit 前后保持了半浮点区域的顺序和值；它是相对数值和
格式证据，不是亮度计 nits，也不能单独证明显示器已把每个编码目标以对应绝对亮度
呈现。

## 同素材 SDR tone-map 参考

同一独立应用以 `useNativeSurface=false` 运行，并实际写入：
`target-prim=bt.709`、`target-trc=bt.1886`、`target-colorspace-hint=auto`、
`tone-mapping=bt.2390`。视频参数仍回读为 `videotoolbox/p010`、BT.2020/PQ，说明
对照只改变输出目标，不改变输入素材。

同一时间点的窗口截图均为 3840x2160：

```text
native half-float reference: docs/status/evidence/luna-pq-six-bands/native-reference.png
SHA-256: d0069faa56b6e1666fcef1e1094819c2a9447a554845b325fedf14d39980b49f
SDR tone-map reference:     docs/status/evidence/luna-pq-six-bands/sdr-tone-map-reference.png
SHA-256: f7eee8df0f24a0baa1c0882e05f6c474eb064cbe2f7996a60751fadaa2bb79da
```

两张截图都能看到六个区域，但截图受当前显示器/窗口合成影响，不能直接作为
绝对亮度或“高光超过 SDR 白点”的证明；真实产品 DV 页面也仍是独立的第三个输入。

## mpv 上游版本差异研究（2026-09-06）

本节用于回答“是否还需要在本地安装多个 mpv 版本做横向比较”。结论是：版本边界已经由官方资料明确，版本对比实验可以跳过；产品最终验收仍不能跳过。

| 版本 | 官方可确认的变化 | 对当前产品的含义 |
|---|---|---|
| 0.36.0 | `vo_gpu_next` 支持 HDR10+ 动态元数据映射，并解析 Dolby Vision 元数据用于动态场景亮度 | 有 DV/HDR 处理基础，但不能据此声称完整 DV RPU、BL/EL 合成或直通 |
| 0.37.0 | libplacebo 变为无条件依赖；gpu-next 仍不是默认输出 | 是当前产品与现代 libplacebo 路径之间的明确构建边界 |
| 0.38.x | 继续要求较新的 libplacebo | 不是单独的 DV 结论，但确认现代 gpu-next 不能脱离 libplacebo 评估 |
| 0.40 | 增加 Linux DRM/dmabuf-wayland 方向的 HDR 直出改进 | 不能直接外推为 macOS 或当前 NativeSurface 已获得该能力 |
| 0.41.0 | libplacebo-based gpu-next 成为默认；改进目标色彩空间、HDR reference white、元数据和 tone mapping | 可作为升级原型的现代参考基线，但 release note 没有承诺具体 DV profile 在 macOS/libmpv 中必然直通 |

官方 stable manual 还明确：HDR10+/Dolby Vision 的信息可以被用于生成带场景亮度的 HDR10 结果，但这不等于把完整 DV 元数据直接交给显示设备。libplacebo 官方说明则包含 Profile 5 转换能力；其 renderer header 对 Profile 7 FEL enhancement layer 也有条件化处理路径。因此“源是 Dolby Vision”与“输出是原生 Dolby Vision”必须继续分开记录。

依据：

- [mpv 0.36.0 release notes](https://github.com/mpv-player/mpv/releases/tag/v0.36.0)
- [mpv 0.37.0 release notes](https://github.com/mpv-player/mpv/releases/tag/v0.37.0)
- [mpv 0.38.0 release notes](https://github.com/mpv-player/mpv/releases/tag/v0.38.0)
- [mpv 0.41.0 release notes](https://github.com/mpv-player/mpv/releases/tag/v0.41.0)
- [mpv stable manual](https://mpv.io/manual/stable/)
- [libplacebo project capability description](https://github.com/haasn/libplacebo)
- [libplacebo renderer header](https://github.com/haasn/libplacebo/blob/master/src/include/libplacebo/renderer.h)

### 决策

当前内置 `Mpv.framework` 为 mpv 0.36.0，构建字符串包含 `-Dlibplacebo=disabled`。因此：

- 不再安排本地多个 mpv 版本的重复对比；
- 不把当前版本日志中的 DV 字段、`target-peak=auto` 或任意增益变化当作原生 DV 证据；
- 后续只有两条有效路径：升级到 `>=0.37 + libplacebo` 并重做集成验收，或保留当前版本并明确声明 DV 为 tone-mapped SDR/base-layer fallback。

### 升级原型的供应链核对

进一步核对当前 media-kit 原生包后，升级入口不是 Dart 层版本号：

- `pubspec.lock` 的 media-kit 包统一固定在 `Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`；
- macOS 视频包 Makefile 固定 `MPV_XCFRAMEWORKS_VERSION=0.6.8` 和对应 SHA-256
  `c396976a267eaaa64bc603f3cc1a2ee02d27c7d5d57935d2458f364afdf0f3cb`；
- SwiftPM 固定下载 `Predidit/libmpv-darwin-build` 的
  `0.6.8_macos-universal-video-default` 各 framework；
- 实际打包的 `Mpv.framework` 已核实为 mpv 0.36.0、`-Dlibplacebo=disabled`。

当前项目使用的 `Predidit/libmpv-darwin-build` release 仍固定为 0.6.8。另核对了
media-kit 更新脚本默认的 `media-kit/libmpv-darwin-build@v0.7.0`：该 release 有
macOS universal XCFramework，但其 `macos-universal-video-default` tarball SHA-256 为
`8e7f96967e5dbb5ae7a95d5778972fcace98dddcd765b4f5196975dec12ecb14`，内含的 `Mpv` slice
仍报告 mpv 0.36.0、`-Dlibplacebo=disabled`、`-Dvulkan=disabled`。

因此准确结论是：现成 universal artifact 存在，但没有可直接把当前 App 切换到
mpv 0.41/libplacebo 的现成 macOS artifact。升级原型仍需取得新的现代 artifact，
再做 media-kit/native surface 集成；不能把 Homebrew 独立 mpv 或测试应用的
libplacebo 能力外推给产品。

截至本次核对，`media-kit/libmpv-darwin-build` 最新 tag 为 `v0.7.2`；v0.7.1/v0.7.2
的 `packages.lock.nix` 仍固定 mpv 0.36.0、FFmpeg 6.0，构建 recipe 仍关闭
`libplacebo`/`vulkan`。所以“上游最新 universal artifact”与“现代 libplacebo
artifact”仍是两件事，不能用 v0.7.2 解决当前产品的能力缺口。

上游 `0.6.8` 的构建源码进一步确认了原因：其 `packages.lock.nix` 固定 mpv
`v0.36.0`、FFmpeg `6.0`；mpv Nix recipe 显式关闭 `libplacebo` 和 `vulkan`，macOS
video 变体仅启用 `gl-cocoa` 与 `videotoolbox-gl`。因此 `vo=gpu-next` 这个配置字符串
不能把当前二进制变成现代 libplacebo renderer；需要改变原生构建依赖和 XCFramework。

升级原型的最小交付物不是 Dart patch，而是一个独立、可回滚的
`macos-universal-video-default` artifact 及其构建账本：mpv/libplacebo/FFmpeg 源码
版本与 SHA、configure log、arm64/x86_64 架构、依赖闭包、各 framework checksum，以及
独立 PQ 片的实际输出证据。在这些证据齐全之前，当前 0.36 fallback 保持不变。

### 本机 mpv 0.41 配置/编译探针（未接入产品）

为验证升级方向不是纯理论，在 `/tmp/piliplusx-mpv-probe.f8a55n` 隔离目录中使用
Homebrew 依赖完成了 mpv 0.41.0 的 Meson 配置和编译：

```text
libmpv=true
libplacebo=required by mpv 0.41
vulkan=enabled
videotoolbox-pl=enabled
gl-cocoa=enabled
swift-build=enabled
```

编译结果：

```text
file: Mach-O 64-bit dynamically linked shared library arm64
size: 4677888 bytes
sha256: a7d58d77587d100c4395dc5030063352e099dabf5e1385b6189110f6b4870f3d
symbols: mpv_create, mpv_get_property, mpv_render_context_create
features: gpu-next, libplacebo, vulkan, videotoolbox-pl
```

本探针的动态依赖仍包括 `/opt/homebrew/opt/libplacebo/lib/libplacebo.360.dylib`、
Homebrew FFmpeg 和 Vulkan loader；只有 arm64，未生成 XCFramework，也未验证 x86_64、
重定位、签名、Flutter/media-kit 接入或真实显示输出。因此它是“源码/本机依赖可编译”
证据，不是产品升级完成证据。

该探针与上游旧 recipe 的差异也已固定：mpv 0.41 直接要求 libplacebo >= 6.338.2，
Vulkan 需要 libplacebo 的 Vulkan 支持和 Vulkan >= 1.3.238，并通过 `videotoolbox-pl`
接入 VideoToolbox；旧 v0.7.x recipe 的 `libplacebo/vulkan` disabled 和仅
`videotoolbox-gl` 不能复用。探针链接到 Homebrew 绝对路径，说明下一步必须做依赖重定位、
双架构和 XCFramework 封装，不能直接复制该 dylib。

本机架构边界也已核对：Rosetta 可执行，但没有 `/usr/local/bin/brew`，因此没有可用于
x86_64 slice 的 FFmpeg/libplacebo/Vulkan 依赖。Xcode SDK 能提供 x86_64 系统框架，不能
替代第三方库 slice；universal artifact 需要上游 Nix/CI 双架构环境或完整的 x86_64
依赖树。

# macOS native HDR 实际运行记录

日期：2026-09-06

## 实际输入与画质选择

- 最新 Debug App：`build/macos/Build/Products/Debug/PiliPlusX.app`
- 页面：`BV1uZ4y1U7h8`，标题“【4K HDR】原来动漫里的世界真实存在！｜Links 杜比视界”
- UI 画质选择：杜比
- 播放请求：`qn=126`；接口返回的可用质量包含 `126,120,112,80,64,32,16`
- 播放 URL 的视频分片包含 `dv1-1`；这证明请求/资源路径带有 DV 提示，但不等于
  mpv 已证明 RPU、profile 或动态元数据已应用。

## mpv / native surface 运行回读

最新 `flutter run -d macos --no-pub` 会话取得：

```text
HDR capabilities: platform=macos, display=true, decoder=false,
  vulkan=false, hcpp=false, reason=native-hdr-layer-not-integrated
Video track codec=hevc, id=1
```

首次空参数事件随后得到实际解码参数：

```text
pixelformat=videotoolbox
hwPixelformat=p010
w=3840 h=2160 dw=3840 dh=2160
aspect=1.7777777910232544 par=1.0
colormatrix=bt.2020-ncl colorlevels=limited primaries=bt.2020
gamma=hlg light=hlg sigPeak=4.926108360290527
chromaLocation=mpeg2/4/h264 rotate=0 stereoIn=mono
```

参数写入后的 mpv 回读也已取得：

```text
generation=1
requested={target-prim: bt.709, target-trc: bt.1886,
  target-colorspace-hint: auto, tone-mapping: bt.2390}
actual={target-prim: bt.709, target-trc: bt.1886,
  target-colorspace-hint: , tone-mapping: bt.2390}
```

首次修正前运行曾报告：

```text
active=false -> active=true
pixelFormat=rgba16Float
colorSpace=extended-linear-bt2020
generation=1
headroom=1.0 -> 2.0304815769195557
```

该首次运行的窗口截图包含可见视频帧，但因当时 native candidate 仍可能被提升，不能
单独作为当前原生 HDR 结论。当前 `HdrSourceMetadata` 已修正为：DV 来源提示遇到
HLG+BT.2020 mpv 参数时仍保留 DV 身份；只有可靠 SDR 参数才清除旧 HDR 身份。

## 修正后复测

同一 Debug App 在修正后重新播放同一页面，取得以下日志：

```text
HDR videoParams: pixelformat=videotoolbox, hwPixelformat=p010,
  w=3840 h=2160, colormatrix=bt.2020-ncl, colorlevels=limited,
  primaries=bt.2020, gamma=hlg, light=hlg, sigPeak=4.926108360290527
HDR decision: source=dolbyVision, primaries=bt2020, transfer=hlg,
  matrix=bt2020, output=toneMappedSdr, surface=texture,
  vo=gpu-next, hwdec=auto, reason=native-hdr-layer-not-integrated
HDR mpv parameter readback: requested={target-prim: bt.709,
  target-trc: bt.1886, target-colorspace-hint: auto, tone-mapping: bt.2390},
  actual={target-prim: bt.709, target-trc: bt.1886,
  target-colorspace-hint: , tone-mapping: bt.2390}
NativeSurface.Ready: active=false, sourceProcessing=mpv-gpu-native-surface
```

这次复测确认：即使 mpv 实际回报 HLG+BT.2020，来源身份仍保持为杜比视界，且
DV-like 来源不会仅凭 HLG 参数晋升为 Darwin 原生 HDR；画面仍通过 Texture/SDR
tone-map 可见播放。`sourceProcessing` 也已改为实际可证明的
`mpv-gpu-native-surface`，不再宣称内嵌 mpv 带有 libplacebo。

## 2026-09-06 最新产品复测

使用当前构建打开 `BV1uZ4y1U7h8`，搜索历史进入目标页面并保持杜比画质选择。日志
记录：

```text
Video quality selection: displayHdr=true, cached=127, target=126, available=126,...
HDR videoParams: videotoolbox/p010, 3840x2160, bt.2020-ncl, limited,
  primaries=bt.2020, gamma=hlg, light=hlg, sigPeak=4.926108360290527
HDR decision: source=dolbyVision, transfer=hlg, matrix=bt2020,
  output=toneMappedSdr, surface=texture, vo=gpu-next, hwdec=auto,
  reason=native-hdr-layer-not-integrated
HDR mpv parameter readback: target-prim=bt.709, target-trc=bt.1886,
  target-colorspace-hint=auto, tone-mapping=bt.2390
NativeSurface.Ready: active=false, rendererReady=true,
  outputEncoding=rgba16Float, headroom=2.0304815769195557
```

## 2026-09-06 target-peak 只读回读

在修正未观测 DV 字段日志语义后，使用 `flutter run` 热重启并重新打开同一 BV，取得：

```text
Video quality selection: displayHdr=true, cached=127, target=126
VideoParams: videotoolbox/p010, 3840x2160, bt.2020-ncl, limited,
  primaries=bt.2020, gamma=hlg, light=hlg, sigPeak=4.926108360290527
HDR decision: source=dolbyVision, transfer=hlg, matrix=bt2020,
  dvProfile=unknown, rpu=unknown, el=unknown,
  dvEnhancement=unknown, dynamicMetadata=unknown,
  output=toneMappedSdr, surface=texture
HDR mpv parameter readback:
  actual={target-prim: bt.709, target-trc: bt.1886,
    target-colorspace-hint: , tone-mapping: bt.2390, target-peak: auto}
NativeSurface.Ready: active=false, rendererReady=true,
  outputEncoding=rgba16Float, headroom=1.0 -> 2.0304815769195557,
  potentialHeadroom=10.1524076461792
```

这次回读证明产品实例当前 `target-peak` 是 `auto`，但只读回读没有证明该属性在
`libplacebo=disabled` 构建中参与实际 HDR 映射；也没有写入任意 peak 或 gain。真实
DV 的 profile、RPU、BL/EL 仍是 unknown/not-observed；`dv1-1` URL 片段和 qn=126
只能证明来源/请求提示，不能证明动态元数据已应用。

窗口截图确认视频帧可见；采样器在该回退路径记录的输入格式为 `bgra8Unorm`，不是
native surface 的 half-float 输入。该复测再次证明：HLG+BT.2020 解码参数不能清除
DV 来源身份，也不能在 native layer 未通过时误报原生 HDR。

## 默认关闭采样器的实际回读

以 `PILIPLUSX_HDR_SAMPLE=1 PILIPLUSX_HDR_SAMPLE_INTERVAL=300` 启动同一 Debug App
并播放同一 BV，采样器在 Metal blit 边界取得了前后数据。示例帧：

```text
HDR frame sample input frame=300 format=bgra8Unorm channel=max(rgb)
  normalized=[p50=0.42745098,p95=0.50980395,max=0.53333336; ...]
HDR frame sample output frame=300 channel=max(rgb)
  linearRegions=[p50=0.45483398,p95=0.4946289,max=0.50439453; ...]
```

六个区域均有记录；采样器默认关闭，只在显式环境变量下每 N 帧执行。当前这次
杜比源因为 `active=false`，native surface 从回退 Texture 收到的是 BGRA8，而不是
half-float FBO；因此不能把这次输出读回解释为 native HDR 亮度证明。代码仍保留
对 native 激活时 `rgba16Float` 输入的采样分支，待取得真实 native activation 后
再补半浮点输入的同帧证据。

## 仍未完成

## 2026-09-06 回退路径生命周期复测

在当前 Debug App、同一 `BV1uZ4y1U7h8` 和同一“杜比”画质选择下，补做了回退路径的
曾尝试做 seek 复测，但一次点击后工具报告“user changed app, re-query”；随后观察到
`04:02` 回到约 `00:10` 只能证明回退路径重新出现画面并继续播放，不能证明 seek
操作本身已被可靠执行。因此本轮记录为“回退路径 replay observed；seek not verified”，
不证明 native HDR 生命周期。

本次运行的 native 状态仍为 `active=false`；虽然 `headroom` 后续从 `1.0` 变为
`2.0304815769195557`，来源仍报告 HLG+BT.2020；当前 videoParams 未提供 DV
profile、RPU 或 BL/EL 字段，因此这些字段均为 unknown/not-observed，不能写成
`dvProfile=none` 或 `rpu=false`，
因此没有把这次状态变化解释为 HDR 亮度通过。暂停/恢复、全屏/退出全屏、换源以及
HDR→SDR→HDR 尚未取得足够可审查的连续证据，仍保持未验收。

本轮显示状态查询命令：

```sh
swift -e 'import AppKit; for s in NSScreen.screens { print("screen=\(s.localizedName) maxEDR=\(s.maximumExtendedDynamicRangeColorComponentValue) maxPotentialEDR=\(s.maximumPotentialExtendedDynamicRangeColorComponentValue)") }'
```

- 这次真实源是 DV 提示 + HLG 解码输出，不是固定 PQ 测试片；尚未完成固定 PQ 片、
  同流 SDR tone-map 和独立 mpv 的同帧亮度比较。
- 2026-09-06 重新用 AppKit 查询当前显示状态：`M27P20` 的
  `maximumExtendedDynamicRangeColorComponentValue=1.0`，
  `maximumPotentialExtendedDynamicRangeColorComponentValue=10.1524076461792`。
  这表示当前运行时还没有观察到 EDR 内容；潜在值大于 1 允许 native surface
  发起 EDR 尝试，但不能把 `maxEDR=1.0` 或潜在值单独写成 HDR 亮度通过证据。
- 本次 `system_profiler` 只报告 1920x1080、60Hz 和显示器标识，不能替代上述 AppKit
  运行时值；headroom 与 native surface 活跃是运行证据，但不是绝对亮度或超过
  SDR 白点的证明。
- 只读 IOKit `IODisplayConnect` 属性进一步显示：`M27P20` 的
  `DisplayAttributes` 声明 `SupportsPQEOTF=Yes`、`SupportsBT2020RGB=512`、
  `SupportsHDRStaticMetadataType1=Yes`，EDID mode 列表包含 HDR static metadata
  与 `DynamicRange=1` 条目；这证明显示器/链路存在 HDR 能力，但不能覆盖当前
  `maxEDR=1.0` 的 compositor 状态，也不能替代可见高光验收。
- 本机 BetterDisplay 的只读状态也识别某条显示记录为 `supportsHDR=1`、`hasHDR=1`，
  报告 HDR 峰值约 1000 nits，并提供 `Toggle HDR for display`。本轮没有执行该切换；
  但它不是继续代码诊断的全局前置条件。
- 2026-09-06 只读核对 BetterDisplay 偏好：某条记录有
  `supportsHDR@Display:114=true`、`hasHDR@Display:114=true`、
  `nitsHDRPeakReported@Display:114=1000`，另有
  `configuredPotentialEDR@Display:111=10.1524076461792`。由于 `Display:111` 与
  `Display:114` 的对应关系未建立，不把该 potential 值绑定给 `M27P20`；这些偏好
  也不是当前 compositor 已启用或画面亮度验收。当前 AppKit `maxEDR=1.0` 只表示
  idle 状态尚未观察到 EDR 内容，不能单独作为全局阻塞结论。
- App 内嵌 mpv 构建明确 `libplacebo=disabled`，native 状态字段已改为
  `mpv-gpu-native-surface`，避免错误宣称 libplacebo。

## 当前 EDR 门控修正

本轮修正 media-kit Darwin `NativeSurfaceOutput`：native HDR 激活前置改为检查实际
窗口屏幕的潜在 EDR 能力（iOS 使用 `potentialEDRHeadroom`，macOS 使用
`maximumPotentialExtendedDynamicRangeColorComponentValue`），因为当前 headroom
可能要在 EDR layer 请求内容后才从 1.0 变化。实际 `headroom`、native 输出报告和
可见高光仍是后续验收条件，不会把潜在值单独当作通过证据。

同时，EDR 查询已绑定到实际 native view 所在的 `window.screen`，不再把
`NSScreen.main` 当作跨屏视频窗口的唯一依据；屏幕参数变化和窗口换屏都会重新计算
active 状态。renderer 未就绪事件也会立即清除旧的 `nativeSurfaceActive`，避免旧输出
状态在换屏或重建后残留。

Dart 事务层现在由同一个 `HdrOutputTransactionGate` 串行 native 配置、参数写入和
回读：捕获 source/player/surface generation，native 调用返回后再次确认事务仍有效；
显示器变化会失效旧 active 状态、reset 输出并重新探测，避免旧事务重新激活已切走的
输出。34 项 HDR 单测中的 2 项覆盖该事务门的交错、过期完成和失败恢复；这仍不是
真实设备生命周期验收。

`HdrCapabilities` 现在同时保留 probe 返回的当前 `headroom` 与潜在
`potentialHeadroom`；即使 `displayHdr` 布尔值不变，headroom 改变也会触发显示状态
刷新。潜在 headroom 仍只作诊断，不参与 native 激活门控。

## 固定 PQ 独立参考应用复测（E5）

为排除产品页面、登录态和外部文件沙盒权限的干扰，使用当前 media-kit 工作树创建
独立 macOS Debug 应用，并把新的六分区固定 PQ 测试片复制到应用沙盒后播放。输入为
`/Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4`，SHA-256 为
`45da67b82cc14d0f903d6af6c416d205658840baff301361518c7e20827af931`。视频参数实际回读
为 `videotoolbox/p010`、`bt.2020-ncl`、`gamma=pq`、`sigPeak=49.261085510253906`。
调用 `createNativeOutput` 和 `configureHdrOutput` 后，最终报告为
`active=true`、`rendererReady=true`、`outputEncoding=rgba16Float`、
`headroom=2.0304815769195557`、`potentialHeadroom=10.1524076461792`；native view
日志显示 `drawn=true`、`pixelFormat=rgba16Float`、`drawableSize=3840x2160`，窗口
截图中视频区域可见。参考应用可执行文件 SHA-256 为
`906ad93ccb966b2f031e855c4e8b68cf8b47414235b28d43b8241c5db1770d59`。

在 `PILIPLUSX_HDR_SAMPLE=1 PILIPLUSX_HDR_SAMPLE_INTERVAL=10` 下，采样器确认 native
surface 的输入和输出均为 `rgba16Float`；六个区域的归一化 `max(rgb)` 在 blit 前后
均为 `[0.37768555, 0.5527344, 0.7163086, 0.88720703, 0.9614258, 0.99316406]`。
这证明相对高光顺序和半浮点数值没有在拷贝边界丢失，但仍不是绝对 nits 证据。

这条 E5 证据证明当前显示器、固定 PQ 输入、mpv native surface 和半浮点绘制链路
可以实际激活；它不等于 PiliPlusX 产品中真实 BV/DV 来源已经完成 native HDR
验收，也不等于已完成亮度计或同帧六区域亮度比较。独立应用初始报告中的
`active=false` 是 surface/frame 尚未就绪，待 `rendererReady` 和 HDR 配置完成后
同一 surface 已转为 `active=true`。

修正后构建：`flutter build macos --debug --no-pub` 通过；当前主应用可执行文件
SHA-256 `0f38ec05334474a4aa406debbf8619d89fed7f930dad047c073abd4575e1a267`。

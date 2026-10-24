# macOS Dolby Vision 输入素材盘点

更新时间：2026-09-06

## 目的

确认当前本地素材是否包含可以用于“DV 解码/普通 HDR 转换/原生 DV”分层验收的
Dolby Vision 输入。没有可确认的 DV profile 之前，不能把现有 HDR10/PQ 或 HLG 结果
扩展成 Dolby Vision 结论。

## 当前结果

使用本机 `ffprobe` 对 `/Users/wuweiwei1/Downloads` 下可见的 MP4/MKV/MOV/M4V 文件
检查视频流 codec、profile、codec tag、像素格式、色彩元数据和 stream side data：

| 素材 | 视频流结果 | 结论 |
| --- | --- | --- |
| `luna-pq-highlight-test.mp4` | HEVC Main 10，`hev1`，10-bit，BT.2020/PQ | HDR10/PQ，不是已确认 DV |
| `luna-pq-six-bands.mp4` | HEVC Main 10，`hvc1`，10-bit，BT.2020/PQ | HDR10/PQ，不是已确认 DV |
| `【4K限免】你的新设备能顶住吗？影视飓风年度样片.mp4` | HEVC Main 10，`hvc1`，10-bit，BT.2020/HLG；DOVI config：Profile 8、Level 7、RPU=1、EL=0、BL=1、compatibility ID=4 | **Dolby Vision Profile 8.x，单层 HLG 兼容** |
| `luna-sdr-720p-bt709-control.mp4` | H.264 High，BT.709/BT.709 | SDR 控制片 |
| `test.mp4`、`test-600.mp4`、`test-1000.mp4` | HEVC Main，8-bit，未声明 HDR 色彩元数据 | 普通 HEVC，不是已确认 DV |

该文件的 `ffprobe` 已明确返回 `DOVI configuration record`，`mediainfo` 也报告
`HDR_Format=Dolby Vision`、`HDR_Format_Profile=dvhe.08`。因此它是当前可用的真实 DV
输入。其他本地文件仍没有可确认的 DV profile；不能用它们替代本片进行 DV 验收。

## 对路线的影响

1. 继续做 B3 的普通 HDR10/EDR 输出验收；PQ 六区片和本片用于真实 DV 转换验收。
2. 对本片记录 codec tag/profile、10-bit、BL/EL/RPU、B3 的 `video-params`、实际可见帧
   和固定显示器结果。由于本片 `EL=0` 且 `compatibility ID=4`，先验证 HLG-compatible
   base layer 是否能稳定进入普通 HDR/EDR。
3. 若本片经 B3 能稳定转换为 BT.2020/PQ 或 HLG HDR 并通过显示验收，默认采用
   `DV converted/fallback`；只有转换失败且产品要求保留动态元数据时，才启动
   AVFoundation `AVPlayer + AVPlayerLayer` PoC。

## 证据边界

- `ffprobe` 的 HDR/DV metadata 识别是输入分类证据，不是显示正确性证据。
- `P010`、BT.2020/PQ 和 10-bit 只证明 HDR10/PQ 形态，不能证明 Dolby Vision。
- macOS 支持 Dolby Vision，也不表示现有 libmpv RGB/EDR surface 能被系统重新识别为
  原生 DV。

## 2026-09-06 B3 实际播放复测

将原始文件复制到测试宿主自己的沙盒容器后，以同一 media-kit macOS Debug 宿主播放。
直接访问 Downloads 和 `/tmp` 均被 App Sandbox 拒绝；这属于文件授权边界，不是解码
失败。沙盒容器副本成功打开并产生可见视频帧。

实际回读：

```text
VideoToolbox: videotoolbox / p010
size: 3840x2160
colormatrix: dolbyvision
primaries: bt.2020
gamma: pq
sigPeak: 4.929096221923828
NativeSurface: active=true, rendererReady=true
pixelFormat: rgba16Float
colorSpace: extended-linear-bt2020
headroom: 2.0304815769195557
Metal draw: drawn=true, pixelFormat=1380411457
```

测试窗口截图中视频内容可见。该证据证明当前 B3 能读入这条 DV Profile 8 单层素材，
并将其转换/渲染到 macOS 的线性 RGBA16Float EDR surface；它仍不证明 Dolby Vision
RPU 被原样交给显示器，也不证明原生 DV passthrough。当前决策因此升级为：B3 普通
HDR/EDR fallback 已有真实 DV 输入的可行性证据，后续重点转为色彩/高光正确性和
暂停、seek、换源、销毁重建回归。

复测后同步修正 media-kit Darwin native-surface 的声明字段，将
`supportedInputFormats` 增加为 `dolby-vision-p8`。该字段只是转换 surface 的输入
契约声明，不代表原生 DV metadata passthrough；修改后的 macOS 测试宿主已重新构建成功。

为下一步同源对照，隔离测试宿主新增了 `MEDIA_KIT_AUTO_TEXTURE=true` 诊断开关：它关闭
native surface/window，使用普通 Texture 并显式设置 `bt.709 + bt.1886 + bt.2390`。
本轮首次对照会话在素材页加载后被 AppKit 外部终止；系统日志显示正常的
`applicationShouldTerminate: NSTerminateNow`，不是解码器崩溃，因此没有产生有效 SDR
对照结果，不能据此修改 HDR/DV 结论。

随后在自动进入单播放器页面的宿主版本中重跑成功。SDR control 的实际回读为：

```text
input: videotoolbox/p010, colormatrix=dolbyvision, bt.2020/pq
target-prim: bt.709
target-trc: bt.1886
tone-mapping: bt.2390
vo: libmpv
hwdec-current: videotoolbox
video-format: hevc
```

普通 Texture 输出有可见视频帧。由此确认同一 Profile 8 DV 输入既能走 B3 的
HDR/EDR surface，也能走 SDR tone-map Texture 回退；这仍是转换/渲染路径证据，
不是绝对亮度、RPU 动态映射或原生 DV passthrough 证据。

### 2026-09-07 B3 同源 DV 生命周期复测

用户确认上一轮退出是手工关闭，不是播放器失败；因此重新启动完整自动生命周期测试。
同一 Profile 8 文件在第一代实例中完成窗口调整、播放器销毁和
`NativeWindow.Detach(detached=true)`；自动重建后第二代实例取得新 handle/token，重新
完成 VideoToolbox/P010、BT.2020/PQ 解码，并再次达到 `active=true`、`rendererReady=true`、
`rgba16Float`、headroom 约 `2.03`，随后也正常 detach。

这关闭了本次 B3 DV 输入的“调整尺寸 -> 销毁 -> 重建 -> 重新 attach -> 销毁”诊断子门。
它不等同于用户导航、前后台、暂停/seek、换源或真实显示正确性验收；这些仍按 macOS
计划单独验证。该结论只属于 macOS B3，不外推到 OHOS。

### 2026-09-07 固定时间点 HDR/SDR 同帧对照

为避免连续播放导致两张截图处于不同画面，隔离宿主增加了仅诊断用的
`MEDIA_KIT_AUTO_START_SECONDS=12`：通过 `Media.start` 定位到 12 秒，收到有效视频参数后
立即暂停，并回读位置为 `0:00:12.000000`。随后分别运行 B3 NativeSurface HDR/EDR 和普通
Texture SDR fallback。

两次桌面截图显示同一云海/太阳/字幕画面，且均有可见帧。HDR/EDR 回读为：

```text
input: videotoolbox/p010, dolbyvision, BT.2020/PQ
target-prim: bt.2020
target-trc: linear
target-peak: 203
tone-mapping: auto
NativeSurface: active=true, rendererReady=true, rgba16Float, headroom=2.03048
```

同一固定时间点的 SDR 回读为：

```text
input: videotoolbox/p010, dolbyvision, BT.2020/PQ
target-prim: bt.709
target-trc: bt.1886
target-peak: auto
tone-mapping: bt.2390
vo: libmpv, hwdec-current: videotoolbox
```

这证明同一 DV Profile 8 输入在当前 macOS B3 中可以稳定输出 HDR/EDR 和 SDR tone-map
两种可见结果；固定画面下主观观察到 HDR/EDR 太阳与云层高光保持，SDR 也无黑屏。没有
亮度计或参考测量时，不把截图升级为绝对亮度、色彩精度或 DV RPU 动态映射正确性的证明。

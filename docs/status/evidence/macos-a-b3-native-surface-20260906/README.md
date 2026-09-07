# macOS A/B3 stock libmpv NativeSurface evidence

日期：2026-09-06

## 测试边界

- 平台：macOS；本记录不代表 OHOS 模拟器或 OHOS 真机能力。
- 播放器：stock libmpv，框架 SHA-256 为
  `5d6e83ee94f35eff70d674e4b86ee4c00ffe36b5656ddbbdb562174f7b2c85d7`。
- mpv 输出：`vo=libmpv`，通过 `mpv_render_context` 的 OpenGL 路径进入现有
  `TextureHW`，再由 MetalSurfaceBlitter 复制到 NativeSurface。
- 测试输入：本地 `luna-pq-six-bands.mp4`，通过 localhost 提供给测试应用，避免
  Downloads 文件访问干扰。
- 本轮没有使用 mpv fork，也没有把 OHOS 结论带入本测试。
- 当前嵌入 `Mpv.framework` 已从二进制确认是 mpv `0.36.0`，构建参数包含
  `-Dlibplacebo=disabled`；本轮 `vo=libmpv` 因此是旧 `vo_gpu`/OpenGL render API，
  不能套用 mpv 0.41 的 libplacebo/gpu-next 语义。

## 已观察事实

播放器日志显示：

```text
vo=libmpv
hwdec-current=videotoolbox
pixelformat=videotoolbox
hw-pixelformat=p010
color space=bt2020-ncl
gamma=pq
sig-peak=49.261086
```

NativeSurface 生命周期显示：

```text
active: false -> true
headroom: 1.0 -> 2.03048
potentialHeadroom: 10.1524
pixelFormat: rgba16Float
colorSpace: extended-linear-bt2020
```

但是 TextureHW/Metal 采样仍报告 `bgra8Unorm`，六个固定区域的值约为：

```text
0.376, 0.552, 0.717, 0.886, 0.960, 0.992
```

第二轮窄诊断确认 native half-float context 已创建，且激活前连续走的是
`rendering regular BGRA route nativeSurface=true`。`active=true` 发生后没有立即出现
half-float render；直到播放器销毁前才观察到一次
`rendering half-float route nativeSurface=true`。这说明 Surface 激活状态变化与下一次
mpv render/update 之间存在时序缺口，不能再简单归因于 half-float context 未创建。

## 结论

1. 不 fork mpv 的 A/B3 路线已经证明：stock libmpv 可以在 macOS 上解码 PQ Main10，
   并进入现有 NativeSurface/Metal 输出链路。
2. 这证明 `gpu-next` 不是进入该路线的必要条件；同时也没有证明真正的 HDR 帧已经
   显示到屏幕。
3. A/B3 不能判定失败。下一步应在确认线程/销毁安全后，验证 Surface active 状态变化
   是否需要触发一次受控的 `VideoOutput.updateCallback`，使 `TextureHW.render` 及时
   使用 half-float context；不要先增加 EDR gain 或后置增益。
4. 若 A/B3 的 producer/context 切换链路修复后仍不能满足真实内嵌 HDR，再做官方
   stock libmpv 的版本对照；随后才评估 AVFoundation。fork mpv 保持最后备选，不是
   当前默认路线。

## 激活边沿重绘验证

### 测试时序纠偏

这两个诊断素材的时长均为 2 秒。早期测试宿主在第 3 秒才配置 HDR，因此早期结果
只能说明末帧重绘行为，不能作为播放中切换的充分证据。随后将测试宿主改为在
`player.open` 前完成 `configureHdrOutput`，并用 localhost 提供同一 PQ 素材。

在 `TextureHW` 的 NativeSurface active 边沿增加了受控的
`VideoOutput.updateCallback`，并用锁保护输出模式读写。相同 stock libmpv、相同 PQ
素材、HDR-before-open 时序的复跑结果：

- `active=true` 在首帧输出前建立；frame 30/60/90/120/…均为 `rgba16Float`；
- `vo=libmpv`、VideoToolbox/P010、BT.2020/PQ 保持不变；
- 六个区域数值仍约为 `0.3777, 0.5527, 0.7163, 0.8872, 0.9614, 0.9932`，所以
  这只证明 half-float 帧已经接管，不证明屏幕亮度或高光超过 SDR 白点。

这验证了 A/B3 的 producer 切换缺口可以在现有 stock libmpv render API 边界内修复，
不需要 gpu-next 或 fork mpv。该修改仍需补充重复激活、回退到 SDR、销毁重建和真实
可见高光验收，当前不视为最终 HDR 通过。

## 当前验收等级

- PQ 解码：已验证。
- `vo=libmpv` render API：已验证。
- NativeSurface active 状态转移：已观察到，不能等同于可见 HDR。
- half-float 帧进入 Metal：已验证（active 边沿重绘后持续 `rgba16Float`）。
- 屏幕高光超过 SDR 白点：未验证。
- Dolby Vision profile/RPU：未验证；本地素材不是确证 DV 输入。

## 同一 libmpv 实例的输出数值契约复核

在修正测试宿主入口后，实际进入 `single_player_single_video.dart`，并在同一实例中
回读 mpv 属性；本次通过 localhost 提供素材，只绕过 Downloads sandbox，不改变输入
内容。关键日志为：

```text
MPVPROP vo=libmpv
MPVPROP hwdec-current=videotoolbox
MPVPROP video-format=hevc
MPVPROP target-prim=bt.2020
MPVPROP target-trc=linear
MPVPROP target-peak=auto
MPVPROP sig-peak=
MPVPROP tone-mapping=auto
```

同一会话的 `video-params` 是 `videotoolbox/p010`、`1920x1080`、`bt.2020-ncl`、
`pq`、`sig-peak=49.261086`；NativeSurface 随后报告 `active=true`、
`rendererReady=true`、`rgba16Float`、`extended-linear-bt2020`，并把 headroom 从
`1.0` 提升到 `2.03048`。因此当前可以确认：

1. stock libmpv 的 A/B3 render API 已按预期把 PQ 输入转为 native surface 所要求的
   linear BT.2020 目标，并且同一实例实际产生了 half-float 输出；
2. `target-peak=auto` 和 `tone-mapping=auto` 只是 mpv 参数状态，`sig-peak` 空值也不
   能替代 source `video-params` 的峰值，更不能推出屏幕已经显示对应亮度；
3. 仍缺少固定显示器上同一高光区域相对于 SDR white 的可见/测量证据，所以本轮不把
   `headroom` 或 half-float 直接升级为“原生 HDR 通过”。

本次测试宿主支持 `MEDIA_KIT_AUTO_SOURCE`，用于通过本机 localhost 复现同一输入，
避免把文件选择器授权问题混入渲染结论；这只是测试工具入口，不是生产路径变化。

## target-peak 单变量对照

在不改变 stock libmpv、素材、`target-prim=bt.2020`、`target-trc=linear`、
NativeSurface 或 Metal shader 的条件下，测试宿主分别设置了 `target-peak=203` 和
`target-peak=1000`。两次均确认输入为相同的 VideoToolbox/P010 BT.2020/PQ 流，且
Metal 输入与输出 readback 数值一致。

| target-peak | half-float 六区 `max(rgb)` | 观察 |
| --- | --- | --- |
| `auto` | `0.3777, 0.5527, 0.7163, 0.8872, 0.9614, 0.9932` | 基线，均未超过线性 SDR white |
| `203` | 与 `auto` 在本次采样精度下相同 | 不能据此断言 `auto` 的内部策略恒等于 203 |
| `1000` | `0.5034, 1.0254, 1.9824, 3.5527, 4.4258, 4.8359` | 明确产生超过 1.0 的线性值 |

这组结果证明：当前 half-float pixel buffer、Metal blit 和 `CAMetalLayer` 数值格式
能够保留超过 1.0 的值；此前 `auto` 的六区被压在 `0..1`，主要应继续调查 mpv
目标峰值/目标映射策略及其与 EDR reference white 的关系，而不是先改 Metal copy。
`target-peak=1000` 仅是诊断变量，不是生产建议，也不证明屏幕已经显示 1000 nits。

Apple 的 `CAEDRMetadata.hdr10(... opticalOutputScale: 100)` 官方定义是：display-referred
linear buffer 中 `1.0` 对应参考显示器 `100 nits`。因此在当前 layer 契约下，half-float
数值可先按 `value × 100 nits` 解释为参考显示器光学输出；这不是面板实测值，也不是
`target-peak=1000` 的直接等价物。mpv 0.36 的旧 `vo_gpu` 是否按同一 reference-white
映射 target peak，仍需通过该嵌入实例的 A/B 数值确认。

按 Apple scale=100 的参考换算，`target-peak=1000` 这次六区读数对应的“参考显示器光学
输出”约为：

```text
50.3, 102.5, 198.2, 355.3, 442.6, 483.6 nits
```

这里的“约”表示数值契约换算，不是亮度计或屏幕可见亮度测量；它只说明当前 half-float
链路承载了这些参考线性值。

## active 边沿回退/恢复实验

隔离宿主在同一 player、同一 generation、同一 PQ 输入上执行了
`resetHdrOutput() -> configureHdrOutput()`，强制 native output 经历
`active=true -> false -> true`。结果为：

- reset 返回 `active=false`；随后 draw 日志的 pixel format 为
  `1111970369`（`kCVPixelFormatType_32BGRA`）；
- configure 返回 `active=true`；后续 draw 日志的 pixel format 为
  `1380411457`（`kCVPixelFormatType_64RGBAHalf`）；
- 切换期间未观察到空 pixel buffer；重新进入 half-float 后，六区数值恢复为
  `0.5034, 1.0254, 1.9824, 3.5527, 4.4258, 4.8359`。

这证明现有 active-edge `updateCallback` 和受锁保护的 producer 选择，在该固定时序下
能够完成 BGRA8→RGBA16Float→Metal 输出切换。它尚未证明 GPU command completion、旧
buffer 槽位回收以及 dispose/recreate 的跨 generation 安全；这些仍是后续生命周期门。

## dispose/recreate 重建实验

自动宿主在同一进程中先完成一轮 `player.dispose`，再创建第二个播放器和 NativeSurface。
第一轮记录为 `handle=44188907984/token=1`，随后出现 `deinit`、factory release 和
`NativeWindow.Detach ... detached=true`；第二轮取得新的 `handle=44191122128/token=2`。
第二轮重新完成 `active=false -> true`，并持续输出 `rgba16Float`，六区线性值再次达到
`0.5034, 1.0254, 1.9824, 3.5527, 4.4258, 4.8359`。

因此“旧 NativeSurface 释放后，新 handle/token 可以重新挂接并恢复 half-float 输出”这一
子门已通过。测试宿主的页面重建计数为 2，但 native 日志中的内部 `generation` 仍为 1；
本次证据不能冒充完整的跨代 generation 语义、GPU completion 或旧槽位回收证明。后续仍需
把 generation 递增/拒绝过期回调作为明确契约验证。

## reset 的显示状态清理

为避免 `resetHdrOutput()` 只切换 producer、却继续保留旧 PQ layer 状态，Darwin native
路径现在在 reset 时下发 `transfer=sdr`；macOS layer 清除 `CAEDRMetadata` 并关闭
`wantsExtendedDynamicRangeContent`，随后 PQ configure 再恢复两者。最新自动测试实际记录：

```text
transfer=pq  edrMetadata=true  wantsEDR=true
transfer=sdr edrMetadata=false wantsEDR=false
transfer=pq  edrMetadata=true  wantsEDR=true
```

随后 native state 回到 `active=true`、headroom `2.0304816`，同一会话持续输出
`rgba16Float`，六区线性值最高约 `4.8359375`。因此 reset/configure 的显示状态清理和
producer 恢复子门已通过；这仍不证明屏幕绝对亮度或可见 HDR 高光。

## macOS 文件授权边界

直接把 `Downloads` 绝对路径交给 sandboxed Debug App 会得到：

```text
Cannot open file ... Operation not permitted
```

初次点击测试宿主的 `Open [File]` 也未能弹出选择器，因为 `file_picker` 报告
`ENTITLEMENT_NOT_FOUND`。随后仅为 `media_kit_test` Debug 配置增加了
`com.apple.security.files.user-selected.read-only`，重新构建后的签名 entitlement 已确认
包含该项。该配置只允许用户通过文件选择器授予所选文件的读取权，不开放整个 Downloads。

当前已通过 macOS 文件选择器实际选择
`/Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4`，选择器返回该文件后播放器
显示了六段灰阶条。这证明 user-selected read-only 授权和文件读取/解码链路成立；该画面
未证明 EDR reference white、绝对亮度或可见 HDR 高光，因此仍不计入原生 HDR 最终验收。

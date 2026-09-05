# OHOS 开发总结

更新时间：2026-09-06

## 当前结论

PiliPlusX 已在 SSH `dev` 上用完整 `lib/main.dart` 生成 unsigned arm64 HAP，并在本机
签名后完成 OHOS 模拟器和实体手机的安装、启动：首页实际绘制正常。近期白屏回归的
原因和修复证据见 [OHOS 运行状态与近期回归记录](ohos-runtime-status.md)。

当前工作目标是打通 OHOS HDR 显示链路。Texture + tone-map 的普通 SDR 与 Dolby Vision
实体机播放已经确认，仅作为安全回退和 A/B 对照。XComponent/native Surface candidate
也已能显示 DV tone-map 画面，但尺寸、EGL/BufferQueue 和解码器生命周期仍不稳定；
因此尚未进入可交付的 native HDR。后续修改必须围绕窗口几何、Surface 生命周期和
NativeWindow 色彩空间证据推进，不能把可见 tone-map 帧误判为 native HDR passthrough。

## 固定基线

- 主平台：Flutter 3.47.2。
- OHOS：Flutter commit `aa76d9bbeee7806a87dbd202d2550dfd11550b82`，Flutter 3.44.9，Dart 3.12.2。
- OHOS CLI：`26.0.0.621`；目标 ABI：`arm64-v8a`；构建模式：release、`--no-codesign`。
- media-kit：`pubspec.lock` 当前 9 个包统一固定到
  `Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`；`73536ef...` 是其
  已包含的历史 Darwin 生命周期节点，`ad22c36a...` 是历史公共 HDR API 比较候选，
  都不能再描述为当前 lock。当前 workflow 仍固定 `73536ef...`，依赖一致性尚待另行修复。
- HDR：OHOS 根据设备 `hdrFormats` 动态探测显示能力；原生 surface 色彩配置已接入，
  但 native HDR active 和 Dolby Vision 真机输出仍需现场播放验收，不能由构建结果代替。

## 已完成实现

- `prepare_ohos_build.py`：从主 checkout 创建隔离构建副本，再校验并转换 package 名、SDK/Flutter 约束、兼容依赖和资源；输出目录必须位于源 checkout 之外。
- `prepare_ohos_flutter.py`：应用 Flutter patch 链，补齐 PageView、WidgetSpan、SelectableRegion 和 `TargetPlatform.ohos` 差异。
- `prepare_ohos_material_ui.py`：对实际解析到的 material_ui/cupertino_ui 缓存应用组件和平台分支兼容补丁。
- workflow：CI 使用 `$RUNNER_TEMP` 下的隔离源码副本和独立 `PUB_CACHE`，包含工具链、依赖、ABI、manifest、固定无签名配置和 SHA-256 校验。
- `tool/ohos/sync_ohos_workspace.sh`：OHOS 构建前以本地 checkout 为唯一源，使用 `rsync --checksum --delete` 同步源文件，并比较本地/远端 SHA-256 manifest；校验失败时禁止继续构建。
- HDR bridge：设备 `hdrFormats` 探测和 NativeWindow 配置代码已编译进 HAP；OHOS 当前可按 A/B 配置使用 Flutter `SurfaceTextureEntry` 或 XComponent/native Surface。native HDR 仍保持 fail-closed，不能把 Texture surface ID 或可见 tone-map 帧当作原生 HDR 证据。
- OHCodec 输入：本地 FFmpeg 补丁为 codec-specific data 增加独立 `AVCODEC_BUFFER_FLAGS_CODEC_DATA` 输入，并保留大 access unit 的 incomplete-frame 分片逻辑；该补丁已在 dev 上交叉编译进 ARM64 `libmpv.so`。
- OHOS video output：外部纹理将视频尺寸按当前显示区域等比限制，并把实际尺寸返回 Flutter，
  使 Flutter、mpv 和 `setTextureBufferSize` 使用同一尺寸；创建/销毁及尺寸变更均有日志。
- `PlatformFeatureSupport.isOhos`：OHOS 不支持的文件导出、后台音频和 PiP 入口返回 unsupported 并隐藏。

## HAP 构建证据

- 2026-09-05 build `2.1.3+2026090517`：本地源码、media-kit 和 native build 均先同步到 dev 并通过 checksum 校验；OHOS 3.44.9 release HAP 编译、签名和 `verify-app` 通过。
- HAP 内 `libs/arm64-v8a/libmpv.so` SHA-256 为 `db65973a6dabefaa8e6feecb1cbdd7656271378403d29774f22dd2bc99663bbf`，确认是 ARM aarch64；HAP 已安装并启动于 HDC `127.0.0.1:5555`，包版本 `2026090517`。
- 该包尚未完成杜比视界现场播放验收；安装/启动证据不等于 HDR 输出证据。

- 2026-09-05 build `2.1.3+2026090511`：本机源码同步到 dev 并通过 SHA 校验，OHOS 3.44.9
  release HAP 编译、签名和 `verify-app` 均通过，已安装到实体设备
  `2PM0223A18006914`；产物包含 arm64 `libmediakit_ohos_hdr.so`。
- `2026090511` 尚未启动验收：设备当时处于锁屏状态，系统拒绝 HDC 启动 Ability。
  因此外部纹理尺寸修复、native HDR active 和 Dolby Vision 仍不能视为已验证。

- 2026-09-02 历史构建工作目录：`/home/wuweiwei1/PiliPlusX-ohos-344`。
- 历史 HAP：`build/ohos/hap/entry-default-unsigned.hap`。
- 历史 HAP SHA-256：`7134be623545a6061b6035fdb424811b8fe7be4d1eb47dd044b5cfc76ad225dc`。
- 包内已确认：`module.json`、`libs/arm64-v8a/libflutter.so`、`libapp.so`、`libmpv.so` 和 `libc++_shared.so`。
- `python3 scripts/verify_artifact.py <hap> --platform ohos --abi arm64-v8a`：通过。
- `flutter pub get`：通过；完整 kernel snapshot：通过。

当前未发布的本地 native archive SHA-256 为
`999bfba12b9da030b5560ce62188da49cc3be48353d37b56b4167a609be50029`，已回收到本地
media-kit 并更新 CMake 校验值；HAP 内解出的 `libmpv.so` 与 dev 构建产物一致。但
CMake 下载 URL 仍指向 ErBWs `20260811` 的旧公开资产，该资产的已提交摘要为
`2bfb9844...`。因此本地缓存存在时可构建，空缓存下载会摘要不匹配；在新产物发布到
不可变 URL 并补齐 manifest、源码/patch commit、许可证和 SBOM 前，这不是可供 CI 或
社区 PR 消费的发布契约。完整来源表见
[media-kit 原生依赖来源与跟踪基线](../reference/media-kit-native-dependencies.md)。

- 2026-09-05 build `2.1.3+2026090520`：补齐 `VideoController` 的 native surface
  公共 getter，XComponent PlatformView 工厂、surface-ready channel 和 OHOS
  native-window FFI 链路编译通过；签名、`verify-app`、安装和启动均通过。
- `2026090520` 已安装到 HDC `127.0.0.1:5555`，设备包版本为 `2.1.3`，版本号为
  `2026090520`；HAP SHA-256 为
  `661efd9e9547373c8e0d60657fb601fa4e93b4784f7a017306476da2ab5159bc`。
- 当前尚未播放 HDR 视频，因此 XComponent surface ready、首帧、显示色彩空间和
  native HDR active 仍未完成现场验收；杜比视界仍按现有策略走 tone-mapping，不能
  由本次安装结果宣称已打通 Dolby Vision 原生输出。
- 2026-09-05 build `2.1.3+2026090522`：修正 OHOS 隔离构建预处理规则，保留同步
  media-kit 提供的 `useNativeSurface` API，并将 OHOS 原生 Surface 改为自动模式预
  挂载，使首个 `videoParams` 延迟报告 HDR 时仍能进入原生通道。HAP 编译、签名、
  `verify-app`、安装和启动均通过；HAP SHA-256 为
  `390eedf7814e931b91d9755a34630d8244680aafe66cb2070be56eb62619cdf6`。
- 设备包版本已核对为 `2026090522`，进程 `com.example.piliplusx` 正在运行；尚未
  播放视频，故仍需现场确认 XComponent surface ready 和 HDR 首帧。
- 随后通过设备截图进入普通视频页时，上方视频区域为黑屏；日志明确显示
  `OhosVideoController.create` 因 `Utils.IsEmulator` 返回 true 而拒绝初始化：
  `Unsupported operation: [VideoController] does not support emulator`。因此该黑屏
  是当前虚拟目标不支持 OHOS media-kit 播放的已知环境限制，未产生
  `OhosNativeSurface`/`nativeSurfaceReady` 事件，不能作为 HDR 通道失败证据。
- 同时 HDC 状态为 `127.0.0.1:5555 TCP Connected`、实体手机
  `2PM0223A18006914 USB Offline`；HDR 播放验收必须切换到后者在线且授权的实体设备。
- 2026-09-05 build `2.1.3+2026090529`：修正 `StandardMessageCodec` 的 OHOS 参数读取，
  `OhosNativeSurfaceFactory` 已能从 `Map` 取得 player handle，真机日志出现
  `Create platform view success`，原先的 `valid player handle` 和 `Invalid envelope` 已消失。
  但进入 XComponent PlatformView 后 Flutter OHOS 渲染线程触发 `SIGSEGV`，因此不能继续
  作为稳定播放路径。
- 2026-09-05 build `2.1.3+2026090530`：关闭 OHOS `useNativeSurface`，恢复 Texture 基线；
  实体机 `2PM0223A18006914` 安装、启动并打开普通 SDR 视频成功，截图显示视频首帧和页面内容，
  进程保持运行。该 A/B 结果将问题边界锁定为 OHOS PlatformView/XComponent/native surface
  路径；Texture 基础播放、网络和当前 tone-mapping 路径仍可用。HDR 原生输出暂不启用。

## 当前 HDR 工作边界（2026-09-05）

- 已确认并保留：本地源码是唯一源，构建前同步到 dev；OHOS Flutter 3.44.9、ARM64
  `libmpv.so`、OHCodec codec-data 补丁、HDR capability fail-closed 判定、HDR decision
  和 tone-mapping 路径。
- 已确认：实体机 `2PM0223A18006914` 的显示探测为 `display=true`，但当前日志仍为
  `decoder=false, vulkan=false, hcpp=false`，所以不能把设备支持 HDR 等同于 native HDR
  输出已生效。
- 已确认：`StandardMessageCodec` 的创建参数是 `Map`；修复后日志出现
  `Create platform view success`，说明 player handle 参数问题已经解决。
- 当前 bridge 已能在实体机到达 `nativeSurfaceReady` 并更新 mpv `wid`，但窗口几何和
  EGL/HCODEC 稳定性仍未解决；0609/0610 的小窗口复测不能作为完整首帧验收。
- 当前代码状态：OHOS 的 `useNativeSurface` 保持关闭以保护可播放性；这不是删除 HDR
  实现。下一步应修复 native surface 的窗口尺寸与 EGL/解码器生命周期，再验证 SDR、
  HDR10/HLG 帧、色彩空间和 Dolby Vision tone-mapping。
- 禁止重复动作：不再重复安装或验证已经确认的 Texture SDR 基线；每次新构建必须携带
  明确的 bridge/HDR 假设、日志证据和对比结论。

### 实体机复验（2026-09-05 23:28--23:30）

- 目标确认：`hdc list targets -v` 显示 `2PM0223A18006914 USB Connected`；
  `127.0.0.1:5555` 仅为模拟器，本次实体机操作未使用该目标。
- 构建 `2.1.3+2026090601` 在 dev 完成 HAP 编译、签名和 `verify-app`；由于设备已有更高
  版本，先前较低版本安装被系统拒绝，随后用递增版本号将该构建成功安装到
  `2PM0223A18006914` 并启动 Ability。
- 实体机截图确认普通 SDR 视频页实际绘制并持续播放；日志出现 `HDR capabilities`
  的 `display=true` 探测和 `HDR decision ... output=sdr, surface=texture`，进程未退出。
  当前 OHOS `useNativeSurface` 仍关闭，因此这次只证明实体机 Texture SDR 回退可运行，
  不构成 XComponent/native-window 或原生 HDR 验收。
- 本轮日志未出现 `SIGSEGV`；仍观察到 OHOS 外部纹理 buffer queue 的
  `OH_NativeImage_AcquireNativeWindowBuffer` 错误，需要在启用 native surface 前继续分析，
  不能把本轮画面证据提升为 HDR 完成。

### Native surface A/B 构建（2026-09-05 23:34--23:36）

- 构建 `2.1.3+2026090602` 已将 OHOS `useNativeSurface` 自动挂载逻辑编译、签名并通过
  `verify-app`，随后安装到实体机 `2PM0223A18006914` 成功。
- 安装后设备进入锁屏；`snapshot_display` 只能取得锁屏画面，无法进入视频页触发
  XComponent `onLoad`、`nativeSurfaceReady` 或首帧。因此本次不能判定 native surface
  是否稳定，也不能宣称修复了此前 SIGSEGV。
- 设备仍保持 HDC `USB Connected`，待解锁后应直接复用该版本或递增版本号继续测试，
  不要改用 `127.0.0.1:5555` 模拟器替代实体机。

### 实体机 Native surface 桥接复验（2026-09-06 00:06--00:12）

- 构建 `2.1.3+2026090609` 完成远端 HAP 编译、签名和 `verify-app`，安装目标明确为
  `2PM0223A18006914`；`127.0.0.1:5555` 未参与本次验证。
- 日志确认完整桥接链：`PlatformViewsChannel create`、`OhosNativeSurface onLoad`、
  Dart `nativeSurfaceReady`、解析 surface id、`attaching native XComponent surface`，
  以及 `native XComponent surface attached`。此前因 handle 类型/控制器匹配提前返回的问题
  已修复。
- 实体机截图曾显示视频实际首帧和连续画面，但后续生命周期复测发现画面仅位于左上角
  小区域；同时日志出现 `vo/gpu-next/opengl: Could not create EGL surface!` 以及
  HCODEC fatal。故目前只能证明事件桥接和部分输出可见，不能证明完整尺寸、稳定输出或
  可交付的 native-window 播放。
- 为保持 fail-closed，主应用的 OHOS `useNativeSurface` 已恢复关闭；实体机默认路径继续
  使用已验证的 Texture SDR。桥接修复保留在 media-kit 隔离构建中，待解决窗口几何和 EGL
  生命周期后再重新开启。
- 日志中的 HDR decision 仍为 `source=sdr, output=sdr, surface=texture`；尚未播放
  HDR10/HLG/Dolby Vision 素材，不能据此宣称原生 HDR 已验收。
- 0609/0610 的几何修复在 0612 native 构建中使画面恢复全宽并可见；但同一时段实体机
  `CodecClient` 报告 `missing parameter sets`、H264 PPS/SPS 无效和 HCODEC fatal。
  在已经可以稳定 tone-map 播放同一杜比视界素材的前提下，这些错误暂不能归因于
  杜比视界解码能力；它们也可能是切换 `vo`/Surface、重建输出或销毁旧窗口时产生的
  次生错误。当前证据只能说明 native 输出路径不稳定，不能证明码流或解码器本身有问题。

### 调试基线调整（2026-09-06）

杜比视界 tone-map 播放必须作为首要基线：固定同一 URL、画质、解码配置和实体设备，
先确认 Texture + tone-map 能持续出帧，再只替换输出 Surface。调试顺序固定为：

1. 记录实际 video track 的 `codec`、`decoder`、`videoParams` 和首帧时间，确认两组
   测试使用同一条码流。
2. 保持 `hwdec` 和色彩参数不变，仅对比 Texture 与 XComponent；XComponent 先强制
   tone-map SDR，验证 Surface 生命周期、尺寸、EGL 和 `wid` 接管时序。
3. 对齐 `vo=null`、更换 `wid`、`vo=gpu-next`、首帧和 HCODEC 日志，判断参数集错误
   是初始打开错误还是输出重建后的次生错误。
4. 只有 native Surface 的 SDR tone-map 稳定后，才测试 HDR10/HLG 和 Dolby Vision
   原生输出；在此之前不强制软解，也不把 HCODEC 日志单独解释为 codec-data 根因。

本轮复核时实体机 `2PM0223A18006914` 仍处于锁屏，`snapshot_display` 只得到锁屏画面，
因此没有把这次检查误记为 tone-map 或 native Surface 播放验收；`127.0.0.1:5555` 仍
不作为替代目标。

### 杜比视界 tone-map 真机基线（2026-09-06 00:34--00:35）

- 在实体机打开公开测试素材 `BV16J4m1H7Nm`，页面标题为
  `Profile8.4_MP4_HEVC_Main10`，实际播放 URL 包含 `1509402846_dv1-1-30126.m4s`
  和基础视频分片。
- 点击播放后，视频区域显示真实测试画面并推进到 `00:21/00:21`；截图证据保存在
  `/tmp/dvplay-ohos.jpeg`。因此确认当前 Texture/tone-map 播放杜比视界测试素材正常，
  之前把黑色测试画面误判为黑屏的结论撤回。
- 同一时间窗口虽然能看到 HCODEC 的 PPS/SPS 日志，但画面仍然正常可见；这些日志不能
  单独作为“解码失败”证据，后续必须区分非致命重试、旧 decoder 实例和真正首帧失败。
- 该基线使用当前已验证的 Texture 路径，尚未证明 XComponent/native Surface 的 SDR 输出。

### HDR 画质选择规则（2026-09-06）

- “设备支持 HDR”是画质选择的统一门控条件：杜比视界（126）、HDR10（125）和 HDR Vivid（129）在支持时都保持可选，不再因为尚未证明 native 输出而单独降级。
- 当显示能力探测明确为不支持 HDR 时，三种 HDR 画质统一置灰；若当前已经选中其中一种，则回退到最高可用的 SDR 画质。
- 所有平台在 URL 查询前都通过统一的 `HdrPlatform.probe` 完成显示能力探测；只有真实的负结果才触发回退，避免把播放器尚未探测时的默认 `false` 误当成不支持并降到普通 4K。平台差异只保留在 channel 实现和 native 输出配置中。
- 该统一时序已在版本 `2026090616` 的 arm64 HAP 中完成构建、签名和校验。
- 该时序修正已通过版本 `2026090615` 的 arm64 HAP 构建、签名、校验并安装到实体机；设备随后进入指纹锁屏，尚未完成该版本新的播放画面验收。

### 0621 Native HDR A/B 复测（2026-09-06 01:42）

- 修正 OHOS native view 外层使用小 decoder rect 的问题后，native Surface 的 DV 测试画面横向铺满视频区域，截图为 `/tmp/0621-dv.jpeg`。
- 真机日志出现 `output=nativeHdr, surface=native-hdr, reason=display-decoder-and-output-ready` 和 `HDR dataspace applied: pq`；这证明 native Surface、PQ NativeWindow 配置及播放器 HDR 决策已经连通。
- 同一阶段仍有 `OH_NativeImage_AcquireNativeWindowBuffer`/BufferQueue `40601000`，需要继续完成生命周期压力回归。

### 0617 Texture 默认路径复测（2026-09-06 01:23）

- 0617 解锁后复用同一 `BV16J4m1H7Nm` 素材，点击播放后正常出画面并横向铺满视频区域，截图为 `/tmp/0617-dv2.jpeg`。
- 该结果确认关闭 OHOS 默认 `useNativeSurface` 后，DV tone-map 回到完整可见的 Texture 路径；native Surface 几何和 EGL 生命周期仍留在后续 A/B。

## 运行验收状态

| 验收项 | 当前状态 | 缺口 |
| --- | --- | --- |
| HAP 安装 | 已验证 | 模拟器与实体手机分别使用匹配 profile 安装成功 |
| Ability/首页启动 | 已验证 | 模拟器与实体手机截图均显示首页 |
| XComponent/NativeWindow 生命周期 | 部分通过 | attach 事件可达，但尺寸错误且有 EGL/HCODEC fatal |
| SDR 首帧、暂停、seek、切集、错误源 | 部分验证 | Texture 基线实体机已出 SDR 首帧；完整控制项仍需回归 |
| 前后台恢复、重复销毁、资源释放 | 未验证 | 需在已打通的 0609 native surface 版本上回归 |
| HDR probe 不报告 `nativeHdr` | 已验证代码契约 | 实体机显示能力为 true，但 decoder/Vulkan/HCPP 未证明 |
| OHCodec codec-data 输入 | 已编译安装 | DV Texture 与 native Surface A/B 均已出画面；仍需确认参数集/EGL 日志是否为播放后的次生错误 |

### Native Surface A/B（2026-09-06 00:46）

- 版本 `2026090614` 已在实体机 `2PM0223A18006914` 安装并启动；同一 `BV16J4m1H7Nm` 杜比视界测试素材显示画面并推进到 `00:15/00:21`，截图为 `/tmp/dv0614b.jpeg`。
- 该包开启 OHOS `useNativeSurface`，因此证明 native Surface 至少能完成本素材的可见 SDR/tone-map 输出；仍不能据此证明 native HDR passthrough。
- 播放后出现 `EGL_BAD_MATCH`、BufferQueue surface 重连以及 HCODEC fatal 日志，但它们发生在已有画面之后；需用首帧时间、Surface attach/detach 和具体 decoder 实例继续定位，不能倒推为“DV 未解码”。
- 版本 `2026090615` 在设备解锁后再次播放同一素材，推进至 `00:02/00:21` 并显示测试画面，截图为 `/tmp/final0615.jpeg`；随后在 `00:07` 左右显示人物画面，截图为 `/tmp/final0615b.jpeg`。
- 版本 `2026090616` 安装并启动后，同一素材再次显示人物画面，截图为 `/tmp/0616-dvb.jpeg`；这验证了统一探测代码进入新包后没有破坏 DV tone-map 播放。

## 复现命令

```sh
export PUB_CACHE=/home/wuweiwei1/.pub-cache-ohos-build
export HOS_SDK_HOME=/home/wuweiwei1/ohos-sdk/command-line-tools/sdk
export OHOS_SDK_HOME="$HOS_SDK_HOME"
export PATH=/home/wuweiwei1/tools/flutter-ohos/bin:/home/wuweiwei1/ohos-sdk/command-line-tools/bin:/home/wuweiwei1/ohos-sdk/command-line-tools/hvigor/bin:$PATH
export PUB_CACHE=/home/wuweiwei1/.pub-cache-ohos-build
export OHOS_WORKSPACE=/home/wuweiwei1/PiliPlusX-ohos-build
python3 scripts/prepare_ohos_flutter.py --flutter-root /home/wuweiwei1/tools/flutter-ohos --workspace "$PWD"
python3 scripts/prepare_ohos_build.py --workspace "$PWD" --output "$OHOS_WORKSPACE"
cd "$OHOS_WORKSPACE"
flutter pub get
python3 "$OLDPWD/scripts/prepare_ohos_material_ui.py" --workspace "$OHOS_WORKSPACE"
flutter build hap --release --no-codesign
python3 "$OLDPWD/scripts/verify_artifact.py" build/ohos/hap/entry-default-unsigned.hap --platform ohos --abi arm64-v8a
```

下一步应以单一 bridge 生命周期假设修复 XComponent/native surface `SIGSEGV`，每次
候选先验证 native 路径的 SDR 首帧、重复 create/dispose 和前后台，再验证 HDR10/HLG
色彩空间及 Dolby Vision tone-mapping。已通过的 Texture SDR 基线只作为 A/B 回退，
不重复当作 native HDR 进展；运行证据齐全前不启用 OHOS 原生 HDR。

## 2026-09-04 手势回归阶段记录

实体机验证发现视频区域的垂直滑动会被 `ExtendedNestedScrollView` 的外层垂直
recognizer 抢走，导致列表滚动而播放器亮度/音量不响应。arena 日志确认播放器
recognizer 已加入但被外层 recognizer 拒绝，因此此前对音量节流或 raw pointer 的
怀疑不是根因。

当前阶段性实现是在播放器内注册专用
`PlayerVerticalDragGestureRecognizer`，并复用原有 pan 回调。实体机手工验证通过，
视频区域不再滚动列表，列表区域仍可滚动。该实现仍属于过渡性的 gesture arena
抢占方案；最终应将播放器交互层从嵌套滚动 hit-test/gesture 路径中隔离，或在
`ExtendedNestedScrollView` 层按 pointer 起点决定是否注册外层拖拽。详细证据、当前
阈值风险和后续方案见 [OHOS 运行状态与近期回归记录](ohos-runtime-status.md)。

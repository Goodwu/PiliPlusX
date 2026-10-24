# Luna 执行交接审计

日期：2026-09-06

本记录按 `docs/plans/luna-execution-correction-plan.md` 逐项核对当前结果。
它不是“全部完成”声明；未满足的验收条件继续保持未完成状态。

## 平台证据边界（先读）

本报告把两个阶段放在同一交接文件中，但证据与结论严格分开：

- **OHOS** 只指 ARM64 鸿蒙模拟器 `127.0.0.1:5555`，固定官方支持范围“仅支持软件解码、仅支持 RGBA 显示”；E1–E4 的 HAP、日志、截图和失败码均来自该模拟器。OHOS 的 E2 原生 Surface 通过，不代表 Flutter Texture 或 native Surface 在模拟器中通过。
- **macOS** 只指 M4 主机上的 `M27P20` 显示器和 macOS Debug App；固定 PQ、EDR headroom、Metal half-float 和 Bilibili BV 证据均不属于 OHOS 实验，也不能证明 OHOS 可见帧。
- 两个平台虽然共享 Dart HDR 状态模型和 `NativeSurface` 命名，但 native backend、显示合成器、输入素材、设备和验收条件不同；任何一个平台的 `active=true`、截图或播放时钟都不得外推到另一个平台。

## OHOS 模拟器阶段

当前模拟器为 ARM64 `127.0.0.1:5555`，官方能力边界为仅软件解码、仅 RGBA 显示。
因此 E2/E3 固定 `hwdec=no` 和 RGBA 输出，不把硬解、HDR 或其他显示格式当作
模拟器成功条件。

| 项目 | 当前结果 | 证据 |
| --- | --- | --- |
| E1 原生 Surface | 通过：EGL/GLES 动态画面可见，间隔截图不同，10 次慢速销毁重建无崩溃 | `docs/status/ohos-emulator-e1-20260906.md` |
| E2 原生 mpv | 通过：产品同版 ARM64 libmpv、`hwdec=no`、软件渲染、RGBA 输出可见；pause/seek 和 3 次重建通过 | `docs/status/ohos-emulator-e2-20260906.md` |
| E3 Flutter Texture | 未通过：media-kit 与官方 `video_player_ohos` 两条路径均推进时钟但黑屏；Flutter external texture 返回 `40601000` | `docs/status/ohos-emulator-e3-20260906.md` |
| E4 Flutter native Surface | 未通过：XComponent surface 建立、mpv attach、时钟和控件交互通过，但截图视频区域全黑；纯色 A/B 也没有可见 surface 内容，同时出现 EGL/BufferQueue 同步错误 | `docs/status/ohos-emulator-e4-20260906.md` |

E3/E4 共同表明，失败边界不只是 media-kit/libmpv：Texture 路径触发 Flutter
external texture 的 `40601000`，native Surface 路径则建立了 XComponent 和 mpv attach
但仍黑屏；纯色背景 A/B 也没有可见 surface 内容，不过该 A/B 不能单独区分
PlatformView 合成与 native buffer 提交失败；同时伴随模拟器 EGL/BufferQueue 同步错误。
当前阻塞边界是 Flutter OHOS
渲染/PlatformView/XComponent 合成与模拟器显示同步链路；不等于真实设备已经验证，也不等于模拟器
播放路径已经修复。

E3 追加了 `enable_impeller=false` 的 renderer A/B，HAP SHA-256 为
`217d02c4492e5d63f63cebb2e30147e91172e7761b29cd1bf7b5e4b719fe0f0d`；仍出现
`40601000` 和 `DGLES ... nullptr gbuffer`，因此失败边界未改变。

## macOS HDR 阶段

### mpv 版本能力边界（上游资料结论）

本项已通过官方 mpv release notes、stable manual 和 libplacebo 官方资料完成研究，
不再安排本地多个 mpv 版本的重复横向试跑。当前产品内嵌的是 mpv 0.36.0，构建选项
包含 `-Dlibplacebo=disabled`；因此它不能按 mpv 0.41 的 libplacebo/gpu-next 默认
行为解释。

- 0.36 的 `gpu-next` 可以解析 Dolby Vision 元数据用于动态场景亮度，但不构成完整
  DV RPU、BL/EL 合成或直通证据。
- 0.37 起 libplacebo 成为无条件依赖；0.41 将 libplacebo-based gpu-next 设为默认，
  并改进 HDR 目标色彩空间、reference white、metadata 和 tone mapping。
- 0.40 的 Linux DRM/dmabuf-wayland HDR 改进不直接适用于 macOS。
- stable manual 对 HDR10+/DV 的描述是“用于产生 HDR10/tone-mapped 结果”与“直接发送
  完整 DV 元数据”两条不同路径；当前日志中的 DV source 身份不能升级为原生 DV 输出。

因此当前 macOS 分支已经作出决策：跳过本地版本比较；如果需要现代 DV/HDR 能力，
另建 `>=0.37 + libplacebo` 升级原型并重做 NativeSurface/真实显示验收；如果不升级，
将当前 DV 路径明确标记为 tone-mapped SDR/base-layer fallback，不宣称 native DV。
资料链接和完整版本矩阵见
`docs/status/macos-pq-mpv-reference-evidence-20260906.md`。

升级原型目前还有一个具体供应链前置条件：`pubspec.lock` 固定
`Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`，macOS 原生包固定
`Predidit/libmpv-darwin-build` `0.6.8` 的 `video-default` artifact；该包实际是
mpv 0.36.0 且禁用 libplacebo。另核对到 media-kit 更新脚本默认的
`media-kit/libmpv-darwin-build@v0.7.0` 已有 universal XCFramework，但其 Mpv slice
仍是 mpv 0.36.0 且禁用 libplacebo/vulkan；因此当前上游有 universal 包，但没有可直接
替换成 mpv 0.41+libplacebo 的 macOS 包。下一步若选择升级，必须先完成可追溯的 universal libmpv
重建/获取和 SHA-256 登记；不得只升级 Dart 依赖号。

补充：`media-kit/libmpv-darwin-build` 最新 tag 已是 `v0.7.2`，但其 v0.7.1/v0.7.2
锁文件仍为 mpv 0.36.0 + FFmpeg 6.0，libplacebo/Vulkan 仍关闭。因此不能把“更新到
最新 media-kit artifact”误写成“升级到现代 HDR/DV renderer”。

对 `Predidit/libmpv-darwin-build@0.6.8` 构建 recipe 的只读复核补充确认：mpv 源码为
`v0.36.0`、FFmpeg 为 `6.0`，`mk-pkg-mpv` 显式关闭 `libplacebo` 和 `vulkan`，macOS
video 仅启用 `gl-cocoa` 与 `videotoolbox-gl`。所以当前代码中的 `vo=gpu-next` 不能
改变二进制能力；升级必须重建原生 XCFramework，并单独登记 configure log、架构、
依赖闭包和每个 framework 的 SHA-256。

本轮另在隔离 `/tmp` 目录完成 mpv 0.41.0 Homebrew 配置/编译探针：libmpv、libplacebo、
Vulkan、`videotoolbox-pl`、`gl-cocoa` 和 Swift 均启用，`libmpv.2.dylib` 编译成功，
SHA-256 为 `a7d58d77587d100c4395dc5030063352e099dabf5e1385b6189110f6b4870f3d`。但该
产物只有 arm64，动态依赖指向 `/opt/homebrew/opt`，没有 universal XCFramework、重定位、
签名或产品播放证据；因此只推进了升级原型的“可编译”门槛，没有改变当前产品 0.36
fallback 结论。

本机没有 `/usr/local/bin/brew`，虽可运行 Rosetta 和 Xcode x86_64 编译器，但没有
x86_64 的 FFmpeg/libplacebo/Vulkan 依赖；因此不能在当前主机直接产出可交付 universal
XCFramework。该升级原型的下一道环境门槛是上游 Nix/CI 双架构构建，当前产品仍保持
0.36 fallback。

实际打开 `BV1uZ4y1U7h8` 并选择“杜比”后，当前 Debug App 取得：

- 请求/实际画质：`qn=126`；视频轨道 HEVC，3840x2160，`videotoolbox/p010`，BT.2020、HLG，`sigPeak=4.926108360290527`。
- mpv 参数回读：SDR 回退为 `target-prim=bt.709`、`target-trc=bt.1886`、`tone-mapping=bt.2390`。
- 来源决策：仍保持 `source=dolbyVision`，输出为 `toneMappedSdr + texture`；不会仅凭 HLG+BT.2020 清除 DV 身份或晋升原生 HDR。当前回调未提供 profile、RPU、BL/EL 字段，这些字段为 unknown/not-observed，不等于 profile none 或 RPU false。
- Native surface：`sourceProcessing=mpv-gpu-native-surface`，`active=false`；窗口仍有可见视频帧和推进的播放进度。

固定 PQ 片已由独立 media-kit macOS 测试应用实际加载显示；配置 native output
后报告 `active=true`、`rendererReady=true`、`rgba16Float`，当前 headroom 从
`1.0` 变为 `2.0304815769195557`，并取得可见窗口截图。独立 mpv 也已确认解码为
10-bit BT.2020/PQ。这证明固定 PQ 输入和独立 native surface 链路可用，但不能替代
PiliPlusX 真实 BV/DV 来源的 native EDR、亮度计或同帧高光验收。

参考应用的低频采样还确认 `rgba16Float` 输入/输出六区域值在 Metal blit 前后保持
一致且递增；这完成了数值格式/拷贝边界的诊断，但没有亮度计，因此不报告绝对 nits。

进一步核对产品实际 `Mpv.framework` 为 mpv 0.36.0 且
`-Dlibplacebo=disabled`；因此不能把独立 mpv 0.41/libplacebo 的 `target-peak` 或
默认 tone mapping 行为套到产品上。Apple 的 `opticalOutputScale=100` 与当前
`rgba16Float` extended-linear 契约一致，暂不改成任意增益；Metal 前后数值一致但六个
区域仍被压在约 `0..1`，下一步需在内嵌 mpv 实例中取得 target-peak set/readback 和
上游 render 数值，才能定位压缩发生点。详细记录见
`macos-pq-mpv-reference-evidence-20260906.md`。

二进制进一步确认：当前 `Mpv.framework` 为 mpv `0.36.0`，编译参数为
`-Dlibmpv=true -Dlibplacebo=disabled -Dgl=enabled -Dgl-cocoa=enabled
-Dvideotoolbox-gl=enabled`。因此当前 macOS 路线是旧 `vo_gpu`/OpenGL render API，
不是 mpv 0.41 的 libplacebo/gpu-next 路线。Apple 官方定义
`opticalOutputScale=100` 时，display-referred linear buffer 的 `1.0` 对应参考显示器
`100 nits`；但 mpv 0.36 源码同时确认其 legacy `vo_gpu` 使用 `MP_REF_WHITE=203.0`，
PQ 线性化与 `target-peak` 均以 203 reference-white 为基准。因此当前 half-float 的
mpv-side 参考单位应先按 `1.0=203 cd/m²` 解释，现有 `opticalOutputScale=100` 是明确
的单位不匹配候选，不能继续直接把值乘 100 当成 mpv 的真实参考光学输出。参数级候选
是隔离验证 scale=203，而不是加 gain；这仍不能当作面板实测亮度。

最新 `flutter run` 实际 BV 会话已只读回读 `target-peak=auto`；同一会话的产品日志将
DV profile、RPU、BL/EL 和动态元数据记录为 `unknown`，而不是把缺失字段写成
`none/false`。这确认了参数状态和元数据观测边界，但仍未证明真实 DV 动态元数据已
进入渲染器。

随后在隔离 media-kit 测试宿主中修正了测试入口：先进入单播放器页面，再在
`player.open` 前配置 native HDR，并在同一 stock libmpv 实例回读输出属性。实际结果为
`vo=libmpv`、`hwdec-current=videotoolbox`、`video-format=hevc`、
`target-prim=bt.2020`、`target-trc=linear`、`target-peak=auto`、
`tone-mapping=auto`；同一 `video-params` 为 `videotoolbox/p010`、BT.2020/PQ、
`sig-peak=49.261086`。NativeSurface 同时达到 `active=true`、`rendererReady=true`、
`rgba16Float` 和 `extended-linear-bt2020`，headroom 为 `2.03048`。这补足了“参数回读、
half-float producer、Metal surface”属于同一播放实例的证据，但仍没有显示器上高光
超过 SDR white 的可见或亮度计证据；`target-peak=auto`、`tone-mapping=auto` 和
`headroom` 均不作最终 HDR 通过条件。

进一步的单变量复核在同一 stock libmpv 实例中完成：保持输入、render API、
`target-trc=linear` 和 Metal 链路不变，`target-peak=auto` 与显式 `203` 的六区
half-float 值均约为 `0.3777, 0.5527, 0.7163, 0.8872, 0.9614, 0.9932`；显式
`target-peak=1000` 则为 `0.5034, 1.0254, 1.9824, 3.5527, 4.4258, 4.8359`，
并且 producer 输入与 Metal 输出 readback 一致。该结果关闭了“Metal blit 把高光
压回 1.0”的假设，但没有关闭“mpv 目标峰值/映射策略或 EDR reference white 不匹配”
的假设。1000 仅为诊断值，未进入产品默认配置；屏幕可见亮度仍未验收。

同一实例还执行了 `resetHdrOutput() -> configureHdrOutput()` 的 active 边沿实验：
reset 后报告 `active=false`，draw 使用 BGRA8（`1111970369`）；configure 后报告
`active=true`，draw 恢复 RGBA16Float（`1380411457`），没有观察到空 pixel buffer，
且 half-float 六区值恢复为 `0.5034..4.8359`。这支持 active-edge 重绘修复在固定
generation 下有效，但不覆盖 GPU completion、旧槽位重用或 dispose/recreate 代际安全。

同一素材另以 `useNativeSurface=false`、`target-trc=bt.1886`、`tone-mapping=bt.2390`
运行 SDR 对照；输入仍为 `videotoolbox/p010` BT.2020/PQ，窗口截图可见六个区域。
native 与 SDR 截图 hash 及限制记录在 `macos-pq-mpv-reference-evidence-20260906.md`，
但两者仍不能替代真实产品 DV 的同帧亮度计验收。

当前诊断素材为 `/Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4`，由
`scripts/generate_pq_bands.py` 生成，左至右为 100、203、400、1000、2000、4000
cd/m² 的 PQ 编码目标，SHA-256 为
`45da67b82cc14d0f903d6af6c416d205658840baff301361518c7e20827af931`。旧的
`luna-pq-highlight-test.mp4` 经复核为单色绿色帧，已从本轮亮度基准中排除。

尚未满足的 macOS 计划条件：

- 当前 AppKit 显示查询取得 `M27P20` 的 `maxEDR=1.0`；本次可直接绑定到该屏幕的
  idle 记录没有形成实际 EDR 画面证据，因此仍没有 native HDR 亮度验收条件，也没有
  亮度计读数。该值不能推出显示器永久不支持 HDR，也不是继续代码诊断的全局 blocker；
- IOKit `IODisplayConnect` 只读属性同时声明该显示器支持 PQ EOTF、BT.2020 RGB
  和 HDR static metadata；这是硬件/链路能力证据，不是当前 compositor 已启用或
  native HDR 画面已通过的证据；
- 尚未完成 App HDR、同流 SDR tone-map、独立 mpv 的固定时间点同帧亮度比较；
- 已实现默认关闭的六区域采样；固定 PQ 控制片已取得 native 激活时 half-float 输入及
  Metal 前后数据，且完成一次固定 generation 的 BGRA8→RGBA16Float 边沿回退/恢复；
  真实产品杜比流的同帧 native half-float 与亮度计证据仍未取得；
- 暂无跨屏、全屏、暂停、seek、换源和 HDR→SDR→HDR 的完整 native HDR 验收。

补充：本轮仅观察到回退路径从约 `04:02` 回到约 `00:10` 后重新可见并继续推进；
由于操作过程中出现工具 re-query 边界，记录为“replay observed；seek not verified”。
该结果不提升 native HDR 验收状态。暂停/全屏/换源和 HDR→SDR→HDR 仍未验收。

因此当前 macOS 结论是“实际播放和 fail-closed 参数事务已验证，原生 HDR 亮度未验收”。

### 2026-09-07 macOS 产品页目标 BV 复测

按 `docs/plans/macos-product-dv-test-sop.md` 从唯一 Debug App 重新执行产品页流程：

- 进程清场后只启动 `/Users/wuweiwei1/src/PiliPlusX/build/macos/Build/Products/Debug/PiliPlusX.app`；
- 搜索框先坐标点击输入框本体，再输入 `BV1vY4y1N7TY`，读取界面确认文本已经写入；
- 搜索结果与目标元数据一致：标题为“蹲守一周，我终于拍到了夕阳下的梦幻场景｜北海道VLOG | Links 4K HDR”，作者为 `Linksphotograph`，时长约 `19:31`；
- 播放页真实出现可见画面，进度推进到约 `17:18`；控制条显示当前画质为“杜比”，详情页显示 `HDR` 和 `BV1vY4y1N7TY`。

这次复测关闭了此前“搜索输入没有真正进入搜索框”和“多个同名应用实例污染结果”两个操作层问题，证明目标 BV 已进入真实产品播放页并能持续出帧。控制条的“杜比”是产品画质选择/页面状态证据，不是 mpv 解码器、DV profile/RPU 或 native EDR 输出证据；当前 macOS 产品页仍未取得这三类直接回读。因此本节不改变“B3 独立宿主已有 DV Profile 8 转换证据、产品页真实 DV 解码/显示仍待确认”的结论。

### W1 fork HDR 层候选复核（2026-09-06）

在隔离 mpv 0.41 fork 中补充了 external `CAMetalLayer` 的 PQ/HLG 配置候选，并在
初始化、reconfig 和 swap 前调用。第一次运行没有显式设置 mpv 输出目标，记录为
`HDR=false/wantsEDR=false`；随后在 W1-only native-window 路径显式设置
`target-prim=bt.2020,target-trc=pq`，首轮 PQ 播放实际进入
`HDR=true/wantsEDR=true/colorspace=ITUR_2100_PQ`。

这纠正了前一版诊断：不是 `target_params` 永远没有传到 macOS backend，而是默认
输出目标仍为 SDR。当前已经证明“显式 mpv target color -> external layer 配置回调”
这条链路存在；但尚未取得 AppKit `headroom > 1`、compositor active 或可见高光
对照。因此 macOS 原生 HDR 仍未验收，重复 HDR 生命周期也未闭合。

纠偏后的原则不变：`gpu-next`、PQ 解码和 `wantsEDR=true` 都不是原生 HDR 成功的
充分条件；还必须证明实际 EDR 合成和可见输出。隔离测试宿主已恢复 stock libmpv。

随后按现有 NativeSurface 的真实契约复跑了 `target-trc=linear`：external layer 使用
`rgba16Float + ExtendedLinearITUR_2020 + wantsEDR=true + CAEDRMetadata.hdr10`
（`opticalOutputScale=100`）。初次 attach 和自动销毁重建后的第二次 attach 均进入
`HDR=true`，并同时取得 `vo=gpu-next`、VideoToolbox、P010/BT.2020/PQ、resize 和
detach。这个结果关闭了 W1 的 target/layer 配置和重复生命周期诊断子门。

但运行时屏幕仍报告 `maxEDR=1.0`、`potentialEDR=10.1524`；没有取得该 mpv layer
独立的 `headroom > 1`、compositor active、同帧高光对照或亮度计读数。因此 W3 的
原生 HDR 可见输出仍未通过。`potentialEDR` 只表示允许尝试，不是当前画面已经进入
EDR。测试宿主已恢复 stock libmpv，OHOS 结论不受此 macOS fork 实验影响。

随后发现更具体的 W3 前置问题：MoltenVK 默认把 mpv Vulkan swapchain 选成
`bgr10a2Unorm`，与现有 NativeSurface 的 `rgba16Float` 契约不一致。加入 macOS-only
16-bit color/alpha swapchain hint 后，present 后实际读回为 `rgba16Float`，并在初次
及重建 attach 中重复成立；因此 swapchain format 子门已通过。即使格式修正后，
`screenMaxEDR` 仍为 `1.0`，所以不能把 format、metadata 或 `wantsEDR=true` 升级为
原生 HDR 可见输出结论。

同一显示器的 NativeSurface 对照随后显式调用 `transfer=pq` 配置，返回
`active=true`、`rgba16Float`、`extended-linear-bt2020`、`headroom=1.0`、
`potentialHeadroom=10.1524`。这证明当前显示模式满足项目的 EDR 尝试门控，也说明
`active=true` 在该实现中不是实际亮度证明；其实现明确使用 potential headroom 允许
首次激活，真实可见输出仍需单独验证。mpv fork 已达到同等 layer 格式和配置条件，
但仍缺少 mpv-owned layer 的独立 active/highlight 证据。

本轮也重新盘点了本机素材：`luna-pq-six-bands.mp4` 和
`luna-pq-highlight-test.mp4` 是 HEVC Main 10/BT.2020/PQ；影视飓风样片是
HEVC Main 10/BT.2020/HLG；控制片是 BT.709 SDR。没有发现带有可确认 Dolby Vision
profile/RPU/BL/EL 的本地输入。因此 DV 仍是“无确切素材、未验证”，不能用 HLG 结果
替代。

本机为 macOS 26.6.2；在此 SDK 上又验证了 `CALayer.preferredDynamicRange=.high` 和
`contentsHeadroom=10`。mpv-owned layer 在 post-present 后仍为
`rgba16Float/ExtendedLinearITUR_2020/metadata=hdr10/wantsEDR=true`，并在重建 attach
中重复成立。但 `screenMaxEDR` 仍为 `1.0`，公开 API 没有提供该 layer 的独立
WindowServer headroom 读数，因此这仍是“高动态范围请求已配置”，不是“可见 HDR 已
通过”。当前 macOS 26 layer 属性候选已覆盖，但输出数值契约和独立测量链路尚未穷尽；
不能把当前 `headroom=1` 直接归因于某一层，也不能停止软件侧调查。

### ScreenCaptureKit 旁路证据与联测边界

随后用 macOS 26 的 ScreenCaptureKit 独立采集显示器：配置
`captureDynamicRange=HDRLocalDisplay`、`pixelFormat=64RGBAHalf` 后成功收到真实屏幕
帧，实际格式为 `RGhA`，IOSurface 的 `ContentHeadroom` 报告为 `1`。这是采集表面
标注，不是 mpv layer 的亮度测量，也不能据此断言合成器已把视频压成 SDR；它只确认
独立屏幕帧采集路径可用，不能把采集格式能力当作播放器已经输出 HDR。

为联测真实 PQ 输入，测试 app 改用 localhost 提供同一素材，确认 `p010`、BT.2020-
NCL、PQ 和 `sigPeak=49.261`；然而该次 Flutter 启动随后报告
`vo=gpu-next: Failed initializing any suitable GPU context`，没有可接受的
present 证据。采集帧仍报告 `ContentHeadroom=1`，但这不是独立的亮度证明，所以这轮只新增了“启动方式与 fork
GPU context 需要复现对比”的 blocker，不改变原有 HDR 结论。测试源、HTTP 服务和
fork 注入均已清理，Debug app 已恢复 stock Mpv SHA-256
`5d6e83ee94f35eff70d674e4b86ee4c00ffe36b5656ddbbdb562174f7b2c85d7`。

### W0 生命周期最新证据

在同一可控 `flutter run` 会话（PID `75156`，当前可执行文件 SHA-256
`28b331a253bda165a6da61f2ae0f5ac2be5c673c5289a915397d976a7f59caed`）中，打开
`BV1uZ4y1U7h8` 后通过正常返回触发 controller dispose，观察到：

```text
dispose player
NativeSurfaceView macOS deinit handle=41446022096 generation=1 token=2
NativeSurfaceViewFactory macOS released handle=41446022096
NativeWindow.Detach handle=41446022096 generation=1 ... detached=true
```

这证明当前 Flutter Texture/native-surface 空壳的 graceful Detach 闭环已通过；同次运行
还观察到 `VideoOutput.Resize` 从 `0x0` 到 `3840x2160`。该尺寸事件不等价于 B2
mpv-owned child window 的 renderer resize/reconfiguration，因此 W1 仍等待该 B2 证据后
再绑定真实 `wid`。热重启只观察到 native reference disposal，不纳入 graceful Detach
证据。

随后已补充只读 frame bridge：macOS `FrameReportingView` 以 0.25pt 容差报告真实
AppKit frame，native channel 发送 `NativeWindow.Frame`，并提供按
`handle/generation` 读回 token/frame 的 `NativeWindow.State`。真实运行观察到
`NativeSurfaceView frame changed (0,0,3840,2160)` 和对应 `NativeWindow.Frame`；
亚像素抖动修正后不会重复上报伪 resize。该 bridge 只覆盖当前 wrapper，不设置 mpv
`wid`，不改变 renderer，也不证明 B2 child-window 的 renderer reconfiguration。

后续运行已实际验证 `Attach(token=1, frame=0x0) → State(token=1, frame=0x0) →
Frame(3840x2160) → Detach(detached=true)` 的同一 handle/generation 闭环；W0 接口
证据因此闭合，W1 仍只剩 mpv-owned child-window 的 renderer resize/reconfiguration
和真实 `wid` 绑定验收。

## 当前路线纠偏（2026-09-06）

上述 W0/W1 历史记录不能继续解释为 stock B2 已具备 Flutter 嵌入能力。mpv 0.41
macOS `gpu-next` backend 的 `MacCommon.config()` 无条件创建自己的 `NSWindow`/`View`；
media-kit 的 `NativeWindow.Bind`/`wid` 写入没有证明外部 view 被 backend 消费。当前
W1 的下一步不是继续补 Flutter token/resize，而是决定是否维护 mpv backend fork 或
采用等价的替代 host；不接受这类窗口所有权改造则回到 A，B1 只保留为 standalone
renderer 对照。

## W1 控制片复核补充（2026-09-06 20:21）

隔离宿主实际加载 mpv 0.41 arm64 artifact 后，使用本地持续运动 BT.709 控制片取得
`vo=gpu-next`、`hwdec-current=videotoolbox`、BT.709 `videoParams` 和真实可见帧。
可见帧出现在同一进程的独立 `package:media_kit` 窗口，而 Flutter 主窗口播放器区域
仍为黑色。因此 gpu-next/解码/独立窗口出图通过，Flutter PlatformView 嵌入失败；
这组结果不构成 HDR/DV 验收。详见
`docs/status/evidence/macos-w1-gpunext-visible-window-20260906/`。

## macOS fork 候选复核（2026-09-06 20:35）

为验证 B2 是否存在可维护的嵌入路线，在独立 mpv 0.41 工作树中实现了最小 external
`NSView`/MetalLayer 绑定候选。Vulkan-only `libmpv.dylib` 编译成功并加载到隔离测试
app；运行后 Flutter 主窗口内部出现控制片，`CGWindowList` 只看到一个主窗口，未再
出现 stock backend 的独立 mpv 窗口。这一证据使 B2 从“stock backend 不可嵌入”推进
为“fork 候选可运行”。

首次运行画面只有目标 view 的约一半尺寸；随后修正 external-view resize 路径并明确
设置 backing-pixel `drawableSize`，第二次运行已在 Flutter 目标区域按完整 16:9 显示
控制片，黑边符合比例，窗口列表仍只有主 Flutter 窗口。当前结论是：fork 候选通过
编译、动态加载、绑定、可见像素和初始尺寸子门，尚未完成完整 resize/detach 生命周期
验收，也未开始 HDR/DV 验收。补丁和产物均为隔离实验，不改变 OHOS 路线或生产默认值。

为避免继续依赖不可重复的人工拖拽，隔离测试宿主新增了 macOS-only window resize
MethodChannel 和 `800x632`/`640x520` 切换按钮；Debug 构建通过，analyze 仅有既有
info。由于本轮 UI harness 未能重新获取 app window，该入口尚未产生 runtime resize
证据，不能提升验收等级。

随后使用 `MEDIA_KIT_AUTO_RESIZE=true` 自动模式取得了可重复 resize 证据：MethodChannel
请求 `640x520`，实际 AppKit/CoreGraphics 窗口为 `640x552`，截图中仍有完整 Flutter
主窗口和 gpu-next 控制片；同次日志为 `vo=gpu-next`、`hwdec-current=videotoolbox`。
这关闭了 fork 候选的初始 resize 子门，但重复 resize、detach 和销毁重建仍未验收。

随后自动模式在 resize 后 dispose player，真实日志取得 `MpvWindowView deinit`、
`NativeSurfaceViewFactory released` 和 `NativeWindow.Detach(... detached=true)`；detach
后同一进程仍只有 `640x552` 的 Flutter 主窗口。单次 detach 子门已通过，但重复销毁
重建、新 generation 重新 attach 和完整导航生命周期仍未验收。

继续运行自动生命周期宿主后，第一轮 token 1/handle 完成 detach，第二轮页面重建取得
新 handle、token 2、重新 Attach、`vo=gpu-next`、VideoToolbox 解码并再次 detach。隔离
SDR 的销毁重建/重新 attach 子门因此通过；用户导航、前后台和 HDR/DV 验收仍待执行。

随后用本地 HEVC Main10/P010/BT.2020/PQ 素材复跑：`video-params` 明确为 PQ，
`vo=gpu-next` 和 VideoToolbox 解码通过，Flutter 内有可见帧；但 NativeSurface 仍为
`active=false`、`headroom=1.0`。因此 fork 路径的 PQ 解码/处理已验证，native HDR 输出
仍未验证；本机没有确切 DV 输入，不能把该结果扩展为 Dolby Vision 结论。

## 代码、构建与工作树

- 2026-09-06 版本研究文档更新后复跑：`flutter test --no-pub test/plugin/pl_player/hdr_test.dart`
  34 项通过；定向 `flutter analyze --no-pub lib/plugin/pl_player/controller.dart
  lib/plugin/pl_player/models/hdr.dart test/plugin/pl_player/hdr_test.dart` 无问题。
  该回归只证明 Dart 状态/事务代码没有回归，不提升 OHOS E3/E4 或 macOS 原生 HDR
  可见输出的验收等级。
- HDR 单测：34 项通过，其中 2 项覆盖可交错事务门的串行、过期完成和失败恢复；不等同于真实控制器生命周期验收。
- 定向 `flutter analyze`：通过。
- `python3 scripts/verify_hdr_channel.py`：7 个端点通过。
- `python3 -m unittest discover -s test -p '*_test.py'`：5 项通过。
- `flutter build macos --debug --no-pub`：通过；最新主可执行文件 SHA-256 为
  `0f38ec05334474a4aa406debbf8619d89fed7f930dad047c073abd4575e1a267`；本轮同时
  修正 Darwin native HDR 用实际窗口所在屏幕的潜在 EDR 能力允许首次尝试；当前
  headroom、native 输出报告和可见高光仍是验收条件，并按实际屏幕重新计算门控。
- native output 事务已补充 source/player/surface generation 检查、来源快照、共享
  串行事务门和显示变化 reset/reprobe；HDR 单测 34 项覆盖现有决策、元数据合并及
  事务门路径，未把真实设备生命周期验收冒充为自动化测试结果。
- PiliPlusX 和 media-kit 均未提交、未推送；主工作树及 media-kit 原有修改均保留。
- media-kit 测试应用本轮为 W1 运行临时开启了 `useNativeWindow`、本地控制片和
  mpv 属性诊断；这些是隔离宿主改动，不代表生产默认值。Flutter 工具产生的宿主
  工程迁移文件与 Darwin native surface 改动均保留，未提交。
- 本轮新增 `FrameReportingView`、`NativeWindow.Frame` 和 `NativeWindow.State` 后，
  macOS debug build 仍通过；HDR 单测再次为 34 项全通过。定向 analyze 仅保留
  `real.dart` 原有的 2 个文档注释 info，无新增 error。

当前目标保持未完成，等待真实 EDR 显示条件和后续亮度/生命周期验收；本记录用于下一轮
逐项继续执行，不作为提交或合并许可。

## 2026-09-06 stock libmpv A/B3 non-fork control

A separate macOS run used the stock libmpv artifact, without the mpv fork and without the
`gpu-next` window path. It selected `vo=libmpv`, `hwdec-current=videotoolbox`, P010,
BT.2020/PQ and `sig-peak=49.261086`. The existing NativeSurface path transitioned from
`active=false` to `active=true`, reporting `headroom=2.03048`, `potentialHeadroom=10.1524`,
`rgba16Float` and `extended-linear-bt2020`.

This is useful evidence that `gpu-next` is not a prerequisite for the stock render-API path.
It is not an HDR-display pass: the bounded Metal sampler remained `bgra8Unorm` with the same
six-region values around `0.376, 0.552, 0.717, 0.886, 0.960, 0.992`; a half-float native
producer was not proven. The next blocker is the `TextureHW` nativeSurface/half-float context
switch and render-update lifecycle, not an immediate need to fork mpv. Detailed evidence is
in `docs/status/evidence/macos-a-b3-native-surface-20260906/README.md`.

## 2026-09-06 A/B3 active-edge redraw result

The stock, non-fork render path was rerun after making the NativeSurface activation edge
queue one existing `VideoOutput.updateCallback`, with the `TextureHW` output-mode flag
protected by a lock. Before activation, samples at frames 30/60/90/120 were `bgra8Unorm`;
from frame 150 onward they were consistently `rgba16Float`. This validates the producer
format transition without `gpu-next` or an mpv fork. The sampled values remained around
`0.3777, 0.5527, 0.7163, 0.8872, 0.9614, 0.9932`, so it is not yet proof of compositor
visible HDR or luminance above SDR white. Follow-up must cover false-edge fallback,
dispose/recreate, and the linear-reference-white/tone-mapping contract.

The test timing was then corrected: both diagnostic clips are two seconds long, while the
old harness configured HDR at three seconds. The harness now configures native HDR before
`player.open`. With the same stock libmpv and localhost-served PQ clip, `active=true` was
established before frame output and frame 30 onward continuously sampled as `rgba16Float`;
the automatic dispose/recreate cycle also completed. The six-region values remained around
`0.3777..0.9932`, so the remaining issue is the linear reference-white/tone-mapping and
compositor-visible highlight proof, not gpu-next or mpv forking.

## 2026-09-06 dispose/recreate reattach result

The automatic lifecycle run completed one full player disposal and page recreation in the same
process. The first native surface (`handle=44188907984`, `token=1`) emitted deinit, factory
release, and `NativeWindow.Detach ... detached=true`. The recreated surface received a new
`handle=44191122128`, `token=2`, re-entered `active=true`, and again produced continuous
`rgba16Float` frames with six-region linear values `0.5034..4.8359`.

This closes the new-handle/new-token reattach subgate. The app page generation reached 2, but
the native diagnostic still reported internal `generation=1`; therefore this is not yet proof
of generation increment/expiry semantics, GPU completion, or old-pool-slot safety. Those remain
explicit lifecycle gates. This is macOS-only evidence; it does not change the separate OHOS
software-decode/RGBA-only conclusion.

## 2026-09-06 reset metadata cleanup result

The Darwin reset path now sends `transfer=sdr` to the native layer, clearing macOS
`CAEDRMetadata` and disabling `wantsExtendedDynamicRangeContent`; a subsequent PQ configure
restores the HDR layer state. The rebuilt host was opened after disabling its stale AppKit
restoration state and the runtime log recorded:

```text
transfer=pq  edrMetadata=true  wantsEDR=true
transfer=sdr edrMetadata=false wantsEDR=false
transfer=pq  edrMetadata=true  wantsEDR=true
```

The same session returned `active=true`, headroom `2.0304816`, and continuous `rgba16Float`
samples with six-region maximum `4.8359375`. The reset/configure layer-state subgate is now
verified. This still does not prove absolute luminance or compositor-visible HDR highlights.

The macOS test host was then opened through the native file picker and the selected
`/Users/wuweiwei1/Downloads/test-clips/luna-pq-six-bands.mp4` was replayed successfully; the
window visibly rendered the six gray bands. This confirms the user-selected read-only file
authorization and file/decode path. It is ordinary frame visibility only, not proof of EDR
headroom, reference-white mapping, absolute luminance, or final native HDR acceptance.

### `opticalOutputScale` 隔离 A/B

测试宿主已增加仅诊断用的 scale 参数，默认仍为 100。scale=100 和 scale=203 使用同一
宿主、同一 PQ 六区素材、同一 mpv 参数和同一 reset/configure 时序运行：两次均为
`active=true`、`rendererReady=true`、`rgba16Float`，headroom 均为 `2.0304816`，
六区 half-float 均为 `0.5034..4.8359`，Metal blit 前后均一致；native 日志唯一变化
是 `opticalOutputScale=100.0/203.0`。因此 scale 只改变显示侧 metadata，不改变
mpv producer 的 PQ 曲线或 half-float 输出。scale=203 运行能正常显示六区测试图，
但固定显示设置下的 SDR-white/高光视觉对照仍未完成，不能据此把 203 定为生产值。

在相同窗口尺寸、素材和显示设置下补做了两次画面对照：scale=203 的右侧高亮区主观
上比 scale=100 更亮、六区层次更容易拉开；两次均能看到六区。该结果是 compositor
截图/肉眼的相对观察，不是亮度计测量，不能报告绝对 nits，也不能单独证明跨显示器
正确。目标显示器上的 SDR white、黑位和高光复核仍是最后验收项。

收尾验证：PiliPlusX `test/plugin/pl_player/hdr_test.dart` 35 项全部通过，相关 Dart
analyze 无问题；media-kit macOS 测试宿主成功构建；测试 HTTP 服务、Flutter 运行进程
均已停止，两个工作树 `git diff --check` 均通过。上述仅覆盖代码/构建和诊断链路，仍不
替代目标显示器上的最终 HDR 验收。

### macOS Dolby Vision 系统能力复核

Apple 官方文档确认 macOS 在兼容设备上支持 Dolby Vision；内置显示器和 Pro Display XDR
支持 Dolby Vision/HDR10/HLG，其他 HDR10 外接显示器会将 Dolby Vision 转换为 HDR10。
但这是 Apple 播放/显示管线的能力，不代表任意 `CAMetalLayer` RGB 内容都能被系统重新
识别为 Dolby Vision。[Apple Mac HDR 文档](https://support.apple.com/en-au/102205)

Apple 的应用级 DV 播放路径是 AVFoundation：DV 8.4 可由 `AVPlayer+AVPlayerLayer`
自动建立 HDR pipeline；若使用 `AVSampleBufferDisplayLayer`，sample buffer 必须保留
10-bit 格式和逐帧 DV display metadata。[Apple Dolby Vision 指南](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)

当前产品 B3 不满足这一条件：mpv 0.36/libplacebo-disabled 将源解码/渲染为 P010 →
linear `rgba16Float`，现有 `CAMetalLayer` 只接收线性 RGB/EDR 数值；当前日志中 DV
profile/RPU 仍为 `unknown`。因此 macOS 能显示 DV，不能推出当前 B3 可以把 DV 原样交给
系统。B3 继续作为通用 HDR fallback；如果目标是原生 DV，应新增 AVFoundation native
surface 路线，而不是在 RGB surface 上增加 metadata 或 gain。

### DV 路线决策

当前优先完成 DV 解码后的普通 HDR10/EDR 输出，不把 AVFoundation 原生 DV 作为默认
播放器后端。原因是现有 B3 已有可复用的播放、控制和 Flutter 生命周期，而原生 DV
需要单独维护 AVPlayerLayer/native overlay，并按 profile 和设备重新验收。若真实 DV
素材在 B3 中能稳定产出 BT.2020/PQ 10-bit 并通过固定显示器的高光/色彩验收，直接采用
`DV converted/fallback`；只有 B3 对实际 profile 失真或产品明确要求保留 DV 动态元数据
时，才启动 AVFoundation PoC。当前 Downloads 已有一条可确认的 Profile 8 DV 素材，但
仍需完成 B3 实际播放、输出参数和可见帧验收，不能提前宣称原生 DV 结论。

随后已完成该素材的 B3 实际播放复测：`videotoolbox/p010`、`colormatrix=dolbyvision`、
BT.2020/PQ，NativeSurface `active=true`、`rendererReady=true`、`rgba16Float`，
headroom 约 `2.03`，Metal `drawn=true`，测试窗口有可见视频帧。这个结果证明 DV
Profile 8 到普通 HDR/EDR surface 的链路具备可行性；尚未证明 RPU 原生直通、显示器
绝对亮度或动态映射正确性。

同一文件的 SDR Texture 对照随后也成功：mpv 回读 `target-prim=bt.709`、
`target-trc=bt.1886`、`tone-mapping=bt.2390`，输入仍为 DV `p010`/BT.2020/PQ，
测试窗口有可见帧。当前已关闭“仅 HDR 路径可见”的疑问，但没有把截图主观亮度当作
绝对亮度或色彩正确性证据。

### 2026-09-07 用户确认后重新执行的 DV 生命周期结果

上一轮测试退出经用户确认是手工关闭，不能作为失败证据。本轮重新执行同一 Profile 8
DV 输入的自动生命周期：第一代实例完成窗口调整、播放器 dispose、
`NativeWindow.Detach(detached=true)`；自动重建后第二代实例取得新 native handle/token，
重新完成 `videotoolbox/p010`、`dolbyvision`、BT.2020/PQ 解码，NativeSurface 再次达到
`active=true`、`rendererReady=true`、`rgba16Float`、headroom 约 `2.03`，并正常完成第二次
detach。

因此 macOS B3 的本次 DV 诊断生命周期子门通过：`resize -> dispose/detach -> recreate/
attach -> visible-ready -> dispose/detach`。这只证明 macOS 隔离宿主当前链路的资源和输出
恢复性，不证明用户导航、前后台、暂停/seek、换源，也不证明 DV RPU 原生直通或绝对亮度
正确性；不能与 OHOS 测试或结论混用。

### 2026-09-07 固定时间点同帧视觉对照结果

隔离宿主新增 `MEDIA_KIT_AUTO_START_SECONDS=12` 诊断参数：通过 `Media.start` 定位到
12 秒，收到有效视频参数后立即暂停；日志回读位置为 `0:00:12.000000`。同一 Profile 8
输入分别运行 NativeSurface HDR/EDR 和普通 Texture SDR fallback，桌面截图中的云海、
太阳和字幕位置一致，均有可见帧。

HDR/EDR 运行回读 `target-prim=bt.2020`、`target-trc=linear`、`target-peak=203`、
`tone-mapping=auto`，NativeSurface 为 `active=true`、`rendererReady=true`、
`rgba16Float`、headroom `2.03048`。SDR 运行回读 `target-prim=bt.709`、
`target-trc=bt.1886`、`target-peak=auto`、`tone-mapping=bt.2390`，并使用
`vo=libmpv`、`hwdec-current=videotoolbox`。

本轮关闭了“同源 HDR/SDR 截图可能不是同一帧”的对照缺口，支持采用 B3 的
`DV converted/fallback` 作为当前 macOS 默认方向。它仍不证明绝对 nits、色彩测量、RPU
动态映射或原生 DV metadata passthrough；这些需要亮度/色度测量或 AVFoundation 原生
DV PoC，不能由截图推断。

### 产品侧状态机回归

固定同帧对照后运行 `flutter test test/plugin/pl_player/hdr_test.dart`，34 项全部通过，
覆盖 SDR 保持、HDR 事务串行/过期完成/失败恢复、能力证明门、DV/HDR 元数据分类、
Texture/native 拓扑和回退规则。该测试证明当前产品状态机没有因为 macOS 诊断结论而改变
默认策略；它不替代真实 PiliPlusX 页面上的暂停、seek、换源和前后台验收。

### 真实 PiliPlusX macOS 页面初步验收

`flutter build macos --debug --no-pub` 成功生成 `PiliPlusX.app`。启动本地构建后，首页
完成内容加载并打开第一个推荐视频；真实页面显示可见视频帧，视频位置从 `00:15` 持续
推进到 `00:23`，证明产品页面的普通播放链路可用。

随后在视频控制层执行暂停：位置从 `00:27` 保持不变；再次点击视频后位置推进到
`00:34`，暂停/恢复子门通过。该素材是普通线上视频，不是本地 Dolby Vision 素材，
所以这只能证明产品页面的基本生命周期，不提升 macOS DV/HDR 结论。seek、换源、前后台、
全屏和产品页面中的真实 DV/HDR 仍未验收。

同一产品页面随后完成了 seek 和全屏子门：进度条点击将位置从约 `02:00` 跳到
`00:01`，回读位置发生变化；窗口全屏后视频区域扩展到全屏布局并保持可见帧，随后正常
退出全屏。该素材仍是普通线上视频，因此这些结果只证明产品页面的通用播放控制和窗口
布局，不提升 DV/HDR 结论。换源、前后台和产品页面真实 DV/HDR 仍未验收。

从首页第二条推荐卡片再次打开视频后，详情页切换为《看完〈欢迎来龙餐馆〉，才懂抗美
援朝打得有多值》，时长变为 `08:47`、BV 号变为 `BV16tbY6PEAV`，位置从 `00:00` 推进到
`00:07`。这证明普通产品页面换源后能更新媒体信息并继续出帧；仍不代表 DV/HDR 换源，
也未关闭前后台和产品页面真实 DV/HDR 验收。

### 产品页面本地 DV 输入审计

检查发现当前 PiliPlusX 没有“打开任意本地视频”的入口。现有 `FilePicker` 主要用于字幕、
导入/导出和设置；播放器的 `FileSource` 由已下载的 `BiliDownloadEntryInfo` 根据目录、
`typeTag` 和固定文件名构造，不能直接接收用户 Downloads 下任意 MP4 路径。因此本轮没有
绕过产品架构注入 DV 文件，也没有把隔离 `media_kit_test` 的 DV 结果伪装成真实产品页面
结果。若需要产品页 DV 验收，下一步必须明确新增本地视频入口，或准备一条产品已有的
下载条目路径。

### 后台暂停复测边界

尝试用 `super+h` 做受控后台复测时，系统同时存在多个同 bundle 的 PiliPlusX/Runner
实例；隐藏后 AX 恢复状态回到了不同页面且没有有效 position 字段。该轮不能判定后台
暂停成功或失败，已标为环境隔离不足，不改变代码结论。下一次必须先保证单一 Debug
实例和唯一窗口，再验证默认 `continuePlayInBackground=false` 下的暂停、恢复和输出重建。

补充做了 macOS 应用隐藏/恢复检查：隐藏后进程仍报告 `isRunning=true`，恢复窗口后仍在
同一视频详情页，媒体标题和时长保持不变，位置继续推进到 `00:59`。这只证明进程级
隐藏/恢复未立即丢失当前源；未覆盖系统挂起、真正后台暂停策略、前后台多次循环或 DV/HDR
输出重建，因此前后台完整验收仍保持未通过。

### 2026-09-07 产品页直接解码日志与发白观感

本轮改用 `flutter run -d macos --debug --no-pub` 启动唯一 Debug App，重新按连续交互流程打开
`BV1vY4y1N7TY`，取得了产品自身 Dart/mpv 日志：

```text
Video track codec=hevc
videoParams: videotoolbox / p010, 3840x1920
colormatrix=bt.2020-ncl, primaries=bt.2020, gamma=hlg
sigPeak=4.926108360290527
HDR decision: source=dolbyVision, transfer=hlg
  output=toneMappedSdr, surface=texture, vo=gpu-next, hwdec=auto
HDR mpv parameter readback:
  target-prim=bt.709, target-trc=bt.1886,
  tone-mapping=bt.2390, target-peak=auto
```

NativeSurface 同时报告 `rgba16Float`、`extended-linear-bt2020`、`rendererReady=true`，但
`active=false`，因此当前产品决策仍然是 SDR Texture 回退；这与独立 B3 宿主的 native
surface 证据不能混为一谈。

用户实际观感为“颜色发白”。该反馈与当前输出路径相符，暂记录为产品页 HLG/DV 转 SDR 的
真实画质回归候选，而不是主观意见或页面标签问题。下一步只做隔离 A/B：保持同一 BV、同一
播放位置和 VideoToolbox/P010 输入，比较当前 `bt.709/bt.1886/bt.2390/target-peak=auto`
与明确 SDR reference-white/target-peak 的结果；未完成 A/B 前不修改默认生产参数，也不把
发白归因给 OHOS 或 macOS 系统 DV 支持。

为支持该 A/B，加入了仅 Debug 环境变量 `PILIPLUSX_HDR_TARGET_PEAK` 的 mpv 参数覆盖；
未设置时生产行为不变。`PILIPLUSX_HDR_TARGET_PEAK=100` 和 `=203` 均能在产品日志中
确认实际写入并回读对应值，且都仍走 `toneMappedSdr + texture`。两轮截图由于产品重启后
起播时间和服务端返回的同一 qn representation 可能不同，不能直接作为同帧画质结论；
因此本轮只关闭了“诊断参数没有生效”的疑问，没有据此选择默认 target peak。HDR 单元测试
仍为 34 项全部通过。

### 2026-09-07 发白根因定位与最小修正

进一步检查 media-kit 的输出选择发现，macOS/iOS 普通 native surface 在 renderer 尚未
验证激活时，`video_texture.dart` 仍使用 `nativeSurfaceCandidate` 选择 native surface；
与此同时产品已经按 `toneMappedSdr` 写入了 `bt.709/bt.1886`。这会把 SDR tone-map 结果
送入尚未 active 的半浮点 native surface，候选拓扑与实际输出状态不一致，是本次发白的
直接架构候选。

已在 `/Users/wuweiwei1/src/media-kit/media_kit_video/lib/src/video/video_texture.dart`
做最小修正：

- 普通 macOS/iOS native surface 只有 `nativeSurfaceActive=true` 才被挂载；
- `nativeSurfaceCandidate` 仍只用于 mpv-owned native-window 实验路径；
- OHOS 的 native surface candidate 逻辑未改变。

修正后重新构建 `PiliPlusX.app` 成功，产品侧目标 BV 仍为
`HEVC/VideoToolbox/P010/BT.2020/HLG`，决策仍明确为 `toneMappedSdr + texture`，而 inactive
native surface 不再作为显示载体。复测截图中海面纹理和高光细节恢复，未再出现上一轮整片
发白的 native-surface 混用现象。该修正解决的是 SDR fallback 的载体错配，不等于 native
HDR 或原生 DV 已通过。

media-kit 全量 `flutter analyze --no-pub` 仍有该工作树已有的 OHOS PlatformView 未定义
错误（`OhosViewSurface`、`OhosViewController`、`init*OhosView`）；这些错误与本次 Darwin
视频选择修正无关。PiliPlusX macOS Debug 构建已通过，HDR 单元测试 34 项仍全部通过。

修正后的真实产品页回归补充：目标 BV 在约 `07:56` 点击视频主体后暂停，约 `1.2s` 后
位置仍为 `07:56`；再次连续点击恢复后位置推进到 `07:58`，暂停/恢复子门保持通过。
本轮 seek 坐标点击未改变位置，不能写成 seek 通过；后续需要重新取得控制条命中区域或
使用产品实际暴露的 seek 控件完成，不把失败操作混入 HDR 结论。

### 2026-09-07 产品策略纠偏：不以 SDR tone-map 代替 HDR 源选择

用户确认：`media-kit` 可以保留 tone mapping 作为底层兼容能力，但 PiliPlusX 正常产品
路径不应在不支持 HDR/EDR 的显示器上请求或打开 HDR/DV 源。显示能力为 false 时，应在
画质请求和 DASH 目标选择阶段排除 Dolby Vision、HDR 与 HDR Vivid，选择可用的普通 SDR
画质；不能先打开 HDR 源，再依赖 `toneMappedSdr` 压回 SDR。

当前代码已经在画质菜单和 DASH 目标选择处使用 `hdrDisplaySupportsHdr` 做初步门控，但
后续要把证据分成两层：显示器的 HDR/EDR 能力，以及 PiliPlusX 当前可用的 HDR 输出后端。
`displayHdr` 不能等同于 `nativeOutputCapable` 或 `nativeOutputActive`。若显示器支持 HDR
但应用输出后端尚未接通，正常产品默认也不应把“DV 输入 + SDR tone-map”当作完成状态；应
继续保留为诊断/底层兜底，并优先完善普通 HDR/EDR 输出。

因此本轮 `source=dolbyVision`、`output=toneMappedSdr` 只说明底层实例收到了 HDR/DV
输入并选择了 SDR 兼容输出，不改变产品策略结论：不支持 HDR 的显示器不应选择 HDR 源，
而原生 DV passthrough 仍未确认。

### 2026-09-07 seek 控件修正

复查 `ProgressBar` 实现后确认，真实视频页底部覆盖层的进度条未传入任何拖动/提交回调，
因此 `RenderProgressBar.hitTestSelf` 为 false；此前连续点击和拖动未触发 seek 并非位置
判断错误，而是控件没有参与命中测试。已在 `lib/plugin/pl_player/view/view.dart` 补齐
`onDragStart`、`onDragUpdate` 和 `onSeek`，沿用 `BottomControl` 的位置更新、预览和最终
提交语义。

修正后 HDR 单测 34 项全部通过，macOS Debug 构建通过。真实 BV 页面 seek 尚未重新执行，
因此仍不能宣称 seek 已通过；必须用新构建完成一次连续拖动并确认位置跳转。

随后使用新构建重新执行真实 BV `BV1vY4y1N7TY` 页面操作：控制条唤出后立即拖动进度线，
最终回读位置从约 `16:26` 跳到 `04:53`。这不是自然播放造成的连续推进，证明补齐回调后
真实产品页 seek 子门通过。AX 容器的百分比字段仍显示旧值，因此本次以 position/duration
回读作为有效证据；该结果只覆盖播放器控制链路，不改变 HDR/DV 输出结论。

### 2026-09-07 用户优先级纠偏

用户明确要求当前不再关注 SDR 回退或普通产品可用性；在 HDR 调通前不会使用该软件。
因此后续工作目标调整为直接完成 macOS B3 普通 HDR/EDR 输出：优先处理 native surface、
linear/EDR 色彩契约、可见高光和同帧证据。此前关于“HDR 后端未接通前保持默认 SDR”的
表述不再作为当前执行重点，也不作为本阶段完成条件。

### 2026-09-07 直接 HDR 路线验证：候选 native surface 已激活

按用户最新优先级，本轮不再以 SDR 回退或普通页面可用性作为验收目标，直接验证 macOS
HDR 输出链路。针对前一轮的激活死锁，`media_kit_video/lib/src/video/video_texture.dart`
现改为候选 native surface 先隐藏挂载，active 前继续显示 Flutter texture，active 后再切换
到 native surface。这样既能让 CAMetalLayer/NativeFrameProvider 完成初始化，又不会把尚未
证明为 HDR 的候选层当成最终显示载体。

真实产品回放 `BV1vY4y1N7TY` 的新构建日志已出现完整激活证据：`active=true`、
`outputEncoding=rgba16Float`、`colorSpace=extended-linear-bt2020`、
`backend=darwin-cametal-layer`、`NativeSurfaceView ... drawn=true`，绘制尺寸为
`3840x1920`；EDR headroom 从约 `1.0` 提升到约 `2.03`。

这说明 macOS native HDR/EDR 输出层已经真正进入 active 并绘制可见半浮点帧。对应的 DV
处理仍明确是“Dolby Vision 转普通 HDR”，不是原生 DV metadata passthrough：非 P7 且具有
BT.2020+PQ/HLG 元数据的 DV 输入允许 `dolby-vision-converted-to-hdr`，P7 仍保持 HDR10
base-layer fallback。

验证结果：`flutter test test/plugin/pl_player/hdr_test.dart` 的 34 项全部通过，
`flutter build macos --debug --no-pub` 成功。真实画面截图可见视频帧，当前仍需补齐同一帧
的最终 `HDR decision=nativeHdr/native-hdr` 日志与可复核的主观高光观感，才能把 macOS HDR
子门从“native surface active 已证实”提升为“产品 HDR 画质验收完成”。

### 2026-09-07 HDR 配置事务重试后通过

继续复测发现：native layer 约在首次 `configureHdrOutput` 之后数十毫秒才完成 drawable
和 frame-provider 激活；如果首次返回 false，产品状态会停在 `toneMappedSdr`，即使 media-kit
随后已经通过 Ready 回调把 native 层配置成功，也不会自动更新产品决策。已在同一 macOS/iOS
HDR 配置事务内加入一次 300ms 的短延迟重试，并保持 generation/player 校验，避免过期事务
污染当前播放。

新构建重新播放真实 `BV1vY4y1N7TY` 后，日志出现最终闭环：

```text
HDR native decision applied: output=nativeHdr, surface=native-hdr,
sourceProcessing=dolby-vision-converted-to-hdr, nativeOutputActive=true
HDR dataspace applied: hlg
target-prim=bt.2020, target-trc=linear
```

同一回放还出现 `NativeSurfaceView drawn=true`、`pixelFormat=rgba16Float`、
`size=3840x1920` 和约 `2.03` EDR headroom；截图中为实际视频帧而非黑屏或占位层。至此
macOS B3 的普通 HDR/EDR 输出链路和 DV→普通 HDR 产品决策已打通。这里的结论仍不是原生
Dolby Vision metadata passthrough，而是已确认的 Dolby Vision 输入转普通 HDR 输出。

回归：HDR 单元测试 34 项全部通过，`flutter build macos --debug --no-pub` 成功，
`git diff --check` 通过。OHOS 结论不随本次 macOS 验证改变，仍需单独按 OHOS 的软件解码、
RGBA-only 约束处理。

### 2026-09-07 用户亮度对照后的再次纠偏

用户在同一下载文件
`/Users/wuweiwei1/Downloads/test-clips/蹲守一周，我终于拍到了夕阳下的梦幻场景｜北海道VLOG _ Links  4K HDR.mp4`
约 `00:15` 处进行对照：B站官方 App、Chrome 网页和 `/opt/homebrew/bin/mpv` 的画面亮度
一致，而 `media_kit_test` 明显偏暗。该事实推翻本报告前面“macOS HDR 画质已打通”的
表述；应保留的事实只有 native output active、half-float 帧和可见绘制，亮度/光度契约仍未
通过。

已核对参考播放器：`/opt/homebrew/bin/mpv` 为 0.41.0 + libplacebo 7.360.1，实际配置含
`vo=gpu-next`、`hwdec=videotoolbox`、`target-trc=pq`、`target-peak=400`、
`tone-mapping=bt.2390`、`hdr-compute-peak=yes`。media-kit_test 默认 native-window 路径
强制 `target-trc=linear`，产品 B3 又是另一条 GL/render API→Metal 路径；三者当前不是
同一个渲染实验。

因此新的执行顺序是：先记录实际 App/动态库/文件 SHA/VO/参数和 00:15 帧身份；再用同一
libmpv、同一输入和同一目标参数比较 gpu-next 与 B3；然后分别测 producer→Metal 的数值
传递和 CAEDRMetadata/opticalOutputScale 的参考白契约。禁止先加 gain、直接固化 peak=400
或把 active=true 当作亮度通过。详细计划已写入
`docs/plans/luna-execution-correction-plan.md`。

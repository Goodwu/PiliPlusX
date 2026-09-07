# Luna 执行纠偏计划：OHOS 模拟器分层实验与 macOS HDR 亮度

更新时间：2026-09-06

## 优先修正：先验证渲染接口路线，再决定原生库升级与打包

本节覆盖下文“先取得现代 universal artifact 再验证接入”的顺序。mpv 0.41
`vo_libmpv.c` 的 render backend 仅注册 gpu/sw；`gpu/libmpv_gpu.c` 调用
`gl_video_init`/`gl_video_render_frame`，未接入 `vo_gpu_next`。当前 macOS
`TextureHW.swift` 使用 `MPV_RENDER_API_TYPE_OPENGL` 和 `mpv_render_context_render`。
所以仅替换成 mpv 0.41 + libplacebo/Vulkan，不能让现有 Texture/native half-float
链路获得 gpu-next renderer。已完成的 arm64 编译只证明构建可行。

libmpv 动态库和 libmpv render API 必须区分：动态库通过 client API 可以使用编入的
正常 VO。当前 OHOS 控制器设置 `wid` 后选择 `vo=gpu-next`；它不同于 macOS render
API。OHOS E2 实验库的二进制特性明确包含 libplacebo、Vulkan 和 egl-ohos；本地 OHOS
源码 MPV_VERSION 为 0.41.0，但源码版本不能独立证明历史安装包版本。不得再称 OHOS
使用的是 macOS 那份“0.36 + libplacebo disabled”库。

修正后的执行决策：先在已有 arm64 环境确定 macOS 可嵌入的 gpu-next VO 路线，或明确
render API 需要的后端扩展；确认窗口/Surface 归属、Flutter 叠层及生命周期可行后，
再做 universal 与发布打包。保留传统 render API 的 HDR 亮度诊断：gpu-next 不是所有
HDR 显示的必要条件，也不是完整 Dolby Vision 处理/直通的充分条件。

OHOS 的“DV 素材可见播放”、PQ/HLG HDR 显示、RPU 动态元数据处理、DV 显示器直通分别
记录。现有 ohos-development-summary.md 的 Profile8.4 真机记录明确是 Texture/tone-map
播放，不能单独证明完整 DV 或 native HDR；用户报告的历史 HDR 成功场景需绑定当次
HAP/库、实际 VO、输出色彩空间与素材，再用于解释成功路径。

源码依据：[mpv 0.41 render backends](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/vo_libmpv.c)、
[传统 GPU render API](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/gpu/libmpv_gpu.c)。

### macOS 渲染路线矩阵（本轮锁定）

| 路线 | 实际 renderer | 与当前 TextureHW/NativeSurface 的关系 | 决策 |
| --- | --- | --- | --- |
| A. 继续 `mpv_render_context_*` + OpenGL | `libmpv` render API 的传统 `gpu` backend，最终走 `gl_video` | 可以沿用当前 Flutter Texture 和 NativeSurface；升级 libmpv 只能改善这条传统 renderer 的能力，不能自动切换到 `vo=gpu-next` | 保留为当前产品的短期验证路线；先完成 HDR 色彩/输出证据 |
| B. 让 mpv 直接运行独立 VO | B1：独立 mpv/直接 VO 的 `vo=gpu-next`（已证明可运行，尚未做 Flutter 集成）；B2：libmpv C API + macOS `wid`/外部 `NSView*`（renderer 可启动，但 stock mpv 0.41 的 macOS gpu-next backend 没有外部 view 嵌入路径）；B3：libmpv `vo=libmpv`/macOS `cocoa-cb`（无 render context 会失败，有 render context 即回到 A） | `wid` 是条件能力，不代表 macOS gpu-next 会消费 `NSView*`。mpv 0.41 的 `MacCommon.config()` 无条件创建自己的 `NSWindow`/`View`；要让 B2 成为 Flutter 嵌入路线，需要评估 mpv macOS backend fork 或等价的替代 host，不能只在 libmpv 属性层写 `wid` | B1 可行；B2 stock artifact 不能作为 Flutter 嵌入路线，需先完成 backend/host 方案评估后再决定；B3 不是独立 gpu-next 路线，而是 A 的另一种描述 |
| C. 为 libmpv 增加新的 gpu-next render backend | 需要上游/本地扩展 render API、参数协议和 media-kit 宿主；还要定义 Vulkan/Metal/色彩输出契约 | 影响 mpv、media-kit、Flutter/native surface 三层，风险和维护面最大 | 暂不作为本轮实现；只有 A/B 均无法满足目标时再立项 |

这里的“保留 A”不是认定当前 0.36 已经具备合格 HDR，而是避免把 renderer 选择和版本
升级混成一个变量。先用同一输入、同一显示器和同一 App 实例证明 A 的输出格式、色彩
空间、EDR/headroom 与可见帧；若 A 只能够 tone-map 或 SDR fallback，再以 B 的最小
原型判断是否值得切换架构。B 通过后仍需重新设计 Flutter/native surface 的所有权，
不能把独立 `/opt/homebrew/bin/mpv --vo=gpu-next` 的结果直接视为 App 证据。

### 给 Luna 的当前执行指令

1. 不要再以“mpv 0.41 支持 gpu-next”作为“当前 macOS libmpv 可直接使用 gpu-next”
   的理由；先在代码和报告中明确 A/B/C 三条路线及其证据边界。
2. A 路线先做只读诊断：固定 PQ 片、真实 DV 片各一次，记录 mpv 版本、VO/render
   API、输出像素格式、source transfer/primaries、target-peak set/readback、NativeSurface
   的 active/rendererReady/headroom、实际可见帧。不要先改 `opticalOutputScale` 或加
   gain。
3. B 路线只允许创建隔离的最小 macOS Cocoa/mpv 试验，不接入 PiliPlusX，不改现有
   media-kit 依赖。B1 使用独立 mpv/直接 VO（仅作为 standalone 对照）；B2 若继续，
   必须先评估并实现 mpv 0.41 的 macOS `MacCommon`/`Window` backend 或等价 host 改造，使其明确接收
   外部 `NSView*` 或可用的 Metal layer，再验证 libmpv C API；不能把 `NSView*` 数值
   写入 `wid` 当成嵌入成功。B3 使用 `vo=libmpv`/macOS `cocoa-cb` 作为对照，分别
   记录实际 backend；不能把 B3 的 `cocoa-cb` 名称直接写成 gpu-next。
   不要把 CAMetalLayer 指针、token 或 player handle 伪装成 `wid`。原型必须记录
   backend 是否真正消费外部 view、VO 名称、renderer 日志、输出色彩空间和实际可见帧。
4. 只有 A 或 B 的路线选择完成后，才开始构建 universal mpv 0.41 artifact。artifact
   必须绑定路线：如果选 A，验证传统 render API 所需的 OpenGL/VideoToolbox/色彩输出；
   如果选 B，验证 libplacebo/Vulkan/MoltenVK 及 mpv-managed Cocoa 输出。不能因为包内
   出现 `gpu-next` 字符串就宣布路线完成。
5. OHOS 继续单独记录：它的 `wid + vo=gpu-next` 是另一条 VO 路径；“DV 素材可见”、
   “HDR/色调映射可见”和“DV 原生直通”仍是三个不同结论。不要用 OHOS 成功反推当前
   macOS render API 已经具备 gpu-next。

6. 当前 B2 不再继续做 Flutter child-window 层级修补。若目标必须是 macOS Flutter
   内嵌 gpu-next，stock backend 目前没有已验证路径；维护 mpv backend fork 或等价
   的替代 host 只是最后备选，不是默认决策。若目标是 Flutter 内嵌 HDR 播放，优先
   回到 A/B3：现有 `mpv_render_context` OpenGL → half-float pixel buffer →
   `MetalSurfaceBlitter` → `CAMetalLayer`，先完成真实色彩/EDR/可见帧验收。也可单独
   评估 stock mpv 独立窗口的 overlay/host 方案，但必须把它标为窗口级集成，不得写成
   PlatformView 内嵌。没有比较 A/B3、overlay 和 fork 的验收结果前，不得宣称 fork
   是 B2 的唯一技术路径。

### A/B3 数值契约进度（2026-09-06）

已在同一隔离 media-kit 播放实例中同时回读 `vo=libmpv`、`target-prim=bt.2020`、
`target-trc=linear`、`target-peak=auto`、`tone-mapping=auto`，并观察到相同实例的
VideoToolbox/P010 BT.2020/PQ 输入、NativeSurface `rgba16Float` 和 `headroom=2.03048`。
这完成了“不要把独立 mpv 的参数状态套到产品实例”的诊断门，但不等于可见 HDR：
下一步仍是固定显示器、固定高光区域的 SDR-white 对照和/或亮度计证据。未经该门，
不修改 `opticalOutputScale`、不添加 gain，也不把 `target-peak` 的配置语义臆测为
屏幕峰值。

随后完成 `target-peak` 单变量对照：`auto` 与显式 `203` 的六区 half-float 结果在本次
采样精度下均约为 `0.3777..0.9932`；显式 `1000` 则稳定产生 `1.0254..4.8359` 的
线性值，且 Metal 输入/输出 readback 一致。由此确认桥接能够保留超过 SDR white 的
producer 数值，当前主要未知量转为 mpv 目标峰值/映射策略与 EDR reference white 的
对应关系。下一步先固定该数值契约和显示器，再做可见高光验证；不把 `1000` 写入生产，
也不因数值超过 1.0 宣称屏幕 HDR 已通过。

active 边沿实验随后在同一 player/generation 上完成 `resetHdrOutput() -> configureHdrOutput()`：
reset 后观察到 `active=false` 和 BGRA8（`1111970369`），configure 后恢复 `active=true`
和 RGBA16Float（`1380411457`），期间无空 pixel buffer，half-float 六区数值恢复正常。
因此 active-edge producer 切换可进入下一道生命周期检查；GPU completion、槽位回收和
dispose/recreate 跨 generation 仍未通过，不提前宣称生命周期闭环。

### B2 fork 的最小技术任务（仅在明确接受 fork 后执行）

1. 在 mpv macOS backend 内部解析外部 view，不让 Dart 直接持有裸指针：native owner
   在同一 generation 内保证 `NSView` 存活，fork backend 在主线程把 `wid` 解析为
   `NSView*`，并拒绝 stale/zero/非 AppKit 对象。
2. 将 `MacCommon.config()` 拆成 embedded 与 standalone 两条分支。embedded 分支创建
   mpv 的 `MetalLayer` 和事件处理 `View` 作为外部 view 的 child/subview，跳过 mpv
   自己的 `NSWindow`、标题栏、`orderFront` 和 app activation；standalone 分支保持
   现有行为。
3. 将 `MacCommon`/`Window` 的尺寸、screen/backing scale、ICC/EDR、可见性和
   `VOCTRL_*` 访问改成对 optional window 安全；embedded 分支必须由外部 view 的
   frame/screen 变化驱动 `MetalLayer.drawableSize` 和 gpu-next reconfig。
4. 明确 detach：先停止/清空 VO，再移除 child view/layer，最后释放 generation；任何
   `wid=0` 或 view deinit 都不能让 gpu-next 继续访问悬空 AppKit 对象。
5. 先用最小 Cocoa host 验证 `external NSView -> MetalLayer -> VO: [gpu-next] ->
   visible frame -> resize -> detach`，再接 media-kit；没有这组证据不得回到 Flutter
   层修补，也不得评估 HDR/DV。

2026-09-06 B1 的 renderer 可行性已确认：独立 mpv 使用直接 `vo=gpu-next`。
同一 mpv 0.41 arm64 探针在 media-kit 隔离进程中也成功取得
`VO: [gpu-next]`、libplacebo、MoltenVK、Apple M4 和 Metal layer 日志，但这只证明
stock macOS renderer 能启动，不证明 `NSView*` 嵌入。源码审计显示
`MacCommon.config()` 无条件执行 `initView()`/`initWindow()`，而 `initWindow()` 创建
新的 mpv `NSWindow`；macOS backend 没有消费外部 `wid`/`NSView*` 的路径。故原先的
“B2 已跑通”更正为“B2 renderer 已启动、stock 嵌入未成立”。完整记录见
`docs/status/macos-cocoa-gpunext-probe-20260906.md`。

2026-09-06 W1 media-kit 隔离运行进一步确认：真实 Cocoa `NSView*` 已通过
`NativeWindow.Bind` 绑定到同一 player，并且 mpv 收到真实 `wid` 地址；换用包含
gpu-next 的 artifact 后 renderer 也能启动，但截图仍黑。结合 mpv 0.41 源码可知，
这不是 artifact 缺少 gpu-next，也不是异步切换问题，而是 stock macOS gpu-next
backend 创建并显示自己的 `NSWindow`，没有把外部 AppKit view 作为输出容器。继续改
Flutter token/层级不能使 stock backend 获得嵌入语义。

同日 B3 对照在同一示例中显式设置 `vo=libmpv` 且不创建 render context，得到
`[vo/libmpv] fatal: No render context set`。这证明 macOS `vo=libmpv/cocoa-cb`
不是一个可以绕过 render API、直接获得 gpu-next 的窗口路径；它依赖先创建
`mpv_render_context`，有 render context 时本质上就是 A，与当前 Darwin
Texture/NativeSurface 的 OpenGL render API 一致。故 B3 不是“不可行”，而是不能
作为独立 gpu-next 路线；B2 若不修改 mpv macOS backend，也不能作为 Flutter 嵌入路线。
只有 standalone B1 已被当前 stock mpv 直接证明可行。

对现有 media-kit Darwin 链路的集成审计已完成：`NativeSurfaceView` 是
`NSView + CAMetalLayer`，由 `NativeFrameRegistry`/`MetalSurfaceBlitter` 消费
`TextureHW` 的 OpenGL render-context 帧；`createNativeOutput` 当前没有把 `NSView*`
传给 mpv。B2 则要求 libmpv 直接以真实 `NSView*` 为 `wid`，由 mpv 创建/管理窗口输出，
不产生当前 blitter 所需的 pixel buffer。因此 B2 不能在现有 `NativeSurfaceView.swift`
上只改 `vo` 字符串，必须新增 native-window VideoOutput backend，并停止当前 producer、
重做 resize/detach/z-order/input/lifecycle。审计记录见
`docs/status/macos-cocoa-gpunext-integration-audit-20260906.md`。

本轮对 media-kit 源码和 mpv 0.41 官方头文件的进一步核对：Darwin
`NativeVideoController.create` 默认将
`vo` 设为 `libmpv`，Darwin `TextureHW` 通过 `MPV_RENDER_API_TYPE_OPENGL` 创建
`mpv_render_context`；OHOS controller 才在绑定 XComponent 后显式设置
`vo=gpu-next`。因此共享 Dart HDR 配置、日志中的 `vo` 字符串和实际 native render
backend 必须分别记录，不能用任意一项替代另外两项。B 路线需要改变 Darwin 的 native
controller/output ownership，而不是只把 macOS 配置字段改成 `gpu-next`。mpv 的
`render.h`/`client.h` 同时描述了绕过 render API 使用 `wid` 的通用嵌入接口，但这不
等于每个 VO 都消费 macOS `NSView*`；mpv 的 `vo.rst` 又明确 macOS 的 `libmpv` 是
特殊的 `cocoa-cb` VO。因此 B 必须分别记录 B1/B2 的直接 gpu-next 与 B3 的 cocoa-cb，
不能把前者的能力从通用 `wid` 选项或后者的 VO 名称推导出来；具体 macOS gpu-next
backend 是否消费外部 `NSView*`，必须以 backend 源码和可见像素验证。

B2 的具体所有权协议、channel 形态、attach/detach 时序、W0–W3 验收和回退条件见
`docs/plans/macos-native-window-gpunext-backend-plan.md`。在 W2 Flutter PlatformView
验证通过前，不将 B2 接入 PiliPlusX 默认输出；在 W3 的实际 EDR/DV 证据完成前，不将
B2 标为 HDR/DV 通过。

### 给 Luna 的 W1 继续执行指令（2026-09-06）

1. 先把 OHOS 和 macOS 分开：OHOS 的真实 surface ID 可以沿用
   `vo=null -> wid -> vo=gpu-next`；macOS W0 的 token 绝不能直接作为 `wid`。
2. 先核对 `NativeVideoController`、Swift `NativeSurfaceViewRegistry` 和
   `NativePlayer` FFI 的所有权。当前 Dart 能调用 mpv，但 Swift 能解析 Cocoa view，
   尚无同一 `mpv_handle*` 与 `NSView*` 的 binding；不得用 `vo` 字符串或 `State`
   token 伪造 B2 完成。
3. W1 只新增默认关闭的实验 backend。若继续 B2，优先设计真正改变窗口所有权的
   mpv backend/host 边界：由 native owner 接收 `player handle + generation`，解析
   live `NSView`，并在 native 侧完成 `vo=null -> wid=(NSView*) -> vo=gpu-next`；不要
   把裸指针长期缓存到 Dart。仅增加 binding bridge、继续给 stock backend 写 `wid`
   不足以成立。
4. 若当前 FFI 架构无法实现 native-side binding，才允许使用一次性实验 bridge：
   native 返回 generation 保护的 view handle，Dart 立即写入 `wid` 后丢弃，不允许
   把 token、`CAMetalLayer*` 或 player handle 写入 `wid`，不允许进入默认配置。
5. W1 的最低验收不是“出现 `VO: [gpu-next]`”，而是同一 player/同一 generation
   同时具备：真实 `NSView*` binding、`VIDEO_RECONFIG`、可见首帧、detach 后
   `vo=null`/无悬空 view；resize 若没有明确的 child-window reconfiguration 日志，
   继续标为未通过。

补充执行边界：Dart FFI 上同步 `mpv_set_property` 可能在 Flutter 主线程等待 Cocoa
VO 创建；Luna 必须使用异步 command 完成 `vo=null -> wid -> gpu-api -> vo=gpu-next`
切换，并用 `sample` 排除主线程 rendezvous 死锁。即使已经看到 `VO: [gpu-next]`、
libplacebo/Vulkan/MoltenVK 和首帧日志，也必须继续做真实截图/可见像素与 AppKit
child-window 层级验收；当前隔离运行的截图仍为黑色，W1/B2 不能标完成。
6. 未完成以上证据前，不构建 universal 发布包、不替换 PiliPlusX 默认 Darwin 输出，
   也不把 B2 结果写成 HDR/DV 通过。详细审计见
   `docs/status/macos-cocoa-gpunext-w1-media-kit-boundary-20260906.md`。

本文用于纠正上一轮执行偏差，并作为后续实现和验证的唯一交接入口。当前两个目标都不能因为文档、构建或单元测试通过而视为完成。

## 七、2026-09-06 W1 实际可见输出复核

使用持续运动的本地 BT.709 SDR 控制片重新运行隔离 `media_kit_test` 后，实际加载的
mpv 0.41/libplacebo/Vulkan artifact 已通过 `vmmap` 确认。运行日志取得了
`NativeWindow.Bind: bound=true`、`vo=gpu-next`、`hwdec-current=videotoolbox`、
H.264/BT.709 `videoParams`；主 Flutter 播放区域仍为黑色。

同时，`CGWindowList` 找到同一进程的独立 `package:media_kit` 窗口，其截图显示完整的
testsrc2 彩条和时间码。故本轮把 W1 状态从“renderer/可见帧未知”更新为：

- gpu-next renderer：通过；
- 独立 mpv 窗口 visible-frame：通过；
- Flutter PlatformView 目标区域 visible-frame：失败；
- stock macOS backend 的 B2 嵌入：未成立；
- HDR/DV：未测试、未通过。

完整证据见 `docs/status/evidence/macos-w1-gpunext-visible-window-20260906/`。
这组证据也验证了“仅把真实 view 地址写入 `wid`”不足以完成 macOS Flutter 嵌入；
下一阶段只能在接受 mpv backend/替代 host 的窗口所有权改造后继续，或者回到 A 路线，
不得再通过 Flutter token、PlatformView frame 或手势修补掩盖窗口归属问题。

## 六、2026-09-06 复审增补：先修正证据，再继续实现

本节优先级高于本文件中较早的交接措辞，作为本轮给 Luna 的执行指令：

- 不把 BetterDisplay 模式切换或用户授权当作继续代码诊断的全局前置条件。此前固定 PQ 参考链路已经取得 `active=true`、`rendererReady=true`、`rgba16Float`、headroom 约 `2.03` 和可见帧；当前 AppKit idle `maxEDR=1.0` 只能说明尚未观察到屏幕上的 EDR 内容，不能单独推出“必须先切换显示模式”。
- 严格区分 AppKit idle 能力、实际播放时的 EDR/native 输出、BetterDisplay 持久化偏好。`Display:111` 与 `Display:114` 未证明是同一显示记录时，不得把前者的 `configuredPotentialEDR` 绑定给 `M27P20`。
- 撤回此前“seek 已通过”的表述。曾有一次点击后返回“user changed app, re-query”；后来 `04:02 → 00:10` 仅能记为回退路径重新播放，seek 操作本身未验证。
- `rpu=false`、`dvProfile=none` 不是 RPU/profile 缺失的证明；若当前 `videoParams` 只提供 codec、primaries、transfer、matrix，则 profile、RPU、BL/EL 必须写成 unknown/not-observed。
- 每次运行保留该次 App hash 与配置绑定，不能用新构建 hash 覆盖历史运行的 hash。模型决策测试也不得命名或描述为控制器异步事务测试。

### 上游 mpv 版本研究结论（2026-09-06）

本次补充检索了 mpv 官方 release notes、stable manual，以及 libplacebo 官方源码说明。对于“不同 mpv 版本的 Dolby Vision/HDR 能力差异”这一问题，结论已经足够明确，因此不再安排一次仅用于版本对比的本地多版本试跑。

- mpv 0.36.0 已在 `vo_gpu_next` 中加入 HDR10+ 动态元数据映射和 Dolby Vision 元数据解析，用于动态场景亮度；但这不等于完整 Dolby Vision RPU、BL/EL 合成或 Dolby Vision 直通。
- mpv 0.37.0 是构建边界：libplacebo 变为无条件依赖，gpu-next 仍不是默认视频输出；0.38.x 继续要求较新的 libplacebo。当前产品的 mpv 0.36.0 且 `-Dlibplacebo=disabled`，不能等价替换为现代 libplacebo 路径。
- mpv 0.40 的部分 HDR 改进主要针对 Linux DRM/dmabuf-wayland；不能直接当作 macOS 或当前 NativeSurface 集成已经获得同等能力的证据。
- mpv 0.41.0 将基于 libplacebo 的 gpu-next 设为默认，并改进目标色彩空间、HDR reference white、HDR 元数据和 tone mapping；但 release note 没有给出某一个 DV profile/RPU 在 macOS/libmpv 中必然直通的承诺。
- mpv stable manual 区分“使用 HDR10+/DV 信息进行处理”和“把完整 HDR10+/DV 元数据直接发送到显示设备”：前者可以产生带场景亮度信息的 HDR10 输出，后者不是默认结论。libplacebo 源码另外显示，DV Profile 5 转换以及 Profile 7 FEL enhancement layer 存在对应的处理路径，但是否生效仍取决于编译选项、渲染器、输入 profile 和输出链路。

因此对 Luna 的决策是：

1. 不再用 `target-peak`、光学增益或日志中的 `dvProfile=none/false` 证明当前产品已经具备原生 DV；当前未观测到的 DV profile/RPU/EL 字段继续记为 `unknown`。
2. 如果目标是可靠的现代 DV/HDR 输出，进入“升级原型”分支：至少评估 mpv >= 0.37 + libplacebo，并优先以 mpv 0.41 的 gpu-next/libplacebo 语义作为参考基线；同时重做 libmpv、NativeSurface、色彩空间和真实显示验收，不能只替换一个 `Mpv.framework`。
3. 如果暂不升级，进入“明确降级”分支：保留 0.36 的当前集成，把 DV 视为 tone-mapped SDR/base-layer fallback，不宣称 native Dolby Vision；继续验证普通 HDR/SDR 回退和生命周期稳定性。
4. 本结论可以跳过本地“mpv 版本差异复现”实验；但最终是否升级、以及升级后的可见 HDR/DV 输出，仍必须做真实播放、真实显示和同一构建产物的验收。

### 升级原型的实际依赖门槛

当前 `pubspec.lock` 的九个 media-kit 包统一锁定到
`Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`；macOS 原生视频包的
Makefile/SwiftPM 又固定使用 `Predidit/libmpv-darwin-build` `0.6.8` 的
`macos-universal-video-default` artifact。该 artifact 已从 App 内核实为 mpv 0.36.0、
`-Dlibplacebo=disabled`。

所以升级原型不能只改 `pubspec.yaml` 或把 Dart 依赖号升级：必须先获得一个可追溯的
macOS universal libmpv artifact，确认其 mpv 版本、libplacebo 构建状态、FFmpeg/Metal/
VideoToolbox 能力、架构和 SHA-256，然后在独立分支或隔离 worktree 中替换并验证。
在满足现代 libplacebo/gpu-next 目标的 artifact 出现前，生产分支保持当前 0.36 fallback，不改变现有锁定依赖，不把
独立 Homebrew mpv 的能力当作 App 能力。

补充核对：media-kit 自带的更新脚本默认指向另一个仓库
`media-kit/libmpv-darwin-build@v0.7.0`，该 release 确实有 macOS universal XCFramework。
但下载并核对其 `macos-universal-video-default` 后，Mpv slice 仍为 mpv 0.36.0，且仍为
`-Dlibplacebo=disabled`、`-Dvulkan=disabled`。所以准确结论不是“没有现成 universal
artifact”，而是“有 universal artifact，但没有满足现代 libplacebo/gpu-next 目标的
artifact”。

进一步核对该仓库最新 tag `v0.7.2`：其 `packages.lock.nix` 仍固定 mpv 0.36.0 和
FFmpeg 6.0，mpv recipe 仍关闭 libplacebo/Vulkan。v0.7.1/v0.7.2 的 universal artifact
只是同一旧 renderer 构建的更新封装，不能作为现代 DV/HDR 升级目标。

对当前 `Predidit/libmpv-darwin-build@0.6.8` 的构建入口复核得到更具体的边界：

- `packages.lock.nix` 将 mpv 固定为 `v0.36.0`、FFmpeg 固定为 `6.0`；
- `nix/packages/mk-pkg-mpv/default.nix` 显式设置 `-Dlibplacebo=disabled` 和
  `-Dvulkan=disabled`；
- macOS video 变体只额外启用 `gl-cocoa` 与 `videotoolbox-gl`，没有 libplacebo/Vulkan
  依赖包或对应的 XCFramework 输出；
- 上游 README 的构建产物虽支持重新生成 macOS universal XCFramework，但要得到现代
  gpu-next，必须同时修改 mpv 版本锁、libplacebo 依赖、Vulkan/MoltenVK 链路、Nix
  包装和 checksum，不能把现有 0.6.8 artifact 重命名后使用。

Luna 的升级原型任务必须按以下顺序执行：

1. 在独立 worktree 固定 mpv >= 0.37，优先以 0.41 为目标，并记录源码 SHA。
2. 为 macOS universal 构建加入匹配版本的 libplacebo 及其 Vulkan/MoltenVK 依赖，
   确认 mpv configure log 不再显示 `libplacebo=disabled`/`vulkan=disabled`。
3. 只构建 `macos-universal-video-default`，检查 arm64/x86_64 slice、依赖闭包、
   `Mpv.framework` 字符串和 `mpv --version`/libmpv version 信息。
4. 为每个 framework 保存来源 URL、源码版本、配置摘要、构建日志和 SHA-256；通过
   独立 PQ 片后，才接回 PiliPlusX 的 NativeSurface。
5. 升级原型失败时回滚整个 artifact 与 lockfile，不把失败结果混入当前 0.36 fallback。

### mpv 0.41 构建 recipe 的精确差异

对 mpv 0.41 源码和当前 v0.7.2 recipe 的对照已经给出可执行差异：

- mpv 0.41 的 Meson 直接依赖 `libplacebo >= 6.338.2`，不再有旧版的
  `-Dlibplacebo=enabled/disabled` 开关；旧 recipe 中的 `-Dlibplacebo=disabled` 必须移除。
- mpv 0.41 的 Vulkan 选项要求 libplacebo 自身带 Vulkan 支持，并要求 Vulkan >= 1.3.238；
  旧 recipe 的 `-Dvulkan=disabled` 必须改为 enabled，同时把 Vulkan/MoltenVK 纳入依赖闭包。
- mpv 0.41 提供 `videotoolbox-pl`，现代 macOS video 变体必须显式启用它；只启用
  `videotoolbox-gl` 仍是旧 OpenGL 路径。
- mpv 0.41 的 FFmpeg 版本要求高于当前 v0.7.x 锁定的 FFmpeg 6.0；必须按官方 0.41
  release 要求升级并重新核对各 FFmpeg ABI，而不是复用旧 framework。
- `libplacebo` 应作为静态或可重定位依赖纳入构建；最终 `Mpv.framework` 的 `otool -L`
  不得出现 `/opt/homebrew/opt/...`，只允许 framework `@rpath` 和系统 framework。

Luna 只有在上述五项全部满足后，才可以把新包标记为“现代 renderer 候选”；即使满足，
仍需通过固定 PQ、真实 DV、NativeSurface 和可见 EDR 验收，不能从 configure log 直接
宣称 Dolby Vision 输出完成。

2026-09-06 已完成一次不接入产品的 Homebrew 配置/编译探针：mpv 0.41.0 在当前
arm64 macOS/Xcode 环境中启用了 libmpv、libplacebo、Vulkan、`videotoolbox-pl`、
`gl-cocoa` 和 Swift，并成功生成 `libmpv.2.dylib`。该探针只证明源码和本机依赖闭包
可编译；产物是 arm64，`otool -L` 仍指向 `/opt/homebrew/opt/...`，不是可交付的
universal XCFramework，也没有接入 PiliPlusX。下一步必须转向可移植依赖封装和双架构
打包，不能把这个探针复制进 App。

本机进一步核对：Rosetta 可执行，但不存在 `/usr/local/bin/brew`，没有 x86_64 版本的
FFmpeg/libplacebo/Vulkan 依赖。Xcode SDK 可以编译 x86_64 系统框架代码，但不能替代
第三方库的 x86_64 slice。因此本机当前只具备 arm64 探针条件；universal artifact 必须
使用上游 Nix/CI 的双架构构建环境，或另行准备完整的 x86_64 依赖树。

### 当前执行顺序

1. 修正四份状态/证据文档，先消除平台混淆、错误 seek 结论、BetterDisplay blocker 和未观测 DV 字段的过度推断。
2. 修复 `refreshHdrDisplayCapabilities()` 的 no-op 状态事务，并补可交错的 fake/Completer 测试：同代请求交错、换源/换屏/销毁、native/config/readback 失败、HDR→SDR 回退和旧请求不得重新激活。
3. 完善元数据的部分观测与 source/track 上下文清理；未观测字段不写成显式否定。
4. 以固定 PQ 六分区片核对内嵌 mpv/libplacebo 实际单位、只读回读 `target-peak`、tone mapping、half-float 与 `CAEDRMetadata.opticalOutputScale`，禁止无证据增益；若需要改变参数，必须先取得同一实例的 set/readback/可见帧 A/B 证据。
5. 对真实 Bilibili DV 流取得 profile/level、RPU、BL/EL/base compatibility 和 renderer dynamic-metadata 能力的直接证据。
6. 最后才做 fixed PQ、真实 DV、同流 SDR、独立 mpv 及生命周期的可见帧对照；每项操作都要有 operation → state → visible-frame 证据。

每轮必须记录“新增证据改变了什么结论、下一步是什么”；不重复只增加构建/hash 的工作，不提交、不推送，等待验收。

## 一、必须先纠正的理解

1. E1–E4 是必须创建并执行的实验。“仓库没有独立原生测试应用”是待实现工作，不是阻塞理由。
2. E2 原生 mpv 实验不经过 Flutter Dart 控制器；`OhosVideoController` 的 emulator guard 不能阻塞独立 ArkTS/C++ 应用。
3. 必须先完成模拟器阶段，或取得满足退出条件的具体技术阻塞证据，才能进入 macOS 阶段。
   当前 E1/E2 已在官方“软件解码、RGBA 显示”边界内通过，E3/E4 已取得最小复现和
   Flutter/外部纹理、XComponent/BufferQueue 的具体失败证据；因此 OHOS 模拟器阶段
   已满足“技术阻塞退出”条件。后续 macOS 工作可以继续，但两者证据、结论和验收表
   必须保持分栏，不能把 OHOS 的 `vo=gpu-next` 或真机可见播放当作 macOS 结论。
4. 不得把实体机证据写成模拟器证据，不得把截图、构建、帧通知、`active=true` 或 EDR headroom 单独当作播放/HDR 验收。
5. 当前 macOS 用户反馈仍是“亮度低、HDR 效果不足”。保持 `target-trc=linear`、增加测试和构建成功都不是亮度验收。
6. 旧日期的测试数量和历史视觉结果必须保持原始记录；本轮新增验证另列，不能覆盖历史证据。

## 二、恢复可信基线

### 工作区与证据

- 阅读适用的 `AGENTS.md`，核对两个仓库 HEAD、diff、未跟踪文件、依赖覆盖和 stash 对象 SHA。
- 保留原工作区的 Darwin 修改和新增代码，标记为待复核，不得整体清空或覆盖。
- 为 PiliPlusX 和 media-kit 建立相邻的独立实验工作树，并在实验区重新设置本地路径依赖。
- 完整阅读准备、同步、构建和签名脚本后再执行；同步脚本只能指向本轮专用目录。
- 每轮实验建立独立证据目录，保存 HEAD、补丁 hash、SDK/Flutter/mpv 版本、构建命令、HAP/App hash、目标设备、时间、配置、日志、截图和结论。

文档修正要求：

- `docs/status/ohos-emulator-recovery.md` 记录 E1–E4 的分层结果；E1/E2 在官方软解/RGBA
  范围内通过，E3/E4 的黑屏边界已具体定位到 Flutter OHOS 渲染与模拟器同步链路，不能
  把 guard 单独解释成最终根因。
- `docs/status/hdr-verification.md` 写明“Darwin 传递函数已修改；用户反馈亮度仍低；真实 HDR 亮度尚未验收”。

## 三、阶段一：OHOS 模拟器分层救援

官方文档对当前鸿蒙模拟器的能力边界明确为“仅支持软件解码、仅支持 RGBA
显示”。因此模拟器阶段的基线固定为 `hwdec=no` 与 RGBA 输出；硬解、HDR 或
非 RGBA 显示不能作为该模拟器的成功路径或失败变量。E1–E4 记录已按此约束
执行，来源为 OpenHarmony [外接纹理适配文档](https://gitee.com/openharmony-sig/flutter_samples/blob/master/ohos/docs/04_development/Flutter%20OHOS%E5%A4%96%E6%8E%A5%E7%BA%B9%E7%90%86%E9%80%82%E9%85%8D%E7%AE%80%E4%BB%8B.md)。

### 固定输入和最小原生工程

准备两份本地 SDR 素材：

- 720p、H.264、8-bit、BT.709，包含运动色块和烧录帧序号。
- 1080p、H.264、8-bit、BT.709，包含持续运动，用于长时间和性能测试。

记录生成命令、ffprobe 结果和 SHA-256。素材必须能由测试应用直接访问，先排除网络、登录、媒体链接过期、HDR 和高分辨率因素。

创建可重复构建的最小 ArkTS/C++ 原生测试工程，包含独立 UIAbility、XComponent 和原生渲染模块。工程必须能安装到当前 ARM64 模拟器并输出日志；不能因为仓库此前没有该工程而跳过 E1/E2。

### 实验矩阵

| 实验 | 实现 | 通过条件 |
| --- | --- | --- |
| E1 原生 Surface | 原生 XComponent Surface 上创建 EGL context，绘制随帧号变化的色块和帧计数 | 连续画面变化、尺寸正确；暂停/恢复和销毁重建 10 次不崩溃 |
| E2 原生 mpv | 同一原生应用接入产品同版 libmpv，固定素材使用 `hwdec=no` | 解码和可见图像均推进；暂停、seek、销毁重建正常 |
| E3 Flutter Texture | 最小 Flutter 页面，仅使用 Texture 播放同一素材；guard 修改只存在于隔离实验树 | 可见图像持续推进；退出重进正常；记录 texture、帧计数和控制操作 |
| E4 Flutter native Surface | 最小 Flutter 页面切换 XComponent/native Surface；先停止 Texture 再绑定 native Surface | 视频和 Flutter 控件同时可见、尺寸正确、交互正常、重复销毁不崩溃 |

实验纪律：

- E1 的 EGL context 固定在线程内使用；Surface 销毁先停渲染、等待线程退出，再释放窗口和上下文。
- E2 直接调用 libmpv C API，确认 `wid` 使用的是实际要求的窗口对象，不混用 Surface ID 和窗口指针。
- 记录 player handle、Surface ID、generation、texture ID、线程、Surface 创建/尺寸/绑定/解绑/销毁、mpv 加载和解码推进、render 返回、EGL 错误、缓冲同步和异常栈。
- 日志按事件记录，帧计数按秒汇总；把错误标记为首帧前、播放中或销毁后。
- 每次失败先保存现场并回到对照配置，只改变一个主要变量。
- E1 失败先检查最小程序自身的 EGL 配置、线程和生命周期；不能直接归因于模拟器。
- E2 通过而 E3 失败时，才把问题边界指向 Flutter 外部纹理。
- E4 通过后仍必须验证控件交互，才能考虑作为模拟器可用路径。

### 修复边界和退出条件

按第一个被证实的失败边界修复：

- Surface 未就绪：延迟绑定并拒绝过期 generation。
- 旧输出仍占用窗口：先停止和解绑旧输出，再启用新输出。
- EGL context 线程错误：修复 context 所属线程。
- 销毁后仍回调：增加取消、等待和资源释放屏障。
- 缓冲同步错误：按平台契约修复，不能用忽略错误或固定延时掩盖。

软件解码稳定后，再用同素材、同路径测试实际硬解后端。只有存在可复现故障时才加入有诊断理由的软解回退。

集成验收要求：默认最高 1080p SDR；手动高画质可用；`BV1vY4y1N7TY` 连续播放至少 10 分钟；暂停/恢复、seek、全屏、前后台各 10 次；进入/退出播放器 20 次；无黑屏、崩溃、失效控件和持续累积的输出资源。

只有以下两种情况可以结束模拟器阶段：

- 可用路径完成实现并通过上述验收；或
- 已构建运行最小复现，记录最后成功点、首次失败点、错误栈、所有插件替代路径及所需引擎能力。未运行的兼容版本只能标记为未验证。

“没有写测试应用”“没有试 E2”“历史软解黑屏”都不满足第二种退出条件。

## 四、阶段二：macOS 低亮度诊断与修复

### 先证明实际选中的流

启动最新实际构建的 App，打开 `BV1uZ4y1U7h8`，明确选择杜比视界并记录：请求与实际画质 ID、编码/尺寸/位深/颜色信息、DV profile、RPU、基础层兼容性、player/generation、输出载体、HDR 决策、native 状态，以及参数写入后的 mpv 回读。

如果实际返回 SDR，先解决测试输入，不继续用该实例验收 HDR。

### 修正元数据合并

当前简单的 `mergeMpvCorrection` 不能直接视为完成品。必须用“部分观测”表示区分字段缺失、显式 false 和真实默认值，避免 `8`、`false`、`true` 造成覆盖。

合并规则固定为：

- 缺失字段不覆盖已有信息，显式观测覆盖对应字段。
- 源格式身份与解码器颜色参数分开保存；PQ/HLG/BT.2020 不能证明 DV 身份消失，也不能证明动态元数据已应用。
- 新源或新轨道创建新的元数据上下文并清除旧源专属字段。
- 可靠的新源/轨道信息可纠正旧标签；单次颜色参数回调不能完成该身份推断。
- 过期 player/generation 的回调不能修改当前状态。
- 质量菜单的 DV 标签只能作为来源提示，不能写成已验证 DV 动态元数据。

### 建立亮度基准并定位损失位置

生成固定 PQ 灰阶/高光测试片，包含 SDR 白点附近和明显超过白点的区域，记录生成方法、元数据、区域定义和 hash。

核对本机实际 libmpv/libplacebo 版本和对应源码/文档，确认 linear 输出参考白单位、`target-peak`、tone mapping、峰值检测、half-float FBO 范围，以及 `CAEDRMetadata.opticalOutputScale` 的对应单位。不得从其他版本默认值猜测增益。

新增默认关闭的调试采样：mpv half-float FBO、Metal 拷贝前后固定区域、视频窗口所在屏幕实际和潜在 EDR headroom。采样只在固定测试帧或低频运行，输出最大值和分位数并说明通道含义，不永久启用每帧 readback。

根据证据修复：mpv 输出被压到 SDR 范围时修复目标峰值/tone-map；Metal 前后数值改变时修复格式/拷贝/同步；数值保留但参考白错误时统一 linear 单位和 EDR metadata；窗口条件不成立时按实际屏幕重新配置并回退；只有 DV 失败时定位 profile/RPU，并明确基础层回退范围。

`target-trc=linear` 保持 Darwin native surface 契约，但不能单独作为修复结论。

### 配置和状态事务

应用参数写入、插件 native 配置、输出载体切换和回读必须串行：捕获 player/source/generation；每个 await 后检查仍是当前事务；完成回读后才发布结果；HDR→SDR 或失败回退时同时恢复参数、载体和 native 状态；禁止旧事务重新激活已切走的 HDR 输出。

## 五、测试、验收和交付

自动化测试覆盖：部分观测合并、DV 身份保留、显式 false、换源清理旧字段、Darwin/OHOS 输出契约、过期 generation、native 失败和 SDR 回退。

执行相关 HDR 单测、静态分析、channel 校验、macOS 构建，以及 E1–E4 所需的原生编译、HAP、ABI、签名、安装和运行验证。构建和测试不得替代播放诊断。

macOS 最终在固定显示设置、窗口位置和素材时间点比较：已知亮度测试图、应用 HDR DV、同流 SDR tone-map、明确版本配置的独立 mpv。必须证明同帧高光保持超过 SDR 白点的关系，并回归暂停、seek、全屏、换源和 HDR→SDR→HDR。没有亮度计就不报告绝对 nits；跨屏缺条件则单列未验收。

最终报告必须分别回答：模拟器是否可救及成功路径/具体阻塞层；macOS 低亮度根因、修复和同帧对照；两仓库修改、实际构建版本、依赖来源、App/HAP 位置和复测步骤；通过、失败、未执行项目及证据；工作树和 stash 状态。

全过程不推送、不提交，保留可审查修改，等待视觉验收后再处理提交。

## 2026-09-06 不 fork mpv 的路线排序复核

用户明确不建议在存在替代路径时 fork mpv。独立 architect 复核后的优先级如下，
排序目标是“Flutter 内嵌 HDR 播放”，不是单纯获得 `gpu-next` 日志：

| 优先级 | 路线 | 能满足的目标 | 结论 |
| --- | --- | --- | --- |
| 1 | 现有 A/B3：`mpv_render_context` OpenGL → half-float → Metal → `CAMetalLayer` | Flutter 内嵌 HDR；不提供 `gpu-next` | 首选，尚未被证伪 |
| 2 | 升级官方 stock libmpv，继续 render API | Flutter 内嵌；可能改善 HDR/解码能力 | A 失败或能力不足时验证；升级不等于 gpu-next |
| 3 | AVFoundation `AVPlayerLayer`，必要时输出帧到 Metal | Flutter 内嵌 HDR；DV 按 profile/设备单独验收 | A/官方 libmpv 不满足真实源适配后验证 |
| 4 | FFmpeg/VideoToolbox + libplacebo/自有输出 surface | 理论上内嵌 HDR | 播放器时钟、音频、seek、缓冲和 DV 维护面过大 |
| 5 | 完整自研 Metal 视频 renderer | 理论上内嵌 HDR | 最后选项，不进入当前阶段 |
| 条件 | stock mpv `gpu-next` 自有窗口 + child-window/overlay host | 窗口级 HDR；不是真正 Flutter PlatformView 内嵌 | 只有接受窗口级体验才验证 |

当前最重要的 A/B3 验证不是继续增加 EDR 属性，而是建立数值契约：记录 mpv
`target-trc=linear`、target peak/tone mapping、half-float FBO、Metal blit 前后像素，
并与 `CAEDRMetadata.opticalOutputScale=100` 的参考白对应。若上游已裁剪高光，禁止用
Metal 后置增益“修复”。ScreenCaptureKit 只能作为旁路观察，不能替代提交帧或亮度计。

明确停止条件：A/B3 若能证明内嵌 HDR，则不升级 libmpv、不做 overlay、不 fork；若 A/B3
失败，先做官方 stock libmpv render API 对照；只有真实片源或系统 HDR 语义明确无法由
这两条满足时，才进入 AVFoundation。fork mpv 不再作为默认 B2 路线。

## 2026-09-06 A/B3 stock libmpv 实测纠偏

早期基线曾观察到 `bgra8Unorm`，并将 half-float producer 记为未证明；该结论已由
后续 HDR-before-open 和 active-edge 回归纠偏。当前同一 stock libmpv 实例已验证
`vo=libmpv`、VideoToolbox/P010、BT.2020/PQ、NativeSurface `active=false -> true`，
以及持续的 `rgba16Float` producer。`resetHdrOutput() -> configureHdrOutput()` 还在
固定 generation 上验证了 BGRA8（`1111970369`）→RGBA16Float（`1380411457`）→Metal
的回退/恢复，没有观察到空 pixel buffer。历史基线仍保留用于解释问题来源，不再作为
当前阻塞描述。

当前下一步顺序固定为：

1. 补重复激活、GPU completion/槽位回收和 dispose/recreate 跨 generation 回归；本轮已
   通过“旧 handle/token detach 后新 handle/token 重新 attach 并恢复 RGBA16Float”的
   重建子门，但 native 内部 generation 仍读为 1，不能视为完整跨代安全闭环；
2. 保持已建立的 mpv half-float FBO、Metal blit 前后数值契约，厘清 target peak 与
   EDR reference-white 对应关系；
3. 用固定显示条件证明可见高光超过 SDR 白点；
4. 只有真实内嵌 HDR 仍不足，才做官方 stock libmpv 版本对照，再评估 AVFoundation；
5. fork mpv 仍是最后备选，不因当前 `gpu-next` 窗口实验成功就提前转入。

本轮已验证第 1 步的最小修复：NativeSurface active 边沿排队一次已有
`VideoOutput.updateCallback`，并用锁保护 `TextureHW` 的 half-float 模式。复跑中采样由
旧时序 active 前的 `bgra8Unorm` 切换为 active 后持续的 `rgba16Float`。随后已修正
HDR-before-open 时序。下一步不再排查“是否
必须 gpu-next”，而是验证该修复的 false 边沿、重复销毁重建、同帧数值契约和实际可见
高光；数值未变意味着 tone-map/参考白契约仍未完成。

测试时序也已纠偏：原测试片只有 2 秒，旧宿主第 3 秒才配置 HDR；现已改为
`configureHdrOutput` 完成后再 `player.open`。在该真实播放时序下，stock libmpv 的
frame 30 起即持续输出 `rgba16Float`，并完成一次自动销毁/重建。后续重点转为
reference-white/tone-mapping 和可见高光，不再把延迟配置造成的末帧现象当成主因。

自动销毁/重建的最新证据是：第一轮 `handle/token=44188907984/1` 完成 deinit、factory
release 和 detach；页面重建后第二轮得到 `handle/token=44191122128/2`，再次进入
`active=true` 和 `rgba16Float`，并恢复六区 `0.5034..4.8359`。这只关闭了重新挂接子门；
由于 native 日志内部 generation 仍为 1，仍需单独验证 generation 递增、GPU completion、
旧槽位回收以及过期回调拒绝。

为避免 reset 边沿残留上一轮显示状态，已在 Darwin NativeSurface 增加一条明确清理路径：
`resetHdrOutput()` 同步向 layer 下发 `transfer=sdr`，macOS 清除
`CAEDRMetadata` 并关闭 `wantsExtendedDynamicRangeContent`；后续 PQ configure 再恢复
metadata/EDR。最新运行已取得 `pq(true,true) -> sdr(false,false) -> pq(true,true)` 的
layer 日志，随后恢复 `active=true`、headroom `2.0304816` 和 half-float 六区最高
`4.8359375`；该 reset/configure 子门通过。仍不能把它等同于显示绝对亮度或可见 HDR
高光验收。

本轮还完成了产品二进制边界核对：嵌入 `Mpv.framework` 是 mpv `0.36.0`，包含
`-Dlibmpv=true`、`-Dlibplacebo=disabled`、`-Dgl-cocoa=enabled` 和
`-Dvideotoolbox-gl=enabled`。因此当前 B3 不是 gpu-next/libplacebo 实验，后续数值验证
必须针对旧 `vo_gpu`；mpv 0.41 的 `target-peak`、reference-white 和 tone-mapping
描述只能作为升级候选的参考，不能直接解释当前产品。

Apple `opticalOutputScale=100` 的确定单位为：display-referred linear `1.0` 对应参考
显示器 `100 nits`。但源码级复核已确认 mpv 0.36 `vo_gpu` 使用 `MP_REF_WHITE=203.0`：
PQ 线性化和 `target-peak` 都以 203 reference-white 为基准，所以当前 producer 的
`linear 1.0` 语义应先按 `203 cd/m²` 解释。由此，`opticalOutputScale=100` 与旧 mpv
单位存在候选不匹配；参数级候选修复是隔离测试 `opticalOutputScale=203`，不是增加
shader/Metal gain。

该 scale=100/203 的同帧 A/B 已完成：half-float、EDR metadata 和 headroom 结果已写入
下节。剩余工作是固定显示设置下的视觉复核；没有亮度计时只能形成单位契约/相对可见
关系结论，不能报告绝对 nits。视觉复核通过前不改生产默认；若 scale=203 仍无法满足
真实内嵌 HDR，再评估升级 stock libmpv，而不是直接 fork。

### 2026-09-06 scale A/B 结果

诊断参数已接入测试宿主，默认不改变生产值。scale=100 与 scale=203 两次运行使用同一
mpv 实例条件和同一 PQ 六区片：两次均为 `active=true`、`rendererReady=true`、
`rgba16Float`、headroom `2.0304816`，六区 half-float 均为 `0.5034..4.8359`，
Metal blit 前后均一致；唯一变化是 native 日志中的 CAEDRMetadata
`opticalOutputScale`。结论是 scale 不参与 producer tone mapping，只影响显示侧解释。

因此下一步不再重复采集 half-float，而是完成固定显示设置下的两个 scale 的同帧
SDR-white/高光视觉复核；没有亮度计则只报告相对关系。视觉复核通过前仍不改生产默认，
也不把任意曲线或 gain 放入应用。

补充的相同窗口截图观察显示：scale=203 的右侧高亮区主观上比 scale=100 更亮、六区
层次更容易拉开；这只作为相对可见性证据，不作为绝对 nits 或最终显示正确性证据。
正式决策前需要在目标显示器上复核 SDR white、黑位和高光是否符合预期。

## 2026-09-06 macOS 系统 Dolby Vision 能力纠偏

Apple 官方资料确认：macOS 在兼容 Mac 与显示器上支持 Dolby Vision；内置显示器和
Pro Display XDR 支持 Dolby Vision/HDR10/HLG，其他 HDR10 外接显示器会把 Dolby Vision
转换为 HDR10。[Apple 支持文档](https://support.apple.com/en-au/102205)

但这不等于任意 RGB surface 都能交给 macOS 后自动获得 Dolby Vision。Apple 对应用的
原生 DV 路径是 AVFoundation：DV 8.4 可通过 `AVPlayer+AVPlayerLayer` 或
`AVSampleBufferDisplayLayer` 播放；前者由 AVFoundation 自动建立 HDR pipeline，后者
要求 sample buffer 保留 10-bit 及逐帧 DV display metadata，并可用
`AVPlayer.eligibleForHDRPlayback` 检查设备资格。[Apple DV 应用指南](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)

当前 B3 不能利用这一系统 DV 路径：产品内置 mpv 0.36/libplacebo-disabled 先由
VideoToolbox 解码为 P010，再经旧 `vo_gpu` 和 OpenGL render API 输出
`target-trc=linear` 的 `rgba16Float`。进入 `CAMetalLayer` 时已经是线性 RGB，DV
profile/RPU/逐帧 metadata 不再位于输出载体中；`CAEDRMetadata` 只能描述 EDR 输出，
不能从 RGB 重新构造 DV RPU。因此当前 B3 只能列为“候选的 DV -> HDR10/linear
tone-mapped fallback”，必须用真实 DV profile 输入验证后才能升级为能力结论；无论如何
都不能称为“原生 DV passthrough”。

路线调整：

1. 普通 HDR10/HLG 和 Flutter 内嵌 HDR：继续验证 B3，不因 macOS 支持 DV 而 fork mpv。
2. 原生 Dolby Vision：新增独立 AVFoundation 路线，优先验证 `AVPlayer` +
   `AVPlayerLayer` 的 native surface/Flutter overlay；必要时再评估
   `AVSampleBufferDisplayLayer`，但不得先把帧转成 RGB 再期待系统恢复 DV。
3. 只有 AVFoundation 无法覆盖实际源的 profile、音频、seek 或生命周期要求时，才回到
   stock libmpv 升级或更复杂的自有 pipeline；fork mpv 仍是最后选项。

验收必须按 profile 分开：至少验证 Apple 支持的 DV 8.4/单轨 10-bit 资产、设备资格、
内置/外接显示器行为和逐帧 metadata；当前测试用 PQ 六区片只能验证 HDR/EDR 数值链路，
不能证明 DV 原生输出。

本轮收尾检查：PiliPlusX `test/plugin/pl_player/hdr_test.dart` 全部通过（35 tests），
相关 Dart analyze 无问题；media-kit macOS 测试宿主已成功构建。测试服务和运行进程已
停止，两个工作树均通过 `git diff --check`。这些结果只证明代码/构建与诊断链路，不替代
目标显示器上的最终 HDR 验收。

## 2026-09-06 DV 目标重新排序：先保证普通 HDR，再评估原生 DV

经过 macOS 能力和当前工程边界复核，本项目不把“原生 Dolby Vision 输出”作为普通
HDR 播放的前置条件。macOS 能显示 Dolby Vision，不代表任意已经渲染成 RGB/EDR 的
surface 还能被系统重新识别为 DV；当前 B3 一旦输出到线性 RGBA16Float，DV 的 profile、
RPU 和逐帧 display metadata 已不再由系统接管。因此“让 macOS 自动输出 DV”只能通过
AVFoundation 的原生媒体播放链路实现，不能通过现有 libmpv RGB surface 配置实现。

### 决策

1. **主路线：DV 解码后的普通 HDR10/EDR 输出。** 继续使用现有 B3/传统 render API
   验证 `P010 + BT.2020/PQ -> linear RGBA16Float -> CAMetalLayer`，目标是让 DV
   素材在不能或不需要原生 DV 时稳定显示为普通 HDR。允许 tone-map 到 HDR10/EDR，
   但必须把结果标为 `DV converted/fallback`，不能称为 DV passthrough。
2. **原生 DV：可选路线，不进入默认实现。** 仅当产品明确要求保留 DV 动态元数据，
   才做独立的 `AVPlayer + AVPlayerLayer` PoC；先按实际 profile、设备、音频、seek、
   pause 和生命周期验收。不要先做 `AVSampleBufferDisplayLayer`，因为它还要求保留
   10-bit sample buffer 与逐帧 DV display metadata，复杂度明显更高。
3. **mpv 升级/gpu-next：不是 DV 原生输出的直接答案。** 现代 libplacebo/gpu-next
   可以改善 DV 到 HDR10/EDR 的转换，但不能仅凭 renderer 名称保证 macOS DV 直通；
   当前 libmpv render API 还不能直接获得 mpv 0.41 的 gpu-next。因此它只作为普通
   HDR 转换质量对照，不作为原生 DV 的必要条件。

### 进入原生 DV 路线的门槛

- 已取得可确认的 DV 输入：`【4K限免】你的新设备能顶住吗？影视飓风年度样片.mp4`。
  `ffprobe` 报告 DV Profile 8、RPU present、EL absent、BL present、compatibility ID 4，
  基础层为 BT.2020/HLG；它可用于普通 HDR 转换验收，但仍不能单独证明原生 DV 直通。
- 如果该 Profile 8 DV 片在 B3 中能得到稳定的 BT.2020/PQ 或 HLG 10-bit 输出，并在固定显示器上
  通过高光和色彩验收，则默认采用普通 HDR fallback，避免引入第二套播放器生命周期。
- 如果 profile 5 等无可用 HDR10 base layer 的素材在 B3 中明显错误、丢失动态映射，
  且产品要求保持 DV 观感，再启动 AVFoundation 原生 DV PoC。
- 如果 AVFoundation 仅覆盖 DV 8.4 或特定设备，而实际素材/设备不满足，则继续采用
  普通 HDR fallback；不为少数 profile fork mpv。

因此当前实施顺序锁定为：**B3 普通 HDR 验收 -> 真实 DV profile 分类 -> 必要时
AVFoundation 原生 DV PoC -> 最后才考虑更重的 mpv/host 改造**。这条顺序同时避免把
OHOS 的成功播放、macOS 的 EDR surface 和原生 DV 直通混成一个结论。

### Profile 8 实际复测后的计划更新

当前已用 `【4K限免】你的新设备能顶住吗？影视飓风年度样片.mp4` 完成一次 B3 实际
播放：输入回读为 `videotoolbox/p010`、`colormatrix=dolbyvision`、BT.2020/PQ，
NativeSurface 为 `active=true`、`rendererReady=true`、`rgba16Float`、headroom 约
2.03，Metal `drawn=true`，测试窗口有可见帧。由此把“DV -> 普通 HDR/EDR 的解码和
渲染链路”从纯待验证改为“已通过一次真实输入的可行性门”。

尚未通过的仍是显示正确性门：没有亮度计和逐帧参考对照，不能判断 RPU 动态映射、
高光绝对亮度或色彩是否正确；也没有证明原生 DV metadata passthrough。因此下一步
不实现 AVFoundation，也不改生产默认，先对该 Profile 8 输入完成同流 SDR 对照、
固定时间点截图/高光检查及生命周期回归。

同时已将 Darwin native-surface 的 `supportedInputFormats` 声明补充为
`dolby-vision-p8`，并通过 macOS 测试宿主构建。该改动只修正能力报告，不改变
PiliPlusX 当前对 Dolby Vision 的 fallback 决策。

为完成同源 SDR 对照，隔离宿主新增 `MEDIA_KIT_AUTO_TEXTURE=true` 诊断模式，显式使用
普通 Texture、`target-trc=bt.1886` 和 `tone-mapping=bt.2390`。首次运行被 AppKit 外部
终止，未取得有效回读或截图；下一次运行必须重新取得 `video-params`、tone-mapping、
首帧和截图后，才能关闭该对照门。

该对照已在自动单播放器模式下重跑成功：同一 Profile 8 输入仍为
`videotoolbox/p010`、`colormatrix=dolbyvision`、BT.2020/PQ，SDR target 为
`bt.709/bt.1886`、`tone-mapping=bt.2390`，Texture 画面可见。故“同源 HDR/EDR 与
SDR 回退均可出帧”已通过；显示观感、绝对亮度和生命周期门仍未关闭。

### 2026-09-07 生命周期复测后的执行调整

上一轮退出已确认是手工关闭，故不纳入失败统计。重新运行同一 DV Profile 8 素材后，
B3 已通过一次完整诊断序列：resize、播放器销毁与 detach、自动重建、重新 attach 和
第二次销毁。第二代实例再次获得 `videotoolbox/p010`、BT.2020/PQ、`active=true`、
`rendererReady=true`、`rgba16Float` 和可见输出。

后续不再重复这个已通过的最小生命周期实验；继续做固定时间点的 HDR/SDR 视觉与高光
相对关系检查，并补暂停、seek、换源、前后台和真实产品页面回归。以上是 macOS B3
证据，OHOS 仍按其软件解码、RGBA-only 和独立设备/模拟器条件单独验收。

### 2026-09-07 固定时间点对照后的计划调整

隔离宿主现在能够用 `MEDIA_KIT_AUTO_START_SECONDS=12` 在有效视频参数到达后立即暂停，
确保 HDR/EDR 与 SDR 截图处于同一素材时间点。实际对照中两种输出均有可见画面；HDR/EDR
保持 `BT.2020 + linear + target-peak=203 + tone-mapping=auto`，SDR 保持
`BT.709 + bt.1886 + bt.2390`。

因此“同源同帧输出可见”子门通过，计划从诊断输出链路转入产品化验收：暂停/恢复、seek、
换源、前后台、HDR→SDR→HDR，以及真实 PiliPlusX 页面。默认路线仍是 macOS B3 的
`DV converted/fallback`；不因这次截图引入 AVFoundation 原生 DV，也不 fork mpv。截图
只形成相对视觉证据，绝对亮度、色彩精度和 RPU 处理仍保持未验收状态。

产品侧 `flutter test test/plugin/pl_player/hdr_test.dart` 已重新执行，34 项全部通过。
因此可以继续沿用当前 fail-closed 状态机和 `DV converted/fallback` 决策；下一步不再修改
HDR 分类/事务逻辑，转做真实 PiliPlusX 页面中的暂停/恢复、seek、换源、前后台和
HDR→SDR→HDR 回归。测试宿主中的固定起点参数仅为诊断工具，不进入生产配置。

真实 PiliPlusX macOS Debug 页面也已初步验证：应用成功构建，首页加载后打开线上普通
视频并显示可见帧；暂停时位置保持 `00:27`，恢复后推进到 `00:34`。由于该素材不是 DV，
这只关闭产品页面普通播放的最小门，不关闭 DV/HDR 页面验收。下一步优先补 seek、换源、
前后台和全屏，再寻找可在产品页面加载的本地/可控 DV 测试入口；在此之前不宣称产品
页面已完成 HDR/DV 验收。

同一线上普通视频随后完成了 seek 和全屏子门：进度条点击使位置从约 `02:00` 跳至
`00:01`，全屏切换后视频区域扩大且仍有可见帧，退出全屏正常。下一步保持范围边界：
先补换源与前后台，再寻找能由产品页面加载的可控 DV/HDR 输入；不得把普通视频控制
回归写成 DV/HDR 验收。

代码审计进一步确认，当前产品没有任意本地视频打开入口：`FilePicker` 不负责视频打开，
`FileSource` 只由已下载 Bilibili 条目构造固定目录和文件名。故不能直接把 Downloads 中的
DV 文件接入产品页；若要关闭“真实产品页面 DV/HDR”这一门，必须先由产品决策是否新增
本地视频入口，或提供已有下载条目的完整路径。未获得该产品范围决策前，继续使用隔离
宿主验证 B3，不修改生产数据流。

普通线上视频的换源子门也已通过：从首页第二条卡片打开后，详情页媒体信息更新为
`08:47 / BV16tbY6PEAV`，播放位置从 `00:00` 推进到 `00:07`。下一步只需补前后台以及
产品页面可控 DV/HDR 源；普通视频换源结果不能替代这两项验收。

应用隐藏/恢复也做了进程级检查：隐藏期间 `PiliPlusX` 仍为 `isRunning=true`，恢复后仍在
同一视频详情页且位置继续推进到 `00:59`。这不是完整后台验收；后续仍需验证系统挂起、
多次前后台、输出资源重建以及 DV/HDR 状态恢复。

后台复测暂不闭门：当前 macOS 环境存在多个同 bundle 的 PiliPlusX/Runner 实例，隐藏/恢复
后无法可靠关联到同一个播放器，position 也缺失。下一步先建立单一 Debug 实例的验收
条件，再做后台暂停/恢复和 NativeSurface 重建；不得使用这次混杂实例的结果宣称成功或
失败。

### 2026-09-07 真实产品页 DV 样本已找到，计划切换

用户提供的 `BV1vY4y1N7TY` 已通过唯一 Debug App 的固定 SOP 实际搜索并打开。目标页元数据、
页面 `HDR` 标签和控制条当前“杜比”画质均与预期一致，视频区域持续出帧；此前“无法把
文字输入搜索框”和“同名应用实例污染”两个操作阻塞已解除。由此不再需要新增本地视频
入口，也不再把 Downloads 文件直接注入产品数据流。

下一轮必须在这个真实产品页上完成以下顺序：

1. 单一 Debug 实例下采集产品自身的当前解码格式/播放日志；
2. 证明实际 codec、pixel format、DV/HDR 输入与页面画质标签不是同一层的误判；
3. 采集 native output、色彩空间、headroom 和可见帧；
4. 再执行暂停/恢复、seek、换源、前后台和 HDR→SDR→HDR 回归。

如果产品页只能得到“页面显示杜比、画面可见”，则结论固定写为“产品页播放层通过，
解码/原生 HDR 输出未确认”，不得用隔离 B3 证据替代产品页证据。固定操作顺序见
`docs/plans/macos-product-dv-test-sop.md`。

### 2026-09-07 DV 输入与输出通道纠偏

产品页最新日志确认：`BV1vY4y1N7TY` 先以 `HEVC + VideoToolbox/P010 + BT.2020 + HLG`
进入 HDR 解码链路，但随后因 `source=dolbyVision` 且 native output proof 不完整，被
决策层选择为 `output=toneMappedSdr, surface=texture`，并设置
`target-prim=bt.709, target-trc=bt.1886, tone-mapping=bt.2390`。

这里的 tone mapping 是把 HDR/DV 的高亮度和宽色域压缩到 SDR 的 BT.709/BT.1886 显示
范围，不是 DV 原生显示，也不是 HDR 输出。它可以作为安全回退，但会牺牲 HDR 高光/色域，
当前用户观察到的“发白”说明这条回退不能直接视为产品完成状态。

路线纠偏如下：

1. **HDR 输入不能因为 DV RPU/profile 字段 unknown 就自动降为 SDR**；已确认的 BT.2020
   + PQ/HLG + P010 输入应单独评估普通 HDR/EDR 输出。
2. **普通 HDR 输出与原生 DV passthrough 分开**：本项目可以先把 DV 转成普通 HDR，仍不宣称
     RPU 原样交给系统或显示器。
3. macOS 先做同一 BV、同一时间点的 `toneMappedSdr` 与普通 HDR/EDR A/B；只有 native
   surface 的 active、可见帧和颜色/高光证据齐全后，才把产品决策切到 HDR 通道。
4. `target-peak` 诊断覆盖仅用于 A/B，不进入默认配置；若普通 HDR 证据成立，再决定是否
     调整 `HdrDecision` 对 DV Profile 8/HLG-compatible 输入的策略。

因此当前正确表述是：**产品已确认 HDR 解码输入，但当前实际输出仍是 SDR tone map；DV
普通 HDR 输出路径尚未接入产品默认决策，原生 DV passthrough 更未确认。**

### 2026-09-07 发白根因与后续门

复核 media-kit 输出选择后发现，Darwin 普通 native surface 的显示条件错误地使用了
`nativeSurfaceCandidate`，而不是已经确认的 `nativeSurfaceActive`。这使得产品在
`toneMappedSdr + texture` 决策下仍可能挂载半浮点 native surface，造成 SDR 参数与输出
载体不匹配，解释了真实产品页的发白观感。

已做最小修正：Darwin 普通 native surface 改为只有 active 才挂载，mpv-owned native
window 和 OHOS candidate 规则保持独立。修正后产品页截图恢复海面纹理/高光细节，macOS
Debug 构建和 34 项 HDR 单测通过。

后续顺序调整为：

1. 在修正后的 Texture SDR fallback 上完成同一 BV 的暂停、seek、换源和前后台回归；
2. 再用独立 Debug 开关验证 DV/HLG-compatible 输入的普通 HDR/EDR native 输出，并要求
   `active=true + rgba16Float + 可见帧 + 同帧观感`；
3. 只有普通 HDR/EDR 通过，才评估是否让 DV Profile 8 进入默认 HDR 决策；
4. 原生 DV metadata passthrough、RPU 动态映射和 AVFoundation 仍是更高一级目标，不因本次
   载体错配修复而自动通过。

修正后的产品回归已补过暂停/恢复：目标 BV 在 `07:56` 暂停后位置保持，恢复后推进到
`07:58`。seek 本轮坐标点击未命中，保持未通过；下一步必须先重新定位实际控制条 hit area
或采用可验证的 seek 控件，再继续换源、前后台回归。

### 2026-09-07 产品策略纠偏：不以 SDR tone-map 代替 HDR 源选择

用户确认的产品策略是：`media-kit` 可以提供 tone mapping 作为底层兼容能力，但
PiliPlusX 的正常画质选择不应在不支持 HDR/EDR 的显示器上请求或打开 HDR/DV 源。
显示器不支持 HDR 时，应在画质请求和 DASH 目标选择阶段排除 Dolby Vision、HDR 和
HDR Vivid，选择可用的最高普通 SDR 画质；不能先打开 HDR 源，再依赖
`toneMappedSdr` 把它压回 SDR。

因此必须区分两个层次：

- `media-kit` / mpv 的 tone mapping：底层可选的输入兼容与诊断能力，不代表产品策略；
- PiliPlusX 画质策略：先判断显示器是否支持 HDR/EDR，再决定是否请求 HDR 源；不支持时
  不产生 HDR 输入，也就不需要为正常产品路径设计 HDR→SDR fallback。

当前代码已有 `hdrDisplaySupportsHdr` 对质量菜单和 DASH 目标的初步门控，但 macOS 的
`displayHdr` 目前表示显示器潜在 EDR 能力，`nativeOutputCapable`/`nativeOutputActive`
则表示应用输出链路能力，二者不能混用。后续应补一条明确的产品门：只有显示器能力和
产品可用的 HDR 输出路径同时满足时，自动/默认选择才允许 HDR 源；否则回退普通 SDR。
保留 `HdrDecision.toneMappedSdr` 仅用于显式诊断、已打开的本地文件或底层安全兜底，
不得把它当作正常画质选择的完成方案。

这也修正了当前 DV 结论：`source=dolbyVision` 加上 `toneMappedSdr` 只能说明底层
播放器已经收到 HDR/DV 输入并选择了 SDR 兼容输出，不能作为 PiliPlusX 产品路径的
目标状态。下一步先验证“无 HDR 显示能力时不会请求/选择 DV/HDR 源”的自动化和真实
页面证据，再继续普通 HDR/EDR 输出验收；原生 DV 仍然是更高一级目标。

### 2026-09-07 seek 控件命中修正

真实产品页的 seek 未生效原因已定位：`view.dart` 中覆盖在视频底部的第二个
`ProgressBar` 只有绘制参数，没有传入 `onDragStart`、`onDragUpdate` 和 `onSeek`。
该控件因此没有启用命中测试，截图中虽然能看到进度线，但点击/拖动不会进入播放器
seek 流程。已补齐与 `BottomControl` 一致的拖动、预览、提交回调；`flutter test
test/plugin/pl_player/hdr_test.dart` 34 项通过，`flutter build macos --debug --no-pub`
通过。

下一步用新构建重新执行真实 BV 页的连续操作：唤出控制条后直接拖动进度线，最后读取
位置变化；只有位置发生非自然播放的跳转才关闭 seek 子门。暂停/恢复已通过，换源、前后台
和 HDR/EDR 输出验收仍按原顺序执行。

复测结果：新构建在真实 BV `BV1vY4y1N7TY` 页面上，连续拖动进度条后位置从约 `16:26`
跳到 `04:53`；该跳转明显不是自然播放推进，seek 子门现已通过。AX 容器显示的百分比
仍可能是旧值，但位置字段已发生目标跳转，因此以位置回读作为本次验收证据。该结果只
证明播放器控制链路，不提升普通 HDR、DV 或 native EDR 验收状态。

### 2026-09-07 HDR 画质请求入口审计

已审计当前 PiliPlusX 的 HDR 画质入口：网络请求的 `qn`、DASH 结果的目标画质、画质菜单
的 `enabled` 状态，以及显示器能力变化后的自动回退，均使用
`plPlayerController.hdrDisplaySupportsHdr` 门控。显示器能力为 false 时不会请求或选择
Dolby Vision/HDR/HDR Vivid；手动画质菜单也会禁用这些条目。`toneMappedSdr` 仍只属于
播放器底层已打开 HDR 输入后的输出决策，不能反向成为画质请求策略。

定向 analyze 只发现既有的 `header_control.dart:807` async-context 提示，与本次 seek 和
HDR 画质门控无关；没有新增错误。后续要把“显示器支持 HDR”和“应用 HDR 输出后端已接通”
作为两个独立证据继续验收，不能仅凭第一层能力选择后就宣称 HDR 播放完成。

当前能力门分层记录如下：

| 事实 | 允许的结论 | 不允许的结论 |
| --- | --- | --- |
| `displayHdr=false` | 不请求/不选择 HDR 或 DV 源，回退普通 SDR | 不应打开 HDR 后再 tone-map |
| `displayHdr=true` | 显示器具备 HDR/EDR 候选能力，可进入输出后端验收 | 不能据此宣称应用已经输出 HDR |
| `nativeOutputCapable=true` | 后端可以尝试建立 HDR 输出 | 不能据此宣称当前帧已经 active |
| `nativeOutputActive=true` 且有可见帧/色彩证据 | 可验收普通 HDR/EDR 输出 | 不能据此宣称原生 DV metadata passthrough |

因此当前 macOS `displayHdr=true`、`nativeOutputCapable=false` 的状态应记录为“显示器有
潜在 EDR，但 PiliPlusX HDR 输出后端尚未接通”，不是“继续使用 SDR tone-map 已完成”。
默认画质策略和底层 `HdrDecision` 的兼容 fallback 继续分开维护。

### 2026-09-07 不 fork mpv 前提下的路线收敛

B2 的 stock mpv macOS `gpu-next + wid` 实验已经证明：真实 Cocoa view 绑定和
`VO: [gpu-next]` 日志不能证明嵌入成功；macOS gpu-next backend 会创建并拥有自己的
`NSWindow`/view，当前 Flutter PlatformView 不能直接接管。按用户明确的不 fork mpv
原则，B2 不再作为当前实现路径，也不继续堆叠 `wid`/token bridge。

当前顺序固定为：

1. 继续使用 A/B3 的 `mpv_render_context` + native-surface/Metal 输出链路，在隔离宿主
   完成普通 PQ/HDR 的 visible-frame、色彩空间、EDR headroom 和同帧观感证据；
2. 只有这些证据齐全，才把 macOS `nativeOutputCapable/Active` 接入产品能力状态，允许
   默认画质选择 HDR/DV 源；
3. 当前不把产品 SDR 回退、普通页面可用性或画质降级作为验收目标；优先直接调通 HDR，
   在 HDR 未通过前不进行产品可用性验收；
4. 如果 A/B3 无法满足 Flutter 内嵌 HDR，再评估 AVFoundation 或窗口级 host；fork mpv
   仍不是默认路线。

### 2026-09-07 直接 HDR 执行结果

用户要求跳过 SDR 画质和普通可用性关注，当前计划切换为“先完成 HDR，再做其它验证”。
已完成一项关键修正：candidate native surface 隐藏挂载、active 前保留 texture、active 后
切换 native surface，以解除 native surface 初始化与 active 状态之间的循环依赖。

当前实测已经看到 macOS `NativeSurface.Ready active=true`、`rgba16Float`、
`extended-linear-bt2020`、`NativeSurfaceView drawn=true` 以及约 `2.03` 的 EDR headroom。
因此 B3 已从“候选但未激活”推进到“native HDR layer active 且有可见帧”。下一步只验证
产品决策状态是否稳定落为 `nativeHdr + native-hdr`，并记录同帧截图/高光证据；不再回到
SDR tone-map 参数调优作为当前主线。

### 2026-09-07 HDR 配置事务重试后通过

复测发现 native layer 首次配置可能早于 drawable/frame-provider 激活，导致产品状态停在
`toneMappedSdr`。已在同一 macOS/iOS HDR 配置事务内加入一次 300ms 重试，并保持
generation/player 校验。真实 `BV1vY4y1N7TY` 新构建回放已出现：
`output=nativeHdr`、`surface=native-hdr`、`sourceProcessing=dolby-vision-converted-to-hdr`、
`nativeOutputActive=true`，同时 native layer 为 `rgba16Float`、`extended-linear-bt2020`，
可见帧已绘制。

B3 当前可标记为 macOS 普通 HDR/EDR 输出已打通；DV 结论限定为 DV 输入转换成普通 HDR，
不是原生 DV metadata passthrough。OHOS 不受本次 macOS 结论影响。

### 2026-09-07 亮度对照纠偏：撤回“macOS HDR 已完成”

用户提供了新的同源体验对照：本地文件
`/Users/wuweiwei1/Downloads/test-clips/蹲守一周，我终于拍到了夕阳下的梦幻场景｜北海道VLOG _ Links  4K HDR.mp4`
在 B 站官方 App、Chrome 网页和独立 mpv 0.41 `vo=gpu-next` 中亮度一致，而
`media_kit_test` 明显偏暗。该证据直接否定“nativeOutputActive=true 就等于 HDR 画质正确”，
因此本计划将 macOS 当前状态改为：**输出链已激活、画面可见，但光度/亮度契约未通过**。

用户进一步固定了参考实现：使用 Homebrew 的 `/opt/homebrew/bin/mpv`，并在该文件约
`00:15` 处观察到亮度差异最明显。后续每组 A/B 必须在同一文件、同一 `00:15` 附近帧、同一
窗口/显示器条件下执行；`/opt/homebrew/bin/mpv` 的实际版本和启动参数必须写入记录，不能
用其它 mpv 二进制或默认配置替代。

当前 `/opt/homebrew/bin/mpv` 已核实为 mpv 0.41.0 + libplacebo 7.360.1；用户的有效配置
包含 `vo=gpu-next`、`hwdec=videotoolbox`、`target-colorspace-hint=yes`、
`target-prim=bt.2020`、`target-trc=pq`、`target-peak=400`、`tone-mapping=bt.2390` 和
`hdr-compute-peak=yes`。这与 media-kit_test native-window 路径强制的
`target-trc=linear`，以及 PiliPlusX 当前可能使用的 `target-peak=auto` 并非同一渲染
配置；因此“brew mpv 更亮”目前是确定的对照事实，但还不能单独证明版本或 Metal blit
哪一层是唯一根因。

本地文件核对结果：SHA-256 为
`7626cac28819ffd1377a712b56c7cc4bbf8677f5db4b39fb0c83f92e58d74443`，视频为 HEVC Main10、
3840×1920、BT.2020、HLG、limited range。后续所有对照必须固定此文件，不能混入此前的
PQ 六区片、其它 BV 或不同下载表示。

architect 独立复核确认的关键混淆：

- `media_kit_test` 默认 `useNativeWindow=true`，强制 `vo=gpu-next`、BT.2020、linear，
  它不是 PiliPlusX 当前 B3 render API 路径；
- 当前 media-kit 测试/产品实际打包的 mpv、编译开关和进程加载路径必须实测确认，不能只看
  pubspec lock；产品历史 `Mpv.framework` 曾为 mpv 0.36.0、`libplacebo/vulkan disabled`，
  而独立 mpv 为 0.41；
- B3 当前的 GL/CVPixelBuffer→Metal blit 没有主动做 PQ/HLG 解码或亮度缩放，
  `rgba16Float`、`extended-linear-bt2020`、EDR headroom 和 `active=true` 都不能证明线性
  数值的参考白正确；
- `target-trc=linear`、`target-peak=auto`、`CAEDRMetadata opticalOutputScale=100`
  之间的单位契约尚未通过同帧数值验证。

#### 新的串行工作计划

1. **P0：冻结对照身份。** 每次运行记录 App、文件 SHA、实际加载的 `Mpv.framework` 路径与
   SHA、mpv 版本/编译开关、实际 `vo`/`hwdec`、输出 owner、窗口模式和时间帧；建立三个
   明确模式：SDR Texture、B3 linear native surface、gpu-next 自有窗口。身份不一致时停止
   亮度归因。
2. **P1：确认输入和解码。** 固定上述 HLG 文件，记录 `ffprobe`、mpv `video-params`、
   P010/VideoToolbox 与 `hwdec=no` 对照；先排除不同表示、硬解差异和错误帧，不改显示层。
3. **P2：确认 mpv 映射数值。** 在同一 libmpv/同一 renderer 下分别比较 gpu-next 和 B3，
   记录 `target-prim`、`target-trc`、`target-peak`、`tone-mapping`，并采样同一帧 producer
   输出；再用固定 PQ 六区和 HLG 控制片做单变量实验。禁止先把 peak=203/400/1000 或 gain
   固化为生产设置。
4. **P3：确认跨 API 数值契约。** 同帧、同 ROI 比较 GL/CVPixelBuffer 与 Metal drawable；
   恒等 blit 应只产生格式/采样误差。随后用绕过 mpv 的已知线性 `0.5/1/2/4` 输入验证
   `CAMetalLayer`、extended-linear BT.2020 和 `CAEDRMetadata` 的参考白/scale 关系。
5. **P4：再决定修改层级。** 若 producer 已被 mpv 映射压暗，优先修 target/版本/映射；若
   producer 正确而 layer 变暗，修 media-kit Darwin 输出契约；若同一 render API 在新版
   stock libmpv 修复且旧版不行，再评估无 fork 升级。未完成 P0–P3 前不切 AVFoundation、
   不 fork mpv、不做后置增益。
6. **最后才做实际显示回归。** 固定窗口、显示器、区域和稳定时间，比较官方/Chrome/mpv/
   media-kit；补暂停、seek、换源、resize、销毁重建和跨屏。`nativeOutputActive` 只能作为
   输出状态字段，不能作为亮度正确字段。

停止条件：如果实际加载库、文件或 renderer 不一致，停止该组实验；如果 producer 已不可逆
压缩，停止后置增益，转向 mpv target/版本证据；只有同一输入和同一目标参数下完成数值、系统
合成和用户可见对照，才允许重新标记 macOS HDR 画质通过。

### 2026-09-07 architect 二次复核：执行顺序修正（覆盖前文未拆分表述）

二次独立复核认为上述方向正确，但在执行前必须修正以下问题。本文节优先于本计划前面较早
的“macOS HDR 已完成”“可直接比较 gpu-next 与 B3”或“先做版本升级”的历史表述；这些历史
内容保留用于记录判断变化，不再作为执行依据。

1. **禁止把 gpu-next 与 B3 当成同一个 renderer。** gpu-next 自有窗口和 B3 render API 是
   两条不同的渲染路径。后续必须拆成三类比较：同一 renderer 的配置比较；同一 B3 host 的
   libmpv 版本比较；不同 renderer 之间只比较最终输出语义，不能据此直接归因。即使升级到
   mpv 0.41，libmpv render API 也不会自动获得 gpu-next 的 renderer；这不构成 fork mpv
   的理由。

2. **先声明 HLG 的数值责任。** 每个实验必须标明 producer 输出是 scene-referred 还是
   display-referred，以及 HLG OETF/OOTF 由谁执行。Apple 的 extended-linear BT.2020 输入
   契约与系统 HLG OOTF 不能和已经完成显示映射的值重复叠加；不能把 HLG metadata 追加到
   已经 display-referred 的 producer 输出上，否则可能发生 double OOTF。PQ、HLG、普通 HDR
   的结果也不能互相推广。

3. **隔离测试元数据。** media_kit_test 某些入口把 transfer 固定为 PQ、mastering peak
   固定为 1000，而 NativeSurfaceView 对 PQ 设置 HDR10 metadata、对 HLG 清除 metadata；
   这组常量不能当作输入文件事实。必须从当前文件和当前 renderer 的实际 video params、
   output color space、pixel format、CA metadata 重新建立一份输出契约。

4. **把显示基线和采样有效性提前到 P0。** 固定显示器 ID、HDR/ICC/BetterDisplay 状态、
   亮度、窗口矩形、背景、headroom，并确认 00:15 是同一个 presentation frame。官方 App、
   Chrome 和 mpv 只能先作为体验参考，不能直接当作像素级真值。现有 sampler 的六区
   `max(rgb)` 不是光度测量，也没有绑定 video PTS；必须绑定 frame/generation/PTS，固定 ROI、
   scale、flip、alpha，并记录线性 luminance，而不是仅记录最大 RGB。

5. **将实验矩阵收敛为最小可判定集合。** 不做无约束全组合，按以下顺序执行：

   - `R`：用户确认的 `/opt/homebrew/bin/mpv` 0.41 + gpu-next + 当前有效配置，作为视觉参考；
   - `W0`：media_kit_test 自有窗口、当前现代/实际加载库和当前配置，复现偏暗；
   - `W1`：保持 W0 的窗口、库和 renderer 不变，只逐项匹配 R 的 target prim/trc、peak、
     tone mapping、peak detection、colorspace hint、output format/metadata，先定位 host
     配置差异；
   - `B0`：media_kit_test 的 B3/native-surface、产品实际旧库和等价输出契约，建立 B3 基线；
   - `P`：PiliPlusX B3 播放同一文件，隔离 controller 参数、时序和产品 overlay；
   - `B1`：仅在 B0 契约仍失败时，在同一 B3 host 上替换现代 stock libmpv 做条件实验。

   SDR Texture 只能作为辅助控制，不能用来诊断 B3 的 linear/Metal blit；W1 变亮也不能
   推导产品应升级库，B0/B1 的结果也不能推导 gpu-next 已进入 B3。若 B1 只有在依赖组合改变
   后通过，只能结论为“新的依赖组合修复”，不能直接归因于 mpv 版本。

6. **重新定义停止条件。** 若某组出现未声明的库、文件、renderer、window owner、frame
   或显示状态差异，只停止该组的归因，不把整项工作判为环境阻塞；先补齐身份记录。若无法
   绑定 producer 与 drawable 的同一帧，则停止数值结论并先修可观测性。没有光度计时只能
   报告相对视觉结果，不能声称绝对 nits；HLG 通过也不能提升为 PQ/DV 通过。现有 300ms
   重试仍是历史生命周期 workaround，不等于画质契约或生命周期已经闭环。

修订后的立即动作是：先完成 `R/W0/W1` 的身份、显示基线和参数逐项匹配，再决定是否进入
`B0/P`。在此之前不修改生产增益、不切 AVFoundation、不 fork mpv，也不因 gpu-next 的
视觉结果直接宣布 B3 可行或不可行。

### 2026-09-07 P0/B0 实测进展：已定位到 producer 映射参数差异

输入文件已复制到测试包 sandbox 容器内以绕过 macOS TCC，字节级校验仍为：

`7626cac28819ffd1377a712b56c7cc4bbf8677f5db4b39fb0c83f92e58d74443`

`W0` 使用 media_kit_test 自有窗口和 app 内实际加载的 Homebrew mpv 0.41/libplacebo/Vulkan，
但当前 `wid + vo=gpu-next + gpu-api=vulkan` bridge 在 macOS 运行时失败：
`vo/gpu-next: Failed initializing any suitable GPU context`。因此 W0 目前只能证明桥接
失败，不能作为亮度结论；不能把该失败归因于 B3。

`B0` 使用同一个现代 mpv 0.41/libplacebo 构建、同一个文件和同一个约 15 秒起始帧，关闭
native-window，走 B3/native-surface。实测得到：

- 解码：`videotoolbox + p010`，`3840x1920`；
- mpv source params：`colormatrix=dolbyvision`、`gamma=pq`、`sigPeak=4.929096`、
  `max-luma≈1000.6`；
- 输出：`vo=libmpv`、`rgba16Float`、`extended-linear-bt2020`、`active=true`，帧已绘制；
- 默认 B3 参数：`target-trc=linear`、`target-peak=auto`、`tone-mapping=auto`；
- 视觉对照仍比 brew mpv 暗，确认问题在输出映射/显示契约，而非文件、解码或 surface 激活。

`R` 的 brew mpv 通过 IPC 读回实际生效值为：`target-trc=pq`、`target-peak=400`、
`tone-mapping=bt.2390`。在 B0 中仅注入 `target-peak=400` 和 `tone-mapping=bt.2390`、
保持 `target-trc=linear` 的控制实验后，15 秒画面的高光明显增强；这证明映射参数是有效
变量，但尚不足以证明该组合就是 B3 的最终契约。下一步必须完成固定窗口/显示器条件下的
最终 A/B，并确认 producer 与 `CAEDRMetadata(opticalOutputScale=100)` 的线性单位一致。

另一个独立事实：当前 PiliPlusX 构建产物仍实际加载 mpv 0.36.0，且编译时
`libplacebo=disabled`、`vulkan=disabled`；不能把 media_kit_test 的现代库实测结果直接
当成产品已具备的能力。产品进入 `P` 前需要先确定可复现的 stock libmpv 供应链或明确旧库
B3 的可行边界。

### 2026-09-07 参数补丁复核：保留为候选，不作为验收结论

生产控制器当前已把 macOS native HDR 的 producer 参数候选设置为
`target-trc=linear`、`target-peak=400`、`tone-mapping=bt.2390`，并已通过
`flutter test test/plugin/pl_player/hdr_test.dart`（34/34）和 macOS debug build。

架构复核发现并已修正一个状态问题：`target-peak` 现在在每次配置中都会显式写入，
macOS native HDR 写 `400`，其它路径写 `auto`，避免同一个 Player 从 HDR 切回 SDR 后
继承旧 peak。该修正仍只适用于 macOS；iOS 没有等价的本地视觉验收，不沿用 macOS
400-nit 假设。

这不等于 HDR/DV 已修复。下一步必须在实际 PiliPlusX（内置 mpv 0.36/B3）完成四组
交叉实验：`auto/auto`、`400/auto`、`auto/bt.2390`、`400/bt.2390`，并记录 mpv
实际回读和同一帧视觉结果；再用同一 B3 宿主隔离 0.36 与现代 libmpv 的版本变量。
在此之前不升级为默认交付结论，也不 fork mpv。

### 2026-09-07 同源产品 A/B：参数生效但 linear EDR 仍偏暗

实际 PiliPlusX 运行时已证明 macOS native HDR 参数确实生效：
`target-trc=linear`、`tone-mapping=bt.2390`、`target-peak=400`，native surface
报告 `rgba16Float`、`extended-linear-bt2020`、`active=true`。但与 brew mpv 同时刻
截图并排后，产品画面仍明显偏暗；因此“参数没有写入”已被排除。

随后对产品在线播放和 media_kit_test 做了参数隔离：

- `target-trc=pq` 虽然平均亮度接近，但 native linear surface 上画面明显发白、对比度和
  色彩错误，不能采用；
- `target-trc=linear` 下分别测试 `target-peak=203/400/1000/100`，没有形成可解释的
  单调映射，不能继续用峰值猜增益；
- media_kit_test 使用同一 SHA-256 文件
  `7626cac28819ffd1377a712b56c7cc4bbf8677f5db4b39fb0c83f92e58d74443`，mpv 回读为
  `dolbyvision/pq/sigPeak=4.929096`，B3 输出为 `rgba16Float + extended-linear-bt2020`
  且 `active=true`；在同一 15 秒帧上仍比 brew mpv 暗；
- 正确传入 `opticalOutputScale=400` 后，截屏亮度没有改善，不能把该 metadata 数值当作
  线性增益修复。临时 optical-scale 环境 hook 已撤回。

当前结论从“producer 参数可能不一致”收敛为：**producer 已匹配可见的 mpv 参数，剩余差异
在 linear producer 输出到 macOS EDR drawable 的颜色/亮度契约，或截图无法表达 EDR 的证据
边界；不能继续用 PQ/linear 切换或 target-peak 猜测解决。** 下一步应在同一 B3 宿主读取
RGBA16Float producer 数值并绑定同一帧，再与 brew mpv 的实际 drawable/显示输出比较；若数值
已一致而屏幕仍暗，优先修 Metal/EDR 输出契约；若数值已偏暗，才回到旧版 `vo_gpu` 的
reference-white/映射实现。生产默认暂不改为 PQ，也不宣称 HDR 已验收。
### 2026-09-07 用户视觉复核：前一轮 A/B 标准不足，结论纠偏

用户在相同显示条件下重新目测确认：`media_kit_test` 的亮度与 brew mpv 基本接近，
而 PiliPlusX 明显偏暗。这一观察推翻了上一节“media_kit_test 也比 brew mpv 暗，因此
差异主要在通用 B3/Metal/EDR 输出契约”的归因；上一节的截图对比只能保留为历史观测，
不能作为同源亮度结论。

前一轮测试标准存在四个问题：

1. `media_kit_test` 实际加载的是 mpv 0.41、libplacebo/Vulkan 构建；PiliPlusX 加载的是
   mpv 0.36、libplacebo/Vulkan disabled、OpenGL 构建。两者不是同一 producer，不能用来
   排除 mpv 版本和后端差异。
2. 部分产品对照使用了在线播放 HLG，而本地文件是 `dolbyvision/pq`；即使画面内容相同，
   transfer 和 source pipeline 也不同，不能作为严格亮度 A/B。
3. 截图不一定保留 macOS EDR/headroom，截图均值、局部亮度和肉眼观感不能互相替代；
   自动统计结果与用户直接观感冲突时，不能继续用统计结果覆盖实际显示验收。
4. “参数已回读”和“屏幕亮度正确”是不同层级的证据；前者只能证明 mpv 属性生效，不能
   证明最终 drawable 与显示器输出正确。

因此测试顺序改为：先固定同一文件、同一时间点和同一窗口条件，比较 PiliPlusX 与
`media_kit_test` 的 producer 版本/后端；随后在同一个 B3 宿主中替换 0.36 与现代 libmpv
做隔离 A/B。只有在同一 producer 仍有差异时，才继续调查 Metal/EDR surface；若现代
libmpv 直接消除 PiliPlusX 的偏暗，优先走不 fork mpv 的 stock modern libmpv 供应链，
不再把参数猜测作为主线。

补充供应链核对：`media-kit/libmpv-darwin-build` 的公开 `v0.7.2` macOS universal
video-default artifact 实际仍是 mpv 0.36.0，且 `libplacebo=disabled`、`vulkan=disabled`、
`gl-cocoa=enabled`。因此单纯把现有 media-kit Darwin artifact 从 0.6.8 升到 v0.7.2
不能获得 brew mpv 0.41 的 producer；若 A/B 证明 modern producer 才能消除偏暗，需要另行
建立可追溯的 stock mpv 0.41 + libplacebo 供应链（可构建/打包，但不 fork mpv），不能把
artifact 版本号升级误当成修复。

### 2026-09-07 同宿主 producer 注入实验：旧版对同一文件产生了不同 source interpretation

将 PiliPlusX 当前打包的 mpv 0.36 及其 FFmpeg/framework 依赖临时注入
media_kit_test 的已构建 B3/native-surface 测试包，未修改 media-kit 源代码，也未改变
测试文件和自动起播位置。临时包实际完成了 native surface 激活，日志包含
`active=true`、`rgba16Float`、`extended-linear-bt2020` 和已绘制帧。

在这个同一宿主中，旧 producer 对测试文件的实际回读为：

```text
videotoolbox + p010
colormatrix=bt.2020-ncl
gamma=hlg
light=hlg
sig-peak=4.926108
```

而此前同一文件由现代 mpv 0.41 producer 回读为：

```text
videotoolbox + p010
colormatrix=dolbyvision
gamma=pq
sig-peak=4.929096
```

这已经证明版本差异不只是 ABI 或编译选项差异：旧 mpv 对同一输入走了不同的源 transfer /
DV 识别路径。因此不能用“两个 App 都报告 native surface active”推导它们的 producer
输出等价，也不能继续把当前亮度差异优先归因到 Metal/EDR。下一步仍需保留同宿主 A/B，
但重点先记录完整 `video-params`、实际 renderer 和同一帧视觉结果；若 modern producer
恢复与 brew mpv 接近的亮度，则升级 stock libmpv/FFmpeg 是首选路线，仍不需要 fork mpv。
### 2026-09-07 modern producer 自包含 arm64 原型：运行与可见 A/B 通过

基于 media_kit_test 当前已验证的 Homebrew mpv 0.41/libplacebo 构建，生成了一个临时
自包含 arm64 App：将 modern mpv 及其 Homebrew 依赖递归复制到
`Contents/Frameworks`，并将依赖改写为 `@rpath`；最终 `otool -L` 未发现残留
`/opt/homebrew` 路径。该临时包未修改 media-kit 或 PiliPlusX 源码，也未替换正式
artifact。

该 App 实际启动并完成播放，日志证明：

```text
video-params: videotoolbox + p010
colormatrix=dolbyvision, gamma=pq, light=display
sig-peak=4.929096, max-luma=1000.606
NativeSurface: active=true, rgba16Float, extended-linear-bt2020
NativeSurfaceView: drawn=true
```

在相同约 15 秒画面上，临时自包含包与 brew mpv 截图的肉眼亮度和高光表现一致；这次
截图仅作为同帧视觉复核，不能替代 EDR 绝对光度测量。结合此前用户对 media_kit_test
现代构建的直接观感，已证明“现代 producer + 当前 B3/native-surface”是可行技术路径。

当前剩余工作从“是否可行”转为“如何交付”：需要得到 arm64/x86_64 都存在、来源和
checksum 可追溯、依赖闭包不指向 Homebrew 的 universal artifact。正式依赖在该门槛
完成前保持旧 artifact，不把临时 arm64 原型当成发布包。

P0 recipe 已固化为
[`scripts/package_macos_modern_mpv_preview.sh`](../../scripts/package_macos_modern_mpv_preview.sh)。
该脚本从旧 mpv 0.36 的 media-kit_test App 开始，替换为 Homebrew mpv 0.41.0，递归复制
其动态依赖并改写为 `@rpath`，然后重新签名和检查依赖闭包。复跑结果：

- 无 `/opt/homebrew` 绝对依赖残留；
- App 可启动并完成固定 15 秒起播；
- `video-params` 为 `dolbyvision/pq/light=display`，`sig-peak=4.929096`、
  `max-luma=1000.606`；
- `NativeSurface active=true`，`rgba16Float`、`extended-linear-bt2020`，并有
  `NativeSurfaceView drawn=true`。

该脚本明确是 arm64 预览 recipe，不是正式 universal 构建脚本：它依赖本机已安装的
Homebrew 二进制，不能替代锁定源码、双架构工具链、许可证清单和真实 Intel 验收。
### 2026-09-07 构建 recipe 纠偏：B3 modern candidate 不等同于 gpu-next/Vulkan 交付

对 mpv 0.41.0 源码的直接核对显示：mpv 0.41 已将 libplacebo 作为必需依赖，但 Vulkan
仍是独立的可选 feature；`videotoolbox-pl` 依赖 Vulkan，而当前 media-kit B3 使用的是
`TextureHW.swift` 创建的 OpenGL render context，并不需要把 B3 改成 Vulkan 或 gpu-next。

因此下一个 B3 modern candidate 的最小构建门槛应改为：

1. mpv 0.41 + 匹配版本 FFmpeg；
2. libplacebo 已启用，并具备 OpenGL backend；
3. macOS `gl-cocoa`、`videotoolbox-gl`、libmpv 和当前 B3 ABI 可用；
4. 先复现同一文件的 `dolbyvision/pq` 与可见亮度；
5. 只有选择 W1/gpu-next 或 `videotoolbox-pl` 路线时，才额外要求 Vulkan/MoltenVK。

旧计划中把“现代 B3”与“Vulkan/MoltenVK/gpu-next 全部启用”绑定，是过强约束；保留为
历史记录，不再作为 B3 modern artifact 的阻塞条件。这样可先在 arm64/x86_64 两个目标
构建相同的 OpenGL/libplacebo producer，降低 universal 依赖树复杂度，同时不改变 W1
实验路线的独立边界。

本轮固定的候选源码输入（下载后 SHA-256，尚未构建 universal artifact）：

```text
mpv v0.41.0       ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
FFmpeg 9.0.1      cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
libplacebo v7.360.1 d05fdf90bea2f629eaa2d115e909fd356388ac639e54f77b87a018a6d76224bd
```

recipe 需要同步完成：更新 `packages.lock.nix`，把 `libplacebo` 纳入 Nix build inputs，
移除 mpv 0.36 的 `-Dlibplacebo=disabled`，将当前 B3 所需的 `gl-cocoa`、
`videotoolbox-gl` 和 OpenGL render API 保留；`vulkan`/`videotoolbox-pl` 只在 W1 或
libplacebo-Vulkan 变体中启用。当前环境无 Nix，不能把下载和 SHA 核对冒充构建通过。

### 2026-09-07 产品 App 注入 smoke test 与测试标准收紧

将同一 arm64 modern preview recipe 注入当前 `build/macos/Build/Products/Debug/PiliPlusX.app`
的隔离副本后，产品进程能够启动；`vmmap` 证明实际加载的是该副本内的
`Mpv.framework`、`libavcodec.63.dylib`、`libavformat.63.dylib`、`libavutil.61.dylib`
和 `libplacebo.360.dylib`，而不是系统或 Homebrew 路径。该 smoke test 只证明产品
能够加载 modern producer，尚未证明产品 UI 已经打开目标视频并完成同一 15 秒画面的
亮度验收，因此不能写成 PiliPlusX HDR 通过。

后续每次 A/B 必须按以下顺序留证：

1. 固定输入文件 SHA-256、显示器、系统 HDR/EDR 状态和 15 秒时间点；
2. 先用 `vmmap`/`otool -L` 证明被测 App 加载的具体 `Mpv.framework`、FFmpeg 和
   libplacebo producer；
3. 在同一 player/generation 回读 `video-params`，至少包含 pixelformat、
   hw-pixelformat、colormatrix、gamma、light、sig-peak、max-luma、target-trc 和
   target-peak；
4. 再确认 NativeSurface active、实际色彩空间/headroom 和 `drawn=true`，最后才比较
   同一帧截图或肉眼亮度；
5. 若截图亮度不同，先按 producer 参数、解码路径和输出色彩契约分层归因，禁止直接
   调 gain、`opticalOutputScale` 或 tone-map 参数“调到看起来一样”。

这次 smoke test 还确认了一个边界：产品内置的正式 artifact 仍是旧 producer；现代
arm64 注入副本只是可复现的诊断/预览工具。要完成目标，仍需构建并验收不依赖 Homebrew
运行时的 macOS modern universal artifact，然后用上述同一套证据重新验证 PiliPlusX。

### 2026-09-07 modern preview 的固定源/固定时间复测

重新构建 `media_kit_test`，用编译期 `MEDIA_KIT_AUTO_SOURCE` 固定用户给出的北海道 HDR
文件、`MEDIA_KIT_AUTO_START_SECONDS=15` 和 `MEDIA_KIT_AUTO_NATIVE_WINDOW=false` 后，
modern preview 运行日志取得：

```text
AUTO_FIXED_START seconds=15.0
AUTO_FIXED_START paused position=0:00:15.000000
videotoolbox + p010
colormatrix=dolbyvision, primaries=bt.2020, gamma=pq, light=display
sigPeak=4.929096221923828
NativeSurface active=true, rendererReady=true, rgba16Float
colorSpace=extended-linear-bt2020
NativeSurfaceView draw=true, pixelFormat=1380411457, size=3840x1920
```

这证明 modern producer 和当前 B3 native surface 在“固定输入、固定时间、实际绘制”层面
可运行；但本次系统级截图探针因同时存在旧的 PiliPlusX/mpv 窗口，曾截到错误前台窗口，
不能用该截图做最终亮度判定。后续必须把窗口 owner/window id 作为截图前置条件，并同时
记录 `AUTO_SOURCE` 与实际加载库，避免再次把不同视频或不同进程混入 A/B。

### 2026-09-07 B3 modern build recipe 的实际 patch 结果

在隔离的 `libmpv-darwin-build` v0.7.2 工作副本中已生成未提交的实验 patch：

- `packages.lock.nix`：mpv `0.36.0 -> 0.41.0`、FFmpeg `6.0 -> 9.0.1`，锁定本轮已
  记录的 SHA-256；
- `mk-pkg-mpv/default.nix`：加入 `pkgs.libplacebo` build input，移除旧版的
  `-Dlibplacebo=disabled`，保留 `gl`/`plain-gl`/`gl-cocoa`/`videotoolbox-gl`，并清理
  mpv 0.41 已删除的旧 Meson option；
- 保持 `-Dvulkan=disabled`，因为这是 B3 OpenGL render-context candidate，不把 W1 的
  gpu-next/Vulkan 依赖混入本路线。

静态 option audit 已确认该 recipe 不再向 mpv 0.41 传递已删除的 `-D` 选项。但本机没有
Nix，故尚未执行真正的双架构构建；实验 patch 只保留在隔离构建副本中，不改变正式
media-kit artifact，也不宣称 universal 构建通过。

本轮进一步完成了窗口级复测：先用 `AUTO_SOURCE=/tmp/pili-hdr-target.mp4` 固定源，
再动态取得 `media_kit_test` 的实际 Window ID 后截图，避免截到 PiliPlusX 或其他 mpv
窗口。modern media-kit 窗口显示的是目标文件 15 秒的 `560mm` 画面，与 brew mpv
窗口显示同一画面；两边的播放器参数和源帧位置一致。截图用于确认“同一窗口、同一源、
同一时间点”，不把窗口缩放和截图编码差异解释成绝对光度计量。

因此当前 A/B 结论可以收紧为：

- 旧 media-kit producer：同一 DV Profile 8 文件走 HLG 参数，产品观感偏暗；
- modern mpv 0.41 producer：走 Dolby Vision/PQ 参数，窗口级画面已与 brew mpv 接近；
- 当前剩余问题是把 modern producer 做成正式 media-kit Darwin 依赖，而不是继续在
  PiliPlusX Dart/Metal 层添加增益或 tone-mapping workaround。

### 2026-09-07 target-peak/tone-mapping 单变量复测

窗口级复测进一步发现：brew mpv 当前有效参数为 `target-peak=400`、
`tone-mapping=bt.2390`，而第一次 modern `media_kit_test` 预览没有显式设置它们。于是
在完全相同的 modern mpv、输入文件、15 秒位置和 native surface 下重新运行，只增加：

```text
target-peak=400
tone-mapping=bt.2390
```

新的日志确认两个属性已写入，且输出仍为 `dolbyvision/pq/light=display`、
`rgba16Float/extended-linear-bt2020`、`draw=true`；窗口截图中的高光表现与 brew mpv
进一步接近。该结果说明 B3 的亮度契约必须同时包含 producer 版本和这两个 mpv 参数，不能
只升级 libmpv 后忽略 target mapping。

PiliPlusX 当前 macOS native HDR 代码已经设置了同样的
`tone-mapping=bt.2390` 与 `target-peak=400`；旧 mpv 因 `libplacebo` disabled 无法完整
消费这组契约。故正式 modern artifact 接入后不需要新增 gain，也不需要再改变现有
Darwin Dart/Metal 参数。

### 2026-09-07 正式构建执行边界

本机核对确认：没有安装 Nix，但隔离构建仓库的 CI 已具备
`DeterminateSystems/nix-installer-action`、Xcode 路径和 artifact 上传流程；flake 同时
声明了 `aarch64-darwin` 与 `x86_64-darwin`。因此下一步可以在远端 CI 上执行双架构构建，
但这需要把当前未提交的实验 patch 提交到一个远端分支并触发工作流。

当前没有自动推送或创建 PR：这会改变远端仓库状态，超出本地诊断授权。正式构建前需取得
用户对“向 `media-kit/libmpv-darwin-build` 创建实验分支并触发 CI”的明确授权；未授权前
保持正式 media-kit artifact 不变，继续使用隔离 arm64 preview 作为运行证据。

只读核对结果：当前 GitHub 身份对上游仓库的 `viewerPermission` 为 `READ`，且账号下
没有现成的 `libmpv-darwin-build` fork。因此实际远端路径应是先创建账号下的 build-repo
fork，再推送实验分支并触发 CI；这两步都属于远端写入，不能由本地继续动作推断授权。

# MK-ROUTING-20261011 App

## Current State
2026-10-17（新候选 1ae8f8fc 三机轮：DV 三机全过；marble AVC 直连被复核门拒＝新阻断）：合并候选=app preferDirect 缺省翻转（显式 copy 意图保留 preferCopy）+库 hwdec-software-fallback=8（连续解码错误阈值，所有权测试 5 项）+ext-id 能力化两切片（HdrDataSpaceExtInfo 新增 validatedPredictionTransfers/setterOnlyTransfers/supportedSurfaceTransfers/yuvWindowArmApi；LYA 自报 {pq} 置信+supportedSurface；LG 自报 setterOnly {pq,pq-itu}+armApi=1；四处 id 判断全部移除：planner 置信度、backend setter-only 五条件、realizer PQ-ITU、yuv_window_arm 准入）。审核：app 切片 V1 PASS（79/79）、库切片1 V1 PASS、库切片2 V2 Critical PASS（LG 行为保持/LYA 不扩权/保守缺省/无 id 特权；931/931+vendor 45/45+analyze 0）。原生位=JAR a1899af2 不变。APK SHA-256 1ae8f8fc…。实机：**LG 4/4 PASS**（AVC=copy+OMX.qcom=API<26 能力边界；DV=baseLayerConvert/nativeHdr/surfacetexture，能力化 arm 走通，config49 accepted，SF format=43 0x7FA30C04 缓冲轮转帧推进实证，截图 overlay 局限照旧）；**LYA DV PASS**（metadataReshape/ext:lya-pq/readback=BT2020_PQ，SF RGBA_1010102 BT2020 SMPTE2084 层）；**marble DV PASS**（nativeDolbyVision/mediacodec_embed/hwdecCurrent=mediacodec/c2.dolby，DisplayPowerController hbmMode off→hdr 原文链+SF BT2020 PQ/HLG 层，diff 0.6426——纠正旧档"marble DV 软解 SDR"误记）。**marble AVC 9/9 轮 FAIL（新阻断，含 720p 回归）**：直连载体懒附着时序（label h264→h264_mediacodec、hwdec-current 'no'→mediacodec、info 空→populate，发生在 review 窗口 0.4-2.4s）被复核门判 endpoint-changed（'no' 为值非空→变更非首发布；附着"同 hwdec 模式"条件不匹配），无 applied、画面冻结；b 快照证明直连已介入（hwdec-current=mediacodec+c2.qti）。该门语义扩展已按 Q1 裁决"以库内 readiness/组件实例身份协议表达"路线派 Specialist 设计（V2 材料随后）。LYA AVC 三样本=copy（设备持久化显式偏好 mediacodec-copy,auto-safe→按设计保留 preferCopy，新缺省未被行使）——**补充轮 lya3：UI 恢复缺省 mediacodec,auto-safe 后 3/3 AVC（720p+4K×2）全部行使 hwdec=mediacodec 直连 PASS**（plan/texture/review success iter=8/OMX.hisi/帧推进 0.71-0.79/零 endpoint-changed/零 ANR-FATAL，证据 /tmp/w5-verify-20261017/lya3-*）：直连载体在干净解码器上可通过现行复核门，AVC→direct 设计端到端成立；marble AVC 为 vendor 特有实例不稳定开放项（既定下一步=固定 4K AVC 流的最小 MediaCodec 客户端对照 mpv 实验；受限单调首附着门扩展方案+V2 材料清单已归档待裁决）。提交：库 81c80ebc、App 6b4b18f65 已推送各自 routing 分支。全部轮零 ANR/FATAL。证据 /tmp/w5-verify-20261017/（marble r1-r4×2+720p+DV、lg-*、lya-*、uicheck/16.png 设置取证）。
2026-10-17（用户样本三机推进 + 用户两项裁决）：①用户样本四任务在 LG 全过（库 b8da287d APK 182a4392/d2b5be9a，含 e9f99ada1 置灰修复；AVC 三样本=h264_mediacodec+mediacodec-copy+OMX.qcom，DV=hevc_mediacodec+surfacetexture，零 ANR/FATAL，证据 /tmp/w5-verify-20261015/lg-final-*）；LYA（3EP7N18C28016072）同 APK 覆盖安装后四样本全 PASS：AVC 三样本 h264_mediacodec+mediacodec-copy+OMX.hisi（diff 0.6950/0.7211/0.6293），BV1vY4y1N7TY=hevc_mediacodec+hwdec=mediacodec 直连+metadataReshape/nativeHdr+path=ext:lya-pq（SF 实证 BufferLayer BT2020 SMPTE2084 Full RGBA_1010102 DEVICE 合成，diff 0.6712），零 ANR/FATAL（证据 bv-lya3-*；r0 深链被华为 HwResolverActivity 分歧框截走属环境阻塞，脚本已加 -n 显式组件；r1 5.2s CDN 截断一次未复现）。②marble 4K 根因定位：c2.qti.avc（copy 4K）与 c2.dolby.hevc（直连 4K）同为 vendor 实例级 `QC2V4l2Codec failed to set format on port:OUT` 首帧失败；720p 同错误但实例重建后收敛（review iter=14 success），4K 在 mpv 默认连续错误阈值 3 内未收敛→软解回退→复核门按"登记后回退即拒"拒绝（4/4 确定）。Specialist 裁决：`hwdec-software-fallback` 计连续解码错误数（成功清零，handle_err），非实例预算；采纳库 backend prepareOutput `_setOwned('hwdec-software-fallback','8')` 单变量候选（所有权测试 5 项新增，video 923/923，V1 复核 PASS，两条非阻断备注已落实）。③**用户裁决（已写入 TASKS.md 长期约束节）**：(a) AVC 走 copy 不符设计、应走 direct，载体路由表对所有编码适用（不限于 HEVC/HDR-DV）；(b) 判断只允许依据设备能力、不允许设备名称（App 层已 grep 证实零设备名逻辑；库内四处 ext-id 判断已本轮能力化清理）；(c) DV 置灰根因修复（e9f99ada1 乐观 hdrDisplaySupportsHdr）已三机实证。LG DV 截图局限=HWC overlay（screencap 截不到），以 logcat+SF 证据验收。
2026-10-16（实机跑通）：库 00943ba3（诊断）→ba637d62（首版 readiness，V2 复审 FAIL：R1 整轮跳过/R2 截断/R3 安全）→46f21a0b（按修改要求重写：identityAfter 前置、双半 config/DV 前置、发布契约白名单=首发布+同配置标签附着、守卫结算超替、诊断三态/相对耗时/轮作用域/转义限长/sink 无副作用/runtimeType 隐私）→0c57dcd9（跨轮附着结算：早期轮登记的未附着基线被合法结算超替）。review+diagnostics 41/41（新增 14：V2 最低清单 T1-T7）、video **909/909**、analyze 0。真机（App 078ea0f4e+库 0c57dcd9 本地树+JAR a1899af2，APK 337ec3ab…）：marble 冷开 0.6851/重入 0.7778（review success iter13/10）、LG 冷开 0.7032/重入 0.8263（review success iter1/5，OMX.qcom 硬解），截图人工核验播放中帧，零 ANR/FATAL。证据 /tmp/w5-verify-20261015/e2e-*。门语义变化已按触发条件提交 V2 复审（进行中）；生产采用以复审 PASS 为准。残余记录：组件名≠实例证明（同名同配置真换实例不可由现属性区分，已按裁决记录接受）；LG 首轮 budget 超时形状（慢 CDN 下 8s 预算）未再复现但未专门修。
2026-10-16（V2 独立审核裁决后 Current State）：本轮三仓成果保留（库 9f3fecf3 夹具 seam 修复+hosted source checks 绿；App 6e14a9b18 八项 pin 统一+source integration 绿；native fdee781 libmpv build-id+dbf3b77 helper 覆盖，**CI run38838143687@dbf3b77 已 SUCCESS**，制品仍 packaged-unreviewed）。V2 审核（agent_5ab599f4）：A/B/D/E 均 PASS-with-notes；C/G 记录过强结论已由 correction 撤回（同根因/非回归/重试命中均未证，四事件拒绝属实）。**裁决：Q1=选 (d) 阶段性保留现有复核门，不批准 (a)(b) 及 Lead 的 (c) 预等待方案（X→Y→Y 反例）；先库内有界诊断取真实 A/B/预算分解证据，若需初始化发布语义应以库内 readiness/组件实例身份协议表达，App 零补丁。Q2=单一完整 CI 构建即可作准入基础（不强制本地双源），但 evidence ZIP 缺契约 manifest.json 布局等要件，ledger 仍不得填写；DEVICE 产出、CORE 登记、独立 V2 背书。Q3=立即并行启动 W1/W2（通用 provider/Surface 协议、无 token 授权、屏障/重建/清理/多 engine），不等 Q1/W4；单写者纪律+DV004 认领取证。Q4=三 PR 均不具备合并/发布条件；先补 W1/W2、Q1 根因、native manifest 准入、最终 APK/设备矩阵，另须分析 general run38744042258 与 App Build 38838300384 的额外失败（macOS bootstrap 等）。**本地 dv001 worktree 构建未完成（native-build.log 停在 shaderc+fcntl Bad file descriptor），其 darwin 适配为本地提交 0df2310 不推送；产物身份若完成只能标 0df2310。复审触发条件：改 Q1 语义、动 owner/lease/bridge 协议、首次填 ledger、合并/发布。
2026-10-16：W5 设备验证完成（可验证范围内）。App 6e14a9b18+库 9f3fecf3+源码管线 JAR a1899af2 的 APK（86047fb9…）在模拟器与两台真机执行安装/冷启/深链/输出创建/零 ANR-FATAL 验证全过；起播被**解码复核门**系统性阻断：LG 两签名（budget exhausted / endpoint changed: video-params/pixelformat）、marble 一签名（endpoint changed: hwdec-current），三台次复现=10-13"间歇 flake"在普通 App 路径实为确定性阻断，证据已归档 /tmp/w5-verify-20261015/。复核门修法属 DV004 用户裁决，本轮不改。模拟器起播观察另受 AVD 环境（DNS/时钟/dumpsys 挂起）阻塞。W4 ELF 根因=NDK r27c lld 默认无 build-id，DV001 fdee781 已修（链接加 -Wl,--build-id=sha1），待 CI 重跑。上段接续会话的 ff/W3/P0 状态仍有效；本条只更新验证与阻断事实。

2026-10-15（本地agent接续会话）：ff 合并远端 5 提交至 `9b55f194`（分层契约 + PQ 载体负例；pubspec 冲突以远端 c7247139 统一组合为准，7a53bc78 单包 pin 作废）。库侧 P0：d5f30c7e 三项 hdr_yuv_presentation_contract_test 失败本地复现并修复——784df146 默认 arm 构造语义变化 × 旧 `_exercise` 夹具未注入/未声明能力；修法为经 `yuvWindowArm:` seam 注入真实管理器 + FakeArmAtoms 替身 + `_issuedPlan` 声明 yuvWindow 通道，断言与生产默认零改动；库提交 `9f3fecf3` 已推送 media-kit routing 并读回；库侧 video 890/890、lab 292/292、managed_output 4、routing 工具 6+17+27 全绿（证据 /tmp/mk-p0-fix-evidence-20261015/）。App 侧 W3：八项 overrides 统一 9f3fecf3，十包 roots/freshness PASS，analyze 0（移除新库下不可达的旧依赖兜底分支），全量 305/305。CI Build failure=native 准入 ledger 空的预期 fail-closed（W4 开放）。上段"未运行测试/analyze、未提交推送"的快进状态由本条取代：本轮已完成提交与推送，stash 恢复副本保留。

2026-10-15：本地分支从 `71d568775` 快进同步 `personal/routing/MK-ROUTING-20261011` 至 `d128d36cf`（11 commits）。恢复工作区时解决 4 个文件冲突：`hdr_output.dart` 保留上游静态 HDR10+/Vivid 标签并附本地旧依赖通配兼容臂；`pubspec.yaml` 保留本地 `media_kit` pin `7a53bc78`，其余依赖采用上游向量；生命周期与路由测试保留上游新增覆盖和本地断言。`route_options.dart` 的本地 Android copy 偏好变更已由上游包含。未运行测试/analyze、未提交推送；stash `codex-preserve-before-pull-20261015` 暂留作恢复副本。

CORE 按用户最新“先合 DEVICE、CI 等其它工作暂停”的指令完成本次源码归并。唯一公共集成分支仍为 `routing/MK-ROUTING-20261011`，公共主 PR 不向正式 base 合并、不发布。原 DEVICE 继续 native 原 PR 的配方修复与实机工作，没有新增 DEVICE 工作线。归并认领与显式处置见 [6128883314](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6128883314)、[6128920010](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6128920010)。

### 本次归并与来源

| 范围 | 来源与处置 |
| --- | --- |
| App PR3 | `9895e7dc040cdc06a33cceba4d4379eba3f596b5` 的9个代码/测试文件原字节归入：DV003 嗅探/缓存/选源、DV005 Session hint/reopen 透传、DV006 Android亮度通道，以及 debug去除`.debug` suffix。状态为 `CODE_INTEGRATED_KNOWN_ISSUES_OPEN`。 |
| 库 PR6 / DV004 | `9a2c5768dd10e71975b7c3e76bb7125460a43e5b` 原始两文件完整归档；保留公共 gather 和既有跨轮拒绝断言，仅归入两项兼容 final-plan 负例。FIRST-complete-only 生产行为与成功夹具未启用，两个用户决定仍开放。 |
| 库 PR5 | `dc41787082752f234fed85db7fb7be3bd855cc45` 归入 Git 来源历史，两脚本精确归档为非执行`.sh.txt`；已有公共matrix/审查文档及三provenance banner保留。两脚本继续排除于可执行配方。 |
| native DV001 | 已建立同名公共 routing ref，指向 `1095a43acb4d0973b8bca59c5da4e300657bdb29`，完整纳入3笔原 DEVICE 提交。原 DEVICE/feature/main 未改、原PR1仍开放。仅源码纳入，没有运行或批准配方。 |

本次归并的公共父提交为库 `ebb00b8a0dedec42a68b84a4ec6e7dffb6c17f02` 与 App `ed0dc2bfc7f51ac3dc14a7f676451db27ecea6a7`；来源、完整文件blob/SHA与每项保留/归档/延后处置在 `Goodwu/media-kit:docs/plans/core-device-integration-20261012.json`。最终发布的准确新HEAD由本提交及中央回读回执绑定。FFmpeg仍为`9aba43cfbee182ade060cdccbe15340a0fbe3e83`。

### 合入后仍开放

- DV003：producer的revision/cid/baseUrl键与selection的spec.key消费断接，in-flight不共享等待；成功HTTP body仍可能无期限等下一chunk、错误take按chunk而非byte；本地videoUrl空值、完整签名URL日志、轨道/sample-entry与BL/RPU/颜色冲突门仍需修复。reopen的initialDoviFacts透传已修并保留。
- DV006：NaN reset、事件线程、应用亮度事件不发送、系统权限/写入结果、cached engine残留Activity handler继续按review5493423824开放。新读[DEVICE回报6128050177](https://github.com/Goodwu/PiliPlusX/pull/3#issuecomment-6128050177)称用户已在LYA手动确认手势数字/实际亮度联动、自动切手动；这项观察不覆盖上述问题。
- DV004：实际decoder identity序列、临时诊断范围与“最终plan履行/捕获真实切换”的语义未决定。保留公共断言，不能把Git ancestry合入写成行为修复。后续DEVICE增量必须对照 disposition 核完整生产文件，不能仅看增量diff。
- **DV001/PR5的配方整改、fresh native、JAR/APK来源、设备HDR与持续性能验收仍为必需、未完成范围。** 读取失败拒绝、双Vulkan独立组合、失败传播、clean staging、精确成员、实际链接/patch/NDK/helper与产物哈希仍待原DEVICE补齐；接受ledger空，批准native输入0。

### 暂停范围与既有证据

本次提交使用`[skip ci]`，CI跟进/新构建/其它代码切片按用户指令暂停；没有查询本阶段的新CI结果，也没有把旧结果借给新合成向量。本机仅做Git三方结构、逐文件来源、保留项与提交回读检查；没有新Flutter/Dart/Kotlin/native执行结果。现有workflow和批准门不变，原有runs不改动。

此前完整受验组合仍严格为App`3884d3e8`+库`4d1d4b7d`，其宿主证据已由ebb/ed0归档，索引`docs/plans/core-lifecycle-bootstrap-host-ci-checkpoint-20261012.json`。旧general38275707106仅保留16:49:33 UTC的最后观察；本阶段不续查或预设其终态。历史a3b577+e269d报告SHA256`156cd314f670a3d958cea70beb3818a4ea3b6dba0d3e9d944e20b8d1858705da`保持原字节。

当前CORE Web快照/等值URI修复、Session订阅修复、精确Flutter pin引导及源码来源门继续保留；已完成query/DASH/F01/R01/config/FFmpeg不重开发。experimental默认false、true主验并回归false；LG YUV8/FULL/range1、精确设备门和owner/ACK/lease保持。普通Session、owner/carrier、完整生命周期、HDR与持续性能继续分层验，10-bit与lease融合继续延期。

### 后续边界

用户已追加授权“确定已合并的情况下，删除相应分支”。逐一回读归并父提交、源文件处置和未前进的来源HEAD后，清理已确认归并的App PR3、库PR5/PR6来源分支；实际删除与ref回读登记中央PR4。全部公共routing保留；native原PR1仍未合到feature base，保留其DEVICE分支供原配方修订。已删除来源分支的App/DV004后继修改由同一DEVICE从公共HEAD出发，先中央认领，原review问题持续跟踪。CI与其它开发维持暂停；DV004两个决策点不在本轮代为裁决。

### 2026-10-13：安卓黑屏专项（ANR 互锁已修复；MKSURF 桥授权缺口已定位，修复方案待裁决）

用户报实机换网络仍黑屏，指令"先把模拟器上的黑屏问题解决了"。模拟器（bluekey-api36-arm64，带 -http-proxy 7890）复现并逐层定位：

**根因一（已修复）：主线程 mpv FFI 互锁 ANR。** Flutter 3.47 在 PlatformView 拓扑下合并线程，Dart root isolate 跑在 Android 主线程（ANR dump 无 1.ui 线程，libapp.so Dart 帧直接坐在 Looper 上）。media-kit release 泵为 NativeCallable 式（wait_event(0)+事件处理+同步 FFI 全在主线程）。ANR 堆栈：主线程 mpv_get_property_string→mp_dispatch_lock 阻塞；vo/worker/demux 线程空闲（用 69d4afff 未 strip libmpv 符号化，注意 ~/src/mpv/_build-arm64-mks 现物已是新构建 fbab13fd，勿再用其符号化旧产物）。起播窗口核心锁被 VO 侧长占、VO 等 main 的 surface 服务 → ABBA 互锁 → ANR → play() 永不执行。debug 模式因走 InitializerIsolate 从不复现。

**已实施修复（~/src/media-kit，未提交，需 V2 审核）：**
1. `mpv_api_isolate.dart` 重写为客户端：MpvApiIsolate.getPropertyString/getPropertyInt64/setPropertyString/setPropertyNodeNone/setPropertyStringListNode/hookContinue 全部转发到泵 isolate 执行（`performMpvApiOp` 共享执行函数）；不再有第二个触碰 mpv 的 isolate（独立 API isolate 方案在 MKS mpv 上仍三环互锁，已实测废弃）。
2. `real.dart` 8 处主线程同步 FFI 改经 MpvApiIsolate：getProperty（config.async 时）、_setPropertyStringDirect（config.async 且非 allowDisposed）、on_load 的 path 读/http-header-fields NODE 数组/playlist-pos INT64/两处 hook_continue、on_unload NODE-none 清理。config.async=false 同步路径与 setPropertyForRelease（disposal 屏障）保留直连。
3. `initializer.dart`：release 也改用 InitializerIsolate（isMainIsolate() 一律），wait_event 统一 50ms 轮询（服务 API 请求）；`initializer_isolate.dart` 主循环监听器新增 API 请求分支。
4. 验证结果：ANR/冻结消除——应用全程响应、无 "isn't responding"、媒体会话/事件/属性回复全部流动（此前 pause=true 后零事件）。

**根因二（已精确定位，修复待裁决）：MKSURF 桥未授权 → hwdec 无输出路径。** mpv 日志实证：`[mpv:vo/gpu-next/surfacetexture] MKSURF: bridge not initialized (verify-only ensure_init; Java side owns init)` → `[mpv:vo/gpu-next] Loading failed` → 会话路由仍选 hwdec=mediacodec（route plan 行为，app 的 VideoControllerConfiguration.hwdec 被会话拓扑所有权覆盖，R2 设计如此）→ MediaCodec 解码器启动但帧无互操作合成路径 → 永久 BUFFERING 黑屏。MKSURF 桥唯一初始化入口=`PlatformVideoView.setLgExperimentOwner`，需要 `configuration.android.lgExperimentOwnerToken`（hdr_lab 回归显式开启 visual278 实验注入随机 token 故能播；PiliPlusX 与 mk-device 工作树均未设置）。app 侧已试 hwdec=null 门（controller.dart hwdec 字段）无效——被会话路由覆盖。

**候选修复（需用户/DV004 裁决，未实施）：**
- 甲：路由层——会话在 MKSURF 桥未授权时选软解路由（DV004 路由语义，明确未决）。
- 乙：mpv fork 层——MKSURF 驱动加载失败时干净回退软解（标准 mpv 行为；涉及冻结中的原生链与 genbump 溯源，须走 build-mks-r1 + V2 门）。
- 丙：app 层——设置 lgExperimentOwnerToken 启用实验拓扑（与"experimental 默认 false"及 single-open 语义冲突，仅诊断适用）。

**Specialist 审核（第四次重试成功）必须改四项已全部落实：** ①回复协议——runner 把 setter 返回码放 error 字段而客户端读 value 并 `as int`，setter 必抛（on_load headers 设置被吞→无 UA/Referer→CDN 拒流，是最后一轮 BUFFERING 的直接原因）；已改为客户端读 (error,value) 二元组、setter 返回码、hookContinue 传播真实返回码并在负值抛错、泵监听器 try/catch 保证 await 必终结。②dispose 后端不匹配（create 去 kDebugMode 但 dispose 未改）→ dispose 改为与 create 同条件 isMainIsolate()。③real.dart 观察者分支（FORMAT_NONE 重读）迁移到 API isolate（config.async 分支保留直连）。④hook_continue 两处加 MpvApiIsolate.isAvailable 条件路由（非主 isolate/NativeCallable 后端回退直连）。DIAG 追踪打印全部移除。已验证：`Set property: http-header-fields=[UA,Referer] -> 1` 首次成功（协议层端到端打通）。Specialist 重要修正：client.c 实证 wait_event 睡眠前释放 ctx->lock，"wait_event(-1) 持锁"表述不成立（独立 API isolate 失败的持锁机制未定，仅保留失败事实）；"Observed decoder changed" 当前语义是阻断（HdrDecoderReviewFailure 拒绝重试），非自动降级循环。其生命周期完整协议（按 handle 后端登记/closing 排空/quiesced ACK/terminate 移出 UI 线程/exit 清理 pending）与 50ms→mpv_wakeup 优化记为后续工作包；回归清单（协议测试/销毁竞态/路由反例/真机 release/跨平台 teardown）留待裁决后执行。

**方案甲实施与端到端验证通过（2026-10-13 用户裁决选甲）：** 实施三层：①路由层（PiliPlusX `route_options.dart` `_importPreference`）——Android 一律映射 `VideoImportPreference.preferCopy`（含 legacy 默认值 'mediacodec'）：直连 surface 导入需 MKSURF 桥 owner 授权，未授权时 mediacodec 导入器无法加载；preferCopy 使规划器选中 `mediacodec-copy`（仍是硬件解码，帧经 CPU 上传合成，不需要该桥），默认与显式 token 都落到可执行的 copy 路径。②解码复核就绪容忍（`hdr_decoder_review.dart` 端点双读一致性）——含空值的不一致（解码器打开中端点填充）与 `video-params/*` 双读抖动 → 重试稳定样本（返回 null 走既有重试环），身份端点双非空不一致仍抛错（证据强度不降）。③`mpv_set_property_async` 回复超时 5s→30s（模拟器/慢 GPU 首次 VO 初始化着色器编译合法超过 5s；该 await 异步不阻塞主线程）。④specialist 4 项必须改全部落实：dispose 后端与 create 同条件、回复协议 (error,value) 二元组（原 setter 必抛 null as int——headers 静默丢失→CDN 拒流的直接原因）、观察者分支迁移、hook_continue 全局路由（isAvailable 条件已移除）。架构定稿（specialist 方向修正后）：**事件泵 isolate 只做 wait_event 排空（release 恢复 -1 阻塞），独立 API isolate 执行全部同步属性/hook FFI**——泵被属性读的 dispatch lock 卡住会导致 mpv 事件队列饱和→core 阻塞在队列满→全停（实测），故泵内禁止长 FFI；两 isolate 并发为 libmpv 文档允许模式。上一轮"独立 API isolate 三环互锁"结论作废：实为 runner 回复端口被 `await first` 取消订阅的 bug（FFI 瞬间完成、回复丢失），specialist 亦实证 wait_event 睡眠前释放 ctx->lock。

**端到端验证（emulator-5554，冷启动+代理）：** `PlaybackState PLAYING(3)`，position 53019ms→61027ms（8s 墙钟 1:1 推进），帧持续变化，视频画面清晰渲染（演唱会视频），零 FATAL/ANR。规划 `import=preferCopy ordered=mediacodec-copy:true,...`。双仓 dart analyze 零问题；PiliPlusX 路由/player 83 项测试与 media_kit 全量宿主测试通过；TEMP-DIAG 已全部移除。改动清单：~/src/media-kit（mpv_api_isolate.dart 新文件、initializer.dart、initializer_isolate.dart、initializer_native_callable.dart、real.dart、hdr_decoder_review.dart，均未提交）+ PiliPlusX（route_options.dart、route_options_test.dart，均未提交）。遗留：specialist 生命周期完整协议（handle 登记/排空/quiesced ACK/terminate 移出 UI 线程）为后续工作包；真机（LYA/marble）回归待装新包执行；50ms→mpv_wakeup 优化可选。

**其它**：宿主 media_kit 测试套件通过（exit 0，多轮）；全部改动 dart analyze 零问题。验证产物：`~/src/media-kit-build/piliplusx-routing-20261013/emulator-smoke/`（各轮截图含 PLAYING 证明 emulator-PLAYING-proof.png）+ /tmp/mpv-diag.log、/tmp/trace.log、/tmp/anr-full.txt、/tmp/dbgd.txt。模拟器当前为冷启动新实例（带 -http-proxy 7890）。specialist 前三次 stream error 失败已如实记录，第四次全新实例成功。

**直连使能方案审核轨迹（2026-10-13 用户指令"启用直连路径，做个方案，并让specialist review"）：** 方案文档 `docs/plans/android-mksurf-direct-import-enable-plan-20261013.md`。第一轮（判"必须修订"，7 项）：三处事实错误——真实 Android Session 在 player_lifecycle_ports.dart:27 创建不接收 configuration（_videoConfiguration 注入不生效）、PlatformViewVideo 挂载条件为 usePlatformView && nativeHandle != null（非 hdrPlatformView）、冷进程普通 SDR 走 Texture 无桥初始化入口（SDR 全量 preferDirect 会重新暴露黑屏）；token 绑定按原生契约（bridge.cpp:175-235 单窗口/同 tuple 幂等/存活期拒绝异 tuple/无窗口可重绑/shutdown 清空）；身份/HdrPlaybackBlocked/超时禁止重试、不得重建 Session 绕过 DV004；convert 载体在桥初始化前后变化需规划协议；默认 true 降级为前置闭合后启用。v2 修订后第二轮判"需第三轮"：A）HdrVideoSession 构造已接受 VideoControllerConfiguration（:82-95），经 configuration.android.lgExperimentOwnerToken 与 HdrOutputContract.controllerConfiguration() 已保留 token——无须新增库构造接口，缺口在 app 会话工厂未传 configuration；B）替换事务须映射全部入口/状态（controller:2401 首开换源、:2444 refresh、:518 setOptions、Session setOptions/setPreference/setPolicy、能力通知链为库自订阅非 app 两个 open 调用可接管；public open() 不接受 HdrSourceFacts；NativePlayer.open 为 backend 内部入口禁止绕过）；C）绑定证明时点消歧——"每次执行尝试中、importer 创建前完成证明"（Session.open 入口前等待会循环依赖：输出在 open 内 prepareOutput→ensure→publish 才创建）；HdrOutputBindTimeout 为禁止重试明示例外（保留，本轮不收紧）。v3 已按 A/B/C 修订：3.1 绑定证明时序契约、3.2 注入通道改既有 configuration 路径、3.3 入口/状态全映射表、3.4 库侧最小接口 L1（绑定状态可观测）/L2（facts-options 迁移）/L3（能力通知接管）、3.5 convert 载体规划期固定+一次有界重规划、3.6 失败分类表（BindTimeout 例外保留）、第 4 节 Phase 1 四步固化+六条最小反例。第三轮复审完成（判"需第四轮"但范围锁定：R1-R4 四项精确补齐即可，明确无需扩大到 DV004/完整 lease）：R1 失败分类定稿（纠正 v3 误述——非 BindTimeout 的 TimeoutException 在 _retry 直接阻断不猜候选，unsupportedStrategy 是未知错误分支非超时路径；新增 MksurfBindFailure 可归因类型，failurePolicy.stop 优先禁止降级，三类失败注入验证）；R2 L1 升级 owner 级证明（证明携带 (ownerKey,generation)+incarnation，importer 创建前经桥 mkst_lc_verify 验证，弃全局 mkst_ensure_init 布尔——其无法区分 A 绑定后 B 重绑；进程级串行准入拒绝异 owner 与迟到回调；shutdown 后由下次执行尝试的 Java ensureInitialized 经串行准入重初始化）；R3 convert 五阶段冷启动时序固定（预备输出→owner 绑定→冻结 carrier/offscreen 契约→必要重建与新 tuple 再绑定→importer 创建；无证明时直连候选不进计划；重规划预算归属跨 Session 逻辑事务，耗尽显式降级或阻断）；R4 L2/L3 升级为移交契约（迁移=源级证据[path/entry/epoch/headers/hint/options/位置/播放状态]，重建=decoder/output 身份证明；事务对象持有 intent/sourceSpec/能力快照/预算；能力通知并入同一串行事务不双跑）。v4 已落实全部四项，第四轮复审完成（判"需第五轮"：R1 失败分类与 R3 convert 时序闭合；三项剩余）：T1 owner 证明接口契约定稿——纠正 v4 事实误述（`mkst_lc_verify` 现状只读 `lc->initialized` 无 tuple/incarnation、匿名命名空间、`mkst_ensure_init` 即调用它；owner 级验证是本轮需新增的桥导出 `mkst_lc_verify_owner(ownerKey,generation,out bindEpoch)`，触及原生链按 provenance 纪律走 build-mks-r1+V2）；T2 准入区间覆盖 ensureInitialized→verify→importer 创建提交或失败清理完成（现有 create gate 只查 initialized/window-active 不校验请求者身份=check-then-use 竞态；两条最低反例：A 验证后 create 前 B init 拒绝串用、同 tuple shutdown→重初始化拒旧证明）；T3 L2 可实施移交协议（库级 handoverFrom 快照接口选型、HdrSourceFacts origins/conflicts 整体迁移、decoder/output 证据清空重取、暂停/位置在事务提交点采样非内部 _openPlay、终止性失败记入事务预算不因替换清零）。v5 已落实，第五轮重试完成（判"需第六轮"：T1 闭合；T2/T3 部分闭合——create 凭据通道、移交顺序与提交条件、epoch 措辞）→ v6 采纳 U1/U2/U3。第六轮首次 stream error 失败，重试完成（判"需第七轮收口"四项：凭据→importer 链路与 ABI 拒绝、意图应用完成点、verify 布尔与 epoch 语义分离、反例四条+文档整理）→ v7 全部收口。第七轮完成（**判"通过进入实施"**：C1 凭据快照冻结链与 C2 意图版本化队列闭合、无新增阻断；遗留仅为 §6 文档整理已清）。实施 5 项关键检查点已写入方案 §6：延迟旧 importer 验旧快照拒绝、三边界意图注入按 (generation,seq) 核对、失败/superseded 不提交、独立复验 ABI 混配/epoch/stop 优先/provenance V2 门、默认 false 真机矩阵后另定开启。**方案 v8 为实施基线**；实施工作量：桥导出扩展（原生链，build-mks-r1+V2）→ L1-L3 契约 → 事务骨架 → direct → 反例与真机矩阵。

### 2026-10-13：用户指令构建 Android 产物（本次构建范围内的暂停解除）

用户在 regression-two-device-20261013 双机回归构建完成后指令：根据该构建成果构建 PiliPlusX Android，不用测试。本次按指令执行单次构建，CI/其它开发暂停边界不变。

- 组合：App `71d568775675716926e60ea0d503bd0fe863e4d6`（routing 分支，工作区仅既有未跟踪 `.zcodeignore`）+ media-kit `5834ce5bdbd0bee3c2f7c130db0c05ed5f01f45f`（同分支；Dart 侧经 pubspec_overrides path 消费，native 侧经 `ORG_GRADLE_PROJECT_mediaKitLocalArm64Jar` 注入）。
- 注入 JAR：`regression-two-device-20261013/apks/media-kit-mks-r1-p5.jar`（SHA256 `9cf43ebc…`；三个场景 JAR 内嵌 `lib/arm64-v8a/libmpv.so` 逐字节一致，均为槽位 `5f8fc04c…`，与上轮基线相同）。gradle 日志确认注入生效（`Using local arm64 libmpv jar SHA-256: 9cf43ebc…`）。
- 产物：`build/app/outputs/flutter-apk/app-release.apk`（27.6MB，`--target-platform android-arm64` + `mediaKitArm64Only=true`；APK 内打包 `libmpv.so` 实测 SHA256 `5f8fc04c…` 与注入槽位一致；v7a/x86_64 仅零星插件小库无 mpv）。归档 `~/src/media-kit-build/piliplusx-routing-20261013/`：APK 副本 `piliplusx-routing-71d5687-release.apk`（SHA256 `a386f5958290ad49c7d72a6d9b18c41b6a3474a8185ddda385d64b35eeaadc71`）、构建日志、hashes.txt。
- 按指令未运行测试/analyze、未提交；构建命令：`JAVA_HOME=openjdk@17 ORG_GRADLE_PROJECT_mediaKitLocalArm64Jar=<p5.jar> ORG_GRADLE_PROJECT_mediaKitArm64Only=true flutter build apk --release --target-platform android-arm64`。
- 追加（同日用户指令"在所有在线adb设备上安装"）：产物已装到全部 5 台在线设备——`3EP7N18C28016072`（LYA）、`dede0cd2`（marble）、`5b79aada`（Mi Note 3）、`LGH870DS42e27764`（LG H870DS）、`a869cea9`（Redmi Note 5A/ugg），`adb install -r` 全部 Success，`com.example.piliplusx` versionName 2.1.2。ugg 安装在该机最后一轮 `regression-round-lg.sh`（ugg5-sdr，07:58:51 退出）结束后执行，未中断回归采集；安装时回归已无运行中进程。
- 追加（同日用户指令"安装并进行测试"→模拟器）：`bluekey-api36-arm64`（API36 google_apis arm64）模拟器安装同一 APK 成功（arm64-v8a）。冒烟结果：冷启动 4.7s 无 FATAL；首页推荐流加载完整。**环境发现：宿主机默认经 `127.0.0.1:7890` 代理出网（`https_proxy` 环境变量），模拟器 NAT 裸 TCP 直连会被网络拦截——应用层全部"连接错误"（ICMP/TCP connect 可通但数据断）；首次启动模拟器未挂代理即复现，`emulator -http-proxy http://127.0.0.1:7890` 重启后 API/feeds/图片全部正常。** 后续模拟器工作一律带该参数启动。播放冒烟：播放页/弹幕章节/API 正常，mpv 建输出、`c2.goldfish.h264.decoder`（1920x1080 BT.709）完成 MediaCodec 配置后静默，控制条停 00:00/00:00——模拟器下媒体分片未缓冲成功（API 域名经代理可达，视频 CDN 分片不达），判定为模拟器+代理环境限制，未定论应用缺陷；真实起播/画面验收按既定纪律以实机（LYA/marble，已装同包）为准。证据：`~/src/media-kit-build/piliplusx-routing-20261013/emulator-smoke/`（launch/hot-tap/proxy-feed/proxy-home/playback 共 6 张截图）。

## History

### 2026-10-12：用户要求优先归并DEVICE之前的Current State（历史快照）

唯一公共集成分支 `routing/MK-ROUTING-20261011`；CORE 唯一公共集成，原 DEVICE 继续 native 构建、实机及原 PR 修订。主 PR 保持 OPEN/DRAFT、未合并、未关闭、未发布。两个隔离 checkout 的实现提交已推送回读；未知原 checkout 修改与 App `.zcodeignore` 未触碰。

### 已完成的实现与当前宿主验证

- Web `setShuffle` 快照写时复制与所有 URI 等值时的同步死循环修复已实现，保留确切条目/index；定向测试现为6项。新general38275707106@4d1d已实际运行；Web定向步骤16:46:55–16:47:22的metadata为success，完整Chrome从16:47:22继续执行。预期6项的实际case日志尚未取得，不能称已读6通过或full完成。
- Android能力通知按存活 listener 集合保留订阅，一个 Session 退出不关闭其他 Session 的通知。新增5项真实 Session/MethodChannel 用例已实际通过，全套777通过、3跳过；native显示器事件、多engine/视图和完整owner/ACK/lease仍另验。最后disable失败的自动重试未实现。
- App使用已有Python读取唯一精确Flutter pin，在SDK安装前直接传版本并在安装后复核；Linux consumer来源包含新helper。Windows实际job已跳过yq、使用3.47.2并完成fresh bootstrap，旧HTTP504引导阻断消除。
- 本机相关Python109通过及独立源码审查保留。旧本机全量509 ran/1fail/5errors/5skip和短/tmp夹具失败均属已归档历史，不能改写；本次完整hosted Python515通过、2跳过另有实际证据。

### 精确组合与实际产物

本轮完整受验组合为 App `3884d3e8f4f38ebd6043c9be5c8dc6cef46e4377`（tree `babf93595feed078058608d6aada5c4dd014ddd5`）+ media-kit `4d1d4b7d23d66e8c7de82c3955238c4a0dd159c2`（tree `34dfc9a45c039e2f1da327f057dc8807f1cf3df3`）。本次台账归档提交不继承该组合的测试标签。

| run / attempt1 | 已核事实 |
| --- | --- |
| App source38275714484 | SUCCESS；5实际ZIP全核，四平台Flutter各268/analyze0，Python515通过+2跳过=517，Chrome DOM1/Web compile及各Dart/资源bundle成功。 |
| App Build38275715109 | FAILURE；7success/6failure/2skip，11实际ZIP全核；其自身5个source子job全部通过，没有借用standalone证据。Android/Pink为空accepted manifest，commands=[]；Linux/Windows/macOS/iOS为SOURCE_PREPARED_NATIVE_BLOCKED。 |
| library source38275707566 | SUCCESS；3实际ZIP全核，video777通过+3跳过（新增5项确实执行）、lab298、analyze0、工具45。 |

16份App ZIP的57步fresh收据、2733源码hash（App lib/test1443+media-kit tracked1290）、261package roots/10本地库包及SDK源码/补丁身份均已独立核验。其中10份source ZIP另核source.txt，6份native诊断由bootstrap与vector收据绑定。App SDK为Flutter3.47.2/Dart3.13.2，库source为3.47.7/3.13.5，分开记录。App诊断ZIP只含kernel/完整Web输出哈希与步骤证据，没有独立归档这些二进制字节。

iOS本轮1920文件、两份批准patch已独立重放；5814条数组commands全部exit0，其中5760=1920×3逐blob读取，其余54条。没有启动native Xcode构建。Windows job114900616789/artifact11758389846已完成fresh准备并抵达native gate；这证明引导修复，不是native批准。

上一轮a73 general38272288190已SUCCESS（23success/1release skip）：Web实际定向4通过、full63通过/27跳过；Linux/Windows各81通过/18跳过，macOS88通过/17跳过。mac有2次Retry、2条OutstandingWork及1条失败标记，按重试后成功保留。8实际ZIP/450内层文件、6上传job日志全核；payload中无source.txt，Android仍为旧发布JAR，不能替代fresh DV001。

query38275707339实际34断言与Android plugin Java编译通过；Darwin38275707332实际9项。OHOS38275707109用独立PR merge3222682893e9659fe44fbaa8977b160aa9bfe99a及另一SDK，HAP未独立下载，不合并为此组合的设备/HDR验收。旧1fcc+a73、a98+0c、13b+5834、a3b+e269报告保留原向量；历史156cd314…报告两仓原字节不变。

### DEVICE 最新复审与必需剩余

AppPR3 `9895e7dc040cdc06a33cceba4d4379eba3f596b5` 的DV006已在[原PR review5493423824](https://github.com/Goodwu/PiliPlusX/pull/3#pullrequestreview-5493423824)回交并逐字回读：正文REQUEST_CHANGES，GitHub状态COMMENTED。新增P1为NaN reset使后续亮度getter范围校验失败；四项P2为线程派发、应用亮度事件未发送、系统权限/写入结果未核及cached engine遗留Activity handlers。原五份DOVI/selection/controller文件与b180相同，key/HTTP body预算/in-flight竞态、本地URL/签名日志、轨道与颜色冲突仍在；9895自身Build38274961135失败，不借旧日志解释它的新run。原DEVICE在原PR继续修，当前公共实现未归入这份回交。

**DV001/PR5完整native、产物和设备归并必需未完，批准native输入仍0。** DV001仍1095a43a，PR5仍dc417870；符号读取失败拒绝、双Vulkan独立覆盖、失败传播/clean staging/精确成员、实际链接/patch/NDK/helper与最终JAR/APK可复核性由原DEVICE补齐，CORE复审。两recipe继续排除，三历史provenance banner保留。

PR6@9a2仍REQUEST_CHANGES；实际decoder identity序列、跨轮guard以及用户对临时诊断范围、最终plan/真实切换验收的两项决定继续开放。普通Session/owner/carrier/完整生命周期、HDR与持续性能继续分层验，不能以宿主测试或旧发布JAR代替。experimental默认false、true主验并测false；LG YUV8/FULL/range1、精确设备门、owner/ACK/lease保持，10-bit/lease融合延期。

### 下一步与证据入口

核当前general38275707106的Web6与完整套件实际日志/产物；保留已执行的4d1d输入。原DEVICE在原PR补DV001/PR5与PR3/PR6修订，CORE续审。下一生产切片须先核认领。

完整证据索引为 `Goodwu/media-kit:docs/plans/core-lifecycle-bootstrap-host-ci-checkpoint-20261012.json`；冻结报告按原字节及SHA归档。中央[实现推送6128112984](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6128112984)、[DV006复审6128220148](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6128220148)及[本轮源码终态6128436938](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6128436938)保留；新的准确HEAD与执行观察继续发布中央PR4。不得把已完成query/DASH/F01/R01/config/FFmpeg/SDK接线按旧planned字段重做。


### 2026-10-12：宿主CI终态归档前的Current State（历史快照）

唯一公共集成分支 `routing/MK-ROUTING-20261011`；CORE 唯一公共集成，现有 DEVICE 保留 native/实机和原 PR 的单写范围。所有主 PR OPEN/DRAFT，未合并、未关闭、未发布。未知原 checkout 修改和 App `.zcodeignore` 未触碰。

### 本阶段已实现，当前提交尚待 hosted 验证

- `CORE-WEB-SHUFFLE-02`：所有 URI 等值时跳过不可能结束的同步 shuffle 循环，保持确切条目/index；恢复时相同 identity 序列保持当前重复条目。新增2项确定性测试，结合前阶段4项后定向共6项。普通混合 URI 的随机方式保留；混合重复 URI 与增删队列映射仍另立未完项。
- `CORE-CAPABILITY-SUBSCRIPTION-01`：Android shared channel 的 enable 按 caller=true 或仍有 listener 计算；一个 Session 销毁不能关闭其他 Session 的显示能力通知。新增5项真实 forTesting Session/MethodChannel 测试，包括存活 Session 实际 re-query、重复注册、迟到 false、延迟 ACK、失败与显式重试。未加计数器/状态缓存，未改 Session/gather、Java、owner/ACK/lease。最后 disable 失败的自动重试不在本切片。
- `CORE-BOOTSTRAP-VERSION-01`：已安装 Python 读取 App pubspec 的唯一精确 Flutter pin，直接传 flutter-version，避免安装 yq；SDK 安装后复用同一解析器严格核 frameworkVersion。拒绝歧义/引号重复键/多行值，保留当前 pubspec 与 platform lists。新 helper 加入 Linux 固定 consumer 来源集合，旧 native 门不变。

认领 [6127642516](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6127642516)、[6127809360](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6127809360)、[6127846798](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6127846798) 已发布回读。三项独立源码审查均通过；本机最终相关 Python **109项通过**（11+31+57+10），diff检查通过。完整本机尝试失败：509 ran / 1 fail / 5 errors / 5 skipped，原因是 macOS 专用操作及缺少真实 Flutter SDK；不能写成本机全量通过。早前短/tmp造成既有260字符夹具失败也保留，最终相关测试在记录的较长临时根通过。本机无 Dart/Flutter/Chrome/Pwsh/ADB，新 Dart 测试尚未运行。

### 已完成的准确 CI 组合

本阶段写入前公共 HEAD 为 App `1fcc367cd98e77a217f8a70a388fcfcdaf92aad4` + media-kit `a73d570b633a949aab6a31e8f68ec03a13643c31`；下表只证明该组合，不能重标给包含本阶段修复的随后提交。

| run / attempt1 | 实际终态与可证明范围 |
| --- | --- |
| App source38272335487 | SUCCESS；5实际ZIP全核，四平台各Flutter268/analyze0，Python504pass+2skip=506，bundle/Chrome DOM1/Web成功。57fresh receipts、2720源码hash、261roots/10库包全核。 |
| App Build38272335840 | FAILURE；7success/6failure/2skip，10实际ZIP全核。Android/Pink空selected manifest、commands=[]；Linux/macOS/iOS为SOURCE_PREPARED_NATIVE_BLOCKED。Windows在yq下载HTTP504后退出，未开始private SDK/source bootstrap，无fresh receipt或artifact。批准native候选0。 |
| library source38272288163 | SUCCESS；3实际ZIP全核，video772pass+3skip、lab298、analyze0、Python tools45。App SDK3.47.2/Dart3.13.2；本库独立source SDK3.47.7/Dart3.13.5，分开记录。 |

旧 general38266780432（head0c6ffeaf，实际merge65531539）现已SUCCESS，23success/1skip；Web61+27skip、Linux/Windows各81+16skip、mac88+15skip。mac日志的字幕失败、两次retry和OutstandingWork保留。8真实ZIP/450内层文件已核，但Android使用v2026.013旧JAR，不能替代fresh DV001。新 general38272288190@a73d的Web定向step metadata已成功，完整suite仍运行；尚未获得终态日志，不能把预期4条写成实际已读4pass，也不覆盖本阶段新增6/5测试。

iOS1918base文件/两批准patch重放和5808receipt commands（5754逐blob读取+54其它）均只属源码证据，未Xcode构建。旧a98+0c、13b+5834、a3b+e269各报告继续保留原向量，历史SHA156cd314f670a3d958cea70beb3818a4ea3b6dba0d3e9d944e20b8d1858705da两仓原字节不变。

### DEVICE 回交与必需剩余范围

DV001仍1095a43acb4d0973b8bca59c5da4e300657bdb29，PR5仍dc41787082752f234fed85db7fb7be3bd855cc45，PR6仍9a2c5768dd10e71975b7c3e76bb7125460a43e5b。**DV001/PR5完整native、产物、设备归并必需未完**：读取失败闭合、双Vulkan独立全组合、失败传播/干净staging/精确成员、真实链接/patch/NDK/helper/JAR/APK均待原DEVICE修与CORE复审。公共matrix及历史审查已部分归入，三个provenance banner保留，两shell recipe继续排除，native接受ledger仍空。

AppPR3 b180旧受审代码仍有producer/consumer key断接、HTTP body期限/in-flight竞态、本地URL空值/签名日志、轨道/颜色冲突，review5492931759正文REQUEST_CHANGES/API COMMENTED。其Build38270385174已FAILURE：各平台实际source/patch/lock/输入门失败，source子job在routing SHA门停止；唯一380B诊断ZIP不是产物。16:05后新AppPR3头9895e7dc040cdc06a33cceba4d4379eba3f596b5只加DV006 Kotlin亮度通道，与上述修复无关；中央6127973022已读，正在原PR增量复审，不继承旧报告的受审SHA或视为批准。

PR6@9a2 review5492587336仍REQUEST_CHANGES；跨轮guard和用户两项DV004诊断/验收语义决定仍未解决，CORE不放宽。普通Session、实际owner/carrier、完整生命周期、HDR与持续性能继续分层验收；experimental默认false、true主验并回归false，LG YUV8/FULL/range1、精确设备门、owner/ACK/lease保持，10-bit/lease融合延期。

### 下一步与证据入口

本阶段commit/push/readback后核准确新向量的Web6项定向/完整suite、video新增5项/完整suite、App引导与完整source结果；保留进行中的a73旧run，不为插队取消或重标。继续原DEVICE新回交复审，不并写native/sniffer/gather。代码和各CI的冻结报告均在 `Goodwu/media-kit:docs/plans/core-lifecycle-bootstrap-checkpoint-20261012.json` 索引；后续真实HEAD与run capture发布中央PR4，旧结果只证明旧组合。

### 2026-10-12：生命周期/引导检查点之前的Current State（历史快照）

唯一公共集成分支 `routing/MK-ROUTING-20261011`；CORE 唯一公共集成，原 DEVICE 继续 native 构建、实机和原 PR 修订。主 PR 保持 OPEN/DRAFT、未合并、未关闭、未发布。原 checkout 未知 dirty/untracked（含 App `.zcodeignore`）未触碰；两个隔离 routing 工作树在开始本切片前均 clean、ahead0/behind0。

### 当前 Web 实现检查点

`CORE-WEB-SHUFFLE-01` 已完成生产改动和独立源码审查，**新代码的 hosted 执行仍待验收**。原认领6126963656，新增 Web CI 写范围 [6127346332](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6127346332) 已发布回读。`real.dart::setShuffle` 在启用和恢复时使用新列表，避免改写已经公开的 state/stream Playlist；不改 equality、distinct、native 或共享 Session。新增两个 Web-only 确定性回归分别检出启用和恢复分支的旧快照改写，验证当前唯一条目/index、成员、两轮 true/false 和重复调用事件数量。恢复分支回归仅验旧快照不可变，不为 shuffle 中增删队列的既有成员策略背书。

原两项 shuffle 测试保留，纠正“增加随机样本即可消除故障”的误导注释。`ci.yml` 只在 Web job 的原完整 Chrome suite 前增加4项 shuffle 定向执行。独立静审确认可提交；修正了 dispose 不发送空 Playlist 的测试误设。`git diff --check` 通过。本地没有 Dart/Flutter/Chrome，未执行新红/绿用例；旧失败38255531407仍只证明原向量，不写成已对候选执行红测。完整静审和源码/blob/hash 见本检查点索引。

另发现两个真实相邻问题，未夹带修复或称完成：所有 URI 等值时现有 while 不会结束；indexOf 按URI比较会丢重复条目身份。需要后续独立认领与确定性验证，不采用扩大随机列表、重试、延时或简单 identical 替代完整条目语义。

### 本检查点之前的最新准确源码验收

本次写入前远端为 App `a98a57f2892592d5b8a25d6533ede4580d412ae5` + media-kit `0c6ffeaf2f509c38f8c76eca42ee255bd69b8cd2`；以下运行只证明该组合，随后 Web/文档提交必须另验。FFmpeg `9aba43cfbee182ade060cdccbe15340a0fbe3e83`；DV001 `1095a43acb4d0973b8bca59c5da4e300657bdb29`；PR5 `dc41787082752f234fed85db7fb7be3bd855cc45`；PR6 `9a2c5768dd10e71975b7c3e76bb7125460a43e5b`；App PR3 `b18086d0d654a5f523296b41bdfb869c588cd3f0`。

| 运行 / attempt1 | 精确输入 | 本轮实际结论 |
| --- | --- | --- |
| App source38266831541 | a98a57f + 0c6ffeaf | SUCCESS；5真实ZIP全部摘要/size匹配；四平台Flutter各268、analyze0，Python504pass+2skip=506，bundle、Chrome DOM1/Web成功。 |
| App Build38266831911 | 同组合，独立jobs/artifacts | FAILURE；7success/6failure/2skip；11真实ZIP全核。Android/Pink native selected manifest空、commands=[]；其他四平台SOURCE_PREPARED_NATIVE_BLOCKED。 |
| library source38266780378 | 0c6ffeaf | SUCCESS；3真实ZIP全核；video772pass/3skip、lab298、两analyze0、Python工具6+12+27通过。 |
| library general38266780432 | run head0c6ffeaf，实际merge65531539 | 取证时仍in_progress；四平台package tests终态与全部artifact内层审计待续，不能称绿。 |

App source/Build的57步fresh receipts、before/after/final向量、261 package roots中的10个库包均匹配。新源码清单为 **2714项**（App lib/test1442 + 库tracked1272）；固定Git树独立重算全部匹配，39个Swift symlink按同树目标解析。iOS1918个base文件和恰好两个批准patch变换已独立重放一致，bundle后停native门，未运行Xcode。App SDK是Flutter3.47.2/Dart3.13.2；库独立source实际使用3.47.7/3.13.5，不混标工具链。kernel/完整Web编译产物字节未归档，只承认日志与digest收据，不声称独立重算这些binary。

历史13b139b+5834ce5b的source38258403604/Build38258404288、a3b577f+e269d966的38255581451及general38255531407保留原向量。历史报告SHA `156cd314f670a3d958cea70beb3818a4ea3b6dba0d3e9d944e20b8d1858705da` 两仓原字节不变。38266821993、38258394875取消结果不计验收。general测试包中的旧发布JAR仍不能替代DV001当前native候选。

### DEVICE 当前回交与仍须完成的归并

App PR3@b180 已由CORE在原PR发布 [review5492931759](https://github.com/Goodwu/PiliPlusX/pull/3#pullrequestreview-5492931759)，正文REQUEST_CHANGES，GitHub状态COMMENTED。确认reopen facts、连接/响应头共享期限、成功累积buffer上限、两backup、旧revision写入拒绝等改善；本机JAR误提交已经撤回，不重复列为当前缺陷。但新revision/cid/baseUrl缓存键未接通仍读spec.key的selection，成功嗅探也不能授权真实126；HTTP成功体停顿仍可无限等待、错误take按chunk计数，in-flight Set不共享等待会使新serial发布空facts。本地source分流前videoUrl!及完整签名URL日志、DOVI轨道绑定/BL/RPU/颜色兼容冲突仍未修。284/analyze0只提供本机日志路径，未获CORE原始证据核验；dd76 hosted在routing SHA门失败、下游skip，07953取消，b180构建取证时运行中。debug包身份变更须与产品集成范围分开说明。

PR6@9a2已移除DIAG并修正AVC/nv12/copy fixture；[review5492587336](https://github.com/Goodwu/media-kit/pull/6#pullrequestreview-5492587336)仍为REQUEST_CHANGES，跨轮guard不可达及“FIRST complete sample”擅自收窄契约未解决。用户关于临时诊断范围和最终plan履行/真实切换验收的两项决定保持未决，CORE不放宽既有断言。旧“126出图”已撤回为120残影；新的DEVICE HEVC/P8.4画面报告不替代当前完整native/JAR/APK/轨道/代次/PTS/持续播放验收，不写成仅剩LG复测。

**DV001与PR5完整native、产物、设备归并必需且未完成。** 无新配方修复或移交；DEVICE仍在原PR单写符号读取失败闭合、双Vulkan独立全组合、失败传播/原子处理、干净staging、精确成员及真实链接/patch/NDK/helper/JAR/APK来源。批准native ledger仍空，失败关闭保持。PR5公共matrix和历史审查已部分归档，27项为synthetic/mocked；三个provenance banner保留；两个shell recipe继续排除。

### 接续与不可混用的验收层级

提交、推送并回读本阶段后，先取新SHA的Web定向/完整suite结果；一般CI中未终态的旧run持续按各自向量取证，过渡进度发PR4，不为轮询频繁改文档。随后按认领推进无需用户决策的独立代码或复审。原DEVICE的App/sniffer/gather/native配方不并写；普通Session、owner/carrier、生命周期、HDR与持续性能均仍必需。query/DASH/unknownDV/F01/R01/FFmpeg/config/SDK/source CI已有实现不按旧planned重做。experimental默认false，true主验证并回归false；LG YUV8/FULL/range1、精确设备门与owner/ACK/lease不变；10-bit/lease融合延期。

规范证据索引：`Goodwu/media-kit:docs/plans/core-web-shuffle-cow-checkpoint-20261012.json`，包含五份逐字节冻结报告：新App source、Build、库source、Web静审、DEVICE b180复审；各自的SHA256/字节数/source blobs和限制均独立记录。


### 2026-10-12：Web COW检查点之前的Current State（历史快照）

唯一公共集成分支 `routing/MK-ROUTING-20261011`；新 CORE 已接手，登记 [6126383144](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6126383144)，范围补充 [6126444208](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6126444208)，复审回交 [6126499419](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6126499419)。CORE 唯一公共集成；现有 DEVICE 继续原 native/实机与 PR3/PR6 修订，不新增 DEVICE 工作线。所有主 PR 保持 OPEN/DRAFT、未合并、未关闭、未发布。

本检查点写入前重新回读：App `13b139b797aa65d853cafb5cb207d17a6e7aceac`；media-kit `5834ce5bdbd0bee3c2f7c130db0c05ed5f01f45f`；FFmpeg `9aba43cfbee182ade060cdccbe15340a0fbe3e83`；DV001 `1095a43acb4d0973b8bca59c5da4e300657bdb29`；PR5 `dc41787082752f234fed85db7fb7be3bd855cc45`；库 PR6 `0fb163c6ec8d54c46698227175b9a21468605246`；App PR3 `15551ede06b0cbec859d61e6d16f8dba2054bba1`（生产增量 `a2478d04`，后一笔仅档案）。这些是受审/受验输入，不是本次随后文档提交的 SHA；新提交不得借用旧 run 改标通过。

已核源码中的 query/DASH/P5/P8.4/unknown DV、CORE-F01、失败感知 SDR 兜底、FFmpeg e8df200c、CORE-R01 资源/decoder/copy/software 契约、有效 auto/prefer/require 和 SDK/source/CI 接线；LG config claim 回归也已修。保留完成记录，不按旧 planned/pending 或“34 info”重做。产品 experimental 默认 false，true 主验证并回归 false；LG YUV8/FULL/range1、精确设备门、owner/ACK/lease 保持，10-bit 与 lease 融合继续延期。

### 已核验的 CI 终态与层级

| run / attempt | 精确源码 | 终态及可证明范围 |
| --- | --- | --- |
| App source [38258403604](https://github.com/Goodwu/PiliPlusX/actions/runs/38258403604) / 1 | App `13b139b7` + media-kit `5834ce5b` | SUCCESS；6 jobs。四平台各 Flutter 268、analyze 0；Python 504 pass + 2 skip = 506；Dart/assets bundle 成功；Chrome DOM 1、Web build 成功。 |
| App Build [38258404288](https://github.com/Goodwu/PiliPlusX/actions/runs/38258404288) / 1 | 同上，但有本 run 独立 jobs/artifacts | FAILURE；7 success / 6 failure / 2 skipped。Android/Pink 在 selection 门因 selected manifest 为空停止，commands=[]；macOS/iOS/Windows x64/Linux x64 为 SOURCE_PREPARED_NATIVE_BLOCKED。批准 native 候选为 0。 |
| media-kit general [38255531407](https://github.com/Goodwu/media-kit/actions/runs/38255531407) / 1 | run head `e269d966`，实际测试 checkout 为 merge `811c7ba6`（main `d7619227` + `e269d966`） | FAILURE；22 success / 1 failure / 1 skipped。Web 60 pass / 1 fail / 27 skip，仅 player-set-shuffle；Linux、Windows 各 81 pass / 16 skip；macOS 88 pass / 15 skip。 |

本轮实际读取 24 个 ZIP（独立 source 5、Build 11、general 8），全部 bytes/size/API digest 匹配。16 份 source/Build bootstrap 均 fresh-source-only、57 步 exit 0、同一向量；独立重算 App lib/test 1442 + media-kit 全 tracked 1263 = 2705 项源码 SHA256 全匹配，261 个 package roots 中 10 个 media-kit 包均在当次 checkout。iOS 1918 个 base 文件已核，恰好两个批准变换经独立 patch 重放匹配；bundle 成功后 native 门停止，未开始 Xcode 构建。归档没有完整 kernel/Web 输出 bytes，不声称独立重算这些编译产物。

general 的八个测试 app artifact 确实存在并已检查内部成员；Android arm64 构建实际下载旧发布 v2026.013 JAR（mpv d24c59905 / FFmpeg b4d2ea4 世代），不能当作 DV001 当前 native 或 App Release 通过。App source `38258394875` 已 CANCELLED，排除。历史 `38255581451` 只证明 App `a3b577f3` + media-kit `e269d966`，原报告 SHA256 `156cd314f670a3d958cea70beb3818a4ea3b6dba0d3e9d944e20b8d1858705da` 保持不变；上一 Build `38255582037` 仍是失败关闭。此前库 source/query/Darwin 成功和 OHOS unsigned HAP 仅保留原向量/原层级历史证据。

### DEVICE 回交及必须保留的剩余范围

DV001 仍 `1095a43a`，PR5 仍 `dc417870`，没有新配方修复回交。review5483753705、comment6110373174 等要求继续开放：符号读取失败必须拒绝、两个 Vulkan 符号单独/已 weak/均无/工具失败/坏 ELF 等完整覆盖、失败传播、原子失败处理、干净 staging、精确三库成员、真实链接输入/patch/NDK/helper 及最终 JAR/APK/member 哈希。DEVICE 在原 PR 单写，CORE 复审；批准输入 ledger 保持空。

PR5 公共 matrix 已集成，27 项仅为 synthetic/mocked 回归；历史文档及 DV003/DV004 审查已部分归档。三个 provenance banner 本分支继续保留。`assemble-jar-arm64.sh` 与 `matrix-device-build.sh` 继续排除，不作为批准 recipe；本次只纠正 inventory 的 65 位 digest 笔误，正确值 `bf54737f08351c71877e2257beb8c6031e7a7aed754b26ceb64ddec0222b498b` 对应 PR5 blob `33abc719` 的 2578 原始字节。**DV001 与 PR5 的完整 native、产物、设备归并都是必需且未完成的范围。**

库 PR6 / DV004 对 `0fb163c6` 的 [review5492283452](https://github.com/Goodwu/media-kit/pull/6#pullrequestreview-5492283452) 结论为 REQUEST_CHANGES：partial 轮在写 identity 前返回，首个完整轮又立即返回，跨轮 guard 实际失效；最终 route/hwdec 比较不能证明真实组件未切换。新 fixture 混用 AVC identity 与 HEVC/MIME、copy 路线与 hardware pixel，仅 gather 返回不构成 Session 验收。用户关于临时诊断范围和“最终 plan 履行／捕获任何真实切换”的两项决定继续未决，不擅自放宽断言。

App PR3 / DV003、DV005 对 `15551ede` 的 [review5492283684](https://github.com/Goodwu/PiliPlusX/pull/3#pullrequestreview-5492283684) 同为 REQUEST_CHANGES。首次/refresh hint 已接线，应改记部分修复；intent.reopen 仍漏 initialDoviFacts。HTTP 总 deadline/流式字节上界、按源身份隔离缓存及竞态、视频轨道绑定/颜色和层冲突仍开放；新 playerInit 无条件 `Uri.parse(videoUrl!)` 在本地分流前可抛空值异常，完整签名 URL 日志需收敛。这些 review 的 GitHub API 状态为 COMMENTED，正文结论为 REQUEST_CHANGES，不冒称正式合并保护状态。

DEVICE [6126388894](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6126388894) 已撤回旧“126 出图”为 120 残影/切换未发生，真实 126 原先在 decoder 创建前被 sourceMetadataUnknown 阻断。新的 DV005 HEVC/P8.4/verified/连续画面及本地测试声称仅按 DEVICE reported、CORE 原始证据待补登记；不能据截图文件名、旧 AVC 序列或只改档案写成仅剩 LG 复测。14:45:42 UTC 补核 PR3 Build38263795883（a2478，attempt1）终态 CANCELLED、Build38263881419（15551，attempt1）FAILURE；两者 source 子作业均在 routing App HEAD 与 DEVICE EXPECTED_APP_SHA 一致性门退出，Flutter/Python/bundle 均未运行。PR6 精确0fb163c6 的 Actions 查询仍0个 run；186/775测试尚无独立 hosted 背书。general macOS 的88通过为最终汇总，日志含字幕重试和 OutstandingWork 失败历史，不能据终态抹去。

最新 DEVICE [6126637477](https://github.com/Goodwu/media-kit/pull/4#issuecomment-6126637477)（14:48:40 UTC）组合终审也为 REQUEST_CHANGES，确认 HTTP/cache/reopen、跨轮契约与 fixture 阻断，并要求移除 DIAG 后新 SHA 复审；其 B4 另报旧 dv003 Flutter/analyze 日志实为223pass5fail/undefined_identifier，需补受审 SHA 的真实成功日志。该 reviewer 报告新 LYA126 HEVC/P8.4 两帧有效；此是已读回交结论，公开评论未提供原始日志/截图字节及完整 native 向量，CORE 独立产物验收仍待。DEVICE 已声明继续原分支按库 PR6→App PR3 修订；本 CORE 不并写。

### 接续范围与证据

本检查点仅更新 TASKS、唯一 conversation 和 JSON 证据/当前台账，未修改生产函数、CI/SDK 或 native recipe。原用户 checkout 的 dirty/untracked（含 App `.zcodeignore`、FFmpeg configure）均未触碰；本 CORE 使用独立干净 routing clone。当前 Linux 环境具 Git/Python/Node 及字节取证工具，没有本地 Flutter/Dart/ADB/native SDK；测试结论来自实际 hosted run，不冒称本机/实机执行。

提交、推送、回读此检查点后，下一候选 `CORE-WEB-SHUFFLE-01` 才登记写范围：Web `real.dart::setShuffle` 与 `player_test.dart` 两个 shuffle 用例/已发 Playlist 快照回归。可变列表原地改写并被 stream distinct 吞事件是源码候选，尚非已证根因；先确定性复现，再评估启用/恢复分支的局部 copy-on-write，验证 Chrome 定向和完整 Web 包。共享 Session/planner/backend/realizer/output slot、App hdr_output/controller、CI/SDK 仍不在本 CORE 代码认领内。

native 之后还须同向量验普通 Session、实际 owner/carrier、生命周期、最新 P5/P8.4 true/false、实体 HDR 和持续性能。各层分别验收，不因宿主、bundle、旧 APK 或部分文档归并而结项。完整证据索引：`Goodwu/media-kit:docs/plans/core-successor-checkpoint-20261012.json`；三份 CI 报告 `core-successor-app-source-ci-20261012.json`、`core-successor-app-build-ci-20261012.json`、`core-successor-general-ci-20261012.json`，以及 native/PR3/PR6/字节来源/source index 均有独立 SHA256。


### 2026-10-12：CORE successor 更新前的 Current State（历史快照，已被顶部取代）

唯一公共集成分支 `routing/MK-ROUTING-20261011`；CORE 是唯一公共代码与审查集成者，DEVICE 仍维护原 DV001 native recipe/build/device acceptance。当前回读 heads：App `a3b577f3794634b497c6f82369bcc98d39d91fa2`（待推送文档 checkpoint），media-kit `5834ce5bdbd0bee3c2f7c130db0c05ed5f01f45f`（文档 checkpoint；源码基线 `e269d9669becb5812663200e7521901e8254c8bd`），FFmpeg `9aba43cf`，DV001 `1095a43acb4d0973b8bca59c5da4e300657bdb29`，PR #5 `dc41787082752f234fed85db7fb7be3bd855cc45`。主 PR 未合并、关闭或发布。

query/DASH/unknown DV/F01/R01、auto/prefer/require 有效配置闭环、FFmpeg e8df200c 和失败感知兜底等完成项保留。旧“34 info”已不是当前问题：App source run 38255581451 四平台 analyze 均无 finding；不得按旧数字重开开发。产品 `experimental` 默认仍为 false；true 主验证，false 回归；LG YUV8/FULL/range1、精确设备门、owner/ACK/lease 不变，10-bit 与 lease 融合不重开。

App run 38255581451 attempt 1 捕获准确向量 App `a3b577f3` + media-kit `e269d966`，终态 SUCCESS。四平台 Flutter 各 268 项通过，analyze 无问题，Dart bundle/source freshness 成功；Python 为 504 pass、2 skip。artifact ZIP/API digest、source.txt、57 步 fresh receipts、前后 source vector、十个 package roots 已核验。证据文件 `docs/plans/core-source-ci-a3b577-e269d-checkpoint-20261012.json` SHA256 `156cd314f670a3d958cea70beb3818a4ea3b6dba0d3e9d944e20b8d1858705da`。App Build run 38255582037 FAILURE/CLOSED BY GATES：Android/Pink 输入获取阶段失败，其余平台为 `SOURCE_PREPARED_NATIVE_BLOCKED`；没有可验收 native/APK 产物，不称 build 通过。

media-kit 当前向量的 source 38255531539、query 38255531454、Darwin 38255531401 成功；OHOS 38255531417 是 unsigned HAP hosted build，不是设备验收。general run 38255531407 在本记录更新时仍运行，须由继任者读终态。

PR #5 已部分归并：公共 matrix 功能在库中，27 项是 synthetic/mocked 回归；至 `644908c` 的 DV003 review 和本次 `dc417870` 的 DV004 critical review 已作为带来源 commit/blob/SHA 的历史审查导入。PR5 merge `66aa28e` 解决三份历史文档冲突时删除了既有 provenance banner；本分支保留 banner，并在 import manifest 记录其删除。新附件 `assemble-jar-arm64.sh` 和 `matrix-device-build.sh` 按当前内容与来源哈希记录但不导入/不执行：前者仍可能把 nm 读取失败当作无导入且只检一个 Vulkan 符号；后者是硬编码重复配方并清理 build intermediates。DV004 review 为 REQUEST_CHANGES，两个诊断/验收语义决定点待用户定向，不据归档启动实现。DV001 和 PR #5 的完整 native/产物/设备归并仍未完成。

DV001 PR #1 仍为 `1095a43acb4d0973b8bca59c5da4e300657bdb29`，无 DEVICE 新修复回交。review5483753705、comment6110373174、6111479264、6111836233、6112842188 中的读取器失败闭合、两个 Vulkan 符号分别覆盖、失败传播、clean staging、精确三库成员与真实链接来源/patch manifest 均未关闭。DEVICE 继续原 PR 单写；CORE 只审，不接管或复制 native recipe。

独立 Critical V2 对 App PR #3 DV003 仍为 REQUEST_CHANGES，不原样归并，也不开第二 DEVICE 线。剩余验收包括 fresh native producer input、真实 APK/ABI/签名来源、普通 Session 与 YUV carrier/owner、最新 P5/P8.4 true/false 与实机 HDR/持续性能。宿主 CI、bundle、native build、设备显示分别报告，不能互相替代。


### 2026-10-12 TASKS 旧状态快照（历史）

## MK-ROUTING-20261011（CORE继任）

- Linux/Windows源码前置四文件第二修正V2 PASS_WITH_PENDING_HOSTED：43contracts/actionlint/20实际caller表达式边界及真实pwsh失败传播通过；native缺受审输入阶段准确失败，不代表Release完成。证据docs/plans/core-linux-windows-source-prelude-20261012.json，旧两轮REQUEST_CHANGES保留。

- 当前已核对源码向量：库751d0cdd + App6c4c1b478。库CI38168100713 video772+3原mac Linux跳过/lab298/两strict0；App38168113931 SUCCESS及Build38168114089内四平台各268/strict0/bundle/finalize，hosted Python实际两次444、parser/kernel7与身份前后稳定。Build整体六Release仍失败；Android/Pink空accepted selector实际preAPI/preGradle拒绝，非native通过。精简证据docs/plans/core-native-ci-checkpoint-20261012.json；原失败/旧向量保留。

- CONFIG实际闭环宿主V2 PASS：库v3作者762/Critical774/strict0、AppR1作者268Flutter/strict0/bundle/channel11与独立90+1通过，20/16冻结hash一致；当前准确源码切片已提交push/readback，最新提交组合CI/native/实机仍待。各轮真实失败不删除，完整记录见Current State与handoff。
- CORE接手中央PR4 comment6110756605；唯一routing/MK-ROUTING-20261011/PR1保持draft。context=`archives/conversations/media-kit-routing-20261011.md`。
- CORE-F01/App报告回归已实现并完成库6e7570fc+App569138fa宿主联合验证：192Flutter、bundle/来源/新鲜度成功，同AppSHA此前244Python保留，严格分析34info未清零。此为历史向量；当前CI03已清零，旧pending/62info/34info不再当前状态。
- iOS私有source variant第二修正Critical PASS_WITH_SCOPE：26variant/31bootstrap+实际三SDK文件补丁语义/原Android重标签拒绝，六source hash一致；只接手已审源码检查点，真实最新iOS bootstrap/pubget/prebuild/hosted/native仍待。原两轮失败及SDK输入r1证据保留，Linux B/PR5未审切片不混入。
- CORE-CI03 App1965ba0e+库bd9b9f85 source run38155973408 SUCCESS：严格分析No issues、211Flutter/1Chrome/263Python、Web/bundle/10包来源与freshness通过，中央6111284247。包名与6315处URI精确迁移，产品/native身份不变。最新App c51fd0973+库12966e7a source38156848733 SUCCESS：211Flutter/1Chrome/268Python、strict/Web/bundle/来源/freshness通过；库source38156773328 video591+3原mac跳过/lab298/strict通过。详见context。
- 最新已核对Appf179+库915：Android/Linux/macOS真实bootstrap成功（各211Flutter/strictclean/bundle/来源），Python本轮各309；source38159246222/Build38159246432因Windows未知SDK修改失败，Build另6Release前置失败。Windows短路径/longpaths/完整拒绝前diff与hash窄修V1 29+19+13/Actionlint通过，待新runner验证；新库R01d8b98已推送独立255/strict通过，旧CI不重标。
- native输入门四新文件critical复审43+2及真实LLVM反例通过：成功诊断/不可读dynsym拒绝、全ZIP CRC。接受账本空，未授权DEVICE/native候选；实际Android/Pink接线另审，设备验收未完成。
- file URI来源核验本机转换已修，13目标+5关联及V1独立13通过，10包/非本地/路径逃逸门保留；真实Windows runner仍待验证。
- 用户明确要求归并DV001与media-kit PR#5：PR5最新5b279611以routing主线为base，DV001最新1095a43；三md初始切片及新增16行已独立复核并分别归库e162/aeaf，DEVICE修原配方，归并后最新完整向量P5/P8.4重测，未归并不能结项。
- Release Python随机路径、OHOS工具链约束及iOS/mac pointer兼容修复已分别审查并提交；真实Release作业验收仍开放。继续CORE-R01、真实选项闭环；DEVICE在原DV001修构建审查并做最新向量实机验收。产品默认experimental=false保留，主验证true及false。


### 2026-10-12 macOS 前置整合前状态快照（历史）

#### Archived Current State（历史快照）

唯一集成分支 routing/MK-ROUTING-20261011。本轮push回读远端 Appa05dfe1bea85e78a7b214b0e4044eab7902a3e06、库38ffb72920550d76c41948daa56aa01b4393681d；FFmpeg9aba43cf、DV0011095a43、PR5 5b279611仍按各自证据归属。root唯一公共集成者，DEVICE继续原native配方/构建/实机职责。所有主PR未合并、关闭或发布；未知dirty和恢复材料保护。

query/DASH/未知DV/F01/FFmpeg e8df200c、R01依赖与资源契约/decoder复核/有限copy软件路线、有效auto/prefer/require及代次/清理债务已实现，禁止按旧planned重做。App34info已清零；产品experimental默认false保持，主验证true另测false；LG FULL/range1/YUV8/精确设备/ownerACKlease保留，不重开10bit/lease融合。

已完成源码验收的历史组合1970+d916：独立source38172589162 SUCCESS，Build38172589627 FAILURE但嵌入源码矩阵API均SUCCESS。独立四平台归档已逐ZIP SHA、source.txt、真实57step/bootstrap、10包当前根、before/after/final源码新鲜度核完；桌面三平台strict No issues/Flutter各268/实际bundle命令成功与kernel摘要。主Android源码日志268 Flutter+Chrome1/strict0。独立Python479总计、477成功、2 iOS真实SDK用例因缺shared Flutter Git source跳过（201.015s）；7真实Dart YAML/parser receipt已核。嵌入Python日志479总计/216.190s，未将独立skip详情套用。6 nativeRelease失败、parity跳过，不称全绿。中央精确归档证据6113706863；旧e31+d916的451与库772+3/lab298分别保留不重标。

Linux/Windows已有A源码前置仍准确SOURCE_PREPARED_NATIVE_BLOCKED，历史e31 Release verify步骤也实际bundle成功（旧错误已更正），不等于native。Android/Pink批准ledger仍空，preAPI/prestaging/Gradle拒绝，不借发布JAR。各平台native、generated产物完整来源、实际设备/HDR/持续性能仍缺验收。

iOS六文件已1970准确提交/回读，第二修正Critical PASS_WITH_SCOPE。独立clean1970+d916/private SDK真实iOS bootstrap/sourceverify/finalize已57step exit0/fresh-source-only；原variant因磁盘不足未启动，旧diskblocked记录保留。空间恢复后原1970+d916真实prepared快照经独立确认合法续接，prepare（含实际offline/enforce pubget）、额外offline/enforce、prebuild、sourceverify、variantlock、finalize全部exit0/finalized，r2 checkpoint 0aacec76已独立回读 PASS_IOS_VARIANT_SOURCE_PREBUILD_ONLY，12实际阶段/1897文件/31pub生成/3build生成/86links/261包清单均核；core-ios-source-r2-evidence-review-20261012.json为95621b42完整独立报告。直接fresh绑定prepare的真实失败r1保留，未手工改status。此通过仅源码前置，不含bundle/Xcode/native/device。新SDK/newcache不能当原Android cache改标签；未运行Xcode/native。

Linux B最终R2九文件V2 PASS_WITH_SCOPE，19实际测试+14独立micro probes；逐requester ORIGIN与全部DSO ABI门恢复，unknown generated明确unbound，fullBundleProvenanceVerified=false/releaseVerified=false。未重跑本轮完整acquire→CMake链，真实producer/编译链接/运行未验，生产ledger仍空。精确文件hash与范围保存在core-linux-native-consumer-final-review-20261012.json；已于库3817b8f3/Appdb6df51e提交并推送，九source committed blobs同V2冻结；不能扩大native批准。

DV001与PR5必须完整归并。历史三MD已归台账；公共matrix归唯一tool入口，重复JAR bundler归原DEVICE canonical，不复制第二配方。PR5四文件第二修正因ENOSPC未完成，PR5公共矩阵四文件最后R4 V2 PASS_WITH_SCOPE，27tests独立通过；92包/37生成正常，SDK真实asset bundler与隐式2.0x/prefix3x变体成员一致，变体新增/删除/内容/mode/link变化可检出，正常Gradle build输出未误冻结，SDK内部链接目标闭包已关。源CLI、源/SDK/资源/七SO/独立artifact批准/每APK来源签名/失败传播公共功能归唯一tool入口。已库38ffb729/Appa05dfe1be准确commit/push/readback，四matrix committed blobs同R4冻结，两个repo源切片clean；原SDK/资源/PUB生成三轮失败与ENOSPC材料保留；未运行新precache/pubget、真实八APK/native或设备。八实际APK/四源truefalse/普通Session/owner实际carrier/可见HDR性能未完成；DV001符号读取失败、两个Vulkan目标、失败传播、clean staging、最终成员/链接补丁来源仍需原DEVICE修复。

用户授权只移除已核旧cache重复文件。固定100小批次经V2与remote PREPARE6116072490持久化后，仅4项实际删除；第5项与前项旧hardlink共inode导致nlink/ctime变化，严格STOP，余96保留。新cache/donors/SDK/App/库全后验相同。实测释放85,913,600bytes，随后系统释放不能归此次清理。原runtime远端log超时失败保留，PARTIAL重试已6116651070双API回读通过；raw checkpoint /tmp/mk-ios-cache-delete-partial-checkpoint.json与恢复材料保留。清理结束，不继续删除。实际角色容量错误已记录并续接原角色，禁止换generic/directlauncher。

新实际CI捕获6d349a06+3817b8f3：Appsource38243549009及库source38243502467已success并独立8artifact实SHA回读：App4平台各268/0skip、Python499=497成功+2原iOS缺共享SDK跳过、WebDOM1；库video772成功+3mac专用Linux跳过/lab298/audit6+12。AppSDK3.47.2与库3.47.7分开。Build三个Release源码前置已独立PASS_HOSTED_RELEASE_SOURCE_PRELUDE_ONLY：57step/bundle/finalfresh真实成功，iOSvariant1909files/31+3gen/86links/261manifests/仅2Dart转换一致；唯一失败均native-input-unavailable，不等Release/native/device通过。两份6d349-checkpoint JSON保全新证据，Build其他矩阵终态待另核。iOS routing workflow三文件已6d349a06提交/push/十二source blobs合并回读同V2；已有50作者contracts及限定独立复审，独立完整重跑ENOSPC未通过。下一步：回读新CI，完成PR5剩余复验/V2及准确stage/commit/push/readback；保留各源码向量，后续HEAD前进重新验收。Linux完整producer→consumer→generated bundle、iOS routing workflow/native、Windows native/其他Release和DEVICE同线程协作继续，不因源码绿或正确拒绝结项。


iOS routing workflow三文件第一修正已V2 PASS_WITH_SCOPE：sourceverify→bootstrapfreshfinalize→variantfinalize顺序恢复，实际helper生命周期/三段bash exit37/actionlint通过；作者50contracts通过，独立50重跑因ENOSPC临时目录失败，不虚称通过。三个source冻结待准确提交，尚无真实hosted/bundle/native验收。PR5两P1窄修23tests曾过，24th canonical修正后完整复测被磁盘门阻断，未review-ready，不混入提交。

PR5原matrix-device-build.sh功能归现tool/matrix-build.sh + routing_matrix.py，原assemble-jar-arm64.sh重复配方仍归DEVICE DV001；此是脚本功能归并，DV001未修复/未回交且八包实机未验，因此整项仍开放。

新适用组合a05dfe1be+38ffb729复验已启动：库source38250657319，Appsource38250698262/Build38250698496（排除同SHA cancelled38250692692），未重标上一6d349+3817结果。



### 2026-10-12 A hosted终态前阶段记录（历史）

唯一集成分支 routing/MK-ROUTING-20261011。已推送库HEAD d91639401862d84c68406aae3b2029400a4cfbd6（仅文档证据提交，已验源码751d0cdd69c26374d452fbf672c5600ce59f2387）；App当前e31aee1b09d6658dadd79a58a19bb1c097a57161（旧已验源码向量6c4c1b4787fe2ce5459ee1d775279192fe432416）；FFmpeg 9aba43cfbee182ade060cdccbe15340a0fbe3e83。DEVICE DV001 1095a43、PR5 5b279611 最近回读未见新修复；中央登记6112985520/构建PR6112842188。主PR未合并、关闭、发布，原checkout未知dirty保留，root唯一公共集成者，DEVICE继续唯一native producer/实机责任。

已实现并集成：query/DASH/unknown DV门、F01源事实、FFmpeg e8df200c、R01输出资源契约/实际decoder复核/有界独立copy软件路线、有效auto/prefer/require从App到Session报告及配置代次/清理债务。CONFIG后续LG专用claim回归已修并V2通过。experimental产品默认false；true主验证、false回归；LG FULL/range1/YUV8、精确设备门和owner/ACK/lease保持，不重开10bit/lease融合。

上一完整联合验收向量为751d+6c4，下列381681证据仍只属该向量。当前e31aee1b0+d9163940 source38169989794已SUCCESS：四平台各268/strict0/bundle/finalize、Python实际451（177.586s）及7parser身份/真实kernel；Build38169989974仍有macOS/Python两source jobs活跃，六Release已失败，暂不声明整轮Build矩阵终态。库source38168100713 SUCCESS：video772、3项原macOS专用Linux跳过、lab298、两包strict0；query38168100554和Darwin38168100584成功。App source38168113931 SUCCESS：四平台各268 Flutter、strict0、bundle/源码绑定/finalize；Python本轮实际444，真实Dart/YAML/kernel 7项与前后identity通过，不借旧362。Build38168114089已completed/failure；其独立Python本轮实际444。34info已清零并由当前严格分析验证。Build内四平台各268/strict0/bundle/finalize均真实成功；完整证据720文件索引已收尾，精简摘要docs/plans/core-native-ci-checkpoint-20261012.json，不以源码通过代替native/设备。

Android/Pink已集成来源/真实YAML/生成物及插件精确清单、双artifact/accepted-ledger、实际localJAR/ABI/sign/parity/finalize门。当前接受账本空；最新两Release实际bootstrap成功后在空selector门失败（artifact11712449501/11712224176，commands=[]，preAPI/preGradle），不能宣称native候选通过。当前独立clean最新源码完整prepare验证进行中：原共享SDK36个tracked修改已正确拒绝且保护；新独立clean SDK d3b14与2524 cache成员hash核对，废弃symlink缓存保存p-rejected，空私有cache真实pubget通过。正式bootstrap及最终finalize exit0/fresh-source-only（receipt SHA256 6b261eff9516a60d1933e617770c3eaae017e2cef9babb4753c5bbba2fc05117）；Android/Pink真实prepare、offline lockedpubget、prebuild与routing lock均通过，分别inputs1888/pubGenerated31/buildGenerated3/pubLinks86，错误参数验证driver旧exit2仍保留。此证据只属于6c4+751，不是native/JAR/APK/device通过。旧receipt不得换vector重标。

DV001与PR5必须完整归并。PR5三历史MD与16行增量已入e162cb3c/aeafc6c3；两个脚本未导入。DV001原审查要求符号读取失败拒绝、两个Vulkan目标分别检查、构建失败传播、干净staging、精确最终成员/补丁及链接来源记录，仍由DEVICE在原PR修；CORE消费者验证不等于producer修复。最新源码P5/P8.4、true/false、普通Session/实际carrier/owner/HDR呈现/持续性能尚缺同向量native与实机验收，旧AVC EOS/模型SDR不重标。

当前工作：linux_windows_source_wiring唯一写App四个workflow/contract文件，接通同一vector/真实bootstrap源码前置，native缺当前输入时准确失败并归档，绝不以此称Release完成；platform_release_design只读设计Linux本地SO/headers/dependency完整消费者及DEVICE原recipe回交接口，随后接续真实producer→consumer→bundle；native_input_worker已完成当前clean Android/Pink完整prepare及finalize，归档收尾；ci_verify已完成当前CI证据核验（19 artifacts及准确ZIP hash）。root拥有TASKS/context/台账/Git。Windows/iOS及其他Release门、DV001/PR5和实机证据仍待，不因单项源码绿灯结项。

Linux/Windows A第二轮已独立Critical PASS_WITH_PENDING_HOSTED并提交推送App e31aee1b09d6658dadd79a58a19bb1c097a57161。43contracts/actionlint/20实际caller-context条件及pwsh失败传播通过；原direct dispatch绕过、提前prepared名称和首修误拒均关闭，原两轮失败证据保留。当前仍只源码前置，native缺接受输入阶段准确失败，hosted新增路径待验；Linux B消费者未审不入已验切片。

完整源码prepare检查点docs/plans/core-source-prepare-checkpoint-20261012.json逐字归档（SHA256 a5d5abf30dd92ce230899a904079b0a6eef511ae09427ce075021116572e8041），仍只证明旧准确6c4+751；没有native或variant postbuild验收。

当前执行范围更新：A第二轮以routing-mode及完整两SHA判定已捕获输入，避免错误按caller event_name区分reusable；已Critical通过并推送e31aee1b0。ios_source_variant独占新增iOS variant/测试、patch.ps1仅SDKOnly隔离条件、bootstrap ios平台及对应测试，不动App原Dart或共享workflow；Linux B消费者独占CMake/独立Linux验证获取工具，接受账本空。PR5 matrix-device-build必要功能正只读定位现tool/matrix-build.sh归并接口，assembly重复打包仍由DEVICE修原DV001，不新增配方。

Linux/Windows A第二轮独立V2 PASS_WITH_PENDING_HOSTED，43contracts/actionlint/20真实条件边界及pwsh拒绝通过，4hash与冻结一致；原两轮失败保留，native尚无受审输入，当前只保存源码前置检查点。iOS及Linux B未审修改不纳本切片。

当前中央范围登记6113083125：pr5_matrix_integration独占库tool/matrix-build.sh/routing_matrix.py/test/README，归并原PR5公共矩阵能力，不改DEVICE bundler；ci_verify只读核Appsource38169989794/Build38169989974实际e31a+d916（source已真实success，Build最后两source jobs仍live，不提前终态）；iOS variant首轮冻结Critical拒绝后由原writer修正平台身份；Linux B实施中、尚未冻结审核。

Hosted A Linux最新实际证据：Build job114560490516 failure，artifact11713952189；真实prepare/verify/finalize各success、bootstrap fresh-source-only、57steps exit0、准确e31a+d916，随后SOURCE_PREPARED_NATIVE_BLOCKED，producerReceipt=null/inputRoot缺/native与device=false，旧production下载全skip。Release前置本身没有bundle步骤，bundle由独立source矩阵验证；先前“Release prepare/bundle/finalize”措辞不能作为该Release bundle证据。Windows还在核验。

iOS首阶段6文件已实现，首轮Critical REQUEST_CHANGES（12variant+31bootstrap及8额外边界）：Android/无platform回执可误finalized，wrongscope可误prepared。原writer第1轮补scope routing-source-bootstrap/platform ios/向量及SDK/cache身份全过程绑定，其他资源/生成/links拒绝门通过；不把合成pubget当真实iOS。证据docs/plans/core-ios-source-variant-review-20261012.json，尚不提交。



### 2026-10-12 最新CI收尾前状态快照（历史）

当前远端集成分支均为 routing/MK-ROUTING-20261011：库751d0cdd69c26374d452fbf672c5600ce59f2387、App6c4c1b4787fe2ce5459ee1d775279192fe432416（已审CONFIG源码切片已提交/push/readback）、FFmpeg9aba43cf；DEVICE DV0011095a43、PR5 5b279611刚重新回读，无新修复回交。主PR仍未合并/关闭/发布。原checkout未知dirty保留。中央最新登记6112841982。

已完成F01/query/DASH/未知DV门/FFmpeg e8df200c，不按旧planned重做。34条分析info已在CI03清零；最新已提交联合源码CI06仅证明Appabc149+库87eb：四平台233Flutter/strict0/bundle/源码freshness，Python实际两次359；Build六Release失败，不能称native验收。库a312窄CI源码685+3既有skip/lab298/strict0、query实际Java31tasks+host34、Darwin9通过；OHOS为实际PR merge unsigned，不是实机。证据原各handoff/summary保留。

CONFIG实际闭环库v3与AppR1原冻结宿主V2 PASS并已集成push/readback，但后续完整lab CI证实LG单次实验配置禁改门回归，该LG窄修四文件已Critical PASS（独立lab298/video775/额外4边界、两strict0/hash同），新源码检查点已push/readback且提交树逐hash与复审同；最新库CI video772+3skip/lab298/strict0已通过，Apphosted矩阵与真实toolsCI收尾，native/实机仍未验。库20文件freeze af984d：作者762/strict0，Critical 762包内+12独立共774/strict0，前两轮三个P1真实修后绿、20hash前后同。App16vector47d60f9...绑定同库v3：作者268Flutter/strict0/bundle/channel11、独立90+1/20kwargs及hash一致，first文件设置竞态已关闭。能力查询/设置/refresh服从最新完整request与源代次，实际require履行复核及cleanup重试保留。requested/effective同配置已接DASH/planner/Session/report；未知legacy诊断、默认experimental=false及unknownDV/F01/owner/budget门保留。最新HEAD-only CI、native/实机仍未验，不把dirty宿主结果重标新SHA。各原失败日志与逐轮freeze/review完整归档见core-config-implementation-review/implementation-handoff JSON。

Android/Pink实际Release候选第二修复轮：第一来源漏项8注入已拒绝，但V2另证真实offline pubget正常ephemeral/plugin误拒与转义YAML build资源绕过且真实bundle包含，仍REQUEST_CHANGES。原native_input_worker单写variant/输入/workflows，新增持久Dart真实YAML工具及直接测试、精确pubgen/link契约；待实际Android/Pink prepare→pubget→prebuild正例与真实资源负例及新freeze复审。reviewer私有SDK/cache授权独占、packageconfig遗留共享roots只在私有metadata按逐包字节hash重绑，原证据保留，共享SDK不改。接受账本空，无approved A/B/新native/APK声明。

DV001与PR5必须完整归并。三历史MD与16行增量已分别入e162/aeaf并核原文/hash/链接；两配方脚本未导入，整体未完成。原DV001符号读取失败/两个目标各自/失败传播/干净staging/精确成员链接补丁manifest等审查仍待DEVICE在原PR修；CORE不另写配方。最新适用源码P5/P8.4、experimental true/false、普通Session/实际carrier/owner/HDR呈现/持续性能仍需同向量构建与实机验证，旧模型/AVC EOS不重标。LG批准FULL/range1/YUV8、精确设备门、owner/ACK/lease保持；不重开10bit/lease融合，产品默认experimental=false。

下一步按已有认领串行冻结、独立V2、准确stage/中文commit/push/readback及最新组合CI；余下Linux/Windows/iOS Release消费者与原DEVICE native协作随后接入，不用发布JAR/SO或旧pin代替当前构建。当前活跃子任务r01d_worker（库修复）、app_config_v2（App critical）、variant_boundary_fix（库独立反例/复核）、native_input_worker（第二来源修复），root唯一集成者。


最新general只读快照：a312 run38164066846已cancelled；旧5c8 run38162912132 GitHub仍in_progress、三test jobs运行且日志不可取，无法证明挂死原因。新docs HEAD作业pending/运行快照不推定终态。证据/tmp/mk-routing-ci-current-snapshot-20261012.json。


第二来源修复实际进展：真实App旧abc149只读解析/生成inventory 1879 tracked/31 pubGenerated/3 buildGenerated/86精确插件links通过；7 YAML语义与kernel编译通过，27 synthetic variant通过。仅工具/清单范围证据，不是新候选完整prepare/native通过。私有101包逐成员hash一致后metadata重绑receipt=/tmp/mk-routing-r2-private-sdk-rebinding.json；inventory=/tmp/mk-routing-r2-real-pubgen-inventory.json。资源真实bundle和错链/生成hash负例仍进行。


App第一修复最新10个真实variants通过，覆盖firstfile/真实FileSource/no-page/latest设置/公开新sourceB优先/dispose/三个真实清理债务；observer仅testing生产factory不传。现对库v3冻结组合fresh全Flutter/strict/bundle，未终审/提交。来源第二修复35variants与30workflowcontract/actionlint通过，普通tracked资源真实bundle exit0且字节匹配、escapedbuild资源在构建前拒绝；全Python与真实Android/Pink诊断收尾，完整新candidate prepare仍待CONFIG真实提交。


2026-10-12集成切片：仅各冻结CONFIG源码/tests（库20、App16）+TASKS/context/本阶段handoff；Android/Pink native16文件仍dirty等待第二来源修复Critical V2及最新clean完整prepare，不混入CONFIG提交。


实际新CI capture已确认source38166934942与Build38166935298 attempt1均Appb7d3a8efa+libb5c50670；本轮Python实际两次362通过（31.293/34.451s），其余矩阵仍live/queued不推定通过。Darwin38166919514九项成功；source/query/OHOS仍live、generalpendingnojobs。

独立来源复审在最新b7d3gitarchive实际offlinepubget/清单正向通过（1881tracked/31pubGenerated/86插件）；仅清单，不完整prepare。hostedPythonjob缺真实SDK是确定新增CI阻断，交Lead/只读Specialist做窄provision方案，native16冻结未commit。


最新CONFIG源码CI真实阻断：库source38166919509 video759通过+3既有skip/strict0，但lab267通过2失败：fake Session.open缺options override编译失败；LGsingle-open wrapper失败后setPreference应拒却返回（专用token pre-mutation guard被CONFIG遗漏）。独立b5c隔离17pass2fail已复现，lab_config_regression唯一writer获窄增Session三个setter禁改门与claim先消费后解析（扩展需红例）及直接tests，普通无tokenCONFIG事务不封锁；需新Critical复审/新提交CI。App已实际Linux两job268/strict0/bundle/finalize、BuildAndroid268+Web成功，其余Windows/macOS仍live不推定通过。OHOS新HAP为PRmerge9e5577d5非纯b5c。

第二来源修复Critical 140及最新b7d3清单/所有YAML资源/插件反例PASS_WITH_SCOPE，整体REQUEST_CHANGES仅CIprovisioning；新native_ci_sdk_wiring唯一三文件（workflow/parser test/contract）按Specialist方案保留macOS fullsuite、双exactcheckout+现bootstrap、真实receipt前后identity/finalize/失败归档，不skip或新SDK配方。native其他13冻结文件不动，当前未提交。


最新待集成切片已通过独立审核：库LGguard四文件+记录（readonlytoken专用setter pre-mutation、失败claim在解析前消费、fakeoverride同步；无token普通Session不封锁）V2 PASS；App native16来源scopePASS+3CI窄修V2 PASS_WITH_PENDING_HOSTED，444Python/36contract/7Dart与identity/actionlint通过，接受账本空、不批准native。源码切片逐hash核对后唯一root提交/push/readback，最新hosted/完整prepare仍待。


最新实际组合CI capture source38168113931/Build38168114089 attempt1均App6c4c+lib751d。库source38168100713已SUCCESS（video772+3skip/lab298/两strict0）。Android/Pink真实Releasebootstrap成功后在accepted acquire阶段拒空manifest：artifact11712449501/11712224176、reason missing-accepted-native-input、commands=[]，preAPI/preGradle，不是旧cache/pin，不代表native成功。MAC Python job实际bootstrap中，不能提前叫444通过。

已复读DEVICE DV0011095/PR5 5b279 HEAD+最新评论，无新修复回交；中央6112841982及构建PR6112842188同步当前实际源码检查点/消费者合同，请DEVICE继续原recipe回交当前stage/精确阻塞，不新增DEVICE任务或配方。最新完整clean Android/Pink sourcevariant prepare验证另进行，真实bootstrap新receipt必须由最新源码与干净sourceSDK在独立环境生成；r3旧patchedSDK/receipt不得改vector冒充，private工具pubget允许按正式现流程执行，共享.runtime只读。



### 2026-10-12 CONFIG独立反例前状态快照（历史，已由Current State替换）

当前已推送库a31269badbf8ecc9ec286a1b0c4bf4f6639708ef（R01e与两CI检查点；CONFIG仍dirty） + Appabc149dcf7e89cf0ea1f08ba133bf1047c36138d；FFmpeg9aba43cf；DEVICE DV001仍1095a43。最新两个CONFIG提交仅事实模型/纯adapter检查点，V1独立35库+22App+4额外反例/target strict通过，一行public export；requested/override/effective与来源/序列化、explicit reset、默认experimental=false与legacy诊断保留。模型未接实际DASH/planner/Session/report，不能标auto/prefer/require闭环，未知hwdec诊断必须由caller处理。库handoff=docs/plans/core-config-model-handoff-20261012.json。

最新完整已验向量只为App08acc+库8b98：source38160661703 attempt1四平台真实bootstrap SUCCESS，各211Flutter/strict零问题/bundle/finalize/10routing+261roots+102toolsroots/2662源码hash/前后freshness；Python359/Chrome1/Webrelease成功。Build38160661882源码矩阵全成功，整体因6Release前置失败。库source628video+3既有mac Linux跳过、lab298及两strict/query/Darwin9/OHOSunsigned通过。Windows原SDK状态干净已真实解阻；旧PNG唯一因果未证明，旧b197取消partial不重标。general旧8b98四平台test仍live/log API404，不猜阻塞/通过。CI05证据/tmp/mk-routing-ci05-20261012/summary.json。

CONFIG组合CI06终态：Appabc149+库87eb，source38161696564 attempt1四平台SUCCESS，各233Flutter/strict0/bundle/finalize，8份source及Buildsource receipt的2667源码hash、10routing/261allroots/102toolsroots无逃逸、originalSDK状态空、准确tree498a895e/c4320051及freshness一致。Python实际两次359，Chrome1/Webrelease成功。Build38161696805源码矩阵全成功、整体因六Release失败；库663video+3既有跳过/lab298/strict及query/Darwin9/OHOSunsigned通过。general仍仅四live快照不推定通过。全部artifact/ZIP/hash/logs证据/tmp/mk-routing-ci06-20261012/summary.json，不重标R01e新提交。

R01a/R01b/R01c/R01d已提交并分别验证。R01e17文件已冻结，作者及独立V2各688全包/strict No issues通过，17源码/test哈希一致，4作者撤门及4独立外置反例证据保留；最终V2 PASS仅宿主范围已回读，本轮保存检查点。有限SDR Texture direct/copy/software、完整route去重、共享MC解码失败与不同导入/upload失败区分、实际CPU帧复核、requested/attempt/effective报告及caprefresh保留当前已审路线已接真实Session。默认coordinator上界1，Session有限catalog3，不放宽HDR<=2/nativeonce/source一次/owner清理债务；F01和unknownDV颜色门保留。普通源EL假fixture修正来自native属性仅DOVI可用的事实，未改变生产源模型。handoff=docs/plans/core-r01e-handoff-20261012.json；不证明native/实机/YUV presenter。CONFIG继续修不可满足新约束却旧输出继续及同route新require实际复核。App实际接线认领中央6112094797/6112101005，与Release writer分离；库共享写入待R01e提交后串行。

CONFIG App第三轮67目标Flutter通过（/tmp/mk-app-config-third-tests.log），真实setDataSource/config first/retry/refresh/settings/恢复、queryA/B旧结果拒绝、off安全toneMap、copy排序覆盖；仅当时dirtyscope，不覆盖后加cleanup故障/重试测试，不是新提交全App验收。首轮43pass/4fail及第二轮65pass/2fail日志保留，fixture/displayHdrTypes/Wakelock mock与真实恢复listeners清理修正分别记录；knownMCnegative增强为独立软件待执行复核与strict/requireHW拒绝，未授权MC/unknownDV。库dispose completeclean/retry和queuedstop仍进行，目标strict接口已通过，完整scope冻结后V2/full验证不可省。

Android/Pink实际Release接线中央6111864635进行中：一次exact source向量、受审A/JAR与B/manifest-evidence双artifact获取、固定selector与账本、bootstrap/副本/显式routing source gates、实际localJAR+arm64Only构建参数、APK后/ABI/sign/parity/finalize。账本仍空，不批准native，缺接受记录必须Gradle前失败不回旧JAR。pending-parity仅中间材料，全部门过才candidate；旧parity对libapp AOT的潜在差异未实测、不删门。生产pin/metadata/签名不放宽，routing不release。

Android/Pink Release V2发现阻断：prepare_android_variant最终来源清单仅选代码后缀，新增res XML/assets JSON/jniLibs SO均被finalized，独立反例/tmp/mk-native-release-review-extra-source.json。冻结14哈希仍一致；114作者/412全Python及旧相关测试成功不足以证明此门。待review完整反馈后原writer修真实构建输入覆盖与生成物边界，不允许把全部新文件当合法，不提交为通过。

Release第一修复轮14文件已重冻，当前Appabc149/库a312 observedHEAD+dirty；作者125相关/423全Python/Actionlint通过，8实际输入注入prebuild与finalize均拒绝，包含已声明资源shader和真实NDK ELF。Lead独立回读14hash一致；原V2复审进行，不能将作者修复算已验收。首次fixture报错顺序/目录mkdir错误日志保留，symlink负例已放knownparent命中真实门。receipt=/tmp/mk-routing-native-release-worker-freeze-r1.json；handoff附修复hash/actualinjection，账本仍空。App新增cleanup70目标及全仓strict0当时dirty通过，新HA真实设置widget测试超时fixture仍修复，完整冻结组合验收未完成。

DV0011095原review5483753705/6110373174/6111479264未修，DEVICE继续原配方/native owner/YUV arm/实机单写，CORE为唯一公共集成者。PR5最新5b历史16行已归aeaf，3md逐字/6hash/相对链接核验，两脚本未导入；188/34info/244为旧8bed+a3+JARcd5声称，原manifest日志未随PR入库，AVC EOS不等dvh1/HDR、UX归因未证。DV001与PR5最终归并、真实完整manifest及最新P5/P8.4/true与false/普通Session/HDR/持续性能仍必需，不能结项。

保留LG批准FULL/range1/YUV8、精确设备门及owner/ACK/lease；不重开10bit/lease融合，不以关闭实验替代验证，产品experimental默认false，true主场景并false回归。ST+PQ不是已证YUV presenter，实际carrier/arm仍待DEVICE协作证明。主任务PR保持未merge/close/publish。

HA真实widget超时根因已独立FakeAsync最小复现：fake-zone创建Completer/real-zone等待造成完成微任务滞留；real-zone创建立即成功。仅harness修正交原writer，Switch/Hive/Session实际断言不变，未称修后通过。证据/tmp/mk-ha-zone-repro.dart。Release r1复审8实际反例拒绝/14hash稳定，额外absolute/escaped资源声明语义及真实私有offlinepubget仍核验中。


### CONFIG模型提交时状态快照（历史）


本CONFIG模型检查点以库8b98+App08acc为代码基线，新增不可变requested/override/effective配置与来源/序列化、纯App设置适配及库一行public export。V1独立35库+22App+4额外反例/两target strict通过，5文件与实际HdrMode/HwDecType哈希一致；隔离纯模型测试最初assets失败保留，最终no-test-assets通过，不是App全量。experimental默认false，explicit auto/reset及按库→App→open完整覆盖；require不被实验/失败策略暗弱化。默认MC组合prefer hardware，disableHA require software；旧原串、copy/direct未完整迁移及未知mode诊断保留。事实模型尚未接DASH/NetworkSource/planner/Session/report，不能标配置闭环完成，后续caller必须处理未知mode诊断。handoff见库docs/plans/core-config-model-handoff-20261012.json。R01e与Release接线其他dirty改动不进入本模型切片。

最新完整已验源码向量只为App08accb63df8c4cab62d00946fb2159dd3781e0ee+库8b98c67a293876bd4af3f36ff245968ca848b41e：source38160661703 attempt1 SUCCESS，四平台真实bootstrap各211/strict零问题/bundle/finalize、Python359/Chrome1/Web；8份source/Build内实际bootstrapreceipt前后向量/10routing+261roots/102toolsroots及2662hash一致，无SKIP。Build38160661882整体FAIL但源码矩阵全成功，6Release既有前置失败，不native验收。库628video+3原mac Linux跳过/lab298与strict/query/Darwin9/OHOSunsigned成功；general四平台test仍live/运行中log API404，未重跑取消跳过。Windows已真实成功，但旧PNG因果未单独证明。证据/tmp/mk-routing-ci05-20261012/summary.json；这些结果不重标本模型提交。


当前已推送App b1978a9602b74ca2821d1d36ea27560381c7c03a；库8b98c67a293876bd4af3f36ff245968ca848b41e（R01d新检查点）。新库8b98 source38160404717独立核对video628+3原mac Linux跳过、lab298及strict通过；Darwin9成功，新App两source仍真实执行中，Python本轮各316（非旧309）。下面完整旧运行只证明f179+915：source38159246222/Build38159246432均失败，Android/Linux/macOS实际bootstrap通过（各strict零问题/211Flutter/bundle/真实SDK及package补丁/10routing与全部261roots/前后final新鲜度），Android另Chrome/Web通过，本轮Python两run各309。Windows original SDK tracked PNG修改被拒绝，路径261字符是嫌疑，实际原文件工作hash/diff缺口保留；Build另6Release前置失败。证据/tmp/mk-routing-ci04-20261012/summary.json，未改标最新库。

CI04 Windows窄修已完成V1独立29 bootstrap+19workflow+13来源/Actionlint通过，待本检查点提交后真实runner验证：runner.temp/rb短根（sdk s/flutter/cache p/results r/fallback f）统一；App首次checkout/SDK前longpaths及LF；未知SDK先收齐status/working/indexdiff与HEAD/index/worktree hash或readError再拒绝。不得ignore/reset原SDK，220字符静态路径计算不证明原因或实际修复成功。来源、真实补丁、roots/hash/freshness/失败归档门保留。

34info已于CI03清零，DEVICE旧8bed+a3向量34info不覆盖当前严格分析。库R01a/R01b/R01c已实现，R01d刚推送8b98c67a普通scalar decoder复核/原子entry-epoch/单review预算/代次与MIME/frame/报告绑定；两critical问题修复后独立255与strict通过，两门删除负例红灯保留。预算不包括open admission，不能抢占同步native FFI。真实carrier、copy/software catalog及auto/prefer/require有效配置闭环仍开放；experimental默认false，true主测/false回归。

native输入门四新文件两critical漏检已修并独立复审通过：完整dynsym与nm交叉核对、exit0诊断拒绝、全部ZIP流式CRC；43unit+2既有ABI通过，真实LLVM原strong/去section反例拒绝与正常合成SO通过。本检查点待提交，尚未接线Release。接受账本空，不授权DV001；实际Release workflow/native候选/ABI/签名/设备未验。正式mac tag、各平台来源/ABI门不删除。

DV001仍1095a43原PR修复未回交；PR5最新5b279611文档16行已归主线aeafc6c3，原与导入6hash及V1原文/5链接核验，两个脚本未导入。新188/34info/244为DEVICE旧向量声称，原manifest日志未入PR；AVC EOS不等于dvh1/HDR，UX归因未证，dvh1菜单后e2e仍缺。DV001与PR5最终归并、完整manifest、最新P5/P8.4/truefalse/普通Session/owner/YUV arm实机复测必需。保留LG FULL/range1及owner/ACK/lease，主PR不merge/publish。


### CI04 Windows检查点前快照（历史）

当前已推送App f7505821fb1c8191f2c899555c4c5e9129d5421a + media-kit9152154473901b750553be96dbc2137c927b2f5d；下述已成功源码运行仅证明此前c51fd0973 + media-kit12966e7a。最新已完成专用source38158306410 attempt1 SUCCESS：实际Appf750+库915（treea8b1cdc6/9ad3d930），strict零问题、211Flutter/1Chrome/299Python、Web/bundle、10包before/patched/after一致与两仓freshness通过。source artifact11709368250 ZIP938b8443eecd0e1b03e21525450340671f2326f7a1704aea8a446f47816b9c6d；Build内source独立11708758246也成功，不跨run改标。库915 source38158342447 video604+3原mac Linux跳过/lab298/strict通过；query34+Java、Darwin9、OHOSunsigned成功，general仍live，旧general四tests终态cancelled。证据/tmp/mk-routing-ci-20261012-next/summary.json。上述运行不证明后续接线提交。

34 info已在CI03 1965ba0e清零并由新向量继续验证，不再是待修项。R01b12966请求契约统一、输出复用/重建与失败清理已实现，本地64目标、独立critical78及strict通过。真实decoder/presenter/copy/software catalog、auto/prefer/require有效配置贯穿闭环仍未完成，experimental产品默认false保持。

Release38156848910仍有失败：Android/Pink/Linux私有PUB_CACHE缺目录；Windows缺兄弟media-kit源码，pubget exit66；mac PR空tag被正式release gate拒绝；iOS已失败于旧锁SHA校验，标准Flutter兼容先成功，未到编译。源码job通过不能代表native/ABI/签名/设备通过。公共bootstrap三个新文件已实施并26目标/13来源测试及V1独立26+13通过：exact两仓HEAD、私有SDK/cache、resolve→真实补丁、全roots/10包来源与前后hash、freshness及失败receipt；尚待真实平台接线，不宣称mock就是真实bootstrap。Windows包补丁helper URI窄修5目标/13关联及V1独立5+13通过，仅标准库单次解码和本机路径转换/URI组件门，原patch校验未改；真实Windows尚待。Bootstrap V1原两缺陷已修：拒绝unknown untracked/ignored源码、不写protected GITHUB_ENV；CRLF和继承SKIP=1明确拒绝，调用方必须checkout前LF配置，不能normalize hash伪通过。已提交Appf7505821f推送回读，真实pubget/3OS尚待；bootstrap_wiring已完成现有sourceworkflow和直接tests接线，V1最终15目标/Actionlint通过，作者15+26+13及YAML/Bash/pwsh解析通过；准备提交新矩阵，真实执行待新CI，R01d_worker已认领普通采样identity/单预算/现有frame&MIME事实，不动nativeDV专用协议。

CORE-R01c中央6111412893认领首小阶段：持续实际hwdec/route不一致不能accept/verified；普通review/open超时不得误标outputBindTimeout排除platformView。已提交库91521544并回读，critical231及全strict通过。合法budget SDR/已准入第二HDR保留；完整actualdecoder采样/资源复核仍开放。原nativeDV、F01、owner与cleanup门保留。曾尝试复用旧r01_implement角色收到agent thread limit reached，未假装执行；新原生team_worker_escalated r01c_worker派发成功，责任仅Session/coordinator/直接测试。

DEVICE最新6111344927登记LG原候选实体屏幕人眼颜色亮度基本正常，DV002呈现项passed_for_vector；不改标最新整合验收。DV0011095a43构建审查及native owner/YUV arm、普通Session无define接线、最新native输入manifest仍开放。CORE不接管配方，不以SurfaceTexture+PQ猜YUV，不改已批准LG FULL/range1。主PR未合并、未发布。

用户再次明确要求归并DV001与PR#5，列为最终必需交付：media-kit PR5 latest86c186f0/base routing主线、构建PR1 DV001 latest1095a43已回读。库文档e162cb3c已部分归并三md/README/原导入hash，独立critical原文/6hash/5relative链接通过，两个sh未归入；DV001仍REQUEST_CHANGES。独立critical角色dv_integration_audit审查可归并文件与旧向量/配方问题；CORE唯一归并者，DEVICE原PR修构建，最新完整输入组合关键P5/P8.4复测不得省略，不自动merge主PR或发布。

新CI Appsource38158306410/Build38158306591、库915source38158342447及query/Darwin/OHOS/general正在核对。Build内源码job114525735394已SUCCESS，artifact11708758246实际f750+915（treea8b1cdc6/9ad3d930），211Flutter/1Chrome/Web/bundle/10roots前后相等及freshness成功；kernel a9c7d7eab0ce9ed196e8a32da6b3b709ad3f5b829ace20353b60ad27b95d437a。Python Build299实跑成功，dedicated源码job仍待其独立终态，不跨run借archive。库915源码604video+3旧mac跳过/298lab/strict已成功。Build整体6Release前置失败，native未验。不删除新鲜度门。


- 2026-10-11：CORE继任从当前远端569138fa建立同分支独立worktree，保留默认checkout .zcodeignore；归并已完成F01/CI02与旧分析债务状态。

### 2026-10-12 前序检查点记录（历史，非当前状态）

CI03远端终态已核验：App1965ba0e6c50316f1a64f6830bb0877d5f84606e+库bd9b9f852949af8980faaad337064a0830c405da，source run38155973408 attempt1 SUCCESS，实际strict零问题、211Flutter/1Chrome/263Python、Web/bundle/10包绑定与两仓freshness通过。artifact11709080173与11708632336按ID/ZIP SHA下载核验，中央6111284247/App6111284532。独立Build38155973649 FAIL，在cache/兄弟源码/旧锁/空tag前置失败，未进入native/ABI/签名。

后续库R01b已推送12966e7ac78983807199e0a179e84ad763a547a7，64目标及critical78/全库strict通过；上面bd9组合不改标此新库。App本次小阶段仅修file URI本机转换及测试：标准库单次decode，保留10包来源/路径安全门；13目标与5关联通过，V1独立13通过。Windows只有标准库语义模拟，真实runner尚未验证。此提交后重新进行最新App+12966源码CI。

CORE-CI03串行包名迁移完成：919文件、6315处精确package URI替换及1处root name，逐文件after==before.replace验证；Python旧输入夹具、产品/native标识未替换。私有pubget已成功，10包media-kit实际路径核验通过；结果JSON内HEAD仍66eedd680，当前dirty改动不是该提交的通过证据。全量严格分析、迁移后控件/Web联合复验及独立审查正在进行，不宣称34info已清零。迁移前文本15项通过、旧重复copy负对照macOS失败符合预期，恢复源码哈希一致；这些不改标为迁移后结果。原稿及逐文件manifest见/tmp/core-ci03-package-uri-migration/。

本轮全量严格分析首次exit1：剩1条原list_tile cascade及5条新增控件测试hasFlag弃用，共6 info，失败保留；修复后最终全量flutter analyze --no-pub exit0 No issues found。迁移后全VM回归211项通过，debug bundle exit0，kernel SHA256 a466231cf59af8f529174ab11a72aad5704f1050bc288cc8170c5c107a1bd7fd。文本控件V1独立15项、基础控件V1独立2项及其目录strict通过。Chrome真实DOM1项、新URI生命周期2项、实际main_web release构建和workflow契约5项通过；Web/lifecycle独立复核再跑2+1项通过、workflow失败传播与来源门核验无阻塞。新增GitHub Chrome/Web入口构建步骤待远端运行。不改标本地dirty测试为570c提交通过。测试日志/tmp/core-ci03-full-{analyze-final,flutter-tests}.log、/tmp/core-ci03-bundle-final.log；Web89文件哈希与运行证据见.runtime/ci03b-results/summary.json。无APK/新native/设备验收声明。

Release pointer兼容修复独立V1通过：两个脚本各自只允许删除唯一完整批准行，缩进可变，其他字节及mac来源/节点/恢复门不变；未知/重复调用及额外App变更拒绝。作者35目标+33关联通过，V1独立35目标通过、关联日志核对。此检查点只提交两个脚本及两个Python测试、记录，不混入CI03大批URI改动。真实iOS/macOS打包尚未验收，证据/tmp/mk-core-pointer-*.log。

2026-10-12：最新已完成联合源码验证为App b969fc289945ea0aa762de3a3ce026301bb17ec0 + media-kit bd9b9f852949af8980faaad337064a0830c405da。App run38153119252 attempt1实际执行192 Flutter、244 Python、bundle、10包源码绑定及远端新鲜度通过；严格分析34 info、0 warning、0 error，整体失败。终态中央6110898494、App6110898811；不是下述旧向量的重标。

CORE-CI03在中央6110943824认领文本控件、Web、生命周期及包名迁移。当前改动尚未提交、尚未全量验收；隔离Flutter3.47.2/私有pub-cache依现有patch.ps1 android配置，前后10包绑定一致，原共享SDK/cache未改。控件与Web行为回归正在执行；包名规范化须同步OHOS准备脚本，不能以name判断跳过工具链转换。产品experimental默认false保持。

OHOS包名兼容准备已修复：五项约束逐scope严格接受唯一old/new，小写包名不再跳过Dart/Flutter/flex/material转换；未知、缺失及重复字段/section拒绝。目标10项及关联19项通过，V1独立重跑目标10项通过、核对关联日志。仅脚本和新回归测试进入此检查点；真实OHOS pub/HAP/native及设备验收未执行。证据/tmp/mk-core-ohos-package-{before,after,related}.log。

CORE-CI04a已定位Release Python随机失败：PBX模板插值后扫描双下划线误拒合法临时路径。两文件修复保留payload/ABI/来源/签名检查，本机目标38及关联177项通过；V1独立重跑目标38通过并核对关联177日志，无阻塞发现。此检查点仅提交这两文件和当前记录，其他CI03/OHOS改动仍待验证；不等同真实Xcode签名验收。证据/tmp/mk-core-ci04a-before.log、/tmp/mk-core-ci04a-inputs.log、/tmp/mk-core-ci04a-related.log。

Release iOS兼容准备失败进一步定位为固定缩进匹配：当前view.dart仍有pointerDownFilter调用（10空格），prepare_standard_flutter_package_compat.py与macOS候选源码允许差异检查固定12空格。不能按“调用已删除”绕过断言；后续应统一严格匹配语义、覆盖实际源码缩进并保留未知变更拒绝。此项尚未修复。

### 接手时状态（历史溯源）

CORE继任登记media-kit PR4 comment6110756605，继续唯一routing/MK-ROUTING-20261011/PR1。App生产代码本阶段未修改，汇总台账归并CORE-CI02/F01终态。权威公共上下文在media-kit archives/conversations/media-kit-routing-20261011.md；v3与takeover仍为接手入口。

App569138fa+库6e7570fc在run38146940852第二次App job114499858358执行192Flutter、bundle/10包来源/新鲜度成功，34info/0error/0warning；同AppSHA此前244Python保留，不声称再次执行。artifact11705617556为实际向量，11705292989为旧库，不混用。终态6110417510，库6110447335。此次文档checkpoint没有改标旧测试为新SHA。

DEVICE继续原native构建/实机，DV0011095a43审查未闭环；续审6110762843。CORE-R01a只改库SurfaceTexture依赖与mismatch隔离；Appcontroller/hdr_output、SDK、native配方未认领改动。下一步最新组合验证、34info、Release CI和真实auto/prefer/require闭环。experimental默认false保持。

### 2026-10-12 Current State 校正前快照（历史，不作当前结论）

旧状态快照

唯一集成分支 routing/MK-ROUTING-20261011。远端当前库d91639401862d84c68406aae3b2029400a4cfbd6、App 1970d440b5b9d9ffc001866064581e4005b26b30、FFmpeg9aba43cfbee182ade060cdccbe15340a0fbe3e83；DV0011095a43、PR5 5b279611未见新修复回交。中央认领6113083125。主PR均未合并/关闭/发布；root唯一公共集成者，DEVICE继续原recipe/native/实机责任，原checkout未知dirty保护。

已完成F01/query/DASH/未知DV/FFmpeg e8df200c、R01解码导入呈现依赖/输出资源契约/实际decoder复核/有限独立copy软件路线、auto/prefer/require有效配置贯穿App选源/planner/Session/report以及请求代次和清理债务；不按旧planned重做。LG配置claim回归已修并独立V2及当前源码CI验证。34info已清零、当前strict0；默认experimental=false，主验证true并回归false；LG FULL/range1/YUV8/精确设备/ownerACKlease保持，不重开10bit/lease融合。

当前完整源码验收仅e31a+d916：App source38169989794 SUCCESS、Build38169989974 failure但其源码矩阵也完整SUCCESS，两套四平台各268/strict0/bundle/finalize；Python本轮实际451两次（177.586/182.022s）、各7真实parser/kernel/identity。库38169536268 video772+3原mac Linux跳过/lab298/strict0，query34+实际Java/Darwin9；OHOS实际PRmerge eaee10dd单独unsigned范围，不是纯d916或实机。证据docs/plans/core-source-prelude-ci-checkpoint-20261012.json含21artifactIDs/hash；完整822文件索引保留本机。general只有pending快照，不推定通过。旧6c4+751/其余旧向量证据各自保留不重标。

Linux/Windows A四文件已第二修正Critical通过并在e31a提交：完整captured vector允许caller PR/dispatch，直接routing/缺向量拒绝，作业名中性。43contracts/actionlint/20实际条件及pwsh失败传播验证。Hosted两Release真实prepare/verify/finalize各57steps0/fresh-source-only后SOURCE_PREPARED_NATIVE_BLOCKED（11713952189/11714201466），旧下载全部skip；原始job日志复核：verify步骤内实际bundle命令成功，未单独归档bundle digest；独立源码矩阵另有bundle证据。不是native或整个平台Release通过。旧两轮REQUEST_CHANGES保留在core-linux-windows-source-prelude JSON。

Android/Pink来源/YAML/生成物/plugin精确契约与双artifact接受门已提交保留；当前ledger/selector空，最新两Release实际preAPI/prestaging/Gradle拒绝，不借旧JAR。旧准确6c4+751已真实clean SDK/Android/Pink prepare/offline lockedpubget/prebuild/lock/finalize成功，各1888inputs/31pubGenerated/3buildGenerated/86links，bootstrap6b261eff；只source前置，无native或variant postbuild验收。原SDK36dirty、失效cache symlink、driver参数错误均保留。此历史向量证据core-source-prepare-checkpoint不改标e31a。

iOS六文件第二修正已Critical PASS_WITH_SCOPE：26variant/31bootstrap、实际d3三文件iOS补丁正例与Android重标签/步骤伪装/文件工具失败等独立9case通过，deepcopy问题已关，六hash前后同。原两轮REQUEST_CHANGES完整保留core-ios-source-variant-review JSON。当前准备仅集成这六source文件及root记录，不混Linux B或PR5未审内容；实际最新iOS bootstrap/pubget/prebuild/hosted/Xcode/native尚待，不称Release完成。

Linux B消费者九文件已冻结（作者库5/App verifier7/acquirer3合成测试通过），独立Critical正在核验真实CLI/CMake参数链、非空synthetic批准和consumerSourceClosure；证据core-linux-native-consumer-review JSON，生产ledger仍空，未批准真实native。不执行伪App helper自授权，不套Android3成员规则、不改DEVICE producer。pr5_matrix_integration单写库tool/matrix-build.sh/routing_matrix.py/tests/README，将公共矩阵归唯一入口，真实fixture内容/当前source/受审native/每APK ABI签名来源与失败传播，已冻结四文件（作者12模拟tests），native_release_review独立V2进行中；不新增弱化/打包配方。root拥有汇总JSON/TASKS/context/Git，其他dirty不混提交。

DV001/PR5必须完整归并：三历史MD及16行已e162/aeaf归入；两脚本仍未完成。assemble-jar-arm64重复DV001且留nm读取失败/单目标问题，由DEVICE归原canonical bundler；matrix-device-build公共功能归现tool/matrix-build.sh。路径/blob/hash与去向见core-pr5-script-inventory JSON，不是脚本批准或整项完成。DV001各符号/ABI/部分写/失败传播/clean staging/最终成员链接补丁manifest仍待原PR修复。最新受审native、八包实际构建、P5/P84 truefalse/普通Session/owner实际carrier/可见HDR/持续性能仍缺同向量验证；旧AVC EOS/模型SDR不能替代。

下一阶段：复审iOS第二修正、V2审核已冻结Linux B与PR5矩阵，再由root准确stage/中文commit/push/readback、最新组合复测。Linux真实producer→consumer→bundle、iOS workflow/native消费者、Windows native/其他Release仍继续原DEVICE协作，不因源码绿或空ledger正确拒绝结项。汇总JSON校正随下一真实源码checkpoint提交，不纯记录push反复取消CI。

2026-10-12继续检查：Linux B冻结九文件已交linux_native_review V2，postbuild CLI/插件名疑点正在独立复现，未提交。PR5实际Lab _hdrRoutingPolicy中HDR_GATE_OPEN=true令allowExperimental=true、HDR_POLICY_EXPERIMENTAL=false保持默认排序；矩阵作者新增逐行allowExperimental字段与八行模拟顺序，尚未冻结/复审，不算八APK。iOS独立clean工具链准备首次agent-slot不足已记录，原Linux作者完成后重派ios_clean_toolchain_prepare成功；只clone验证SDK/cache输入，不运行未审iOS脚本。磁盘1.3GiB，不清理原资料，旧Android-patched SDK/cache不可改标签当iOS。

PR5矩阵四文件准确冻结记录core-pr5-matrix-review-20261012.json（库d916），12项模拟tests不代表真实八APK；与Linux B V2并行，均未审通过或提交。Linux独立复现已发现postbuild参数与插件名缺陷，另RPATH允许额外绝对路径，审核仍收尾。

Linux B首审终态REQUEST_CHANGES：38独立probe/15已有tests与最小CMake真实configure，准确五P1（postbuild双层参数、实际插件名、绝对RPATH、不可达bundle布局、App linux/与shared gate闭包遗漏）；原writer第1修正已授权。原9hash/HEAD冻结一致，报告1f9c4b84保留，未声称native批准/编译。

PR5首审终态REQUEST_CHANGES：正常lab自身package根、Flutter完整APK成员与非法build --build-dir阻断，成功receipt仅内存未落盘；P5明确DV事实应独立于缺失裸BT2020 VUI。首轮四hash不变，12原tests仍过不能抵实际CLI失败；原作者第1修正已授权，未提交。iOS新clean SDK输入r1精确源tag3.47.2/官方origin与describe已补并全量hash复验，证据1a542619；只准备输入，不是iOS bootstrap或构建通过，旧Android-patched cache保持。

中央最新review登记6113395912：Linux B与PR5首审真实失败/修正范围、SDK输入与DEVICE同原PR回交边界已发布；不改标旧CI、不启动第二配方。



iOS六已审source+root记录已精确提交push/readback App1970d440b（six committed blobs逐hash=V2），库仍d916；未混Linux B/PR5未审source。source38172589162 pending、Build38172589627 queued为真实新1970，重复source38172585650已cancelled，不拿旧e31全绿改标。ios_clean_toolchain_prepare正在新clean两个checkout/私有SDK/p空运行真实当前iOS前置，期间不push新向量；Linux B第1修正新冻结已交V2，App新HEAD为独立iOS提交，九ownedbytes未被此commit触碰。

原e31a+d916前置bundle更正已按两个原始job日志+成功step API核实（Linux114560490516/Windows114560490505）：实际命令及nonzero throw guard完整执行后进入finalize；不是独立named bundle step，也非单独归档产品hash。原摘要ac15事实错误保存并附更正，不重标1970/native。

Linux B第1修正V2仍REQUEST_CHANGES：18原tests/49独立probe及实际generated postbuildCLI，旧4问题关闭于synthetic scope；剩余allDSO ABI门被删除回归和requesterRPATH/RUNPATH非传递缺口。原writer第2/最后修正授权，必须恢复原ABI及逐请求者可达性门，不删失败断言/制造绿；新freeze再V2，真实native仍未批准。报告118ff41e保留。

实际1970+d916 iOS bootstrap/sourceverify/finalize已exit0/fresh-source-only，before/after/final精确向量一致，真实SDK三文件语义和两patch阶段身份在receipt；variant启动前因仅约158MiB(<256MiB reserve)准确停止，尚未创建或验证。完整raw e8f4d8d1保留本机，项目compact checkpoint附源hash/step结果；只source前置，不是Xcode/native/Release。只读同字节cache统计正进行，不清理材料/复用Androidpatch。

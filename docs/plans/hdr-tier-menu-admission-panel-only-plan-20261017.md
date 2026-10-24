# HDR 档位菜单准入：面板能力唯一判定（策略切片设计 v2 · 已实施）

> 状态（2026-10-17）：**已按本设计实施并通过 V2**（Critical Reviewer 五轮复审，最终 PASS-with-notes；宿主全量 363 PASS、analyze 0）。§1.7 由用户「按方案实施」采纳**推荐方案 X**。实施中按复审补充并落实的内容（R1–R4、B1–B3、D/E1/E2 8K 门）与设计稿的差异见文末「实施记录」。**本文为源码与宿主验收，实机矩阵见 routing conversation Current State。**
> 基线 App `997244ba9`（routing/MK-ROUTING-20261011）。前置依赖：DV003 嗅探 facts 键断接修复（C 修正版）先实施、通过 V2 与真机验收；本切片与其同文件（`lib/pages/video/controller.dart`），按单写者纪律串行。**本切片的行为矩阵与修前反证一律以「C 已落地、本策略未改」为基线。**
>
> 文件代号：P=`lib/pages/video/controller.dart`，L=`lib/plugin/pl_player/controller.dart`，E=`lib/pages/video/video_quality_eligibility.dart`，S=`lib/plugin/pl_player/source_selection.dart`，R=`lib/plugin/pl_player/route_options.dart`。行号对应 `997244ba9`。

## 1. 策略公理（用户裁决，2026-10-17）与精确化

1. **档位编号即内容声明**：126=杜比视界、125=HDR10、129=HDR Vivid。B 站只对存在对应版本的视频、且账号有资格时才下发这些轨；两种 126 标注形态（`dvh1.08.07` 显式 / 裸 `hvc1.2.4.L150.90`）容器实证均为真 DV（P8.4）。菜单**不做第二层内容确认**。
2. **菜单被动准入唯一能力判定 = 面板 HDR 能力**。精确定义：面板 probe 返回 resolved 且 `displayHdrTypes` 含已知 HDR 类型（1=DV、2=HDR10、3=HLG、4=HDR10+）；null / 空集 / unresolved 均不算支持。三机实测集合 LG `{1,2}`、LYA `{2,3}`、marble `{1,2,3,4}` 均满足。vendor 输出能力串（LG `setterOnly {pq,pq-itu}`、LYA `{pq}`）是输出/读回能力，**不是**面板类型，不参与判定；不按设备名特判。
3. **规划器可行性只在「即将打开源」时咨询**（五个开源入口，见 §2）。菜单被动渲染不咨询规划器、不等待嗅探、不触发能力查询。
4. **PiliPlusX 不使用 HDR→SDR tone-map**：B 站 DASH 恒带 SDR 轨，SDR 输出就播 SDR 轨。SDR 面板灰禁 HDR 档是最终态。
5. 嗅探 facts 与容器复核**只服务播放层**（DV005 `initialDoviFacts` + Session 打开时复核）。
6. 既有约束不变：判断只依据设备能力不依据设备名；macOS 8K 门禁独立于 HDR，不动。
7. **「HDR 模式=关闭」语义（待用户裁决）**。事实：设置入口 `lib/pages/setting/models/play_settings.dart:29-38`，R:109-111 把 `HdrMode.off` 映射为 `output.require(sdr)`；现行为是 HDR 面板上仍可选 HDR 档并 tone-map 为 SDR 播放——与公理 4 冲突，且它不是诊断入口而是用户设置。两个候选：
   - **X（推荐）**：「HDR 关闭」作为用户偏好层的第二个菜单灰禁输入——灰禁 = 面板无 HDR ‖ 用户关闭 HDR，提示「已关闭 HDR 输出」；HDR 档在任何面板上都不再以 tone-map 打开。同步、静态、无规划器耦合，与公理 4 完全一致。库 `require(sdr)` 语义及其 selection 测试（`source_selection_test.dart:100-132`、`pq_presentation_unavailable_test.dart:74-80`）不动——它们是库级能力断言，不是菜单准入断言。
   - Y：HDR 关闭时菜单仍白，点击拒绝并提示。与「白=可选」直觉冲突，不推荐。
8. **「保留当前播放」契约的精确范围**：点击后的**开源前检测**（轨存在性 / 面板 / HDR 关闭 / 路由）拒绝不改变当前播放；进入真实 open 之后的失败按播放器既有错误契约处理，本切片不承诺旧源恢复（那是播放事务设计，另立项）。
9. 菜单准入只证明「可选」，不保证输出成功（HDR 激活、硬解、持续出帧由播放层证据判定）。

## 2. 现状判定点（事实，已按评审修正）

### 2.1 展示层
- `qualityEligibility()` P:717-732。消费者：`header_control.dart:1007-1039`（ListTile 恒 `enabled: true`）、`pl_player/view/view.dart:924-940`（PopupMenuItem 恒 `enabled: true`）。两处均**仅视觉置灰**，点击一律进入 `changeVideoQuality`。
- 纯函数 E:82-125 已按 125/126/129 + `displaySupportsHdr` 判 HDR 档，再独立判 macOS 8K。

### 2.2 请求层（开源前，影响服务端是否下发 HDR 档）
- P:1290、P:1299：playurl 请求的 qn/tryLook 由 `hdrDisplaySupportsHdr` 决定。SDR 面板时服务端可能根本不下发 HDR 档（届时是「无此档」而非「灰禁」）。

### 2.3 开源前选源入口（五个，共用 `_routeAllows` P:272-275、`findVideoByQa` P:1049、`_hdrTierPresentable` P:701-702）
| 入口 | 位置 | 现状要点 |
|---|---|---|
| B 点击 | `changeVideoQuality` P:760-790 | probe → eligibility → `_hdrTierPresentable`（P:773）→ findVideoByQa → `updatePlayer()` **未 await**（P:789）即返回 true，菜单随即 toast「画质已变为」 |
| C 冷启动 | P:1404-1507 | P:1404 候选轨路由过滤；P:1420/1462/1483 三处 `_allowsHdrSourceAsSdr`；P:1495 `_hdrTierPresentable`；**降档无 toast** |
| D 面板变化降级 | `_onHdrDisplayChanged` P:672-692 | P:674 getter early-return；P:672-676 **先读 `data.dash` 再判当前档**；fallback 用旧 `_routeSelection` 取首个 SDR；空集静默 return；toast「已切换」早于 `updatePlayer()` 完成 |
| E1 设置变化重开 | P:183-190 | `where(_routeAllows)`，空集 → `stopForRouteOptions` |
| E2 输出目标变化重开 | P:252-258 | 同上 |

### 2.4 能力发布层（`hdrDisplaySupportsHdr`，初值乐观 true，L:620-634 / e9f99ada1）
| 来源 | 性质 | Android 路由覆盖 |
|---|---|---|
| L:1743 `refreshHdrDisplayCapabilities` Android 分支 | 面板 probe | **首开主来源**：P:1273 在 playurl 请求前 `await`；P:243 目标刷新时调用 |
| L:1854 `HdrCapabilityChangedEvent` | 面板事件 | 后续变化来源 |
| L:2264 首次 Session 发布初始化结果 | 发布 | 晚于页面选档，无回调 |
| L:2309 | **发布失败回滚**（非 probe） | 可能恢复旧值 |
| L:1383 / L:1766 | 非 Android 路径 | 正常 Android Session 不经过 |
| **P:314** `= selection.displayHdr ?? false` | 路由查询结果覆写 | `_sources` 为空（查询失败）时 null→false，误灰好面板 |
| L:1741 | `?? false` | probe 自身失败亦 null→false（**本切片不改，登记为后续三态项**） |

### 2.5 `_allowsHdrSourceAsSdr`（P:267-270）
五处使用：P:674、727、1420、1462、1483。

### 2.6 已核实的缺陷与测试障碍（事实；未运行复现的标注「可达」）
- **late `data` 可达异常**：`data` 为 late（P:123），普通网络源在 P:1317 才赋值；P:620 注册回调在前，P:1273 的 refresh 若首次返回 false 会同步回调 `_onHdrDisplayChanged`，P:672-676 先读 `data.dash` → `LateInitializationError` 可达。现 getter early-return 可能遮蔽了它，删 getter 后会暴露。
- D 的 fallback 可为空：S:150-154 显式 output/decode `require` 且能力未知时 SDR 轨也被拒；无 SDR 轨时亦空。
- B 的「保留播放」不严格：P:280-282 unsupported legacy request → `stopForRouteOptions` 停播；陈旧 probe 返回 false 无 toast；P:789 不 await。
- 宿主测试障碍：P 直接用 `dart:io Platform.isAndroid`（P:230、702、718）；`androidSessionOverride` 只改 `usesAndroidRouting`，macOS/Linux 宿主打不到 Android 分支，T1/T8 在旧实现下也可能「白」，修前反证无效。`probeRoutingForTesting` 不绑定 HDR 回调；`cid` late final（P:96）。
- `scripts/`、`tool/` 未发现依赖「SDR 面板 HDR 菜单白」的自动化；库工具的 SDR-only tone-map 矩阵是库级语义，不随本切片翻转。

## 3. 改动设计 v2（仅 App 侧；media-kit 库、JAR、规划器、复核门零改动）

### 3.1 菜单纯展示化
- 删除 P:718-722（Android `routeUnsupported` 前置分支）。
- `displaySupportsHdr:` 改为仅面板标志（若 §1.7 裁决 X：`&& hdrMode != off`，新增原因 `hdrModeOff` 与文案「已关闭 HDR 输出」）。macOS 8K 参数与逻辑不动。
- **行为注记**：此前因路由拒绝而灰的 **SDR 档**同样变白，点击时由开源前守卫拒绝并提示；写入矩阵。

### 3.2 删除页面层 tone-map 豁免
- 删除 `_allowsHdrSourceAsSdr` getter 及五处使用（P:674/727/1420/1462/1483），清理随之无用的 import。
- 库 `require(sdr)` 语义、S:157-160 分支、selection 层测试**不动**。

### 3.3 统一五个开源入口的 rendition 准入
- 新增 `_openAdmits(VideoItem item)`：HDR 档 = 面板 HDR（且按 §1.7 裁决 HDR 未关闭）∧ `_routeAllows(item)` ∧ HDR-presentable（`isHdrPresentable(prediction)`）；SDR 档 = `_routeAllows(item)`。**不再允许 require(sdr) 绕过 HDR 呈现要求**。
- B/C/D/E1/E2 的候选过滤与最终 `findVideoByQa` 前复核统一用 `_openAdmits`；E1/E2 的 `where(_routeAllows)` 改为 `where(_openAdmits)`，防止 SDR 面板/HDR 关闭下重开时选回 HDR 档。
- 保留逐轨 `_routeAllows`、最终 `findVideoByQa`、Session 打开时复核三道既有守卫。

### 3.4 面板发布
- 保留 P:1273 / P:243 的请求前 `await refresh`（首开覆盖的依据）。
- **删除 P:314-315**，不保留旁路；面板标志只由 L 的 probe/事件链写入。
- 文档化边界：L:1741 的 null→false、三态（unknown/已确认 HDR/已确认 SDR）、`bindOutputView` 旧目标窗口（先清 selection、异步 probe、后 refresh）均**不在本切片**，登记为后续「面板状态三态化」项。

### 3.5 回调与降级（D、C）
- `_onHdrDisplayChanged`：顺序改为先判 `currentVideoQa` 是否 HDR 档（null 或非 HDR → return），再访问 `data`，并以 `data` 就绪守卫保护（late 未赋值时直接 return，不抛）。
- fallback = 按**质量值**最高的 `_openAdmits` SDR 轨（不依赖服务器列表顺序）。
- 空集不静默：toast「当前显示器不支持 HDR，且没有可播放的 SDR 画质」。
- 「已切换到…」toast 移到 `await updatePlayer()` 完成之后。
- 冷启动 C 真实降档时新增一次提示。

### 3.6 点击 UX 与可测性（B）
- 顺序改为：轨存在性 → 面板 / HDR 关闭**同步快速拒绝**（不等 probe）→ `_probeRoutingCapabilities`（超过阈值显示非阻塞「正在检测播放路径」，完成/失效必清理；阈值实施时定、UX 验证）→ 复核 revision/serial → 路由拒绝 toast 统一用 E 的 `routeUnsupported` 文案「当前解码或 HDR 输出路径不支持该档位」（与「当前显示器不支持 HDR 输出」区分）→ `findVideoByQa` → **`await updatePlayer()` 后再返回 true**（两个菜单的「画质已变为」随之后移到真实开源之后）。
- 陈旧 probe 返回 false：不 toast、不报成功（保持）。P:280-282 legacy unsupported request 停播路径不属本切片（登记）。
- **测试 seam**：新增最窄 `routingPlatformPredicate`（默认 `Platform.isAndroid`）注入点，P:230/702/718 统一经该谓词；生产默认零变化。禁止测试直接注入 facts/cache 绕过 C 的生产链。

### 3.7 行为矩阵（基线 = C 已落地、本策略未改）
| 场景 | 基线 | v2 后 |
|---|---|---|
| HDR 面板，126 裸 hvc1，facts 未到（嗅探中/失败） | 灰（unresolved） | **白**；点击→路由拒 toast，保留当前播放 |
| HDR 面板，126 裸 hvc1，facts 已到 | 白 | 白；点击→`await` 开播后才报「画质已变为」 |
| HDR 面板，126 `dvh1.08.07` | 白 | 白 |
| HDR 面板，P7 / 未知 profile | 灰 | **白**；点击→规划器拒（非 unresolved 分支）toast |
| SDR 面板，任何 HDR 档（若服务端仍下发） | 灰 | 灰；冷启动缓存 126 → 最高 SDR 实选 + **新增 toast** |
| SDR 面板 + HDR 关闭 | 白（tone-map） | **灰** |
| HDR 面板 + HDR 关闭 | 白并 tone-map 开播 | X：**灰「已关闭 HDR 输出」** / Y：白 + 点击拒 |
| SDR 档被路由拒 | 灰 | **白**；点击拒 toast |
| HDR 面板，路由能力 source query 瞬时失败 | HDR 档全灰（P:314） | **白**（面板标志不变） |
| 面板 HDR→无 + HDR 关闭 + 当前 126 | 不降级 | **降级到 SDR 轨** |
| 面板 HDR→无 且无合格 SDR | 静默 | **提示** |
| 首次面板回调 false 早于 `data` 赋值 | 可达异常 | 不抛、return |
| 设置/目标变化重开（SDR 面板或 HDR 关闭） | 可能重选 HDR | **不会** |
| macOS 8K 各态 | 原样 | 原样 |

## 4. 测试设计 v2

### 4.1 前置：seam 与夹具
- `routingPlatformPredicate` seam 先行，**修前基线与修后版本使用同一 seam**，反证才成立。
- 真实 page 夹具扩展（在 `route_options_lifecycle_test.dart` 基础上）：绑定 HDR 回调（`probeRoutingForTesting` 不覆盖）；显式初始化 `cid`；SmartDialog widget host 观察 toast；fake Player/Session 记录 pause/open/dispose 以证明「保留播放」；MethodChannel 分别控制面板查询（`sources=[]`）与 source batch 查询。
- 新文件：`test/pages/video/hdr_tier_menu_admission_test.dart`；必要时 Android integration test 承接必须命中真实 `Platform.isAndroid` 的反证。

### 4.2 用例
| # | 用例 | 断言 | 修前反证（相对 C 基线、同 seam） |
|---|---|---|---|
| T1 | HDR 面板 + 126 裸 hvc1 + 无 facts | `qualityEligibility(126).enabled` | 旧：`routeUnsupported`（Android 分支） |
| T2 | T1 下 `changeVideoQuality(126)` | 返回 false、路由 toast；current/cache/source 不变、Player 零 pause/open/dispose | 非策略反证（旧亦拒） |
| T3a | SDR 面板菜单 | `displayHdrUnsupported` | — |
| T3b | SDR 面板真实冷启动、缓存 126 | 实选最高 SDR + toast | 旧：无 toast |
| T3c | 首次 false 回调早于 `data` 赋值 | 不抛 | 旧：`LateInitializationError` |
| T4a | HDR 面板已确认 + source query 失败 | 标志保持 true、126 白 | 旧：P:314 翻 false |
| T4b | 已确认 false + 查询失败 | 不被翻 true | — |
| T5 | SDR 面板 + HDR 关闭 + 125（或显式 P8 的 126 + 可 tone-map 能力） | 灰 | 旧：白 |
| T6a | 面板 HDR→false 事件 + 当前 126（含 HDR 关闭） | 最终 source 为 SDR 轨 | 旧：early return |
| T6b | 同上但无合格 SDR | 提示、不静默 | 旧：静默 |
| T7 | 125/129 参数化 | 菜单同 126；播放层不保证 | — |
| T8 | HDR 面板 + P7 `dvh1.07` | 白；点击被规划器拒（非 unresolved） | 旧：灰 |
| T9 | 面板五态：已知 HDR / 已知 SDR / unknown-null / 目标变化期间旧结果 / 迟到查询 | 按 §1.2 语义 | — |
| T10 | 被动重复渲染菜单 | 零 capability query / sniff / predict | — |
| T11 | E1/E2 设置变化、目标变化（SDR 面板 / HDR 关闭） | 不重选 HDR 档 | 旧：可能 |
| T12 | HDR 面板 + HDR 关闭 | 按 §1.7 裁决 | 旧：白 + tone-map |
| T13 | fallback 空集三种：无 SDR 轨 / 显式 require 下能力失败 / SDR 轨被拒 | 提示、不静默、不崩 | — |
| T14 | 旧 query / 旧点击被新 revision、options、target、dispose 淘汰 | 不发布、不 toast 成功 | — |
| T15 | 两个菜单 Widget 颜色、点击提示、状态刷新 | 与 eligibility 一致 | — |
| T16 | macOS 8K 原测试；非 Android 首次 false 回调 | 不变 | — |
| T17 | 保留：unknown-DV、P7、逐 codec 授权、C 冻结快照/共享等待、DV005 | 不翻转 | — |
| T18 | 点击成功时点 | 「画质已变为」在 `updatePlayer` 完成后 | 旧：早于开源 |

## 5. 范围边界（不做）
- media-kit 库、规划器、复核门、嗅探实现、DV005 通道零改动。
- L:1741 null→false、面板三态、`bindOutputView` 旧目标窗口：后续项。
- P:280-282 legacy unsupported request 停播路径：不改。
- 真实 open 失败后的旧源恢复：不做（播放事务设计另立项）。
- SDR 面板 tone-map：不做。
- 菜单 Widget 结构：不改（仅文案与刷新时点）。
- TASKS.md 长期约束节「App 画质选单的置灰逻辑应查询路由规划器可行性…」一句替换为公理 1-9（含 §1.7 裁决结果）。

## 6. 风险与回归面
- **断网 ≠ 嗅探失败**：同 revision facts 可能已缓存，`dvh1.08.07` 根本不嗅探。验收须用无缓存裸 hvc1 新 rendition 或受控失败注入，并证明本次确实等待并失败；断网后旧播放可能因缓冲耗尽自然停止，须与点击引发的 pause/teardown 区分。
- **SDR 面板的请求层效应**：probe 在 playurl 前影响 qn/tryLook，服务端可能不下发 HDR 档；真机验收写成「若当前 DASH 含 HDR 档则灰并提示」。
- **双事务**：面板事件后库 `hdr_video_session.dart:1457-1509` 自身可能重规划/重开，App 回调另开 SDR 的最终结果须经真实 Session 时序测试，不能只断言回调被调用。
- 删 P:718-722 的 SDR 档变白面；`_openAdmits` 若过严可能使 E1/E2 空集触发 `stopForRouteOptions`——T13 覆盖。
- 强制 `usesAndroidRouting=false` 的组合不等价于正常 Session（MainActivity 已删旧 probe handler），不以此宣称等价。
- menu 白、predict playable、`DV003_OPEN quality=126` 均不替代最终 HDR 激活、硬解、持续出帧。

## 7. 验收
**宿主**：4.2 全 PASS，T1/T3b/T3c/T4a/T5/T6a/T8/T11/T18 的修前反证记录（旧实现确实失败，同 seam）；既有 sniff/selection/unknown-source/route-options lifecycle/player lifecycle/eligibility/macOS 8K 套件 PASS；全量；analyze、diff-check。

**真机**（与 C 修正版同候选）：
| 设备 | 场景 | 要求 |
|---|---|---|
| marble / LG / LYA（HDR 面板） | `BV1uZ4y1U7h8`、`BV1vY4y1N7TY` | 126 白；点击开播 126 且「画质已变为」在开播后；证据链 `DOVI_SNIFF`→`predict source=…dolbyVision`→`DV003_OPEN quality=126`→`phase=applied`+SF/HDR 层+帧推进 |
| 任一 HDR 面板 | 受控嗅探失败（无缓存裸 hvc1 新 rendition / 注入） | 126 白；点击 toast 路由文案；当前播放零 pause/teardown |
| HDR 面板 + HDR 关闭 | 两视频 | 按 §1.7 裁决行为 |
| SDR 面板设备（ugg `a869cea9` / Mi Note 3 `5b79aada`，先 probe 确认 `displayHdrTypes` 空） | 两视频 | 若 DASH 含 HDR 档：灰 + 「当前显示器不支持 HDR 输出」；缓存 126 冷启动落 SDR + toast；SDR 轨正常播放 |

**审核等级：V2（Critical Reviewer）**。依据：改变 SDR 面板禁止 HDR rendition 的开源约束、HDR 关闭下的重开/降级行为、能力发布与降级事务、开源前失败不打断播放的不变量。若压缩为仅 §3.1 的纯展示切片可 V1，但不满足公理范围。

**顺序**：C 修正版（实施 → V2 → 真机）→ 本切片（同文件串行）→ V2 → 真机。只读分析与测试设计可并行，不允许两个 writer 同时编辑 P。

## 8. 裁决
- §1.7「HDR 关闭」语义：**X**（用户「按方案实施」采纳推荐方案）。

## 9. 实施记录（2026-10-17，与 §3 的差异，均经 V2 审定）
- **范围扩大（Lead 裁决）**：L（`lib/plugin/pl_player/controller.dart`）允许最小改动——新增 `RouteOptionsDecision { reopened, keepCurrent, superseded }` 回调契约、`applyRoutePreferences()` 改为「页面先决策 rendition → `superseded`/revision/_fsDisposed/identical 守卫 → `reopened` 跳过 `setOptions`、`keepCurrent` 且无已发布会话走 `ensureRouteSourceOptions` 否则 `setOptions`」。原因：原序先 `setOptions` 以当前 126 重开（toneMapSdr）再降 SDR，违反公理 4（V2 日志实证）。L 其余零改动（blob `d7a2b041…`）。
- **五入口统一 + 最终边界**：`_openAdmits`（HDR 档 = 面板 ∧ 未关闭（全平台）∧ Android 再叠加 `_routeAllows` + presentable）；`findVideoByQa` 过滤改 `_openAdmits`；**`playerInit()` 在 `setDataSource` 前施加最终准入**（覆盖 view.dart 首次手动播放/页面恢复、header_control 听视频切回、`editPlayUrl`），文件源/本地诊断例外。
- **共用兜底 `_pickFallbackSdrTrack()`**：非 HDR ∧ `_openAdmits` → `tracksEligibleForPlayback`（macOS 8K 门）→ 质量最大 → `findVideoByQa(requireConfirmedEightKHardware: true)` 定 codec；D/E1/E2/`playerInit`/冷启动统一；先选轨再写状态；空集明确提示或既有 stop。**行为变化**：E1/E2 当前 HDR 档被拒时只在合格 SDR 中兜底，不再横向切换到另一 HDR 档。
- `updatePlayer()` → `Future<bool>`（选源被拒 false；true 仅表示选源通过并完成初始化调用，不是播放成功收据）；D 的「已切换」仅在 true 且 isClosed/revision/当前档复核后发出。
- §3.6 的慢检测提示**移除**（toast 无所有权、可误关/吞提示），登记为后续 UX 项。
- 删 P:314 覆写、删 `_allowsHdrSourceAsSdr` 五处使用；`data` 改可空影子字段 + 就绪守卫（修复首次 false 面板回调早于 `data` 赋值的可达 `LateInitializationError`）。
- 测试：`test/pages/video/hdr_tier_menu_admission_test.dart` 44 用例（T1–T19、R2-a/b/c、B1×3、B2/B2(published)、B3-a/b/c/d/e、D-8K-a/b/c、E1-8K、E2-8K）；routing 平台谓词 seam、toast sink、HDR 回调绑定、`seedDecodeCapabilitiesForTesting` 等最窄注入点；修前反证相对「C 已落地（120a51aec）」基线、同 seam，证据 `/tmp/hdr_menu_prefix_evidence.txt`。
- **残余（未修，已登记）**：D 路径库侧 `hdr_video_session.dart:1457-1509` 自主重规划与页面降级的双事务竞态（需用户裁决库侧钩子或接受瞬态）；库 `setOptions` 总以新 options 重开当前 media（rendition 仍准入的设置变化有一次库驱动同档重开）；L:1741 null→false 与面板三态；`bindOutputView` 旧目标窗口；legacy unsupported request 停播路径；真实 open 失败后旧源恢复；音质/codec 菜单在重开被拒时的成功 toast 时点；E1/E2 空集 stop 分支与「当前 HDR 被拒、另一 HDR 可用、SDR 可用仍选 SDR」的锁定测试待补；真机矩阵待验。

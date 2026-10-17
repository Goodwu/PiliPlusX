# Android 直连导入路径使能方案 v8（MKSURF 桥 owner 授权）

日期：2026-10-13 · 分支：routing/MK-ROUTING-20261011 · 状态：v8（按第七轮复审三项剩余与两处整理修订，待第八轮复审）

修订记录：
- v1→v2：注入点/挂载条件/覆盖范围事实修正；token 原生契约；失败分类收紧；默认 false；验收矩阵重写。
- v2→v3：证明时点消歧（importer 创建前）；注入通道改既有 configuration 路径；事务入口/状态全映射；L1-L3；convert 规划期固定；BindTimeout 例外保留。
- v3→v4：R1 失败分类定稿（纠正 unsupportedStrategy 误述；MksurfBindFailure + stop 优先）；R2 L1 owner 级证明方向；R3 convert 五阶段与跨 Session 预算；R4 L2/L3 移交契约方向。
- v4→v5：第四轮"需第五轮"（R1/R3 闭合；T1 owner 证明接口契约定稿、T2 准入至 importer 创建、T3 L2 移交协议）。
- v5→v6：第五轮"需第六轮"（T1 闭合；T2 部分——create 凭据通道与跨线程协调；T3 部分——移交顺序与提交条件；U3 epoch 措辞统一）。
- v6→v7：第六轮"需第七轮收口"（①凭据→importer 链路与 ABI 拒绝策略 ②意图应用完成点 ③verify 布尔与 epoch 语义分离 ④最低验证四条）。
- v7→v8（本轮，按第七轮三项剩余与两处整理）：**C1 凭据快照冻结链**（verify 结果→事务不可变凭据→随输出创建下发→importer 创建时复制冻结→v2 create 对冻结凭据原子核对；旧实例不得借用后续事务凭据；缺凭据拒绝、禁止从桥当前绑定补齐）；**C2 意图版本化队列与应用屏障**（open 期间新增意图带事务 generation+序号入版本化队列，播放就绪点按序应用；提交前原子核对最新 generation 且无未应用意图；open 期间/完成前/提交边界的暂停/seek 均不丢失，superseded 不提交）；**整理**（标题/修订记录版本对齐；窗口销毁并入 epoch 事件枚举）。**T1 owner 证明接口契约定稿（纠正 v4 事实错误：`mkst_lc_verify` 现状只读 `lc->initialized`，owner 级验证是本轮需新增的桥导出，非既有能力；新增导出触及原生链，按 provenance 纪律走 build-mks-r1+V2）**；**T2 准入覆盖到 importer 创建提交或失败清理完成（消除 check-then-use 竞态），含两条最低反例**；**T3 L2 写成可实施移交协议（HdrSourceFacts origins/conflicts 保留规则、库级移交入口选型、暂停/位置采样点、提交与失败归属）**。R1（实现须保留 Session:785-803 全局 stop 检查先于 BindTimeout 例外的顺序）与 R3（方案层）维持闭合。

## 1. 目标与非目标

**目标**：为 PiliPlusX Android 建立 MKSURF 桥的 owner 授权、owner 级绑定证明与降级契约，使 HDR/DV PlatformView 拓扑的直连导入路由可执行、可降级、可验收；普通 SDR Texture 播放维持 copy 不变。

**非目标**：
- 不裁决 DV004 复核收敛语义；不改身份断言；不以重建 Session 绕过 DV004 阻断。
- 不实现完整 ACK/lease；采用 T2 的进程级串行准入最小机制（Phase 2 演进）。
- 不解除 experimental 策略门控（非 carrier 级隔离）。

## 2. 事实基线

1. 桥初始化唯一入口：`PlatformVideoView.setLgExperimentOwner(token, generation)`；Java 初始化异常仅记日志后继续——Surface 就绪 ≠ 桥 owner 就绪。
2. 原生现状（bridge.cpp）：`mkst_lc_verify(MkstLifecycle* lc)` 只读 `lc->initialized`，**无 tuple/incarnation 参数**；匿名命名空间；导出的 `mkst_ensure_init()` 即调用它。`mkst_lc_init/verify/create_gate/shutdown` 为生命周期族。单窗口；同 `(ownerKey, generation)` 幂等；存活期拒绝异 tuple；无窗口可重绑；shutdown 清空。**现有 create gate 只检查 initialized/window-active，不校验请求者身份**（T2 竞态依据）。
3. `HdrVideoSession` 构造已接受 `VideoControllerConfiguration`（:82-95）；`HdrOutputContract.controllerConfiguration()` 已保留 `lgExperimentOwnerToken`。缺口：app 会话工厂（player_lifecycle_ports.dart:27）未把 configuration 传入 Android 会话链。
4. 挂载条件：`usePlatformView && nativeHandle != null`。冷进程普通 SDR 走 Texture，无桥初始化入口。
5. 失败分类（Session:782-829）：身份变化、HdrPlaybackBlocked 禁止重试；`HdrOutputBindTimeout` 明示例外；非 BindTimeout TimeoutException 直接阻断；**全局 stop 检查先于 BindTimeout 例外（实现须保留此顺序）**。
6. `HdrSourceFacts` 维护字段来源（origins）与冲突（conflicts）状态（hdr_source_facts.dart:35-45,84-89）；Session 内部重开使用 `_openPlay`，非用户实际暂停状态（Session:405-432,718,1376-1384）。
7. 事件泵 isolate 独占 wait_event + API isolate 承载同步 FFI（不变量）。

## 3. 设计

### 3.1 绑定证明时序契约

- **时点**：每次执行尝试中、importer 创建前完成 owner 级绑定证明；Session.open 入口前不做等待。内部 retry/reopen 与跨 Session 替换同等遵守。
- **失效**：桥 shutdown、owner/generation 变更、窗口重建、bind epoch 推进后，旧证明失效。
- **失败处置**：按 3.6。

### 3.2 T1：owner 证明接口契约（新增桥导出，纠正 v4 误述）

**事实澄清**：现有 `mkst_lc_verify` 只返回 initialized 布尔，**不能**校验 tuple/incarnation——owner 级验证是本轮需**新增**的桥能力（小幅 additive C 改动，触及原生链：按 provenance 纪律走 build-mks-r1 + V2 门，与 mkst 生命周期族同处声明）。

新契约：
- **incarnation 归属**：`(ownerToken, generation)` 由 App 替换事务生成并推进。
- **bindEpoch 推进规则（U3）**：在绑定 tuple 实际变更、shutdown/清空、**或窗口销毁**时递增；同 tuple 幂等重初始化不推进（绑定状态幂等 ≠ 凭据失效，二者分离）。
- **验证导出（新增）**：`mkst_lc_verify_owner(ownerKey, generation, out bindEpoch) -> bool`——initialized 且当前绑定 tuple 匹配时返回 true 并带出当前 bindEpoch；调用方比对"自持 epoch == 当前 epoch"判定证明有效，不等即失效（含 shutdown/重绑推进后）。
- **失效事件**：shutdown、重绑（异 tuple 成功）、窗口销毁均推进 epoch 使旧证明失效——此时 verify_owner 布尔可为 true（tuple 仍匹配），但调用方自持 epoch 与返回 epoch 不等即判证明过期（布尔=身份匹配，epoch 比较=时效，二者分离）。
- **可观测**：Java `ensureInitialized` 失败从"仅记日志"改为可观测失败上报（L1 前置）。
- 查询经 API isolate 调用（不产生初始化，verify-only 语义不变）。

### 3.3 T2：准入覆盖到 importer 创建（消除 check-then-use）

进程级串行准入（单一线程 + 事务互斥，最小机制）的**保护区间 = ensureInitialized → lc_verify_owner → importer 创建提交（或失败清理完成）**，覆盖 init、迟到初始化回调、shutdown、create 四类事件：
- 区间内拒绝异 owner 的 init/create；
- 同 tuple shutdown→重初始化：bindEpoch 推进使旧证明失效，旧持有者的 create 请求被拒绝；
- 失败清理在区间内完成后方释放准入。
最低反例：A 验证成功未建窗口时 B init → 拒绝串用；同 tuple shutdown→重初始化 → 旧证明被拒；桥 shutdown 后复用旧输出 → 拒绝；能力通知与换源/settings 并发 → 单事务串行；清理失败后新 owner 不得进入；同源终止性失败不得被自动 refresh 清空阻断。**v7 增补四条**：异 owner 不借用当前绑定；旧新 ABI 混配拒绝（旧 importer+新桥、新 importer+旧桥均失败关闭）；同 tuple 重绑后 verify 成功但旧 epoch create 失败；open 等待中暂停/seek 不丢失且 superseded 不提交。

**U1 create 凭据通道落地（含 ABI 版本化）**：
- 传递链：Java `setLgExperimentOwner(token, generation)`（桥记录 ownerKey+bindEpoch）→ 路由应用时 media_kit 将 `(ownerKey, generation, bindEpoch)` 作为 mpv 选项随输出创建下发 → hwdec_surfacetexture 驱动持有该凭据 → 创建窗口时传入桥。
- 原生签名：**版本化新符号 `mkst_create_decoder_window_v2(ownerKey, generation, bindEpoch, ...)`**（旧无参符号保留但改为失败关闭：无凭据一律拒绝），在桥生命周期锁内原子核对——当前绑定 tuple 与 epoch 均匹配才创建；异 owner、窗口存活期、epoch 过期一律拒绝。
- 旧新组合失败关闭：旧 importer（无凭据）+ 新桥 → 走旧符号 → 失败关闭；新 importer + 旧桥 → v2 符号解析失败 → 失败关闭。mpv 与 bridge 的配对纳入双方 provenance。
- 请求身份经 Java `ensureInitialized/setLgExperimentOwner` 既有通道到达桥，create 凭据由该通道下游透传，不新增第二套身份体系。

**U1 跨线程协调（限定）**：Dart 侧由替换事务串行化各次尝试（同一时刻至多一个事务持有准入）；native 侧 create/shutdown 维持 mpv GL 线程契约（bridge.cpp:34-45，不迁往 API isolate）；桥生命周期锁内的原子校验不等待任何长操作——准入失败立即返回错误，由事务决定降级/阻断，杜绝"持桥锁等另一线程 create"。

**C1 凭据快照冻结链（⑦细化）**：①`mkst_lc_verify_owner` 成功 → 替换事务捕获**不可变凭据快照** `(ownerKey, generation, bindEpoch)`；②快照随输出创建作为 mpv 选项绑定到**该次 Player/output attempt**；③importer 创建时**复制并冻结**快照（此后桥侧 epoch 推进不影响已冻结副本）；④`mkst_create_decoder_window_v2` 对冻结凭据在桥生命周期锁内原子核对（tuple+epoch 与当前桥状态均匹配才创建）。旧 importer 实例不得借用后续事务更新的凭据（冻结即隔离）；**快照缺失 → 拒绝创建，禁止从桥当前绑定补齐或借用身份**。

### 3.4 T3：L2 可实施移交协议

- **移交入口选型**：库级移交（Session 公开 `handoverFrom(previous)` 快照接口）——选定此路线；不从源重新采集 facts（源已消费、行为不可复放）。
- **HdrSourceFacts 保留规则**：origins/conflicts 随快照整体迁移（字段级来源与冲突是复核与报告的既有输入）。
- **证据分类**：迁移=源级证据（path/entry/epoch、headers、hint、options、位置、播放状态、facts 快照）；**清空重取**=decoder/output 身份证明（hwdec-current、pixelformat、mediacodec-info、绑定证明）在新执行尝试中重新取得。
- **移交顺序（U2 定稿）**：①事务起点采样（player 实际暂停/位置，非内部 `_openPlay`）→ ②旧会话关闭 + 旧窗口 shutdown（epoch 推进，旧证明失效）→ ③新会话绑定（新 tuple，epoch 推进）→ ④新 open 以恢复态为入参（start=采样位置、play=采样播放态）→ ⑤当前事务 + 显式成功结果方提交。
- **提交条件（U2）**：`OpenSuperseded` 正常返回**不算成功**（Session:617-621）；提交 = 当前事务仍是最新 generation 且 open 以明确成功完成。失败（异常/超时/被取代）不提交，按预算与失败分类处置。
- **等待期间用户操作（C2 版本化队列）**：归属新会话的排队意图——open 期间新增的暂停/seek 携带事务 generation+序号进入**版本化意图队列**，在新会话播放就绪点（playback-restart/首帧前）按序应用；**应用完成屏障**：提交前原子核对当前事务 generation 与已应用意图版本一致、无未应用意图方可提交——open 启动后、完成前、提交边界注入的暂停/seek 均入队列不丢失；superseded 事务的队列整体作废不提交。
- **失败归属**：旧会话终止性失败记入事务预算（不因 Session 替换清零）；pending/current intent 由事务对象持有并按 generation 拒绝旧发布。
- **L3 能力通知**：能力快照随事务传递，能力变化触发同一串行事务的一次替换；验证暂停重建不自动播放、旧回调不能提交、同源终止失败与预算不因 Session 替换清零。

### 3.5 convert 冷启动时序（R3，维持 v4 闭合结论）

预备输出（挂载）→ owner 绑定（ensureInitialized + `mkst_lc_verify_owner` 证明当前 tuple/epoch）→ 冻结最终 carrier/offscreen 契约 → 必要重建与新 tuple 再绑定（经替换事务）→ importer 创建（准入区间内）。无证明 → convert 直连候选不进计划；预算归属事务对象，耗尽显式降级/阻断。

### 3.6 失败分类表（R1 闭合，维持 v4）

| 失败 | 处置 |
| --- | --- |
| `MksurfBindFailure`（未授权/绑定拒绝/证明失效） | 可归因：`allowAlternatives` → 排除直连候选降级 copy/no；`stop` → 阻断（stop 优先） |
| `HdrOutputBindTimeout` | 既有明示例外：可排除 PlatformView 候选后降级（不改） |
| 身份端点变化 / HdrPlaybackBlocked | 阻断，禁止重试/重建绕过 |
| 普通超时（非 BindTimeout） | 停止、清理、阻断——不重试不猜候选 |
| 就绪中抖动 | 就绪容忍重试（窗口 8s） |

实现顺序约束：保留 Session:785-803 全局 stop 检查先于 BindTimeout 例外的既有顺序。三类注入验证照旧。

## 4. Phase 1 范围与顺序

1. 桥导出扩展（T1 C 改动）+ provenance 纪律（build-mks-r1 + V2）；
2. L1-L3 契约实现（含 T2 准入区间、T3 移交协议）；
3. 可控事务骨架先行（跨会话准入、shutdown 屏障、失败保留、旧 generation 拒绝发布），后接 direct；
4. 默认维持 false；十条反例（§3.3 六条 + v7 增补四条）+ 三类失败注入 + 真机矩阵 + Reviewer 独立检查闭合后，另步决定 true。

最小反例：A 验证成功未建窗口时 B init → 拒绝串用；同 tuple shutdown→重初始化 → 旧证明拒绝；桥 shutdown 后复用旧输出 → 拒绝；能力通知与换源/settings 并发 → 单事务串行；清理失败后新 owner 不得进入；同源终止性失败不得被自动 refresh 清空阻断。

## 5. 真机验收矩阵

沿用 v4：冷进程 SDR 首播（copy）、冷 HDR 首播（直连+证明先行）、HDR→SDR、退出重入，开关 on/off；marble 默认 HDR 路由与显式 convert/reshape 分开验；真无 HDR 目标播 HDR 内容验 tone-map/阻断（能力以新快照为准）；direct 可恢复→copy→no 与身份/超时→阻断分开注入；快速换清晰度、暂停重建、后台恢复、能力变化、重叠会话拒绝；Release 零新增 ANR/FATAL、持续可见帧、seek/重入；呈现级证据。

## 6. 审核

- v1：第一轮"必须修订"（7 项）→ v2。
- v2：第二轮"需第三轮"（A/B/C + BindTimeout + convert 协议 + Phase 1 固化）→ v3。
- v3：第三轮"需第四轮"（R1-R4 范围锁定）→ v4。
- v4：第四轮"需第五轮"（R1/R3 闭合；三项剩余：T1 owner 证明接口契约——纠正 `mkst_lc_verify` 既有能力误述、T2 准入覆盖至 importer 创建、T3 L2 可实施移交协议）→ 本 v5 全部采纳。
- v5→v6：第五轮"需第六轮"（T1 闭合；T2 部分闭合——create 凭据通道与跨线程协调未落地；T3 部分闭合——移交顺序与提交条件未定；epoch 措辞须统一）→ v6 采纳 U1（create 凭据通道与跨线程协调）、U2（移交顺序与提交条件）、U3（epoch 幂等与失效分离）。
- v6→v7：第六轮"需第七轮收口"（①事务凭据→importer 实例→create 链路与 ABI 拒绝策略 ②删除提交点采样旧句、定 open 期间意图应用完成点 ③verify 布尔与证明 epoch 语义分离 ④最低验证四条补齐；另文档头版本滞后整理）→ v7 全部收口。
- v7→v8：第七轮"通过进入实施"（C1 凭据快照冻结链、C2 意图版本化队列与提交屏障闭合，无新增阻断；§6 重复记录已整理）。实施关键检查点（5 项）：①延迟旧 importer 至新凭据下发后再 create，验证仍用旧快照并拒绝；②三边界（open 启动后/完成前/提交边界）注入暂停/seek，按 (generation,seq) 核对应用进度，入队与检查-提交共享串行边界；③意图应用失败、superseded、清理失败均不得提交或释放错误准入；④独立复验 ABI 混配、epoch 失效、stop 优先、原生 provenance/V2 门；⑤默认 false，同候选真机矩阵通过后另行决定开启。

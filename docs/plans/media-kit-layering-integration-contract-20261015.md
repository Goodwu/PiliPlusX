# PiliPlusX：media-kit 分层解耦对接契约

契约 ID：`MK-ROUTING-20261011/LAYERING-20261015-r1`。日期：2026-10-15。
状态：后续实现与验收要求已记录；不是普通 YUV owner、当前原生包或真机验收完成声明。本次仅修改文档。

## 1. 唯一规范与适用范围

库侧规范为 [受管 YUV 输出：分层解耦与生命周期设计约束](https://github.com/Goodwu/media-kit/blob/routing/MK-ROUTING-20261011/docs/plans/managed-yuv-layering-contract-20261015.md)。本文承接其 L01—L12，定义 App 责任与测试映射，不重复定义 owner 协议、设备策略或 C1—C4 候选表。语义冲突以库侧该版本约束为准，并同步修订两仓，而非在 App 增加临时旁路。

继续原 `routing/MK-ROUTING-20261011` 分支、PiliPlusX PR #1 和 media-kit PR #4；接续 [初始集成计划](app-media-kit-2276715-integration-20261015.md)、[C4 后续交接](app-pq-carrier-followup-20261015.md)。历史文件中的 SHA、pending 和测试数字只属于其记录时点；下一接手须读实际 refs 与最新 PR 回执。

观察基线：App `3bd3a07b1a214a6789791b266624c6ddc080932d`、库 `c7247139ee2865ae43f8d0663fc77a1aa8baea91`。已有无 Player 查询、逐 DASH 选源、不可变选项、Session/报告、静态兼容标签及 C4 无载体修复不得重新开发。库普通调用缺 owner 的错误仍是未完成资源协议的真实阻塞，不能靠 App 传实验 token 消除。

## 2. App 只表达业务意图（对应 L01—L04）

App 继续提交准确的片源事实/来源、VideoSourceSpec、VideoOutputTarget 和有效播放选项；查询、DASH 选择、NetworkSource、Session 执行及报告保持同一源/目标/选项及 revision 归属。保留慢查询、换源、换屏和配置 revision 的过期结果保护，不以旧全局快照兜底。

App 负责普通视频视图的挂载、更新、卸载及使用库提供的 controller/listenable；无需额外的厂商初始化步骤。播放设置可以要求输出或解码方式，但不承载临时资源、运行期授权或安全释放凭据。

禁止在普通路径新增以下行为：

| 禁止项 | 正确归属或处理 |
|---|---|
| 自动生成、传递或持久化 lgExperimentOwnerToken/owner/lease；伪造 routeLocked/acceptNonConformant | 库的 backend/输出生命周期建立真实授权，实验身份不能当业务参数 |
| SDK/机型/指纹白名单、config49 判断、另一张 C1—C4 表 | 能力/候选由库决定；精确厂商安全检查在具体实现 |
| 调用 vendor MethodChannel、JNI/FFI arm 或 bridge 初始化 | 库的受管输出协议，App 不补库侧缺口 |
| 从 prediction/report/event listener 启动异步预 arm 或触发厂商资源准备 | 报告用于消费/展示，不是可等待的执行屏障 |
| 处理 Surface 句柄、资源身份迁移、释放 ACK、进程锁、cleanup debt 的底层重试 | 库内完成并返回明确结果；App 不盲目并发重开绕过错误 |
| 用诊断页面、特定 define 或手工预热作为正常播放前提 | 关闭诊断的普通入口必须参加正向验收 |

受控测试替身可注入能力、延迟和故障，但不得将伪能力、假 ACK、实验 token 或旧二进制带入普通运行路径。删除开关也不等于删除路由必需的执行参数；由库根据实际路由设置。

## 3. 库侧交付边界与 App 的依赖（对应 L05—L11）

库侧必须复用现有 Surface 身份和释放协议，把运行期授权与不可变输出要求分开；通用接口由输出层定义，vendor 实现单向依赖接口，Session 只编排通用事务。不得只把实验 API 改名或给普通配置填 token。

首次打开要建立真实 owner、准备 ACK 与激活屏障；初始 dataspace、bridge、EGL/VO 的实际顺序由库核实，不能要求 App 延迟挂载或提前调用厂商 API 来解循环等待。App 不依赖某个 SurfaceAvailable 回调就是安全 arm 点这一未经验证的假设。

重开、候选重试、review-reopen、设置/显示变化、HDR↔SDR、全屏/前后台导致的 Surface 重建和 dispose 必须由同一库协议处理。有效输出可复用，不把每次 open 强制重建变成 App 规则。旧 callback/旧 cleanup 不影响新源，清理失败保留欠账及阻塞，App 不强制清账。

全局 native arm 的进程初始化限制仍可能存在。分层接口完成不等于任意多窗口并发隔离；冲突由库明确返回，App 不能自己维护另一把锁，也不能因一个 engine 缺插件推断全进程无冲突。多个普通 controller/Session 的受支持并用范围须有实际测试或明确限制。

本工作包主要在 media_kit_video、Android 输出实现、vendor 呈现实现及必要 bridge 接口完成；不预设修改通用 Player、FFmpeg/mpv/libplacebo 或重写 Darwin/OHOS。App 仅进行已证明必要的公共接口消费、依赖更新和测试；若需要扩大底层范围，记录证据后同步库侧方案。

## 4. 错误、回退与结果展示（对应 L02/L07/L09/L12）

`yuvWindowArmUnavailable` 不应被 App 吞掉、伪装成功或通过补 token 绕过。目标是库自动建立授权，真正的实现缺失/预约/绑定/arm 失败仍有结构化阶段、原因和 cause；并发冲突、过期请求与清理失败不能伪装成永久设备不支持。

设备能力声明、计划可执行、准备完成、Surface 绑定、decoder 复核及实际呈现分别理解。App 只根据库实际报告展示状态；没有实际呈现证据，不因 route prediction、opened、bound 或 channel ACK 显示已验证。报告不持久化裸指针、原始 token 或释放凭据。

整个项目仍使用同一套实验性候选和默认路径；不得新增功能启用开关或生产/实验可行集。HDR 失败不隐式转 SDR；用户明确 HDR off/require SDR 属于独立请求，冲突和未知源事实按原契约处理。HDR10+/Vivid 本期仅静态 PQ/HLG 兼容，动态 C1/C2/B1—B4 保持延期；静态兼容成功不能展示为动态映射成功。

## 5. App 必需验收与库侧映射

下表是待落实的验收标准，不是本次已新增或执行的测试。可以复用、补强既有用例，不以重复计数制造覆盖。每行后续登记实际测试文件、源码组合、命令/退出码、CI run/head 和产物/设备证据。

| App case ID | 库侧对应 | 验收要求 |
|---|---|---|
| APP-L01 | L-A01/L-A03/L-A04 | App 普通路径无 vendor/owner/arm 依赖；替换测试呈现实现不改 App/Session；无 vendor 时无关路径仍可用 |
| APP-L02 | L-A02/L-A05 | query→DASH→NetworkSource→Session→report 源/目标/options 一致；慢查询、换屏/换源丢弃旧结果，查询不分配运行资源 |
| APP-L03 | L-A06/L-A07/L-A15 | 普通公开入口无 token、无诊断预热的 YUV 冷开正向成功；以真实注册/准备/激活证据验收，而非只运行 forTesting/实验页 |
| APP-L04 | L-A08/L-A09/L-A10 | 同 session HDR→SDR→HDR、设置变化、重复 open、切源、Surface 重建/全屏及 dispose；不触发实验 single-open，旧回调不替换新源 |
| APP-L05 | L-A07/L-A08/L-A11 | 准备/绑定/bridge/arm/VO 故障、延迟或丢失 ACK、timeout 与 cleanup debt；错误可见，无假成功/无主 arm/盲重开 |
| APP-L06 | L-A12/L-A13 | 非 YUV 路径零 arm；多 controller/session/engine 冲突及支持范围可验证，App 无自建全局锁 |
| APP-L07 | L-A16 | 未实现、并发拒绝、源未知、静态兼容、失败报告准确；不隐式 HDR→SDR，不显示动态或面板验证假成功 |
| APP-L08 | L-A14/L-A15/L-A16 | 最新适用源码与完整原生输入联合编译；普通 App 安装包和实际设备完成冷开/重建/恢复/PQ与持续性能验收 |

负向用例正确返回缺 owner/缺实现错误，只证明失败传播正确，不能算 APP-L03 正向完成。mock 能力/ACK、源码 bundle、实验页成功、历史绿色 CI 都不能替代普通安装包和设备结果；skip、缺样本、缺设备保持未完成。

源码验收继续使用严格 analyze、全套 Flutter/Python、Web DOM/编译、Linux/Windows/macOS 源码 bundle 与实际 package roots/freshness。原生 JAR/so 来源、APK 成员/ABI/签名、Android-Pink parity、设备 HDR 与性能分别记录；文档提交不修改 accepted ledger，也不代表发布条件已满足。

## 6. 提交与交接规则

库实现完成相应接口后，再把 App 依赖和必要调用更新到当时最新适用源码；不为本次纯文档修改追改依赖锁文件。测试版不固定在上述阅读基线或借旧 JAR，单次构建捕获精确输入并前后核验，SHA 只用于来源追溯。

每次接续先读两仓 refs、当前契约版本、原 PR 最新回执和本地 dirty，再对照已实现与待验收项。保留已有配置、选源、Session、报告、C4 无载体回归，不另开分支重复开发。新增接口需求先更新库侧规范/测试映射，不在 App 悄悄补设备规则。

本次状态：仅落盘与建立文档入口，普通受管 owner、完整原生产物、安装包及设备级验收未因本文发生改变。旧计划/回执保留为历史，不将其 pending 或通过数字当作新候选结果；没有合并 PR 或发布 Release。

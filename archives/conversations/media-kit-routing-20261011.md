# MK-ROUTING-20261011 App

## Current State

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

## History

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

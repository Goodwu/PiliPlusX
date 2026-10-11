# MK-ROUTING-20261011 Android/Pink native 输入门

本门用于 routing 任务的 arm64 Android/Pink JAR 前置检查和 APK 后置检查。现有 `verify_artifact.py`、插件 ABI/parity、安全、源码新鲜度和设备验收门继续执行；这里不代替它们。本阶段接入 Build 的 Android/Pink 作业与最终 parity 作业；实际 GitHub 执行仍须独立验收。初始 `routing-native-accepted-inputs.json` 的 `entries` 为空，DV001 `1095a43` 以及历史发布 JAR 均未获此门授权。

## 信任边界

DEVICE 提供 manifest 和附件。CORE 根据真实完整构建记录审核来源、补丁、干净 staging、最终库成员和链接来源，随后在本仓受审提交中新增接受记录。manifest 不能用 `reviewStatus` 或其他自报字段授权自己，未知字段会拒绝。

接受记录绑定 manifest **原始文件字节** SHA-256、source closure SHA-256、producer repository/run/attempt/artifact ID、最终 JAR SHA-256 和中央 PR #4 审核链接。记录不允许由下载附件、环境变量或 CLI 的任意文件替换；CLI 只读取本仓固定账本。调用者须使用可信源码 checkout，并用现有 bootstrap/source gate 校验本仓和账本没有被输入制品覆盖。本门的 JSON 相等/hash 一致只能说明与已审输入一致，不能凭此自行证明实际编译来源。CORE 未审真实附件就不得登记接受。

consumer App/Dart media-kit SHA 单独记在回执。它们由现有 bootstrap/source freshness gate 确认；本门检查 SHA 格式，不自行证明 checkout 来源。SO 的 native 闭包是 FFmpeg/mpv/libplacebo/helper/recipe/toolchain，不要求仅有 Dart 文档变化就重编 SO。native 来源或适用补丁变化必须重新构建、重新审核，不沿用旧接受记录。

## Manifest schema 1

JSON 顶层字段恰为 `schemaVersion`（整数 1）、`task`（`MK-ROUTING-20261011`）、`platform`（`android`）、`artifact`、`components`、`toolchain`、`staging`、`linkInputs`、`evidence`、`members`。重复 JSON key、未知字段、缺字段拒绝。所有摘要为小写十六进制；commit/tree 为完整 40 位，SHA-256 为 64 位。下面是字段说明，不是候选输入。

| 字段 | 必需内容 |
| --- | --- |
| `artifact` | `kind: jar`、JAR basename `name`、`sha256`、`identity`。identity 恰为 `repository`（Goodwu producer）、正整数 `runId`、`artifactId`、`attempt`。下载身份须由 CORE 核验，不能仅相信 manifest。 |
| `components` | 恰为 `FFmpeg`、`mpv`、`libplacebo`、`helper`、`recipe` 五项；每项含明确 GitHub `repository` URL、`commit`、`tree`、`sourceEvidence` ID 和 `patches` 数组。 |
| `components.*.patches` | **有序** `{path, sha256, evidence}` 列表；明确无补丁才可为空。patch path 唯一，实际补丁附件 hash 与列表 hash 一致。source evidence 必须证明实际使用的 tree/dirty/适用补丁，而非另一个干净仓库的 HEAD。 |
| `toolchain` | `ndkVersion`、`ndkSha256`、`compilerVersion`、`compilerSha256`、`sysrootSha256`、`evidence` ID。版本与摘要非空，实际工具/NDK 来源由附件审查。 |
| `staging` | `cleanEvidence`、`membersEvidence`、`linkEvidence` ID，分别绑定清理/重新建 staging 记录、最终 JAR 库成员记录、真实链接来源/命令记录。不能用文件存在代替这些记录。 |
| `linkInputs` | 非空有序 `{component, path, sha256}` 列表；component 属于五组件或 `toolchain`；至少覆盖 FFmpeg、mpv、libplacebo、helper、toolchain；component/path pair 唯一。实际对象/静态库来源必须由 link evidence 审查，不从 SO strings 猜源码。 |
| `evidence` | 非空 `{id, path, sha256, kind}` 列表；ID/path 唯一；kind 为 `source`、`patch`、`toolchain`、`staging`、`members`、`link` 或 `weak-import-contract`。所有引用必须存在且 kind 匹配。附件按给定根目录读取，不允许 symlink、绝对路径、`..`、反斜线或驱动器路径。单附件上限 64 MiB。 |
| `members` | 恰为以下三路径，每项恰有 `sha256`、`buildId`（实际 ELF Build ID，非空 8–128 hex）、`soname`（与 basename 相同）、非空唯一有序 `needed` basenames、`elfClass: 64`、`machine: 183`。 |

JAR 三文件路径固定：

- `lib/arm64-v8a/libmpv.so`
- `lib/arm64-v8a/libmediakitandroidhelper.so`
- `lib/arm64-v8a/libc++_shared.so`

JAR 可有 `lib/`、`lib/arm64-v8a/` 目录项，其他文件/目录、重复项、路径穿越、symlink、加密 ZIP 均拒绝。archive 压缩文件上限 1 GiB，条目上限 100000，单条解压上限 256 MiB，JAR 总解压上限 384 MiB（APK 1 GiB），大于 1 MiB 的条目压缩比例超过 250 拒绝。所有 JAR/APK 合法成员（含额外插件和资源）均以有界流读到 EOF 检查 CRC/解压及实际尺寸，不能仅读取三个目标库；ZIP CRC/decompression 错误不忽略。

source closure 为如下对象的 UTF-8 canonical JSON SHA-256：只取 `components`、`toolchain`、`staging`、`linkInputs`、`evidence`、`members`，keys 排序，分隔符 `,`/`:`、`ensure_ascii=True`；数组顺序保留。原始 manifest SHA 同时绑定其完整字节和下载身份，不能只比较 closure。

## CORE 接受账本

顶层恰为 `schemaVersion: 1`、`task`、`selectedManifestSha256`、`entries` 数组。选择器为 null 或唯一已审记录的 manifest SHA，不按名字、时间或最新制品猜选。当前选择器为 null、entries 为空；获取命令在任何 API、下载和 Gradle 之前以 `missing-accepted-native-input` 失败并写回执。旧版三字段空账本也安全失败；旧版非空账本缺选择器拒绝，不能自动选择。每条恰含：

- `manifestSha256`、`sourceClosureSha256`、`artifactIdentity`、`jarSha256`。
- `acquisition: {jar, evidence}`：A/JAR 与 B/manifest+附件各含 `repository`、`runId`、`attempt`、`artifactId`、`name`、`zipSha256`、`producerHeadSha`、`uploadJobId`，不允许额外字段。两项须同 repository/run/attempt/producer HEAD，artifact ID 不同；A 的身份须等于 `artifactIdentity`，producer HEAD 须等于 manifest recipe commit。A 先上传 JAR、B 后上传带 A 身份的 manifest/附件，B 的身份只记在 CORE 账本，避免 manifest 与自己的 ZIP hash/ID 循环依赖。
- `approval: {reviewUrl, coreCommit}`；reviewUrl 为 Goodwu/media-kit PR #4 的具体 comment/review，coreCommit 为已审证据完整提交 SHA。链接存在及审查充分性由 CORE 登记时核实，本门不把符合 URL 格式当作远端审核通过。
- `allowedWeakVulkanImports`：从三成员路径到明确符号名数组的 map；未列出的路径/符号不允许 weak 导入。只能列 `vkGetPhysicalDeviceProperties2`、`vkGetPhysicalDeviceQueueFamilyProperties2`，不允许 duplicate。
- `weakImportEvidence`：无 weak 允许集时必须 null；有允许集时必须指向 manifest 的 `weak-import-contract` 附件。CORE 必须先审核该实际输出拓扑/不会调用弱函数的契约，不能仅允许 weak 以制造通过。

两项 Vulkan 目标逐项检查。任何 strong undefined (`U`) 均拒绝；weak undefined (`w`/`v`) 只有已审契约明确授权才接受。即使只有 QueueFamilyProperties2 存在，也不能漏检。本门不改写二进制、不执行弱化工具。

## 二进制工具与回执

ELF 先检查原始 magic/class/endianness/type/machine，再通过明确传入的 GNU/LLVM `readelf` 和 `nm` 读取 header、notes、dynamic、undefined symbols。每次命令真实 exit code、stdout、stderr 记入回执；启动失败/timeout 的 exitCode 为 null，保留 error，不能记成 0。工具非零退出、成功退出但 stderr 有诊断（例如 `no symbols`）、不可识别输出、缺/重复 Build ID、SONAME/NEEDED 不一致均失败。另以 `readelf --dyn-syms --wide` 要求唯一完整 `.dynsym` 表、声明数与顺序行数一致、合法 null entry，并与 `nm` undefined 集合交叉核对；无法读取动态符号表、表不完整或两工具集合不同均不能推断 absent。清除 ELF section headers 的合法运行库若当前工具无动态符号读取能力，明确失败关闭，不把 `nm` exit 0 空输出当作不存在强导入。`nm` 空输出只有在可读完整动态表也证明无导入且两工具无诊断时才可接受；不使用 pipeline/grep 把工具失败当成 absent。

APK 后置门重新执行完整 JAR 前门，并将 APK 的上述三个成员与已审 JAR 逐字比较。其他插件 `.so` 可存在，但必须位于规范 `lib/arm64-v8a/`，并继续调用现有 ABI 校验；其他插件的 provenance/parity 由原有门另验，不能由本门扩大通过范围。

```bash
python3 scripts/verify_routing_native_inputs.py \
  --jar "$NATIVE_JAR" --manifest "$NATIVE_MANIFEST" \
  --evidence-root "$NATIVE_EVIDENCE_ROOT" \
  --app-commit "$APP_SHA" --media-kit-commit "$MEDIA_KIT_SHA" \
  --readelf "$NDK_BIN/llvm-readelf" --nm "$NDK_BIN/llvm-nm" \
  --receipt "$RUN_DIR/native-input-before.json"
```

APK 构建后增加 `--apk "$APK"` 并使用另一个 `--receipt` 路径。命令失败必须传播，上传失败回执供审查，但不得上传为 accepted candidate。前门应在 Gradle 默认 JAR 下载/输入替换之前运行，缺已审 JAR、manifest、附件或记录直接阻断；不能回退发布 JAR。

回执含实际 `stage`、`status`、失败 `reason`、consumer 向量、native 闭包/下载身份、命令记录和成功核验的成员；只有接受记录匹配且二进制（后门还含 APK）检查完成才有 `nativeVerified: true`。`deviceVerified` 永远 false。输入 schema/安全/工具/接受失败不代表设备问题；native 输入通过也不证明 native 构建过程全栈正确、安装、HDR 或持续性能通过。

## 实际获取、变体与工作流闭环

`acquire_routing_native_inputs.py` 只读本仓固定接受账本，使用现有 `GH_TOKEN` 能力调用 GitHub API，按已审 artifact ID 获取元数据和 ZIP；API 权限不足或缺字段直接失败，不寻找其他 token 或历史 JAR。元数据须匹配精确 ID/name/run/HEAD、未过期、ZIP SHA-256 digest 和正数大小。GitHub artifact 元数据没有直接的 attempt 字段：本门读取指定 run 的指定 attempt jobs（有界分页），要求唯一已审 uploadJobId 是该 run/attempt/HEAD 的成功完成 job，artifact created_at 位于该 job started_at 与 completed_at 之间。此联合证据与 CORE 已审记录绑定，不能声称 API 直接提供 artifact attempt。

下载用 `gh api` 子进程流式写入 RUNNER_TEMP 新建私有目录，stdout/stderr、大小与超时有界；记录真实退出码，不打印 token。ZIP 字节数和 SHA 与已审记录和元数据逐项一致后，逐成员完整 CRC/解压校验，再安全解包；禁止 duplicate、symlink、加密、穿越、超限、覆盖源码或账本。A 恰含一个 JAR basename，B 恰含 `manifest.json` 与 manifest 声明的 `evidence/` 附件。随后执行完整 native 前门；未成功时不给工作流 local JAR 输出。

Build 的 `routing-vector` 在开始时捕获一次 App 和当前 media-kit 精确 HEAD，将同一组合传 source reusable、Android 与 Pink；source reusable 收到 library SHA 后使用该值。原有真实 routing bootstrap、SDK 补丁链和源码门继续执行。`prepare_android_variant.py` 从精确 App Git blob 核对 tracked 原字节，在私有目录生成普通/Pink 副本；Pink 仅执行固定文件/固定次数的 package/constants transform，记录所有 tracked 文件 before/after hash，原 App 不改。通过可信 media-kit sibling 链接保持原 path override/锁文件字节，独立执行 `flutter pub get --offline --enforce-lockfile`；十包来源与所有外部 package roots 一致，只有 App root 移动，并验证 HDR channel。finalize 复验原字节、固定变体字节、完整文件树和 package roots。V2 指出旧快照仅扫描 Dart/Kotlin/Java 后缀，新增 XML/asset JSON/shader/JNI 未拒绝；本修正默认拒绝原 base 与副本中的任何未知文件或目录，所有 tracked 文件逐字对应确切 Git blob/固定 Pink 变换，不依赖后缀或 `.gitignore`。

生成物例外使用 helper 中的精确 `PUB_GENERATED` / `BUILD_GENERATED` 文件集合，包含 pub package 配置/固定平台 registrant，以及实际 Flutter Android 工具维护的 plugins dependencies、local.properties、Gradle wrapper、单一 Android GeneratedPluginRegistrant.java；不允许同目录任意新文件。pubget 结束后记录前门完整清单和 hash；实际 Flutter build 之前运行 `--check-prebuild` 再验，任何新增/改变输入先阻断。pubget 固定文件在 build 后仍须一致；仅明确 Android build 工具生成文件可在该生命周期更新，并记录 `finalGeneratedHashes`，finalize 必须有前门标记。

只有 `build/`、`.dart_tool/flutter_build/`、`.dart_tool/dart_build/`、`.dart_tool/hooks_runner/`、`android/.gradle/`、`android/.kotlin/` 可作为明确构建产物目录，在副本 prebuild 时禁止存在，build 后不作为编译来源白名单。非 regular 文件和未精确授权的 symlink 拒绝。pubspec 不能将这些位置或 pub 配置声明为 assets/fonts/shaders/deferred assets（含真实 YAML 解码、URI 解码、inline collection、anchors 和归一后的 `../` 路径）；tracked 输入不能落在保留生成物位置。Android/Gradle/CMake 新的 source/native override 若与保留生成位置重叠，需明确合同审核，当前失败关闭；不凭目录名含 `.generated` 放行 assets 或原生链接输入。这是本仓当前布局的有界合同，未来 Flutter/Gradle 如新增合法工具输出，必须审查其位置/生命周期后扩展精确集合，不能通配全部新文件。

routing lock/ref 模式是显式合同，默认 production 的 immutable git pin 和 metadata 验证保留。routing lock 必须与精确 App HEAD 的 `pubspec.lock` blob 逐字相同，不能仅相信 receipt 中的 hash；逐一核对十个路径依赖、media-kit HEAD、变体身份和 package roots。workflow ref 门检查本仓三份具体 workflow 的实际 gate 顺序与必要参数，Actionlint 另验 YAML/表达式/shell。

实际构建使用 `flutter build apk --release --split-per-abi --target-platform android-arm64 --android-project-arg=mediaKitLocalArm64Jar="$VERIFIED_JAR" --android-project-arg=mediaKitArm64Only=true --no-pub`。构建后执行 native APK 门、原 ABI 门、apksigner，再分别 finalize 变体与原 bootstrap/newness；只有成功才上传 `routing-android-staging` / `routing-pink-staging` 构建材料。它们有明确 `pending-parity=true`、consumer 向量和 `deviceVerified=false`，不是候选。失败回执单独以 diagnostics 上传。

最终 parity 作业只按这两个上游作业的 artifact ID 取同 run 材料，保留原 `verify_android_native_parity.py`，要求精确布局、已 finalize 的变体、fresh-source-only bootstrap 和一致 consumer/selection。还会重新获取已审 A/B 并复验两份 APK 的 JNI 字节、ABI 和签名；最后核对两仓远端仍是捕获组合。全部通过才上传明确的 `routing-*-candidate-*`；routing 不上传 production artifact，不发布 Release。未通过 parity 时保留日志与向量。单独 Pink dispatch 在 routing 分支缺少 Build 捕获模式时显式失败，不能进入生产下载路径；生产发布的既有 contents 写权限保留。

原 parity 门目前比较所有 `.so`，包含 App AOT `libapp.so`。Pink 的合法 Dart 常量变换可能改变其字节，这是尚待独立审核的合同缺口：未来需明确区分 producer/shared plugin native parity 与合法派生 App AOT 的身份、ABI、来源。当前保留原门，不删比较制造通过；无实际已审 native 输入，尚无此次两份实际 APK parity 通过或失败证据。其他平台 Release native 接线也未在此阶段完成。

## 验证边界

`test/verify_routing_native_inputs_test.py` 使用明确标记的 synthetic manifest/证据/ELF 和 mocked 工具输出，覆盖正门和 missing/stale component、patch/order、接受身份/closure、duplicate/path/ABI/ZIP bomb、工具失败、exit 0 stderr/no-symbols、缺失/截断动态符号表、两个 Vulkan 目标、weak 契约、额外 APK 插件 CRC 损坏、APK 换库等负门。fixture 的 in-memory 接受记录不写入实际账本，也不证明 DEVICE 候选。实际工具解析另用本机 NDK 编译的合成 ELF 验证；合成 native source 仍不等于任务 native 构建输入。

另有 acquisition/variant/workflow 回归，含空选择器无 API、元数据/attempt/job/时间窗、stream 上限、附件 CRC、stage consumer/finalize/替换 APK、锁文件 blob、每个 gate/关键 build 参数删除、失败上传拒绝。临时合成 Git/JSON/ELF fixture 仅验证合同，不写入真实接受账本。

2026-10-12 critical 修正复验：实际 NDK27.2 合成 ELF 的普通强 QueueFamilyProperties2 导入拒绝；同 ELF 仅清空 section-header 指针/数量后，BuildID/动态段仍可读但符号表不可读，明确拒绝。三个正常合成 SO 经 15 次真实 LLVM 读取通过。证据 `/tmp/mk-routing-native-real-llvm-fixture-r2.log` 与同前缀 `-receipt.json`（含 validator SHA），仅本机 parser/gate 行为证据，不授权 native candidate。

本阶段作者收尾证据：`/tmp/mk-routing-native-final-author-tests.json` 记录 43 gate、23 acquisition、16 variant、30 workflow、2 原 ABI 共 114 项回归及真实退出码；三 workflow Actionlint 日志 `/tmp/mk-routing-native-actionlint-final.log`。当前 validator 的真实 NDK 合成复验 `/tmp/mk-routing-native-real-llvm-final-receipt.json` 包含 validator SHA、3 次编译、15 次正常读取和两项 critical 负例。`/tmp/mk-routing-native-empty-workflow-final.json` 记录从 Build/Pink 提取的 acquisition run body 本机执行：两者 exit 1、selection 回执明确 missing-accepted-native-input、commands 为空、native staging 和后续 Gradle sentinel 均未创建。这证明本机命令失败传播，不冒称 GitHub 运行或实际 native/APK 构建通过。

V2 来源漏项修复作者证据：`/tmp/mk-routing-variant-r1-real-injections.json` 重放真实 XML/asset JSON/声明目录 shader 与实际 NDK 编译 ELF jniLibs，在 prebuild 与 finalize 均拒绝；App Git/解析回执仍是明确 synthetic fixture，不授权该 ELF/native 候选。合法 pubget/build 输出正例和未跟踪 Gradle/CMake/fonts/manifest/config/未知 `.dart_tool`/symlink 负例纳入变体回归，三 workflow Actionlint 日志 `/tmp/mk-routing-native-actionlint-r1.log`。本轮 owned 125 项作者回归全部通过（43 gate、23 acquisition、27 variant、30 workflow、2 原 ABI），记录 `/tmp/mk-routing-native-r1-final-author-tests.json`；全 Python 当前工作树 423 项通过，日志 `/tmp/mk-routing-native-r1-full-python-final.log`。此为当前 dirty 工作树的本机 Python 验证，与具体提交身份、hosted GitHub/真实 native/APK 运行分开验收。


第二轮 V2 确认正常实际 pubget 生成 Darwin ephemeral/Swift 文件和 Linux/Windows plugin 链接被第一轮误拒，并实证 `"\u0062uild/generated.json"` 逃过旧 YAML 正则后被实际 Flutter bundle 加载。新增持久工具 `android/tool/parse_routing_manifest.dart` 使用 bootstrap 私有 Flutter tools package_config 的锁定 yaml 3.1.3；不改变 App 依赖、不额外 pubget 工具、不存在正则 fallback。三阶段显式传同一 exact tracked App parser，记录 parser/helper/SDK HEAD/tools config/lock/YAML 实现与 manifest SHA。Flutter tools 的 pubspec.lock 是实际生成文件，并非 SDK tracked blob；初始核其 yaml 3.1.3 与 package_config 精确根对应，前门/后门保持初始 hash 不变。真实 YAML token、loadYamlDocuments 和递归节点验证共同拒绝自定义 tag/directive、多文档、错误类型/键、循环 alias 和越界规模；字段经过真实解码，绝对/URI/生成物及未知未 tracked 资源失败关闭。锁版 public YamlNode 丢弃 tag，实测 !Foo 可被接受，故有界内部 Scanner.scan()/TagToken/TagDirectiveToken 检查真实 token；接口及五个锁版实现文件 hash 随 receipt 绑定。

PUB_GENERATED 精确补充 ios/macOS 的 Flutter ephemeral 配置、lldb 和两种 Swift generated package 文件，以及 dartpad registrant；没有开放整个 ephemeral。Linux/Windows `.plugin_symlinks/<packageName>` 只能指向核对后的 package_config 精确根；Darwin `.packages/<package-root-basename>` 只能指向该包实际 pubspec 声明的 platform 或 sharedDarwinSource 对应 darwin 子目录下 `<packageName>`，要求 Package.swift regular 且不逃包根。`.flutter-plugins-dependencies` 的每个 platform/name/path/shared 标志均与 package_config 和真实包 pubspec 对照，不能自行授权链接。SourcePackages copied target 当前未涵盖，遇到明确拒绝。walk 不跟链接，校验后移除目录；父目录链接、错误包、其他 cache 目标和额外链接均拒绝。source 的生成物不复制，副本独立 offline enforce-lock pubget 后记录 pubGenerated 和 pubLinks（raw/canonical target/packageName）；前门/后门两者均保持不变。build 允许更新的 plugin metadata 仍须语义闭包相等，不能改变已记录链接身份。

本机实际 parser/pubgen 材料使用 reviewer 授权的独立 SDK/cache，101 个外部 Flutter tools 依赖先逐成员完整 hash 等同于原缓存才重绑定 metadata；保留原 config、前后 SHA 和逐包迁移回执 `/tmp/mk-routing-r2-private-sdk-rebinding.json`，没有改共享 SDK/cache，也不声称私有 SDK 未修改。实际 abc149 已归档 App 的只读新工具 inventory 记录 `/tmp/mk-routing-r2-real-pubgen-inventory.json`；旧 App archive 不含新工具且旧控制器不符合当前 CONFIG checker，因此该材料只证明实际 YAML/pkg/generated 边界，不将旧向量改标成新 candidate 完整通过。完整新 App Android/Pink prepare 等经过审核的新提交再执行；native accepted ledger 仍为空，真实 A/B/native/APK 成功以及 all-SO parity 的 App AOT 合同缺口仍未验收。


第二轮作者冻结证据 `/tmp/mk-routing-native-r2-final-author-tests.json`：owned 140 项（43 gate、23 acquisition、35 variant、30 workflow、2 ABI、7 实际 YAML/工具编译）包含于当前 dirty 全 Python 438 项通过（138.006s）；standalone variant35、workflow30、parser7 也通过。锁定 tools graph 下新 Dart parser 分析 0 issue，三 workflow Actionlint 通过。实际普通 tracked asset Flutter bundle 输出逐字匹配，escaped asset 在 build 前拒绝，见 `/tmp/mk-routing-r2-resource-bundle.json`。clean b9d6 文档 HEAD 的普通/Pink 副本各实际 offline enforce-lock pubget 与来源清单通过（1879 tracked、31 pubGenerated、3 buildGenerated、86 精确插件链接），但旧源尚无新 parser/CONFIG factory，所以此材料不证明新完整 prepare。10 次实际 XML/assets/shader/NDK ELF 与错包链接前后门拒绝见 `/tmp/mk-routing-r2-real-injections.json`。当前 Build/Pink acquisition run body 在本机各 exit1，空 selector 下 commands 为空、无 native staging、Gradle sentinel 不存在，回执 `/tmp/mk-routing-r2-empty-workflow.json`；不冒称 hosted GitHub/native/APK 成功。第二轮完整 affected 文件 hash 冻结在 `/tmp/mk-routing-native-release-worker-freeze-r2.json`，后续独立复审与已审新提交的完整 source→prepare→prebuild 仍是单独门。

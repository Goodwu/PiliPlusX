# MK-ROUTING-20261011 Android/Pink native 输入门

本门用于 routing 任务的 arm64 Android/Pink JAR 前置检查和 APK 后置检查。现有 `verify_artifact.py`、插件 ABI/parity、安全、源码新鲜度和设备验收门继续执行；这里不代替它们。工作流接线另行审核。初始 `routing-native-accepted-inputs.json` 的 `entries` 为空，DV001 `1095a43` 以及历史发布 JAR 均未获此门授权。

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

顶层恰为 `schemaVersion: 1`、`task`、`entries` 数组。每条恰含：

- `manifestSha256`、`sourceClosureSha256`、`artifactIdentity`、`jarSha256`。
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

## 验证边界

`test/verify_routing_native_inputs_test.py` 使用明确标记的 synthetic manifest/证据/ELF 和 mocked 工具输出，覆盖正门和 missing/stale component、patch/order、接受身份/closure、duplicate/path/ABI/ZIP bomb、工具失败、exit 0 stderr/no-symbols、缺失/截断动态符号表、两个 Vulkan 目标、weak 契约、额外 APK 插件 CRC 损坏、APK 换库等负门。fixture 的 in-memory 接受记录不写入实际账本，也不证明 DEVICE 候选。实际工具解析另用本机 NDK 编译的合成 ELF 验证；合成 native source 仍不等于任务 native 构建输入。

2026-10-12 critical 修正复验：实际 NDK27.2 合成 ELF 的普通强 QueueFamilyProperties2 导入拒绝；同 ELF 仅清空 section-header 指针/数量后，BuildID/动态段仍可读但符号表不可读，明确拒绝。三个正常合成 SO 经 15 次真实 LLVM 读取通过。证据 `/tmp/mk-routing-native-real-llvm-fixture-r2.log` 与同前缀 `-receipt.json`（含 validator SHA），仅本机 parser/gate 行为证据，不授权 native candidate。

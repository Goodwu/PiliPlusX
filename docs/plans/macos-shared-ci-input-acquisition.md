# macOS 共享候选 CI 的固定输入获取

`scripts/fetch_macos_shared_ci_inputs.py` 把固定下载、官方 uchardet header 和完整 framework 来源接到已有输入准备入口。它不修改正常 ensure、workflow、pubspec、preparer 或 consumer，不发布正式产品。当前源码和 CPU/mock 测试不代表真实 ZIP 下载、Xcode 签名、共享构建、GPU 或屏幕验收。

## 固定来源和身份

`scripts/macos-shared-ci-inputs.lock.json` 固定 10 个归档：Goodwu universal runtime、mpv0.41、FFmpeg9.0.1、libass0.17.1、uchardet0.0.8 和 Predidit0.6.8 的 Ass/Freetype/Fribidi/Harfbuzz/Png16 ZIP。摘要沿用既有审核值；不使用这些 ZIP 中的旧 Mpv。CLI 没有 URL、版本、摘要、lock 路径覆盖参数。脚本固定 lock 的 whole-file SHA，lock 固定 host 模板的文件集合和 SHA；来源或模板变化必须重新审核脚本/lock。

uchardet 官方 URL 是 `https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz`。实际只读 HTTPS 200 取得 222648 bytes，归档 SHA 为 `e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0`。其中 `uchardet-0.0.8/src/uchardet.h` 为 3641 bytes，SHA 为 `3322493803399ae88a24608d2844e57933cc15f33c529d8d4cce92e0b19f56cb`，与此前已审核 header 精确一致。此证据不能代替其他 9 项的实际获取检查。

下载只允许固定 HTTPS URL 和允许的 HTTPS redirect hosts，设大小上限并先核完整归档 SHA。GitHub 重定向中的临时 query token 不写入证据。ZIP 检查全部成员的规范路径、重复项、类型和展开大小，再从唯一 XCFramework metadata 选择 macOS arm64+x86_64 片段。完整 framework 的文件、目录和内部安全相对链接保留；绝对、逃逸、失效链接、特殊文件和不匹配的平台/架构拒绝。header 只读取固定 tar 普通文件并单独核摘要。

raw `verify` 会从保留的固定归档重新派生 header 和每个 framework 全树，再与提取结果比较。修改提取物后重新写一套自洽 JSON 不能绕过 ZIP 来源绑定。

## 签名边界

实际本地 SPM cache 的五个 framework 为 ARM linker-signed / Intel unsigned：ARM `flags=0x20002(adhoc,linker-signed)`、`Info.plist=not bound`、`Sealed Resources=none`，隔离原 ARM thin strict verify 通过，而原完整 bundle 因无资源签名失败。Intel 无 LC_CODE_SIGNATURE，display 与 isolated verify 都明确未签名。此 cache 事实不能冒充 CI 已下载和认证相同 ZIP；真实执行必须先通过上述 archive→tree 绑定。

来源分类遵循已审方向：

- 两 ABI 完整 context 已有效：不加 CodeSignOnCopy，输出 whole-file、thin、CDHash 与完整 tree 必须保持。
- 固定 ZIP 的 ARM 仅有有效 linker 签名，且无 Info/resource 绑定、isolated strict 通过；Intel 无 LC 且 display/isolated 都明确未签名：允许在**私有输出副本**建立完整 bundle 资源签名。
- 原 thin 坏签、非 linker 的坏 context、已有资源绑定损坏、矛盾证据或其他混合状态：立即拒绝，不重签修复。

完整 context 已严格通过时，孤立薄片可能因缺 bundle metadata 验证失败；记录真实返回值，不把孤立上下文错误覆盖完整 context 的验签结果。linker 例外始终要求 isolated strict exit0。现有 preparer 的通用签名政策不改变。

独立 Xcode host 只嵌入五个完整 framework，使用 CodeSignOnCopy 为许可的副本签名，已有效 context 不重签；不调用 Flutter/ensure，不链接或播放视频，不启动 host。签前后记录实际 tree、whole/thin SHA、CDHash、工具链和每个工具 argv/stdout/stderr。

2026-10-04 首次真实 host 日志 `shared-ci-real-acquisition-20261004-r1/sign-logs/tool-0060.json` 显示五框架复制均启用了 `-strip-unsigned-binaries`，实际执行 `strip -D -S -no_atom_info`。原 Ass 的 ARM string table 大小 12488→12496、Intel 12512→12520，payload 门正确拒绝该变化。修正只在 host target Release 和显式 xcodebuild argv 同时设置 `COPY_PHASE_STRIP=NO`、`DEPLOYMENT_POSTPROCESSING=NO`、`STRIP_INSTALLED_PRODUCT=NO`。symbol/string table、load commands 和其他 payload 门保持完整；CPU/mock 不能证明真实 Xcode 已停止 strip，须由 fresh 真实 host 日志和精确前后指纹确认。

签名前的完整 inspection 保存到外部 `log-dir/source-inspection.json`。每个 framework 的两 ABI 原始 before/after payload、资源身份和结构差异先写入 `log-dir/derivation-NAME.json`；先采集五框架，再执行原精确比较。第一个 payload 拒绝后即使清理私有 stage，五组诊断仍保留。诊断不参与归一化或放行。模板 pin 和脚本身份变化使旧 raw seal 过期：须按新审核版本重新执行合法 fetch→verify，不能修改旧 manifest 形成自洽 reseal。

自带 Mach-O64 指纹覆盖 executable section bytes/relocations、所有非签名 load commands、CPU/file flags、UUID、minOS、install ID、dependencies、symbols/strings、dyld/linkedit streams。仅签名 command、__LINKEDIT 最终尺寸及未使用的对齐填充可变；不能声称原 ARM thin 整文件摘要不变。metadata/resources 除 bundle signature 文件外必须精确保留。

实际 stage 和最终发布路径都重新逐 ABI strict 验完整 context；两次检查相等、来源不变后才原子发布 `sealed/signed-context-manifest.json`。失败只撤回本次创建且 inode 仍匹配的输出；日志保留。强制终止可能留下 unsealed payload，消费者须拒绝。原下载、原提取物和既有 inputs/work 不改。

## 显式 CLI 和后续接线

调用方先建立仓库和所有输入树之外的规范 scratch 父目录。每个 output/log 必须不存在，路径不得相交、含 symlink/`..` 或位于 App 内。没有开发者 `/private/tmp`、`/opt` 默认路径，也不重用缓存或已发布输出。

```bash
python3 scripts/fetch_macos_shared_ci_inputs.py fetch \
  --output "$RAW_INPUTS" --log-dir "$FETCH_LOGS"
python3 scripts/fetch_macos_shared_ci_inputs.py verify --directory "$RAW_INPUTS"

# 真实 Xcode/签名操作：必须另行串行安排，此工作包仅测试 mock。
python3 scripts/fetch_macos_shared_ci_inputs.py sign-contexts \
  --inputs "$RAW_INPUTS" --output "$SIGNED_CONTEXTS" --log-dir "$SIGN_LOGS"
python3 scripts/fetch_macos_shared_ci_inputs.py verify-contexts \
  --inputs "$RAW_INPUTS" --directory "$SIGNED_CONTEXTS" --log-dir "$VERIFY_LOGS"
```

然后串行运行已有 `build_macos_mpv_runtime.py OUTPUT --work-dir WORK --jobs 4`，保留两 ABI headers prefix 和完整 runtime provenance，再运行 `verify_macos_mpv_runtime.py OUTPUT`。以上不需要新 media-kit revision。

取得已审核不可变 shared recipe 后，preparer 的四个 `--*-archive` 依次指向 raw `archives/libmpv-macos.tar.gz`、`mpv.tar.gz`、`ffmpeg.tar.xz`、`libass.tar.gz`；`--uchardet-header` 指向 raw `include/uchardet.h` 并传固定 header SHA；`--libass-library` 指向 signed `frameworks/Ass.framework/Versions/A/Ass`，摘要来自实际已验证的 signed manifest；`--library-root` 指向 signed `frameworks`。其余 `--runtime-work/--runtime-directory/--recipe/--output` 显式传入。preparer 会重新严格核 libass 来源，规范独立副本 ID/签名，并建立执行 config/lock。调用前再次执行 raw/context verify，不把现算任意文件 SHA 当来源批准。

随后遵循 [输入准备](macos-shared-input-preparation.md) 与 [候选消费者](macos-shared-candidate-consumer.md) 的实际 CLI：sealed verify→同一 shared builder→精确 runtime embed→final bundle gates→独占候选发布。完整候选应直接调用 consumer 以免先重复构建 slices；fresh/resume identity 不得串用。

共享 recipe/bridge 已本地提交并由正式锁固定为 `252c5851e2ebbcb0876f3bb819303c21fbfe29cd`，bootstrap 策略及手动候选 workflow 已实现并审核；尚未推送，远程来源获取、hosted fresh 和屏幕验收仍未完成。普通 ensure 保留 Intel 构建及最终门禁，显式 bootstrap 为拒绝分发的中间包。固定依赖成功只能闭合输入获取阶段，不能称完整 CI 或屏幕验收完成。

## 测试和验收

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s test -p macos_shared_ci_inputs_test.py -v
```

CPU 测试使用合成归档、合成 Mach-O 和 mock 工具，验证来源绑定/自洽 reseal 拒绝、archive/link/type 安全、签名分类、代码/资源变化拒绝、Xcode/最终验签失败无 seal、source 不变和独占发布。mock whole chain 不证明真实 ZIP 或 Xcode 行为；后续须由 Lead 串行固定下载、真实 host build/签名、stage/final verify，并保存原始返回码。正式默认发布与最终 P5/HDR/跨平台验收另行决定。

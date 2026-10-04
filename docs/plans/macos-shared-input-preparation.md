# macOS 共享核心候选的输入准备

`scripts/prepare_macos_shared_inputs.py`它只准备独立、固定身份的候选构建输入，不构建 mpv，也不修改应用、正常 `ensure_macos_mpv_bundle.sh` 或 CI 默认发布后端。

## 必需输入

- 固定 Goodwu universal 归档，SHA-256 `2965439e9d239a441263288140b2d8b09ee877478084916f63575a1775de97a4`。
- 固定 mpv 0.41.0、FFmpeg 9.0.1、libass 0.17.1 源码归档；摘要复用 `build_macos_mpv_x86.py` 已审核的固定值，脚本每次重新校验，不下载。
- `build_macos_mpv_runtime.py` 产生的 runtime 输出目录及 work 目录。后者必须同时保留 `arm64/include` 与 `x86_64/include`，包含 libplacebo API349 和 Vulkan headers；前者必须有完整固定来源 manifest 及四个 universal runtime 库。
- 显式 universal libass 二进制和调用方已审核的 SHA-256。可以是 `Ass.framework/Versions/A/Ass` 或已规范化的 `libass.dylib`。仅独立副本允许将前者 ID 改为 `@rpath/libass.dylib` 并重新 ad-hoc 签名；原输入不修改。构建输入中的最终副本摘要才是后续应用封装的精确绑定值。
- 显式 uchardet 0.0.8 header 及已审核摘要。此头文件没有可直接核验的版本宏，因此调用方须审核来源和摘要；脚本不会从 Homebrew 搜索或推断版本。
- 显式额外 library roots，用于 libass/FFmpeg 引用的 `@rpath/*.framework/Versions/A/*` 等依赖。仅复制实际闭包中的二进制，保留 universal 整文件字节，不复制 framework 顶层符号链接。
- 已审核的 `media-kit/tool/shared_gpu_next` recipe 路径。正式锁已固定包含 recipe 和 Swift bridge 的已审本地提交 `252c5851e2ebbcb0876f3bb819303c21fbfe29cd`；该提交未推送，远程可获取性及 hosted fresh 仍未验证。

所有显式输入路径都要求真实路径，不接受符号链接及通过符号链接祖先访问的路径。完整 framework 验证上下文允许内部安全相对链接，记录其目标字符串及完整普通文件/目录身份；外部、绝对、逃逸、失效链接与特殊文件一律拒绝。macOS 的 `/var`、`/tmp` 别名应由调用方先解析为规范真实路径。输出的父目录须存在，输出本身须不存在；输出不得与仓库、recipe、归档、runtime、header 或 library roots 相交，也不得位于 `.app` 内。没有固定 `/private/tmp`、`/opt` 或开发者目录默认值。

## 调用

以下变量由候选 CI 入口提供明确的已审核输入。scratch 父目录应在仓库和依赖树之外；可以使用规范化的 runner 工作目录，每次使用独立输出路径。

```bash
python3 scripts/prepare_macos_shared_inputs.py \
  --goodwu-archive "$GOODWU_ARCHIVE" \
  --mpv-archive "$MPV_ARCHIVE" \
  --ffmpeg-archive "$FFMPEG_ARCHIVE" \
  --libass-archive "$LIBASS_ARCHIVE" \
  --runtime-work "$RUNTIME_WORK" \
  --runtime-directory "$RUNTIME_DIRECTORY" \
  --recipe "$SHARED_RECIPE" \
  --libass-library "$LIBASS_LIBRARY" \
  --libass-library-sha256 "$LIBASS_SHA256" \
  --uchardet-header "$UCHARDET_HEADER" \
  --uchardet-header-sha256 "$UCHARDET_HEADER_SHA256" \
  --library-root "$EXPLICIT_FRAMEWORK_ROOT" \
  --output "$SHARED_INPUTS"

python3 scripts/prepare_macos_shared_inputs.py \
  --verify "$SHARED_INPUTS" --recipe "$SHARED_RECIPE"

python3 "$SHARED_RECIPE/build_macos.py" \
  --archive "$SHARED_INPUTS/archive/mpv.tar.gz" \
  --dependency-config "$SHARED_INPUTS/sealed/dependency-config.json" \
  --dependency-lock "$SHARED_INPUTS/sealed/dependency-lock.json" \
  --work-dir "$SHARED_BUILD_WORK" --output-dir "$SHARED_BUILD_OUTPUT"
```

构建器的 work/output 也必须与输入目录、所有仓库分离。这里的 lock 是**本次来源检查后的执行身份快照**，其绝对路径不能迁移；它不表示对任意 libass/header 参数的自动来源批准，也不是视频或屏幕验收。

## 发布与消费者门禁

脚本先在同卷隐藏 stage 检查真实 Mach-O、ABI、minOS ≤12、FFmpeg 版本、API349 和实际依赖闭包，再完成下述签名准备，最终重新检查并保存 `stage-inspection.json`。payload 以禁止覆盖的 rename 发布后，再针对**实际存在的最终路径**调用同一构建器的 dependency inspection。报告必须与受控路径映射后的 stage 预期完全相等，最终 lock 使用这次实际检查结果。

只有最终路径检查通过后，配置、真实 lock 与完整文件清单一起原子发布为 `sealed/`。发布由 payload rename、final inspection、atomic seal 三步组成。异常会撤回本次创建的输出；强制终止可能留下未封存 payload，消费者必须拒绝缺少 `sealed/inputs-manifest.json` 的目录。`--verify` 会重新核对完整文件集合、SHA、recipe 身份和实际 dependency inspection；每次 build/package 前都必须运行。已有输出不重用、不覆盖，失败重试应选新路径。

封装阶段还必须把 `lib/` 中每个实际闭包二进制的**精确字节**嵌入独立候选应用，保留相对 `@rpath` 路径，再调用 `package_macos_shared_build.py`。该包脚本要求输入应用 runtime 与构建 lock 整文件摘要相等；仅构建 slices 并不足够，也不能将薄片摘要当 universal 整文件摘要。当前 preparer 不负责应用依赖嵌入、Flutter 构建或 shared backend gate。

## 派生签名与独立 framework 验证上下文

真实 Goodwu 固定归档的 11 项实际 flat runtime 依赖是混合签名：arm64 有有效 linker-signed ad-hoc 签名，x86_64 无 `LC_CODE_SIGNATURE`。不能把整个 fat 文件当未签名，也不能用 `codesign --force` 重签整 fat 来掩盖坏签。

准备阶段逐 ABI 检查 LC、codesign display 与 strict verification。已有签名必须严格通过；缺 LC 加上 display 明确 `not signed at all` 才认定该薄片未签名。遇到已有坏签或矛盾状态立即失败。独立临时薄片只对真正未签架构执行 `codesign --sign -`；已签薄片不改。lipo 合成新 universal 后重新验证全部签名、ABI、minOS 与安装依赖，并实际再次提取原已签薄片，要求 bytes SHA 和 CDHash 均不变。原归档、原 inputs-v1 和旧构建不修改；派生动作发生在新 stage、最终 lock 检查之前。

manifest provenance 记录 source/derived whole-file SHA、逐 ABI 原签名状态、薄片 SHA、只签未签薄片的动作、派生签名状态及已签薄片保护证据。后续 `--verify` 实际验证这些派生签名和原已签薄片保护，不根据记录布尔值宣称签名有效。原来已完整签名的 flat 库保持整文件 bytes。

framework 二进制保留原 whole-file bytes。签名依赖 Info.plist/resources 时，在孤立 binary-only 目录验签会误报缺上下文；因此准备阶段先在显式来源完整 framework 中严格验两 ABI，然后安全复制完整验证上下文到独立 `framework-context/<name>.framework`。其 binary SHA 必须等于 `lib/` 中的锁定 binary，context 的普通文件、目录与内部相对 symlink 目标均封存。发布后和每次 `--verify` 使用**输入自身**完整 context 逐 ABI strict 验证，不要求原来源 framework 继续存在，不使用 deferred 验证，也不重签 framework。consumer 仍在实际 App 的 framework metadata 下重新严格验证，不能借 context 代替最终 App 签名验收。

旧 inputs-v1 缺少此签名政策，保留用于失败追溯；新脚本拒绝把它当已准备好的签名输入，应创建新 inputs-v2 并使用新的 fresh work/published 身份，不覆盖或重用旧依赖 lock。原 Ass.framework 转 flat libass 的显式 ID 派生同样要求来源完整 context 先 strict 通过，派生动作记录后再验，不允许修补坏来源签名。

## 验证边界

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s test -p prepare_macos_shared_inputs_test.py -v
```

单元测试覆盖拒绝路径、归档安全、发布失败、最终路径检查与身份变化、未封存目录、sidecar/额外文件/符号链接/recipe 篡改，以及签名双证据、坏已有签名拒绝、只签未签薄片、ARM 薄片保护、签名失败不修改 stage 源文件、完整 framework context 与独立验证；其中发布流程使用 mock inspector，不能作为真实 ABI 证据。真实固定归档和 runtime 输入还需单独运行 prepare 与 `--verify`，记录明确退出码。正式启用共享默认发布仍等待运行、颜色和用户屏幕验收。

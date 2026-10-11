# Android 7（LG H870DS）打不开诊断与播放恢复

## Current State

2026-10-11：LG H870DS（lucye，LG G6，Snapdragon 821，Android 7.0/API 24，arm64-v8a，4GB）上报 PiliPlusX "打不开"。诊断确认为**兼容性缺陷而非性能问题**，分两个工作包完成并实机验证：

- **WP1 启动容错（app 侧，已构建待提交）**：根因是 `main_native.dart:120` 的 `MediaKit.ensureInitialized()` 无容错。当前 libmpv 构建（libmpv-android-v2026.10 / media-kit `5f9ddf17` JAR）链入了 Vulkan 1.1 符号 `vkGetPhysicalDeviceQueueFamilyProperties2`，Android 7.0 的系统 `libvulkan.so` 仅含 1.0 符号，dlopen 失败 → `NativeLibrary.ensureInitialized` 抛 `Cannot find libmpv.so` → main() 在 runApp 前死亡 → 首帧永不绘制（`am start -W` Status: timeout，WaitTime 10s，黑屏）。此前 LYA-AL00（API 29）与 marble（API 30+）均有 Vulkan 1.1，未暴露。
- **WP2 播放恢复（实验已验证，正式化待办）**：`libmpv.so` 全部 394 个未定义符号中，仅 2 个 Vulkan 1.1 符号在 API 24 缺失（`vkGetPhysicalDeviceProperties2`、`vkGetPhysicalDeviceQueueFamilyProperties2`）；其余（4 个 Vulkan 1.0 符号、7 个 ANativeWindow 符号）API 24 全可用，包内无 ANGLE 依赖。将这 2 个符号在 `.dynsym` 中改为 weak undefined（全文件仅 2 字节改动）后 dlopen 成功；app 的 Android 路径（Texture/mediacodec-copy/gpu-next-GLES）从不创建 Vulkan 上下文，弱化符号不会被调用。

### 实机证据（/tmp/piliplusx-android-lg-launch-20261011/）

- 根因取证：`launch1.log`（UnsatisfiedLinkError + `media_kit: ERROR: MediaKit.ensureInitialized`，Unhandled Exception 栈指向 main_native.dart:120）；`screen1.png`（纯黑）；未定义符号清单 `undefined_syms.txt`。
- WP1（APK `d39a966d29034cd7e6cf73877b7e7ff7ee3ed39339ba3b39e52a7fed554b2a2f`，release 签名）：冷启动 `Status: ok`、`Displayed +2s502ms`，`MediaKit.ensureInitialized failed` 被捕获后应用继续；首页信息流/图片/更新弹窗正常；深链视频页打开、评论区加载、零 FATAL/ANR。截图 `screen-wp1-home2.png`、`screen-wp1-play1.png`。
- WP2（APK `0fe41cda26ca45f835d51d62a2c7791325aabfe4c80333480b49545aa2b8865e`，debug 重签实验包）：卸载重装后冷启动 `Status: ok`、WaitTime 2.7s；logcat 无任何 dlopen/缺依赖错误；深链 `BV1T7t96BECu` 播放成功——`OMX.qcom.video.decoder.avc` Loaded→Idle→**Executing** 硬解、弹幕渲染、像素采样差分证明帧连续推进（6s 间隔约 28% 采样点变化）、切后台返回后播放恢复。截图 `play2-*.png`、`resume-*.png`；日志 `launch-wp2.log`、`log-wp2-play.log`。唯一掉帧记录为视频页打开时一次性 `Skipped 53 frames`（SD821 重负载，非持续）。
- 工具：`weaken_vk_symbols.py`（ELF64 .dynsym 弱化，指定符号 GLOBAL→WEAK）、`repack_weakened.sh`（重打包+debug 签名）。

### 已知缺口 / 后续

1. **libmpv 正式修复未落地**：弱化目前只在实验包（APK 后处理）。正式路径应在 libmpv 构建仓（Goodwu libmpv-android build）把 `vkGetPhysicalDeviceProperties2` / `vkGetPhysicalDeviceQueueFamilyProperties2` 弱导入（或等效 dlsym 化），出新 JAR 后经 media-kit libs 包钉定，app 无需改动。风险契约：这两符号仅 libplacebo Vulkan 上下文创建路径调用，app Android 拓扑不触达；若未来引入 vo=vulkan 需先恢复强符号并要求 API 28+。
2. **WP1 降级 UX 不完整**：仅 WP1 包在缺 libmpv 设备上，视频页打开后播放链路在 `Player.create` 前静默停滞（无错误、无 toast、黑屏；release 日志证实无播放器创建记录）。main 侧 catch + `mediaKitLoadFailed` 标志与 controller catch 处 toast 已实现（analyze 通过），但实机未捕捉到 toast 视觉证据（更新弹窗遮挡/时序）；视频页停滞-无反馈是次级鲁棒性问题，登记待办。
3. 本轮为 LG 设备启动+基础播放验收，不替代最终候选矩阵的竖屏 SDR/PQ、surface 重建、HLG/HDR Vivid 与同源颜色对照项。
4. 设备备注：该 LG 交互式 `logcat` 为空，必须 `adb exec-out logcat`；系统休眠激进，自动化期间需 `svc power stayon true`；系统自带 "Google Play 商店已停止" 弹窗与 app 无关。

历史区（按时间）

- 2026-10-11 13:12 首轮复现：v2.1.2（46adc41b…，2026-10-10 构建）安装成功（minSdk 24 恰好压线）但启动 10s 超时黑屏，logcat 定位 dlopen 失败与 main 未捕获异常。
- 2026-10-11 13:24 符号分析收窄至 2 个缺失符号；弱化脚本 2 字节验证通过（llvm-nm 复核 `w` 标记）。
- 2026-10-11 13:30 WP1 实机验收通过（启动/首页/深链视频页/零 FATAL）。
- 2026-10-11 13:40 WP2 实机验收通过（硬解 Executing、帧推进、重入恢复）。

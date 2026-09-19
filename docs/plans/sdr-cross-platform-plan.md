# 非 HDR 全平台可用：主要事项

更新时间：2026-09-05。当前证据汇总见
[SDR 跨平台构建证据](../status/platform-sdr-build-status.md)；本文件只保留计划、
验收口径和未解除阻塞，不重复粘贴构建日志。

## 目标与范围

在原生 HDR 尚未完成真机验收前，先保证 Android/Pink、iOS、macOS、
Windows x64、Linux x64、Linux arm64、OHOS 和 Web 的 SDR 主链路可构建、
可启动、可播放并能安全释放资源。

SDR 主链路是兼容性和运行保护基线，不是具备 HDR 硬件能力设备的产品替代方案。对
任一平台，只要硬件能力满足 HDR，就必须继续实现 HDR；只有能力探测确认硬件不满足时，
才允许把 SDR/tone-map 作为最终输出。原生 HDR 后端未完成、生命周期缺陷、交互问题、
缺少真机证据或模拟器限制都必须记录为 HDR 阻塞，不能改写成硬件不支持。

- `HdrMode.off` 仅表示用户主动关闭 HDR；虚拟机、模拟器、远程桌面和能力明确不足的
  设备可以使用 SDR/tone-map，但不能据此推断支持 HDR 的真机也允许回退。
- 构建成功只作为编译证据；只有实际启动和播放完成后才记录运行验收。
- Web 以核心播放为目标；下载、托盘、原生窗口等浏览器不支持的功能隐藏或禁用。
- Linux arm64 发布 tar.gz 和 deb；Linux x64 继续发布 tar.gz、deb 和 rpm。

详细命令、产物路径和校验值见 [SDR 跨平台构建证据](../status/platform-sdr-build-status.md)。

## 当前基础

- Web release 已生成，原生接口已通过条件实现隔离，播放器固定走 SDR。
- Android arm64 release APK 已用 Java 17 构建并通过 ABI、manifest 和 SHA-256
  校验；Pink 对应产物和 native library parity 仍需补齐。
- macOS universal release 已构建；本机登录点播已确认视频画面、弹幕和进度正常。
- iOS simulator 与无签名 device app 已构建，仍缺运行验收。
- Linux x64 已在 `dev` 生成 tar.gz、deb、rpm；Linux arm64 已在 Lima 生成
  aarch64 ELF、tar.gz 和 deb，并完成架构及摘要校验。
- OHOS signed arm64 HAP 已在模拟器和实体机安装/启动；实体机 Texture SDR 首帧已
  通过，完整控制与生命周期矩阵仍未完成。native surface 是当前 HDR 硬约束下的实现路径，
  不能因为 SDR 首帧通过就把它降级为可选后续功能。
- Windows x64 和 Linux 实际视频呈现仍缺可用图形/来宾设备环境；OHOS 已解除
  “无设备”阻塞，但 native surface 当前会触发 `SIGSEGV`。
- `pubspec.lock` 的 9 个 media-kit 包当前统一锁定到
  `0fa6afe9cd9af8d8437919257d81a27c643f2f63`；8 个 workflow 和发布 manifest 仍引用
  `73536ef...`，必须另行完成一致性迁移和回归，不能声称当前发布链已经固定。

## 实施顺序

1. **固化公共回退契约**：保持平台能力与运行状态分离，补齐初始化失败、surface
   重建、重复 dispose、播放结束和 Web 条件导入测试。
2. **补齐 Android/Pink**：使用 Java 17 生成两个 arm64 APK，验证包名/签名差异和
   native library 一致性；在模拟器或设备上完成启动及 SDR 点播。
3. **补齐 Apple 运行门**：在 iOS Simulator 验证启动、点播、旋转、后台恢复和资源
   释放；复验 macOS 全屏、窗口缩放、跨屏与长时间播放。
4. **补齐 Linux 运行门**：Xvfb 只用于启动和生命周期；寻找真实 X11/Wayland 图形
   会话分别验证 x64 与 arm64 的首帧、音画同步、seek、全屏和退出。
5. **补齐 Windows**：启动 Windows 11 ARM VMware，安装 Flutter/VS C++/SDK，交叉
   构建 x64，并在模拟层验证安装、SDR 播放、DPI、最小化和全屏。
6. **补齐 OHOS**：安装并启动已签名 HAP 已完成；继续在实体机验证 XComponent/
   NativeWindow 生命周期、点播、前后台切换、SDR 回退和亮度/音量手势。模拟器仅
   用于安装、启动和基础输入验证，不用于 media-kit 视频首帧验收。
7. **补齐 Web**：本地 HTTP server + Chrome 验证首页、登录态、SDR 点播/直播、
   弹幕、暂停、seek、画质切换和错误源恢复。
8. **最终集成**：将全部 media-kit 条目切换到同一候选 SHA，重跑 lock、workflow、
   ABI、manifest、SHA-256、单测和各平台 SDR 烟测；保留旧 SHA 作为回滚点。

## 统一验收矩阵

每个平台至少记录以下状态，并附命令、日志或截图：

- 依赖严格解析成功，目标架构正确。
- release 产物生成并通过 manifest/SHA-256 校验。
- 应用可安装或可启动，首屏无黑屏、崩溃和无限等待。
- SDR 点播能够出首帧且音画同步；暂停、恢复、seek 和画质切换正常。
- 字幕、弹幕、全屏/窗口变化、前后台恢复及播放结束释放正常。
- 不支持的 HDR、Dolby Vision 或 HDR Vivid 内容能够回退到可播放 SDR。
- 无真实运行环境时明确标记“构建通过，运行待验证”，不得提升验收状态。

## 当前阻塞及解除条件

- **Pink**：缺对应 APK 与 Android/Pink native parity 结果；生成两包后解除。
- **iOS**：缺 Simulator 实际启动和播放记录；启动可用 Simulator 后解除。
- **Windows**：VMware 客户机需要密码且尚无来宾通道；能够启动 VM 或取得独立
  Windows runner 后解除。
- **Linux x64/arm64**：现有环境没有真实图形输出；取得带 GPU 的 X11/Wayland
  会话后解除视频呈现阻塞。
- **OHOS**：模拟器和实体机的 HAP 安装、Ability/首页启动已解除；模拟器不能作为
  media-kit 视频播放设备，实体机仍需补齐当前包的完整 SDR 播放矩阵和亮度/音量手势
  实测。
- **HDR**：对硬件能力满足的设备属于当前交付硬约束；需系统色彩空间、播放器元数据、
  原生输出成功和 HDR/SDR 亮度比证据同时成立，才可标记 `nativeHdr`。证据不足是验收
  阻塞，不是允许回退的硬件结论。

## 变更边界

- 提交时仅纳入本计划及输出生命周期修复文件，保留用户已有的无关改动；不做宽泛清理。
- CI 采用按平台触发、路径过滤和 concurrency cancellation，避免每次运行全量长测。
- 不把 CI、模拟器、Xvfb 或虚拟显示结果描述为真机视频呈现或 HDR 验收。

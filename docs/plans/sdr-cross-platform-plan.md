# 非 HDR 全平台可用：主要事项

更新时间：2026-09-02。当前证据汇总见
[SDR 跨平台构建证据](../status/platform-sdr-build-status.md)；本文件只保留计划、
验收口径和未解除阻塞，不重复粘贴构建日志。

## 目标与范围

在原生 HDR 尚未完成真机验收前，先保证 Android/Pink、iOS、macOS、
Windows x64、Linux x64、Linux arm64、OHOS 和 Web 的 SDR 主链路可构建、
可启动、可播放并能安全释放资源。

- 默认保持 `HdrMode.off`；虚拟机、模拟器、远程桌面和能力不足的设备统一使用
  SDR/tone-map，不报告 `nativeHdr`。
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
- OHOS unsigned arm64 HAP 已构建并通过内容、ABI、manifest 和未签名检查；`hdc`
  无在线目标，运行门未解除。
- Windows x64、OHOS、Linux 实际视频呈现仍缺可用图形/来宾设备环境。
- media-kit 当前继续统一锁定到
  `73536efdda482f2d5eefe2feb7038db419944b96`；公共 API 候选
  `ad22c36a9986a8418c81829821962009425cf5e5` 已通过完整 CI，但须在全平台
  SDR 回归后再统一切换。

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
6. **补齐 OHOS**：取得模拟器或真机后安装 unsigned HAP，验证 XComponent/
   NativeWindow 生命周期、点播、前后台切换和 SDR 回退。
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
- **OHOS**：没有可用模拟器或真机；设备可安装 HAP 后解除。
- **HDR**：继续作为独立后续阶段；需系统色彩空间、播放器元数据、原生输出成功和
  HDR/SDR 亮度比证据同时成立，才允许启用 `nativeHdr`。

## 变更边界

- 提交时仅纳入本计划及输出生命周期修复文件，保留用户已有的无关改动；不做宽泛清理。
- CI 采用按平台触发、路径过滤和 concurrency cancellation，避免每次运行全量长测。
- 不把 CI、模拟器、Xvfb 或虚拟显示结果描述为真机视频呈现或 HDR 验收。

# 全平台原生 HDR 开发主要事项

更新时间：2026-09-06

本文件保留原生 HDR 的总体路线和验收门槛。早期环境与 SHA 只作为历史快照；各平台
当前状态以 [HDR 后端状态矩阵](../status/hdr-backend-status.md) 和
[HDR 验证账本](../status/hdr-verification.md) 为准。

## 跨平台硬约束

对所有目标平台，只要设备硬件能力满足 HDR，就必须实现并交付 HDR 播放。只有能力
探测明确证明显示输出、解码 profile、色彩管线或等效硬件条件不满足时，才允许最终
回退到 SDR/tone-map。

原生后端未完成、PlatformView/NativeWindow 生命周期有缺陷、色彩空间配置失败、交互
问题、缺少真机证据、模拟器限制和 CI 环境不足，都不能归类为“硬件不满足”。这些
情况必须作为开发阻塞或验收缺口继续处理。为了避免黑屏或崩溃而采取的临时运行回退，
只能作为保护措施，不能成为产品默认路径或 HDR 阶段完成条件。

## 目标与完成定义

- 完成 Android/Pink、iOS、macOS、Windows x64、Linux x64 和 OHOS 的原生
  HDR 输出后端，并在对应目标工具链上编译通过。
- 原生 HDR 必须具备原生 surface、系统 HDR/EDR 色彩空间、播放器保留的
  BT.2020 与 PQ/HLG 元数据，以及高于 SDR 基线的 HDR/SDR ratio 或平台等效指标。
- 模拟器、虚拟机、CI 和无图形 SSH 环境只能证明编译、启动、布局、生命周期或
  SDR 回退，不能单独证明原生 HDR。
- 只有硬件能力不满足时，才允许将 Texture/gpu-next tone-mapped SDR 作为最终回退；
  实现失败时可以临时保护播放，但必须保留 HDR 阶段阻塞并继续修复，不能以回退代替
  HDR 实现。

## 当前基线

本计划是原生 HDR 的后续路线图；截至 2026-09-02，OHOS 已完成完整 unsigned arm64
HAP 构建，但仍停留在“运行待验证”，不应误读为原生 HDR 已完成。当前状态详见
[HDR 后端状态矩阵](../status/hdr-backend-status.md) 和
[HDR 验证账本](../status/hdr-verification.md)。

- 2026-09-02 初始快照中的 9 个 media-kit 包固定到 `73536ef...`；2026-09-05
  `pubspec.lock` 已统一到 `Goodwu/media-kit@0fa6afe9...`，但 workflow/manifest 仍为
  `73536ef...`，两者尚未完成一致性迁移。
- media-kit 公共 HDR 生命周期位于
  `integration/piliplusx-hdr-public-api`，当前提交为
  `ad22c36a9986a8418c81829821962009425cf5e5`；其全平台构建和长 package tests
  已通过，但各平台原生 HDR 后端仍需实现。
- 公共通道固定为 `piliplusx/hdr_capabilities`，提供 `probe`、
  `configureOutput` 和 `resetOutput`。能力可用与输出已激活必须分开记录；只有
  `configureOutput` 获得系统和播放器确认后才能进入 `nativeHdr`。
- `HdrMode` 继续只向用户暴露 `auto/off`，当前默认保持 `off`；HCPP、VO、
  swapchain 等只出现在诊断信息中。

## 平台实现重点

| 平台 | 原生后端 | 开发与验证重点 |
| --- | --- | --- |
| Android/Pink | HCPP/SurfaceView + MediaCodec | 保持 HCPP → SurfaceView → Texture 运行保护链；只有硬件能力明确不满足时才允许最终回退，其他失败必须阻塞 HDR 验收。API 34+、Vulkan、HDR display、10-bit codec profile 和完整 HDR 元数据同时满足后提交 Window HDR mode 与 dataspace。 |
| iOS | `UIView` + `CAMetalLayer` PlatformView | 接入 EDR-capable 原生 layer，设置 10-bit/浮点像素格式和 BT.2020 PQ/HLG 色彩空间；模拟器或 EDR 不可用只能作为环境/能力证据，不能替代支持设备上的 HDR 实现。 |
| macOS | `NSView` + `CAMetalLayer` | 根据窗口所在 `NSScreen` 动态配置 EDR；监听窗口缩放、全屏、跨屏和显示参数变化，只有目标屏硬件能力不满足时才允许最终回退。 |
| Windows x64 | 原生视频子窗口 + D3D11 flip-model swapchain | 绑定播放器 HWND，验证 10-bit format、`CheckColorSpaceSupport` 和 `SetColorSpace1`；同步 DPI、缩放、全屏、最小化和跨显示器布局。 |
| Linux x64 | GTK 原生视频区域 + Wayland color-management | 仅在 compositor 协议、驱动、HDR output、10-bit surface 和 image description 全部可证明时启用；X11、远程桌面和软件渲染只有在对应硬件/输出能力明确不满足时才允许最终 SDR。 |
| OHOS | `XComponent` → NAPI/C++ → `OHNativeWindow` → 解码器输出 | 完成 surface 生命周期、窗口尺寸同步、硬解 profile 和 NativeWindow HDR 色彩空间配置；平台 API 证据不足时保持未验收并继续实现，不能把 `nativeOutput=false` 当作完成状态。 |

FinVideo 只用于参考 HDR10、HLG、Dolby Vision、HDR10+ 元数据分类，以及硬解和
GPU 渲染策略。其实际播放器来自外部 `@ohpg/player`/FinPlayer，公开应用源码没有
可直接移植的 XComponent/NativeWindow HDR 后端，且为 GPL-3.0；不得未经许可证
边界审查直接复制。OHOS 底层实现继续以 Predidit media-kit、OpenHarmony 官方
接口及公开的 ccplayer/VLC OHOS 生命周期实现为主要参考。

## 执行与并行顺序

1. 先冻结公共 Dart/channel/native lifecycle 接口，并确保能力、candidate 和
   active 三种状态不会混用。
2. 在同一公共基线上并行开发 Apple、Windows、Linux 和 OHOS 后端，同时让
   Android/Pink 适配统一生命周期。
3. 每个平台使用独立 media-kit 分支，编译通过后再合入专用 HDR 集成分支；
   最终才把 PiliPlusX 的全部 media-kit lock 一次性更新到同一完整 SHA。
4. 公共接口变化只运行一次公共测试；平台分支只触发对应 workflow，使用路径过滤、
   `workflow_dispatch` 和 concurrency cancellation，避免每次推送重复全量长测试。
5. 保留 PiliPlusX 现有脏工作树和无关改动；未经明确要求不提交本地应用改动，也
   不自动合并现有 draft PR。

## 可用执行环境与下一步

- Apple：macOS 已在 HDR 显示器验证 `NSView`/`CAMetalLayer`、BT.2020 和 EDR 输出，
  仍缺 HDR/SDR 跨屏及全屏回归；iOS simulator/device 产物已有，仍需真机 EDR 证据。
- Windows：先用 GitHub Actions `windows-latest` 构建标准 x64；随后启动本机
  VMware Fusion ARM Windows，安装或复用 Flutter、Visual Studio C++ 和 Windows
  SDK，交叉构建并通过 x64 模拟层验证子窗口、布局、生命周期和 SDR 回退。
- Linux：SSH `dev` 已完成 Ubuntu 22.04 x86_64 release 构建，但没有 DISPLAY、
  Wayland 或 GPU。继续用它做 x64 编译；实际 HDR 运行必须寻找带 Wayland HDR
  compositor 的图形主机。Lima aarch64 只用于接口和 ARM 编译检查。
- OHOS：模拟器和实体机均已完成签名 HAP 安装/启动；实体机 Texture SDR 与 Dolby Vision
  tone-map 首帧已通过，XComponent/native Surface candidate 也已显示 DV tone-map。
  当前缺口是窗口几何、EGL/BufferQueue 和 Surface 生命周期稳定性，以及 PQ/HLG
  NativeWindow 色彩空间和 `nativeOutputActive` 的实体机证据；完成前继续保持
  native HDR fail-closed。
- Android/Pink：已有 Java 17 release 产物证据；本机当前仅有 Java 26，debug
  JdkImageTransform 失败，仍需 CI/Java 17 环境补齐 Pink parity 和运行矩阵。

对每个平台按“本机 → 模拟器/VM → SSH/Lima → GitHub Actions → 可安装工具链”
依次排查。只有这些路径都已检查，并留下具体命令、错误和缺失项后，才可记录为
当前没有可用执行环境。

## 测试与放行门槛

- 公共验证：HDR 决策单测、Dart analyze、七平台 channel contract、media-kit
  lock/workflow SHA、ABI、release manifest 和 SHA-256 校验。
- 编译矩阵：Android/Pink arm64 APK、iOS simulator/无签名 device、macOS、
  Windows x64、Linux x64 和 OHOS arm64 unsigned HAP。
- 运行矩阵：SDR、HDR10/PQ、HLG、不支持的 Dolby Vision/HDR Vivid 回退，以及
  DASH、离线缓存、画质切换、旋转/跨屏、全屏、PiP、后台恢复、字幕、弹幕、截图
  和重复销毁。
- 状态分级统一为“代码完成”“目标平台编译通过”“运行与 SDR 回退通过”“原生
  HDR 真机验收通过”。只有最后一级允许将对应平台默认值从 `off` 调整为 `auto`。

详细现状和执行证据分别见
`../status/hdr-backend-status.md`、`../status/hdr-verification.md` 与
`../status/ohos-development-summary.md`。

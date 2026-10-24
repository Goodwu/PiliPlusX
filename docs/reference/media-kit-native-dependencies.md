# media-kit 原生依赖来源与跟踪基线

更新时间：2026-09-05

本文记录 PiliPlusX 当前 media-kit fork 与 `media-kit/media-kit` 官方主分支在各平台
实际消费的原生依赖。这里的“当前版本”是构建声明固定的版本，不等于对应构建仓库的
最新 Release，也不等于已经在 PiliPlusX 真机验证。

## 1. 审计基线

| 角色 | 仓库与提交 | 用途 |
| --- | --- | --- |
| 官方框架基线 | [`media-kit/media-kit@c533e446`](https://github.com/media-kit/media-kit/tree/c533e446755f51cf53c7e57aea873f2aa5355f81) | 核对官方主分支实际下载声明 |
| 当前产品依赖 | [`Goodwu/media-kit@0fa6afe9`](https://github.com/Goodwu/media-kit/tree/0fa6afe9cd9af8d8437919257d81a27c643f2f63) | `pubspec.lock` 中 9 个 media-kit 包的统一来源 |
| OHOS 上游工作 | [`media-kit/media-kit#1326`](https://github.com/media-kit/media-kit/pull/1326) | 已有 OHOS 实现和社区协作入口 |

审计时官方 `main` 为 `c533e446755f51cf53c7e57aea873f2aa5355f81`。PR #1326
仍为 Open，GitHub 报告 `mergeable=false`、`mergeable_state=dirty`；官方 `main`
不存在 `libs/ohos/media_kit_libs_ohos`。因此，现阶段“采用官方 media-kit”应理解为
“以官方 main 为代码基线维护最小 OHOS 补丁”，不能理解为直接改用官方发布包后仍然
保有 OHOS 能力。

## 2. 官方 media-kit 的原生依赖

### 2.1 Android

官方构建声明：[`build.gradle`](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/libs/android/media_kit_libs_android_video/android/build.gradle)。

| ABI | Release 资产 | 构建脚本校验 |
| --- | --- | --- |
| arm64-v8a | [`v1.1.7/default-arm64-v8a.jar`](https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-arm64-v8a.jar) | MD5 `83df25b61193af8fa815e373143ac9af` |
| armeabi-v7a | [`v1.1.7/default-armeabi-v7a.jar`](https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-armeabi-v7a.jar) | MD5 `22e21526fefc0a2b8f17adbec9f57590` |
| x86_64 | [`v1.1.7/default-x86_64.jar`](https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86_64.jar) | MD5 `6fa26bf0459b11f1c0b0dbc29e5b940d` |
| x86 | [`v1.1.7/default-x86.jar`](https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86.jar) | MD5 `0d742b756dc9d1fcd84ea271d8b68f32` |

截至本次审计，[构建仓库 Releases](https://github.com/media-kit/libmpv-android-video-build/releases)
已有 `v1.1.11`，但官方 media-kit `main` 仍消费 `v1.1.7`。跟踪任务必须分别记录
“框架声明版本”和“构建仓库最新版本”，不能看到新 Release 就假定应用已经升级。

### 2.2 iOS 与 macOS

官方构建声明：

- [iOS Makefile](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/libs/ios/media_kit_libs_ios_video/ios/Makefile)
- [macOS Makefile](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/libs/macos/media_kit_libs_macos_video/macos/Makefile)
- [iOS SwiftPM 清单](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/libs/ios/media_kit_libs_ios_video/ios/media_kit_libs_ios_video/Package.swift)
- [macOS SwiftPM 清单](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/libs/macos/media_kit_libs_macos_video/macos/media_kit_libs_macos_video/Package.swift)

| 平台 | 完整 XCFramework 压缩包 | SHA-256 |
| --- | --- | --- |
| iOS universal | [`v0.7.2 ios-universal-video-default`](https://github.com/media-kit/libmpv-darwin-build/releases/download/v0.7.2/libmpv-xcframeworks_v0.7.2_ios-universal-video-default.tar.gz) | `a0dbcddc0eaefa5534eb2bdc797e5386b1e0cd4057ed8f73aa2dd6105503dffb` |
| macOS universal | [`v0.7.2 macos-universal-video-default`](https://github.com/media-kit/libmpv-darwin-build/releases/download/v0.7.2/libmpv-xcframeworks_v0.7.2_macos-universal-video-default.tar.gz) | `dd9928fff9c97329e17f69fe8ef0d621cf458f9f70847955f84b4eb1e9047b09` |

SwiftPM 会按以下规则分别下载 18 个 binary target，而不是只下载一个 `libmpv`：

```text
https://github.com/media-kit/libmpv-darwin-build/releases/download/v0.7.2/
libmpv-xcframeworks_v0.7.2_<ios|macos>-universal-video-default_<Framework>.zip
```

`<Framework>` 包括 `Ass`、`Avcodec`、`Avfilter`、`Avformat`、`Avutil`、`Dav1d`、
`Freetype`、`Fribidi`、`Harfbuzz`、`Mbedcrypto`、`Mbedtls`、`Mbedx509`、`Mpv`、
`Png16`、`Swresample`、`Swscale`、`Uchardet` 和 `Xml2`。每个组件的 SwiftPM
checksum 以对应 `Package.swift` 为准。

### 2.3 Windows

官方构建声明：[`CMakeLists.txt`](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/libs/windows/media_kit_libs_windows_video/windows/CMakeLists.txt)。

| 架构/组件 | Release 资产 | 构建脚本校验 |
| --- | --- | --- |
| x86_64 libmpv | [`20241021 mpv-dev-x86_64`](https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/mpv-dev-x86_64-20241021-git-0f78584.7z) | MD5 `6ecf18e85b093c3f7edb16f3ee6603f3` |
| ARM64 libmpv | [`20241021 mpv-dev-aarch64`](https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/mpv-dev-aarch64-20241021-git-0f78584.7z) | MD5 `5b507a35db13eee6cb7eb21e8be7c83d` |
| ANGLE | [`ANGLE v1.0.1`](https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z) | MD5 `e866f13e8d552348058afaafe869b1ed` |

最终应用会带入 `libmpv-2.dll`，并按当前脚本带入 `d3dcompiler_47.dll`、`libEGL.dll`
和 `libGLESv2.dll`。ANGLE 资产来自维护者个人仓库，不属于 `media-kit` 组织，供应链
清单必须单独列出其所有者、许可证和替代方案。

### 2.4 Linux

官方 `media_kit_video` 通过 [`pkg-config`](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/media_kit_video/linux/CMakeLists.txt)
查找系统 `mpv` 和 `epoxy`，不下载固定的预编译 libmpv。具体系统包名由目标发行版决定。

`media_kit_libs_linux` 还会下载并从源码构建：

| 内容 | 下载链接 | 校验 |
| --- | --- | --- |
| mimalloc 2.1.2 源码 | [`v2.1.2.tar.gz`](https://github.com/microsoft/mimalloc/archive/refs/tags/v2.1.2.tar.gz) | MD5 `5179c8f5cf1237d2300e2d8559a7bc55` |

因此 Linux 验收必须同时记录目标发行版、glibc/libstdc++、系统 libmpv 版本及其包来源；
不能只记录 media-kit Dart 包版本。

### 2.5 OHOS

官方 `main` 当前没有 OHOS libs package，也没有官方 OHOS libmpv Release URL。采用
官方主分支时必须在以下方案中明确选择一个：

1. 推荐过渡方案：从官方最新 `main` 维护最小 OHOS fork，所有需要 fork 的 media-kit
   子包统一固定到同一完整 SHA；
2. 在上游同意的拆分边界内继续完善 PR #1326；
3. 暂停 OHOS 能力，完全采用官方发布包。

在 OHOS 正式合入前，不允许把“官方非 OHOS 平台构建成功”表述为“已完成官方
media-kit 切换”。

## 3. PiliPlusX 当前 fork 的下载来源

以下来源取自 `Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`，用于
说明当前产品与官方基线的差异，不代表这些第三方 Release 已满足可复现构建、许可证、
SBOM 或长期维护要求。

| 平台 | 当前 fork 来源 | 固定版本/资产 | 校验 |
| --- | --- | --- | --- |
| Android arm64-v8a | `Predidit/libmpv-android-video-build` | [`v1.2.7/default-arm64-v8a.jar`](https://github.com/Predidit/libmpv-android-video-build/releases/download/v1.2.7/default-arm64-v8a.jar) | SHA-256 `13e882d96b8cd235425172b022e4a94dfcae5f07985dff85c8d648e7369fa2d1` |
| Android armeabi-v7a | 同上 | [`v1.2.7/default-armeabi-v7a.jar`](https://github.com/Predidit/libmpv-android-video-build/releases/download/v1.2.7/default-armeabi-v7a.jar) | SHA-256 `7f522ed762ea6dfeba93a02e3837c5538790030b9965a03ed3a00276adc7b32c` |
| Android x86_64 | 同上 | [`v1.2.7/default-x86_64.jar`](https://github.com/Predidit/libmpv-android-video-build/releases/download/v1.2.7/default-x86_64.jar) | SHA-256 `aed0fffc99e5e554d48e1af90bc700133c25fbc02615bf1bf17db9299365c481` |
| Android x86 | 同上 | [`v1.2.7/default-x86.jar`](https://github.com/Predidit/libmpv-android-video-build/releases/download/v1.2.7/default-x86.jar) | SHA-256 `9269643264a1c9689116467f313d5e1b23ea56a68d338ab940c5e8fcf07061c6` |
| iOS universal | `Predidit/libmpv-darwin-build` | [`0.6.8 ios universal`](https://github.com/Predidit/libmpv-darwin-build/releases/download/0.6.8/libmpv-xcframeworks_0.6.8_ios-universal-video-default.tar.gz) | SHA-256 `d428641cc6c100de8234eae04e229966e46949eb73fcabd526a008a02e9bf968` |
| macOS universal | 同上 | [`0.6.8 macOS universal`](https://github.com/Predidit/libmpv-darwin-build/releases/download/0.6.8/libmpv-xcframeworks_0.6.8_macos-universal-video-default.tar.gz) | SHA-256 `c396976a267eaaa64bc603f3cc1a2ee02d27c7d5d57935d2458f364afdf0f3cb` |
| Linux x86_64 libmpv | `Predidit/libmpv-linux-build` | [`20260810/libmpv_x86_64.zip`](https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_x86_64.zip) | SHA-256 `45922100e5240bf69a72fa2ae140d5b54e1ed03993a8a3746dc798e3ae8ad6e4` |
| Linux x86_64 headers | 同上 | [`20260810/libmpv_x86_64_header.zip`](https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_x86_64_header.zip) | SHA-256 `c654ee0145167694c7ab55c02810d59b5e73e09c5404b32c0b037b53e42c164d` |
| Linux aarch64 libmpv | 同上 | [`20260810/libmpv_aarch64.zip`](https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_aarch64.zip) | SHA-256 `da0609556e2864dbe828102972edea96173a4be1ad1427a7493942dccb039b9f` |
| Linux aarch64 headers | 同上 | [`20260810/libmpv_aarch64_header.zip`](https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_aarch64_header.zip) | SHA-256 `1333f1717bd2449bd99ffdf3fd4653bdf919c4113d0b49f54f8dbd94a8dc678c` |
| Windows x86_64 | `Predidit/libmpv-win32-video-cmake` | [`20260811 x86_64`](https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/20260811/mpv-dev-x86_64-20260811-git-ad59ff1.7z) | SHA-256 `0161ad026f9ebd418a9b660c8e8c569f7959b5bb8e5f4a63e462ffc73327d4d8` |
| Windows ARM64 | 同上 | [`20260811 ARM64`](https://github.com/Predidit/libmpv-win32-video-cmake/releases/download/20260811/mpv-dev-aarch64-20260811-git-ad59ff1.zip) | SHA-256 `1b0d58db5bc1b24437d63120ae6e1b0d887ec504e53523dc4666893d00e7f4e8` |
| OHOS ARM64 | `ErBWs/libmpv-ohos-build` | [`20260811/libmpv_aarch64.zip`](https://github.com/ErBWs/libmpv-ohos-build/releases/download/20260811/libmpv_aarch64.zip) | 已提交基线 SHA-256 `2bfb9844a7552c450694581b315b26cdf6202eaa57724e9f70f3facfad75163b` |

当前 fork 的 Linux 还下载 mimalloc 2.1.2 源码，来源与官方表相同。Apple SwiftPM
同样按 18 个 framework 分组件下载，完整组件校验值以 `0fa6afe9` 下的对应
`Package.swift` 为准。

## 4. 当前 OHOS 本地产物阻塞

2026-09-05 本地 media-kit 工作树中存在尚未提交的 `libmpv_aarch64.zip`：

```text
SHA-256 999bfba12b9da030b5560ce62188da49cc3be48353d37b56b4167a609be50029
```

本地 CMake 校验值已改成 `999bf...`，但下载 URL 仍指向 ErBWs `20260811` Release；
该公开资产的已提交校验值是 `2bfb...`。这意味着：

- 本地 archive 存在时可以通过校验；
- 删除本地缓存后会下载旧公开资产，并因 SHA-256 不匹配而失败；
- 当前状态不是可供社区 PR、CI 或干净环境消费的发布契约。

解除条件是把新产物发布到不可变且可追溯的 Release，并同步 URL、SHA-256、构建
manifest、源码及 patch commit、许可证、SBOM；或者恢复旧 URL 与旧 SHA。不得覆盖
既有 tag/asset，也不得只提交本地二进制缓存。

## 5. 持续跟踪字段与更新规则

每次 media-kit 或原生依赖升级任务都必须记录：

```text
平台与 ABI：
media-kit 基线 SHA：
框架构建声明版本：
构建仓库最新 Release：
实际下载 URL：
校验算法与摘要：
产物内库名、架构和 SONAME：
上游源码/patch commit：
许可证与第三方许可证：
SBOM/build manifest：
干净缓存重建结果：
目标平台构建结果：
真机播放结果：
最后核对日期：
```

更新规则：

1. 先更新本表的候选记录，不直接修改产品 lock；
2. 比较“官方 main 实际消费版本”和“构建仓库最新 Release”；
3. review 构建脚本、源码版本、patch、许可证和 ABI，不只比较版本号；
4. 在空缓存中验证下载和摘要，再验证目标平台打包；
5. media-kit 各子包必须同一 SHA 升级和回滚；
6. 构建、安装、SDR 播放、原生 HDR 分别记录证据等级；
7. Release URL、摘要或源码来源任一不一致时 fail closed。

## 6. 上游风险观察项

- [`media-kit#1437`](https://github.com/media-kit/media-kit/issues/1437)：报告官方
  Android/iOS 预编译依赖中的 Mbed TLS 无法连接 TLS 1.3-only 服务。PiliPlusX 尚未
  独立复现，升级评估时应加入对应网络样例。
- [`media-kit#1441`](https://github.com/media-kit/media-kit/issues/1441)：报告官方
  Windows 固定的旧 libmpv 在部分 HLS master playlist 上可能黑屏。PiliPlusX 尚未
  独立复现，Windows 基线必须加入 HLS 回归。

这些 issue 是监控线索，不等于当前产品已经确认存在相同故障。

# SDR 跨平台构建证据

更新时间：2026-09-20

本轮将 Web 与原生入口做了条件隔离，并完成可复现的本机构建门：

注：macOS runtime follow-up 行是对早期黑屏记录的最终结果，早期“待验收”描述已被其覆盖。

| 目标 | 证据 | 结果 |
| --- | --- | --- |
| Web | `flutter run -d chrome`；`flutter build web --release --no-wasm-dry-run` | `build/web` 已生成；当前是独立的 URL 播放验证入口，使用单个 HTML video，固定 SDR/tone-map，隐藏原生能力。媒体 URL 必须满足浏览器 codec/CORS 要求；不支持直接组合 B 站分离的 DASH 音视频流，也不等同于完整客户端功能 |
| Android arm64 | `scripts/build_android_arm64_release.sh` | 2026-09-20 成功生成 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`（26.5 MB）。脚本只对构建子进程显式指定 JDK 17；本机默认 JDK 27 不满足当前 AGP 的 JdkImageTransform。`pubspec_overrides.yaml` 同步 Android webview 的项目级 Git override 后，避免其覆盖文件解析到 AGP 9 不支持的 hosted 实现。 |
| Android ABI 与签名 | `unzip -Z1`、`aapt dump badging`、`apksigner verify --verbose --print-certs` | APK 只含 `lib/arm64-v8a/`（`libapp.so`、`libflutter.so`、`libmpv.so` 等），包为 `com.example.piliplusx` 2.1.2+1（minSdk 24、targetSdk 36），SHA-256 `8c611b54e8a33acad4b0834e778346139cea25b32bddf03974649629a6938cb1`。v2 签名通过；因没有 release keystore，签名者是 Android Debug，不能视为可发布的生产签名包。 |
| Android arm64 模拟器启动 | AVD `bluekey-api36-arm64`（API 36 / arm64-v8a）；`adb install -r`、`am start -W`、`dumpsys`、截图 | 安装成功，`com.example.piliplusx/.MainActivity` 冷启动完成（约 7.9 秒）、首屏已绘制且进程为 arm64。随后系统记录 `Input dispatching timed out`，对话框显示 “PiliPlusX isn't responding”；选择 Wait 后 15 秒仍为 `mNotResponding=true`。因此仅安装/首屏通过，模拟器交互运行验收为失败；未关闭应用、未清除数据，保留现场。 |
| Android release metadata | `release_manifest.py` + `verify_release_manifest.py` | manifest 与 `SHA256SUMS` 通过（4 个文件） |
| macOS release | `flutter build macos --release`（Xcode 26.6、CocoaPods 1.17.0） | universal app：`build/macos/Build/Products/Release/PiliPlusX.app`；分发 zip：`build/macos/artifacts/PiliPlusX-macos-universal-release.zip`，SHA-256 `bdeec2e39034df591b0e9649e2789894056a8f7013cb58f7ccc50297cfd609b9`。该本地包未签名/未公证；此行为历史构建证据，后续 runtime follow-up 与连续换源记录覆盖其早期黑屏候选结论 |
| iOS device | `flutter build ios --no-codesign` | `build/ios/iphoneos/Runner.app` 已生成（无签名） |
| macOS runtime follow-up | 已重启最新构建；所有平台统一由 media-kit `Video.fit/alignment` 布局，保留 `Transform.flip/RepaintBoundary`，不再使用外层 `FittedBox` 或 macOS 专用分支 | 已登录 SDR 点播显示实际视频画面，弹幕、进度和相关视频正常；统一有限约束渲染路径通过首帧验证 |
| macOS 连续相关视频换源 | 当前最终代码的全新 debug App 中连续切换 Linksphotograph 视频，覆盖 SDR、HLG、Dolby Vision tone-map；记录 mpv、texture ID、控制层和 native 生命周期日志 | 修复前色彩处理模式变化会错误触发 Texture 重建并使 `_videoController=null`，导致画面、进度条和视频内信息整层消失甚至 native 崩溃。修复后压力切换始终复用同一 player handle/texture ID，无输出 Dispose/Create，进程持续存活；窗口快照同时确认视频帧和带当前位置/总时长的进度条。Android/Pink 真正的载体切换仍保留并待 HDR 真机压力测试 |
| 历史 macOS artifact | 曾重新打包早期直接 texture 候选的 universal app | `build/macos/artifacts/PiliPlusX-macos-universal-release.zip`；SHA-256 `eb9b6aa544b69bd16d820e6b9af6e214dd379f6f42f8eef5a592ad23fe434faf`。该产物已被当前统一布局与 media-kit 生命周期修复取代，不代表最终提交 |
| iOS simulator | `flutter build ios --simulator` | `build/ios/iphonesimulator/Runner.app` 已生成 |
| Linux arm64 CI | `.github/workflows/linux_arm64.yml` | 已加入原生 `ubuntu-24.04-arm` runner、aarch64 ELF 校验、tar.gz 与 manifest；本机无法执行 Linux 构建 |
| Linux arm64 Lima | Lima `default`（Ubuntu 24.04，`uname -m=aarch64`） | release ELF、tar.gz、arm64 deb 已生成；`verify_binary_arch.py`、manifest/SHA 校验通过；tar SHA-256 `dc1f2d270c2bfdbb812cf6dd300200f647993af2d3c4367195b7a00c17c913a1`，deb SHA-256 `fa94815ade8ff72b18ca7be82f266556659579b06d616ca7bea057bbca2bc314`；Xvfb 启动保持 20 秒后回收（仅启动/生命周期证据，不是视频呈现证据） |
| Dart/HDR tests | `flutter analyze --no-fatal-infos`; `flutter test test/plugin/pl_player/hdr_test.dart` | analyze 通过（仅既有 info）；HDR 22 项通过 |

## Android arm64 release 构建

在仓库根目录运行：

```bash
scripts/build_android_arm64_release.sh
```

脚本固定构建 `--release --split-per-abi --target-platform android-arm64`，产物是 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`。它只为该构建进程设置 `JAVA_HOME`，不会更改终端或系统默认 Java。

默认使用 Homebrew 的 `openjdk@17`：`/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`。若 JDK 17 位于其他位置，调用时覆盖即可：

```bash
PILIPLUS_ANDROID_JAVA_HOME=/path/to/jdk-17 scripts/build_android_arm64_release.sh
```

JDK 17 缺失时，脚本会在构建前失败并给出安装提示；不要让构建回退到默认 JDK 27。现有 AGP 在 JDK 27 上会于 `JdkImageTransform` 失败。

Linux x64 已在 `dev`（Ubuntu 22.04 x86_64）构建并生成 tar.gz、deb、rpm，架构及 manifest/SHA 校验通过；产物已同步到本地忽略的 `remote-release-linux/`，其中 `metadata/SHA256SUMS` 校验全部通过；Xvfb 仅可作为启动/窗口生命周期测试。固定 OHOS Flutter commit `aa76d9b...` 已验证为 Dart 3.12.2，远端临时副本 `flutter pub get` 成功；SSH dev 已识别 OHOS SDK 和 hvigor，完整 `lib/main.dart` kernel snapshot 及 unsigned arm64 HAP 已构建通过，HAP 内含 `libflutter.so`、`libapp.so`、`libmpv.so`；`verify_artifact.py` 只验证 ABI 与包结构，未签名状态来自固定构建配置和 `--no-codesign`，不由 ZIP 条目推断。产物位于 `/home/wuweiwei1/PiliPlusX-ohos-344/build/ohos/hap/entry-default-unsigned.hap`，SHA-256 为 `7134be623545a6061b6035fdb424811b8fe7be4d1eb47dd044b5cfc76ad225dc`。主平台 HDR 单测（22 项）、HDR channel 校验、Web release、macOS debug、iOS device 无签名构建及 Android arm64 release 均已通过；Android 使用本机 OpenJDK 17，只有第三方插件 compileSdk/Kotlin 迁移预警。OHOS 目前已有本机模拟器和实体机，已完成匹配 profile 的 HAP 安装与 Ability/首页启动；模拟器视频播放受 media-kit guard 限制，实体机视频首帧及后续播放矩阵继续单独验收。Windows 本机虽有 Windows 11 ARM VMware 镜像，但 `vmrun start` 报告该 VM 需要密码，无法启动或取得来宾访问通道；因此 Windows x64 保持未验收。本文件不把静态 workflow/CI 配置当作运行验收。

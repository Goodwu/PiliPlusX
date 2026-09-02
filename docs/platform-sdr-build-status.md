# SDR 跨平台构建证据

本轮将 Web 与原生入口做了条件隔离，并完成可复现的本机构建门：

注：macOS runtime follow-up 行是对早期黑屏记录的最终结果，早期“待验收”描述已被其覆盖。

| 目标 | 证据 | 结果 |
| --- | --- | --- |
| Web | `flutter build web --release --no-wasm-dry-run` | `build/web` 已生成；浏览器入口使用 HTML video，固定 SDR/tone-map，隐藏原生能力 |
| Android arm64 | `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home flutter build apk --release --split-per-abi --target-platform android-arm64` | `app-arm64-v8a-release.apk` 已生成 |
| Android ABI | `python3 scripts/verify_artifact.py --platform android --abi arm64-v8a .../app-arm64-v8a-release.apk` | 通过；SHA-256 `8b9b0aa9ad40f5fa25aa963e0273690754db6af9bcb6fa4a9bd2bae32cfab96a` |
| Android release metadata | `release_manifest.py` + `verify_release_manifest.py` | manifest 与 `SHA256SUMS` 通过（4 个文件） |
| macOS release | `flutter build macos --release`（Xcode 26.6、CocoaPods 1.17.0） | universal app：`build/macos/Build/Products/Release/PiliPlusX.app`；分发 zip：`build/macos/artifacts/PiliPlusX-macos-universal-release.zip`，SHA-256 `bdeec2e39034df591b0e9649e2789894056a8f7013cb58f7ccc50297cfd609b9`。该本地包未签名/未公证。窗口改为启动后立即显示，并将 macOS media-kit 输出切到 pixel-buffer（关闭 OpenGL 硬件纹理）作为黑屏修复候选；已登录点播确认“音频/进度前进但画面全黑”，本轮复测时系统再次锁屏，首帧修复尚未验收 |
| iOS device | `flutter build ios --no-codesign` | `build/ios/iphoneos/Runner.app` 已生成（无签名） |
| macOS runtime follow-up | 已重启最新 release，并绕过 `Transform.flip/FittedBox/RepaintBoundary` 组合，直接挂载 macOS `Video` texture | 已登录 SDR 点播显示实际视频画面，弹幕、进度和相关视频正常；macOS 黑屏修复通过首帧验证 |
| macOS artifact refresh | 重新打包直接 texture 修复后的 universal app | `build/macos/artifacts/PiliPlusX-macos-universal-release.zip`；SHA-256 `eb9b6aa544b69bd16d820e6b9af6e214dd379f6f42f8eef5a592ad23fe434faf` |
| iOS simulator | `flutter build ios --simulator` | `build/ios/iphonesimulator/Runner.app` 已生成 |
| Linux arm64 CI | `.github/workflows/linux_arm64.yml` | 已加入原生 `ubuntu-24.04-arm` runner、aarch64 ELF 校验、tar.gz 与 manifest；本机无法执行 Linux 构建 |
| Linux arm64 Lima | Lima `default`（Ubuntu 24.04，`uname -m=aarch64`） | release ELF、tar.gz、arm64 deb 已生成；`verify_binary_arch.py`、manifest/SHA 校验通过；tar SHA-256 `dc1f2d270c2bfdbb812cf6dd300200f647993af2d3c4367195b7a00c17c913a1`，deb SHA-256 `fa94815ade8ff72b18ca7be82f266556659579b06d616ca7bea057bbca2bc314`；Xvfb 启动保持 20 秒后回收（仅启动/生命周期证据，不是视频呈现证据） |
| Dart/HDR tests | `flutter analyze --no-fatal-infos`; `flutter test test/plugin/pl_player/hdr_test.dart` | analyze 通过（仅既有 info）；HDR 20 项通过 |

Linux x64 已在 `dev`（Ubuntu 22.04 x86_64）构建并生成 tar.gz、deb、rpm，架构及 manifest/SHA 校验通过；产物已同步到 `remote-release-linux/`，其中 `metadata/SHA256SUMS` 校验全部通过；Xvfb 仅可作为启动/窗口生命周期测试。`dev` 已安装固定 OHOS CLI `26.0.0.621`、OpenJDK 17 和 Flutter OHOS commit `aa76d9b...`，但 HAP 编译仍被 Flutter 3.44 与项目当前 API（BottomSheet、DraggableScrollableSheet、SelectableRegion 等）不兼容阻塞，未生成 HAP，故 OHOS 仍标记为环境/源码兼容性阻塞。Windows 本机虽有 Windows 11 ARM VMware 镜像，但 `vmrun start` 报告该 VM 需要密码，无法启动或取得来宾访问通道；因此 Windows x64 保持未验收。本文件不把静态 workflow/CI 配置当作运行验收。

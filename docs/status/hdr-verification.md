# HDR 验证账本

更新时间：2026-09-05

这份账本只记录已经执行的验证。构建成功、显示器能力探测或单元测试，均
不能替代真实设备上的原生 HDR 验收。

## 2026-09-05 依赖一致性复核

当前 `pubspec.lock` 的 9 个 media-kit 包均指向
`Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`，但 8 个 workflow
中的 lock 校验和发布 manifest 仍固定为
`73536efdda482f2d5eefe2feb7038db419944b96`。只读复核结果：

| 检查 | 结果 | 结论 |
| --- | --- | --- |
| `verify_media_kit_lock.py ... --commit 0fa6afe9...` | 通过 | 当前 lock 内 9 个包来源一致 |
| `verify_media_kit_lock.py ... --commit 73536ef...` | 失败 | `73536ef...` 不再是当前产品 lock |
| `verify_workflow_media_kit_refs.py --commit 73536ef...` | 通过 | 当前 8 个 workflow 仍一致引用历史 SHA |
| `verify_workflow_media_kit_refs.py --commit 0fa6afe9...` | 失败 | 当前 lock 与 workflow/manifest 尚未完成一致性迁移 |

因此当前只能声明“lock 内部一致”，不能声明“lock、workflow 和发布 manifest 一致”。
更新 CI SHA、重跑对应构建和生成新发布 manifest 应作为独立实现任务；本次文档完善
不修改 workflow。原生依赖下载来源另见
[media-kit 原生依赖来源与跟踪基线](../reference/media-kit-native-dependencies.md)。

## 2026-09-04 阶段性验证

本阶段已完成 macOS HDR 显示器上的原生输出验收；跨屏和全屏生命周期仍需补测。

| 项目 | 证据 | 结果 |
| --- | --- | --- |
| SDR 视频播放 | 最新 Debug App 实际播放截图 | 已验证：画面正常，无黑屏 |
| SDR 上 HDR 画质保护 | 播放器画质菜单和详情页菜单 | 已验证：杜比视界、HDR 真彩置灰且不可点击 |
| SDR 默认画质降级 | `queryVideoUrl` 的最终 `targetVideoQa` 保护 | 已实现：默认 HDR 画质在 SDR 上选择最高可用 SDR 源 |
| HDR 显示器原生输出 | 最新 Debug App 实际播放 BV1uZ4y1U7h8；`CAMetalLayer` `active=true`，`rgba16Float`/BT.2020，实际画面可见，播放中 EDR headroom=2.03048 | 通过 |
| HDR/SDR 跨屏移动 | 无跨屏实测证据 | 未验证 |
| 显示器变化通知 | macOS 原生屏幕变化通知 -> `EventChannel` -> Dart | 已实现，待 HDR/SDR 实机验证 |
| media-kit 双目标过渡渲染 | `Goodwu/media-kit` 当前工作树 | 已实现：同时维护 Texture 回退帧与 native half-float 帧，surface 按 active 选择 |
| PiliPlusX macOS Debug 构建 | `flutter build macos --debug --no-pub` | 成功，产物为 `build/macos/Build/Products/Debug/PiliPlusX.app` |
| HDR 决策测试 | `flutter test --no-pub test/plugin/pl_player/hdr_test.dart` | 25 项通过 |

### 帧节奏复核

在 23e4646（避免 macOS HDR 双重渲染）之后重新构建并播放上述视频。native
surface 保持激活且画面连续；渲染器每次 mpv 更新只选择一个目标，不再同时执行
Flutter Texture 和 half-float Metal 两次 libplacebo 渲染。该结果作为当前帧率抖动
修复后的实机证据；尚未建立独立的 FPS/Present 间隔采样器。

当前阶段仍需在 HDR/SDR 跨屏和全屏生命周期中验证：事件只触发一次有效换源，
HDR 输出状态、画面、帧率和播放进度均保持正常；返回 HDR 屏幕后不能出现黑屏
或重复重载。

## 历史及分阶段已验证

| 项目 | 证据 | 结果 |
| --- | --- | --- |
| 2026-09-02 media-kit 历史来源固定 | `verify_media_kit_lock.py pubspec.lock --commit 73536efdda482f2d5eefe2feb7038db419944b96` | 该阶段 9 个 media-kit 包均指向 `Goodwu/media-kit` 同一验证 SHA；不代表 2026-09-05 当前 lock |
| 2026-09-02 workflow 历史引用固定 | `python3 scripts/verify_workflow_media_kit_refs.py --commit 73536efdda482f2d5eefe2feb7038db419944b96` | 8 个 workflow、9 个 lock 检查和 8 个发布 manifest 引用均使用该历史 SHA；当前 workflow 仍未迁移到 `0fa6afe9...` |
| HDR 决策 | `flutter test --no-pub test/plugin/pl_player/hdr_test.dart`（2026-09-06） | 25 项通过，覆盖 SDR、HDR10、HLG、Dolby Vision、HDR Vivid、元数据不完整回退、HCPP 门槛、能力解析、生命周期状态拆分和输出配置序列化 |
| HDR channel 契约 | `python3 scripts/verify_hdr_channel.py` | Android、Pink、iOS、macOS、Windows、Linux、OHOS 共 7 个端点统一使用 `piliplusx/hdr_capabilities`，并检查结构化输出和能力拆分字段 |
| 原生输出生命周期契约 | `python3 scripts/verify_hdr_channel.py`、`flutter test test/plugin/pl_player/hdr_test.dart` | 7 个端点均提供 `probe`、`configureOutput`、`resetOutput`；配置结果未获系统/播放器确认时统一 active=false；Dart 分离 capable/active 状态 |
| Dart 静态检查 | `flutter analyze`（HDR controller、model、两个 channel、view 和测试共 6 个文件） | 无问题 |
| 发布校验脚本 | `python3 -m unittest discover -s test -p '*_test.py'` | 5 项通过，覆盖 manifest/hash、Android native parity、Android/OHOS ABI 包结构及错误架构拒绝 |
| 全平台探测改动回归 | `python3 scripts/verify_hdr_channel.py`; `python3 -m unittest discover -s test -p '*_test.py'`（2026-09-06） | 7 个 HDR channel 端点通过；发布校验 5 项通过 |
| Android patch 可应用 | material patch 链按 `patch.ps1` 顺序在临时副本应用 | 已内置 patch 会安全跳过，`scaffold_android.patch` 可应用，真实冲突仍阻断 |
| 远端 fork | `Goodwu/media-kit` 分支 `integration/piliplusx-hdr-08b` | 当前提交 `0dd1535ec622c0e8560551b15800c75c3a07da95` |
| 公共 HDR 生命周期分支 | `Goodwu/media-kit` 分支 `integration/piliplusx-hdr-public-api` | `ad22c36a9986a8418c81829821962009425cf5e5`，提供跨平台默认安全接口、Android PlatformView surface/dataspace 生命周期，以及 Linux system-libmpv ABI 回退；PiliPlusX 已加入兼容桥接，待各平台后端实现后再统一更新 lock |
| 公共 API CI | GitHub Actions run `33548127882` | 16 个构建 job 和 4 个 package test job 全部成功（含 Android、iOS、Windows x64/ARM64、macOS、Linux、Web），1 个发布 manifest job 按分支条件跳过；仅记录为编译证据，不作为原生 HDR 验收 |
| 公共 API 最新 CI | GitHub Actions run `33555639764` | 提交 `ad22c36a9986a8418c81829821962009425cf5e5` 的 17 个构建/打包 job 与 Linux、macOS、Web、Windows 四个长时 package-test job 全部成功；仅记录为编译/测试证据，不作为原生 HDR 验收 |
| Darwin 输出重建屏障 | `Goodwu/media-kit` 分支 `fix/darwin-video-output-rebuild-barrier` | `73536efdda482f2d5eefe2feb7038db419944b96`；同 handle 的 Create/Dispose 已串行化，macOS 最终压力切换已通过，iOS 仍缺运行时回归 |
| OHOS unsigned HAP | SSH `dev`：`flutter build hap --release --no-codesign` + `verify_artifact.py` | 完整 kernel snapshot 与 arm64 HAP 通过；包内含 `libflutter.so`、`libapp.so`、`libmpv.so`；SHA-256 `7134be623545a6061b6035fdb424811b8fe7be4d1eb47dd044b5cfc76ad225dc` |
| 主平台回归 | `flutter test test/plugin/pl_player/hdr_test.dart`; `python3 scripts/verify_hdr_channel.py`; Web/macOS/iOS/Android 构建命令 | HDR 22 项、channel contract、Web release、macOS debug、iOS device 无签名和 Android arm64 release 构建均通过 |

### macOS 连续换源黑屏与崩溃（2026-09-02）

在 macOS debug App 中连续切换 Linksphotograph 的相关视频（片源以 Dolby
Vision/HLG 为主）完成了交互式复现与修复验证：

- 黑屏时 mpv 仍报告 `playing=true`、`vo-configured=yes`，播放位置继续增长，且
  `showControls=true`；因此故障不是解码停止，而是 Flutter 播放器表面失效。
- 画面、进度条和视频内信息总是一起消失。原因是 HDR 元数据从 SDR、HLG、Dolby
  Vision 之间变化时，Android 原生 HDR surface 专用的 `_rebuildVideoOutput` 也在
  macOS 被调用。重建期间 `_videoController` 会暂时为 `null`，并反复注销、注册
  Flutter texture；累积后表现为整层黑屏，严重时触发 native 崩溃。
- 重建判断现在只比较输出载体。macOS 的 SDR 与 HDR tone-map 都使用同一 Texture，
  因此只更新 mpv 的 target primaries、transfer 和 tone mapping 参数；Android 在
  Texture 与 HCPP 拓扑真正变化时仍可重建。原有相关视频切换逻辑保持不变。

该结果只证明 macOS texture tone-map 路径。Darwin 根因修复已下沉到
`Goodwu/media-kit` 提交 `73536efdda482f2d5eefe2feb7038db419944b96`：旧
`VideoOutput` 的 worker、Flutter texture 注销和 native texture 释放现在有可等待的
完成屏障，同一 handle 的 Create/Dispose 通过队列串行执行。PiliPlusX 已移除 macOS
特殊渲染与平台延时等临时规避；视频缩放统一交给 media-kit `Video` 自身的
`fit/alignment`，不再使用外层 `FittedBox` 制造无界约束。重建期间仍保留跨平台
nullable controller 防护，避免合法的短暂无输出状态导致整层构建失败。该阶段依赖
曾锁定到该提交；当前产品 lock 已更新为 `0fa6afe9...`。Android/Pink 的 HCPP/SurfaceView
可能需要在原生 HDR surface 或 dataspace 改变时重建，不能据此删除 Android 重建。
当前 Android 重建已串行化，HCPP dataspace 也改为等待新 controller 创建完成后在
同一事务内提交；candidate 变为 active 时因载体未变，不再重复重建。但尚无 HDR 真机连续执行
`SDR -> HDR10/PQ -> HLG -> Dolby Vision -> SDR` 的运行证据；需要同时记录
`nativeOutputActive`、实际 dataspace、系统 HDR 指示、画面、进度控制层和崩溃日志，
通过后才能声明 Android 该路径已验收。

2026-09-03 又以当前最终代码全新构建并启动 macOS debug App。快速连续切换
Linksphotograph 的 SDR、HLG 与 Dolby Vision 视频期间，player handle 与 texture ID
始终保持不变，没有输出 Dispose/Create 或 `_videoController=null` 重建，进程持续存活；
运行中的窗口快照同时确认了实际视频帧，以及包含当前位置和总时长的进度条。该结果
覆盖了统一 `Video.fit/alignment` 布局与最终依赖 SHA，但仍只属于 macOS Texture
tone-map 路径，不替代 Android HDR 真机验收。

## 未完成或证据不足

- 本机使用 OpenJDK 17 构建当前 Android arm64 release APK 成功，并通过 ABI
  校验；现有 compileSdk 与 Kotlin 迁移信息是第三方插件预警，不影响本次产物。
- Apple（iOS）、Windows、Linux、OHOS 的原生 HDR 输出尚未接通或证明；当前保持
  Texture tone-map，并在能力状态中报告回退原因。
- 尚未取得 Android HDR 真机与 SDR 设备的系统色彩空间、播放器元数据和
  HDR/SDR ratio 记录；因此不能开启全局 `HdrMode.auto`。
- 完整播放矩阵（DASH、缓存、切换、分 P、旋转、全屏、PiP、后台、字幕、
  弹幕、截图）尚未完成逐平台真机验收。

## 历史环境复核（2026-09-02）

本节保留当日环境快照，不代表当前 OHOS 设备状态。2026-09-05 已有模拟器和实体机
运行证据，当前结论见 [OHOS 开发总结](ohos-development-summary.md) 和
[OHOS 运行状态](ohos-runtime-status.md)。

- 本机已检测到 Xcode 26.6、Flutter 3.47.2 和 macOS desktop target；`flutter
  devices` 没有 Android 或 iOS 真机，`adb devices` 为空。
- 本机 `flutter build macos --debug` 已完成，生成 `build/macos/Build/Products/Debug/PiliPlusX.app`；
  Swift/InAppWebView 仅有上游弃用警告。此前 release 的 Swift package resolution
  等待记录保留为历史限制，不覆盖本次 debug 成功证据。
- `dev` SSH 目标已确认是 x86_64 Ubuntu 22.04；GTK、mpv、Wayland headers、
  Clang 和 Flutter 3.47.2 已安装，并同步了本机可用的 Git/hosted pub 缓存。
  `flutter pub get --offline --enforce-lockfile` 已成功完成；该主机没有可见 GPU、
  `DISPLAY` 或 `WAYLAND_DISPLAY`，因此当前仍不能做 Linux native HDR 验收。Lima
  当前为 aarch64，不能替代 Linux x64 目标；VMware Fusion 已安装但未启动
  Windows 客户机。
- 在补齐依赖并应用 Flutter framework patches 后，Linux release 构建已进入
  Ninja C++ 阶段；项目自身 `linux/runner/my_application.cc` 成功编译，随后第三方
  `desktop_webview_window` 在 Ubuntu 22.04 的 libsoup 2.4 头文件下失败：
  `g_date_time_get_seconds(SoupDate*)` 类型不匹配。该错误来自依赖版本兼容性，
  不是 HDR channel 或 runner 代码错误；CI Linux 构建仍作为独立编译证据保留。
- 在远程临时目录修正该第三方兼容调用后，34 个 Ninja 编译/插件链接步骤均通过，
  但最终链接被 media-kit 下载的 `libmpv.so.2` 阻断：该二进制要求
  `GLIBC_2.38/GLIBCXX_3.4.32`，而 Ubuntu 22.04 提供较旧运行时。该结果证明项目
  runner、Linux channel 和 media-kit 插件源码已编译，剩余是预编译 libmpv 的发行版
  ABI 兼容问题，未将临时依赖修改写回仓库。
- media-kit 公共分支随后提交 `201617c6dd093f854c1753b03ccc17c1b3faebe6`，加入
  `MEDIA_KIT_USE_SYSTEM_LIBMPV=ON` 选项；在 `dev` Ubuntu 22.04 以该选项构建后，
  `flutter build linux --release --no-pub` 成功生成 x86_64 bundle。对应 CI run
  `33555423714` 已触发（随后因 concurrency 被新提交取消）；随后自动选择旧 glibc
  system-libmpv 的提交 `ad22c36a9986a8418c81829821962009425cf5e5` 已触发 CI run
  `33555639764`，该 run 已完整成功。
- 在 `dev` 的最终复验中清除 CMake 选项后，media-kit 自动检测到 `glibc 2.35` 并
  选择系统 `/usr/lib/x86_64-linux-gnu/libmpv.so`；Linux x86_64 ELF binary 已成功
  生成。该验证使用远程临时工作目录，不改变 PiliPlusX 本地工作树。
- 该 SSH 会话没有 `DISPLAY` 或 `WAYLAND_DISPLAY`；启动 bundle 得到 GTK
  `cannot open display`，因此远程环境只能证明构建，不能执行桌面启动或 HDR/SDR
  运行时验收。
- `dev` 的 OHOS SDK 自带 `hdc` 可执行文件，但 `hdc list targets` 返回 `[Empty]`；
  SDK Emulator 启动时报告 `libQt5Core.so.5` 动态库加载失败，故 HAP 尚未安装运行。

## 复验入口

```sh
# 当前 lock：应通过，证明 9 个 package 的 resolved-ref 一致。
python3 scripts/verify_media_kit_lock.py pubspec.lock \
  --commit 0fa6afe9cd9af8d8437919257d81a27c643f2f63

# 当前 workflow 的历史固定值：应通过，但不证明与当前 lock 一致。
python3 scripts/verify_workflow_media_kit_refs.py \
  --commit 73536efdda482f2d5eefe2feb7038db419944b96

# 目标一致性检查：在 workflow 完成迁移前预期失败。
python3 scripts/verify_workflow_media_kit_refs.py \
  --commit 0fa6afe9cd9af8d8437919257d81a27c643f2f63
flutter test test/plugin/pl_player/hdr_test.dart
flutter analyze lib/plugin/pl_player/models/hdr.dart \
  lib/plugin/pl_player/hdr_android.dart test/plugin/pl_player/hdr_test.dart
```

真实设备记录须先通过 `python3 scripts/verify_hdr_evidence.py <record.json>`；
模板见 `docs/examples/hdr-device-evidence.example.json`。模板中的占位值不能作为验收证据。

## CI 长测试说明

`media_kit/test/src/player/player_test.dart` 不是只做快速单元测试：当前文件有
81 个 test declaration 和 102 个显式 `Future.delayed`，覆盖真实媒体打开、
播放、HTTP header、playlist、seek 和状态切换等测试；其中 56 个测试声明了
显式 timeout，最大为 5 分钟。测试中存在多处 30 秒、45 秒、1 分钟及更长的等待；
CI 还分别在 Linux、macOS、Windows 和 Web runner 上执行完整测试集合。因此
单个 package test 超过 30/45 分钟并不能单独证明 runner 卡死。应以 job
handle、测试步骤是否仍为 `in_progress`、以及最终日志为准；不得用未经测量的
workflow timeout 截断该测试集合。

### Run 33521950254 的实际结果

远端 `Goodwu/media-kit` 分支 `integration/piliplusx-hdr-08b`、提交
`dc72c14f4ef1b61ec4dede9a53e7d0ce55a827e5` 的完整日志已取得：

| Job | 开始 | 结束 | 结果 |
| --- | --- | --- | --- |
| Web | 14:51:08Z | 15:22:13Z | 57 passed, 30 skipped |
| Linux | 14:51:08Z | 15:27:41Z | 77 passed, 18 skipped |
| Windows | 14:51:09Z | 15:28:45Z | 77 passed, 18 skipped |
| macOS | 14:51:10Z | 15:29:54Z | 77 passed, 18 skipped |

整条 workflow 为 `success`，20 个 job 成功、0 个失败或取消；发布 metadata
job 因非默认分支条件而跳过。上述证据说明该测试集合在不同平台确实可能运行
超过 30 分钟，但本次没有因 30/45 分钟限制中断。

OHOS run `33526479029` 使用旧工具链时在依赖解析阶段失败：Flutter OHOS
commit `3162ec7f` 内置 Dart `3.9.2`，而 `file_picker 12.1.3` 要求 Dart
`>=3.10.0`；将其降级到 `11.0.3` 又会与 `media_kit_video` 的 `win32 ^6`
约束冲突。修复提交 `6393db1a` 已改用固定的 OHOS Flutter commit
`aa76d9bb`（Flutter tool 要求 Dart `^3.10.0-0`），并保留 `file_picker 12.1.3`。
验证 PR `Goodwu/media-kit#1` 的首次 run `33527854415` 已失败在依赖解析：
OHOS Flutter fork 的浅检出没有 release tag，Flutter 报告版本为
`0.0.0-unknown`，因此 `file_picker 12.1.3` 被拒绝。提交 `4f154b66` 已在
固定 commit 上创建本地 `3.44.9+ohos` build-metadata tag；后续 run 已确认依赖
解析通过。该 PR 只包含 OHOS HAP job，主 CI 的完整矩阵已限定为 `main/dev`
目标 PR。

后续验证显示 `3.44.9+ohos` 的依赖解析已成功，但使用 OHOS SDK
`5.1.0.125 (API 18)` 构建时出现 29 个 ArkTS API 编译错误，使用
`6.1.1.125 (API 24)` 仍有 15 个错误；最终固定到 CLI `26.0.0.621` 后构建通过。

最终 OHOS 验证 PR 已合并到 `integration/piliplusx-hdr-08b`，合并提交为
`0dd1535e`。run `33534063631` 完整成功：使用固定 Flutter OHOS commit
`aa76d9bbeee7806a87dbd202d2550dfd11550b82`（CI 标记为 `3.44.9+ohos`）和
HarmonyOS CLI `26.0.0.621`，严格解析 `pubspec.ohos.lock`，以
`--no-codesign` 生成 `entry-default-unsigned.hap`，并验证 HAP 内的
`libs/arm64-v8a`、manifest 和 SHA256。manifest 中记录的 HAP SHA256 为
`fdeeb31b16d8ea7d5ff17465bf7770d87d26b899e30e00f564a0c6c8474f8aab`。

Windows ARM64 的首次失败 run `33534958536` 已定位为 Flutter detached checkout
报告 `0.0.0-unknown`，并非 ARM64 编译失败。提交 `09b8fa4a` 在固定 Flutter
commit `d3b14c876900e553bc736ca19295fc09e3853e8e` 上创建本地 `3.47.2` tag；
修复 run `33536180435` 已验证依赖解析、Windows ARM64 构建、打包和 artifact
上传均成功。该 run 后续因重复 package tests 被取消，不影响上述已完成 job。

远端 fork 的手动构建 run `33537336517` 使用 `run_package_tests=false`，四组
长 package tests 均为 `skipped`，构建矩阵独立运行；对应改动已提交到 draft PR
`Goodwu/media-kit#2`。

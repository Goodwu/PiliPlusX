# OHOS 运行状态与近期回归记录

更新时间：2026-09-04

本文件记录 2026-09-04 在 OHOS 模拟器和实体手机上的实际运行证据，以及图标、播放器手势和白屏回归的最终结论。

## 当前结论

- OHOS arm64 HAP 可以在模拟器和实体手机上安装并启动。
- 模拟器和实体手机均已验证首页能正常绘制，白屏问题已修复。
- OHOS 应用图标已改为与 Android 同源的绿色 `P`，不再使用此前错误的蓝色机器人头像。
- 播放器触摸代码路径已恢复：左侧上下滑动调节亮度，右侧上下滑动调节音量；实际调节效果仍需在实体机播放视频时专项回归。
- 播放器视频区域的黑屏布局问题已修复：`media-kit_video` 的 `Video` 显式接收播放器区域的宽高约束。
- 本次白屏不是本地与 `dev` 的关键源码不同步，而是平台判定范围过大造成的启动回归。

### 侧滑亮度/音量调试结论

2026-09-04 真机调试日志确认：左右边缘 pointer 事件、区域判定和亮度动画
均能进入；右侧音量链路能够调用 `setVolume`。原有亮度调用依赖
`screen_brightness_platform_interface` 的默认 MethodChannel，但 OHOS 工程没有
对应插件实现，因此只更新了应用内动画，未改变实际屏幕亮度。现已通过
`harmonyChannel.setWindowBrightness` 接入 OHOS `Window.setWindowBrightness(0..1)`
窗口 API；v4 HAP 已编译、签名并安装，真机已观察到亮度反馈从 45% 调整到 89%，
右侧音量日志也连续产生实际数值更新。

## 回归原因与修复边界

播放器原先只在 Android/iOS 上走移动端触摸注册路径。将 OHOS 直接加入全局 `PlatformUtils.isMobile` 后，手势可以进入移动端路径，但同时触发了应用启动阶段的移动端初始化，包括方向、系统 UI 和 `setupServiceLocator()`。

OHOS 在该初始化路径中停在 `paths-enter`，应用窗口创建成功但 Flutter 首页没有绘制，表现为全白屏。修复方式是：

- `PlatformUtils.isMobile` 继续只表示 Android/iOS 的全局移动端能力。
- 新增 `PlatformUtils.isTouchDevice`，仅表示播放器触摸设备，定义为 Android/iOS/OHOS。
- `pl_player/view/view.dart` 的音量/亮度监听、指针注册、触摸交互和分段拖动使用 `isTouchDevice`。
- 应用主入口和播放器控制器中依赖完整移动端插件/方向能力的逻辑继续使用 `isMobile`。

## 图标修复

Android 的启动图标前景来自 `ic_launcher_foreground.xml`，颜色为 `#5CB67B`，图形为绿色 `P`。macOS 使用同一品牌图形的绿色背景白色 `P` 图标。OHOS 原先的 `app_icon.svg` 和 entry 的 `icon.svg` 是蓝色机器人头像，属于错误资源而不是资源加载失败。

以下三个 OHOS 资源现在统一为绿色 `P` 矢量图：

- `ohos/AppScope/resources/base/media/app_icon.svg`
- `ohos/AppScope/resources/base/media/icon.svg`
- `ohos/entry/src/main/resources/base/media/icon.svg`

最终签名 HAP 中已检查 `resources/base/media/icon.svg` 和 `resources/base/media/app_icon.svg` 的内容，均包含 `#5CB67B`，不再包含旧的 `#00AEEC` 机器人图形。

## 安装与启动证据

构建使用 `tool/ohos/build_sign_hap_test.sh`，编译在 `dev:/home/wuweiwei1/PiliPlusX-ohos-344` 完成，签名在本机完成。模拟器和实体机必须使用各自 profile：

- 模拟器：`xiaobai-debug.p7b`
- 实体手机 `2PM0223A18006914`：`com_example_piliplusx.p7b`

使用错误 profile 时，系统会报设备 UDID 不在签名 profile 中；证书/私钥可以相同，但 profile 通常不能直接通用。

## HAP 构建、签名与安装脚本

脚本位置：`tool/ohos/build_sign_hap_test.sh`。

脚本流程固定为：在 `dev:/home/wuweiwei1/PiliPlusX-ohos-344` 编译 unsigned HAP，下载到本机，用小白调试助手 signer 签名并校验；如果传入 `--install`，再通过本机 `hdc` 安装并启动。脚本访问远端构建依赖时使用 `http_proxy` 和 `https_proxy`：`http://127.0.0.1:7890`。

模拟器构建、签名、安装和启动：

```sh
tool/ohos/build_sign_hap_test.sh \
  --version 2.1.3 \
  --output "$HOME/Downloads/PiliPlusX-ohos-emulator.hap" \
  --profile "$HOME/Documents/hap_installer/store/xiaobai-debug.p7b" \
  --install 127.0.0.1:5555
```

实体手机构建、签名、安装和启动：

```sh
tool/ohos/build_sign_hap_test.sh \
  --version 2.1.3 \
  --output "$HOME/Downloads/PiliPlusX-ohos-device.hap" \
  --profile "$HOME/Documents/hap_installer/store/com_example_piliplusx.p7b" \
  --install 2PM0223A18006914
```

常用参数：

- `--build-number NUMBER`：指定 HAP versionCode；默认使用当前时间戳。
- `--remote-host HOST`、`--remote-project DIR`：切换 SSH 主机或远端源码目录。
- `--profile FILE`、`--cert FILE`、`--key FILE`、`--signer FILE`、`--config FILE`：覆盖本机签名材料。
- `--keep-permission`：保留 `WRITE_IMAGEVIDEO`，仅在 profile 已授权该权限时使用。
- 不传 `--install` 时只生成并校验签名 HAP，不操作设备。

查看全部参数：

```sh
tool/ohos/build_sign_hap_test.sh --help
```

设备安装前先确认：

```sh
/Users/wuweiwei1/.local/harmony-tools/bin/hdc list targets
```

资源或入口配置发生变化后，脚本运行前应清理远端 `build/ohos` 和
`ohos/entry/build`，避免 Hvigor 增量缓存继续使用旧资源。脚本默认只临时处理测试
权限，远端 `module.json5` 会在退出时恢复。

实际产物：

- 模拟器：[PiliPlusX-ohos-green-p-fixed-white-screen.hap](../../../../Downloads/PiliPlusX-ohos-green-p-fixed-white-screen.hap)（本机下载目录产物）
- 实体机：[PiliPlusX-ohos-green-p-fixed-white-screen-physical.hap](../../../../Downloads/PiliPlusX-ohos-green-p-fixed-white-screen-physical.hap)（本机下载目录产物）

证据：

- `hdc -t 127.0.0.1:5555 install -r ...` 返回 `install bundle successfully`，重新启动后截图显示首页内容。
- `hdc -t 2PM0223A18006914 install -r ...` 返回 `install bundle successfully`，随后 `aa start` 成功；实体机截图显示首页内容。
- `flutter analyze lib/utils/platform_utils.dart` 通过，`git diff --check` 通过。

## 验收限制

当前模拟器的 `media_kit_video` OHOS 实现明确拒绝 emulator，绕过保护会导致 native 播放进程 SIGSEGV，因此模拟器只能验收安装、启动、界面和触摸事件分发，不能作为视频播放验收设备。视频播放和亮度/音量实际效果应继续在实体手机上验证。

`dev` 构建目录不是 Git checkout，固定脚本编译的是独立远端目录；修改本地源码后必须显式同步到该目录，并在资源变更后清理 `build/ohos` 与 `ohos/entry/build`，否则 Hvigor 可能继续打包旧图标资源。

## 视频渲染与模拟器限制

OHOS 真机曾出现播放器区域黑屏，但应用 CPU 占用正常、控制层仍存在。原因是视频
`Video` 在 OHOS 的 XComponent 尺寸约束下没有获得稳定的显式宽高；补充
`width: maxWidth` 和 `height: maxHeight` 后，实体机已出现实际视频首帧。该修复只
解决 Flutter 视频区域布局，不代表模拟器可以播放视频。

当前 `media_kit_video` OHOS Dart 实现会主动检测 emulator 并抛出
`UnsupportedError`。临时绕过检测后，模拟器 native 播放进程出现 signal 11，日志
包含 `createimage with ctx null` 和 `bind external with nullptr gbuffer 0`。因此不要
删除该 guard；模拟器只用于安装、启动、界面和基础输入验证，视频首帧应在实体机完成。

## 权限记录

小白调试助手的通用模拟器 profile 不包含 `WRITE_IMAGEVIDEO`。测试脚本默认在远端
构建期间临时移除该权限，退出时恢复远端 `module.json5`；需要真实图片/视频写入
能力时，应使用已授权该权限的设备 profile 并传入 `--keep-permission`。

`READ_PASTEBOARD` 曾出现 profile 授权提示，但不是当前 HAP 安装或首页启动的阻塞
原因；是否保留应根据实际剪贴板功能和目标 profile 重新确认，不能仅凭该提示判断
启动失败。

## 视频区域垂直手势与列表滚动（2026-09-04）

### 问题现象

在视频详情页，视频区域上下滑动偶尔不能调整亮度/音量，反而会滚动视频下方的
列表。该问题在竖屏和横屏都出现；竖屏要求关闭左右边缘的亮度/音量调节，且从
视频区域起手时不能影响下方列表。

### 已确认的事件竞争证据

播放器位于 `ExtendedNestedScrollView` 的 header 内，页面结构不是两个完全独立的
触摸控件：

```text
ExtendedNestedScrollView
├── video header
│   └── PLVideoPlayer / MouseInteractiveViewer
└── body / video list
```

实体机 `2PM0223A18006914` 的 arena 日志确认：pointer 已到达播放器，触摸按钮为
主按钮，controls 未锁定，播放器的 `PlayerScaleGestureRecognizer` 也已加入 arena，
但外层 `VerticalDragGestureRecognizer` 先获胜：

```text
Adding: PlayerScaleGestureRecognizer
Adding: VerticalDragGestureRecognizer
Accepting: VerticalDragGestureRecognizer
Self-declared winner: VerticalDragGestureRecognizer
PlayerScaleGestureRecognizer rejected
```

因此问题不是 `setVolume` 节流、按钮过滤或 profile 权限，而是播放器和嵌套列表
共享同一个 Flutter gesture arena。

### 当前验证通过的实现

`lib/common/widgets/gesture/player_gesture_recognizer.dart` 增加了
`PlayerVerticalDragGestureRecognizer`。它继承 Flutter 的
`VerticalDragGestureRecognizer`，将垂直方向的胜出判定阈值设为 1px。播放器在
pointer down 时注册该 recognizer，并将 start/update/end 转换后复用原有的
`_onPanStart`、`_onPanUpdate`、`_onPanEnd`，没有复制亮度、音量、全屏和横向 seek
业务逻辑。

实体机手工验证通过的版本：

- `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-vertical-early-win.hap`
- 构建号：`2026090414`
- 安装返回：`install bundle successfully`
- 结果：视频区域上下滑动不再滚动列表，亮度/音量功能正常。

### 当前实现的局限与后续计划

这是用于验证根因的 arena 抢占方案，不是最终理想的控件边界设计。1px 只是当前
验证成功的参数，尚未证明是必要的最小值；过低可能把轻微垂直抖动误判为垂直手势，
影响横向 seek。

最终应考虑：

1. 将播放器交互层移到 `ExtendedNestedScrollView` 外部，通过独立 overlay/Stack
   覆盖视频区域，使视频区域和列表区域不再共享外层滚动 recognizer。
2. 封装或维护 `ExtendedNestedScrollView` 的小型 fork：pointer down 位于视频
   header 时不注册外层垂直拖拽，位于 body/list 时才注册列表拖拽。

在上述结构完成前，不应继续叠加 raw pointer、全局禁用滚动或更复杂的节流 workaround。
当前代码已移除 arena/pointer/volume 临时日志和全屏禁滚动临时改动；后续若调整
阈值，应对竖屏边缘、横屏边缘、横向 seek 和列表区域分别做 A/B 真机验证。

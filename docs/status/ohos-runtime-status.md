# OHOS 运行状态与近期回归记录

更新时间：2026-09-11

本文件主要保留 2026-09-04 在 OHOS 模拟器和实体手机上的白屏、图标、手势和
Texture 播放回归证据。最新 HDR/native surface 状态见
[OHOS 开发总结](ohos-development-summary.md) 和
[HDR 后端状态矩阵](hdr-backend-status.md)。

> 2026-09-08 更新决策：OHOS native surface/HCPP 在实体机完成 `nativeSurfaceReady`、
> surface attach 和可见首帧验收前，不得作为普通播放默认路径。控制条输入修复与视频
> 输出恢复分开验证；当前产品默认回到已验证可播放的 OHOS Texture 路径，native/HCPP
> 只保留为后续隔离验证目标。

## 当前结论

- OHOS arm64 HAP 可以在模拟器和实体手机上安装并启动。
- 模拟器和实体手机均已验证首页能正常绘制，白屏问题已修复。
- OHOS 应用图标已改为与 Android 同源的绿色 `P`，不再使用此前错误的蓝色机器人头像。
- 播放器触摸代码路径已恢复：左侧上下滑动调节亮度，右侧上下滑动调节音量；实际调节效果仍需在实体机播放视频时专项回归。
- 播放器视频区域的黑屏布局问题已修复：`media-kit_video` 的 `Video` 显式接收播放器区域的宽高约束。
- 本次白屏不是本地与 `dev` 的关键源码不同步，而是平台判定范围过大造成的启动回归。
- XComponent/native surface 的完整生命周期和原生 HDR 输出仍未完成验收；这属于
  HDR 验收缺口，不能用关闭该路径来解决控制条问题。
- 视频主体点击唤出控制条已在 HAP `2026090821` 的实体机 A/B 中确认；后续 native
  surface 验证必须与这条已恢复的 Texture 输入/输出基线分开进行。

### 2026-09-08 输出回归 A/B 结论

实体机 `2PM0223A18006914` 对比验证了近期 OHOS native/HCPP 默认切换引入的黑屏：

- HAP `2026090816`/`2026090820`：OHOS `useNativeSurface=true`，创建了
  `media_kit_ohos_native_surface_0`，但未收到 `nativeSurfaceReady`；控制层存在，
  视频区域整块黑屏。
- HAP `2026090821`：仅关闭 OHOS `useNativeSurface`，恢复 Texture 输出；实体机
  出现实际视频首帧，且点击视频主体能显示完整控制条。
- `HDR decision` 日志在两轮都显示 `surface=texture`，但第一轮仍被
  `_videoConfiguration` 的 OHOS native-surface 默认值切入 `vo=null` 等待链；因此
  该字段不能单独证明实际输出拓扑。

当前最小修复保留触控相关改动，恢复 OHOS Texture 默认输出；iOS/macOS native
surface 配置不变。后续若重新启用 OHOS native/HCPP，必须按“Texture 可播放基线 →
单独启用 HCPP → `nativeSurfaceReady` → surface attach → 可见首帧 → HDR”顺序验收。

### 2026-09-08 控制条交互与 HDR 约束

完整实施计划见 [OHOS 视频区域点击修复计划](../plans/ohos-video-area-tap-fix-plan.md)。

现象：实体机 `2PM0223A18006914` 上，视频主体区域点击无法唤出控制条，黑边区域
可能可以点击。该现象不能通过“能播放首帧”或“控制条在黑边出现”判定为已修复。

应用侧事件链为：

```text
Flutter 全局 pointer route
  → MouseInteractiveViewer 的 opaque Listener
  → _onPointerDown
  → ImmediateTapGestureRecognizer.addPointer
  → arena accept / reject
  → _onTapUp
  → PlPlayerController.controls
  → 控制条动画与 native surface 合成
```

Luna 应按这条链记录同一个 pointer 的 `down/move/up/cancel`，分别测试视频中心、
视频上下黑边和控制条区域。首个缺失点决定排查层级：

| 首个缺失点 | 调查边界 | 允许的修改方向 |
| --- | --- | --- |
| 全局 pointer route | OHOS PlatformView/HCPP 原生承载和 Flutter 事件转发 | 修复原生命中/转发契约，保留 native HDR 输出 |
| `MouseInteractiveViewer` Listener | Flutter 命中树、PlatformView bounds 或上层遮挡 | 调整交互层边界，复用现有 recognizer |
| tap 注册或 arena accept | 手势竞争、`ImmediateTapGestureRecognizer` 的移动取消条件 | 修复 tap/arena 生命周期，不能牺牲拖动和双击 |
| `_onTapUp` 已执行 | 控制条状态、自动隐藏定时器或合成顺序 | 修复状态/动画/层级，不改 HDR 输出选择 |

已有 `Listener(behavior: HitTestBehavior.opaque)`，不能直接增加重复 Listener 或在
`onPointerUp` 强制切换控制条；这会造成同一 pointer 重复注册并绕过拖动取消、双击、
长按和弹幕逻辑。只有确认事件已经进入 Flutter 且现有 Listener 没有覆盖到目标区域时，
才可以建立独立 Flutter 交互层，并复用现有 recognizer 和控制器状态。

每次 A/B 都必须记录：HAP 版本、surface 类型、surface ID/generation、viewport 和
PlatformView bounds、HDR source/output 状态、首帧与控制条行为。任何 A/B 若关闭
native surface、HCPP、HDR 画质或强制 SDR tone-map，均不能作为产品修复结论。

#### 当前代码修复（待实体机验收）

已在实际使用的 OHOS Flutter fork `/Users/wuweiwei1/src/flutter-ohos-e3` 补上
HCPP DISPLAY 节点的输入转发：`PlatformViewsControllerHybrid` 创建 wrapper 时把
`touchDispatcher`/`axisDispatcher` 传给 `DynamicView.buildNodeContainer()`，后者
在 HCPP wrapper 上将 `down/move/up/cancel` 和 axis 事件转回 engine 的
`dispatchTouchToEngine`/`dispatchAxisToEngine`。此前 dispatcher 只被赋值、没有任何
调用点；这使视频 XComponent 即使设置 `HitTestMode.None`，视频主体触摸仍不会进入
Flutter pointer route。该修改不调用 Dart 业务逻辑、不改变手势 arena、不切换
Texture/SurfaceView、不关闭 HCPP 或 HDR。

当前静态证据：两个引擎文件 `git diff --check` 通过，且 dispatcher 的赋值、wrapper
绑定、NodeContainer 调用链均可检索到。配置阶段已确认 DevEco OHOS SDK 可定位，
但 engine 构建入口随后因本机缺少 `vpython3` 退出（code 127），所以本轮没有可直接
产出该 OHOS engine/HAP 的编译环境，尚未声称 ArkTS 编译、HAP 安装或实体机点击验收通过；下一步必须用
该 fork 重新构建 HAP，在 `2PM0223A18006914` 上按计划同时采集视频中心/边缘/黑边的
 Flutter pointer、recognizer、控制条和 native HDR 日志。随后使用临时 `vpython3`
 入口重试，配置又因本地 engine checkout 缺少 Skia/dependency 目录而停在
 `setup_git_versions()`；既有 `dev` 构建机当前 SSH 公钥认证也失败。因此实体机当前
 安装的仍是旧 HAP versionCode `1788642115`，不能作为本修复验收证据。

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

HCPP embedding 还有一条不可省略的产物链：脚本会先用远端修改后的
`flutter-ohos` embedding 源码重建 HAR，再同步 debug/release/profile 的 arm64 缓存 HAR，
保留原有 `libflutter.so` 和模块元数据，并为旧 HAR 留可恢复备份。unsigned HAP 生成后，
脚本从实际 `ets/modules.abc` 检查 `HcppInputRect` 与 `hcpp_input_rects_map`；任一 marker
缺失即 fail-closed，不签名、不安装。源码文件存在或 source SHA 一致本身不能替代这个
ABC 检查。

签名完成后，`tool/ohos/build_sign_hap_test.sh` 会在 HAP 旁生成
`<signed-hap>.manifest.txt`，记录 HAP、`modules.abc`、`libflutter.so`、`libmpv.so`
的 SHA-256，以及 HCPP 和 synthetic Cancel marker。该 manifest 只证明最终产物身份，
不替代实体机呈现、播放中全屏或 HDR 可见输出验收。

2026-09-09 实体机播放中回归 artifact
`/tmp/piliplusx-ohos-verify-20260909-171201` 已完成 20 次完整退出/进入全屏：方向
校验 20/20，视频主体帧进展证据 20/20，HDR decision evidence 和 HCPP 诊断门禁通过，
未观察到灰屏。该结果使用 `VERIFY_ALLOW_VISUAL_PLAYBACK=1`，部分周期无障碍树未暴露
播放按钮，因此不能等同于 20 次语义 playing 证明；颜色仍为 `INCONCLUSIVE`，其余
生命周期、SDR/PQ/HLG 可见切换和 macOS 回归仍未完成。

当日实际产物：

- 模拟器：`PiliPlusX-ohos-green-p-fixed-white-screen.hap`（本机临时下载产物）
- 实体机：`PiliPlusX-ohos-green-p-fixed-white-screen-physical.hap`（本机临时下载产物）

`~/Downloads` 不是可移植的仓库证据位置，不能作为后续任务输入。长期证据应使用版本号、
HAP SHA-256、构建 manifest、签名 profile 类型和可重建命令；需要保留产物时应发布到
明确的 Release 或归档位置，而不是从文档链接个人下载目录。

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

## HDR/SDR 输出拓扑复核（2026-09-08）

实体机 `2PM0223A18006914` 使用 HAP `2026090823` 复测长片
`BV1vY4y1N7TY`：视频 handoff 初始帧可能短暂为黑，随后画面持续可见且截图发生变化。
同一轮 hilog 依次确认：

- `nativeSurfaceReady`、native XComponent surface attach；
- `HDR native decision applied: output=nativeHdr`；
- `HDR dataspace applied: pq`；
- 稳定截图 `/tmp/piliplusx-ohos-tap-fix-20260908/dv-2026090823-later.jpeg`。

SDR 仍保持 `output=sdr, surface=texture`，此前 HAP `2026090822` 已在实体机
复核可见。普通 OHOS SDR 不再默认挂 native surface；HDR candidate 只在源元数据和
显示 HDR 条件满足时挂载，active 仍由 media-kit surface/configuration 结果确认。

为减少手工坐标误差，新增
`tool/ohos/verify_hdr_real_device.sh`：从当前 `uitest dumpLayout` 解析文本 bounds，
自动打开指定历史源、采集 hilog、首帧/稳定截图并给出 native HDR 或 Texture 证据。

## 2026-09-09 持续触控中的 surface 重建

生命周期脚本 artifact：`/tmp/piliplusx-surface-recreate-20260909-r2`。连续播放基线和
重建后连续播放各完成 1 个全屏周期，方向/HDR decision 通过。日志确认 force-stop 前后
进程和 surface 身份变化，并在新 surface 建立后恢复 `output=nativeHdr`；重建初期的
`EGL_BAD_MATCH`、旧 surface/buffer queue 找不到和短暂 `toneMappedSdr` 已保留为待分析
证据。当前没有 Flutter pointer id 级 Down/Move/Cancel/Up 证据，所以生命周期实验不等于
触控终止链通过，也不等于灰屏或 SDR/HDR 可见亮度问题已解决。

## 2026-09-09 HCPP 输入关联诊断首轮

`/tmp/piliplusx-pointer-trace-verify-20260909` 记录到 16 个 ArkTS owner、16 个
NAPI request，以及单调的 attachment epoch/事件时间戳；Dart `PlayerTouchTrace` 观察到
对应 Down/Up。由于最终 HAP 的 `libflutter.so` 未重建，native NAPI item/实际 engine
dispatch 仍未验证；也尚未完成进程不退出的 hide/dispose/page-exit Cancel 测试。

本轮 force-stop/start 只代表冷启动 surface 控制变量，不能作为旧 Dart 发送 Cancel 的要求，
也不能作为播放中全屏灰屏的复现或排除证据。灰屏结论仍只接受连续播放场景。

进程存活探针 `/tmp/piliplusx-process-live-exit-20260909` 前后 PID 均为 `54029`，但没有
观察到可确认的页面 dispose/recreate 或 Cancel；因此只证明未发生 force-stop，不证明 HCPP
终止链通过。探针需要补充播放器页语义前置条件和 attachment 变化门禁。

探针现已增加持续拖动和两次 Back 的脚本化时序，并在 HAP 中加入 `action=dispose`、
`stage=cancel-request` marker；产物为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-pointer-trace-dispose-signed.hap`。实体机安装后
在首个布局采集阶段变为 HDC `USB Offline`，因此取消链尚未在实体机闭环；模拟器仅能验证
构建/脚本条件，不能替代真机触控验收。

实体机恢复后 artifact `/tmp/piliplusx-process-live-exit-20260909-r7` 证明了进程存活的
page-exit：PID `9053` 前后不变，布局从全屏播放器变为首页，出现 owner/request Down、
Dart PointerDown、owner/request Up、Dart PointerCancel 和随后 `action=dispose`。但 Up
先于 dispose，未出现 `stage=cancel-request`，所以不计为 synthetic Cancel 通过；下一步
要改用独立的应用/系统生命周期入口制造 hide/dispose 与 active pointer 重叠。

architect 复核后将 native engine trace 降级为归因增强而非前置门槛：若 ArkTS 已提交 Cancel
但 Dart 未收到，或出现 native 转换/目标 shell 专属断点，再恢复 native rebuild 主线；当前
优先验证现有 ArkTS Cancel 提交、Dart 观察、owner 清理和 attachment 重连。

## 2026-09-09 process-live 钩子修正

`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed-r2.hap` 已通过
构建、HCPP ABC marker gate、签名和 `verify-app`。相关 Dart 单测、静态分析、脚本语法
和 diff 检查均通过。app-side 生命周期钩子已修正为持续重臂，并在同一按压窗口内依次
触发正常 fullscreen back 与 page back，避免把一次全屏返回误当页面销毁。

`/tmp/piliplusx-process-live-test-baseline-20260909-r4` 的连续播放基线通过 1 次全屏
周期，帧进展可见；`/tmp/piliplusx-process-live-exit-20260909-r9` 仍是旧钩子运行结果，
只看到 Down/Up 和存活 PID，没有 dispose/Cancel，因此不计入生命周期验收。r2 HAP 的
实体机重测因目标随后变为 `USB Offline` 未执行；当前不能声称 Cancel 生命周期已闭环。

## 2026-09-09 architect 复核修正与 r5 产物

独立 architect 终审指出上一版 process-live 诊断的返回语义、epoch 来源身份和脚本关联
门禁均不足。现已完成修正：生产 PopScope 语义由 controller handler 驱动，等待全屏状态
退出后再 page pop；探针绑定活动 pointer；HCPP input rect 按 attachment 新建并将不可变
epoch 传入 dispatch，旧 epoch 在入口丢弃；脚本要求同一 pointer/view/epoch 的完整链路和
Dart Cancel。诊断 define 现在仅在 debug 编译生效，release 构建会拒绝该 define。

相关 Dart 单测、analyze、OHOS 脚本语法和 diff-check 通过；stale attachment contract
断言已加入 embedding 测试。最终 r5 HAP：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed-r5.hap`，manifest
记录 HCPP `attachmentEpoch` 与 `stale-attachment` marker，签名和 `verify-app` 通过。

当前仍无真机结论：HDC 只有 `127.0.0.1:5555` 模拟器；r5 尚未在实体机上执行有效的
播放中活动触点生命周期测试，也未关闭重建后新 attachment Down、真实 HDR/灰屏和最终
连续播放回归。

## 2026-09-09 r6 诊断包与契约测试修正

本轮修正了 embedding contract checker 的旧签名匹配，并将 ArkTS 的全触摸类型测试改为
符合 pointer owner 约束的合法序列：`Down -> Move -> Up`、`Down -> Cancel`。契约脚本
现通过：`HCPP input block contract: PASS`；主工程针对性 Flutter 测试 17 项全部通过，
analyze、Python 编译、OHOS 脚本语法和两工作树 `git diff --check` 通过。

最新诊断包已使用同步后源文件重新构建：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed-r6.hap`。
`verify-app` 通过，HAP SHA-256 为
`67bd8365b7df036bf7bf51d94393a9b6334dd7d7dde83ec42b42ca57ec2ebb28`，manifest 中记录
`abc_marker_HcppInputRect=12`、`abc_marker_attachmentEpoch=1`、
`abc_marker_stale_attachment=3`、`abc_marker_cancelTimestamp=1`，并保留
`traceSeq/ownerSeq` 诊断字段。

这仍然只是代码、契约和产物证据，不是实体机通过证据。当前 HDC 仍只有
`127.0.0.1:5555` 模拟器；r6 尚未在实体机完成持续播放活动触点的 page-pop/Cancel/dispose
闭环，也未完成播放中连续全屏灰屏/HDR、竖屏视频主体触控和 surface 重建回归。

同日用 `HDC_TARGET=127.0.0.1:5555` 对 r6 做了模拟器脚本 smoke：安装/启动、布局解析、
搜索和进入视频页均完成，但在 native HDR 前置条件处 fail-closed，未执行全屏回归。该结果
只证明脚本目标选择和前置门禁行为，不替代实体机 HDR/播放证据；此前一次未设置
`HDC_TARGET` 的失败是脚本默认实体机目标不存在，已确认不是 HAP 构建错误。

## 2026-09-09 r7 实体机脚本复测边界

r7 已重新构建、签名并通过 `verify-app`。当前包为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed-r7.hap`，SHA-256 为
`da4f01683194d3cba399a5538873b2c7b3e585d2f08f85c4eaaaeadd870e54cf`。HDC 同时观察到
实体机 `2PM0223A18006914` 和模拟器 `127.0.0.1:5555`，本轮明确使用前者。

实体机复测确认搜索和进入视频页可完成，首帧只是较慢，HDR native 前置条件通过，一次
全屏切换前的画面是正常播放画面；没有产生灰屏通过或失败结论，因为测试在全屏控件前置
状态处停止。

本轮修正了两个真实 UI dump 变体：搜索节点可能只有自身 bounds；成功搜索后播放器可能
只导出原生 XComponent 与 Slider，不导出结果文字。脚本现在仅在“可见视频表面 + Slider”
同时存在时继续。另发现 force-stop/start 会恢复上一次横屏全屏状态；UI dump 未暴露真实
全屏按钮，旧的透明右下角候选会误点，已移除。缺少可验证语义按钮时必须安全失败，不能
用固定坐标替代。

当前运行时结论：视频/HDR首帧路径仍可用，r7 代码已在实体机运行；连续播放中进入、退出
全屏的灰屏问题仍未完成实体机验收。下一步应先让控制层暴露稳定、可解析的全屏动作语义，
再继续脚本化全屏循环。

## 2026-09-09 architect 终审后的第二轮修正

独立终审又发现五项不能用 r6 直接放行的缺口，已完成本地代码修正：

- OHOS HCPP input 的 Axis 入口现在携带 attachment epoch；dispose 会递增 epoch，使旧
  input/overlay/hover 回调失效；detach/detachFromView 清空 pending overlay 队列；Hover
  只在当前可见 attachment 上注入。
- active pointer 保存 Down 的不可变 `ownerSeq`，Move 不再覆盖生命周期取消的来源序号。
- OHOS native fullscreen method channel 现在等待窗口方向/系统栏/多窗口操作完成后才回调
  success；media-kit Dart OHOS wrapper 不再吞掉原生失败，队列可以观察失败并重试/恢复。
- 播放中全屏脚本现在在每次具体切换完成后重新检查可见视频区域是否变化；时间位置变化
  不再单独作为画面播放证据。
- 新增 dispose 后旧回调/同 viewId 重建和 detach pending overlay 的定向 embedding 测试。

本地 HCPP contract、Flutter 定向测试、Dart analyze、脚本语法和 diff-check 通过；但这些
修正尚未生成新的 HAP。尝试构建 r7 时，`dev:172.24.136.84:1040` 在源同步阶段连接超时，
因此 r7 尚无产物，r6 不能代表上述修正。实体机运行验收仍未开始。

## 2026-09-09 r9-r11 实体机方向契约与播放中回归

实体机和独立 architect review 确认：OHOS 的 `PlatformUtils.isMobile` 只包含 Android/iOS，
播放器新增的 mobile reconciliation 在 OHOS 不可达；OHOS 全屏实际走 media-kit native
fullscreen 分支。不能把横屏窗口当成逻辑全屏，也不能把退出前的实际方向动态当成产品契约。

本轮没有把 OHOS 加入全局 `isMobile`。退出 native fullscreen 现在将 `horizontalScreen`
作为 `allowLandscape` 传给 media-kit OHOS 适配；启动阶段通过现有 `harmonyChannel` 设置同一
方向策略，`false` 使用 portrait，`true` 使用 auto rotation。r10 曾因视频持续 buffering
停止；r11 已构建、签名、安装，SHA-256 为
`22f90375421751752f83c189dee99bee2354bc11c67b5d627c96ffd70491cb28`。

r11 实体机单周期通过：启动 portrait；进入 fullscreen landscape；退出 portrait；再次进入
landscape；每次播放中 post-transition 样本均检测到中央视频区域变化；HDR native decision
evidence 通过；控制条通过 `pl-player-fullscreen-toggle` 定位。该结果不是灰屏颜色结论。

r11 实体机长跑执行到第 7 周期前置采样时停止：中央视频帧发生变化，但 UI dump 连续返回
`unknown` 播放语义，脚本按 fail-closed 规则没有把“帧在动”当成播放状态证据。已增加
unknown 状态下重新唤醒控制条并重采样的脚本重试，尚未重跑 20 周期。仍未完成：20 周期
最终结果、process-live 生命周期、surface recreate、SDR/PQ/HLG 矩阵、竖屏视频触控，以及
same-frame 色彩/亮度对比。完成这些并经最终 architect review 后，才能判断历史播放中切换
全屏变灰是否真正解决。

## 2026-09-09 r11 长跑灰屏现场与结论修正

r11 20 周期长跑在第 16/17 周期由人工观察确认变灰后立即停止，未继续点击或刷新现场。
保留的关键截图包括 `09-cycle-16-enter-fullscreen-immediate.jpeg`、
`09-cycle-16-enter-fullscreen-stable.jpeg` 和 `09-cycle-16-enter-post-transition-after.jpeg`；
画面仍在播放但明显低对比度、灰雾化，证明“中央帧仍变化”不能作为颜色正常判据。现场目录为
`/tmp/piliplusx-ohos-r11-gray-incident-20260909`，长跑目录为
`/tmp/piliplusx-ohos-r11-physical-cycles20-final-20260909`。

独立 architect review 修正根因排序：第 17 周期 resize 后确实执行了 NativeWindow 色彩契约
setter，`attempted/result` 均成功；因此不能简单归因于应用层 HDR decision 未重跑。更值得优先
调查的是旋转/resize 后 VO/WSI、实际 buffer 与 RenderService 的色彩解释或生效时序失配。
对同一视频 surface 的保存快照显示，第 13、14、16 周期的节点色彩状态从对照的 7 变为 4；
第 16 周期还出现默认 surface `2520x1260` 与实际队列 buffer `2274x1137` 的尺寸分叉。

下一步禁止直接增加重复 HDR 初始化或固定延迟。应先把 Hilog 采集覆盖整个长跑，并在 native
单调时间线上关联 surface/VO、swapchain generation、实际 buffer extent/format/colorspace、
首个 present、setter readback 和 RenderService 节点状态；脚本新增 `COLOR_CONTRACT_MISMATCH`
门禁，在同一 PQ 输出节点色彩状态由基线 7 变 4 时立即停测并保留现场。visual-color 仍需同源
同 PTS 参考或人工屏幕证据，不能由帧变化单独推出颜色正常。
## 2026-09-09 灰屏诊断门禁已落地

已将 RenderService 现场证据接入实体机验证脚本：
`tool/ohos/inspect_render_service.py` 按视频 surface 名称解析 `colorSpace`、队列默认尺寸、
实际 buffer 尺寸和 `metadataType`，首次有效采样写入本次运行的
`render-service-color-baseline.json`。后续同一 surface 的颜色状态变化会记录
`COLOR_CONTRACT_MISMATCH` 并立即停止，保留对应截图、布局、RenderService 快照和事件时间线。

脚本的 Hilog 默认采集窗口也已从固定 60 秒改为：长跑 1800 秒、单次验证 180 秒；仍可用
`VERIFY_LOG_SECONDS` 显式覆盖。这样不会再把长跑后半段当成“没有日志”。历史 r11 快照离线验证：
第 12 周期解析为 `colorSpace=7`，第 16 周期解析为 `colorSpace=4`，并同时发现实际 buffer
`2274x1137` 与 surface 默认 `2520x1260` 的尺寸分叉。

这只是诊断和 fail-closed 门禁，不是修复灰屏；在取得完整 native/VO/WSI/RenderService 时序
证据前，不增加重复 HDR 初始化或固定延迟 workaround。

## 2026-09-09 固定 producer extent 诊断失败

为验证“旋转/resize 导致 producer buffer 尺寸变化，从而触发灰屏”的假设，构建并安装了仅
用于诊断的 fixed-producer HAP：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-fixed-producer-20260909-signed.hap`，SHA-256
为 `e1a3fd8e4eb4e231716bf02ec4ec4bc2404824f93753fdbc71270dd8653e0de6`。该版本只把提交给
mpv 的 `ohos-surface-size` 固定为 `2520x1260`，Flutter/XComponent 的几何变化、HDR
属性调用、VO、解码器和生命周期均未改变；运行日志确认 `producerExtent=2520x1260`。

实体机播放中执行全屏/竖屏切换后仍出现持续灰屏，且切换方向不能恢复。保留现场目录为
`/tmp/piliplusx-ohos-fixed-producer-gray-incident-20260909`。RenderService 快照显示同一
视频 surface `25683904430766` 的默认尺寸和实际 queue buffer 都是 `2520x1260`，但节点
`colorSpace/uifirstColorGamut/NodeColorSpace` 稳定为 `4/4/4`；因此 producer extent 固定
并不能阻止故障，尺寸变化不是充分根因。

现场的 `no dirty buffer` 日志属于 Flutter 主 surface `25683904430762`，不是视频 queue，
不能据此解释视频灰屏。当前优先级改为消费者色彩解释链：需要把 VO/WSI 的 target mapping、
color hint、实际 present、RenderService 节点状态和同一 surface generation 关联起来；在
这条证据完成前，不提交固定尺寸生产修复，也不增加重复 HDR 初始化或固定延迟 workaround。

## 2026-09-10 mapping/hint 诊断实机结果

为补齐 native provenance，重新构建了固定 producer extent 且包含完整 mapping/hint marker 的
诊断 HAP：`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-fixed-producer-mapping3-20260909-signed.hap`。
manifest 中 `libmpv_sha256=a4fee672e49d82912d22644c80a383807c241fdaec96003d9dfebdaba924fc75`，
三个 marker 均存在。构建过程中还修正了 media-kit CMake 的 SHA256 provenance；旧 zip 会被
完整性门禁拒绝，不会静默当作新诊断包。

实机脚本完成 3 个持续播放周期，现场目录为
`/tmp/piliplusx-ohos-fixed-producer-mapping3-3cycles-20260910`。日志显示 mpv 侧持续得到
`swap_trc=2`、`target_trc=12`、`hint trc=12`、`strict=1`，说明 HDR/PQ target mapping
已经进入 VO。与此同时 NativeWindow color contract 持续为
`attempted/result=0`、`readback space=0/25`，RenderService 视频 surface
`25683904430773` 的所有采样均为 `colorSpace=4/uifirstColorGamut=4/NodeColorSpace=4`；
进入/退出全屏的固定 producer 采样仍保持进入时 `2520x1260`，但颜色节点没有进入 HDR 状态。

截图从首个全屏稳定样本起即呈持续低对比度灰雾，切换方向没有恢复。当前最强证据链是：
mpv 的 HDR target mapping 正确，但动态 NativeWindow 色彩输出没有真正写入或没有被
RenderService 消费；不能再把主因归为 producer 尺寸或 Flutter 全屏几何。下一步应检查
OHOS VO/WSI 的动态 color-space/metadata setter 调用条件、返回值和 consumer 生效边界，
而不是继续增加 resize 重试或固定延迟。

## 2026-09-10 consumer readback recovery 实机结果

针对上述证据增加了独立 native patch
`tool/ohos/ohos-consumer-color-recovery.patch`：每次 VO 写色彩后读取 NativeWindow
color space；若 desired PQ/HLG 与 readback 不一致，则清空 color-space、metadata、static
metadata 和 white-point 缓存，让下一帧重新写入完整 contract。该 patch 不改变 producer
尺寸、不重启 VO、不引入固定延迟。

Recovery HAP 的 `libmpv_sha256` 为
`4edc0e8a4e89b3c58f36a620786f02a99c5e9e3ee3e3485b789e4cc73e9885de`。实体机 3 周期现场为
`/tmp/piliplusx-ohos-consumer-color-recovery-3cycles-20260910`：共 4 次观察到
`desired=31 actual=25`，随后日志出现 `attempted{space=1 metadata=1 static=1
hdr_white_point=1 sdr_white_point=1}`，readback 恢复为 `space=31`。所有 RenderService
采样均为 `colorSpace=7`，进入/退出全屏的截图恢复正常对比度和颜色，未再出现持续灰屏。

这验证了“consumer 色彩状态被重置而 VO 缓存仍认为有效”是当前灰屏的直接故障机制。仍需
扩大到至少 30 周期、多个源和 SDR/PQ/HLG 矩阵，并完成 architect 终审后，才能把该 patch
从诊断恢复方案提升为正式修复结论。

## 2026-09-10 recovery patch 构建链收敛

architect 复核指出，恢复逻辑不能只存在于远端手工修改的 `ohos_common.c`。现已将
`tool/ohos/ohos-consumer-color-recovery.patch` 同步纳入
`/Users/wuweiwei1/src/ohos-native-build/libmpv-ohos-build/patches/mpv/`，并把五个缓存字段
的清理收敛为 `invalidate_output_color()`，供 consumer readback 失配和公开的
`vo_ohos_invalidate_color()` 共用。

同时修正 native `patch.sh` 的外层 process-substitution 位置。此前脚本只运行了 HDR contract
检查，未实际遍历依赖 patch 目录；修正后才会对每个依赖执行幂等的 `git apply --check/apply`
流程。当前本机缺少 native build 所需的完整 ffmpeg checkout，因此这里只完成 patch-chain
静态可应用性检查，不把本机 patch 脚本运行结果当作 native 编译通过。

`verify_hdr_real_device.sh` 现在在显式设置 `VERIFY_REQUIRE_NATIVE_DIAGNOSTICS=1` 时要求
四个 marker 全部存在，并可用 `VERIFY_EXPECTED_LIBMPV_SHA256` 校验 HAP 内实际 `libmpv.so`；
在 `VERIFY_REQUIRE_COLOR_CONTRACT=1` 时，稳定全屏首个 RenderService 基线默认必须为
`colorSpace=7`，可用 `VERIFY_EXPECTED_RENDER_COLOR_SPACE` 覆盖。这些门禁只服务于当前 PQ
诊断，不替代后续 SDR/HLG 矩阵。

## 2026-09-10 chain HAP 与 30 周期实机结果

已从远端 `mpv` HEAD 临时 worktree 按 `ohos-color-contract-diagnostics.patch`、
`ohos-consumer-color-recovery.patch`、`ohos-output-mapping-diagnostics.patch` 顺序应用，
确认 patch chain 可从干净基线生成正确源码；native `libmpv.so` 编译通过，SHA-256 为
`7a1e0b453e2c03677775084df358f27e6dbf7e6b35c615740c925dda997c4055`。正式签名 HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-consumer-recovery-chain-20260910-signed.hap`，
HAP 内 SHA 与 native 产物一致，四个 native marker 和 HCPP marker 均存在。

实体机 30 周期长跑目录为 `/tmp/piliplusx-ohos-consumer-recovery-cycles30b-20260910`。
第 1 至 15 周期完整通过：播放中退出/进入全屏、方向和帧变化均正常，所有稳定采样均为
`colorSpace=7`，动态队列尺寸 `1260x630` 与 `2520x1260` 均正常。第 16 周期退出阶段同样
保持 `colorSpace=7`、readback `31`；进入阶段逻辑控制条已切换为“退出全屏”，但系统窗口
仍为 portrait，脚本按方向门禁停止。Hilog 显示这是 fullscreen/orientation 事务失败，不是
颜色 contract 失配或灰屏：该现场没有 `COLOR_CONTRACT_MISMATCH`，NativeWindow readback
持续为 PQ `31`。

因此本轮证明了 recovery HAP 在 15 个连续播放周期内消除了历史灰屏直接机制，但完整 30
周期接受仍未关闭；剩余阻塞是独立的 OHOS 全屏方向事务稳定性，以及 SDR/PQ/HLG、source/
metadata 切换、暂停/后台返回和 surface recreate 矩阵。

## 2026-09-10 全屏方向确认门禁与测试源

为避免“native 方向请求回调成功、但窗口仍是 portrait”造成逻辑全屏与实际 Surface 状态
分叉，media-kit OHOS 全屏事务现监听 `windowSizeChange`，只在窗口实际达到 landscape/
portrait 后返回成功；5 秒内未达到目标则失败并记录最终尺寸。对应 HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-orientation-gate-20260910-final-signed.hap`，SHA-256
为 `fd40c23e0980d4a860e2dbb0a174fceae9279fab0d0ff05def60ad7f8d3f30f7`。HAP 已通过签名、
完整性和 native marker 检查，但因本轮 HDC 设备 Offline，尚无实机运行证据。长跑脚本已加入
可逆的亮屏保护：开始时 wakeup/延长自动熄屏，退出时恢复原设置。

后续格式矩阵使用以下候选源：真彩 HDR `BV15z4y1Z734`、HDR Vivid `BV121421y7PM`、HLG
测试信号 `BV1ZB4y1F7jf`、PQ/HLG/SDR 对照 `BV1tM4y1L7EF`。可用
`tool/ohos/verify_hdr_source_matrix_real_device.sh --hap <HAP>` 串行执行，每个源必须以播放时实际
Hilog transfer、metadata、NativeWindow readback 和 RenderService 状态确认格式，搜索结果
仅证明候选用途，不能替代设备端格式证据。

模拟器 SDR 方向短测目录为 `/tmp/piliplusx-ohos-orientation-sdr-emulator-cycle1-20260910`。
最终 HAP 安装/启动和搜索通过，但视频页发生 `EGL_BAD_SURFACE`，无障碍布局缺少进度条，
脚本在控制条操作前 fail-closed。该结果只记录模拟器 native-surface 呈现边界，不替代实体机
全屏方向、HDR 或持续灰屏验收。

## 2026-09-10 reapply-color-after-resize 杜比视界长跑结果

针对全屏 resize 使 NativeWindow consumer 色彩状态失效、而 VO 缓存未立即重写的问题，新增
`tool/ohos/ohos-reapply-color-after-resize.patch`，在 OpenGL/Vulkan resize 完成后立即由
OHOS VO 重新应用当前色彩契约。远端 native `libmpv.so` SHA-256 为
`f68b7b2dc7613268a9db505a138cd165ebbb2128810b40d407b0eefe2f6bb2ae`；签名 HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-reapply-color-after-resize-20260910-r4-signed.hap`。

实体机杜比视界源 `BV1vY4y1N7TY` 在持续播放前提下完成 30/30 次退出/进入全屏往返，91 次
播放进度观察，120 次 RenderService 色彩契约采样均为 `baseline_color_space=7`、
`color_space=7`，没有 `COLOR_CONTRACT_TRANSIENT` 或 `COLOR_CONTRACT_MISMATCH`。Hilog
确认 `source=dolbyVision`、`output=nativeHdr`、`surface=native-hdr`、
`nativeOutputActive=true`，并应用 PQ dataspace。

这关闭了本轮自动化 DV 播放/全屏/色彩契约回归门禁，但脚本仍输出
`color verdict: INCONCLUSIVE`：截图来自不同播放时刻，不能充当同源同帧显示颜色参考。
在独立视觉颜色验收完成前，不能把杜比视界称为“全部通过”，也不得开始其它格式测试。

## 2026-09-10 杜比视界视觉回归门禁关闭

在同一 r4 HAP、同一实体机和同一 DV 源 `BV1vY4y1N7TY` 上，追加 3 次持续播放中的全屏
短程对照，目录为 `/tmp/piliplusx-ohos-dolbyvision-visual-ab-20260910`。3/3 周期、10 次
播放进度观察和 12 次 RenderService 色彩契约采样均通过；短测 Hilog 没有 consumer color
mismatch。全屏立即帧、稳定帧及回切后的截图均未出现持续灰雾、明显对比度塌陷或颜色跳变。

结合此前 30/30 长跑结果，杜比视界“播放中切换全屏变灰”回归门禁现已关闭，可以进入其它
格式矩阵。这里的结论限于当前设备、HAP、DV 源及 native DV-to-HDR 输出链路；它不是显示
仪器意义上的绝对色准认证，也不扩展到所有 Dolby Vision profile 或动态元数据直通。

## 2026-09-10 方向门禁包 DV 重验与格式矩阵最新状态

最新方向门禁 HAP 在实体机 `2PM0223A18006914` 上对 `BV1vY4y1N7TY` 完成 30/30 次持续播放
全屏往返、91 次进度观察；稳定 RenderService 色彩采样全部为 `colorSpace=7`，无颜色契约瞬态
或失配，实际窗口方向每轮通过。证据目录：`/tmp/piliplusx-ohos-orientation-dv-cycles30-20260910`。

其它格式随后启动：`BV15z4y1Z734` 完成 30/30 轮且颜色契约异常为 0，但实际 Hilog 格式为
`hdr10/pq`，不计为 HDR Vivid。`BV121421y7PM` 的一次重跑完成 21/30 轮后因
`unknown + frame unchanged` fail-closed；另一轮暴露 USB 系统对话框处理和恢复后的全屏
语义不同步，不能计为通过。当前仍需重新验证该源、HLG、真正 HDR Vivid、SDR/PQ/HLG 往返、
surface recreate、生命周期和竖屏主体触控。

补测样片 `BV19VBUBHEBK` 与 `BV1HBxxePEHo` 后，实际 Hilog 均为
`source=hdr10`、`transfer=pq`，所以尚未获得真正 HDR Vivid/HLG 样片证据。两次单轮测试均
在播放中切换全屏后遇到 `buffering -> unknown`，脚本 fail-closed；控制条语义重试本身已
成功，不应把这两次结果记为格式或颜色通过。

## 2026-09-10 process-live 生命周期门禁通过

专用 debug HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-20260910-signed.hap`
在实体机完成正式门禁复跑，证据目录 `/tmp/piliplusx-ohos-process-live-20260910-r17`，脚本
返回码为 0。持续播放、全屏、活动 drag 下，稳定 PID 和同一 view/epoch 的 owner Down、
owner Cancel、NAPI Cancel、attachment dispose、page-pop、Dart PointerCancel 均已关联通过。
该生命周期门禁已关闭；重建后持续播放、格式切换和竖屏触控仍独立未关闭。

实体机 surface recreate 目录 `/tmp/piliplusx-ohos-surface-recreate-20260910-r1` 已产生：
baseline 全屏往返和视频帧进展通过，活动 drag 期间 force-stop/start 后捕获旧 surface
`Cannot find surface`、窗口销毁及新 native window `SetDisplayWindow`；重启后布局和截图也已
保存。该结果只关闭冷重启/surface 边界采集，不关闭 graceful dispose、重建后持续播放、HDR
颜色稳定性或灰屏门禁。

## 2026-09-10 process-live 实体机证据

专用 debug HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-20260910-signed.hap`
已签名并通过 `verify-app`，实体机目录 `/tmp/piliplusx-ohos-process-live-20260910-r8` 捕获到
owner Down、owner Cancel、NAPI Cancel、attachment dispose、page-pop、Dart PointerCancel，
且 PID 稳定。首轮脚本返回失败是门禁解析器假设错误，不是运行链路缺失；已修正 live Hilog
延迟、`activeOwner`/view/epoch 关联、实际取消事件名和 Cancel-before-dispose 顺序。修正后
尚需在稳定全屏播放场景下再取得一次脚本返回码 0；后续 r9 因方向未切换而未形成有效复跑。

## 2026-09-10 格式门禁脚本收紧与当前短测

源矩阵脚本新增实际格式门禁：HDR Vivid 和 HLG 源必须分别在自身 `hilog.txt` 中出现
`source=hdrVivid` 与 `transfer=hlg`，不能用标题、BVID 或 `colorSpace=7` 推断格式；字段命名
变化只能通过显式正则覆盖。相关规则和日志延迟重抓参数已写入实体机操作说明。

实体机短矩阵目录 `/tmp/piliplusx-ohos-hdr-matrix-20260910-format-gate` 的首个真彩候选
`BV15z4y1Z734` 在进入横屏后因 `playing -> unknown` 且帧不变而 fail-closed，未计为通过；
Hilog 实际识别为 `source=hdr10, transfer=pq`，随后进入 `output=nativeHdr`。本轮只证明脚本
按预期拒绝短素材/网络停滞，不构成该源完整矩阵通过。

## 待办：真实 HLG / HDR Vivid 样片

按当前验收决定，暂时跳过 HLG 与 HDR Vivid 的实体机长跑，不把缺少可靠输入误写成格式通过。
`BV1ZB4y1F7jf`、`BV11b4y1d7Cr` 虽标注 HLG，实体 Hilog 均为 `source=hdr10, transfer=pq`；
`BV121421y7PM`、`BV19VBUBHEBK` 虽标注 HDR Vivid，前两者实际为 `source=hdr10, transfer=pq`，
`BV1SmtKzQEpi` 的当前短测未满足 `nativeHdr` 前置条件。

恢复条件：取得可下载或可由产品页面稳定播放的真实样片后，先以实际 transfer/metadata 和
Hilog 确认格式，再分别执行至少 30 轮持续播放全屏往返、颜色契约、source/metadata 切换和
视觉对照。此待办不影响已关闭的 DV 门禁，也不允许用 PQ 样片替代 HLG/Vivid。

## 2026-09-10 实体机离线与本地回归检查

本轮开始时 HDC 显示 `2PM0223A18006914 USB Offline`；执行 `hdc tconn 2PM0223A18006914`
返回 `CreateConnect failed`，随后设备命令返回 `E001005 Device not found or connected`。
因此本轮未将 PQ/SDR 实体机结果记为通过，也未切换到模拟器冒充实体机。

设备离线期间，播放器定向 Flutter 测试 17/17 通过；本轮修改文件的精确 `flutter analyze`
无问题。全目录 analyze 仅剩既有的 `lib/plugin/pl_player/widgets/mpv_convert_webp.dart:65`
`cascade_invocations` 信息，不属于本轮整改文件。

## 2026-09-10 macOS 构建回归边界

实体机离线期间使用 `caffeinate -dimsu flutter build macos --debug --no-pub` 成功生成
`build/macos/Build/Products/Debug/PiliPlusX.app`。构建输出提示 `flutter_inappwebview_macos`
尚不支持 Swift Package Manager；这是插件兼容性警告，本次构建未失败。该结果只证明 macOS
debug 编译通过，不关闭 macOS 播放、HDR/DV 可见输出或产品交互回归。

随后以 `open -n build/macos/Build/Products/Debug/PiliPlusX.app` 启动该产物，5 秒后进程
`PiliPlusX` 仍在运行，macOS `System Events` 能看到对应应用进程。该结果只关闭 macOS
debug 启动烟测，不替代产品内视频播放、HDR/DV 输出或交互验收。

## 2026-09-10 PQ/SDR 源方向门禁失败

实体机恢复 Online 后，使用方向门禁 HAP 对 `BV1tM4y1L7EF` 执行 3 轮短测；首轮和重跑均在
首次全屏点击后停止：按钮语义为“全屏”且点击成功，但 `08-fullscreen-stable` 实际仍为
portrait，未进入周期或颜色通过判定。两轮 Hilog 均识别源为 `source=hdr10, transfer=pq`，
并最终进入 `output=nativeHdr`；证据目录分别为
`/tmp/piliplusx-ohos-pq-hlg-sdr-BV1tM4y1L7EF-20260910-cycles3` 和
`/tmp/piliplusx-ohos-pq-hlg-sdr-BV1tM4y1L7EF-20260910-cycle1-r2`。

同一设备、同一 HAP 随后对 DV 源 `BV1vY4y1N7TY` 执行 1 轮，进入/退出/再次进入横屏及每次
播放进展均通过，脚本返回码为 0；证据目录为
`/tmp/piliplusx-ohos-dv-control-BV1vY4y1N7TY-20260910-cycle1-r2`。当前应把 PQ 源失败归为
源级/会话级方向事务缺口，不能归因于 DV 已关闭的颜色回归，也不能计为 PQ/SDR 通过。

随后发现 OHOS 语义树对实际可见 Flutter 控制条也可能报告 `opacity=0`，因此不能把 opacity
作为唯一门禁。现已改为只接受点击前最新的 `visible/enabled/clickable` 节点，并保留重新唤醒、
重新 dump 的时序；一次新的 DV 回归因应用未回到预期视频/搜索页而提前停止，未产生新的播放
结论；设备 HDC 当时仍为 USB Connected。

## 2026-09-10 PQ 短片自动退出复核

诊断 HAP 已以更高版本号构建、签名并安装。DV `BV1vY4y1N7TY` 使用脚本完成首次进入、退出、再次进入横屏，且播放帧持续变化；证据目录为 `/tmp/piliplusx-ohos-dv-control-BV1vY4y1N7TY-20260910-cycle1-r5`。

PQ `BV1tM4y1L7EF` 的 trace 证明原生进入横屏和实际 `windowSizeChange` 均成功，随后短片接近结束时收到应用 `exitFullScreen`，回到竖屏；缩短稳定等待后首次方向检查通过，但播放进展检查读到 `paused`。architect 建议优先使用长 PQ/SDR 源验证，并区分既有完成自动退出策略，暂不修改 OHOS Utils 或全屏队列。

## 2026-09-10 长 PQ 源播放前置失败

按 architect 建议改用约 305 秒的 `BV15z4y1Z734` 进行 PQ/HDR10 连续播放验证。两次脚本运行均成功完成进入横屏，`08-fullscreen-stable` 的窗口为 `2720x1260`；但播放进展门禁在位置 `0%` 长时间处于 `buffering`，最终采样为 `before=buffering after=unknown frame=changed`，证据目录为 `/tmp/piliplusx-ohos-pq-long-BV15z4y1Z734-20260910-cycle1-r1` 和 `/tmp/piliplusx-ohos-pq-long-BV15z4y1Z734-20260910-cycle1-r2`。

因此本轮只证明长源的全屏方向事务通过，未证明 PQ/SDR 播放过程中的亮度、颜色或切换稳定性；当前阻塞点是实体机网络/源播放前置，不修改全屏队列或 OHOS Utils。HLG 与 HDR Vivid 因暂未找到可用样片，按要求跳过并保留待办。

随后对同一长源扩大到 3 轮时，首轮全屏后无障碍树同时缺少播放语义和有效 Slider 位置，中央视频裁剪区虽有变化，但默认门禁按 `unknown` fail-closed；关闭自动 seek 重置后重跑也未改变该边界。新增的 `VERIFY_ALLOW_VISUAL_PLAYBACK=1` 仅允许将这种结果标记为“仅视觉帧进展”的诊断证据，不等价于播放状态通过，尚未用它关闭 PQ/SDR 验收。另一次重跑在进入视频页截图前 HDC 变为 Offline，脚本安全停止。

在实体机短暂恢复在线后，长 PQ 源单轮重跑成功建立 `playing`，完成进入横屏、稳定窗口
`2720x1260` 和中央视频帧变化，并取得 `output=nativeHdr`；证据目录为
`/tmp/piliplusx-ohos-pq-long-BV15z4y1Z734-20260910-cycle1-r3`。这只证明单轮方向和帧进展
前置通过，不能替代 PQ 多轮或视觉颜色验收。

随后 3 轮和关闭 seek 重置的重跑均未形成完整通过：一个在 `unknown + frame changed` 且无有效
Slider 位置时被默认门禁拒绝，另一个在进入视频页截图前因 HDC Offline 停止。诊断开关仍只用于
明确标记“仅视觉帧进展”，不改变默认 fail-closed 规则。

## 2026-09-10 PQ 3 轮通过与控制条时序修复

实体机恢复在线后，脚本先在 `r6` 复现了“第二次进入全屏按钮语义存在但窗口仍为 portrait”；
最新 Hilog 没有第二次 `FullscreenTrace trigger`，而 layout 节点确实是最新的
`visible/enabled/clickable` 全屏按钮。复查发现循环路径在点击前先做 `capture_display`，会消耗
控制条短暂可见窗口。移除循环点击前截图、保留点击后的 immediate/stable 截图后，`r7` 完成
长 PQ `BV15z4y1Z734` 的 1 轮完整进入/退出/再次进入全屏，且每个播放进展门禁均观察到视频帧变化。

随后 `cycles=3` 的 `r2` 完成 3/3 轮，10 次播放进展观察通过，HDR decision 为
`source=hdr10, transfer=pq, output=nativeHdr`；证据目录为
`/tmp/piliplusx-ohos-pq-long-BV15z4y1Z734-20260910-cycles3-r2`。颜色仍为
`INCONCLUSIVE`，因为尚未采集同源同帧实屏对照。

尝试 30 轮的 `r1` 在第 4 轮停止：片源已从 91% 播放到 97%，进入全屏后接近片尾，控制条不再出现；
这不是 30 轮通过，也不是新的点击链故障。证据目录为
`/tmp/piliplusx-ohos-pq-long-BV15z4y1Z734-20260910-cycles30-r1`。

同一修正版脚本随后对 SDR 源 `BV1GJ411x7h7` 执行 3 轮，3/3 轮进入/退出/再次进入全屏，10 次
播放帧进展观察通过；Hilog 实际确认 `source=sdr, transfer=sdr, output=sdr, surface=texture`，
脚本输出 `Texture/SDR evidence: PASS`。证据目录为
`/tmp/piliplusx-ohos-sdr-BV1GJ411x7h7-20260910-cycles3-r1`。该轮关闭 SDR 方向和帧进展门禁，
颜色视觉对照仍为 `INCONCLUSIVE`。

随后使用同一修正版脚本执行 surface recreate 控制实验：连续播放基线完成一次 DV 全屏往返并有
视频帧进展，活动拖动期间执行 force-stop/start，捕获旧 surface 消失、新 Flutter native window
重新 `SetDisplayWindow` 以及重启后截图；证据目录为
`/tmp/piliplusx-ohos-surface-recreate-20260910-r3`。该实验仍是冷重启/surface 边界证据，
不关闭旧进程 graceful dispose、重建后继续播放或竖屏视频主体触控门禁。

## 2026-09-10 竖屏全屏方向约束

用户要求竖屏视频进入全屏时保持竖屏，不需要旋转方向。验证脚本新增显式 `--vertical`：
它要求窗口态和所有全屏稳定态均为 `portrait`，并保留播放中的进出全屏链路；不再把所有
进入全屏的场景写死为 `landscape`。

产品侧 `PlPlayerController` 已将竖屏源的全屏方向归一为 portrait，并忽略进入请求中携带
的横屏方向，同时增加 requested/effective 方向日志。Flutter 定向测试、Dart analyze 和脚本
语法检查通过。

新逻辑已在 `2026091201` 构建 HAP 中编译、签名和 verify-app 校验通过：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-vertical-fullscreen-20260910-signed.hap`，
SHA-256 为 `28b075e2c72a58ee263e21e0053b2166341ce9182f4bd768228da2e492e35`。
但实体机安装阶段 `hdc install -r -d` 连续 180 秒无输出并超时；设备仍可执行
`hdc shell echo connected`，因此当前不能声称新逻辑已完成实体机验收。旧 HAP 的一次竖屏
基线运行因控制条未在脚本窗口内出现而 fail-closed，也不计入方向通过。

随后使用新 HAP `2026091202` 复查发现，原生 OHOS `media-kit_video` 的
`Utils.enterFullScreen()` 仍无条件请求 `USER_ROTATION_LANDSCAPE`，此前播放器层的
portrait 归一化因此没有真正到达窗口层。已补齐 `PiliPlusX → MethodChannel → media-kit
ArkTS` 的 `landscape` 参数：竖屏源进入/退出全屏均保持 portrait，且保留
`requested/effective` 方向日志。该版本重新构建、签名、设备端分块传输 SHA-256 校验和
`bm install -p` 均成功；首次新包实测前因设备构建后自动锁屏而被脚本安全停止，待解锁后
重跑，不计入方向通过。

新 HAP `2026091203` 进一步将竖屏全屏改为播放器内应用全屏：仅隐藏/恢复系统栏，不调用
OHOS 原生窗口旋转或 landscape multi-window；横屏源仍使用原生窗口全屏。构建和静态检查
通过，但该版本分块传输到第 4 块时实体机 HDC 变为 Offline，尚未安装或运行验收。

最终方向版本 `2026091204` 将竖屏路径收敛为纯播放器布局事务，不调用系统栏或原生窗口 API，
避免平台副作用阻止逻辑状态提交。实体机安装成功，版本运行验收目录为
`/tmp/piliplusx-ohos-vertical-BV1Wp4y1P7KU-20260910-cycle1-r7`：初次进入、退出和再次
进入全屏均保持 `portrait`；控制条语义依次为 `全屏 → 退出全屏 → 全屏 → 退出全屏`；
初次和循环后的播放帧进展均观察到。片源到达 100% 时脚本按显式片尾恢复策略 seek 到 0、
重新播放后再次观察到帧变化，不能把暂停采样本身计为播放通过。

尝试扩大到 `cycles=3` 时，实体机在脚本启动前再次变为 HDC `USB Offline`，没有执行任何
UI 操作，不计入 3 轮结果。颜色结论仍与方向验收分离，HLG/HDR Vivid 仍按待办跳过。

实体机恢复后使用同一 `2026091204` HAP 重跑 `cycles=3`，证据目录为
`/tmp/piliplusx-ohos-vertical-BV1Wp4y1P7KU-20260910-cycles3-r2`。3/3 轮的进入、退出、
再次进入全屏均保持 portrait，控制条语义状态正确切换，9 次播放进展观察通过；第 2 轮
片源到达片尾时执行了显式 seek/restart 恢复并重新取得帧进展。该结果关闭竖屏全屏方向和
循环播放门禁，但不扩大为颜色视觉、HLG/HDR Vivid 或其它格式验收。

## 2026-09-10 surface recreate 冷启动边界复核

实体机重新 Online 后，使用 `verify_surface_recreate_real_device.sh` 完成连续播放基线和活动
拖动期间的 force-stop/start 实验，证据目录为
`/tmp/piliplusx-ohos-surface-recreate-20260910-r4`。基线全屏往返和播放帧进展通过；实验期间
保留了 4 秒脚本拖动，随后强制停止并重启应用。Hilog 记录了旧 surface 不可查找/窗口销毁，
以及新进程 `56367` 重新执行 `SetDisplayWindow`、`ReleaseOffscreenWindow`；重启后的布局、截图
和 PID 也已保存。

该结果只确认冷启动进程与 Flutter native window 的 surface 边界，不能替代已独立关闭的
process-live graceful Cancel/dispose 门禁，也不能证明旧进程销毁后继续播放、颜色稳定性或灰屏
回归。后续若需覆盖“重建后继续播放”，必须增加不杀进程的 surface detach/recreate 入口和同源
连续帧证据。
## 2026-09-10 输出重建所有权修正与同进程重入边界

本轮修复 `PlPlayerController._rebuildVideoOutput` 的生命周期竞态：新增独立输出事务代数，
`dispose()` 会使挂起的异步重建失效，过期创建结果在提交前释放。远端 OHOS HAP 构建检查器也
同步调整为要求两个真实 `disposeForRebuild` barrier（当前输出释放与过期输出清理），不允许
回退到同步 dispose。版本 `2026091301` 已编译、签名、verify-app 校验并分块安装到实体机；
本地定向测试 17/17，controller 精确 analyze 无问题。

实体机验证：首次连续播放/横屏全屏往返基线通过，目录为
`/tmp/piliplusx-ohos-owner-r1-baseline-r2`。随后脚本化 page-exit 在活动拖动期间保持 PID
`61567`，并捕获 owner Cancel、NAPI Cancel、attachment dispose；第二轮 page-exit 保持 PID
`64659`。使用新增的 `VERIFY_REUSE_CURRENT_APP=1` 不执行 force-stop/aa start，脚本已能从
现有搜索结果页语义点击 `first-video`，并对“视频 0/没有数据/点击重试”执行语义重试。

当前同进程重入尚未通过：重入验证目录为
`/tmp/piliplusx-ohos-owner-r1-same-process-reentry-r5`，搜索结果仍为无数据，未形成
`nativeHdr`、新 attachment/nativeSurfaceReady 和重入后连续播放证据。因此不能把旧进程
Cancel/dispose 门禁或冷重启 surface 证据扩大为“重建后继续播放通过”；后续需要网络可用时在
同一 PID 下完成搜索结果到新视频页的真实重入。

实体机重连后的复测继续保持同一结论：`r7` 杜比视界冷启动基线目录
`/tmp/piliplusx-ohos-owner-r7-dv-baseline` 完成 1 个播放中全屏往返，HDR decision 和帧进展
通过；page-exit 目录 `/tmp/piliplusx-ohos-owner-r7-page-exit` 的 PID 前后均为 `18536`。
但同进程回入 `/tmp/piliplusx-ohos-owner-r7-same-process-reentry` 在点击结果后连续语义重试
仍停留在“视频 0/没有数据”，没有进入目标视频页，因此本轮不计入 HDR、surface 或全屏结论。

同时修正了验证脚本的门禁：点击搜索结果后必须重新确认目标 BVID、Slider 和视频唤醒区域均存在；
“没有数据/点击重试”在打开详情阶段只允许有限次语义重试，未恢复就 fail-closed，不再把失败详情页
误判为播放器页继续执行全屏测试。初始搜索结果分支也改为传递真实 layout，避免不存在的
`03-results.json` 产生误导性错误。

## 2026-09-11 同进程重入全屏回调边界

同一实体机 PID `18536` 随后通过脚本化返回、重新搜索和语义点击恢复到目标视频页，目录为
`/tmp/piliplusx-ohos-owner-r8-direct-reopen`；该过程观察到 Slider、真实播放区域和帧进展，说明
“回入后详情页暂时无数据”不是唯一故障。使用 `VERIFY_REUSE_CURRENT_APP=1` 的同进程全屏复测目录
为 `/tmp/piliplusx-ohos-owner-r8-same-process-reentry-success2`：脚本确认按钮语义为“全屏”，
HCPP overlay Down/Up 均为 accepted，且同 PID 有 native HDR contract；但点击后立即和稳定采样均
保持 portrait，未出现 Dart `FullscreenTrace`，因此全屏业务回调未被证实触发，不能计为同进程重入
通过。再次复测 `r9` 仍复现相同 portrait 结果。

本轮还核对了部署产物：当前实体机 HAP 内 `libflutter.so` 只含旧的
`nativeDispatchTouchToEngine` 字符串，不含 dev 源码新增的 `HCPP_POINTER` native trace；因此
NAPI/engine 贯通诊断尚未进入实机产物。architect 建议下一步先完成安装产物与 native engine 的
一致性，再以单次 Down/Up 同时记录 ArkTS、NAPI、PointerDataPacketConverter 和 Dart 四个边界；
在此之前不应修改方向事务或加入点击延时 workaround。当前设备随后变为 `USB Offline`，待重连后继续。

随后将注入触点的 device namespace 收敛到 ArkTS embedding：`HCPP_INJECTED_DEVICE_BIAS = 1 << 40`，
C++ NAPI bridge 改为透明转发，避免旧 HAP native 和未来重建 native 重复加偏移；并补充
`input_pointer_owner_forwards_terminal_events_after_visible_false` 的设备身份断言。新 HAP
`2026091302` 已在 dev 构建、签名、verify-app 和包内 `modules.abc` marker/hash 检查通过，产物为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-owner-device-bias-20260911-r1-signed.hap`，HAP SHA-256
为 `e1897128f349f6c58146e0d353c676b692068be6b0b594912653538fd5b978c3`。该包尚未完成实体机
安装和运行验收；当前 HDC 仍为 `USB Offline`。

复核 `2026091302` 后发现 ArkTS 中的 `1 << 40` 会被 32 位位运算截断，上一版实际没有建立
高位 namespace，故该包不作为候选。已改为精确数值 `1099511627776`，并将单测阈值同步改为
同一数值；新 HAP `2026091303` 已重新构建、签名、verify-app 和 marker/hash 校验通过，产物为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-owner-device-bias-20260911-r2-signed.hap`，HAP SHA-256
为 `9eccbbeaf5a8a37af99897c34d4ed6a408c2cbd64a57382170e463000a7a57d0`。仍待实体机安装和运行
验收。

进一步复核发现当前 NAPI `device` 读取函数原先是 `napi_get_value_int32`，因此即使 ArkTS 使用
`2^40` 也会在 bridge 被截断。现将 namespace 改为 32 位安全值 `1048576`，并将 C++ bridge
读取改为 `TouchGetInt64`；当前旧 native HAP 可正确接收该值，未来 native 重建也保持同一协议。
此前 `2026091302/1303` 均不作为候选。新 HAP `2026091304` 已构建、签名、verify-app 和
marker/hash 校验通过，产物为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-owner-device-bias-20260911-r3-signed.hap`。
实体机恢复后必须优先安装此版本，不能安装 r1/r2。

## 2026-09-11 r4b 同进程全屏队列边界

实体机 `2PM0223A18006914` 已安装递增版本 `2026091305`，HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-fullscreen-trace-20260911-r4b-signed.hap`。
冷启动杜比视界基线 `/tmp/piliplusx-ohos-fullscreen-trace-r4b-cold` 通过首次进入、退出、
再次进入全屏的方向门禁，并观察到播放帧进展；颜色结论仍按规则为 inconclusive，不能由日志替代
同帧可视对比。

同一 PID `34955` 的 page-exit 保持进程存活，随后脚本化返回、清空搜索框、重新搜索并进入同一
视频页。复测 `/tmp/piliplusx-ohos-fullscreen-trace-r4b-reentry2` 记录了 HCPP Down/Up、
`device=1048576`、Dart `FullscreenTrace trigger/execute`，但只出现
`[FullscreenPlatformTrace] enqueue owner=2`，没有对应的 `start`；方向保持 portrait。因此问题
边界已从触控/NAPI 前移到应用侧进程级 `_platformTail`：存在与页面重入相关的未完成平台 Future，
但触发条件在该轮尚未完全证实，不能定性为 MethodChannel handler 已断开。

下一步必须定位该未完成 Future 的具体操作（SystemChrome、原生全屏或窗口获取），再修复其完成/失败
契约；不允许直接重置队列、增加点击延时或并发放行新请求。

随后使用 r5（`2026091306`）在同一实体机、同一进程直接脚本化清空搜索框、重搜并回入目标视频，
目录 `/tmp/piliplusx-ohos-fullscreen-queue-trace-r5-reentry` 完成一次全屏往返；队列日志中
`enter/exit-native-fullscreen` 均有 `start/finish`，原生方向日志完整。紧接着同一进程执行
3 个连续全屏退出/进入周期，目录 `/tmp/piliplusx-ohos-fullscreen-queue-trace-r5-cycles3` 的
方向和播放帧进展全部通过。r4b 的队列阻塞因此暂记为条件相关的队列等待，仍需用“失败中间流程”
可重复触发后再决定修复点，不能把一次 r5 通过扩大为所有页面生命周期已通过。

进一步的 r6 生命周期日志 `/tmp/piliplusx-ohos-fullscreen-lifecycle-trace-r6-intermediate/hilog.txt`
定位到具体阻塞者：`dispose owner=1` 后，`preferred-orientation` 有 `start/finish`，而
`show-system-bar` 只有 `enqueue/start` 没有 `finish`。OHOS 原生全屏由 media-kit 窗口负责系统栏，
因此应用 dispose 不应再调用通用 `SystemChrome.setEnabledSystemUIMode`。r7 已在
`_restoreFullScreenPlatformState` 对 OHOS 跳过该系统栏恢复步骤。

r7 HAP `2026091308` 已安装。冷启动目录 `/tmp/piliplusx-ohos-fullscreen-lifecycle-fix-r7-cold`
通过一次全屏退出/进入并观察到播放帧；从首页脚本化回入后的同进程目录
`/tmp/piliplusx-ohos-fullscreen-lifecycle-fix-r7-reentry-cycles3` 完成 3 个连续全屏周期，owner=2
的每个 native enter/exit 均有 `start/finish`，方向和播放帧进展全部通过。颜色仍需同源同帧可视
对比，不能由本轮日志宣称已解决。

## 2026-09-11 r8 当前包生命周期门禁

当前源代码诊断包 `2026091309` 已在实体机安装。冷启动目录
`/tmp/piliplusx-ohos-process-live-current-r8-cold-1620` 再次通过 Dolby Vision 的全屏进入、退出、
再次进入和播放帧进展；颜色仍为 `INCONCLUSIVE`，符合“不能用日志替代同源同帧对比”的规则。

外部页面退出目录 `/tmp/piliplusx-ohos-process-live-current-r8-page-exit-1623` 观察到同一 PID
`61161` 保持不变，并完成同一触点的 page-pop、PointerCancel、global route removed、播放器
`dispose` 和 `nativeSurfaceDestroyed`。原有脚本只识别旧版 `hcpp_input owner/cancel/napi/attachment`
格式，因而曾错误报告失败；现已拆分为“应用页面生命周期门禁”（本轮 PASS）和“HCPP attachment
协议门禁”（本轮 NOT OBSERVED），不再把格式不匹配误判为运行时释放失败。下一步仍需在最终生产包
完成同进程重入复测，并保留 HCPP attachment 协议门禁作为独立证据项。

## 2026-09-11 r9 生产包复测

生产包 `2026091310` 已完成签名、verify-app 并显式安装到实体机，HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-fullscreen-lifecycle-fix-20260911-r9-signed.hap`，
SHA-256 为 `a33c856a7b0d576d75c71365817082e0df7e9e3c3d433be99027b330d24342df`。

冷启动目录 `/tmp/piliplusx-ohos-fullscreen-lifecycle-fix-r9-cold-1626` 通过 Dolby Vision
首次进入、退出、再次进入全屏，方向和播放帧进展均通过。随后在同一进程、同一视频页执行 3 个
连续播放中全屏往返，目录 `/tmp/piliplusx-ohos-fullscreen-lifecycle-fix-r9-reentry-cycles3-1630`
的每一周期均通过退出到 portrait、继续出帧、重新进入 landscape、继续出帧；未复现 r6 队列卡死
或持续灰屏。颜色与灰屏根因仍未完成同源同帧的客观对比，不能宣称颜色问题已解决；HLG/HDR Vivid
仍按计划保留待办。

## 2026-09-11 r10 requestId 诊断与 30 周期压力测试

诊断包 `2026091311` 已显式安装到实体机，HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-fullscreen-request-trace-20260911-r10-signed.hap`，
SHA-256 为 `e54cb803d55c6df589858df864663c4ba557910b7369bce2d0ce98277608959e`。

3 周期目录 `/tmp/piliplusx-ohos-fullscreen-request-trace-r10-cycles3-20260911-171347`
全部通过。新增 requestId 已贯通 Dart execute/invoke、MethodChannel、ArkTS handler、
`getLastWindow`、方向请求、`windowSizeChange`、committed 和 result；每次播放中退出均回到
portrait，再进入均到 landscape，未复现方向失败或持续灰屏。此前由 Hilog 外层时间戳造成的
“Flutter 已返回但原生未处理”判断不能作为根因。

正式 30 周期目录 `/tmp/piliplusx-ohos-fullscreen-request-trace-r10-cycles30-20260911-171703`
在第 3 周期按 fail-closed 规则失败，不能计为 30 周期通过。失败发生在已完成一次退出/进入且
方向均正确之后：播放状态先为 `buffering`，随后 15 次重试均为 `unknown`，但位置由 12% 推进
到 15%、帧仍变化。该证据更符合网络/播放器语义状态不可用，不支持修改全屏方向事务；后续需在
稳定播放状态下重跑正式门禁。颜色仍为 `INCONCLUSIVE`，HLG/HDR Vivid 仍为待办。

同一诊断包在提高搜索等待、并将短片结束重置阈值设为 80% 后完成正式 30 周期：目录
`/tmp/piliplusx-ohos-fullscreen-request-trace-r10-cycles30-restart80-20260911-174606`，脚本
返回码为 0。30/30 周期均在播放帧变化期间完成退出到 portrait、重新进入 landscape 和再次帧进展；
第 24 周期触发一次结束源重置后继续通过。事件中有 30 个 `cycle-complete`、61 个方向验证和 91
个播放进展证据；HDR decision evidence 为 PASS。该结果关闭 Dolby Vision 播放中全屏往返的正式
30 周期门禁，但颜色仍需同源同帧可视对比，HLG/HDR Vivid 仍保留待办。

## 2026-09-13 r11 生产包与触控验收边界

生产包 `2026091312` 已签名、verify-app 并安装到实体机，HAP SHA-256 为
`fd5e71dfa54fa1f12ece5dd41007b688ac371f282caaf46867a0d79a6294620b`。目录
`/tmp/piliplusx-ohos-fullscreen-lifecycle-fix-r11-production-cycles3-20260913-181118`
完成冷启动 3 周期播放中全屏往返，HDR decision evidence PASS，方向和帧进展通过。

Flutter 手势与播放器相关本地测试合计 56 个通过，包含命中边界、单指方向判定、取消和全屏队列。
但 r11 是生产包，`PlayerTouchTrace` 默认关闭；对 r11 执行的 `uiInput swipe`/`drag` 垂直探针
没有产生可验证的 Flutter 触摸或亮度/音量反馈，因此不计真实滑动手势通过。下一步需在 dev SSH
恢复后构建显式开启 `PILIPLUS_PLAYER_TOUCH_TRACE=true` 和 process-live hook 的 debug 诊断包，
用脚本完成左右边缘上下滑及 Down/Move/Up/Cancel 证据，再恢复安装 r11。

当前仍未关闭的计划项：生产包 page-exit/surface destroy-recreate 独立门禁、同源同帧颜色/灰屏客观
对比、SDR/PQ 切换验收、竖屏视频主体控制条与滑动专项验收，以及 HCPP attachment protocol
证据。HLG/HDR Vivid 因缺少可靠真实样片继续保留待办；尚未进入其它格式的正式长跑。

## 2026-09-13 r12 触控诊断包复测边界

因 dev SSH 恢复，已构建并签名触控诊断包 `2026091313`：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-gesture-diagnostics-20260913-r12-signed.hap`，
SHA-256 为 `38490439d411991e25ecee6ca71f0834a23b764ce508b45b0ad22e98aa72ce69`。该包已安装到
实体机并启用 `PILIPLUS_PLAYER_TOUCH_TRACE=true` 与 process-live hook。

播放唤醒目录 `/tmp/piliplusx-ohos-gesture-r12-wake-20260913-1747` 的一周期 HDR/方向/帧进展
通过；process-live 目录 `/tmp/piliplusx-ohos-gesture-r12-20260913-1750` 的应用生命周期门禁
通过（PID 稳定、page-pop、PointerCancel、route removed、dispose、surface-destroyed 均有证据）。
该包仍未观察到旧格式的 HCPP attachment protocol 记录，故该协议门禁继续为 NOT OBSERVED。

在真实 landscape 视频范围内，由脚本执行左侧 `(300,850)->(300,300)` 与右侧
`(2420,850)->(2420,300)` 两次 `uitest uiInput drag`，设备返回 `No Error`，但没有产生可验证的
播放器 `PlayerTouchTrace` 或亮度/音量反馈；同时 Hilog 持续报告 `power_host` 读取 brightness
失败。因此竖向手势仍不能计为通过，现有证据优先指向输入未到达 Flutter overlay 或设备亮度能力
异常，尚不能据此修改手势算法。尝试恢复 r11 生产包时被设备拒绝为 version downgrade，未执行卸载
或清数据；实体机当前仍为诊断包，后续需构建更高 versionCode 的生产包恢复。

随后使用 `tool/ohos/verify_player_vertical_gesture_real_device.sh` 在 r12 上重跑。脚本从
`08-fullscreen-stable.json` 派生左侧 `(136,1008)->(136,252)`、右侧
`(2584,1008)->(2584,252)`，并暂停 gate 子进程避免控制条点击打断手势。`swipe` 这一轮目录为
`/tmp/piliplusx-ohos-vertical-gesture-r12-swipe-20260913-1905`：HCPP 对 Down、连续 Move
以及终止 Cancel 均记录 `activeOwner=0 activeEpoch=1` 并成功提交 NAPI，说明完整触点链已到达
Flutter 输入引擎；但当前 trace 尚未记录 `_onPanUpdate` 的亮度/音量结果，且随后 gate 的 surface
生命周期操作触发了正常的 Cancel/dispose。因此本轮只关闭“脚本坐标与 HCPP Down/Move/Cancel
链路可观测”子门禁，仍不关闭“实际亮度/音量改变”和竖屏专项手势验收。

同一 r12 诊断包对已确认竖屏源 `BV1Wp4y1P7KU` 执行 `--vertical --cycles 3`。首次运行因该源
未进入 `nativeHdr` 被前置门禁停止；在仅关闭 HDR 前置门禁的诊断运行
`/tmp/piliplusx-ohos-vertical-video-r12-20260913-1940` 中，第 1 轮进入/退出和第 2 轮退出均
保持 portrait 且播放帧继续，第 2 轮再次进入时方向仍为 portrait，但控制条语义连续采样仍为
“全屏”（应为“退出全屏”），脚本按 fail-closed 停止。Hilog 同时显示对应 enter 请求已执行，
所以该边界需要继续检查 `isFullScreen` 的逻辑提交与竖屏布局重建时序，不能计竖屏 3 轮通过。

## 2026-09-13 r15 开发诊断包与播放态回归

为区分 HCPP 输入链路与播放器手势处理，在 r15 开发诊断包中增加了全屏逻辑提交、手势决策及
亮度/音量实际调用日志；未改变业务分支。包 `2026091315` 已签名并安装到实体机，当前继续保留
开发诊断包，不恢复生产包。

脚本目录 `/tmp/piliplusx-ohos-vertical-gesture-r15-20260913-181936` 使用实时布局派生的
`(136,1008)->(136,252)` 和 `(2584,1008)->(2584,252)` 坐标执行 `swipe`。HCPP 记录了
Down、连续 Move、Cancel，且 `activeOwner=0 activeEpoch=1`；但本轮没有出现 Flutter 侧
`pan-start`、亮度/音量分支或实际调用日志，故仍不能计竖屏手势通过。同期日志出现
`displayed=0`、窗口方向回到 portrait 及 surface size 重设，继续表明需要解决 PlatformView
生命周期/输入分发时序，而不是仅调整手势阈值。脚本因控制条重现失败返回 1，该失败按诊断门禁记录。

Dolby Vision 播放态 3 周期回归目录为 `/tmp/piliplusx-ohos-dv-r15-cycles3-20260913-182125`，
脚本返回 0，3/3 轮均完成 portrait/landscape 往返及播放帧进展，HDR decision evidence 为
PASS。颜色 verdict 仍为 `INCONCLUSIVE`，因为没有同源同帧的客观显示亮度对比；该轮仅证明 r15
诊断日志没有破坏既有 Dolby Vision 全屏生命周期链路。

## 2026-09-13 r16-r18 触控链路收敛

r16、r17、r18 均继续使用实体机上的开发诊断包，没有恢复生产包。此前 r15 测试脚本用
`SIGSTOP/SIGCONT` 暂停全屏 gate 子进程，不能可靠阻止 gate 在手势期间继续点击控制条；现已改为
`VERIFY_PAUSE_AFTER_STABLE_FILE` 文件屏障，避免测试自身制造额外触控/取消事件。

r18 目录为 `/tmp/piliplusx-ohos-vertical-gesture-r18-barrier-20260913-184656`，HCPP 记录了
同一触点的 Down、连续 Move 和 Cancel，Flutter 侧也记录了 PointerDown、`pointer-allowed=true`、
recognizer add-pointer 和 first-move。该轮使用左/右边缘竖滑；当前竖屏策略明确拒绝边缘竖滑，且
未出现 `move-filter`、`pan-start` 或亮度/音量实际调用，因此不能计为播放器手势功能通过。脚本
最终仍因全屏稳定后的控制条语义未重新暴露而 fail-closed，不能把该失败归因于“触摸未到达”。

为补齐此前缺失的正向路径，`verify_player_vertical_gesture_real_device.sh` 新增
`--region center`（或 `VERIFY_GESTURE_REGION=center`），用于在中心区域验证单指竖滑到全屏
决策；默认 `edge` 保留边缘策略探针。中心区域专项测试及其亮度/全屏实际效果仍待执行。

用户复测补充了重要边界：竖屏状态上下滑动时，若触点落到播放器下方区域，实际表现为推荐列表
滚动。这与当前布局一致——竖屏页面将播放器和下方推荐内容作为两个独立区域，播放器的
`MouseInteractiveViewer` 不覆盖推荐列表；因此该现象本身不是播放器手势成功，也不是播放器层
失效的直接证据。后续专项必须使用实时布局计算出的播放器矩形内部坐标，并同时记录播放器
`PointerDown/Move/Cancel` 与推荐列表 scroll offset，才能判断是否存在父级滚动竞争。

尝试以 `BV1Wp4y1P7KU` 执行竖屏中心专项时，目标源未进入 `nativeHdr`，前置门禁拒绝继续，目录为
`/tmp/piliplusx-ohos-vertical-video-gesture-r18-center-20260913-185401`；该轮没有产生手势结论，
不能把源格式前置失败误报为触控失败。当前本地手势/HDR 相关测试 56 项通过，脚本语法与 diff
检查通过；实体机专项仍未关闭。

## 2026-09-13 r19 arena 仲裁实验

r19 开发诊断包已在实体机完成构建、签名、校验和安装，未恢复生产包。播放器 recognizer 在单指
方向决策成立后新增显式 `resolvePointer(accepted)`，目标是让播放器在与
`ExtendedNestedScrollView` 共享 arena 时优先接管已判定为播放器手势的 pointer；拒绝路径仍释放
pointer，使明确的非播放器区域可以继续滚动。

竖屏窗口态中心专项目录为
`/tmp/piliplusx-ohos-vertical-video-gesture-r19-windowed-center-20260913-190713`。触点命中
播放器矩形，但仍只观察到首个 Move 和最终 Up，没有 `move-filter`、`accept-single-pointer` 或
`pan-start`；随后 gate 的状态被中心触控改变，导致竖屏期望检查失败。该结果表明父级滚动竞争或
OHOS Move 分发在方向判定前终止 recognizer 的假设仍需进一步证实，r19 不能计手势通过，也不能
据此宣称推荐列表滚动已修复。

r20 开发诊断包增加了 recognizer 的终止日志并完成实体机安装。窗口态中心竖滑目录为
`/tmp/piliplusx-ohos-vertical-video-gesture-r20-windowed-center-20260913-191214`；日志明确出现
`recognizer first-move pointer=7`，随后出现 `recognizer reject pointer=7 accepted=false`，而
没有方向过滤、单指接管或 pan-start。该时序确认播放器 recognizer 在方向过滤达到其当前 touch
slop 前已被 arena 拒绝，符合父级纵向 Scrollable 抢先获胜的解释。下一步应调整播放器与父级
Scrollable 的仲裁边界/预判时序，并为“播放器内手势”和“播放器外列表滚动”分别建立正反向测试，
不能只继续调业务层亮度或全屏阈值。

r21 验证了两阶段仲裁修复。竖屏窗口态中心专项目录为
`/tmp/piliplusx-ohos-vertical-video-gesture-r21-windowed-center-20260913-192025`，日志出现
`move-filter action=fullscreen`、`recognizer accept-single-pointer`、`pan-start`、
`pan-update type=fullscreen` 以及 `fullscreen commit target=true before=false vertical=true`；
播放器内部中心竖滑因此通过。业务动作发生在后续累计移动超过标准 `kTouchSlop` 后，未用降低业务
阈值替代 arena 修复。

同包边缘专项目录为
`/tmp/piliplusx-ohos-vertical-video-gesture-r21-windowed-edge-layout-20260913-192343`。
日志出现 `move-filter action=reject-portrait-edge` 和 recognizer reject，且即时 UI layout 的
可滚动节点从 `[0,2037][1260,2720]` 变为 `[0,978][1260,2720]`，同时保存了
`layout-before-gesture.json`/`layout-after-gesture.json`；这证明明确拒绝的竖屏边缘手势仍交给
推荐内容滚动，没有把整页滚动锁死。该脚本最后因继续执行后续全屏 gate 的语义状态变化而返回 1，
不影响上述两个手势子门禁结论。

同一 r21 开发包执行 Dolby Vision 播放中 3 周期回归，目录为
`/tmp/piliplusx-ohos-dv-r21-cycles3-20260913-192532`，脚本返回 0。3/3 周期均完成 portrait/
landscape 全屏往返、播放帧进展和 HDR decision PASS，说明本次触控 arena 修复未破坏既有 DV
全屏生命周期。颜色 verdict 仍为 `INCONCLUSIVE`，不替代同源同帧显示对比。

r21 横屏全屏态边缘竖滑专项目录为
`/tmp/piliplusx-ohos-dv-gesture-r21-landscape-edge-20260913-193334`。脚本注入的左侧手势命中
播放器亮度通道，右侧手势命中音量通道；两条路径均记录了 `accept-single-pointer`、`pan-start`、
`pan-update` 以及亮度/音量数值变化。该结果补齐了横屏手势正向证据，并与竖屏边缘“交给推荐列表
滚动”的策略保持区分。该轮仍保留同源同帧颜色比较未完成的限制。

r21 继续完成了非 DV 格式与生命周期探针：

- PQ 长源 `BV15z4y1Z734` 连续 3 轮目录为
  `/tmp/piliplusx-ohos-pq-sdr-r21-20260913-194324/BV15z4y1Z734`；3/3 轮全屏往返、帧进展和
  HDR decision 均通过。该源的格式分类仍按 Hilog 处理，不能由标题推断为 HLG 或 HDR Vivid。
- SDR 源 `BV1GJ411x7h7` 使用 `VERIFY_REQUIRE_HDR=0` 的非 HDR 门禁完成 3/3 轮，目录为
  `/tmp/piliplusx-ohos-sdr-r21-20260913-194811`；全屏往返、帧进展和 `Texture/SDR evidence`
  通过。颜色比较仍为 `INCONCLUSIVE`。
- surface 重建目录为 `/tmp/piliplusx-ohos-surface-recreate-r21-20260913-194037`。冷重启前后
  PID 分别为 8815、14204；新进程记录了 Flutter `OnSurfaceCreated`、`SurfaceChanged` 和
  新渲染窗口，baseline 的 HDR decision 和帧进展通过。该脚本明确是冷重启控制变量，不证明
  旧 isolate 收到 Cancel。日志中的 `XComponentBase is not attached` 实际来自 engine 的
  `OnDispatchMouseLeaveEvent`（日志文案复用了 `OnSurfaceCreated`），不是 surface 创建/销毁
  回调失败；仍保留为旧 XComponent/鼠标离开事件边界观察，不能把它扩大解释为视频 surface
  重建失败。
- 进程存活 Back 探针目录为 `/tmp/piliplusx-ohos-process-live-r21-back-20260913-193947`，
  返回 0、PID 保持不变，并观察到 overlay Down/Up 与 attachment dispose；但没有观察到旧
  pointer 的 Cancel，因此不关闭完整 PointerCancel 门禁。使用应用内部 hook 的另一轮因未产生
  `process-live-test page-pop` 而 fail-closed，目录为
`/tmp/piliplusx-ohos-process-live-r21-20260913-193820`，不计入通过。

## 2026-09-13 r22 生命周期修复后复验

r22 开发诊断包已完成构建、签名、校验、安装和启动，HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-gesture-lifecycle-r22-signed.hap`，设备安装版本为
`2.1.3 (2026091322)`。本轮没有恢复生产包。

竖屏窗口态中心脚本目录为
`/tmp/piliplusx-ohos-vertical-r22-windowed-center-20260913-201423`。动态播放器矩形内的滑动
记录了 `move-filter action=fullscreen`、`accept-single-pointer`、`pan-start`、
`pan-update type=fullscreen` 和 `fullscreen commit target=true before=false vertical=true`；
因此该正向手势确实由播放器接管，没有把播放器内滑动误判为推荐列表滚动。触点落在播放器
下方时推荐列表滚动仍符合布局边界，不能用来证明播放器手势失败。

r22 Dolby Vision 播放中全屏回归目录为
`/tmp/piliplusx-ohos-dv-r22-cycles3-20260913-200720`，3/3 周期完成方向往返、播放进展和
HDR decision。颜色 verdict 仍为 `INCONCLUSIVE`，没有同源同帧实屏对照。

r22 横屏边缘脚本目录为
`/tmp/piliplusx-ohos-dv-gesture-r22-landscape-edge-20260913-201821`，脚本命令返回成功并
记录了全屏提交，但本次独立采集窗口没有形成亮度/音量 recognizer 与数值变化记录，因此横屏
边缘亮度/音量手势不计通过；`uiInput No Error` 不等价于业务手势成功。

r22 surface 生命周期脚本目录为
`/tmp/piliplusx-ohos-surface-recreate-r22-20260913-202055`，返回 0。冷重启后的新 Flutter
进程记录了 `OnSurfaceChanged`、新 native window 和视频继续出帧，baseline 的 HDR decision
和帧进展通过；该脚本是冷重启控制变量，不是同进程 native video surface destroy/recreate，
也不关闭 PointerCancel → 新 attachment → native ready 门禁。

本地手势、全屏队列、触控 trace 和 hit-test 定向测试 23 项全部通过。r22 仍未关闭同源同帧
颜色对照、同进程活动 pointer Cancel 闭环、横屏边缘亮度/音量本轮缺失证据、macOS 共享代码
回归以及 HLG/HDR Vivid 样片待办。

## 2026-09-13 r24 process-live 诊断包

r24 仅在 r22 基础上增加 `PILIPLUS_PROCESS_LIVE_TEST=true`，已完成 dev 远端构建、HAP 签名、
verify-app 校验和实体机安装，产物为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-r24-signed.hap`。安装后的启动由
设备锁屏门禁拒绝：`10106102`，开发者模式下 HDC 无法自动解锁。已脚本化执行 `power-shell
wakeup` 并重试 `aa start`，仍被锁屏拒绝，因此本轮没有伪造 process-live 结果，也没有执行
任何手工 UI 操作；设备解锁后应直接使用已安装 r24 重跑该脚本。

随后对 media-kit 共享代码做了不改变运行语义的静态收敛：OHOS 控制器通过
`NativePlayer.isReleaseCallbacksActive` 查询 release callback 窗口，不再越过
`PlatformPlayer` 的 protected 成员；定向 analyze 已无 warning，仅保留 2 条既有文档注释
info。该源码变化尚未重新打包进实体机，因此不能修改 r24 的运行时结论。

## 2026-09-13 r25 process-live 与格式矩阵复验

r25 已将上述 media-kit accessor 纳入 HAP，并完成实体机安装启动。持续播放基线目录为
`/tmp/piliplusx-ohos-process-live-r25-baseline-20260913-210218`，HDR decision 和帧进展通过，
颜色仍为 `INCONCLUSIVE`。

同进程 process-live 目录为
`/tmp/piliplusx-ohos-process-live-r25-external-20260913-210403`，应用生命周期门禁通过：
PID 保持 `63959`，活动 pointer=21 的 page-pop、PointerCancel、global route removed、
dispose 和 nativeSurfaceDestroyed 顺序完整。HCPP attachment protocol 仍为
`NOT OBSERVED`，两个门禁不合并解释。

r25 可用格式矩阵目录为
`/tmp/piliplusx-ohos-hdr-matrix-r25-20260913-210704`。`BV15z4y1Z734` 3 周期方向/帧进展/HDR
decision 通过；HLG/HDR Vivid 按用户要求跳过。对照源 `BV1tM4y1L7EF` 的第一次矩阵执行因
控制条/全屏语义未稳定而 fail-closed。复核确认该源实际为 HDR10 横向视频，不能因设备页面暂在
portrait 就标记为竖屏视频；矩阵脚本现仅支持显式 `VERIFY_SOURCE_PQ_HLG_SDR_VERTICAL=1`
声明，默认不猜测源方向。该对照源仍需在控制条稳定后重跑。
矩阵脚本曾把 `BV1tM4y1L7EF` 的设备 portrait 页面误当成竖屏视频，导致方向断言错误；现已改为
仅在显式 `VERIFY_SOURCE_PQ_HLG_SDR_VERTICAL=1` 时传递竖屏约束，默认不猜测视频方向。

真正竖屏源 `BV1Wp4y1P7KU` 的 r25 专项目录为
`/tmp/piliplusx-ohos-vertical-r25-fullscreen-20260913-212023`，显式 `--vertical` 后首轮和第二轮
均保持 portrait，并完成播放中全屏进出与帧进展；第三轮因源约 7 秒自然结束，恢复播放后语义状态
未稳定而 fail-closed。该结果证明竖屏不旋转路径可工作，但不关闭长周期竖屏门禁。

r25 竖屏中心手势专项目录为
`/tmp/piliplusx-ohos-vertical-gesture-r25-center-20260913-212431`；本轮在全屏稳定检查阶段发现
当前实际窗口为 landscape，因显式竖屏前置与运行时方向不一致而 fail-closed，未采集手势 verdict。
这与上面的真正竖屏源全屏短周期证据分开记录，不将失败归因于推荐列表或手势 recognizer。

### 2026-09-13 r25c 竖屏手势坐标与方向复验

修正 `verify_player_vertical_gesture_real_device.sh`：新增 `--vertical`，并确保 fullscreen
phase 也向主 gate 传递竖屏约束。实体机复验目录为
`/tmp/piliplusx-ohos-vertical-gesture-r25c-center-20260913-213405`；首次全屏稳定态为
`portrait`，实际注入的两次中心竖滑均返回 `No Error`，命令坐标由动态播放器矩形派生为
`(630,2193)->(630,641)`。

本轮日志确认触点进入播放器：有 `MouseInteractiveViewer Listener PointerDown`、
`PlPlayerView _onPointerDown`、`recognizer first-move`，随后 tap recognizer 被 arena 拒绝；
但没有 `pan-start`、`pan-update` 或亮度/音量业务回调，因此该轮不计播放器竖滑通过。全屏
提交日志明确为 `vertical=true`，首轮方向门禁通过；后续 gate 因控制条无法稳定重新暴露而
fail-closed，不能把 gate 失败归因于推荐列表滚动。

本轮还确认播放器下方区域在无障碍布局中是独立的可滚动 body（视频/标签区域之后的
`Scroll`）。因此用户观察到的“播放器下方上下滑动滚动推荐列表”是触控边界正证据。后续
播放器手势验收必须使用播放器矩形内部坐标，并把推荐列表滚动作为反向边界断言；不能用下方
区域的滚动结果判断播放器 recognizer 是否失效。

同轮补充的本地 `player_view_hit_test.dart` 边界回归通过：播放器矩形外的拖动使推荐列表
`ScrollController.offset` 增大，固定了“播放器外可滚、播放器内由播放器决定”的布局契约。

### 2026-09-13 r25d 同进程重入复验

在仍在线的实体机上以 `VERIFY_REUSE_CURRENT_APP=1` 重跑 `BV15z4y1Z734`，目录为
`/tmp/piliplusx-ohos-same-process-reentry-r25d-20260913-213813`。脚本未 force-stop，复用同一
应用进程完成窗口态 portrait → fullscreen landscape → portrait → fullscreen landscape，1 周期
方向事务和视频主体帧进展通过，HDR decision 通过，颜色仍为 `INCONCLUSIVE`。

该轮补齐了“同进程可重新进入播放器并持续出帧”的应用层证据，但脚本没有形成可解析的旧
page-pop 后 `nativeSurfaceDestroyed → 新 attachment/native ready` 成对标记，因此仍不能关闭
严格的同进程 surface 重建门禁，也不能把颜色问题标记为已解决。

### 2026-09-13 r25e page-exit 编排复验

新增 `verify_surface_page_exit_reentry_real_device.sh`，将全屏稳定屏障、process-live page-exit
和同进程 re-entry 串成单一脚本。实体机目录为
`/tmp/piliplusx-ohos-surface-page-exit-reentry-r25e-20260913-214318`。前半段成功：
`page-pop=1`、PID=`27166` 稳定、Dart PointerCancel=2、route removed、dispose 和
`nativeSurfaceDestroyed` 顺序完整；HCPP attachment protocol 仍为 `NOT OBSERVED`。

重入阶段未通过，失败发生在搜索结果页返回“视频 0/没有数据/点击重试”，不是播放器输出或
方向门禁；同目录的独立重试仍停在同一网络前置。因而本轮只关闭了编排脚本的 page-exit
生命周期半程，不能关闭“surface 销毁后新 attachment/native ready/持续出帧”的完整门禁。

### 2026-09-13 r25f 竖屏 windowed drag 对照

同一 r25 包、真实竖屏源使用 `VERIFY_GESTURE_COMMAND=drag` 在 windowed phase 重跑，目录为
`/tmp/piliplusx-ohos-vertical-gesture-r25f-windowed-drag-20260913-214654`。两次输入均返回
`No Error`，但播放器仅收到 Down/Up，没有形成 `first-move → move-filter →
accept-single-pointer → pan-start/pan-update` 链，因此仍不计手势通过。对比 r21 的完整链路，
不能仅通过替换 `swipe`/`drag` 认定为脚本输入问题；后续继续保留 HCPP 原始事件与 Flutter
trace 的分层证据。

### 2026-09-13 r25h 同进程 surface 销毁后重入成功

修正主 gate 对“视频 0/没有数据”空搜索结果页的状态归一化：脚本现在会通过语义返回离开该页，
重新解析首页搜索入口，而不是在旧空结果页反复点击“点击重试”。随后重跑专用编排脚本，目录为
`/tmp/piliplusx-ohos-surface-page-exit-reentry-r25h-20260913-215135`。

本轮完整闭环通过：page-exit 前后 PID 均为 `32340`；旧 attachment `platformViewId=0` 被
dispose，旧 native surface 产生 `nativeSurfaceDestroyed`（surfaceId=`25683904435488`）；同一
PID 重入后创建新 `VideoOutput`（textureId=3），新 attachment `platformViewId=1`，并收到
`nativeSurfaceReady`（surfaceId=`25683904435489`）。重入后 `BV15z4y1Z734` 完成 1 周期全屏方向
往返、HDR decision 和视频主体帧进展，脚本返回 0。该证据关闭了严格的
`nativeSurfaceDestroyed → 新 attachment/native ready → 持续出帧` 应用层门禁；旧 HCPP
attachment protocol 统计仍单独为 `NOT OBSERVED`，颜色仍需同源同帧实屏对照。

### 2026-09-13 r25i 竖屏推荐列表边界与运行时拖动复验

使用同一 r25 诊断包和真实竖屏源 `BV1Wp4y1P7KU`，目录为
`/tmp/piliplusx-ohos-vertical-gesture-r25i-windowed-drag-20260913-220316`。脚本由
语义布局动态解析播放器矩形，窗口态与全屏态方向均为 `portrait`，且播放主体帧进展被观察到。
但在控制条超时后，后续全屏控制语义未重新稳定暴露，主 gate 按 fail-closed 规则停止；两次
windowed `drag` 虽返回 `No Error`，本次只采集到播放器区域的 Down/Up，没有形成
`first-move → move-filter → accept-single-pointer → pan-start/pan-update`，不计手势通过。

该失败不改变布局边界结论：`player_view_hit_test.dart` 的简单列表用例确认播放器矩形外的竖向拖动
仍可推进推荐列表；真实 `ExtendedNestedScrollView` 用例进一步确认播放器矩形内外的
`PointerDown` 过滤边界分别生效。播放器矩形内才进入播放器自己的单指方向判定。不能通过扩大
透明播放器 overlay 到整个页面来“修复”推荐列表滚动，否则会重新制造控制条、播放器手势与
页面滚动的职责冲突。
## r25j：播放器区域与推荐列表的按下时所有权边界

用户观察到的“竖屏上下滑动滚动推荐列表”说明触点落在播放器与推荐列表共享的嵌套滚动竞技场中。播放器矩形内若让外层 `Scrollable` 先入场，OHOS 首个小位移就可能把手势交给推荐列表；播放器矩形外则应保持推荐列表可滚动。

本次落实了按下时过滤：`ExtendedNestedScrollView.pointerDownFilter` 根据现有播放器 RenderBox 的全局几何范围，在 `PointerDown` 阶段拒绝播放器区域的外层竖向 recognizer；区域外返回允许。所有权从 Down 到 Up/Cancel 固定，不再依赖 1px/2px 阈值抢竞技场。对应 Flutter SDK 与 `extended_nested_scroll_view` 的补丁会由构建准备脚本自动应用。

模拟器/Flutter 测试新增真实 `ExtendedNestedScrollView` 边界用例，并验证播放器区域与区域外分别触发过滤；目标设备实体机回归仍需安装不带 process-live 注入的最新 HAP 后执行脚本确认。

r30（`2026091330`）、r31（`2026091331`）和最新 r32（`2026091332`）均完成 OHOS 兼容准备、
HAP 构建、签名和 `verify-app`；r32 产物为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-gesture-r32-signed.hap`，
SHA-256 为 `0a5c286587fce84dbf0e9d09d5c92322e54f24b564b1bef87a7ae8fc0affc3fc`。多轮安装时目标设备
均处于 HDC `Offline`，因此尚未形成实体机手势通过证据。

### r32 实体机触控边界验收（2026-09-14）

设备恢复在线后，r32 成功安装并启动。全屏中心竖向手势脚本目录为
`/tmp/piliplusx-ohos-vertical-gesture-r32-fullscreen-20260913-233421`，真实竖屏源
`BV1Wp4y1P7KU` 形成 `outer-scroll pointer-rejected`、`accept-single-pointer`、`pan-start`、
`pan-update type=fullscreen` 完整链，脚本 verdict 为 `PASS`；同时记录 Texture/SDR 与视频帧进展通过，
颜色仍保持 `INCONCLUSIVE`。

新增推荐列表区域脚本 `tool/ohos/verify_player_recommendation_scroll_real_device.sh`，目录为
`/tmp/piliplusx-ohos-recommendation-scroll-r32-20260914-000500`。窗口态播放器下方的脚本滑动使
列表文本锚点从 `y=2069` 移至 `y=1891`，并完成播放/全屏前置门禁，verdict 为
`recommendation scroll verdict: PASS`。这两条证据分别关闭播放器内和播放器外的触控所有权门禁，
不把 HDC `No Error` 单独当作通过。

### r32 surface 重建探针补充（2026-09-15）

使用真彩 HDR 源 `BV15z4y1Z734` 和同一签名 HAP 完成一次脚本化连续播放基线：方向、帧进展及
`HDR decision evidence` 均为 `PASS/OBSERVED`，颜色仍为 `INCONCLUSIVE`。随后执行
`tool/ohos/verify_surface_recreate_real_device.sh` 的冷重启实验，artifact 为
`/tmp/piliplusx-ohos-surface-recreate-r32-dv-20260915-000400`；实验完成并记录重启后 PID、窗口
和日志，但这是 force-stop/start 控制变量，不证明旧 Dart isolate 收到 Cancel，也不关闭活动
pointer Cancel 或同进程 surface recreate 门禁。

同轮使用普通源 `BV1Wp4y1P7KU` 时，基线按 `nativeHdr` 前置条件 fail-closed，未进入重建动作；
这不是播放或重建失败。后续 native surface 生命周期复验必须使用运行时确认为 native HDR 的
源，并将旧进程 Cancel、attachment identity 变化和重建后继续播放分别记录。

随后使用同一专用 process-live debug HAP 复跑 `tool/ohos/verify_process_live_view_exit.sh`，
artifact 为 `/tmp/piliplusx-ohos-process-live-r25-external-recheck-20260915-001700`。在持续
播放的真彩 HDR 场景中，应用生命周期门禁输出 `page-pop=1`、`listener-cancel=1`、
`route-cancel=1`、`dispose`、`nativeSurfaceDestroyed` 且 PID 保持稳定；该门禁现有新一轮
实体机证据。该包没有 `hcpp_input` 记录，因此 HCPP attachment protocol 仍明确为
`NOT OBSERVED`，不由应用层通过结果代替。验证脚本已同步收紧 Cancel 计数及 HCPP 记录存在时的
失败分类；重入编排器也改为在 page-exit 证据采集后终止旧 gate，避免过期坐标污染重入测试。

同一 debug HAP 的完整 page-exit → re-entry 编排随后返回 `page_exit_rc=2`、`reentry_rc=1`：
page-exit 应用层仍为 PASS，但 HCPP 日志只有同一 attachment 的 Down/Up、没有 Cancel，故新判据
明确报告 HCPP `FAIL`；重入阶段目标视频连续返回“没有数据/点击重试”，按网络前置失败处理，
不把它计作 surface 重建失败。更长的 `drag` 复验中应用层仍为 PASS（Listener/route Cancel
各一次、PID 稳定），但没有任何 `hcpp_input` 记录，继续保持 `NOT OBSERVED`。这两轮共同说明：
应用页面生命周期 Cancel 已可复验，HCPP attachment Cancel 仍需在实际 DISPLAY 输入块保持可见且
活动 pointer 与 dispose 重叠的条件下单独闭环。

为制造该重叠条件，新增仅 debug 诊断开关 `PILIPLUS_PROCESS_LIVE_DIRECT_PAGE_POP=true`，不新增
生产 Cancel API，也不改变默认全屏返回路径。对应 HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-direct-20260914-signed.hap`，SHA-256
为 `b439770a67810e2bc62329d4f37ae8d6c29c39c81f0fe64e426b4cff20287175`，已完成构建、签名、
`verify-app` 和实体机安装。该包真彩 HDR 基线通过；直接 page-pop 复验中 Flutter Listener/全局
route Cancel 均在页面销毁前产生且 PID 稳定，但该触点没有 `hcpp_input` 运行时记录，因此仍不能
关闭 HCPP attachment Cancel 门禁。它只证明应用层可在原生 Up 前取消，不能替代 embedding 侧
owner/NAPI Cancel 证据。

本次 HAP 的 embedding HAR 实际来自 `dev:/home/wuweiwei1/tools/flutter-ohos`，其
`PlatformViewsControllerHybrid.ets` SHA-256 为
`8189ff3048817371cf66c19190c90d36009c51770fb5768fa0cc3e8b6aad268a`；本地
`/Users/wuweiwei1/src/flutter-ohos-e3` 是独立 dirty checkout，不能把本地源码状态直接视为
该 HAP 的运行时实现。后续若要修复或关闭 HCPP 门禁，必须先同步/构建明确版本的 embedding HAR，
再用最终 HAP 做实体机验证。

### 2026-09-14 竖屏推荐列表边界脚本一致性

用户补充确认：竖屏状态从播放器下方区域上下滑动时，页面应滚动推荐列表；这不是播放器内
手势失败。播放器内滑动和播放器外列表滑动必须作为两条相反边界断言分别验收。为避免候选
包切换时误测设备上的旧包，`verify_player_vertical_gesture_real_device.sh` 已补齐 `--hap`
参数，并与推荐列表脚本统一支持显式 HAP；操作文档同步更新。脚本语法与帮助输出检查通过。
本轮实体机未重跑，因 HDC 目标仍为 `USB Offline`。

### 2026-09-14 r32 重连后边界与 Dolby Vision 复验

设备恢复在线后，使用同一份 `PiliPlusX-ohos-gesture-r32-signed.hap` 完成两条触控边界复验。
推荐列表脚本先因首页推荐标题“迎新版本推送”被全局文本匹配误判为版本弹窗；收紧
`has_update_dialog` 后，脚本正常进入视频页，播放器下方列表文本锚点由 `y=2069` 移至 `y=1891`，
并输出 `recommendation scroll verdict: PASS`。同时修正脚本在列表证据完成后释放无关全屏 gate 的
编排问题，避免后续全屏失败污染列表 verdict。artifact 为
`/tmp/piliplusx-ohos-recommendation-scroll-r32-final-20260914-100439`。

播放器内竖滑脚本以 `VERIFY_REQUIRE_HDR=0`（触控专项，不改变应用 HDR 实现）运行，真实竖屏保持
portrait，播放器内中心滑动观察到 `outer-scroll pointer-rejected`、recognizer 接管链和
`gesture verdict: PASS`；artifact 为
`/tmp/piliplusx-ohos-vertical-gesture-r32-dialogfix-sdr-20260914-100150`。

同一 r32 包的真彩源 `BV15z4y1Z734` 完成 3 周期播放中全屏回归，HDR decision、方向和帧进展通过，
颜色仍为 `INCONCLUSIVE`。随后扩大到 30 周期时，慢启动经过延长的 HDR 等待窗口后进入循环，
但第 2 周期退出全屏后播放语义变为 `unknown`；虽有视频帧变化，脚本仍按 fail-closed 停止，
未将其计作 30 周期通过。artifact 为
`/tmp/piliplusx-ohos-dv-r32-cycles30-hdrwait-20260914-101232`。该轮说明当前剩余是播放/缓冲
语义时序门禁，不放宽为视觉帧通过。

随后将语义状态恢复重试提高到 15 次、间隔 2 秒再次执行 30 周期；该轮完成 3 个周期后在第 4
周期出现真实 `加载中` 画面，进度仍从 `70%` 推进到 `76%`，但 15 次采样均为 `buffering/unknown`，
故仍按播放/缓冲前置失败停止。artifact 为
`/tmp/piliplusx-ohos-dv-r32-cycles30-semanticwait-20260914-101708`。这进一步证明不应以进度
变化替代稳定播放状态，也未将 30 周期门禁标记为通过。

architect 复核该 artifact 后收紧了历史表述：`events.tsv` 中第 3 周期曾出现
`before=playing after=buffering frame=changed`，并由旧版 `slider-plus-video-frame` 分支弱放行，
因此不能把“完成 3 周期”表述为 3 个稳定播放周期。已修改验证脚本，使 position+视频帧证据在
任一端为 `buffering` 时拒绝；同样收紧 restart-position 分支。后续 30 周期结果必须重新在该
分类规则下取得，不能复用旧版弱证据。

为定位首次停顿来源，media-kit 的本地 dirty checkout 已增加 debug-only
`MediaKitBufferTrace` 低层标记，分别记录 `core-idle` 与 `paused-for-cache` 的单调时钟和值；
应用层仍只消费既有单一 buffering stream，不新增第二套状态。该改动尚未构建进新的 HAP，需在
下一次固定 media-kit/HAR/native 产物身份的诊断包中验证。若日志显示缓存先耗尽，落到数据供给/
缓存配置层；若原始属性正常而派生值错序，才在 media-kit 归并层修复；若停顿紧随 surface/
输出变化，再回到 OHOS VO 生命周期排查。控制条状态机暂不重写。

随后构建并安装仅含 touch/state/source trace 的开发 HAP，manifest 中 HAP SHA-256 为
`b9110bf98cc2bbb25c5ba2011b06c91afcb922bf799c71be596e7335fdebc459`，artifact 为
`/tmp/piliplusx-ohos-dv-buffer-trace-20260914-1101`。该轮在首次全屏后按新门禁停止，未计入
4 周期；但低层时间线首次确认：`core-idle=true` 后紧接 `paused-for-cache=true`，解除时
`core-idle=false/paused-for-cache=false`，位置从约 `0.133s` 到 `0.334s` 仅推进约 `201ms`，
随后以约 3 秒间隔反复发生。期间同时出现 `EGL_BAD_MATCH`/旧 surface 查找失败和 native HDR
重新应用，因此当前证据支持“缓存停顿与输出重建同时存在”，尚不能把唯一根因归给任一层。
下一版 trace 还将记录 `demuxer-cache-time` 与 `cache-buffering-state`，用于判断缓存是否先
耗尽；该轮输出为诊断证据，不是 DV 周期通过。

指标 trace 已在同一设备、同一片源的 1 周期 gated 重跑中验证有效，artifact 为
`/tmp/piliplusx-ohos-dv-buffer-metric-gated-20260914-1112`。seek 后新增的真实非 buffering
前置通过；但退出全屏后的首个 post-transition 采样仍为
`before=buffering after=unknown frame=changed`，脚本返回 1。此时缓存时间约 `62s`，而
`core-idle=true` 与 `paused-for-cache=true` 同时出现，随后缓存百分比从 `0–4%` 回升到
`100%`；这说明全屏退出附近存在输出/核心重配置导致的停顿或状态合并问题，不能再归因为缓存
耗尽。下一版继续记录原始 `pause` 属性，确认是否真的发生了用户/播放器暂停，再决定修复
media-kit 的 buffering 归并或 OHOS VO/surface 生命周期。

为区分控制条超时与真实缓冲，新增 debug-only `player-state` trace 并构建签名包
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-r32-state-trace-20260914-signed.hap`，SHA-256 为
`546571fd9019401ccb77b3eaa3c8a66c8557f719ddde1505543765c8201cf957`。该包的 3 周期真彩回归
仍通过 HDR decision、方向和帧进展，但状态 trace 显示 `playing=true` 仅初始化一次，随后
持续出现约每几秒一次的 `buffering=true/false`；这与第 4 周期 artifact 中的 `加载中` 一致，
确认该轮是实际播放/缓冲抖动，不应仅靠进度变化判定稳定播放。
artifact：`/tmp/piliplusx-ohos-dv-r32-state-trace-3cycles-20260914-103131`。

同一 state-trace 包继续执行播放器内竖滑专项，artifact 为
`/tmp/piliplusx-ohos-vertical-gesture-state-trace-keepgate-20260914-104815`。为避免
手势发生后立即释放 gate 导致 OHOS 日志尚未落盘，脚本在手势后保留 gate 直到 trace 刷新，再
单独分类手势结果。日志形成 `outer-scroll pointer-rejected` → `accept-single-pointer` →
`pan-start` → `pan-update type=fullscreen` 完整链，最终输出
`gesture verdict: PASS (player accepted center vertical gesture)`。同轮主 gate 后续未能稳定重新
暴露全屏控制语义，且 debug process-live 注入触发 page-pop/cancel；因此该 artifact 只证明
播放器内触控所有权，不关闭控制条时序、生产生命周期或 HCPP attachment Cancel 门禁。

本轮 Flutter 定向测试 `test/plugin/pl_player test/common/widgets/gesture` 共 59 项通过；
三个实体机脚本均通过 `bash -n`，`git diff --check` 通过。共享代码与脚本门禁已具备回归证据，
但真实设备剩余问题仍集中在播放/缓冲稳定性、控制条语义时序、颜色同源同帧对照及 HCPP 协议证据。

带原始 `pause` 属性的诊断 HAP manifest 中 HAP SHA-256 为
`f9d0871955029c0352eeffe8fcfb1ead7b4237c178a798652915e73ab114c2c0`，artifact 为
`/tmp/piliplusx-ohos-dv-buffer-pause-20260914-1117`。该轮只出现初始化阶段
`pause=false`，全程没有应用/用户 `pause=true`；但在缓存约 `36–62s` 时仍反复出现
`core-idle=true`、`paused-for-cache=true` 和 `cache-buffering-state=0`，随后恢复到
`100`。因此可以排除“播放器主动暂停”以及“缓存已耗尽”两种解释，当前首要嫌疑收敛为
全屏切换触发的 OHOS VO/surface 重配置与 media-kit buffering 状态映射之间的交互。该轮
退出全屏后的播放门禁仍 fail-closed，不能计为 DV 周期通过；下一步应沿 output generation、
surface resize/attach 和 mpv property 事件的同一时间线检查，而不是修改控制条状态机。

另建固定 producer extent 的 debug-only 对照包尝试隔离尺寸变化，但 seek 后始终未取得非 buffering
的有效前置样本，artifact 为 `/tmp/piliplusx-ohos-dv-fixed-extent-20260914-1124`，不进入
任何通过统计，也不足以支持修改 `force` resize。该实验按无效诊断记录保留。

跳过 `ohos-surface-size` 属性更新的 debug-only 对照包已构建签名，但首次脚本运行在进入全屏前
即被新的稳定播放门禁拦截，artifact 为
`/tmp/piliplusx-ohos-dv-skip-size-20260914-1132`。seek 后状态短暂为 `playing`，随后反复为
`buffering/unknown`；低层 trace 显示缓存约从 `4.8s` 增长到 `10s`，期间仍出现
`core-idle/paused-for-cache`。因此该轮未形成有效的全屏 A/B 对照，不能据此判断跳过属性更新
是否有效，也再次确认稳定播放前置仍未解决。

随后修正验证脚本的播放状态重试时序：控制条超时后，每次状态重试都会从最新布局重新唤醒，
避免把隐藏控制条解析为 `unknown`。使用热缓存且不 seek 的同一诊断包完成 1 周期，退出/进入
全屏均有方向与播放推进证据；artifact 为
`/tmp/piliplusx-ohos-dv-skip-size-retryfix-20260914-1148`。日志显示两次全屏尺寸变化确实
发生，但未在转换时新增 `core-idle/paused-for-cache`；该包只作诊断，颜色仍为
`INCONCLUSIVE`。

为修复长周期中退出全屏后偶发横屏残留，Flutter OHOS 方向监听现在在全屏事务进行期间不再
响应中间旋转事件，避免向同一 owner 的平台队列追加过期 enter/exit 请求。定向 Flutter 测试
通过 19 项；新 debug HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-orientation-guard-20260914-signed.hap`，SHA-256
为 `b978706dfddf9dd5b2b24ee1fb6d509e9d08595994a616fcdc27479e3a65edfa`。同一包在实体机
正常在线时完成 4 个热缓存播放中全屏周期，包含片尾重启后的第 4 周期，全部通过方向和播放
推进门禁，artifact 为 `/tmp/piliplusx-ohos-dv-orientation-guard-4cycles-20260914-1200`。

同一包继续执行 20 周期时，第 4 周期方向已正确恢复 portrait，但随后实体机 HDC 变为
`USB Offline`，连续布局 dump 无输出，脚本按 fail-closed 停止；artifact 为
`/tmp/piliplusx-ohos-dv-orientation-guard-20cycles-20260914-1230`。该轮不是播放器断言失败，
也不能计入 20 周期通过；必须在设备重新 Online 后重跑完整 20 周期。

## 2026-09-14 本轮离线期间的静态复核

本轮复核时 `/Users/wuweiwei1/bin/hdc list targets -v` 仍为 `[Empty]`，因此没有重启或重算实体机
验收。方向守卫版本的 Flutter 定向测试共 25 项通过（全屏请求队列、owner 生命周期、播放器
触控边界、手势仲裁和 trace），`flutter analyze` 针对 controller/fullscreen/queue 无问题，
`tool/ohos/*.sh` 全部通过 `bash -n`，`caffeinate -dimsu flutter build macos --debug` 构建成功。
这些结果只证明代码和构建链路，不替代实体机播放、同源同帧颜色或 surface/HCPP 生命周期证据。

随后经独立 architect 复核确认，`PlPlayerController` 的 native orientation listener 当前只在
`PlatformUtils.isMobile` 成立时注册，而该条件不包含 OHOS；因此新增的 OHOS transaction guard
没有可达性证据，已撤回，避免把 4-cycle 结果错误归因于它。正式验证器已改为默认拒绝
`playing→unknown` 等弱播放证据；`VERIFY_ALLOW_WEAK_PLAYBACK_EVIDENCE=1` 仅用于诊断，不能
计入正式周期。下一步应先建立当前 HAP 的方向事件/请求统一时间线，再决定 native barrier 或
应用队列的修复层级。

当前源码对应的新 debug HAP 已重新构建、签名并通过 `verify-app`：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-strict-playback-20260914-signed.hap`，SHA-256 为
`6990d0577efcd5a5bdb769720581b22cb2a1c9edd7df6f80bb90f8588e131c5b`。构建完成时 HDC 仍为
`[Empty]`，所以尚未安装或运行该候选包。

根据 architect 对原生完成屏障的复核，`media-kit` OHOS `Utils.ets` 已改为只有在
`setPreferredOrientation` 成功且窗口几何匹配时才完成方向事务；窗口尺寸事件先到不再提前
resolve，API 失败仍立即 reject。基于该源码重新构建签名 HAP：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-strict-barrier-20260914-signed.hap`，SHA-256 为
`1f04308443e7aec50ef0ec94f53edf34d52d857c09c7d28d3bb5eff493e0cdc6`，并通过 `verify-app`。
构建后 HDC 仍为 `[Empty]`，尚未安装或进行实机验证。

进一步修复同一 controller 的 surface-loss 恢复：`nativeSurfaceDestroyed` 现在只在 controller
已 dispose 时清除 native candidate；存活 controller 会保留候选资格，使新的 XComponent 和
generation 能重新发出 `nativeSurfaceReady`，再恢复 native 输出/HDR。该改动已重新构建签名并
通过 `verify-app`：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-surface-recovery-20260914-signed.hap`，SHA-256 为
`80bb0fe32240220a8affed08b892e53d99426af2c98486865f8fcdba85e80de2`。HDC 仍为 `[Empty]`，
尚未安装或实测。

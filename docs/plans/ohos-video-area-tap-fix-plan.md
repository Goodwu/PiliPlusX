# OHOS 视频区域点击无效修复计划

更新时间：2026-09-08

本文供 Luna 及后续实现 Agent 执行。目标是修复实体机
`2PM0223A18006914` 上视频主体区域点击无法唤出控制条的问题，同时保留 OHOS
native surface/HCPP 和 HDR 输出路径。

## 1. 目标与硬约束

### 目标

- 视频主体区域单击可以唤出和隐藏控制条。
- 视频主体区域的双击、长按、亮度/音量滑动、横向 seek、双指缩放保持正常。
- 控制条、进度条、字幕、弹幕、全屏和页面列表之间的命中边界稳定。
- native surface 在播放、旋转、全屏、前后台、seek、重播和销毁重建后仍可交互。

### HDR 硬约束

- 所有平台只要硬件能力满足 HDR，实现 HDR 就是硬约束。
- 本任务不得关闭 OHOS native surface、HCPP、HDR 画质或强制 SDR tone-map。
- 探测失败、后端未实现、软件故障、证据不足、模拟器限制和 CI 无法复现，都不能归类为硬件不支持。
- HDR 能力和实际激活状态必须分别记录；不能把配置值、`active=true` 或首帧单独当作完整 HDR 证据。
- 任何“控制条恢复但 HDR 输出退化”的方案都判定为失败。

### 范围

首轮聚焦 OHOS 实机，允许修改 PiliPlusX 和本地 media-kit 的 OHOS 交互边界代码。
共享 Flutter 交互代码的修改必须补充跨平台回归。保留当前工作树中已有的修改和未跟踪
证据文件，未经明确要求不提交、推送或发布。

## 2. 当前代码链路与未知点

当前已确认的 Flutter 侧链路：

```text
MouseInteractiveViewer.Listener
  → _onPointerDown
  → ImmediateTapGestureRecognizer.addPointer
  → gesture arena
  → _onTapUp
  → PlPlayerController.controls
  → showControls
  → 控制条动画
```

当前实现事实：

- `MouseInteractiveViewer` 已使用 `Listener(behavior: HitTestBehavior.opaque)`。
- 播放器手动注册 tap、双击、长按、垂直拖动和缩放 recognizer。
- `ImmediateTapGestureRecognizer` 在移动距离平方超过 `4.0` 时主动拒绝 tap，即超过 2 个逻辑像素。
- `_onTapUp` 可能进入弹幕处理分支，不一定立即切换控制条。
- `PlPlayerController.controls` 负责更新 `showControls` 和自动隐藏计时器。
- OHOS native video path 使用 PlatformView/XComponent，并包含 `IgnorePointer`、透明 PlatformView surface 和 ArkUI `HitTestMode.None`。
- 当前配置保留 OHOS native surface/HCPP，不能通过切换 Texture 作为交互修复。

仍需在实机证明：

- 故障 HAP 实际使用的 PiliPlusX、media-kit、Flutter/Dart 和 OHOS SDK 版本。
- 视频中心点击是否进入 Flutter 全局 pointer route。
- 事件是否到达现有 Listener、是否成功注册 tap、因何被取消。
- `_onTapUp` 是否执行，以及是否被弹幕、控制锁或其他状态分支消费。
- 控制条状态是否已变化但被计时器、动画或 native 合成层遮挡。
- OHOS PlatformView 原生承载、Flutter 命中树或合成层级中哪个边界造成区域差异。

“黑边可以点击、画面不能点击”只能作为定位线索，不能直接证明 XComponent 吞事件。
此前的手势阈值、ArkUI hit-test 和 SurfaceView/HCPP A/B 结果必须保留为证据，不能继续
在没有新断点证据时堆叠同类修改。

## 3. 阶段一：固定可复现的实机基线

### 3.1 核对构建输入

在任何代码修改前记录：

- PiliPlusX 当前提交、工作树差异和相关文件摘要。
- 实际解析的 media-kit 路径、提交和工作树差异。
- OHOS 构建使用的 Flutter/Dart、引擎和 SDK 版本。
- 本地源码与远端构建副本中相关文件的摘要。
- HAP versionCode、SHA-256、构建参数和签名 profile 类型。
- 实机安装版本、进程和当前前台页面。

所有 HDC 命令显式指定 `-t 2PM0223A18006914`；`127.0.0.1:5555` 仅用于模拟器辅助验证，
不能用于最终视频和 HDR 验收。

### 3.2 固定测试视频和页面状态

优先使用用户当前能复现的问题视频，记录：

- BV/CID 或本地文件标识、画质、编码和 HDR 格式。
- 播放位置、画面比例、竖屏/横屏/全屏状态。
- 控制条自动隐藏时长。
- 弹幕、字幕、控制锁和手势设置。
- 实际解码方式、native surface/HCPP 状态和 surface ID/generation。

先保留原始故障，再安装只增加诊断的构建；诊断构建必须复现同一问题。不得通过切换
SDR 输出建立所谓正常基线。

阶段产出：可复现操作、视频场景、故障 HAP/诊断 HAP 来源、输出路径和初始 HDR 证据。

## 4. 阶段二：定位输入链路的首个断点

### 4.1 诊断要求

增加显式开关控制的 debug-only 诊断。诊断不得修改事件返回值、手势竞争、计时器或播放行为。

按同一操作关联以下观测点：

| 层级 | 必须记录 |
| --- | --- |
| OHOS 原生 PlatformView/承载容器 | down/move/up/cancel、时间戳、坐标、命中对象和 bounds |
| Flutter pointer route | pointer、device、kind、buttons、时间戳、全局坐标 |
| `MouseInteractiveViewer` Listener | 收到的事件、局部坐标和播放器区域 |
| recognizer | addPointer 是否成功、移动距离、拒绝原因、arena accept/reject、cancel 原因 |
| `_onTapUp` | 是否执行、弹幕分支、控制锁、切换前后状态 |
| 控制条状态 | `showControls`、计时器、动画状态和控件是否实际可见 |
| 视频输出 | view ID、surface ID、generation、输出类型、HDR 配置和激活状态 |

Flutter pointer ID 与原生 pointer ID 不假设相同。通过时间戳、坐标、事件类型和事件序列关联；
无法关联时必须明确记录。原生 bounds、物理像素和 Flutter 逻辑像素注明单位及缩放比例。

全局监听器必须随宿主生命周期注册和移除，避免重建后重复监听。全局 route 只能观察，不能
直接触发显示控制条等业务操作。

### 4.2 实机对照操作

在同一 HAP、同一视频、同一布局和同一输出模式下测试：

1. 视频主体中心。
2. 主体画面靠近边缘但避开按钮的位置。
3. 视频上下黑边；没有黑边时记录不适用。
4. 控制条已经显示时的按钮和进度条。

每个位置分别使用 HDC 坐标点击和真实手指轻触。每轮等待控制条按既有配置隐藏后再测试。
唤出控制条和点击目标控件必须连续完成，随后立即采集状态，避免自动隐藏造成误判。

先在原始弹幕/字幕设置下复现；必要时分别关闭弹幕或字幕作为单变量对照，不得同时改变多个条件。

### 4.3 首个断点与下一步

| 首个缺失点 | 修改边界 |
| --- | --- |
| 原生入口有事件，Flutter 全局 route 无事件 | OHOS PlatformView/HCPP 原生命中与引擎转发 |
| Flutter 全局 route 有事件，播放器 Listener 无事件 | Flutter 命中树、PlatformView bounds、变换、裁剪或遮挡 |
| Listener 收到但 recognizer 未注册 | buttons、pointer kind、控制锁、active pointer 和生命周期 |
| recognizer 已注册但 tap 被取消 | 2px tap 拒绝、其他 recognizer 获胜、系统 cancel 或重建 |
| `_onTapUp` 执行但状态不切换 | 弹幕分支、控制锁、业务状态和控制器状态所有权 |
| `showControls` 已变化但控件不可见 | 动画、自动隐藏计时器、Flutter 绘制或 native 合成顺序 |

若事件轨迹无法解释区域差异，建立最小复现宿主：使用相同 OHOS Flutter 和 media-kit，
保留相同 native HDR 输出，只逐项加入 Flutter 手势、弹幕和页面嵌套结构。不得通过改成
Texture 简化实验。

阶段产出：至少一组成功与失败事件轨迹、首个断点、根因假设和可推翻该假设的实验结果。

## 5. 阶段三：架构复核与最小修复

诊断完成后启动新的 architect 实例，输入原始需求、HDR 硬约束、事件轨迹、失败尝试、
候选修复和当前判断，要求其独立确认修改层级。没有断点证据时不得直接选择 overlay、
原生转发补丁或阈值修改。

### 5.1 原生承载或事件转发问题

- 阅读实际打包版本的 OHOS PlatformView 承载实现，确认 XComponent 外层容器的命中行为。
- 优先复用现有引擎机制修复命中、坐标变换或转发契约。
- 保留 HCPP/native surface 合成和 HDR 配置。
- 保证 down/move/up/cancel 只转发一次，并在旋转、重建和销毁后清理陈旧目标。
- 禁止通过原生 click 回调旁路调用 Dart 显示控制条。
- 若必须修改 Flutter OHOS 引擎，先提交最小复现和架构复核结论，并在隔离 checkout 中固定引擎来源。

### 5.2 Flutter 命中边界问题

只有事件已进入 Flutter 且证据确认命中边界错误时，才建立独立 Flutter 交互层：

- 交互层位于视频输出之上、按钮/进度条/字幕/弹幕业务区域之下。
- 替换旧交互注册入口，保证一个 pointer 只注册一次。
- 复用现有 tap、双击、长按、垂直拖动和缩放 recognizer。
- 保留缩放前后坐标、字幕拖动、弹幕命中、亮度/音量和横向 seek 语义。
- 不新增平行的 `showControls` 状态，不直接绕过 `PlPlayerController.controls`。

### 5.3 手势识别问题

只有日志证明 tap 因识别策略丢失时才修改 recognizer：

- 区分轻触抖动、真实拖动、系统 cancel 和其他 recognizer 获胜。
- 优先使用 Flutter 的设备手势设置和标准 touch slop，禁止继续堆叠经验阈值。
- 修复 active pointer、arena 或 cancel 清理时，保持双击、长按、拖动取消、控制锁和弹幕语义。

### 5.4 状态或合成问题

- 在现有 `controls` 状态所有者中修复，不新增平行可见状态。
- 若弹幕或控制锁错误消费点击，修复对应业务分支。
- 若计时器提前隐藏，修正触发和取消关系，不以无限延长隐藏时长掩盖事件缺失。
- 若 native 层遮挡控制条，修复合成层级，同时确认 HDR 原生输出持续有效。

每轮只修改一个主要变量；任何修改都必须保留 HDR 路径和输出证据。

## 6. 验证计划

### 6.1 自动验证

根据实际修改运行：

- Dart analyze 和 `git diff --check`。
- 手势测试：轻触、轻微移动、超过 touch slop、cancel、第二 pointer、双击、长按和销毁清理。
- 交互层测试：按钮不触发背景点击、事件不重复注册、缩放坐标、字幕/弹幕命中。
- 状态测试：显示/隐藏、自动隐藏、控制锁和弹幕分支。
- OHOS 构建、media-kit 依赖检查和最小复现验证。
- 相关 HDR 决策、channel contract 和输出生命周期回归。

### 6.2 实机交互验收

竖屏和全屏分别验证：

- 视频中心、画面边缘和黑边各至少 20 次独立单击。
- 控制条隐藏时轻触一次显示，显示时轻触一次隐藏，不能重复切换。
- HDC 点击和真实手指点击。
- 播放/暂停、进度条 seek、双击、长按、横向 seek、双指缩放。
- 横屏亮度/音量滑动及竖屏禁用区域。
- 控制锁、菜单、字幕拖动和弹幕点击。
- 视频区域起手不误滚动下方列表。
- 至少 10 次页面退出并重新进入。
- 旋转、全屏、前后台恢复、播放结束后重播。

### 6.3 HDR 验收

修复前后使用同源、同设置和相近播放位置对照，确认：

- 片源和画质未降低。
- 实际仍走 native surface/HCPP，没有暗中切到 SDR 输出。
- 输出像素格式、色彩空间、HDR metadata 和真实显示证据匹配。
- surface ID/generation 在重建时正确更新，无陈旧绑定或重复资源。
- 控制条、seek、全屏、后台恢复后 HDR 输出仍有效。
- 视频可见，颜色和亮度没有新增退化。

`active=true`、配置开关、截图或首帧单独不足以证明 HDR 完成。已有 HDR 证据缺口必须
继续记录，不能通过关闭 HDR 消除。

## 7. 最终审核与交付

基本验证完成后启动新的 architect 实例，独立检查：

- 是否修复根因而非只改变现象。
- 输入所有权、坐标、取消和生命周期是否正确。
- 是否出现重复转发、重复注册或陈旧 surface。
- HDR 输出是否被改变、绕过或降级。
- 是否存在更简单可靠的修改层级。

最终文档记录：

- 根因和成功/失败事件轨迹。
- 修复层级和修改文件。
- 应用、media-kit、引擎和 HAP 来源。
- 交互验收结果和 HDR 输出证据。
- 已通过、失败和未执行项目。

只有实机视频主体点击正常、相关交互无回归、native surface 生命周期稳定且 HDR 路径未
退化，才能报告问题已修复。

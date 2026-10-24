# OHOS 实机控制条操作记录

适用设备：实体机 `2PM0223A18006914`。`127.0.0.1:5555` 是模拟器，不用于这条验收。

## HDR 约束

控制条交互问题的 A/B 不得关闭 OHOS native surface/HCPP、禁用 HDR 画质或强制
SDR tone-map。每次测试都要记录 HAP 版本、surface 类型、surface ID/generation、
HDR source/output 状态和控制条结果；交互恢复但 HDR 输出退化不算通过。

## 输入链路诊断

同一视频、同一屏幕方向下，分别点击视频中心、上下黑边，按 pointer ID 记录：

```text
Flutter pointer route
→ MouseInteractiveViewer Listener
→ _onPointerDown
→ tap recognizer / gesture arena
→ _onTapUp
→ showControls
```

竖屏手势专项也必须显式传入 `--vertical`。该参数会在 `windowed` 和 `fullscreen` 两种
phase 中传递给主 gate；否则已确认的竖屏源可能被按横屏期望检查：

```sh
VERIFY_REQUIRE_HDR=0 VERIFY_KEEP_SCREEN_ON=1 \
./tool/ohos/verify_player_vertical_gesture_real_device.sh \
  --source BV1Wp4y1P7KU --hap /path/to/candidate.hap \
  --vertical --region center --phase fullscreen \
  --out /tmp/piliplusx-ohos-vertical-gesture-center
```

`--hap` 会先安装并使用指定候选包；省略时沿用设备上当前已安装包。推荐列表边界脚本
同样支持该参数，两个脚本应指定同一份候选 HAP。

斜向 seek 容错专项使用三条脚本手势（明显水平、接近临界的斜向、明显竖向），由同一
fullscreen gate 采集 Flutter 的方向决策：

播放器触屏和 trackpad 两条路径都要先累计超过约 `18px` 的有效移动距离，再锁定方向；
`2px` 仅用于点击类手势的轻微抖动处理，不能作为 seek 方向准入阈值。方向锁定后，Cancel
或第二指接管只撤销 seek 预览，不提交最终位置。

```sh
VERIFY_REQUIRE_HDR=0 VERIFY_KEEP_SCREEN_ON=1 \
./tool/ohos/verify_player_seek_direction_real_device.sh \
  --source BV1Wp4y1P7KU --hap /path/to/candidate.hap \
  --out /tmp/piliplusx-ohos-seek-direction
```

竖屏播放器下方的上下滑动必须单独运行推荐列表边界脚本；它只验证列表锚点上移，不把
播放器内部手势或控制条结果混入列表结论：

```sh
VERIFY_KEEP_SCREEN_ON=1 \
./tool/ohos/verify_player_recommendation_scroll_real_device.sh \
  --source BV1Wp4y1P7KU --hap /path/to/candidate.hap \
  --out /tmp/piliplusx-ohos-recommendation-scroll
```

HDC 返回 `No Error` 只表示输入命令被接受；只有同时出现播放器 Listener、recognizer
方向决策和业务回调，才计播放器手势通过。播放器下方推荐区域必须作为独立列表边界探针，
不能替代播放器内部坐标测试。

若布局中出现 Feishu 等外部系统浮层（例如“会议中”），脚本会以
`foreground-system-overlay` fail-closed；应先由测试环境关闭该浮层，再重跑，不得把浮层遮挡
造成的搜索/触控失败归因于播放器。

手势脚本本身也 fail-closed：`--region center` 必须同时观察
`accept-single-pointer`、`pan-start` 和 `pan-update type=fullscreen`；`edge` 必须观察
`reject-portrait-edge`。缺少任一业务链时脚本返回非零，即使 HDC 返回 `No Error`。

首个缺失事件决定修改层级。已有 Listener 时，不要直接追加重复 Listener，也不要在
`onPointerUp` 绕过现有 recognizer 强制显示控制条；需要同时保留拖动、双击、长按、
弹幕和 HDR native surface 的合成边界。

## 操作原则

- 控制条会在很短时间内自动隐藏。
- 不要在“唤出控制条”和“点击目标控件”之间插入等待、截图传输或日志查询。
- 所有连续操作放进同一条 HDC 命令，必要时只在最后一步完成后等待并截图。
- 坐标以刚刚生成的当前方向截图为准；横竖屏、状态栏和视频区域变化后不能复用旧坐标。
- 如果需要确认控件边界，先唤出控制条，再立即 `dumpLayout`；dump 结束后控制条可能已经超时，不能把 dump 后的状态当作仍可点击。

## 标准 HDC 操作模板

```sh
HDC=/Users/wuweiwei1/bin/hdc

# 唤出控制条后立即点击目标控件；把坐标替换为当前截图中的坐标
$HDC -t 2PM0223A18006914 shell uitest uiInput click <视频区域X> <视频区域Y>
$HDC -t 2PM0223A18006914 shell uitest uiInput click <目标控件X> <目标控件Y>

# 目标操作完成后再等待和抓取状态
sleep 2
$HDC -t 2PM0223A18006914 shell hilog -x | tail -100
```

全屏按钮测试必须使用同一条连续命令，不能先点击视频、等待几秒后再点击全屏。验证真正全屏要同时检查：显示旋转、窗口宽高、详情页内容是否隐藏和视频是否占满全屏。详情页视频区域横向铺满不等于全屏播放。

脚本默认目标是实体机 `2PM0223A18006914`；对模拟器做 smoke 时必须显式设置
`HDC_TARGET=127.0.0.1:5555`。模拟器的安装、启动和布局结果不能替代实体机播放/HDR/灰屏验收。
上述验证脚本都会解析 `hdc list targets -v`，只有目标状态为 `Online` 或 `Connected` 才会继续；
目标离线时立即失败，不会继续点击或重复采集布局。

## 当前已确认的辅助命令

```sh
# 当前画面截图
$HDC -t 2PM0223A18006914 shell snapshot_display -f /data/local/tmp/current.jpeg
$HDC -t 2PM0223A18006914 file recv /data/local/tmp/current.jpeg /tmp/current.jpeg

# 控件树（只读诊断）
$HDC -t 2PM0223A18006914 shell uitest dumpLayout -p /data/local/tmp/layout.json
$HDC -t 2PM0223A18006914 file recv /data/local/tmp/layout.json /tmp/layout.json
```

不要用 `uiInput input_text` 或 `uiInput keyevent` 这类不存在的子命令；本环境支持的是 `click`、`doubleClick`、`longClick`、`inputText`、`text`、`keyEvent`。

## 强制脚本化 HDR 实机验证

后续涉及视频打开、搜索、截图或 HDR 日志采集的 UI 操作，必须使用：

```sh
cd /Users/wuweiwei1/src/PiliPlusX
VERIFY_LOG_SECONDS=25 \
VERIFY_FIRST_FRAME_WAIT=4 \
VERIFY_STABLE_WAIT=6 \
VERIFY_SEARCH_WAIT=3 \
./tool/ohos/verify_hdr_real_device.sh \
  --source BV1vY4y1N7TY \
  --out /tmp/piliplusx-ohos-verify-run
```

脚本会从当前 UI layout 解析搜索框、提交按钮、首个视频结果、视频区域和全屏按钮的
真实 bounds，依次执行启动、搜索、打开视频、必要授权、窗口态截图、唤出控制条、
立即点击全屏、全屏前后截图和 hilog 采集；不得在脚本外补发手动点击来代替其中任何
一步。启动后及打开视频后，脚本会检查当前 layout 是否包含“发现新版本”弹窗，
仅在确认存在该弹窗时语义点击“取消”（无“取消”时使用“不再提醒”），然后重新
抓取 layout；不会用固定坐标或盲点点击处理弹窗。产物目录包含 `01-home.json`、
`01-home-after-dialog.json`（若出现弹窗）、`02-search.json`、`02-filled.json`、
`03-results.json`、`04-after-open.json`、`05-windowed.jpeg`、
`06-controls.json`、`06-controls.jpeg`、`07-fullscreen-immediate.jpeg`、`08-fullscreen-stable.jpeg`
和 `hilog.txt`。如果 UI 文本或结构变化导致脚本找不到节点，应修改脚本并记录原因，
不能退回到截图坐标盲点。

脚本默认要求首帧前已经出现 `output=nativeHdr/surface=native-hdr`；如果账号、画质选择
或源流状态导致回落到 480P SDR，脚本会以无效 HDR 前置条件退出，不会继续执行全屏回归。
调试非 HDR 流时可显式设置 `VERIFY_REQUIRE_HDR=0`。

使用 `--cycles` 或 `--toggle-count` 做持续播放压力测试时，脚本默认先从当前 Slider
位置 seek 到 `0%`，再确认语义播放状态，避免从上次观看的末尾位置开始。可设置
`VERIFY_RESET_PLAYBACK_START=0` 关闭该行为。每个 HDC 调用默认有 60 秒单次超时，可用
`VERIFY_HDC_COMMAND_TIMEOUT` 调整；该默认值覆盖实体机 HAP 安装的常见耗时，超时轮次只记录为
观测失败，不计入全屏通过。切换瞬间的 RenderService Surface 缺失属于过渡态，只有
`*-fullscreen-stable` 快照强制要求颜色契约可用。

冻结帧只作为控制变量基线：它用于采集同一帧的布局、方向、surface/HCPP 和 HDR
decision 证据，不能暴露、排除或证明“播放中切换全屏后颜色变灰”。生命周期压力使用
独立脚本，先建立连续播放基线，再在持续拖动期间重启应用触发 surface 销毁/重建，最后
用连续播放重新进入一次全屏：

```sh
./tool/ohos/verify_surface_recreate_real_device.sh \
  --source BV1vY4y1N7TY \
  --hap /Users/wuweiwei1/Downloads/PiliPlusX-ohos-hcpp-input-cancel-fix-signed.hap \
  --out /tmp/piliplusx-surface-recreate
```

`lifecycle-relevant.log` 只用于检查 pointer 终止、surface 重建和 HDR 恢复链；它不是
冻结帧灰屏结论。灰屏回归仍必须使用连续播放的 `--cycles`/`--toggle-count`，并保留
播放状态或独立的视频主体帧进展证据。

竖屏视频全屏不应旋转到横屏。使用已由视频元数据确认的竖屏源时，必须显式传入
`--vertical`，脚本会先断言窗口态为 `portrait`，再对初次进入、退出和再次进入全屏
均断言 `portrait`。该选项不能根据标题或截图外观猜测：

```sh
VERIFY_REQUIRE_HDR=0 VERIFY_KEEP_SCREEN_ON=1 \
./tool/ohos/verify_hdr_real_device.sh \
  --source BV1Wp4y1P7KU --vertical --cycles 1 \
  --hap /path/to/new-signed.hap \
  --out /tmp/piliplusx-ohos-vertical-cycle1
```

产品侧全屏执行器对竖屏源将进入请求的方向归一为 portrait，并记录
`[FullscreenTrace] execute ... requested=... effective=...`；只有脚本布局方向和该日志
同时符合要求，才计入竖屏全屏通过。若安装阶段 HDC 长时间无输出，必须保留安装超时证据，
不能用旧 HAP 的运行结果替代新逻辑验收。`--vertical` 默认从竖屏视频主体中心唤醒控制条，
避免点击底部黑边；如源布局特殊，可显式设置 `VERIFY_WAKE_MODE=video-wake` 或
`VERIFY_WAKE_MODE=video-center`。

该生命周期脚本中的 `force-stop/start` 是冷启动控制变量：旧进程已被杀死，不要求它再发送
Flutter Cancel。若要验证 Cancel、旧 attachment 迟到事件隔离和新 attachment 重连，必须另行
设计进程保持存活的 hide/dispose/page-exit 测试；该冷启动步骤也不能用于复现或排除播放中切换
全屏的颜色变灰。

进程保持存活的 Back/page-exit 探针使用独立脚本执行：

```sh
./tool/ohos/verify_process_live_view_exit.sh \
  --out /tmp/piliplusx-process-live-exit
```

它要求应用当前已在播放器页，通过 HDC `uiInput keyEvent Back` 离开页面，记录前后 PID、能力
状态和 HCPP/Flutter 输入日志；它不负责建立播放状态，也不替代连续播放灰屏回归。
默认还会从当前视频区域开始一条 8 秒拖动，再注入两次 Back，以覆盖“有活动 pointer 时
dispose”的路径；可用 `VERIFY_PROCESS_LIVE_HOLD_SWIPE=0` 关闭拖动。只有在输出同时出现
播放器页退出、同一 view/epoch 的 owner Down、owner Cancel、Cancel NAPI request、
`action=dispose`、Dart PointerCancel 和稳定 PID 时，才可计为生命周期通过。

若要在 page-exit 后验证同一进程重入，可设置 `VERIFY_REUSE_CURRENT_APP=1` 再运行主验证脚本；
该模式不会执行 `force-stop/aa start`，会复用当前 PID，并从首页、搜索结果或视频页按语义布局
继续定位。搜索结果的“视频 0/没有数据/点击重试”会被记录并重试；它只用于重入探针，不能把
冷启动或 force-stop 后的 surface 证据当作同进程重建通过：

```sh
VERIFY_REUSE_CURRENT_APP=1 \
  ./tool/ohos/verify_hdr_real_device.sh \
  --source BV1vY4y1N7TY --cycles 1 \
  --out /tmp/piliplusx-ohos-same-process-reentry
```

若要测试进程保持存活的页面隐藏链，可使用系统 Ability 作为生命周期入口：

```sh
VERIFY_PROCESS_LIVE_LIFECYCLE=background \
  ./tool/ohos/verify_process_live_view_exit.sh \
  --out /tmp/piliplusx-process-live-background
```

该模式通过 `aa start` 暂时切到系统设置再返回应用，不依赖 uiInput 的并发排队；它只用于
验证 hide/Cancel 生命周期，仍不替代播放中连续全屏灰屏回归。

诊断 HAP 启用 app-side process-live 钩子时，使用构建脚本传入：

```sh
./tool/ohos/build_sign_hap_test.sh \
  --dart-define PILIPLUS_PROCESS_LIVE_TEST=true \
  --output /Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed.hap
```

安装并建立持续播放、全屏状态后，执行：

```sh
VERIFY_PROCESS_LIVE_EXTERNAL_HOOK=1 \
  ./tool/ohos/verify_process_live_view_exit.sh \
  --out /tmp/piliplusx-process-live-exit
```

实体机日志可能晚于手势返回，脚本会在退出后等待并重抓证据。日志较慢时可显式调整：

```sh
VERIFY_KEEP_SCREEN_ON=1 \
VERIFY_PROCESS_LIVE_EXTERNAL_HOOK=1 \
VERIFY_PROCESS_LIVE_LOG_FLUSH_WAIT=40 \
VERIFY_PROCESS_LIVE_EVIDENCE_RETRIES=12 \
VERIFY_PROCESS_LIVE_EVIDENCE_RETRY_WAIT=5 \
./tool/ohos/verify_process_live_view_exit.sh \
  --out /tmp/piliplusx-process-live-exit
```

这三个参数只影响证据采集的等待与重抓，不改变播放器生命周期行为；门禁仍要求稳定 PID、同一
view/epoch 的 `owner Down -> owner Cancel -> Cancel NAPI -> attachment dispose`，以及
app-side page-pop 和 Dart PointerCancel 的完整链路。

该模式由应用钩子触发正常返回，脚本只产生并保持 PointerDown，不再同时注入 Back。
只有日志同时出现 `process-live-test page-pop`，并且同一 view/epoch 存在严格的
`owner Down -> owner Cancel -> Cancel napi-request -> action=dispose` 顺序、恰好一次
owner Cancel 和 attachment 变化，才算生命周期证据通过；它不判断灰屏。OHOS embedding
的取消事件实际记录为 `stage=owner ... TouchType=Cancel`，不是字面量
`stage=cancel-request`。

脚本现在还会关联同一 activeOwner、PlatformView 和 attachment epoch：必须存在对应的
owner Down、page-pop、Cancel、dispose，以及至少一个 Flutter/Dart Cancel；独立日志数量不再
被视为通过。脚本在判断前会等待日志转发并抓取 post-flush `hilog -x` 快照。
`PILIPLUS_PROCESS_LIVE_TEST` 仅允许 debug HAP，生产 release 不会启用该钩子。

脚本还会在输出目录写入 `verdict.env`，分别记录 `application`、`attachment`、`playback` 和
`overall`。例如应用层通过但 HCPP attachment 未观测时为
`application=PASS`、`attachment=NOT_OBSERVED`、`overall=INCONCLUSIVE`，不能被上层当作完整
生命周期 PASS。

全屏操作特别按“视频底缘唤醒控制条 → dump/截图留证 → 再次 dump → 立即解析并点击全屏按钮”的
短时序执行，避免控制条动画期间使用旧 bounds。截图只作证据，点击必须使用点击前最新的
layout；全屏按钮通过 `text`、`description`、`contentDescription` 等
UI 属性匹配；如果图标没有可访问性文字，则从当前视频控制行 layout 中选择 Slider
下方、视频区域右下角的可点击节点（不能按页面顶部的“更多”按钮或固定的“右数第二个”
假设定位）；视频唤醒点也由当前 layout 中 Slider 顶缘推导，
不使用固定屏幕坐标。

`verify_hdr_real_device.sh` 已将这条时序固化：`06-controls.json` 和
`09-cycle-*-controls.json` 只用于截图/诊断；实际点击使用对应的
`*-controls-click.json`，并在点击前重新执行 `dumpLayout`。循环 transition 路径点击前不再
执行截图，避免控制条在截图期间超时隐藏；点击后的 immediate/stable 截图仍作为转场证据。
这不是放宽控制条门禁，而是避免控制条滑入动画导致语义树 bounds 与截图时刻不一致。

脚本要求目标控件来自点击前最新的 `dumpLayout`，且 `visible=true`、`enabled=true`。
不能单独用 `opacity` 作门禁：OHOS 有时会对实际可见的 Flutter 控制条错误报告
`opacity=0`；控制条超时问题必须通过“重新唤醒 + 重新 dump”处理，不能使用旧布局。

脚本只能通过 `power-shell wakeup` 保持亮屏，不能绕过实体机的系统锁屏。若布局检测到
`ScreenLockRootComponent` 或指纹解锁界面，会明确记录 `device-lock-screen-detected` 并停止；
需要先在实体机完成解锁，再重新运行脚本。

仅更换 HAP 时可使用：

```sh
./tool/ohos/verify_hdr_real_device.sh \
  --hap /Users/wuweiwei1/Downloads/PiliPlusX-ohos-xiaobai-2.1.3-signed.hap \
  --source BV1vY4y1N7TY
```

该脚本只负责可重复的 UI/证据采集；日志中的 `reapplied HDR after native surface attach`、
`reapplied HDR after surface resize` 或 `reapplied HDR after video params resize` 只能证明
producer contract 被重放，不能把 `result=0`、`active=true` 或普通截图当作 HDR 亮度证明。
最终仍需结合同一片源的实际可见高光、颜色和全屏切换结果判断。

要复现重复切换后的灰屏，必须在持续播放状态下使用 `--toggle-count` 或 `--cycles`：

```sh
./tool/ohos/verify_hdr_real_device.sh \
  --hap /Users/wuweiwei1/Downloads/PiliPlusX-ohos-xiaobai-2.1.3-signed.hap \
  --source BV1vY4y1N7TY \
  --toggle-count 3 \
  --out /tmp/piliplusx-ohos-verify-toggle
```

该选项从首次全屏稳定状态开始，按当前 layout 唤醒控制条并重复进出全屏；循环点击前只保存
最新语义 layout，避免截图消耗控制条可见窗口；每轮保存
`09-toggle-N-fullscreen-immediate.jpeg`、`09-toggle-N-fullscreen-stable.jpeg` 及对应 JSON。加上 `--freeze-frame` 可先暂停同一帧，
但这只用于同帧截图、几何和输入链控制基线，不能证明或排除播放中变灰。若 native
surface 的播放/暂停按钮不出现在无障碍 layout，可显式设置
`VERIFY_ALLOW_VISUAL_PLAYBACK=1`；脚本会改用排除控制条的中央视频帧差，并标记
`semantic state unavailable`。该模式不是语义播放状态的替代验收，默认仍 fail-closed；
整个过程仍由脚本执行，不得在控制条超时后人工补点。

正式持续播放门禁还默认拒绝 `playing→unknown`、`unknown＋位置变化＋帧变化` 等弱证据；仅在
需要诊断无障碍语义缺失时显式设置 `VERIFY_ALLOW_WEAK_PLAYBACK_EVIDENCE=1`，该运行只能作为
诊断记录，不能计入 DV 周期通过。

验证诊断 native HAP 时，设置 `VERIFY_REQUIRE_NATIVE_DIAGNOSTICS=1`：脚本会在安装前检查
HAP 内的 `libmpv.so` 是否包含 `OHOS color contract`、`OHOS color hint after set_color` 或
`OHOS target mapping` 标记；缺少标记会 fail-closed，避免把旧 native 包当成诊断包运行。

运行四源矩阵时，`verify_hdr_source_matrix_real_device.sh` 对 HDR Vivid 和 HLG 额外检查各自
`hilog.txt` 的实际格式标记，默认分别为 `source=hdrVivid` 与 `transfer=hlg`。标题、BVID 名称
或 `colorSpace=7` 均不能替代格式识别；若 media-kit 日志字段命名变化，只能显式设置
`VERIFY_EXPECTED_HDR_VIVID_REGEX` / `VERIFY_EXPECTED_HLG_REGEX`，并保留该源的 Hilog 作为证据。

在暂时没有可靠样片时，可显式跳过对应源：

```sh
tool/ohos/verify_hdr_source_matrix_real_device.sh \
  --hap /path/to/signed.hap --cycles 30 \
  --skip-hdr-vivid --skip-hlg
```

跳过会记录源和原因，并以退出码 `3` 表示“矩阵不完整”；它不会被报告为整体通过。

要验证同一进程的 page-exit 后重入，使用专用编排脚本，避免旧 gate 与 page-pop 同时注入
控件操作：

```sh
VERIFY_KEEP_SCREEN_ON=1 \
./tool/ohos/verify_surface_page_exit_reentry_real_device.sh \
  --source BV15z4y1Z734 \
  --out /tmp/piliplusx-ohos-surface-page-exit-reentry
```

脚本会在播放中的全屏稳定屏障暂停，触发活动 pointer 的 process-live page-pop/dispose，
再以 `VERIFY_REUSE_CURRENT_APP=1` 重进同一源。page-exit、surface 生命周期和 re-entry
分别记录，任一环节缺证据都不能报告为完整通过。
## 播放器与推荐列表手势边界

页面使用 `ExtendedNestedScrollView` 时，播放器区域内的指针由播放器拥有，播放器区域外的竖向拖动才由推荐列表拥有。构建准备脚本会在 Flutter SDK 中注入 `pointerDownFilter`，并在 `pub get` 后对 `extended_nested_scroll_view` 应用对应参数补丁；不要通过扩大透明 overlay 或手工点击改变边界。

本地 Flutter/OHOS 代码变更后，先运行：

```bash
flutter test test/plugin/pl_player/player_view_hit_test.dart test/common/widgets/gesture/player_gesture_recognizer_test.dart
```

OHOS 实机 HAP 构建使用 `tool/ohos/build_sign_hap_test.sh`；安装成功后再运行本文件后续的竖屏手势脚本。HDC 离线、构建成功或 `uiInput` 返回 `No Error` 均不能替代播放器接管链和推荐列表实际滚动证据。

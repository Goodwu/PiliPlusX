# TASKS.md

## Now（当前推进，最多 3 条）

- [ ] 修复 macOS `BV1vY4y1N7TY` Dolby Vision 亮度不足
  - status: in_progress
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 正式 macOS 产物使用可追溯的 modern libmpv（mpv 0.41+、libplacebo/Vulkan）并完成同一 DV 输入、同一时间点的 HDR/SDR 对照；日志确认 `dolbyvision/pq` 识别、`target-peak=400`、`tone-mapping=bt.2390`、原生 EDR 可见帧和高光观感达到参考播放器。当前原正式包仍为 mpv 0.36/libplacebo disabled；本地 modern arm64 预览已验证可行，但尚未形成正式 universal 依赖。
  - latest: 已通过 `gh run download` 获取 `Goodwu/libmpv-darwin-build` 分支 `experiment/mpv-041-b3-opengl` commit `bc52bbaedf02fcf11d8042ce1e7799815a2e8405` 的成功 Actions artifact（run `34097910903`），并新增 `scripts/build_macos_goodwu_hdr.sh`、`scripts/package_macos_goodwu_mpv_hdr.sh` 固化构建。最终包 `build/macos/Build/Products/Debug/PiliPlusX-goodwu-hdr-final.app` 的 `Mpv.framework` 已确认 universal mpv 0.41.0，进程实际加载分支 libmpv、libplacebo、Vulkan、shaderc 和 FFmpeg，且同一 BVID 可播放；旧正式包与最终包均已定位到约 50% 播放位置完成画面对照，最终包高光明显恢复；已通过无 `/opt/homebrew` 绝对依赖、`codesign --verify --deep --strict`、45 项 HDR 测试和 Dart analyze。旧正式 `PiliPlusX.app` 仍嵌入 mpv 0.36.0；需要将 Goodwu artifact 依赖正式纳入发布流水线并补齐播放器日志中的 Dolby Vision/target-peak/tone-mapping 证据，任务保持 in_progress。
  - latest: architect 三轮独立审核均为 FAIL。已修复线性 RGBA16F 层的 PQ metadata 错配实验、reset 旧配置回灌、窗口屏幕 headroom、Metal command 完成状态、videoParams 决策绕过、Dart reset 事务版本和 verifier 正则；修复后源码 `flutter build macos --debug --no-pub`、45 项 HDR 测试、analyze、diff check 均通过，`PiliPlusX-goodwu-hdr-final3.app` 可打包并实际播放目标 BVID，画面不再出现已报告的立即发白现象。仍未达成：active 必须绑定成功首帧、Darwin active false 双向同步及 display refresh 顺序、完整 GL→Metal fence/lease、arm64/x86_64 modern 依赖能力一致性、同源同 PTS 光度验收；按用户要求，未将任务标记 done。
  - latest: final4 运行采样仍持续为 `bgra8Unorm`，未据此宣称 HDR 已打通；按 architect 建议将 OpenGL→Metal 生产者栅栏改为 `glFinish()`，补充 native gate 诊断字段，并修正 macOS Dolby Vision 在 display reset 后直接 return、导致 native 配置未重新下发的问题。45 项 HDR 测试、analyze、diff check、macOS debug build 通过，`PiliPlusX-goodwu-hdr-final7.app` 已重新打包；architect 复审进行中，任务保持 in_progress。
  - latest: architect 已对 reset/重叠 reset/失败重试/旧 Ready/epoch 门禁代码审查 PASS；最终源码再次通过 45 项 HDR 测试、Dart analyze、两仓库 diff check 和 `flutter build macos --debug --no-pub`，并生成 `PiliPlusX-goodwu-hdr-final8.app`（Goodwu universal mpv 0.41.0、无 `/opt/homebrew` 绝对依赖）。但产品验收仍保持 in_progress：尚未取得同一候选持续 `rgba16Float → successful frame → active=true`、reset/切屏恢复和同源同时间亮度对照证据，不能宣称整条 HDR 链路已完成。
  - latest: 在 reset 失败/重叠窗口增加共享 Future 和 reset-in-flight 门禁；architect 对最终 reset/旧 Ready 代码门禁再次 PASS。最新 `PiliPlusX-goodwu-hdr-final9.app` 已重新构建打包，Goodwu universal mpv 0.41.0 且无 `/opt/homebrew` 绝对依赖。端到端亮度验收仍未闭合：历史实测曾持续观察到 `bgra8Unorm`，当前缺少 final9 同进程持续 `rgba16Float`、active=true 和同源同时间亮度对照证据，任务保持 in_progress。
  - latest: final10 已纳入 DV 初始 hint 不伪造 PQ 的修复；46 项 HDR 测试、Dart analyze、`flutter build macos --debug --no-pub`、Goodwu universal mpv 0.41.0 打包及绝对依赖检查通过。无 HDR 显示器时仅确认到 native `rgba16Float`/EDR 候选链路，未宣称实际亮度达到 HDR；连接 HDR 显示器后仍需同源同 PTS 做高光/中灰亮度接受度对照，并完成 architect 最终复审。

- [ ] 补齐 controller source/output 完整时序覆盖
  - status: in_progress
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 以可控依赖覆盖 source 切换、复用 Player open、codec probe、output rebuild、非末引用释放和最终 dispose 的真实调用链；证明无旧源回写、永久 in-flight、失效输出发布或共享监听丢失。2026-09-17 已新增 opaque-handle lifecycle orchestrator，生产 `Player.open`/listener rebind 已接入同一 open gate；44 项 HDR 定向测试覆盖 probe/output 迟到释放、重叠 open 与 final-dispose 顺序。初始 `_initPlayer`、rebuild 和 controller 最终释放尚未完整改由该编排器执行，任务继续进行。

- [ ] 构建唯一最终候选并完成 OHOS 实体机矩阵
  - status: in_progress
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 最终候选绑定源码、依赖、补丁、HAP 摘要和脚本版本；横屏及竖屏视频各 3 个完整周期、控制条/手势/seek 边界、surface 重建、同进程重入、DV/PQ/SDR 和同源颜色对照分别有实机证据；DV 长周期完成 30 个连续周期。设备重连后推荐列表专项已通过；DV surface 脚本的连续播放基线通过，但冷重启后未重新打开视频，故只记录冷启动控制，不计 surface 恢复通过。P13 已完成横屏 DV 三轮矩阵，P14 已完成同一进程页面退出与目标播放重入；仍缺最终候选上的竖屏 SDR/PQ、surface 重建、HLG/HDR Vivid 与同源颜色对照。
  - latest: Architect review 后已将 Flutter OHOS engine embedding 的生产差异整理为 `tool/ohos/flutter_embedding/ohos_hcpp_embedding.patch`，native NAPI 与 embedding tests 分别独立为 opt-in patch；`build_sign_hap_test.sh` 的 engine inline substitutions 已迁移到 `scripts/prepare_ohos_embedding.py`。三个 patch 对当前 `dev:/home/wuweiwei1/tools/flutter-ohos` dirty checkout reverse-check 通过，并在固定 `aa76d9bbeee7806a87dbd202d2550dfd11550b82` 临时 clean worktree 中全部 clean-apply 通过（生产 4、native 1、test 1 个路径）。随后将 `build_sign_hap_test.sh` 的 debug-only HCPP marker gate 与 release 路径分开，避免 release HAP 因 debug 诊断字符串缺失而误失败；CI HAR 消费和 native `libflutter.so` 来源契约仍未验证，因此不宣称供应链闭环。

## Next（近期候选）

- [ ] P13 竖屏 SDR/Texture 三轮矩阵（中断后重跑）
  - status: todo
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 以 P13 HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-final-candidate-20260918-p13-signed.hap`（SHA-256 `8b2dca2ebdccfe26174ffba75eeb7ab6c51926a55faeb406735493647738831c`）在 `BV1sA4y1D7ZA` 执行 `--vertical --cycles 3`；必须取得绑定 PID/view/epoch 的 initial enter 与 cycle-1/2/3 exit/re-enter 共七份 action record PASS、三轮 portrait、播放帧推进和 final drain。2026-09-18 已启动但被用户中断；仅生成 `01-home.json`、`02-search.json` 和 Hilog，尚未打开视频或进入动作阶段，不形成通过或失败结论。

- [ ] 在获得可靠样片时验证 HLG/HDR Vivid
  - status: todo
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 先确认实际源格式，再进行独立实体机验收；没有可靠样片时维持待办

## Blocked（等待输入或外部条件）

- 当前无同进程退出重入阻塞项。

## Recently Done（最近完成）

- [x] Codex Agent Team Luna fallback 运行时门禁
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 历史任务，已于 2026-09-19 被通用 root spawn policy 取代。`AGENTS.local.md` 要求原生角色创建与持久化 `turn_context` 核验；失败时停止工作包，不再启动 Codex adapter launcher。2026-09-18 的 direct preflight 仅保留为历史运行时材料，不代替新主会话对原生 Mechanical Worker 的验证，也不降低当前实体机验收要求。

- [x] P13 最终候选横屏 DV 三轮矩阵
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: P13 HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-final-candidate-20260918-p13-signed.hap`（SHA-256 `8b2dca2ebdccfe26174ffba75eeb7ab6c51926a55faeb406735493647738831c`）未启用 process-live hook。artifact `/tmp/piliplusx-ohos-dv-p13-cycles3-20260918` 的 PID `8923`、view `0`、epoch `1`：initial enter 与 cycle-1/2/3 exit/re-enter 共七份 action record 全为 PASS；每次方向 portrait -> landscape -> portrait -> landscape、播放帧推进与 150 秒 root-Hilog final drain 均通过。HDR decision evidence PASS；颜色仍为 INCONCLUSIVE。

- [x] P14 同进程页面退出与播放重入
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: artifact `/tmp/piliplusx-ohos-page-exit-reentry-bv1vy4y1n7ty-p14-20260918` 在 PID `64534` 完成全屏就绪后的 page-pop；`page-exit/verdict.env` 为 application/attachment/overall PASS，日志按序含 page-pop、Cancel request 和 attachment dispose。重入阶段以同一 PID 打开 `BV1vY4y1N7TY`，`reentry/verdict.env` 为 application/playback/overall PASS，前后 PID 均为 `64534`，并有 `reentry-playback-progress` 的播放状态及视频帧变化证据。

- [x] P12 同进程页面退出生命周期链
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: versionCode `2026091802` 的 P12 HAP artifact `/tmp/piliplusx-ohos-page-exit-reentry-bv1vy4y1n7ty-p12-20260918/page-exit` 记录同 PID `55077` 的 page-pop、Dart PointerCancel、route cancel、同 view/epoch 的 HCPP owner Down -> Cancel -> NAPI -> attachment dispose；`verdict.env` 为 `application=PASS`、`attachment=PASS`、`overall=PASS`。

- [x] P9 推荐列表纵滑边界
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 设备恢复 `USB Connected` 后在 `BV1sA4y1D7ZA` 详情页执行 artifact `/tmp/piliplusx-ohos-recommendation-scroll-bv1sa4y1d7za-p9-20260917-reconnect`；windowed portrait baseline 下播放器区保持布局，推荐列表文本锚点由 2069 变为 1891，专项 verdict PASS。

- [x] P9 竖屏全屏边缘纵滑拒绝
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: artifact `/tmp/piliplusx-ohos-vertical-gesture-edge-bv1sa4y1d7za-p9-20260917` 对左右边缘分别注入纵滑；均记录 `gesture move-filter action=reject-portrait-edge` 与 recognizer reject，专项 verdict PASS

- [x] P9 竖屏全屏中央纵滑接管
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: artifact `/tmp/piliplusx-ohos-vertical-gesture-center-bv1sa4y1d7za-p9-20260917` 的两个中心纵滑均有同 PID/view 的 `accept-single-pointer action=fullScreen`、`pan-start` 与 `pan-update type=fullscreen`；专项 verdict PASS。此项只证明播放器接管中央纵滑，不推断亮度或音量实际改变

- [x] P9 竖屏全屏 seek 方向边界
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: artifact `/tmp/piliplusx-ohos-seek-direction-bv1sa4y1d7za-p9-20260917` 在同一稳定竖屏全屏页记录三次受限输入；方向判定依次为 `horizontal`、`reject-portrait-edge`、`fullscreen`。清晰横滑唯一进入 seek，斜滑与竖滑均未进入 seek；专项 verdict PASS，主 gate 的 Texture/SDR 与帧推进也通过，颜色独立为 INCONCLUSIVE

- [x] P9 竖屏 SDR/Texture 三轮实体机矩阵
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 先在 `BV1sA4y1D7ZA` 的实际详情页确认 BVID、720×1280、`source=sdr, output=sdr, surface=texture` 与持续播放，再执行 artifact `/tmp/piliplusx-ohos-vertical-sdr-bv1sa4y1d7za-p9-cycles3-fresh-20260917`。PID `62938`、view `0` 的 initial enter 和 cycle-1/2/3 exit/re-enter 共七份 Flutter 通道 action record 均 PASS；每次保持 portrait 和播放帧推进，三个 cycle complete 与 150 秒 root-Hilog final drain 完成。颜色结论仍为 INCONCLUSIVE

- [x] P9 严格单轮播放中全屏回归
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: `2PM0223A18006914` 的同一 P9 进程完成 initial enter、cycle exit、cycle re-enter；三个 action record 均绑定 PID/viewId/epoch 且严格四标记 PASS，方向、持续出帧和 native HDR decision 同时通过；颜色结论保留 INCONCLUSIVE

- [x] P9 横屏三轮的 fail-closed 中间证据
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 新进程 initial enter、cycle-1、cycle-2 共五个 action record PASS；cycle-3 exit 在 360 秒内缺严格四标记而为 INCONCLUSIVE，保留 150 秒 failure drain/snapshot，未追加输入

- [x] 定位并修正 P9 cycle-3 exit 的 opacity-zero 误点击
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 原始输入在同 PID/view/epoch 的 HCPP seq 83/84 与 Flutter global Down/Up 均到达，却未命中 fullscreen-button；后续 `owner-1-5-exit` 是前一轮排队请求。`verify_player_button_input_trial_real_device.sh` 现拒绝直接点击仅由 fresh/opacity-zero 解析出的节点，先 wake、重抓再进行唯一 raw action；P9 原始布局离线反例通过

- [x] 第一轮验证器门禁和 controller 生命周期修复
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: 当前布局/PID/attachment/同试次事件序列门禁成立；native-output token、旧 source open、非末引用释放、codec probe 和 output publication 已有首轮修复及定向回归

- [x] 拒绝发布 `_initPlayer` 异步创建期间已过期的 output 候选
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: `VideoController.create` 改为局部候选；source generation、Player count 或 dispose 状态失效时释放候选且不注册监听、不写共享 `_videoController`。`dart analyze lib/plugin/pl_player/controller.dart lib/plugin/pl_player/models/hdr.dart` 与 47 项 HDR/touch-trace 定向测试通过

- [x] 为全屏验证器补离线反例和可单测标记边界
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: `verify_player_button_markers.py` 从试次脚本提取同 PID/view/epoch、顺序、HCPP 配对和消费 offset 判定。4 个离线反例覆盖 opacity-zero 旧布局、错误 PID/view/epoch、乱序、旧 offset 与已消费迟到标记；`python3 test/ohos_player_button_verifier_test.py`、`bash -n` 和 `py_compile` 通过

- [x] 修正后 P9 横屏单周期实体机回归
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: artifact `/tmp/piliplusx-ohos-fullscreen-p9-post-verifier-fix-20260917` 的 initial-enter、cycle-1 exit、cycle-1 re-enter 均 PASS，全部绑定 PID `41102`、viewId `0`、epoch `1`；exit 先 wake/regrab，方向 portrait -> landscape -> portrait -> landscape，连续 root-Hilog final drain 完成，P9 native HDR decision 与持续出帧均通过，颜色仍 INCONCLUSIVE

- [x] 修正后 P9 横屏三轮实体机回归
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: artifact `/tmp/piliplusx-ohos-fullscreen-p9-post-verifier-fix-cycles3-20260917` 的 initial-enter 与 cycle-1/2/3 exit/re-enter 七份 action record 全为 PASS，均绑定 PID `44607`、viewId `0`、epoch `1` 与独立 consumption offset；每次方向 portrait -> landscape -> portrait -> landscape，连续出帧、native HDR decision 和 150 秒 root-Hilog final drain 均通过，颜色仍 INCONCLUSIVE

- [x] 按渲染拓扑修正竖屏 SDR 输入验证器
  - status: done
  - context: archives/conversations/player-architecture-remediation.md
  - acceptance: `verify_hdr_real_device.sh` 仅在日志明确判定 nativeHdr/native-hdr 时使用 HCPP attachment；明确 SDR/Texture 时以同 PID/view 的 Flutter 四标记绑定输入，并在 action record 写明 `input_channel`、不伪造 HCPP 序号。修正 Texture 空字段导致 ledger 丢失 end offset 的编码后，离线 5 项验证、47 项播放器回归和 target analyze 通过；artifact `/tmp/piliplusx-ohos-vertical-sdr-p9-cycles3-channel-ledger-fix-20260917` 的 initial enter、cycle-1 exit/re-enter 均 PASS，保持 portrait 和持续出帧

## 规则

- 新任务必须写入本文件；完成任务必须打勾。
- 每个活跃任务必须有唯一 context、可验证 acceptance 和明确状态：todo / in_progress / blocked / done。
- 同一总目标和其重复子项不得同时作为活跃进度；因候选版本或验收口径变化重新打开的任务必须写明失效原因。
- 每次实质推进更新本文件和当前 conversation；历史完成项超出上限后压缩进对应 conversation。

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

## 当前交付边界与验收规则

- 当前唯一交付主线是 OHOS 实体机播放器验收闭环：控制条和手势、全屏、持续播放、HDR 颜色亮度及 source/output 生命周期。macOS 仅做共享代码变更涉及的回归；不启动新的 macOS 渲染路线、上游重建或无关格式工作。
- 保留现有原生 HDR 路线。不得以 Texture SDR 回退、屏蔽功能、降低验收条件或删除诊断解决 HDR 路径上的交互问题。变更技术路线前，记录直接阻断证据、替代路线的最小可行性实验和受影响回归范围；影响交付范围的决定交由用户。
- 同时只推进一个实体机关键阻断项；可并行处理不改变当前候选包的独立测试或证据提取。实验开始前记录假设、基线、唯一主要变量、预期区分结果和停止条件；同类实验连续两轮未缩小范围时重新诊断。
- 设备、权限、依赖或环境缺失时，完成独立工作后标记 blocked 并停止相关验收；明确区分产品失败、测试基础设施失败、环境阻塞、证据不足和通过。验证器故障先修验证器；不得以重复探测、静态检查、构建通过、HAP 安装、单次动作或跨试次拼接日志代替实体机验收。
- 每个候选 HAP 必须绑定源码、依赖、补丁版本、包摘要、设备、脚本版本和关键参数；保留最近可复现通过基线。只有相关实现、依赖、环境或验收标准改变时才重新打开既有通过项，并注明失效原因。
- 实体机操作只通过 HDC 脚本；同一设备同一时段只能有一个输入执行者。动作前校验目标应用、PID、attachment、逻辑全屏状态和新鲜布局；控制条隐藏时最多一次安全唤醒后重抓布局。前置不成立立即 fail-closed，不追加点击。
- 每个输入试次必须绑定唯一 ID、坐标、时间范围、PID/view/epoch 和独立消费的日志标记。不得跨试次拼接 pointer、callback 和 request，也不得让迟到日志改写已结束试次的 verdict。四标记只证明请求链路；完整全屏验收还须证明事务提交、正确方向和持续出帧。
- 验证器须覆盖旧布局、错误 PID、过期 attachment、重复/乱序/缺失/迟到日志的离线反例；诊断日志默认关闭且有界。不得仅扩大超时，先定位事件生成、输出、传输或解析的首个缺口。
- 手势以累计约 18px 确认方向，只有 `|dx| > 3 × |dy|` 的明显横向手势进入 seek；分别验证播放器内手势、倾斜容错、Cancel/多指和播放器外推荐列表滚动。无直接反例不得继续调整阈值、层序、代理按钮、合成 PointerUp 或 down 直接全屏。
- 全屏状态仅在平台事务成功后提交；竖屏视频全屏不强制旋转。取消、销毁和失败不得伪造成功或永久阻塞后续请求。所有异步 Player/source/output 完成后的发布都校验 source、Player、输出事务和存活状态；失效结果不发布但须释放资源及 in-flight 标记。非末引用释放不得取消共享监听；最终释放必须等待真实释放；controller 测试覆盖真实调用链的 open、probe、rebuild 和 dispose 时序。
- 应用只决定 HDR 策略，media-kit 管理输出配置，OHOS VO 管理动态 NativeWindow 色彩契约；不得多层重复写动态输出属性。颜色验收必须使用同设备、同源、同一暂停帧或可复现片段；日志色彩契约或不同播放时刻截图不能单独证明显示正确。HLG/HDR Vivid 没有可靠样片时保持待办，不阻塞已定义的 DV、PQ、SDR 验收。

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

## 规则

- 新任务必须写入本文件；完成任务必须打勾。
- 每个活跃任务必须有唯一 context、可验证 acceptance 和明确状态：todo / in_progress / blocked / done。
- 同一总目标和其重复子项不得同时作为活跃进度；因候选版本或验收口径变化重新打开的任务必须写明失效原因。
- 每次实质推进更新本文件和当前 conversation；已完成工作及其证据只保留在对应 conversation，不在本文件复述。

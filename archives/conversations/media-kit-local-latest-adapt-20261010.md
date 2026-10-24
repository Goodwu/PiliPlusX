# 本地 media-kit 最新版适配与双机基础功能回归（2026-10-10）

## Current State

- **回归结论：通过（双机基础功能全绿）**。PiliPlusX（分支 `fix/darwin-video-output-rebuild-barrier`）经 `pubspec_overrides.yaml` 全量 path 指向本地 `~/src/media-kit` main `53ede203`（领先 S12 钉定 `23e58ec4` 共 82 提交）完成适配：公开 API 零编译破坏（Scout 全符号核对），app 侧两处适配提交后，156 项测试 PASS、analyze 仅 85 条存量 info。arm64 release APK（SHA-256 `46adc41bcd5ed92741e37025a9af92787f819589e2d976243097e4b4d12e9290`，27.2MB）在 LYA-AL00 与 marble 基础功能全绿，ANR 零新增、零 FATAL。
- **app 侧适配改动（本提交）**：
  1. `lib/plugin/pl_player/hdr_output.dart` `isHdrPresentable` 增认 `HdrPresentation.nativeDolbyVision`：库侧 DV 成熟度提升（d2fdbc65/a0d8c4a3）后 nativeDV 成为默认呈现之一，旧判断只认 `nativeHdr` 会使 DV 档在选 DV 直通的设备上系统性回落 SDR；另将 P5 探测注释刷新为引擎 attach 原生探针一次性探测（`HdrCapabilities.query` 的 `player` 参数仅兼容保留）。
  2. `lib/plugin/pl_player/widgets/mpv_convert_webp.dart` `dispose` 改 async 并 await `Initializer.dispose`：该 API 自 wakeup drain 化起为异步屏障，旧代码未 await 即 `mpv_terminate_destroy`，与未排空事件回调竞争同一 ctx；`_onEvent` 内的 fire-and-forget 调用因此把 terminate 移出回调轮次，更安全。
- **未动项**：`pubspec.yaml` 的 git 钉定 refs（`23e58ec4`/`0fa6afe9`）保持不变——按用户"测试版从最新源码构建、钉定只属发布链"的裁决，发布链钉定更新待发布轮处理。
- **边界（未验收项）**：marble 未登录，DASH 无 DV 档，app 内 DV 链路在 marble 不可达（账号凭据门禁，非适配缺陷；库侧 marble nativeDV 直通已由 media-kit 回归轮独立验证）；HDR 屏幕观感（色彩/亮度）按惯例本轮不验收；`tool/player_test/` 框架仍未建立，本轮为 ADB 直接驱动。

## 适配核对要点（Scout 报告结论，已逐项落地核实）

- 破坏性变化：零。库内唯一公开成员删除为 `HdrCapabilities` 测试缝（app/测试零引用）；签名只放宽（`query` player 改可空）；barrel export 只增（`native_wakeup_callback`/`darwin_wakeup_callback_owner`）；无新传递依赖。
- 行为变化（不阻塞）：HDR10 默认路由增 convert/reshape（app 文案 switch 已全覆盖）；GPU HDR PlatformView 默认 `rgba1010102`；`NativePlayer.dispose` 新增重入门（app 端口路径不触发）；`HdrVideo` 包 `AndroidOutputPresentationHost`（widget 参数未变）。
- 依赖代际：build.gradle 换 arm64 JAR 为本地 DV-experiment 源码构建（`libmpv-android-video-build-dv-experiment` 路径实证），`libmedia_kit_video_hdr_bridge.so`、`libmedia_kit_dataspace_vendor.so` 均在包内。

## 实机证据（/tmp/piliplusx-android-verify-20261010/）

- **LYA-AL00（3EP7N18C28016072，Android 10，lya/）**：冷启动 COLD 608ms；SDR `BV1T7t96BECu` 深链起播帧推进 11.99（视频区 y136-946 像素差，下同）；暂停后帧冻结、恢复后 50.88；seek 69%→77%、seek 后 25.67；back 退出 + 深链重入 71.88；DV `BV1vY4y1N7TY`：`HDR predict quality=126 playable=true presentable=true`，会话 `dvProfile=8 compatId=4 baseLayerDirect nativeHdr verified`（P8.4 HLG 直出，quality=126 hevc 实播）帧推进 71.77；ANR 计数 2→2、FATAL 0；13 份截图/布局证据 + 全程 logcat。
- **marble（dede0cd2，23049RAD8C，HyperOS V816/Android 15，marble/）**：全新安装经 media-kit 回归同款"继续安装"自动化（KEYCODE_MENU + uiautomator 轮询点按，直接 `install -r` 报 `INSTALL_FAILED_USER_RESTRICTED` 静默拒绝）；冷启动 COLD 743ms（未登录直进首页）；SDR `BV1T7t96BECu` 起播 6.56（quality=32 h264 sdrDirect 符合未登录档位）；暂停帧冻结 0.00、seek 58%→75%、恢复 28.30、重入 17.90；ANR 2→2、FATAL 0。控制条 dump 存在竞态（唤醒后 0.6s dump 偶发早于控制条挂树），重试窗内全部闭合。
- 工具链备注：venv Pillow 像素差判定（`/tmp/piliplusx-android-verify-20261010/venv`）；构建曾因磁盘满（gradle daemon 中断）失败一次，清理 `~/.gradle/caches/8.14`（6.2GB，再生缓存）后重建成功。

## 过程要点

1. Scout（Explore）对 82 提交做 app 使用面全符号兼容核对，产出 B/C/D 三段结论；本文件"适配核对要点"为其收口。
2. LYA 控制条批次按 AGENTS.local.md 连续脚本约束执行（唤醒→重抓布局→定位→点击→复核单命令完成）；marble 首轮唤醒 dump 竞态未命中后，以精确节点边界重试闭合。
3. 两机测试后均熄屏；marble 装 PiliPlusX 后其 media-kit hdr_lab 测试 app（r30g）未动。

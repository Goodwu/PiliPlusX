# OHOS HDR 实机调试基线

更新日期：2026-09-06

这份文档是 OHOS HDR 实机调试的唯一持久基线。后续测试、日志判断和质量选择都以这里的事实为准。

## 设备与显示能力

- 实体机 HDC 目标：`2PM0223A18006914`。
- `127.0.0.1:5555` 仅是模拟器，不能作为实体机播放验收目标。
- 真机显示能力探测返回 `hdrFormats=[1,2,3]`，因此手机支持 HDR。
- `hdrDisplaySupportsHdr=false` 只有在完成本次 `probe` 后才有意义；旧包或尚未探测时的默认值不能用来判断手机不支持 HDR。

## 已确认的播放事实

- 公开测试素材：`BV16J4m1H7Nm`，标题为 `Profile8.4_MP4_HEVC_Main10`。
- Texture + tone-map 在实体机能够正常显示 Dolby Vision 画面。
- 版本 0614、0615、0616 在启用 OHOS XComponent/native Surface candidate 后也能显示 DV tone-map 画面。
- 曾经截图中的黑色区域是测试素材的黑色测试帧，不能据此判定黑屏或 DV 解码失败。
- EGL、BufferQueue、HCODEC 日志必须和首帧时间及 Surface 生命周期对齐后再归因；单独出现这些日志不能证明 DV 解码失败。

## 统一画质选择规则

显示能力探测和画质门控在所有平台统一执行，和是否 OHOS 无关：

1. 在 URL 和画质选择前先调用 `HdrPlatform.probe`。
2. 显示设备确认支持 HDR 时，Dolby Vision（126）、HDR10（125）、HDR Vivid（129）全部保持可选。
3. 显示设备明确不支持 HDR 时，上述三种 HDR 统一置灰，并回退到 SDR 画质。
4. 不能因为 native HDR 尚未证明，就只把 DV 或 HDR Vivid 单独降级；也不能在 `probe` 之前依据默认的 `false` 做降级。
5. 两个画质菜单都必须包含 HDR Vivid 的同一门控条件。

这里的显示 HDR 能力门控和 native HDR passthrough 是两个独立问题：前者决定 HDR 画质是否可选，后者决定是否可以绕过 tone-map 直接输出原生 HDR。

## 当前验证记录

- 0616 arm64 HAP 已构建、签名、校验，并安装启动到实体机。
- `flutter test --no-pub test/plugin/pl_player/hdr_test.dart`：25 项通过。
- `python3 scripts/verify_hdr_channel.py`：7 个端点通过。
- Python 发布校验：5 项通过。
- `git diff --check`：通过。

## 尚未完成的工作

- native HDR passthrough 仍缺少 PQ/HLG NativeWindow 色彩空间和 `nativeOutputActive` 的实体机证据。
- native Surface 还需要完成暂停、seek、重播、播放结束、销毁重建压力验收。
- 控制条会很快自动隐藏；唤出后必须在同一条 HDC 命令中连续执行后续点击，避免中间等待导致操作失效。
- 设备锁屏时，HarmonyOS 开发模式下 HDC 不能自动绕过指纹认证；锁屏期间不能把截图或控制操作当作播放验收。

## 0616 native Surface 复核（2026-09-06）

重新拉起已安装的 `2026090616` 后，DV 测试画面可见，但视频被压缩到左上角，右侧和下方为大面积黑色。这是 XComponent/native Surface 的窗口几何或输出生命周期问题，不是 DV 码流解码失败证据。截图：`/tmp/native-recheck.jpeg`。

因此应用默认输出已恢复为 Texture + tone-map；OHOS native Surface 只保留为后续显式 A/B 候选，直到窗口尺寸和 EGL 生命周期完成真机验收。

## 0617 Texture 默认路径构建（2026-09-06）

- 版本 `2026090617` 已完成 arm64 HAP 构建、签名、校验，并安装启动到实体机 `2PM0223A18006914`。
- 该版本将 OHOS 默认 `useNativeSurface` 关闭，目标是恢复 Texture + tone-map 的完整画面布局。
- 安装启动后设备重新进入指纹锁屏；HarmonyOS 开发模式下 HDC 不能绕过认证，因此本轮未把锁屏截图当作 DV 播放验收。解锁后应直接复用 0617 进行同一素材的全宽画面复测。

## 0617 解锁后复测（2026-09-06）

- 解锁后复用 0617，搜索并打开 `BV16J4m1H7Nm`。
- 点击视频区域后，DV 测试素材正常出画面，画面横向铺满视频区域，未复现 0616 native Surface 的左上角缩小问题；截图：`/tmp/0617-dv2.jpeg`。
- 这验证了“OHOS 默认 Texture + tone-map”修复，同时不改变 native HDR 仍需独立证明的结论。

## 0621 native HDR A/B 复测（2026-09-06）

- 0621 使用 native Surface，并修正 Flutter native view 外层尺寸后，DV 测试画面横向铺满视频区域；截图：`/tmp/0621-dv.jpeg`。
- 真机日志确认 `output=nativeHdr, surface=native-hdr, reason=display-decoder-and-output-ready`，并出现 `HDR dataspace applied: pq`。这首次同时证明了 OHOS native Surface、PQ NativeWindow 配置和播放器 native HDR 决策已连通。
- 仍有 OHOS external texture/BufferQueue 在 Surface 切换阶段报 `40601000`，需要继续做暂停、seek、重播、销毁重建和资源释放压力回归；不能把单次首帧提升为完整生命周期验收。

## 2026-09-06 fullscreen and native transfer follow-up

真机反馈了两个仍需修复的问题：全屏时 XComponent 画面落在左上角小区域，native HDR 画面颜色发灰且亮度偏低。

已在 media-kit OHOS native surface 分支调整：

- OHOS `PlatformViewVideo` 不再用解码器 `rect` 给 XComponent 外层设置固定尺寸，改由父级视频 viewport 提供最终约束，避免全屏旋转后 native surface 仍停留在左上角的小尺寸盒子中。
- native HDR 的 mpv target transfer 不再强制为 `linear`。NativeWindow 已配置为 PQ/HLG，因此 target transfer 跟随源 HDR transfer（PQ 或 HLG），避免线性样本被显示层按 PQ/HLG 解释后产生灰暗画面。

这两项需要重新构建 HAP 并在真机上复测全屏、PQ 亮度和 HLG；当前 0621 证据仍只代表旧版本的 native PQ 链路已显示画面。

0622 已构建并安装到真机。自动进入视频页后当前选中的流在日志中标记为 `source=sdr`，因此该次截图不能作为 PQ 亮度验收；需要在画质菜单明确选择 HDR/DV 流后再验证 `target-trc=pq`、全屏布局和亮度。

0623 重新构建并安装真机包，OHOS 实际 `OhosVideoController.configureHdrOutput` 已补上 `target-prim=bt.2020` 与 `target-trc=pq/hlg`。构建、签名、校验、安装均成功；HDR 亮度仍需在明确选中 HDR/DV 画质后进行最终视觉验收。

0625 真机包已包含 HDR 请求修正并重新安装。对 BV16J4m1H7Nm 的请求在 HDR 屏幕上已尝试 `qn=126`（最高偏好 127 映射到 DV 码），但接口实际返回的 DASH 列表仍为 `80,64,32,16`，日志为 `target=80, source=sdr`。这表明该视频/账号接口响应没有提供 HDR 档位，不能把它误判为播放器 native HDR 失败；需要用接口确实返回 DV/HDR 码的测试视频继续做最终 native PQ 验收。

## 2026-09-06 1080P+ 置灰修正

真机页面反馈 1080P 以上画质全部置灰。根因不是 HDR 显示探测，而是菜单用 `index >= total - usefulCount` 假设 `support_formats` 与 DASH 列表顺序一致；接口实际可能按相反顺序返回，导致可用的高画质被错误标灰。

画质菜单现改为按 DASH 实际返回的 quality ID 判断可用性，同时继续单独用显示 HDR 能力控制 DV/HDR10/HDR Vivid。普通 1080P、2K、4K 不再受 HDR 开关误伤。

0626 画质菜单修正包已完成构建、签名、校验并安装真机。菜单可用性判断已从位置区间改为 DASH quality ID 集合，避免接口顺序变化导致 1080P+ 全部灰掉；本次页面截图显示视频可正常渲染，HDR 接口返回问题仍按 0625 记录。

0627 画质菜单置灰修正包完成真机构建并安装。构建前清理了远端历史 `piliplusx-ohos-build.*` 临时目录（无活动进程，释放约 70GB），构建恢复正常。菜单现在按 DASH quality ID 判断可用性；当前测试视频接口仍只返回 `80,64,32,16`，因此其 HDR 流可用性仍取决于账号/接口响应。

0628 构建脚本清理修正：远端 HAP 构建脚本的退出 trap 原先被 module 恢复 trap 覆盖，导致每次构建泄漏完整临时工作树；现合并为同时执行 `restore` 与 `cleanup`，并通过 `bash -n` 和发布校验回归。

0629 native Surface 生命周期复测（真机 `2PM0223A18006914`）：打开视频后日志依次出现 `native XComponent surface attached`、`suspendTexture: textureId=1`；返回上一页触发 `nativeSurfaceDestroyed`，随后 `resumeTexture: textureId=3, surfaceId=...`。销毁事件之后不再产生新的 `40601000`，证明 native Surface 接管、Texture 暂停、Surface 销毁和 Texture 恢复链路已打通。本次片源仍被接口标记为 SDR，因此不把它计入 PQ/HDR 色彩验收。

## 0630 最新安装包运行状态（2026-09-06）

- 最新生命周期修正版 HAP（构建号 `1788632984`）已完成构建、签名、校验、安装并启动到实体机 `2PM0223A18006914`。
- 进程仍在运行（`pidof com.example.piliplusx` 返回 `54270`）；本轮 hilog 未发现 `SIGSEGV` 或 `Fatal signal`。
- 该轮确认的是 native Surface/Texture 生命周期稳定性和画质菜单 ID 门控；由于接口给当前测试视频返回的仍是 SDR DASH（`80,64,32,16`），不能用它宣称 PQ 亮度或 native DV 色彩已经完成验收。

## 0630 登录状态影响（2026-09-06）

- 实机复测期间发现 B 站账号已退出登录。
- 因此此前接口只返回 `80,64,32,16`、目标质量回落到 `80` 的结果不能继续作为片源不提供 HDR 的最终结论；未登录/会员权限缺失可能同时限制 1080P+、HDR 和 Dolby Vision 档位。
- 重新登录后必须在相同实体机、相同 HAP 和相同视频上重新记录 `support_formats`、DASH quality IDs、HDR metadata 与最终 `HDR decision`，再判断 1080P+ 菜单和 native PQ 亮度。

## 0631 登录恢复后的真实 DV 复测（2026-09-06）

- 重新登录后，`BV16J4m1H7Nm` 的 DASH 列表实际返回 `126,120,112,80,64,32,16`；日志为 `displayHdr=true, cached=127, target=126`，证明此前仅返回 SDR 档位确实受登录状态影响。
- 最新修正版 HAP（构建号 `1788633558`）已构建、签名、校验并安装到实体机。真实 DV 流日志依次出现 `source=dolbyVision, transfer=pq`，随后 `output=nativeHdr, surface=native-hdr, reason=display-decoder-and-output-ready`。
- 修正 `video_texture.dart` 让 OHOS native Surface 在 `LayoutBuilder` 的实际视频 viewport 中布局，不再让 `FittedBox` 使用解码器小尺寸。实机截图 `/tmp/real-dv-fixed-0906.jpeg` 显示详情页视频区域横向铺满 1260px 屏幕宽度；这不是进入全屏播放，因此不能据此宣称全屏左上角小块问题已解决。
- 当前截图为系统 SDR 截图，不能单独量化 HDR 峰值亮度；画面已可见且 native HDR/PQ 决策成立。播放期间仍观察到少量 `OH_NativeImage_AcquireNativeWindowBuffer` `40601000`，需继续确认其是否为切换残留以及是否影响长时间播放。

## 0632 全屏验收边界（2026-09-06）

- 对最新已安装包只做了运行状态检查，没有把详情页视频区域截图当作全屏证据。
- 当前 hilog 的显示状态仍为 `rotation=0, width=1260, height=2720`，未出现真正横屏全屏状态；因此“全屏播放左上角小块”仍是未完成验收项。
- 先前尝试的 native view 命中行为改动已撤回，未安装对应构建；控制条自动超时是操作时序问题，不能作为代码改动依据。

## 0633 控件超时与 UI 层级证据（2026-09-06）

- 当前 UI dump 中 XComponent 的 bounds 为 `[0,124][1260,832]`，对应详情页视频区域，不是全屏路由；dump 中未出现“全屏”控件文本，说明控制条已经超时隐藏。
- 该证据支持“测试时序导致按钮不可操作”的判断，不支持修改 native Surface 命中行为。后续全屏测试必须先唤出控制条，再在同一短操作窗口内点击按钮并立即抓取旋转和窗口 bounds。

## 0634 长片源 BV1vY4y1N7TY 实机复测（2026-09-06）

- 按要求改用较长片源 `BV1vY4y1N7TY`；页面标题为“蹲守一周，我终于拍到了夕阳下的梦幻场景｜北海道VLOG | Links 4K HDR”，时长约 19 分钟。
- 登录会话下接口返回 `126,120,112,80,64,32,16`（多条重复音视频 representation），日志为 `displayHdr=true, cached=127, target=126`。
- 播放决策日志依次出现 `source=dolbyVision`、PQ HDR10 元数据补正，最终 `output=nativeHdr, surface=native-hdr, reason=display-decoder-and-output-ready`；截图 `/tmp/bv1v-long-dv.jpeg` 可见真实长片画面。
- 播放期间仍持续出现 `OH_NativeImage_AcquireNativeWindowBuffer() ... 40601000`，同时 `VideoOutputManager.setSurfaceSize` 高频重复提交 `3840 1920`。这属于当前 native Surface/外部纹理稳定性阻塞证据，尚未证明长时间播放、全屏和亮度验收完成。

## 0635 长片去重与 tone-mapping 配置复测（2026-09-06）

- 针对 0634 日志中同一 `3840x1920` 尺寸被高频重复提交的问题，media-kit OHOS 控制器增加请求级去重；HAP 构建号 `1788634973` 已完成构建、签名、校验、安装并在实体机启动。
- `BV1vY4y1N7TY` 重新打开成功，当前进程只出现一次 `VideoOutputManager.setSurfaceSize ... 3840 1920`；长片画面可见，HDR 决策出现 `output=nativeHdr, surface=native-hdr`。
- 复测发现 native HDR 分支把 mpv `tone-mapping` 设为非法值 `no`，实机日志明确报 `Invalid value for option tone-mapping: no`。现改为合法值 `auto`，构建前代码测试和静态分析通过。
- 新包启动后按同一长片重新测试，当前进程未再出现该 `tone-mapping=no` 报错；`40601000` 仍会出现，说明尺寸请求去重和非法 tone-mapping 修正尚未解决外部纹理缓冲获取问题。
- 截图 `/tmp/bv1v-tone-auto.jpeg` 证明长片仍能出画面，但画面观感偏灰、亮度偏低；这仍需在真实 HDR 显示状态和 native Surface 生命周期稳定后继续做 PQ 色彩验收，不能把截图直接当作完成证据。
- 当前仍未进入横屏全屏路由；详情页视频区域和真正全屏播放继续分开验收。

## 0636 native Surface 延迟输出与交换链色彩提示复测（2026-09-06）

- 针对 0635 的 `40601000`，OHOS native-surface 候选创建阶段现保持 mpv `vo=null`，收到 `nativeSurfaceReady` 后才绑定 XComponent；同时事件顺序调整为先 `SuspendTexture`、后切换 mpv 输出。
- 最新 HAP 构建号 `1788636094` 已完成构建、签名、校验、安装并在实体机启动。`BV1vY4y1N7TY` 仍能出长片画面，日志确认 `HDR dataspace applied: pq` 与 `output=nativeHdr`。
- 该时序修正没有消除 `40601000`；错误仍在 native Surface 接管后持续出现，说明当前主要消费者是 OHOS Flutter/XComponent external texture 的 BufferQueue，而非 mpv 启动阶段向旧 Texture 产帧。
- 按 mpv 官方色彩管理要求，native HDR 同步增加 `target-colorspace-hint=yes`，用于让 gpu-next 交换链明确传递 BT.2020 PQ/HLG 色彩空间；代码测试、静态分析和 HAP 构建均通过。
- 截至本轮，画面可见但仍需在实体机屏幕上确认灰暗问题是否改善；`40601000`、真正横屏全屏和亮度验收仍未完成，不能标记计划完成。

## 0637 色彩提示后的真实画面（2026-09-06）

- `BV1vY4y1N7TY` 在构建号 `1788636094` 上持续播放，截图 `/tmp/bv1v-hint.jpeg` 可见画面随时间变化，证明不是静止首帧或黑帧。
- `target-colorspace-hint=yes` 已生效到 native HDR 参数路径，日志仍确认 `HDR dataspace applied: pq`；但截图观感暂未达到明亮、饱和的目标，不能宣称灰暗问题已解决。
- 5 秒窗口统计到约 749 条 `40601000`，因此该错误不是偶发首帧告警，需继续定位 OHOS Flutter/XComponent external texture 的消费节流或 BufferQueue 生命周期。

## 0638 Surface 视频源与白点参数首轮验证（2026-09-06）

- native OHOS HDR 窗口配置增加 `SET_SOURCE_TYPE=OH_SURFACE_SOURCE_VIDEO`，并设置归一化 HDR/SDR white-point brightness（测试值 `1.0/0.2`）；重置路径恢复 UI 源和 SDR 参数。HAP 构建号 `1788636654` 已构建、签名、校验、安装并启动到实体机。
- 使用 `BV1vY4y1N7TY` 长片复测，画面持续变化且详情页视频区域可见；但 RenderService 对应用根 Surface 仍报告 `hdrWhitePointBrightness=0`、`sdrWhitePointBrightness=0`、`HDR=0`，当前不能据此宣称 compositor 已进入 HDR。
- 本轮截图仍处于详情页，未进入横屏全屏；`40601000` 仍持续出现。下一步需确认 HDR 配置调用对应的 XComponent Surface 是否被 RenderService 单独暴露，并在明确选中 DV/HDR 档位后重新抓取 native 配置返回值和 Surface 元数据。

## 0639 HCPP 独立合成后的亮度观感（2026-09-06）

- 构建号 `1788637321` 启用 OHOS HCPP 视频 Surface 后，实体机现场观感反馈为“目前亮度不错了”。这与此前 texture composition 将 HDR 帧写入 SDR 根 Surface 的判断一致，说明独立合成路径已经改善实际亮度表现。
- 同一构建的 RenderService 仍记录 `media_kit_ohos_native_surface_0Surface` 为 10-bit、HDR/SDR white point 为 `1.0/0.2`，但 `HDR=0` 仍未消失；因此亮度改善已得到现场观感支持，系统 HDR 标志和全屏仍需继续验证。

## 0640 重建实验回退与稳定包复测（2026-09-06）

- 为了让 HDR 参数早于交换链创建而尝试的自动输出重建触发 `ValueNotifier<int?> was used after being disposed`，导致输出重建失败；该实验已回退，没有保留在当前代码中。
- 回退后的稳定包构建号 `1788637772` 已重新构建、签名、校验并安装。`BV1vY4y1N7TY` 复测再次出现 HCPP overlay、`HDR dataspace applied: pq` 和最终 `output=nativeHdr, surface=native-hdr`，没有再出现 `output-dispose-failed`。
- RenderService 仍能看到独立视频 Surface，white point 为 `1.0/0.2`，10-bit 格式和静态元数据存在；`HDR=0` 仍是待解释字段。现场亮度改善保持，真正横屏全屏仍未验证。

## 0641 稳定包全屏操作复核（2026-09-06）

- 稳定包 `1788637772` 的详情页视频 Surface bounds 为 `[0,123][1260,709]`，显示仍为竖屏 `1260x2720`；按控制条记录执行连续点击后没有触发全屏，未观察到横屏旋转或窗口 bounds 改变。
- 本次没有修改控制条或命中测试逻辑。控制条在截图/布局抓取前已自动隐藏，当前证据只能确认全屏尚未触发，不能据此判断全屏路由本身失败。

## 0642 亮度观感确认（2026-09-06）

- 实机现场最新反馈为“目前观感上亮度不错了”。在 HCPP 独立合成、10-bit Surface、PQ dataspace 和 native HDR 决策保持不变的条件下，当前亮度改善得到再次确认。
- 因此后续调试暂不继续调整亮度、白点或 tone-mapping 参数，优先处理真正横屏全屏以及 native Surface 控件交互；任何新改动都需避免回归当前画面观感。

## 0643 横屏输出缩放、居中与 HDR 复验（2026-09-06）

- 实机包 `1788639240` 在 `BV1vY4y1N7TY` 上验证了横屏手势：窗口为 `2720x1260`，native 输出从竖屏的 `1260x630` 重算为 `2520x1260`；视频左右黑边各约 `100px`，不再贴在左上角。
- 重算后日志为 `reapplied HDR after surface resize: result=0 transfer=0`，随后截图 `/tmp/fs-final.jpeg` 显示横屏视频居中且高光、饱和度恢复；当前全屏低亮与灰暗现象未在该包复现。
- 同一旋转曾产生两次相同的强制重算，已增加有效输出尺寸去重，避免重复触发 native swapchain/HDR 配置。

## 0644 全屏实机复核结果（2026-09-06）

- 实机包 `1788639450` 复核 `BV1vY4y1N7TY`：横屏截图 `/tmp/fs-final2.jpeg` 为 `2720x1260`，视频内容左右各约 `100px` 黑边，已按比例居中；不再出现左上角块状布局。
- 重算路径记录 `3840x1920 -> 2520x1260`，HDR 重应用返回 `result=0 transfer=0`。本轮截图的夕阳高光和暖色饱和度正常，先前“全屏发灰、亮度不高”未复现。
- 后续源码又增加了按横屏视口尺寸的请求级去重；该优化需随下一次 HAP 构建安装后再补充运行日志，不改变本轮已验证的显示结果。

## 0645 全屏稳定性优化包（2026-09-06）

- 构建号 `1788639668` 已完成 OHOS arm64 HAP 编译、签名、校验，并安装到实体机 `2PM0223A18006914`。
- 本包包含横屏视口级重复刷新抑制；上一轮已验证的居中、亮度和 HDR 重应用逻辑保持不变。安装启动完成，长片全屏回归需继续按控制条操作规程复测。

## 0646 稳定性优化包实体机回归（2026-09-06）

- `1788639668` 实体机回归成功打开 `BV1vY4y1N7TY` 并进入横屏全屏；截图 `/tmp/fstest2.jpeg` 为 `2720x1260`，视频左右黑边对称，未出现左上角小块。
- 日志确认横屏只完成一次有效 HDR 重应用：`3840x1920 -> 2520x1260`、`result=0 transfer=0`；视频高光和颜色可见，未复现全屏低亮问题。
- 仍观察到一次重复到达 `SetSurfaceSize(force=true)`，但尺寸结果相同且没有第二次 HDR 重应用；后续可继续收紧 native manager 的重复请求抑制，不影响当前画面结果。

## 0647 横屏持续播放短时稳定性（2026-09-06）

- 在 `1788639668` 横屏全屏状态保持 `BV1vY4y1N7TY` 播放约 40 秒，PID `41593` 在开始、10/20/30/40 秒轮询中始终不变。
- 前后截图均为 `2720x1260`，像素差异均值约 `67/62/65`，证明画面持续更新；本轮日志未出现 `40601000`、`SIGSEGV`、`Fatal signal` 或 `output-dispose-failed`。
- 该结果是短时稳定性证据，尚不能替代完整 19 分钟长片、前后台切换和退出全屏回归。

## 0648 OHOS 全屏方向锁定回归（2026-09-06）

- 针对 0647 约 67 秒后被方向监听恢复竖屏的问题，OHOS 手动全屏且横向视频时忽略纵向传感器事件；退出全屏仍执行原有方向恢复。
- 新包 `1788640200` 已构建、签名、校验并安装到实体机。横屏全屏保持约 80 秒，PID `44486` 在 8 次 10 秒采样中始终不变；首尾截图分别为 `2720x1260`，没有回到竖屏。
- 实时日志没有出现 `40601000`、`SIGSEGV`、`Fatal signal` 或 `output-dispose-failed`。本轮解决的是方向稳定性，完整 19 分钟播放和前后台切换仍需继续验证。

## 0649 左侧亮度手势初始值修复（2026-09-06）

- 根因：左侧手势在 `getWindowBrightness` 异步读取完成前，直接以 `_brightnessValue = 0.0` 作为手势基准，因此第一次调整总是从最低亮度开始。
- 修复：手势开始时优先使用已读取的亮度，其次使用控制器缓存值；两者都不可用时使用 1.0 作为临时基准，并阻止异步读取结果覆盖正在进行的左侧手势。
- 验证：`dart analyze lib/plugin/pl_player/view/view.dart lib/plugin/pl_player/controller.dart`、`flutter test --no-pub test/plugin/pl_player/hdr_test.dart`、`git diff --check` 均通过。实机 HAP 回归待后续测试窗口执行。

## 0650 亮度手势修复包安装（2026-09-06）

- 新包构建号 `1788640716` 已完成 OHOS arm64 HAP 编译、签名和校验，产物为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-xiaobai-2.1.3-signed.hap`。
- 已安装并启动到实体机 `2PM0223A18006914`；HDC 同时可见 `127.0.0.1:5555` 模拟器，但本轮未使用模拟器做视频验收。
- 实体机进程 `com.example.piliplusx` 当前运行中，左侧亮度手势行为由用户后续现场确认。

## 0651 控制条点击回归修复包（2026-09-06）

- 根因：左侧亮度专用纵向手势识别器使用 `1px` 接受阈值，触摸点击中的微小抖动会抢先赢得手势竞技场，导致视频区域的 tap 无法唤出控制条。
- 修复：改用设备触摸阈值（无设备值时使用 `kTouchSlop`），保留纵向亮度滑动，同时让普通点击继续交给 tap 识别器。
- 新包构建号 `1788641194` 已完成 arm64 HAP 编译、签名、校验并安装到实体机 `2PM0223A18006914`，已自动重启应用等待现场验证。

## 0652 native Surface 触摸穿透修复包（2026-09-06）

- 实机反馈确认：视频画面区域点击无法唤出控制条，只有上下黑边可以；这证明 ArkUI XComponent 的 native 命中区域覆盖了 Flutter 控制层。
- 共享 media-kit 的 OHOS `OhosNativeSurface.ets` 已将 XComponent 设置为 `HitTestMode.None`，保留视频渲染但不再吞掉 Flutter 的点击和手势。
- 新包构建号 `1788641456` 已完成 arm64 HAP 编译、签名、校验并安装到实体机 `2PM0223A18006914`，已自动重启应用等待复测。

## 0653 OHOS SurfaceView 交互 A/B 包（2026-09-06）

- `HitTestMode.None` 在实机上没有改变视频区域点击行为，继续使用 HCPP 时 native platform view 仍覆盖 Flutter 控制层。
- 临时 A/B 将 OHOS `PlatformViewVideo` 改为 `initSurfaceOhosView`，绕过 HCPP 的独立合成命中层，验证控制条交互是否恢复；HDR 亮度和 native 合成状态需单独复核，不能把本包直接视为最终 HDR 方案。
- 构建号 `1788641715` 已完成编译、签名、校验并安装到实体机 `2PM0223A18006914`，已自动重启应用等待用户复测。

## 0654 SurfaceView/HCPP 亮度对比记录（2026-09-06）

- 实机反馈：SurfaceView A/B 包与 HCPP 包的亮度观感没有明显差异；该结论保留为后续对比测试基线，不把 SurfaceView 作为控制条问题的解决方案。
- 实机反馈同时确认：SurfaceView A/B 仍然只有视频上下黑边可以唤出控制条，视频画面区域点击仍无效，因此问题不是 HCPP 独有的点击层级现象。
- 已恢复 HCPP 代码路径并重新编译安装 debug 包 `1788641972`，后续 release 包基于该恢复状态构建。

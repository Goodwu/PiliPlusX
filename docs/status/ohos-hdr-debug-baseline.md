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

## 当前工作树：全屏变灰回归的 A/B 修正（2026-09-08）

当前 media-kit 工作树曾将 `refreshSurfaceSize` 中的 HDR producer-contract
重应用删除，并让 OHOS FFI 不再写 transfer metadata/color space。该状态尚未有新的
实机包证明能保持 0643/0644 的亮度结果；它与已记录成功包的关键差异相同于“全屏后
变灰”的现象。

现已恢复为：新 XComponent surface attach 和全屏 resize 均在同一 surface/generation
串行保护内，重新应用当前 PQ/HLG 的 format、gamut、white-point、metadata 和 color
space；并记录 `serial/view/surface` 及返回值。该修正仍需用实体机脚本化复测，不能仅
凭 `result=0` 宣称 HDR 已验收。

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

## 0655 release 实机测试包（2026-09-06）

- 基于已提交代码和恢复后的 HCPP 路径完成 release 模式 HAP 构建，构建号 `1788642115`，unsigned HAP 约 `77.1MB`。
- 签名、校验和实体机安装均成功，目标为 `2PM0223A18006914`；应用已自动重启，等待后续 HDR 与控制条对比测试。

## 0656 全屏变灰回归脚本化复测（2026-09-08）

- 使用 `tool/ohos/verify_hdr_real_device.sh` 在实体机 `2PM0223A18006914` 上完成连续操作；搜索并播放同一片源 `BV1vY4y1N7TY`，没有在脚本外补发 UI 点击。产物目录为 `/tmp/piliplusx-ohos-verify-20260908-r11`。
- `06-controls.jpeg` 确认视频底部控制条和全屏图标；脚本从当前 layout 的 Slider 与右下角可点击节点推导全屏目标，避免控制条超时或误点页面顶部按钮。
- `07-fullscreen-immediate.json` 和 `08-fullscreen-stable.json` 的根 bounds 均为 `[0,0][2720,1260]`，证明进入真实横屏全屏；两张截图均显示视频画面持续变化，脚本报告 `frame progression: PASS`。
- 同轮 hilog 记录 `HDR native decision applied: output=nativeHdr`、`HDR dataspace applied: pq`，并在横屏 resize 记录 `3840x1920 -> 2520x1260`、`reapplied HDR after surface resize: result=0 transfer=0`。
- 全屏立即和稳定截图中的夕阳高光、暖色饱和度可见，未复现此前“全屏变灰/亮度偏低”；该结果是当前包和当前片源的实机回归证据，长片、前后台切换及退出全屏仍需单独验证。

## 0657 重复全屏 colorspace A/B 与冻结帧复测（2026-09-08）

- 在 r15 的基础上仅将 FFI HDR colorspace 从 `OH_COLORSPACE_BT2020_PQ_LIMIT` /
  `OH_COLORSPACE_BT2020_HLG_LIMIT` 对齐为 mpv 使用的
  `OH_COLORSPACE_DISPLAY_BT2020_PQ` / `OH_COLORSPACE_DISPLAY_BT2020_HLG`；其余 resize、
  metadata、target-trc 和 Surface 生命周期逻辑保持不变。
- 新包已构建、签名、校验并安装到实体机；使用脚本 `--freeze-frame --toggle-count 3`
  连续进出全屏，产物为 `/tmp/piliplusx-ohos-verify-20260908-r19`。
- 脚本先暂停同一视频帧，再采集首次全屏、退出全屏、再次进入全屏的 immediate/stable
  截图。第 2 次进入全屏的两张截图保持同一帧的亮度、蓝色天空和绿色草地，没有出现“先亮后灰”；
  `HDR decision evidence: PASS`、`frame progression: PASS`。
- 该 A/B 证明 colorspace 枚举不一致是必要修正，且当前包已通过冻结帧的重复切换验证；仍需在
  用户现场确认主观灰屏不再出现，并继续保留真实 buffer/RenderService 属性作为后续深入证据。

## 0658 播放中全屏变灰修正包（2026-09-08）

- architect 复核确认：暂停切换安全、播放中切换变灰，优先指向 live Vulkan resize/present 与
  Dart FFI 并行写 NativeWindow producer contract 的竞态；单纯把 `invalidate_color` 前移或
  增加延时不足以解决根因。
- 修正 media-kit OHOS controller：初次 surface attach/HDR configure 仍使用 FFI；窗口尺寸
  变化期间只更新 mpv `target-*` 属性，不再从 Dart 线程并行调用 `_configureHdr`，由 mpv VO
  线程在新 swapchain 首帧恢复 NativeWindow colorspace、metadata 和 brightness。
- 新包构建号 `1788840216` 已完成编译、签名、校验并安装到实体机
  `2PM0223A18006914`。使用脚本执行播放中连续 3 次全屏切换，产物为
  `/tmp/piliplusx-ohos-verify-20260908-r20`；脚本报告 `HDR decision evidence: PASS`、
  `frame progression: PASS`，立即/稳定截图均保持可见高光与饱和颜色，未复现“先亮后灰”。
- 该结果是当前片源和当前设备的脚本化回归证据；仍需用户现场确认主观亮度，并在必要时补充
  NativeWindow 实际 buffer colorspace/RenderService 属性，而不能仅以日志或 `result=0` 作最终证明。

## 0659 WSI swapchain 诊断包（2026-09-08）

- architect 否决了直接扩展 `pl_swapchain_frame` 的 generation 方案：恢复时机仍晚于
  acquire，且存在公共结构体 ABI 风险；该方案未进入 HAP。
- 为验证“多次切换后发生隐式 Vulkan swapchain 重建”的假设，构建链新增临时诊断 patch，
  将 libplacebo `(Re)creating swapchain` 日志提升到可采集级别；未改变渲染或颜色逻辑。
- native `libmpv_aarch64.zip` 已重建，SHA-256 为
  `202e6b36e49a92b6e8a0822a414dcfbc0c8f6caf048d29e087ff0e5e311888cb`；对应诊断 HAP
  构建号 `1788845149` 已签名、校验并安装到实体机。包内 `libmpv.so` 已确认包含诊断字符串。
- 下一次必须在 `nativeHdr` 前置条件成立时执行多次切换；脚本现默认拒绝 480P/SDR 流，避免
  把登录态或画质回落造成的结果误判为 HDR 变灰。

## 0660 播放中多次全屏灰屏证据与日志增强（2026-09-08）

- r22 在不清数据、自动处理版本更新弹窗的前提下，使用 `BV1vY4y1N7TY` 连续切换 6 次；
  HDR 前置条件通过，日志确认 `source=dolbyVision`、`output=nativeHdr`、
  `surface=native-hdr`、`nativeActive=true`，同一 native surface ID 在全屏尺寸间切换。
- 用户目测后续全屏均为灰屏；即时截图也显示窗口态与横屏全屏之间存在明显的饱和度/亮度下降线索。
  但旧脚本仅以截图差异判定 frame progression，不能自动证明颜色变化，因此不能把该轮写成
  “已修复”或“已定位根因”。
- architect review 指出最值得关联的是视频 surface 周边的 `ReleaseBufferLocked: cache not find`
  与旋转期间的 `SetWindowTransform: App Is Not Doing Pre-rotation`；它们目前仍只是时间关联点，
  不能单独证明 colorspace 丢失。NativeWindow 同一 surface ID 也不等于同一批 swapchain buffer。
- 诊断脚本新增 `events.tsv`，记录每次切换、点击和截图时间，并将最终输出改为明确的
  `color verdict: INCONCLUSIVE`；不再把截图变化冒充颜色验收。
- 为打通 WSI 日志链路，临时诊断 native 将 libplacebo INFO 映射到应用当前采集的 warn 通道，
  并成功重建 `libmpv.so`（zip SHA-256：
  `2b098cb1c024f8e69273bbc136f0cc96deab7fb936b318d0f8ed8474cb7536c1`）。签名 HAP 已生成，
  但构建耗时期间实体机 HDC 变为 `USB Offline`，安装未完成；不得把该包视为已实机验证。

## 0661 换线后连续全屏复测：灰屏已稳定复现（2026-09-08）

- 更换 USB 线后先执行 5 次 HDC 探针，前后均为 `USB Connected`；随后使用
  `tool/ohos/verify_hdr_real_device.sh --source BV1vY4y1N7TY` 连续切换全屏 6 次，
  全程脚本操作且未清理应用数据。产物为 `/tmp/piliplusx-ohos-verify-20260908-r32`。
- 本轮脚本完整通过 `HDR decision evidence: PASS` 和 `frame progression: OBSERVED`；
  6 次切换和全部截图均完成，故不是上一轮 HDC 断线造成的无效复测。
- 人工复核截图确认：初始全屏及第 2 次横屏画面仍有正常颜色；第 4、6 次横屏稳定截图
  出现明显灰雾化，弹幕仍清晰，符合“播放中反复切换后画面变灰”的用户现象。该轮应判定
  为“灰屏已复现”，不是修复通过。
- 日志同时显示 `nativeHdr` 已生效、每次 resize 后都执行 HDR reapply，但仍反复出现
  `ReleaseBufferLocked: cache not find the buffer` 和 `SetWindowTransform: The App Is Not Doing
  Pre-rotation`。这些是关联证据，暂不能据此直接修改系统旋转或 BufferQueue 生命周期。
- architect 复核建议的下一步是单一 A/B：保持灰态横屏和同一 surface，只在 VO 线程强制重放一次
  现有 HDR 色彩契约，且不主动重建 swapchain；记录重放前后的同源、同播放时间段画面。若恢复，
  再定位颜色状态失效/缓存时序；若不恢复，继续补齐实际 swapchain、format/colorspace、
  acquire/present 和 setter 返回值证据。当前不应继续堆叠 pre-rotation 或 BufferQueue workaround。

### 延迟重放诊断包用法

当前默认延迟为 `1200ms`；构建时可传入延迟毫秒数做 A/B，对照包显式传 `0`：

```bash
tool/ohos/build_sign_hap_test.sh \
  --dart-define OHOS_HDR_DELAYED_REAPPLY_MS=1200 \
  --install 2PM0223A18006914
```

该路径只通过 mpv 属性路径重放 `target-prim`、`target-trc` 和
`target-colorspace-hint`，不调用 HDR FFI、不主动重建 swapchain。两轮均须使用同一片源和
同样的脚本切换次数。

## 0662 延迟 HDR 重放 A/B：6 次切换未复现灰屏（2026-09-08）

- 诊断包使用 `OHOS_HDR_DELAYED_REAPPLY_MS=1200` 构建、签名并安装到实体机；
  HDC 安装和启动均成功。产物为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-hdr-delay1200-signed.hap`。
- 使用同一片源 `BV1vY4y1N7TY` 完成 6 次脚本化全屏切换，产物为
  `/tmp/piliplusx-ohos-verify-20260908-r33-delay1200`。HDR 前置条件通过，6 次切换和截图完整完成。
- 与 r32 对照：初始、第 2、4、6 次横屏稳定截图均保持蓝天、绿色和正常饱和度，未出现 r32
  第 4、6 次的灰雾化；日志确认延迟重放在 serial=3、6、10、14 等 resize 后执行。
  这支持“resize 后颜色契约恢复时序”假设，但尚不能证明 1200ms 是最终正确时序，也不能直接
  把定时器作为永久 workaround。
- 后续 12 次尝试 `/tmp/piliplusx-ohos-verify-20260908-r34-delay1200` 因搜索后接口报错、
  未进入 `nativeHdr`，脚本 fail-closed 退出；该轮不是 HDR 结果，不能与 r33 合并统计。

## 0663 延迟重放包在确认播放推进后仍复现灰屏（2026-09-08）

- 针对 r33 可能因网络卡顿而实际暂停的疑问，脚本新增播放推进门槛：每次全屏切换前连续抓取两帧，
  间隔 2 秒；帧完全相同则立即使整轮失效，不再进入 HDR 结论。新增产物为
  `/tmp/piliplusx-ohos-verify-20260908-r35-delay1200-playing`。
- 在同一实体机、同一片源 `BV1vY4y1N7TY`、同一延迟重放包上，6 次切换前的 6 个推进采样均通过，
  `HDR decision evidence: PASS`，且 HDC 全程在线。因此本轮不是网络导致视频暂停的无效样本。
- 人工复核稳定截图：初始全屏和第 2 次仍正常；第 4 次已明显灰雾化，第 6 次继续灰雾化。
  证据文件为 `08-fullscreen-stable.jpeg`、`09-toggle-2-fullscreen-stable.jpeg`、
  `09-toggle-4-fullscreen-stable.jpeg`、`09-toggle-6-fullscreen-stable.jpeg`。
- 日志仍同时出现 `diagnostic delayed HDR reapply done` 与多次
  `ReleaseBufferLocked: cache not find the buffer`；因此“延迟重放单独修复问题”的假设被本轮有效播放
  回归否定，1200ms 目前只能保留为诊断变量，不能作为修复验收结论。

## 0664 状态机与诊断产物复核（2026-09-08）

- r36/r38 的 RenderService 快照显示，横屏有效样本中的视频 surface 始终保持 10-bit buffer
  (`config` format 34)、`metadataType=2`、静态 HDR metadata、`hdrWhitePointBrightness=1.0`、
  `sdrWhitePointBrightness=0.2`，视频 surface `colorSpace=7` 且为 device composition。由此不能把
  “NativeWindow HDR 标签丢失”作为当前已证实根因；实际 Vulkan 输出映射仍未被观测。
- r36 暴露出测试状态机曾把竖屏退出全屏状态命名为 `fullscreen-stable`，因此该截图不能用于颜色结论。
  r38 已改为识别横屏/竖屏交替，只有横屏状态才作为有效全屏样本；r38 的 4 次切换均完成，播放推进门禁
  均通过，但颜色结论仍为 `INCONCLUSIVE`，因为不同截图不是同一帧。
- `ohos_ui_layout.py` 的竖屏唤醒坐标曾按面积选中透明整页 XComponent，导致点击点落在真实视频 surface
  之外。现已优先选择黑色 native video XComponent，并将唤醒点限制在其 bounds 内；离线布局回放验证为
  竖屏 `[0,162][1260,792]` 内的 `y=772`。r39 尚未完成实机确认，因 HDC 在启动阶段变为 `USB Offline`。
- 诊断 patch 虽已同步到 dev wrapper，但当前 media-kit 内置 `libmpv_aarch64.zip` 的 SHA-256 为
  `2b098cb1c024f8e69273bbc136f0cc96deab7fb936b318d0f8ed8474cb7536c1`，其中不含新增诊断字符串；
  签名 HAP 内的 `libmpv.so` 也不含这些标记。因此必须先完成 patched `.so` → ZIP → HAP → 运行库的
  身份链路验证，再继续判断 Vulkan `VkFormat`/`VkColorSpaceKHR` 和首个 present 的时序。

## 0665 防止 CMake 复用旧 libmpv（2026-09-08，已被 0667 修正）

- `media_kit_libs_ohos` 的 CMake 原先只在 `libs/arm64-v8a` 为空时解压 ZIP；即使 ZIP 已替换，
  非空目录中的旧 `libmpv.so` 仍可能被打进 HAP。此前尝试在配置阶段清理目标目录，但该目录是
  共享解压/消费路径，配置期删除会制造空目录和并行构建竞态；该做法不再作为当前方案。

## 0667 将 libmpv 解压从 CMake configure 移到构建目标（2026-09-08）

- `media-kit` 的 OHOS CMake 现在只在 configure 阶段下载并校验 archive，使用带 archive 依赖的
  `LIBMPV_EXTRACT` stamp 目标在实际构建阶段清空并重新解压 `libs/arm64-v8a`，并让
  `mediakit_ohos_hdr` 显式依赖该目标；不会在配置期删除共享目录。
- 该最小修正位于工作区外的 `/Users/wuweiwei1/src/media-kit/.../CMakeLists.txt`，保留其余
  用户未提交改动不动。尚未运行 dev 远端构建、HAP 签名、安装或实体机验证。

## 0668 诊断 patch 条件编译与实机脚本门禁（2026-09-08）

- `vo_gpu_next.c` 的 OHOS target-mapping 诊断补齐了 `#endif`，并仅在 `HAVE_OHOS` 下声明
  `swap_color`，避免非 OHOS 编译出现未闭合条件块或未使用变量；同步更新
  `libmpv-ohos-build/patches/mpv/ohos-output-mapping-diagnostics.patch`。
- `verify_hdr_real_device.sh` 保留 `--toggle-count` 兼容行为，新增 `--cycles N`，每个 cycle 完整
  执行退出横屏/进入竖屏再回到横屏；播放门禁现在要求语义 `playing` 加位置变化或帧变化，
  并明确输出 `paused`、`buffering`、`unknown`，JPEG 变化不能单独证明播放。
- 版本更新弹窗只允许脚本识别的关闭动作；检测到未知动作或弹窗未消失即 fail closed。
  本阶段仅完成静态检查/帮助检查，未进行设备 UI、远端构建或签名安装。

## 0666 增加实际 target mapping 观测（2026-09-08）

- 未直接采用无条件“双调用”方案。architect 复核认为 `set_color` 与
  `pl_swapchain_colorspace_hint` 的互斥可能造成 shader target 与 Vulkan swapchain mapping 分裂，
  但尚不能解释全屏切换后的状态变化；直接双写还可能触发额外重建和 HDR metadata 双写。
- 新增 `patches/mpv/ohos-output-mapping-diagnostics.patch`，只记录 OHOS `set_color` 回写后的
  hint，以及 `pl_frame_from_swapchain` 原始 target 与最终 target 的 primaries、transfer、levels 和
  HDR luminance 字段，不改变颜色策略或生命周期。
- 该 patch 尚未进入 HAP；dev SSH 当前不可用。恢复连接后必须先验证 patch、native ZIP、HAP 和运行库
  的身份，再用连续全屏脚本对照灰态/正常态的 mapping 日志。
- `verify_hdr_real_device.sh` 新增可选门禁 `VERIFY_REQUIRE_NATIVE_DIAGNOSTICS=1`；对当前旧诊断 HAP
  的预检已按预期失败，明确报告 HAP 内缺少诊断标记，避免再次把旧包的“无日志”误判为运行路径无事件。

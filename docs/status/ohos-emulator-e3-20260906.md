# OHOS 模拟器 E3 Flutter Texture 实验记录

更新时间：2026-09-06

## 目标与边界

使用与 E2 相同的本地 SDR 素材，创建最小 Flutter 页面，仅走
`OhosVideoController` 的 Flutter Texture 输出，验证纹理 ID、播放推进、控制和
退出重进。模拟器官方约束为“仅支持软件解码、仅支持 RGBA 显示”，所以本实验
固定 `hwdec=no`，不把硬解、HDR 或非 RGBA 输出当作变量。E3 的 guard 修改只存在
隔离实验树，不修改 PiliPlusX 主仓库或当前 dirty 的 media-kit 工作树。

## 隔离实现

- Flutter OHOS fork：`/Users/wuweiwei1/src/flutter-ohos-e3`
  - branch：`oh-3.44.9-dev`
  - revision：`4f1a4267afdd99ef58f81ae825fae7fb5603c67e`
- Flutter 应用：`/Users/wuweiwei1/src/luna_flutter_e3`
- media-kit 隔离 worktree：`/Users/wuweiwei1/src/luna-ohos-e3`
- guard 修改位置：隔离 worktree 的
  `media_kit_video/lib/src/video_controller/ohos_video_controller/real.dart`
- 页面使用 `VideoController` 的 Texture 路径，`useNativeSurface=false`，固定
  `hwdec=no`，素材复制到 `/data/storage/el2/base/files` 后调用
  `Player.open(Media(path))`。为适应该 fork 报告 `0.0.0-unknown` 的 SDK 元数据，
  仅在隔离 worktree 放宽 media-kit 的 Flutter 下限；同时把 wakelock 依赖替换成
  E3 专用 no-op，不代表正式产品依赖方案。

## 构建与安装

```text
flutter pub get                         成功，32 dependencies
flutter build hap --release --no-codesign 成功
HAP: build/ohos/hap/entry-default-unsigned.hap
HAP SHA-1: c5f9e3f6f3edc0d9f40d625ab6bab920d2c9edea
安装目标: 127.0.0.1:5555
aa start: com.example.luna_flutter_e3/EntryAbility 成功
```

首次构建失败是 `DEVECO_SDK_HOME` 未设置；设置为
`/Applications/DevEco-Studio.app/Contents/sdk` 后重试成功。该问题不是源码或
ABI 失败。

## 实际运行证据

启动后日志证明 Texture 对象和播放控制链路确实建立：

```text
LunaE3 texture id=1
LunaE3 texture start path=/data/storage/el2/base/files/e2-sdr-720p.mp4
LunaE3 position=1000ms
LunaE3 position=2000ms
LunaE3 control pause position=2400ms
LunaE3 control seek position=2000ms
LunaE3 control play
LunaE3 position=3000ms
LunaE3 position=4000ms
```

页面状态栏从 `playing texture 1s` 持续推进到 `11s`；执行了 pause → seek(2s) →
play；随后执行 `aa force-stop` → `aa start`，进程重新存活并再次取得 Texture ID。
本轮日志未见 `SIGSEGV`、`FATAL` 或 `Cpp Crash`。

为排除单一输出配置，补做了两个 A/B：

- `enableHardwareAcceleration=false` 与 `true` 均固定 `hwdec=no`，均得到相同
  `40601000` 黑屏；因此不是该开关单独造成的。
- `vo=gpu` 出现 `null gpu context`、`eglCreateImage ... ctx null` 和同步错误；恢复
  `vo=gpu-next` 后仍是同一个 external-texture `40601000`，所以不把 `gpu` 当作
  模拟器可用替代路径。

同时开启 mpv debug 日志后，除一条不影响时钟推进的
`lavf: Failed to create file cache.` 外没有 `vo`/窗口初始化失败；播放时钟仍从
`1s` 推进到 `3s`，故素材和 mpv 初始化不是首个失败点。

## Flutter renderer A/B：`enable_impeller=false`

为排除 Impeller renderer 本身对模拟器外部纹理路径的影响，在同一隔离 E3 工程、同一 ARM64 模拟器和同一软件解码素材上追加了 A/B 变体：

- 修改隔离工程 `ohos/entry/src/main/resources/rawfile/buildinfo.json5`：`enable_impeller=false`。
- 构建命令仍为 `flutter build hap --release --no-codesign`，生成 HAP SHA-256：`217d02c4492e5d63f63cebb2e30147e91172e7761b29cd1bf7b5e4b719fe0f0d`。
- 安装目标：`127.0.0.1:5555`；包名：`com.example.luna_flutter_e3`。
- 播放时仍出现 `DGLES: bind external with nullptr gbuffer 0`，以及 `ohos_external_texture.cpp(488) OH_NativeImage_AcquireNativeWindowBuffer() failed or buffer is null, ret = 40601000`。
- 播放时钟仍前进到约 1/2/3 秒，暂停、seek、继续播放控制仍执行，但视频区域仍无可见帧。

结论：关闭 Impeller 没有改变失败边界；问题仍落在 Flutter OHOS external texture 与模拟器 BufferQueue/同步路径，不能据此宣称模拟器视频显示已修复。隔离工程已恢复 `enable_impeller=true`，产品代码不因该 A/B 改动。

## 官方 video_player_ohos 替代路径 A/B

为排除 media-kit 自身的 `VideoOutput` 实现，另建隔离应用
`/Users/wuweiwei1/src/luna_video_player_e3`，使用 OpenHarmony-SIG
`flutter_packages` 的 `video_player_ohos`，同一 Flutter OHOS fork
`4f1a4267afdd99ef58f81ae825fae7fb5603c67e`、同一 ARM64 模拟器
`127.0.0.1:5555` 和同一 `e2-sdr-720p.mp4`。本次只放宽了该隔离副本的 SDK
约束并移除非 OHOS 平台依赖，没有修改产品仓库或 media-kit 工作树。

```text
Flutter package source: /Users/wuweiwei1/src/flutter-packages-e3
package revision:       35fb467533e174411a117b2a030c15d2a3a9687c
HAP:                    /Users/wuweiwei1/src/luna_video_player_e3/build/ohos/hap/entry-default-unsigned.hap
HAP SHA-256:            6c049c549ece7ef09e1b8b592bb72b2f1fa897152f505c2585962970e96ab922
install/start:          hdc -t 127.0.0.1:5555 install -r ... && aa start
```

实际日志包含：

```text
Adding plugin: VideoPlayerPlugin
LunaVideoPlayerE3 texture initialized
LunaVideoPlayerE3 position=1417ms
LunaVideoPlayerE3 position=2424ms
LunaVideoPlayerE3 control pause position=2929ms
LunaVideoPlayerE3 control seek position=2000ms
LunaVideoPlayerE3 control play
LunaVideoPlayerE3 position=11413ms
ohos_external_texture.cpp(488) ... ret = 40601000
```

最新截图 `/tmp/luna_video_player_e3.jpeg`，SHA-1
`5b14b34d95ba4a7bbc333b1b4ae58d88ee22b50d`，仍只有 Flutter 页面和控制条，视频区域
全黑。该替代路径没有使用 media-kit 或 libmpv，但失败位置和错误码完全相同；因此
已排除“media-kit 的 mpv/VideoOutput 独有故障”作为首个失败点。OpenHarmony 官方
OpenHarmony 的[外接纹理适配文档](https://gitee.com/openharmony-sig/flutter_samples/blob/master/ohos/docs/04_development/Flutter%20OHOS%E5%A4%96%E6%8E%A5%E7%BA%B9%E7%90%86%E9%80%82%E9%85%8D%E7%AE%80%E4%BB%8B.md)
同样采用 `TextureRegistry.registerTexture()` 返回 `surfaceId`，再把该 ID 交给播放器；
当前实验已经走到同一纹理契约，但引擎在取
`OH_NativeWindowBuffer` 时失败。

上游 Flutter OHOS 的[同类问题记录](https://gitee.com/openharmony-sig/flutter_engine/issues/IA5R3G)
也记录了 `40601000` 与 BufferQueue 没有 dirty buffer 同时出现的白屏现场；这与本实验“播放器时钟继续推进、Flutter external texture
无法取得可消费 buffer”的分层结论一致。该上游记录只能作为边界佐证，不等价于当前
fork/模拟器已有修复。

但视频区域始终为黑色，最新截图 `/tmp/luna_e3/luna_e3_final.jpeg`（1260×2720，
SHA-1 `520d5d3d18e6e2943ba4cb62ae878555bdec98f6`）没有可见视频帧。同期 Flutter 引擎
持续报告：

```text
ohos_external_texture.cpp(488)
OH_NativeImage_AcquireNativeWindowBuffer() failed or buffer is null,
ret = 40601000
```

因此 E3 的结论是：Texture ID、解码/播放时钟、pause/seek/play 和重进链路通过，
但“可见连续播放”失败；失败点在 Flutter OHOS external texture 获取
`OH_NativeWindowBuffer`，不是播放器对象未推进。

## 阶段结论

E3 **未通过**。按执行计划，E4 不能被视为 E3 的成功替代；本轮仍额外执行 E4
以确认 native Surface 边界。当前最小可复现缺口是：在官方只支持
软件解码/RGBA 显示的模拟器上，OHOS Flutter external texture 返回
`40601000`，导致 Texture 画面黑屏。media-kit 和官方 `video_player_ohos` 两条
插件路径均复现，故退出条件所需的“插件替代路径”已执行；所需的引擎能力是能够在
该 Flutter Texture producer/consumer 契约下取得并同步 RGBA NativeWindowBuffer。
保留该现场，不把日志中的播放进度误报为可见首帧，也不把 E2 原生 Surface 的通过
结果外推到 Flutter Texture。E4 随后作为独立 native Surface 边界实验执行，结果见
`docs/status/ohos-emulator-e4-20260906.md`，同样未通过可见帧验收。

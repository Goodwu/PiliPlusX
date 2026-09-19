# OHOS 模拟器播放救援记录

更新时间：2026-09-06

本记录只收录当前 ARM64 模拟器上的证据。实体手机的 Texture/native Surface
结果见 [OHOS 开发总结](ohos-development-summary.md)，不能替代本表的模拟器结论。

## 环境快照

| 项目 | 结果 |
| --- | --- |
| HDC 目标 | `127.0.0.1:5555` |
| 目标 ABI | `uname -m` = `aarch64` |
| 应用包 | `com.example.piliplusx`，Ability `EntryAbility` |
| 当前 media-kit | `3d57f37f9008435c7895082b2f5b052e9a61081c` |
| 当前 PiliPlusX | `2763566f6979232ca64f8654b758d0d2f16e9bb3` 加未提交工作树修改 |
| 现场截图 | `/tmp/ohos-emulator-current.jpeg`，1260×2720；应用首页可见，视频区域黑色 |

模拟器官方约束：仅支持软件解码、仅支持 RGBA 显示。因此 E2 固定 `hwdec=no`
和 RGBA 输出；硬解、HDR 和非 RGBA 输出不属于该模拟器成功路径的实验变量。

设备命令和启动复核：

```sh
/Users/wuweiwei1/.local/harmony-tools/bin/hdc list targets
/Users/wuweiwei1/.local/harmony-tools/bin/hdc -t 127.0.0.1:5555 shell uname -m
/Users/wuweiwei1/.local/harmony-tools/bin/hdc -t 127.0.0.1:5555 shell \
  aa start -a EntryAbility -b com.example.piliplusx
```

应用启动日志包含 `Get device info, it is emulator`。当前 OHOS Dart 控制器在
初始化播放器前仍主动返回：

```text
[VideoController] does not support emulator. Please use actual device.
```

因此当前安装包可以证明 Ability 和 Flutter 页面启动，不能证明模拟器视频播放。

## 实验矩阵

| 实验 | 假设与主要变量 | 结果 | 结论与缺口 |
| --- | --- | --- | --- |
| E1 原生 Surface | 独立 ArkTS/C++ XComponent/EGL 动态色块，不经过 Flutter、mpv | HAP 构建/安装/启动成功；Surface ID `3285649981617` 经 NAPI 创建 NativeWindow，EGL/GLES render thread 持续 `eglSwapBuffers`；截图可见动态色块，间隔截图 SHA 不同；10 次慢速 stop/start 均返回成功，最终进程存活且无崩溃 | E1 通过。证据与工程见 `docs/status/ohos-emulator-e1-20260906.md` 和 `/Users/wuweiwei1/src/luna-ohos-e1`。callback 直接注册路径的 SIGSEGV 作为后续 E4 风险保留，不阻塞已通过的 Surface ID 对照。 |
| E2 原生 mpv | 在 E1 Surface 上接入同版 libmpv，软件解码固定本地 SDR | 独立 ARM64 HAP 包含产品同版 `libmpv.so`；`hwdec=no`、`MPV_RENDER_API_TYPE_SW`、RGBA 输出；状态 `frames>0/mpvReady=true/frameReady=true/error=0`；可见截图间隔 SHA 不同；pause/seek 和 3 次销毁重建通过 | E2 通过。证据见 `docs/status/ohos-emulator-e2-20260906.md`；仅覆盖模拟器官方支持的软解/RGBA，不覆盖硬解/HDR。 |
| E3 Flutter Texture | Flutter 页面仅使用 Texture 播放固定本地 SDR；先用隔离 media-kit，再用官方 `video_player_ohos` 替代路径 | 两条路径均构建/安装/启动成功并推进播放时钟、pause/seek/play；两条路径视频区域均黑屏，Flutter `ohos_external_texture.cpp(488)` 持续返回 `OH_NativeImage_AcquireNativeWindowBuffer() ... 40601000`；官方替代路径未使用 media-kit/libmpv | E3 未通过。播放时钟推进不等于可见首帧；失败边界已从插件缩小到 Flutter OHOS external texture 与模拟器 BufferQueue/同步链路。证据见 `docs/status/ohos-emulator-e3-20260906.md`。 |
| E4 Flutter native Surface | Flutter 页面改用 XComponent/native Surface，Texture 停止后再绑定 | 已构建、安装并运行独立 E4；取得 `nativeSurfaceReady`、真实 Surface ID、mpv attach、播放时钟和 pause/seek/play；截图视频区域全黑，并出现模拟器 EGL/BufferQueue 同步错误 | E4 未通过。native surface 接管成立但最终可见帧仍失败，边界扩大为 Flutter OHOS PlatformView/native surface 与模拟器 EGL/BufferQueue 同步链路。证据见 `docs/status/ohos-emulator-e4-20260906.md`。 |

失败现场保留在两个仓库的命名 stash 中，未直接 `stash pop`：

- `media-kit`：`ohos-emulator-20260906-blocked-remove-emulator-guard`、
  `ohos-emulator-20260906-blocked-remove-emulator-guard`。
- `PiliPlusX`：`ohos-emulator-20260906-blocked-upstream-external-texture`、
  `ohos-emulator-20260906-blocked-software-texture-ab`、
  `ohos-emulator-20260906-blocked-native-surface-and-texture-crash`。

## 阶段结论

当前插件产品包仍有 emulator guard，但独立对照已证明模拟器在官方约束内可以完成
产品同版 libmpv 的软件解码和 RGBA 输出。E3 和 E4 已在本地 OHOS Flutter fork
上实际执行；两者均有播放时钟但无可见视频帧。随后用官方 `video_player_ohos`
替代路径复现 E3 相同错误，因此不能把问题继续归因于 media-kit，也不能把 E2 结果
外推为 Flutter 播放已恢复。不得把播放时钟或历史实体机日志当作 Flutter 可见首帧
证据。

E3 另做了隔离 renderer A/B：`enable_impeller=false` 的 HAP SHA-256 为
`217d02c4492e5d63f63cebb2e30147e91172e7761b29cd1bf7b5e4b719fe0f0d`，仍复现
`40601000` 与 `DGLES ... nullptr gbuffer`，因此关闭 Impeller 没有改变本轮模拟器
黑屏的失败边界。隔离工程已恢复 `enable_impeller=true`。

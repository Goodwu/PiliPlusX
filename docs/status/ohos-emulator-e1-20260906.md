# OHOS 模拟器 E1 独立原生 Surface 实验记录

更新时间：2026-09-06

## 目标

在当前 ARM64 OHOS 模拟器上，用不含 Flutter、Dart、media-kit 和产品
`OhosVideoController` 的最小 ArkTS/C++ 工程验证 XComponent Surface、EGL
context、GLES 动态色块和销毁/重建边界。该实验只为 E1，不是视频播放验收。

## 固定输入

| 项目 | 结果 |
| --- | --- |
| 工程 | `/Users/wuweiwei1/src/luna-ohos-e1` |
| 设备 | `127.0.0.1:5555`，`uname -m=aarch64` |
| 模拟器官方图形/解码约束 | 仅支持软件解码；仅支持 RGBA 显示 |
| SDK | `/Applications/DevEco-Studio.app/Contents/sdk/default` |
| HAP | `entry/build/default/outputs/default/entry-default-unsigned.hap` |
| HAP SHA-256 | `59a1409b07db37504a7bc8ee225a89a265e6fdc02b30830a9eb190ed8b34f599` |
| ABI | `arm64-v8a`；HAP 清理重建后只包含 `libs/arm64-v8a/libentry.so` |

## 已执行

```sh
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export OHOS_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw clean
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default
/Users/wuweiwei1/.local/harmony-tools/bin/hdc -t 127.0.0.1:5555 \
  install -r entry/build/default/outputs/default/entry-default-unsigned.hap
/Users/wuweiwei1/.local/harmony-tools/bin/hdc -t 127.0.0.1:5555 \
  shell aa start -a EntryAbility -b com.example.luna.e1
```

构建成功，HAP 安装成功，Ability 启动成功。屏幕截图显示独立工程标题和
黑色 Surface 区域；截图可由 `snapshot_display` 重新生成。

## E1 通过证据

C++ 已链接 `EGL`、`GLESv3`、`ace_ndk.z`、`ace_napi.z`、`native_window` 和
`hilog_ndk.z`。ArkTS XComponent `onLoad` 取得真实 Surface ID，再经独立
NAPI 方法调用 `OH_NativeWindow_CreateNativeWindowFromSurfaceId`；EGL context、
window surface、GLES 绘制和 `eglSwapBuffers` 全部在同一 render thread 内执行。

最终 HAP `59a1409b...ed8b34f599` 安装到 `127.0.0.1:5555` 后，日志包含：

```text
LunaE1 ArkTS XComponent onLoad surface=3285649981617
LunaE1 ArkTS native start result=true
com.example.luna.e1/DGLES ... eglSwapBuffers_special ...
```

截图 `/tmp/luna-e1-final.jpeg` 显示标题和完整 Surface 动态色块；相隔约 1 秒
的两张截图 SHA-256 分别为：

```text
00f2f7a883a838b972be361f5d8b6f10767ed8dbb0d347e3959249c45a08f426
f17a977253ecdaa0a0c6bad5dfbbaaf3e38167c090211d2509390b30b773064d
```

生命周期复核执行了 10 次慢速 `aa start`，每次前后均执行 force-stop，命令均
返回 `start ability successfully`；最后再次启动后 `ps` 仍有
`com.example.luna.e1`，日志未出现 `SIGSEGV`、`Cpp Crash` 或 `TypeError`。

因此 E1 通过：Surface 可见、画面随帧变化、EGL/交换推进、重复销毁重建未崩溃。
这只证明 E1 原生 Surface，不证明 mpv 解码或 Flutter Texture/native Surface。

## 失败的 callback A/B（保留，不作为 E1 根因）

早期 A/B 曾直接调用 `OH_NativeXComponent_RegisterCallback`，在该模拟器上触发
`SIGSEGV`；另一个显式 import 版本曾触发 `Cpp Crash`。这些路径已不再用于 E1，
因为 Surface ID→NativeWindow 路径已经提供了满足 E1 的独立原生对照。该现象仍
应在后续 E4 native Surface 集成阶段单独复核，不能写成 EGL 或模拟器 GPU 根因。

## 后续

E2 已在同一独立工程中通过，详见
`docs/status/ohos-emulator-e2-20260906.md`。随后已完成 E3 Flutter Texture 和
E4 Flutter native Surface 的独立复测；两者均保留为失败证据，不改写本 E1 通过结论。

# OHOS 开发总结

更新时间：2026-09-04

## 当前结论

PiliPlusX 已在 SSH `dev` 上用完整 `lib/main.dart` 生成 unsigned arm64 HAP，并在本机
签名后完成 OHOS 模拟器和实体手机的安装、启动：首页实际绘制正常。近期白屏回归的
原因和修复证据见 [OHOS 运行状态与近期回归记录](ohos-runtime-status.md)。

## 固定基线

- 主平台：Flutter 3.47.2。
- OHOS：Flutter commit `aa76d9bbeee7806a87dbd202d2550dfd11550b82`，Flutter 3.44.9，Dart 3.12.2。
- OHOS CLI：`26.0.0.621`；目标 ABI：`arm64-v8a`；构建模式：release、`--no-codesign`。
- media-kit：当前 Darwin 生命周期修复 `73536efdda482f2d5eefe2feb7038db419944b96`；
  尚未切换到公共 HDR API 候选 `ad22c36a9986a8418c81829821962009425cf5e5`。
- HDR：OHOS 继续 fail-closed，`nativeOutput=false`，仅允许 Texture SDR/tone-map。

## 已完成实现

- `prepare_ohos_build.py`：从主 checkout 创建隔离构建副本，再校验并转换 package 名、SDK/Flutter 约束、兼容依赖和资源；输出目录必须位于源 checkout 之外。
- `prepare_ohos_flutter.py`：应用 Flutter patch 链，补齐 PageView、WidgetSpan、SelectableRegion 和 `TargetPlatform.ohos` 差异。
- `prepare_ohos_material_ui.py`：对实际解析到的 material_ui/cupertino_ui 缓存应用组件和平台分支兼容补丁。
- workflow：CI 使用 `$RUNNER_TEMP` 下的隔离源码副本和独立 `PUB_CACHE`，包含工具链、依赖、ABI、manifest、固定无签名配置和 SHA-256 校验。
- `PlatformFeatureSupport.isOhos`：OHOS 不支持的文件导出、后台音频和 PiP 入口返回 unsupported 并隐藏。

## HAP 构建证据

- 工作目录：`/home/wuweiwei1/PiliPlusX-ohos-344`。
- HAP：`build/ohos/hap/entry-default-unsigned.hap`。
- HAP SHA-256：`7134be623545a6061b6035fdb424811b8fe7be4d1eb47dd044b5cfc76ad225dc`。
- 包内已确认：`module.json`、`libs/arm64-v8a/libflutter.so`、`libapp.so`、`libmpv.so` 和 `libc++_shared.so`。
- `python3 scripts/verify_artifact.py <hap> --platform ohos --abi arm64-v8a`：通过。
- `flutter pub get`：通过；完整 kernel snapshot：通过。

构建首次在 media-kit CMake 下载阶段等待 `libmpv_aarch64.zip`；预下载并校验其
SHA-256 `2bfb9844a7552c450694581b315b26cdf6202eaa57724e9f70f3facfad75163b` 后，
HAP 构建完成。该压缩包只保留在远端构建缓存，不作为仓库生成物提交。

## 运行验收状态

| 验收项 | 当前状态 | 缺口 |
| --- | --- | --- |
| HAP 安装 | 已验证 | 模拟器与实体手机分别使用匹配 profile 安装成功 |
| Ability/首页启动 | 已验证 | 模拟器与实体手机截图均显示首页 |
| XComponent/NativeWindow 生命周期 | 未验证 | 无图形运行环境 |
| SDR 首帧、暂停、seek、切集、错误源 | 部分验证 | 实体机此前已验证视频首帧；当前模拟器不支持 media-kit OHOS 播放 |
| 前后台恢复、重复销毁、资源释放 | 未验证 | 无设备 |
| HDR probe 不报告 `nativeHdr` | 代码契约已固定 | 仍需运行日志确认 |

## 复现命令

```sh
export PUB_CACHE=/home/wuweiwei1/.pub-cache-ohos-build
export HOS_SDK_HOME=/home/wuweiwei1/ohos-sdk/command-line-tools/sdk
export OHOS_SDK_HOME="$HOS_SDK_HOME"
export PATH=/home/wuweiwei1/tools/flutter-ohos/bin:/home/wuweiwei1/ohos-sdk/command-line-tools/bin:/home/wuweiwei1/ohos-sdk/command-line-tools/hvigor/bin:$PATH
export PUB_CACHE=/home/wuweiwei1/.pub-cache-ohos-build
export OHOS_WORKSPACE=/home/wuweiwei1/PiliPlusX-ohos-build
python3 scripts/prepare_ohos_flutter.py --flutter-root /home/wuweiwei1/tools/flutter-ohos --workspace "$PWD"
python3 scripts/prepare_ohos_build.py --workspace "$PWD" --output "$OHOS_WORKSPACE"
cd "$OHOS_WORKSPACE"
flutter pub get
python3 "$OLDPWD/scripts/prepare_ohos_material_ui.py" --workspace "$OHOS_WORKSPACE"
flutter build hap --release --no-codesign
python3 "$OLDPWD/scripts/verify_artifact.py" build/ohos/hap/entry-default-unsigned.hap --platform ohos --abi arm64-v8a
```

下一步继续在实体机验证当前包的视频首帧、暂停、seek、切集、错误源以及左右滑动
亮度/音量效果；运行证据齐全前不启用 OHOS 原生 HDR。

## 2026-09-04 手势回归阶段记录

实体机验证发现视频区域的垂直滑动会被 `ExtendedNestedScrollView` 的外层垂直
recognizer 抢走，导致列表滚动而播放器亮度/音量不响应。arena 日志确认播放器
recognizer 已加入但被外层 recognizer 拒绝，因此此前对音量节流或 raw pointer 的
怀疑不是根因。

当前阶段性实现是在播放器内注册专用
`PlayerVerticalDragGestureRecognizer`，并复用原有 pan 回调。实体机手工验证通过，
视频区域不再滚动列表，列表区域仍可滚动。该实现仍属于过渡性的 gesture arena
抢占方案；最终应将播放器交互层从嵌套滚动 hit-test/gesture 路径中隔离，或在
`ExtendedNestedScrollView` 层按 pointer 起点决定是否注册外层拖拽。详细证据、当前
阈值风险和后续方案见 [OHOS 运行状态与近期回归记录](ohos-runtime-status.md)。

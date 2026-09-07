# macOS 纯 SDR 输出对比

日期：2026-09-07

## 测试边界

本次只测试非 HDR 内容，不测试 tone-mapping、HDR 显示或 Dolby Vision。

素材：`luna-sdr-720p-bt709-control.mp4`

- H.264，1280x720
- `yuv420p`
- primaries / transfer / matrix：BT.709
- limited range

由于 macOS 应用直接读取 Downloads 受到 TCC 限制，测试 App 通过 localhost 读取同一文件；文件内容未转换。

## 参考链路

使用不读取用户 mpv 配置的纯 SDR 参考：

```text
/opt/homebrew/bin/mpv --no-config --force-window=yes --pause \
  --vo=gpu-next --hwdec=videotoolbox \
  --target-prim=bt.709 --target-trc=bt.1886 \
  --target-colorspace-hint=no --tone-mapping=clip <sdr-url>
```

参考实例回读：`vo=gpu-next`、`hwdec-current=videotoolbox`、BT.709、`bt.1886`、`target-peak=auto`、`tone-mapping=clip`。SDR 源没有进入高光 tone-mapping 场景。

注意：直接执行 brew mpv 而不加 `--no-config` 会加载本机 `mpv.conf` 中的
`target-prim=bt.2020`、`target-trc=pq`、`target-peak=400` 和
`tone-mapping=bt.2390`，那不是本次纯 SDR 参考。

## 发现与修复

NativeSurface 创建时原先无条件写入：

```text
target-prim=bt.2020
target-trc=linear
```

这会影响尚未升级为 HDR NativeSurface 的普通 Texture 输出，使 SDR 输入按线性 BT.2020 目标产生明显亮度偏差。

修复位于 `media_kit_video/lib/src/video_controller/native_video_controller/real.dart`：

- 创建 NativeSurface 时不再无条件设置 BT.2020/linear；
- 只有配置 transfer 为 PQ/HLG 时才选择 BT.2020/linear；
- SDR 配置选择 BT.709/BT.1886；
- 诊断 harness 增加纯 SDR 分支，不调用 HDR NativeSurface 配置，也不设置 tone-mapping。

## 结果

将 media-kit 和 clean SDR mpv 的窗口截图裁剪到同一 1280x720 视频区域后比较：

| 版本 | MAE | 结论 |
| --- | ---: | --- |
| 修复前 | 约 0.0740 | SDR 输出明显偏暗/色彩偏差 |
| 修复后 | 约 0.0177 | 大面积色块基本一致，剩余误差主要来自缩放、边缘和测试图案细节 |

修复后代表性平坦区域的 RGB 采样通常只相差 1–3 个 8-bit 码值；media-kit 日志也回读为 `target-prim=bt.709`、`target-trc=bt.1886`、`hwdec-current=videotoolbox`。

## 验证状态

- 纯 SDR 解码：通过
- 纯 SDR media-kit 与 clean gpu-next mpv 亮度/颜色对齐：通过（截图像素对比）
- 默认 mpv 用户 HDR 配置下的对比：不纳入本次结论
- HDR / Dolby Vision / tone-mapping：未测试
- media-kit 包的 Dart 分析：存在工作区已有的 OHOS 平台 API 错误；本次修改文件自身的定向分析无新增 error，macOS App 构建和运行通过
- PiliPlusX macOS Debug 构建：通过
- `flutter test test/plugin/pl_player/hdr_test.dart`：34 个测试全部通过

未提交任何 commit。

# Luna SDR 可见性控制片

生成时间：2026-09-06

## 用途

用于 macOS W1/B2 窗口可见性和首帧验收，不用于 HDR、杜比视界或原生直通结论。
片源是持续运动的 `testsrc2`，避免短片播放到 EOF 后把最终截图误判为黑屏。

## 文件

- 路径：`/Users/wuweiwei1/Downloads/test-clips/luna-sdr-720p-bt709-control.mp4`
- SHA-256：`664ad7d5f38db11266a4ee8b9ce650d989548901531d85193d01d1d09f101c44`

## ffprobe

```text
codec_name=h264
width=1280
height=720
pix_fmt=yuv420p
color_space=bt709
color_transfer=bt709
color_primaries=bt709
r_frame_rate=30/1
duration=20.000000
```

生成命令使用 `libx264`、`yuv420p` 和 `x264-params colorprim=bt709:transfer=bt709:colormatrix=bt709`。

## 使用边界

运行时应保持循环或在 5–15 秒区间截图，并把截图时间、播放器时间、`VIDEO_RECONFIG`、
实际 `VO`、child-window 层级和 detach 日志放在同一证据目录。看到 `VO: [gpu-next]`
或首帧日志但截图无可见像素，仍只能判为 renderer 子门通过、visible-frame 子门未通过。

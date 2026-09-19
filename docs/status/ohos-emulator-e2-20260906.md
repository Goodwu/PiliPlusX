# OHOS 模拟器 E2 独立 libmpv 软件解码实验记录

更新时间：2026-09-06

## 目标与边界

在 E1 已通过的同一独立 ArkTS/C++ 工程中接入产品同版 `libmpv`，使用固定本地
SDR H.264 素材验证：`hwdec=no` 软件解码、libmpv 软件渲染帧、RGBA/GL 输出、
暂停、seek、销毁重建。模拟器官方约束为“仅支持软件解码、仅支持 RGBA 显示”，
所以本实验不把硬解、HDR 或非 RGBA 输出作为成功路径。

## 固定输入

| 项目 | 结果 |
| --- | --- |
| 工程 | `/Users/wuweiwei1/src/luna-ohos-e1` |
| 设备 | `127.0.0.1:5555`，`uname -m=aarch64` |
| 产品同版 libmpv | `media-kit/libs/ohos/media_kit_libs_ohos/ohos/src/main/cpp/libmpv_aarch64.zip` |
| libmpv archive SHA-256 | `999bfba12b9da030b5560ce62188da49cc3be48353d37b56b4167a609be50029` |
| HAP SHA-256 | `a17559e91e989e3e23d3f64ff7df7808c34052ade74f9b9e9d25563586c25aaf` |
| HAP native 内容 | `libmpvrender.so`、`libmpv.so`、`libc++_shared.so`，均为 `arm64-v8a` |
| 测试片 | `assets/e2-sdr-720p.mp4`，SHA-256 `652cf1d5ac3a2c753621705d4d56bfb10a57352868659e57f4339bb826cc77d8` |
| 素材属性 | H.264 Main，720×406，30 fps，`yuv420p`，BT.709 色彩空间，12 秒 |
| 长时/高分辨率测试片 | `/Users/wuweiwei1/src/luna-ohos-e1/assets/e2-sdr-1080p-plan.mp4`，SHA-256 `c4fb52203f5872e80f681ae82adb9ec6f47c23d83cfeed82803b69049780589a` |
| 长时/高分辨率素材属性 | H.264 High，1920×1080，30 fps，`yuv420p` 8-bit，BT.709 色彩空间，15 秒；由 `testsrc2` + 动态 hue 生成 |

## 实现与构建

E2 通过同一个 XComponent Surface ID 创建 `OHNativeWindow`，render thread 建立
EGL/GLES。libmpv 设置 `vo=libmpv`、`hwdec=no`、`config=no`，创建
`MPV_RENDER_API_TYPE_SW` context，使用 `rgb0` 软件帧写入 CPU buffer，再上传
GL texture 输出到 RGBA window surface。渲染循环同步调用 `mpv_wait_event(..., 0)`，
确保 `loadfile` 事件持续推进。

测试片由以下方式生成，使用随动色相保证帧内容随时间改变：

```sh
ffmpeg -f lavfi -i "testsrc2=size=720x406:rate=30" \
  -vf "hue=h=2*PI*t" -t 12 -c:v libx264 -pix_fmt yuv420p \
  -profile:v main -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -movflags +faststart assets/e2-sdr-720p.mp4
```

补充的真正 1920×1080 版本使用同一 `testsrc2`/动态 hue 方法，输出固定为
`yuv420p`、H.264、BT.709；此前名为 `e2-sdr-1080p.mp4` 的旧文件实际为
1280×720，本轮不将其作为 1080p 规格证据。

HAP 构建、安装、启动均成功；原始测试片先由 ArkTS 从 `rawfile` 复制到应用
`filesDir`，native 使用复制后的真实路径播放。

## 通过证据

启动约 3 秒后日志状态为：

```text
LunaE2 status={"frames":61,"pixelSum":3862456,"mpvReady":true,"frameReady":true,"error":0}
```

pause 后执行绝对 seek 到 2 秒并恢复播放，日志为：

```text
LunaE2 after seek={"frames":81,"pixelSum":3862901,"mpvReady":true,"frameReady":true,"error":0}
```

截图 `/tmp/luna-e2-final-a.jpeg` 可见真实测试片色条和时间/帧 OSD；间隔约 2 秒
的两张截图 SHA-256 为：

```text
2510eebe536fea06db7f5372488b9ef0858ea6af1ec492358266f464c906b82d
15fceab5af6b804b1664d24a78010049adeea60ec3acf85e536c0b6faf98b7ac
```

两次截图内容不同，且画面可见，证明软件解码帧已进入 RGBA/GL 输出，而不是只有
播放器对象或日志状态。

随后执行 3 次 `aa force-stop` → `aa start`。每次均获得 `frames>0`、
`mpvReady=true`、`frameReady=true`、`error=0`；pause/seek 回调也均成功。最后
`ps` 仍有 `com.example.luna.e1`，日志没有 `SIGSEGV`、`Cpp Crash`、`FATAL`
或 `abort`。

## 结论

E2 通过：在当前 ARM64 鸿蒙模拟器官方支持范围内，产品同版 libmpv 可以以
`hwdec=no` 软件解码固定 SDR 文件，并通过 RGBA XComponent Surface 显示和推进
视频帧；暂停、seek、销毁重建均有实证。该结果不扩展为硬解、HDR、Flutter
Texture 或 Flutter native Surface 结论。

随后已执行 E3 Flutter Texture 和 E4 Flutter native Surface；详见对应状态记录。
E3/E4 的失败不改写本 E2 在官方“软件解码 + RGBA”范围内通过的结论。

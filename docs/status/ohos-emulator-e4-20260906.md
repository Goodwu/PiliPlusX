# OHOS 模拟器 E4：Flutter native Surface

日期：2026-09-06

## 实验边界

目标是把 E3 的最小 Flutter 播放页从 `Texture` 切换到 media-kit 的
ArkUI `XComponentType.SURFACE` native Surface。遵守官方模拟器限制：仅软件解码、
仅 RGBA 显示；实验固定 `hwdec=no`，不以硬解或 HDR 作为变量。

独立工程：`/Users/wuweiwei1/src/luna_flutter_e4`

- `useNativeSurface=true`
- `vo=gpu-next`
- `hwdec=no`
- 素材：与 E1/E2/E3 相同的 `e2-sdr-720p.mp4`
- 目标：ARM64 OHOS 模拟器 `127.0.0.1:5555`
- HAP：`/Users/wuweiwei1/src/luna_flutter_e4/build/ohos/hap/entry-default-unsigned.hap`
- HAP SHA-256：`d28652cfca4f1da0a60e950a06ae9af95a104e798ec4fc59d846606ab3cc5549`

## 构建、安装与运行

构建使用此前 E3 的 OHOS Flutter SDK 和 DevEco Hvigor：

```text
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
Flutter SDK: /Users/wuweiwei1/src/flutter-ohos-e3
Flutter revision: 4f1a4267af
flutter build hap --release --no-codesign: 通过
hdc install -r: 通过
aa start -a EntryAbility -b com.example.luna_flutter_e3: 通过
```

## 运行证据

日志顺序证明 native Surface 路径真实建立，而不是只把配置字段设为 true：

```text
LunaE4 texture/native id=1 native=true active=false
nativeSurfaceReady: {viewId: 0, handle: 547926878800, surfaceId: 3285649981748}
parsed native surface id: 3285649981748
attaching native XComponent surface 3285649981748
native XComponent surface attached: previous=50165218017280 surface=3285649981748
LunaE3 position=1000ms
LunaE3 position=2000ms
LunaE4 control pause position=2400ms
LunaE4 control seek position=2000ms
LunaE4 control play
LunaE3 position=3000ms
LunaE3 position=7000ms
```

Flutter 页面截图：`/tmp/luna-e4.jpeg`，SHA-256
`d098ae1991c96b39c0049a361ed5ac829e8104f43e625187d954c36f8c9d1d0f`。
截图显示标题、状态栏和控制按钮均可见，状态为 `playing native surface 11s`，
但视频区域全黑。

## XComponent 可见性 A/B

为区分“mpv 未提交帧”和“XComponent 在 Flutter PlatformView 中未形成可见合成”，
在同一隔离工程中只把 `OhosNativeSurface.ets` 的 XComponent 背景从黑色改为红色，
其余配置和素材不变。该 A/B HAP SHA-256 为
`28861e64a480b5878ff807c44ca471b356385ceb769946d550de0b9387317f47`。

启动后截图 `/tmp/luna-e4-red.jpeg`，SHA-256
`d0ddba969b3dbb51bafb0f7129aca70f673d945a9a8c54368081dc0b0c300bda`；标题、状态栏和
控件可见，但原视频区域仍为黑色，没有出现红色 XComponent 背景。随后已恢复隔离
工程的黑色基线，未把该诊断颜色改动留作正式实现。

## 结论

E4 **未通过**：native XComponent surface 的创建、surface ID 传递、mpv `wid` attach、
播放时钟和 Flutter 控件交互均通过；最终视频帧仍不可见。纯色背景 A/B 也未能让
XComponent 区域显示红色；由于 `XComponentType.SURFACE` 本身是不透明 native
surface，该 A/B 不能单独区分 PlatformView 合成失败和 native buffer 未提交，只能
确认没有可见 surface 内容。日志同时出现模拟器
`DGLES` 的 `eglCreateImage ... ctx null`、`bind external with nullptr gbuffer`、
`eglQuerySurface ... EGL_BAD_ATTRIBUTE` 和 BufferQueue 同步错误。

因此 E3 的 external texture 失败不是唯一问题：切换到 native Surface 后，
模拟器仍不能完成 Flutter/ArkUI surface 上的可见帧提交。当前阻塞边界应记录为
Flutter OHOS 渲染/PlatformView 与模拟器 BufferQueue、EGL/GLES 同步链路；不能把
软件解码或 libmpv 重新列为首因。E4 不构成真实设备 native surface 可用性的证明。

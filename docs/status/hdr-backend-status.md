# HDR 后端状态矩阵

更新时间：2026-09-04

构建与设备证据索引见 [HDR 验证账本](hdr-verification.md)；OHOS HAP 当前已构建，
但因 `hdc` 无在线目标仍未进入运行验收。

这份记录区分“能力探测”“原生输出”和“SDR tone-map 回退”。构建成功或
检测到 HDR 显示器，不能单独作为原生 HDR 已启用的证据。

media-kit 公共输出生命周期已在 `Goodwu/media-kit` 的
`integration/piliplusx-hdr-public-api`（`ad22c36a9986a8418c81829821962009425cf5e5`）提供；PiliPlusX
通过兼容桥接调用该生命周期，旧 lock 仍可回退到原 channel 路径。各平台默认实现
fail-closed，平台后端完成后才能将对应 lock 条目提升到该集成 SHA。

| 平台 | 当前输出路径 | 当前能力状态 | 原生 HDR 解锁条件 |
| --- | --- | --- | --- |
| Android / Pink | 先以 HCPP `SurfaceView` 承载 tone-map，dataspace 提交确认后才切为 native HDR；输出重建后重新提交 dataspace；失败时回退 SurfaceView，再回退 Texture | 已实现显示 HDR 类型、当前 track 对应的 MediaCodec HEVC Main10/VP9 Profile 2/AV1 Main10、Vulkan 和 API 门槛探测；track 到达后会重探测；dataspace 设置失败或重建后重提失败均回退。重建已串行化，但 SDR/HDR/HLG/Dolby Vision 连续切换仍无真机证据 | 真机确认 PQ/HLG dataspace 生效，并压力验证连续格式切换时画面、进度控制层和 native 生命周期稳定 |
| iOS | Flutter texture tone-map | 仅探测 EDR；`configureOutput` 已接入但 fail-closed，原生 HDR layer 尚未接入 | 使用 HDR-capable `UIView`/`CAMetalLayer`，并验证设备解码 profile 与 EDR 输出 |
| macOS | Flutter texture tone-map；native surface 按 active 状态单路渲染 | 能力探测绑定窗口实际所在 `NSScreen`；显示器变化通过原生通知和 `EventChannel` 推送到 Dart；SDR 上杜比视界/HDR 画质选项置灰，默认 HDR 画质自动降级到最高可用 SDR 源；HDR native layer 仍需真实 HDR 显示器验证 | 使用窗口内 `CAMetalLayer`，设置 EDR 色彩空间/像素格式并验证 HDR 输出、帧率及 HDR/SDR 跨屏切换 |
| Windows x64 | D3D11 mailbox → Flutter `GpuSurfaceTexture`（BGRA8） | 已接入只读 DXGI 当前输出探测和统一 `configureOutput`/`resetOutput` 契约；nativeOutput 仍为 false，保持 tone-map | 增加独立视频子窗口与真实 flip-model swapchain，检测输出并调用 DXGI 色彩空间接口 |
| Linux x64 | Flutter texture / OpenGL | 已接入保守能力 channel 和统一输出契约；Wayland、X11 与软件渲染会明确记录回退原因，不宣称 HDR；保持 tone-map | 接入 Wayland color-management 协议，仅在 compositor、驱动和输出均可证明时启用 |
| OHOS | Texture tone-map | capability channel 和统一输出契约明确返回 `nativeOutput=false` | 完成 XComponent/NativeWindow HDR 查询、输出路径和真机验证 |

## 回退不变量

- `HdrMode.off` 永远使用 SDR tone-map。
- 能力探测失败、原生 surface 初始化失败或色彩空间设置失败，都必须保留可播放的 Texture/SDR 路径。
- 未有系统色彩空间或等价真实设备证据时，不把 `displayHdr` 或编解码 profile
  单独解释为 `nativeHdr`。
- 每个平台启用原生 HDR 前，必须补充一份真实设备日志，至少包含片源
  primaries、PQ/HLG transfer、输出色彩空间和相对 SDR 基线的指标。

# HDR 后端状态矩阵

更新时间：2026-09-07

构建与设备证据索引见 [HDR 验证账本](hdr-verification.md)。OHOS 当前已有模拟器和
实体机证据：Texture 与 XComponent/native Surface 的 DV 首帧均已通过；0621 已出现
native HDR 决策和 PQ dataspace 应用。native HDR 仍未通过完整生命周期验收。

这份记录区分“能力探测”“原生输出”和“SDR tone-map 回退”。构建成功或
检测到 HDR 显示器，不能单独作为原生 HDR 已启用的证据。

PiliPlusX 当前 9 个 media-kit 包统一锁定到
`Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`。公共输出生命周期
历史候选 `integration/piliplusx-hdr-public-api`（`ad22c36a...`）保留为差异审查来源，
不能再称为当前 lock。当前 lock 与 workflow 中的历史 `73536ef...` 尚未完成一致性迁移，
详见 [HDR 验证账本](hdr-verification.md)。各平台仍须 fail closed，平台后端完成并取得
真实设备证据后才能提升状态。

| 平台 | 当前输出路径 | 当前能力状态 | 原生 HDR 解锁条件 |
| --- | --- | --- | --- |
| Android / Pink | 先以 HCPP `SurfaceView` 承载 tone-map，dataspace 提交确认后才切为 native HDR；输出重建后重新提交 dataspace；失败时回退 SurfaceView，再回退 Texture | 已实现显示 HDR 类型、当前 track 对应的 MediaCodec HEVC Main10/VP9 Profile 2/AV1 Main10、Vulkan 和 API 门槛探测；track 到达后会重探测；dataspace 设置失败或重建后重提失败均回退。重建已串行化，但 SDR/HDR/HLG/Dolby Vision 连续切换仍无真机证据 | 真机确认 PQ/HLG dataspace 生效，并压力验证连续格式切换时画面、进度控制层和 native 生命周期稳定 |
| iOS | Flutter texture tone-map | 仅探测 EDR；`configureOutput` 已接入但 fail-closed，原生 HDR layer 尚未接入 | 使用 HDR-capable `UIView`/`CAMetalLayer`，并验证设备解码 profile 与 EDR 输出 |
| macOS | `NSView` + `CAMetalLayer` 原生 surface；Flutter Texture 在 active 前保留 | 2026-09-07 真实 `BV1vY4y1N7TY` 回放已取得 `nativeOutputActive=true`、`nativeHdr/native-hdr`、`rgba16Float`、`extended-linear-bt2020`、可见 `3840x1920` 帧和约 `2.03` EDR headroom；但用户在约 00:15 对照确认 media-kit_test 明显低于 B站官方/Chrome 和 `/opt/homebrew/bin/mpv` 0.41 gpu-next，光度契约未通过 | 保留原生输出链，先冻结同文件/同帧/同参数对照，验证 mpv target mapping、版本和 GL/Metal 数值尺度；不得把 active=true 当作 HDR 画质完成 |
| Windows x64 | D3D11 mailbox → Flutter `GpuSurfaceTexture`（BGRA8） | 已接入只读 DXGI 当前输出探测和统一 `configureOutput`/`resetOutput` 契约；nativeOutput 仍为 false，保持 tone-map | 增加独立视频子窗口与真实 flip-model swapchain，检测输出并调用 DXGI 色彩空间接口 |
| Linux x64 | Flutter texture / OpenGL | 已接入保守能力 channel 和统一输出契约；Wayland、X11 与软件渲染会明确记录回退原因，不宣称 HDR；保持 tone-map | 接入 Wayland color-management 协议，仅在 compositor、驱动和输出均可证明时启用 |
| OHOS | Texture + tone-map 回退；XComponent/native Surface native HDR A/B | 实体机 `display=true`（`hdrFormats=[1,2,3]`）；0621 的 DV 测试画面全宽可见，日志出现 `output=nativeHdr` 和 `HDR dataspace applied: pq`；native view 尺寸已修正，仍有 `40601000` BufferQueue/external-texture 日志 | 完成暂停、seek、重播、销毁重建压力回归；确认 HLG 色彩空间、Surface 重连和资源释放稳定后，才把 OHOS native HDR 作为默认交付路径 |

## 回退不变量

- `HdrMode.off` 永远使用 SDR tone-map。
- 能力探测失败、原生 surface 初始化失败或色彩空间设置失败，都必须保留可播放的 Texture/SDR 路径。
- 未有系统色彩空间或等价真实设备证据时，不把 `displayHdr` 或编解码 profile
  单独解释为 `nativeHdr`。
- 每个平台启用原生 HDR 前，必须补充一份真实设备日志，至少包含片源
  primaries、PQ/HLG transfer、输出色彩空间和相对 SDR 基线的指标。

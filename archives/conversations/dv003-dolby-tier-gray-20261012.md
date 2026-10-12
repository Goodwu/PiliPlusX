# DV003：B 站杜比视界档（126）面板恒灰——嗅探修复

## Current State

2026-10-12（DEVICE/MK-ROUTING-20261011）：根因定案、修复已实施并通过宿主与真机验收，DV003 分支待 CORE 归并。

1. **根因**：B 站杜比视界档（quality=126）DASH 轨以普通 HEVC Main10 串下发（本例 `hvc1.2.4.L150.90`，文件名 `*_dv1-1-30126.m4s`），不以 `dvh1.*`/`dvhe.*` 声明。`HdrOutputSelector.descriptorFromDash` 对 126 档只能返回「仅 DV 意图、无 profile」descriptor → `hasUnresolvedDolbyVision=true` → `DashRouteSelection.allows()==false` → 清晰度面板恒灰（LG/LYA 双机复现，toast=routeUnsupported）。B1b「未知 DV 不放行」语义本身正确；缺陷在于**站点档位编号（126）本身就是 DV 声明，而 profile 可从该轨自己的初始化段容器记录取得**。
2. **修复（本分支）**：`dovi_sniff.dart`——对 126 轨 baseUrl 做单次有界 Range GET（init 段，≤64KB/4s 超时），ISO-BMFF box 遍历 `stsd/sample-entry` 内 `dvcC/dvvC/dvwC`，按 FFmpeg `ff_isom_parse_dvcc_dvvc` 位布局解析 DV facts；`descriptorFromDash` 消费 facts 装配完整 descriptor（P5/P8/P10；compat 4→HLG、1→PQ；未知 profile/compat 保持未知语义）。失败 fail-closed（维持灰禁）。controller 按 rendition 缓存调度，playurl revision 变化重嗅。
3. **真机验证（LYA-AL00 API29，登录态 BV11f4y1K7Wx P2）**：嗅探日志 `206 → facts=DoviFacts(profile: 8, level: 7, rpu: true, el: false, bl: true, compat: 4)`；清晰度面板「杜比视界」**白色可选且被自动选档选中**（修复前同内容同机为灰色，截图对比 `dv003-*.png`）；零 FATAL。DV 分 P 播放链路既有 EOS e2e 不变。【更正 2026-10-12】菜单范围验收通过；126 播放级验收未完成——position 00:05 为打开初始状态不能作为播放推进证据，且当前另有已复现的 120-AVC 普通解码复核失败（DV004，media-kit PR#4 6125013567），126 无图是否同因待补证。
4. **宿主回归**：`dovi_sniff_test.dart` 13 项（真实字节 fixture + P5/P8.4/未知 profile/keyless compat 0/缺记录/截断/无 URL/超限 + 面板准入集成）全过；全量 281 tests、analyze 0 issues。既有 10 项 unknown-DV 断言未翻转。
   【证据更正 2026-10-12，终审 B4】上句最初引用的 dv003-flutter-test.log/analyze.log 为**早期失败记录**（+223 -5 / analyze 2 issues），不能作为绿证。绑定受审 SHA `dd76cf839`（含终审整改 B1/B2/reopen）的真实成功日志：`manifests/dv003-final-tests-dd76cf83.log`（**284 全过**）与 `manifests/dv003-final-analyze-dd76cf83.log`（**No issues found**）。终审四项阻断已在本分支整改：B1 网络硬预算（统一 deadline/流式截断/有界 drain）、B2 facts 缓存改 rendition 身份键+代次防护、reopen 通道补 initialDoviFacts（均 dd76cf839）；B3/DIAG 移除在库侧 DV004 9a2c5768（media-kit PR#6）。
5. **过程教训（如实）**：首版 `_rangeGet` 未把 UA/Referer 头写入请求（`_headers` 只给了可注入 fetch），真机 403 一度被误归因传输栈指纹——specialist 复核抓出该版本绑定错误；修正后 dart:io 直连 CDN 即 206。DV003 实施登记与中央线程相关表述以本文件为准。
6. **specialist 评审**（PR#5 分支 644908c9 `dv003-specialist-review.md`）：分两层（App 站点知识/库消费标准 descriptor）、三态准入设计、错标风险矩阵。本修复采纳其「嗅探优先」；三态准入因嗅探打通而不需要。

## 2026-10-12 补全（DV005）

上节"播放级验收未完成"由两个独立缺陷叠加：DV004（media-kit PR#6，复核误杀已修）与 DV005（本分支 a2478d04c：DV003 的嗅探 facts 只到菜单未到播放器——pl_player session.open hint 未消费 facts，126 被 planner 按 B1b 阻断 sourceMetadataUnknown；打通 initialDoviFacts 通道）。**LYA 真机 126 冷启动闭环**：dvProfile=8/compatId=4，baseLayerDirect→nativeHdr verified，OMX.hisi hevc，画面渲染+帧推进+零 FATAL（dv005-frame1.png）。开放项仅剩：CORE 归并后在 LG（PQ 面板）复测 126 convert/tone-map 路径。

## 开放项

- DV003 归并后需按最新整合向量在 LG（PQ 面板，预期 convert/tone-map 路径）复测 126 档行为。
- codec 串显式 `dvh1/dvhe` 的轨不受影响；`dvh1.07`（P7）与未知 profile 仍按未知语义灰禁（有据设计）。
- 既有画质项（黑位不足/高亮过曝）留待画质分轮。

## 证据

- LYA 面板前/后对比：`evidence/LYA-app-dv/{panel8.png, dv003-fixed-panel.png}`（跨机目录 `/Users/wuweiwei1/src/mk-device-20261011/evidence/`）
- 嗅探日志：`DOVI_SNIFF status=206 ... facts=DoviFacts(profile: 8, ... compat: 4)`
- 宿主：`manifests/dv003-flutter-test.log`（281 通过）、`manifests/dv003-analyze.log`（0 issues）
- 中央登记：media-kit PR#4 comments 6119674293 / 6119869298 / 6122712443 / 6120461592

## 历史区

- 2026-10-12 15:xx 用户报告灰禁；16:xx 真机复现（LYA panel8.png）+ 宿主矩阵锁定三种灰禁 codec 情形。
- 2026-10-12 17:xx 用户 API 数据定案根因（hvc1 串）；specialist 架构评审。
- 2026-10-12 18:xx Range 嗅探实施；传输 403 误判为一轮（实为未发头）；修头后 206 + facts 验证通过。
- 2026-10-12 19:xx 面板验收通过，DV003 分支提交。

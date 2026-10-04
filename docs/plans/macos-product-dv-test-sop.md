# macOS 产品 DV/HDR 固定测试操作说明

通用播放器交互时序以 [跨平台播放器固定操作说明](player-interaction-operation-sop.md) 为准；本文只补充 macOS 产品页、目标 BV 和 macOS 证据边界。

本文用于重复验证真实产品页面上的杜比视界/HDR 视频。目标是让每次测试都使用同一个应用、同一套输入动作和同一套证据，不把搜索结果标签、OHOS 结论或 mpv 后端日志互相替代。

## 0. 固定边界

- 本文测试 macOS 产品应用，不用于 OHOS。性能验收优先使用 Release；Debug 用于诊断，两者结果分别记录。
- 每次只启动一个已构建并通过最终门禁的明确路径：

  `/Users/wuweiwei1/src/PiliPlusX/build/macos/Build/Products/Release/PiliPlusX.app`

  或 `/Users/wuweiwei1/src/PiliPlusX/build/macos/Build/Products/Debug/PiliPlusX.app`

- 开始前必须确认没有同 Bundle ID 的旧实例、临时 Runner 或同名副本。
- 共享渲染核心实验使用 conversation `Current State` 指定的独立候选绝对路径；普通 Release 路径与共享候选分别记录，不能沿用另一候选的实屏验收。
- 目标视频使用 `BV1vY4y1N7TY`；页面标题应包含 `4K HDR`，作者应为 `Linksphotograph`，时长约 `19:31`。
- “页面显示 HDR”只能证明产品选中了目标条目；最终解码/输出结论必须有应用自身解码格式、mpv/VideoToolbox 日志或 native output 证据。

## 构建与依赖硬门禁

- 使用普通 `flutter build macos --release --no-pub`（诊断时可选择 Debug）；Xcode 在 Flutter/Pods 嵌入以及全部 18 个 Swift Package 依赖框架复制、签名完成之后统一执行 `scripts/ensure_macos_mpv_bundle.sh`，Debug/Profile/Release 均不可跳过。
- 首次构建自动获取固定 Release archive；离线可用 `PILIPLUSX_MPV_ARCHIVE` 指向已下载副本，但 SHA-256 必须为 `2965439e9d239a441263288140b2d8b09ee877478084916f63575a1775de97a4`。首次缺少缓存时自动从固定源码构建双架构四库和 Intel mpv slice，需 arm64 主机及 cmake/meson/ninja/pkg-config/Python/uchardet；缓存逐项校验源码身份与文件 SHA-256。需要匹配 libplacebo 349 ABI 的运行库；`PILIPLUSX_MPV_RUNTIME_DIR` 可指向已验证的四库目录。Homebrew libplacebo 360 不能替代 349。缺失依赖或校验失败即构建失败。
- 构建完全结束后、启动前执行 `scripts/verify_macos_mpv_bundle.sh APP_PATH`。阶段内 PASS 不能替代最终包门禁：2026-10-03 已复现 SPM 自动复制旧 mpv 晚于无依赖脚本，现通过 36 个明确输入建立复制/签名 → 校验脚本 → 最终应用签名的顺序。
- `scripts/verify_macos_mpv_bundle.sh APP_PATH`分别检查 arm64/x86_64 的实际 mpv 0.41.0、必需 feature、可重定位闭包、每个应用架构的真实加载/无输出初始化与签名，并输出 Mpv SHA-256；禁止凭包名或历史记录确认依赖。
- 构建失败的产物不得用于验收；加载门禁通过仍需本 SOP 的实际播放证据。固定归档的 x86_64 Swift 链接缺陷已由固定源码重建 slice 修复；四库均以 macOS 12.0 为部署目标重建。实际默认 Debug 的双架构加载/初始化门禁已通过，默认完整 Release 构建及最终 app 独立重验已通过，证据见 conversation 的 macos-final-release-20261003；仍需可见播放验收。

## 共享核心候选构建

共享候选使用已审核的 Python consumer，详细输入准备及封装规则见 [bootstrap说明](macos-shared-candidate-bootstrap.md) 和 [consumer说明](macos-shared-candidate-consumer.md)。不要使用未纳入当前交付范围的旧 shell frontend。

先在明确绑定共享源码的产品 checkout 中构建已签名中间 App：

```sh
PILIPLUSX_MPV_BUNDLE_MODE=shared-candidate-bootstrap flutter build macos --release --no-pub
```

中间 App 带 `MediaKitSharedBootstrapPending`，不得启动验收或分发。随后使用尚不存在的工作、发布、输出和日志路径消费已封存输入：

```sh
python3 scripts/build_macos_shared_candidate.py \
  --input-app "$SIGNED_BOOTSTRAP_APP" --inputs "$SEALED_INPUTS" \
  --recipe "$SHARED_RECIPE" --work-dir "$FRESH_WORK" \
  --published-dir "$FRESH_SLICES" --output-app "$NEW_CANDIDATE_APP" \
  --log-dir "$NEW_LOG_DIR" --input-kind normal --jobs 2
```

变量必须在本次任务中明确绑定实际绝对路径；源码/配方/输入身份按对应说明校验，不能将本机封存依赖当作 hosted fresh 结果。consumer 在私有副本中完成封装和签名，最终校验双架构运行库及共享后端，清除 pending 后才发布。保存 `.shared-core.json`、`.shared-backend.json`、源码绑定和实际构建日志。空目标后端 probe 不证明 P5 颜色、HDR 亮度或流畅度。

本地文件诊断必须在 bootstrap 构建时额外传入 `--dart-define=PILIPLUS_LOCAL_VIDEO_DIAGNOSTICS=true`，随后 consumer 使用 `--input-kind diagnostic`。未传 define 的正常包入口默认关闭；input-kind 仅记录调用者声明，不替代实际构建配置核验。诊断源码已修正为 `autoplay:false` 初始化、真实视图挂载后显式播放，最终17项CPU测试和增量源码复审通过；尚未构建或播放这一诊断增量。不同候选分别记录 Runner 摘要，不沿用历史 v9/v10 的运行接受。

当前 r4 正常候选完成源码/产物绑定及最终运行库门禁，但 4K窗口用户反馈卡顿；P5颜色正常、HDR输出未证明且卡顿严重，HLG卡顿严重，PQ颜色亮度高光正常但开头卡顿。性能优化作为后续专题，验收记录继续保留这些失败或未知项。

## P5 样片身份与产品入口

在线 `BV1vY4y1N7TY` 的 `dolbyvision / BT.2020 / PQ` 信息不包含 profile；不得将其播放结果单独作为 Profile 5 颜色验收。

已核验的本地输入为 `/Users/wuweiwei1/Downloads/test-clips/Mystery Box Dolby Vision Profile 5.mp4`，SHA-256 `3e610d3b1b11e9b802da66d69bd97f6371a2b114ee464a7e8517fe31d706cc9f`。容器 DOVI 记录为 profile 5、level 9、RPU=1、EL=0、BL=1、compatibility id=0；视频为 HEVC Main10、3840×2160、60000/1001 fps。该记录只证明输入，不能证明输出颜色正确。

默认产品 `FileSource` 入口使用 Bilibili 离线下载目录和固定文件名。显式诊断构建通过原生文件选择器授权任意本地视频，以 `DirectFileSource` 复用正式 `PlPlayerController`、`PLVideoPlayer`、源切换和输出生命周期；以同一个已打开 Player 的实际元数据复核源格式，不凭文件名注入 P5 结论。历史 v9/v10 的轨道读取和可见播放仅保留在 conversation 历史证据中，不代表最新候选已验收。macOS 当前使用 `VideoController / Player.open`，Android 使用 `HdrVideoSession`，两者 API 路径不同；共享色彩核心的验收仍需分别证明实际后端。

颜色对照固定同一源、同一时间点和同一显示器，分别记录 SDR 映射与 native HDR 的实际输出编码。macOS 截图不能证明 EDR 亮度；产品可见颜色和参考高光仍由实屏对照验收。

历史同源颜色参考使用独立 `/private/tmp/ppx-p5-reference-20261004/DVP5Reference.app`。当时参考进程 PID46092 已实际初始化并读回 `gpu-next / macvk / Vulkan`，VideoToolbox/P010 与 DV/PQ 源信息，暂停在 PTS10.010000；打开的容器文件 SHA-256 与上述 P5 样片相同。参考请求 SDR BT.709/BT.1886/100nit/BT.2390，不能用于证明产品 HDR 亮度。它使用独立 feature 构建，不能作为单变量性能 A/B；控制窗口已可见，视频窗口尚未取得实屏对照，Mac 锁屏时不进行视觉验收。库、驱动、runner 与日志身份见 conversation 当前状态及 `reference-player/native-reference-46092.json`。

用户已报告独立 `/opt/homebrew/bin/mpv` 播放同一 Mystery Box 也卡顿；已绑定其 mpv 0.41.0 / libplacebo 7.360.1 / FFmpeg 9.0.2 和配置。其目标PQ与产品线性EDR路径不同，不能唯一归因libplacebo，亦不替代最新产品验收。

## 1. 启动前清场

1. 关闭当前 PiliPlusX、Runner 和临时测试应用。
2. 检查进程，只保留后续要启动的本次候选应用：

   ```sh
   pgrep -alf 'PiliPlusX|Runner'
   ```

3. 如果发现多个实例，先停止全部旧实例，再从唯一绝对路径启动所选候选应用。
4. 不要通过 Spotlight、Dock、最近使用项目或模糊应用名启动，避免打开旧副本。
5. 启动后确认窗口标题/应用路径属于上述所选配置的 `.app`。

## 2. 搜索目标 BV（固定输入动作）

1. 打开应用搜索页。
2. **先用坐标点击搜索输入框本体**，不要直接依赖 `set_value`。输入框位于窗口顶部；按当前截图定位输入框中部，避免复用其他窗口或像素比例下的旧坐标。
3. 执行全选并输入：

   ```text
   BV1vY4y1N7TY
   ```

4. 读取界面状态，确认搜索框的实际文本已经变成 `BV1vY4y1N7TY`。
5. 如果全选未清掉旧文本，不能点击搜索；点击输入框右侧清除按钮，确认实际输入框为空后重新聚焦并输入。2026-10-03 已复现 Flutter 输入框 `setValue` 只改变语义、全选输入却追加旧文字；必须以实际显示文字核验，不能只依赖 AX 值。
6. 只有在状态读取确认文本正确后，才点击搜索按钮。

## 3. 目标条目确认

搜索结果必须同时满足：

- 标题：`蹲守一周，我终于拍到了夕阳下的梦幻场景｜北海道VLOG | Links  4K HDR`
- BV：`BV1vY4y1N7TY`
- 作者：`Linksphotograph`
- 时长约 `19:31`

点击该条目的封面/标题进入播放页。若结果不满足上述条件，停止记录，不得把其他视频当作 DV 样本。

## 4. 播放与证据采集顺序

按以下顺序连续执行，不在中间改变路线：

### 控制条操作硬规则

- 控制条、设置菜单和进度条都是自动隐藏的短时 UI；不得把“唤出、截图、识别、再点击”拆成多个交互回合。
- 每次操作必须在同一个连续调用中完成：安全唤出控制条 → 重抓当前布局/目标 → 点击目标 → 读取状态复核。
- 不要在唤出与目标点击之间拆分调用、长时间等待或切换焦点；目标必须来自同一连续调用内的最新布局。
- 如果一次操作失败，重新在同一连续调用中唤出并完成整组动作；不要拿已经收起的旧坐标继续点击。
- Computer Use 的 AX 操作参数使用 `element_index`；不要写成 `element`。若使用坐标，必须以刚才同一截图的窗口坐标为准，并在连续调用结束后才读取结果。

1. 等待视频出现稳定可见画面，记录页面截图。
2. 记录页面标题、BV、时长、当前播放位置和页面 HDR 标签。
3. 打开产品的解码/播放信息入口，记录“当前解码格式”以及是否显示 VideoToolbox、HEVC、P010、HDR/Dolby Vision 等信息。
4. 同时采集应用进程日志：

   ```sh
   log show --style compact --last 5m \
     --predicate 'process == "PiliPlusX" OR process == "Runner"'
   ```

   只把与当前播放时间相符的日志作为证据。
5. 记录 native output 状态：播放器是否 ready、实际视频帧是否绘制、输出色彩空间/EDR/headroom 是否存在。
6. 记录结果时分成三层：

   - 页面层：目标页面和 HDR 标签；
   - 解码层：实际 codec/pixel format/decoder；
   - 输出层：实际 native surface、色彩空间、headroom 和可见帧。

## 5. 失败分支

- 搜索框没有文本：回到第 2 步，不继续点击搜索。
- 搜索结果没有目标 BV：检查是否误启动旧应用或搜索文本错误，不能改用推荐视频替代。
- 页面有画面但没有解码信息：记录为“产品播放可见，解码证据不足”，不要推断为 DV 已解码。
- 只有日志显示 HDR/DV、没有可见帧：记录为“日志提示，显示未验收”。
- 有可见帧但输出仍是普通 SDR：记录为“播放成功，HDR 输出未成立”。
- 出现第二个应用实例：立即停止本轮，清场后从第 1 步重来。

## 6. 结论模板

```text
样本：BV1vY4y1N7TY
页面确认：通过/失败
实际可见播放：通过/失败
解码证据：未采集/HEVC + VideoToolbox/其他
DV/HDR 输入证据：未确认/确认（注明来源）
native 输出证据：未确认/确认（注明色彩空间、headroom、visible frame）
最终结论：只能确认到页面层/解码层/输出层
限制：
```

## 7. 与 OHOS 的隔离

本 SOP 的 macOS 结果不能证明 OHOS 支持或不支持 DV/HDR。OHOS 仍按其独立结论处理：模拟器仅软件解码、仅 RGBA 显示；OHOS 的 libmpv、HAP、设备和显示证据不得混入本记录。

## 4K60 SDR 对照补充

- 用户指定 `BV1heam6TExz` 时，选择 4K，并从播放信息确认 3840×2160、实际 decoder 和色彩参数；不要用 1080P 60帧菜单项代替 4K，也不要用前一段 30fps HDR 的结果代替本次测试。
- 固定视频、起始位置、窗口尺寸、倍速、诊断配置和构建模式。分别保存播放状态与生产/消费/呈现证据，剔除暂停、seek、缓冲、尾段及切换窗口。
- SDR `floatEnabled=false / surfaceActive=false` 时，可见画面走 Flutter Texture。隐藏原生视图的 Metal completed 或 drawable presented 不能代表屏幕呈现；生产约60帧/s也不能证明没有卡顿。Flutter `copyPixelBuffer` 消费次数仍不是显示器呈现次数。
- 最新 SDR guard 仅跳过隐藏 native 绘制：允许 `floatEnabled || surfaceActive`，以保留 HDR 首个 float 帧的激活路径。需运行验证 SDR native enqueue 不增长、Texture 画面持续推进，以及 HDR 首帧激活和 HDR→SDR reset。用户实屏观察决定可见流畅性是否验收。
- Mac 锁屏时停止 UI 验收，撤销临时诊断环境；待人工解锁后重查运行进程与候选身份。构建/日志校验通过不能替代本段运行验证。

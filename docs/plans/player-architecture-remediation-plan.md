# 播放器架构整改实施记录

更新时间：2026-09-14

本轮按 OHOS 实机问题优先，修正共享交互、输出生命周期和状态所有权；macOS 仅做回归，不迁移既有线性 EDR 色彩实现。

> 说明：本文件前部的“当前验证边界”、旧 HAP 和“等待下一轮协议设计”段落保留为
> 2026-09-09 早期阶段记录；随着文档末尾的追加记录推进，后文的最新 artifact 和验证
> 结论优先，不能把早期的“未执行”状态当作当前状态。

当前有效索引（2026-09-13）：embedding epoch/ownerSeq、全屏请求队列、HDR consumer recovery、
方向事务等待、脚本化布局点击、竖屏播放器/推荐列表手势边界和 process-live 证据链已落地。
当前实体机已有 `2.1.3 / 2026091325`（r25 诊断开关包）；DV、PQ、SDR 各自的方向/帧进展短周期门禁以及
竖屏/横屏手势正反向探针已有证据。HLG/HDR Vivid 因当前候选实际均被识别为 PQ，按用户决定
暂缓并记录待办。颜色仍需同源同帧实屏对照；surface 丢失后的 SDR 恢复、过期输出 fallback
和 OHOS native fullscreen 对称清理刚完成代码收敛，必须在新包上复验；旧 pointer Cancel
与新 attachment 同进程重建仍未形成完整通过证据。正式交付前不恢复生产包、不提交 Git，且
必须保留这些门槛的独立 verdict。

补充：播放器内竖滑与播放器下方推荐列表竖滑必须作为相反边界断言；两个实机脚本均支持
`--hap` 显式绑定候选包，避免测试误用设备上的旧包。当前实体机 HDC 仍未恢复 Online，
因此本项脚本改动尚未形成新一轮实机 artifact。

## 已落地的代码边界

- 触控：视频手势在加入 arena 前做资格判断；单指方向只决策一次，拒绝后安全退出；单指与双指统一由播放器 scale recognizer 仲裁。
- 生命周期：输出重建保留真实 `await disposeForRebuild()`；OHOS controller 共享 dispose Future；旧 resize/config 使用 generation/revision 失效；过期 native surface destroy 不得恢复旧 Texture。
- HDR 参数：OHOS 应用层只负责策略和 configure/reset 入口；OHOS media-kit 后端唯一写入 mpv target 参数。生产环境关闭延迟诊断重放（默认 0）。NativeWindow 动态 ColorSpace/metadata/brightness/white-point 由 mpv VO 唯一写入；FFI 仅保留 format/gamut/source type 等静态 producer 配置，不直接写动态输出属性。
- 全屏：方向、系统栏和桌面全屏调用等待成功后才更新状态；失败允许重试；全屏请求不再在 `finally` 中伪造成功。
- 验证脚本：所有 UI 操作通过当前布局解析；支持 `--cycles` 完整进出轮次；播放证据区分 playing、paused、buffering、unknown；未知版本弹窗动作 fail closed；颜色结论保持 inconclusive，不能用 JPEG 差异冒充 HDR 通过。

## 当前验证边界

已通过 Flutter analyze、触控针对性测试、Python 编译、OHOS 脚本语法/帮助检查及多个工作树的 diff 检查。此前缺失的 native 交叉编译和 HAP 产物身份链路已在 `dev` 补齐；OHOS 实机播放/全屏压力测试及 macOS 回归仍未完成。

2026-09-09 再次探测 `dev` 时，SSH 到 `172.24.136.84:1040` 超时；本机也未发现可用的 OHOS SDK/交叉编译器。因此 native 编译和实机验收仍是明确未执行项，不将本地 emulator TCP target 或历史 HAP 记录计入本轮通过。

同日 `dev` 恢复后先完成一次旧依赖的远程 debug HAP 构建，随后修正 OHOS SDK 不提供的 `NATIVEBUFFER_COLOR_GAMUT_NATIVE` 兼容性和补丁幂等性，并在 `dev` 完成 patched `libmpv` 交叉编译。新的 `libmpv.so` SHA-256 为 `2c4d1fae1d54975811be2717d2ec9d0dce1611643198992b9e8bd0b75364e3a6`，ZIP SHA-256 为 `dfdf3a238acdeb50bb91c89a317adaf2fcf44d51df8220ecfa8462ae768051df`；签名 HAP 为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-architecture-20260909-native-diagnostics-signed.hap`，HAP 内 `libmpv.so` 与该 `.so` 哈希一致，并包含 `OHOS target mapping`、`OHOS color hint after set_color` 诊断字符串。该 HAP 已安装并启动于本地 `aarch64` emulator，仅计入部署/启动烟测，不计入实机 HDR 验收。

实机验收必须继续覆盖：持续播放中至少 20 个完整全屏进出轮次、暂停对照、SDR/PQ/HLG 双向切换、竖屏视频主体唤出控制条、旧 surface 事件和重建；没有当前 surface 的呈现证据时状态只能是 unknown。

2026-09-09 architect 终审指出并由 Luna 完成首轮 P1 修复：native surface 的 creation generation 现在由 Flutter creation params 传入 ArkTS，并随 ready/destroy 回传；ready/destroy 在副作用前校验 view/surface/generation；HDR reset 按 surface identity 与成功模式去重，surface 暂不可用时仍先恢复 SDR target；dispose 先停止 mpv VO，再释放 Texture，原生释放异常上抛。Flutter 手势同时修正为全局坐标计算位移，并让资格判断与业务执行使用同一按下位置。

该轮修复已通过 media-kit P1 contract test、目标 Dart analyze/format、PiliPlusX 手势测试/analyze 和 diff 检查；ArkTS/hvigor、真机 destroy/recreate、播放中全屏及 PQ/HLG 可见输出仍未验证。HDR 白点属性的唯一写入者、format/gamut 的停止/初始化边界仍需后续独立处理或在真机日志中确认，不能把本轮 patched HAP 启动当作已解决。

P1 修改后重新生成的签名包为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-architecture-20260909-p1-signed.hap`，HAP 内 `libmpv.so` 仍与 patched native 产物一致（`2c4d1fae1d54975811be2717d2ec9d0dce1611643198992b9e8bd0b75364e3a6`），已在本地 `aarch64` emulator 安装并启动。该结果只证明构建、签名、依赖身份和启动链路，仍不替代物理设备的呈现与触控验收。

实现后终审仍保留下一轮门槛：正常 `Player.dispose` 与输出释放的协议、mpv property 返回码、HDR 白点唯一写入者及 producer 停止边界；ready 后 pending HDR 重放的 config revision；原始触控按下点到业务回调的贯穿；全屏请求合并与部分成功恢复。以上项目已交给 Luna 分成 media-kit 与 PiliPlusX 两个互斥工作集继续落实，完成前不进入正式实机结论。

最新终审（2026-09-09）确认：generation/reset/dispose 的基本方向正确，但上述 3 个 P1 和 3 个 P2 仍未闭环。两项 Luna 后续任务均按安全边界暂停：media-kit 任务发现需要同步修改 `NativePlayer`、OHOS VO/FFI 和 native build 的跨仓库协议；PiliPlusX 任务只产生了未接入的 recognizer 半成品，已清理恢复为可编译的当前实现。当前状态因此是“代码/产物证据已增强，架构终审未通过，等待下一轮跨层协议设计”，不进入正式实机验收。

## 后续硬门槛

1. 用实际 patched `.so`、ZIP、HAP 和运行时加载库完成身份链路验证。
2. 运行真机脚本并保留“已验证／失败／未执行”记录；网络缓冲、HDC 断线或无呈现证据的轮次不计入通过样本。
3. 实机与 macOS 回归完成、architect 独立终审通过前，不提交 Git，不宣称灰屏问题已解决。

## 2026-09-09 candidate 绘制闭环修复

实体机诊断脚本确认 PlatformView factory 已创建，但没有出现
`OhosNativeSurface.onLoad` / `nativeSurfaceReady`；同时 Flutter 持续报告
`No DlImage available for ImageExternalTexture`。architect 复核指出 OHOS candidate
在 `nativeSurfaceActive=false` 时被 `Opacity(0)` 完全跳过 paint，形成“ready 依赖
绘制、绘制又依赖 ready”的闭环。

Luna 在 sibling `media-kit` 工作树中完成单变量修复：OHOS candidate 保持有效尺寸并
参与 paint，Texture 仍位于其后作为 inactive 视觉回退；没有放宽 capability probe、
伪造 active/ready 或改变 VO/HCPP/解码策略。新增 candidate 静态契约测试，并通过
相关 contract tests、format、analyze 和 diff-check。

新的签名候选为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-architecture-20260909-candidate-opacity-fix-signed.hap`，
HAP SHA-256 为 `889a5d45ac3e407d11012d22f07b4822b8f23f2f758a1f06a65c05097afe1d48`；
已在 `dev` 完成源码同步、远程 Hvigor 构建、签名和 verify-app。

按要求先做模拟器测试，但 `dev` 上启动的 ARM64 模拟器 HDC 仍为 `[Empty]`，容器日志
显示缺少 `/dev/usb-ffs/hdc` USB gadget 能力；本机也无在线模拟器目标。因此本轮只
计入构建/签名，不计入模拟器安装、启动、播放或 Surface 生命周期验证。模拟器恢复
HDC 后，第一检查项必须是 `onLoad → nativeSurfaceReady → nativeSurfaceActive`，
再进入 HDR/全屏测试。

candidate 修改后的独立 architect 复核结论为：可以继续进行首次单变量诊断，不需先
修改 capability probe、VO 或 HCPP 选择；但该修改本身尚未证明 ready、首帧、overlay
或 HDR 输出。ready 后仍需单独检查：inactive Texture 是否实际有帧、candidate 外层
decoder 尺寸与内层 viewport 尺寸是否造成几何跳变，以及 surface destroy 后由哪个
owner 重新建立 candidate。上述项目不得用静态契约测试替代实体机证据。

## 2026-09-09 后续修复与当前门槛

实现后复核发现旧 P1 尚未全部闭环，Luna 随后按互斥工作区完成第二轮修复：

- media-kit：破坏旧 VO 前清除已应用模式；HDR 配置失败后显式恢复 SDR，并强制后续 reset 重启 VO；release property 仅在实际 release 生命周期开放；补充 SDR→HDR 失败→SDR 恢复契约测试。
- PiliPlusX：全屏请求队列抽离为独立文件；异步系统栏/方向步骤在 await 前后检查生命周期；销毁时取消排队请求并等待当前平台步骤收束；新增等待中销毁测试。
- native build：重新生成颜色契约补丁，移除 `if (0)` 表面禁用；OHOS VO 是 HDR/SDR white-point 唯一写入者，resize/reconfigure 同时失效两类缓存；checker 要求源码、补丁和 FFI 边界一致。

验证结果：手势 5/5、全屏队列 3/3、PiliPlusX 定向 analyze、media-kit contract/analyze、native checker、三个工作树 diff-check 均通过。macOS 主机的 media-kit 全量测试仍不能加载 OHOS 专属 `OhosView*` 类型；全屏队列已隔离后可独立运行。

native bundle 在 `dev` 重新构建并通过 fail-closed contract checker；ZIP SHA-256 为 `dd975746ae3610e4fb738d79962fb9a9babb5527b225cb2557297b2c5c7c583e`，其中 `libmpv.so` SHA-256 为 `175f5ec56efc99a44bba297fd0562dd62a9fb8697d92c88913688e836c2921d3`。签名 HAP 为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-architecture-20260909-final-p2-signed.hap`，HAP 内嵌库与该 SHA 一致，并包含 `owner=ohos_vo`、HDR/SDR white-point attempted/result/valid 诊断字段。该 HAP 已安装并启动于 `127.0.0.1:5555` 本地 emulator，仅证明部署/启动，不证明实体机呈现、HDR 或触控。

旧 HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-architecture-20260909-final-p1-signed.hap` 不再是当前候选；native 契约变化后必须使用 p2 HAP。最终 architect 复核和实体机脚本验收仍未完成，当前不能宣称灰屏/亮度、HDR 可见输出或触控问题已解决。

## 2026-09-09 p5 收口状态

后续复核发现并修复了同一 owner 的最后一个销毁收尾缺口：方向恢复和系统栏恢复现在是独立、带 owner 校验的尝试；方向失败不会跳过系统栏恢复，cleanup 使用 in-flight 状态，失败后允许重试。全屏队列、owner、手势测试共 12 项通过，定向 analyze 无 error，diff-check 通过。

最终候选为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-architecture-20260909-final-p5-signed.hap`，HAP SHA-256 为 `11ec35f24c540119dece0deb0d8ec315ea8d881c71ed890c20824b90052c4ed2`；包内 `libmpv.so` SHA-256 仍为 `175f5ec56efc99a44bba297fd0562dd62a9fb8697d92c88913688e836c2921d3`，与 dev bundle 一致。p5 已安装并启动于 `127.0.0.1:5555` emulator，仅证明部署/启动链路。

当前可以使用 p5 进入实体机脚本的诊断试跑；正式验收仍需真实物理设备的呈现证据、SDR/PQ/HLG 双向切换、连续全屏轮次、竖屏视频主体触控、surface 销毁重建和 macOS 回归。不能把 p5、模拟器启动、JPEG/整屏变化或静态诊断字符串单独宣称为 HDR 正确呈现、灰屏/亮度问题解决、触控稳定或生命周期压力通过。

2026-09-09 candidate 绘制修复后的本地复核再次通过：native OHOS HDR lifecycle/color
contract、candidate/platform-view/P1 contract tests、media-kit diff-check、OHOS
preparation Python 编译及实机脚本帮助检查均通过。上述结果只证明源码与候选构建契约
一致；因 HDC 目标缺失，仍未产生新的运行时呈现证据。

同日用户手工启动 Emulator 后，本机目标 `127.0.0.1:5555` 恢复在线，架构为
`aarch64`。使用 opacity-fix 候选 HAP 和 `verify_hdr_real_device.sh` 完成安装、启动、
搜索、打开视频以及自动化唤醒控制条流程；但首次模拟器试跑在
`08-fullscreen-stable` 处停止。独立 architect 复核 `06-controls.json` 与对应截图后
确认：控制条并未出现，原布局解析器的最后兜底误选了推荐视频菜单的“更多”按钮，
所以 portrait 不能作为应用全屏回归证据。

已收紧 `tool/ohos/ohos_ui_layout.py`：当全屏语义节点和播放器结构条件均不存在时，
现在返回 `fullscreen button not found`，不再点击任意右下角节点；用本次
`06-controls.json` 离线反例验证返回码为 1，并通过 Python 编译和脚本帮助检查。
本次日志还确认模拟器在 `OhosVideoController.create` 前触发
`VideoController does not support emulator`，因此 opacity candidate 尚未进入
`factory → onLoad → nativeSurfaceReady → nativeSurfaceActive` 路径。模拟器运行结果
仅计入“脚本安装/启动/播放页面可达、错误目标被 fail-closed”，不计入 Surface、HDR、
全屏或触控验收；下一步应先在实体机用同一候选验证 Surface ready 链路。

随后进一步收紧脚本：控制条唤醒后先要求布局中存在可见 Slider 或明确的全屏语义节点，
否则记录 `controls-presence-failed` 并停止，不进入任何全屏点击。当前模拟器的同一份
`06-controls.json` 已验证返回 `video controls not exposed`；该检查只约束测试前置条件，
不把模拟器的 emulator guard 或渲染错误转化为播放器功能结论。

实体机重新连接后，使用同一候选在 `2PM0223A18006914` 完成首轮运行。运行日志确认
`OhosNativeSurface` 的 create/onLoad、`nativeSurfaceReady`（`viewId=0`、
`generation=1`）和 attach 均发生；随后确认
`HDR decision output=nativeHdr surface=native-hdr nativeOutputActive=true`，并取得
PQ 数据空间应用及 Dolby Vision 转 HDR 的运行时诊断。这证明当前候选已实际进入
Surface/HDR 决策链路，但不等于 HDR 主观亮度或色彩验收通过。

同一轮中视频画面可见，但播放区唤醒后控制条仍未出现在布局/截图中；脚本因此在
`controls-presence-failed` 停止，未执行全屏点击。该结果把问题进一步定位到
“native surface 播放可见 → Flutter 控制层触控/overlay 可达”边界，保留为下一轮
触控修复输入；不得用这轮 HDR ready 证据覆盖控制条失败，也不得因控制条失败回退或
修改 HDR 输出策略。

## 2026-09-09 HCPP 触控边界复核

最新触控试跑在实体机上记录到：全局 `pointerRouter` 能收到真实 down/up，
但 `MouseInteractiveViewer` 的 `Listener`、播放器 `_onPointerDown` 和
`_onTapUp` 均没有日志；将透明交互层改为 Video 的 Stack sibling 后结果仍相同。
因此，当前证据不支持继续调整手势阈值，也不支持把问题归因于 HDR/native surface
绘制层。

architect 独立复核确认 HCPP 的 DISPLAY 原生视频层位于 Flutter 主 surface 之上；
Flutter 树中的透明 Listener 不保证产生可接收触摸的 ArkUI overlay。现有 embedding
已有 `FlutterOverlayBlock -> dispatchTouchToEngine -> PointerDataPacket` 通路，但
overlay rect 目前来自 SliceViews 的绘制区域，绘制范围与输入范围仍有耦合。架构约束
现明确为：播放器拥有 viewport 和 gesture arena，media-kit 只声明 native output
及生命周期，OHOS embedding 负责唯一命中区域、坐标转换、目标 Flutter view 和完整
pointer 转发，native surface/libmpv 只负责 HDR 视频绘制；输入入口不得随控制条显隐、
弹幕或 overlay 像素变化而消失，不得重复注入同一触摸，也不得通过关闭 HDR、切换
Texture 或近乎透明色块制造 workaround。

下一步先补充一次失败 down 的完整证据：实际 HAP 使用的 embedding 版本、原生入口、
window/local 坐标、DPR、Flutter `viewId/device/position` 以及 Listener bounds。只有
当证据确认是原生入口覆盖缺口，才做单变量的局部输入 block A/B；必须验证一套真实
down/move/up/cancel 能进入现有 gesture arena 且只触发一次控制条。不得直接把 block
扩展为全 viewport，也不得全局修改主 XComponent 的 `HitTestMode.Default`。

另记录部署边界：远端 `flutter-ohos` 工具链源码已有 HCPP wrapper 转发实现，但构建
使用的 `oh_modules/@ohos/flutter_ohos` 是独立展开副本；后续必须从实际 HAP 的版本和
源码映射确认部署内容，不能把工具链源码的修复视为已运行。当前实体机结果仍是
“视频可见、HDR native decision 已进入、播放器触控未达 Listener”，架构终审及正式
实体机验收均未通过。

## 2026-09-09 触控诊断字段与模拟器复核

Luna 完成了只读诊断增强：播放器触控 trace 现在记录 Flutter `viewId`、`device`、
`position/global` 坐标，并在布局完成后安全采样 Listener/viewport 的 RenderBox
尺寸与 global bounds；未改变手势、HCPP、native surface 或 HDR 逻辑。相关单测 8/8
通过，定向 analyze 无 error，diff-check 通过。

诊断 HAP
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-touchtrace-bounds-signed.hap`
已完成源码同步、远端构建、签名和 verify-app。先按要求安装到
`127.0.0.1:5555` ARM64 模拟器并运行脚本：安装、启动、搜索和视频页可达；但该模拟器
仍在 `OhosVideoController.create` 前被 emulator guard 拦截，控制条没有暴露，脚本在
`video controls not exposed` 处 fail-closed，未点击全屏。该轮不计入 Surface、HDR、
触控或全屏验收；也没有产生可用的 PlayerTouchTrace/Listener 运行时样本。

HAP 的 source map 显示实际打包的 embedding 依赖为
`@ohos/flutter_ohos 1.0.0-8dff183bbd7`。仍需继续核对该展开副本是否包含 HCPP wrapper
转发实现，再以实体机重新执行带 bounds/viewId 的诊断脚本；在此之前不直接扩大 block
或修改主 XComponent 命中模式。

## 2026-09-09 HCPP 输入 block A/B 的架构约束落地

根据上述失败 down 证据，HCPP A/B 只在 OHOS embedding 增加与 DISPLAY 几何一致的局部
透明输入 block；不修改 native surface、libmpv、HDR 策略、主 XComponent、Dart 播放器
或 gesture arena。当前约束及实现细节单独记录在
`flutter-ohos-e3/docs/platforms/ohos-hcpp-input-block.md`，本节保留主计划的验收边界。

- `DynamicView` 不再为 HCPP 安装第二个 touch/axis dispatcher；DISPLAY 的输入入口只能
  是局部 input block，overlay XComponent 仅用于合成且为 `HitTestMode.None`。
- input/overlay rect 按 platform view id 使用稳定节点 identity；几何更新不得因坐标变化
  重建活动节点，也不得让控制条、弹幕或 overlay 像素变化移除视频输入入口。
- Down 建立 `pointerId -> platformViewId` owner；Move/Up/Cancel 必须沿同一入口转发，
  隐藏、detach、dispose、restart、zero rect 或 end-frame 缺失前先发送 Cancel，再清理
  storage。不可重复注入，也不可把 platform view id 错写进 PointerData 的 `view_id`。
- block 只能覆盖实际 DISPLAY 视频矩形，不得扩展为全 viewport，不得修改主 XComponent
  的全局 `HitTestMode.Default`，不得通过关闭 HDR、切换 Texture 或透明色块绕过边界。
- 生产路径不能依赖 `onBeginFrameHybrid` 清理状态；必须验证 window/local 坐标、DPR、
  fullscreen/safe-area 变化，以及实际 HAP 中展开的 embedding 版本和源码映射。

当前已通过 embedding 静态契约检查；Hypium/ArkTS 编译和实体机输入验收仍需实际工具链
及签名 HAP。正式通过的最低证据是实体机在视频播放中完成 down/move/up/cancel、控制条
重叠区域、拖拽、双指/取消、detach/recreate，并确认每个手势只进入一次 Flutter arena，
同时保持 native surface/HDR 回归证据。静态检查或模拟器启动不能替代这些证据。

## 2026-09-09 HCPP 产物链约束与模拟器结果

本轮验证补充了一个必须独立满足的构建约束：embedding 源码、生成 HAR、ohpm 展开副本
和最终 HAP 的 ABC 必须是同一版本。工具链源码中出现 `HcppInputRect` 不代表运行时已经
使用该实现；实际 HAP 的 `ets/modules.abc` 必须同时包含 `HcppInputRect` 和
`hcpp_input_rects_map`。此前的 `ab2`、`diag` HAP 虽然源码目录已经有 HCPP 修改，但其
ABC 仍只包含旧的 `hcpp_overlay_rects_map`、`touchDispatcher` 和 `axisDispatcher`，因此
不得作为 HCPP 触控结论依据。

具体约束如下：

- embedding HAR 必须先由修改后的 OHOS embedding 源码编译；不能只复制 ETS 源文件，
  也不能把源码 SHA 当作运行时版本证明。
- debug、release、profile 的 arm64 HAR 是独立消费路径，构建脚本必须覆盖实际模式对应
  的 HAR，并在 unsigned HAP 的 `ets/modules.abc` 上设置 fail-closed marker gate。
- 合并 HAR 时只替换 embedding 的 ETS/C++ 类型内容，保留原有 `libflutter.so` 和发布
  模块元数据；旧 HAR 必须留有可恢复备份。
- HAP 通过 ABC 门禁、签名和 `verify-app` 只证明产物身份与部署完整性；仍不能替代模拟器
  的可达性证据或实体机的 native surface、控制条、pointer owner 和 HDR 输出证据。

本轮实际生成的 embedding HAR 已通过 ArkTS/Hvigor 编译，合并后的实际 SDK HAR 包含上述
HCPP marker，应用构建生成的 unsigned HAP 也通过 marker gate，并完成签名和
`verify-app`。模拟器脚本随后安装并打开视频页，但日志明确记录
`VideoController does not support emulator`，`hcpp_input publish ... rects=0`，控制条
未暴露，脚本在 `video controls not exposed` 处 fail-closed；因此该轮只证明 HAP 身份、
安装、启动和错误前置条件处理正确，不计入视频播放、HCPP 输入、全屏或 HDR 验收。实体机
仍需使用同一份通过 ABC gate 的 HAP 完成正式输入与 HDR 回归。

## 2026-09-09 实机重复全屏复核与测试时序修正

使用可重复 HAR→HAP 构建脚本生成的
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-hcpp-input-repeatable-signed.hap`，在实体机
`2PM0223A18006914` 上完成了两组脚本验证：

- 播放中执行 3 个完整退出/进入全屏周期：方向校验通过，3 次播放推进证据通过，
  `nativeHdr/nativeOutputActive` 和 HCPP ABC/诊断门禁通过。
- 冻结同一帧后执行 3 个完整周期：方向校验全部通过，HDR decision evidence 通过；视频
  中心的 HCPP block Down/Up、`route=input`、Flutter Listener 和 `_onTapUp` 事件链均有
  成功样本。该组只作为同帧截图、几何和输入链的控制变量基线，不能用于暴露或排除
  “播放中切换全屏后变灰”的故障。

冻结帧截图的中心视频区域统计在初始全屏和 3 次重新进入全屏之间保持稳定：亮度均值约
`126.43–126.65`，RGB 均值变化小于约 `0.3`；退出到竖屏的同一帧统计也在各周期一致。
这只能作为当前截图 A/B 的支持证据，不能替代显示仪器或用户主观高光/颜色验收，因此
脚本仍保留 `color verdict: INCONCLUSIVE`，不把 HDR 日志或截图单独宣称为亮度问题已完全
解决。

第一次冻结复核曾在第二周期使用了过期的控制条 layout bounds：截图耗时期间控制条滑入
动画改变了全屏按钮位置，旧快照点击点落在新按钮范围之外。architect 复核确认该失败不
足以证明 HCPP block 几何失效；失败事件实际走了 `route=overlay`，不是 DISPLAY input
入口丢失。现已修正 `verify_hdr_real_device.sh`：截图布局只作证据，点击前重新
`dumpLayout`，实际点击使用 `*-controls-click.json`；对初次唤醒和每个重复周期均适用。

因此当前边界是：HAR/ABC 产物身份、HCPP 事件链、控制条唤醒、重复全屏方向和冻结帧截图
一致性已有脚本证据；真实设备主观 HDR 亮度/色彩、更多触控手势矩阵、页面退出重进和
前后台/销毁重建压力仍需按本计划继续验收。不得把本节的流程通过误报为全部交付完成。

## 2026-09-09 synthetic Cancel 时间域修正与 20 周期冻结复核

最终架构复核发现，HCPP 正常 Down/Move/Up 使用 ArkUI 事件时间戳（纳秒域），而隐藏、
detach 或销毁时补发的 synthetic Cancel 曾使用 `Date.now()`（Unix 毫秒域）。两者混用会
破坏同一 pointer owner 链的时间单调性，尤其可能在快速全屏、窗口重建或取消场景中制造
难以复现的输入异常。现已改为从该 view 的活动 pointer 中取最近 ArkUI 时间戳，并在同一
时间域内追加极小的去重间隔；静态 HCPP contract 重新通过，新的签名 HAP 也通过 ABC
marker gate、签名和 `verify-app`。

同一实体机上，冻结帧脚本已完成 20 次退出/进入全屏周期，20 次方向校验全部通过，HDR
decision evidence 通过，最终仍明确记录 `color verdict: INCONCLUSIVE`。这只证明控制变量
场景下没有出现脚本可见的方向或控制条失败，不能证明播放中的颜色稳定，也不能替代故障
复现。按照历史故障条件，只有持续播放中的全屏切换才计入灰屏/变灰回归；播放中 20 周期、
触控手势矩阵、生命周期压力或主观 HDR 亮度验收仍未关闭。

产物身份目前已能由最终 HAP 的 SHA、`modules.abc` 中的 HCPP markers 和 native library
SHA 复核；但 embedding 源码、远端生成 HAR、展开 ohpm 副本与最终 ABC 的逐级 hash 清单
仍需进一步固化到每次测试 artifact，避免只凭固定路径或单一 marker 推断精确源码版本。

## 2026-09-09 播放中全屏测试边界修正

用户复核确认：历史“播放中切换全屏后变灰”在冻结帧条件下无法复现。因此冻结帧测试的
结论严格降级为控制变量基线，只用于采集同一帧的截图、方向、几何、HCPP 输入链和 HDR
decision 证据；它不能暴露、排除或证明播放中颜色变灰问题。灰屏回归的有效条件必须是
持续播放，且每个有效样本都要保留播放状态或独立的视频主体帧进展证据。

同日使用修复版 HAP 开始播放中 20 周期测试。第一轮完成第 12 周期前的方向切换，期间
视频主体裁剪区持续出现帧变化；但第 12 周期退出后 HDC `dumpLayout` 连续失败，整轮
标记为无效，不计入 20 周期通过。第二轮因重新安装 HAP 前实体机已变为 `USB Offline`，
HDC 目标消失，未执行，不把模拟器替代为实体机证据。

测试脚本现将两类证据分开：默认仍要求 layout 中的语义 playing 状态；显式设置
`VERIFY_ALLOW_VISUAL_PLAYBACK=1` 时，若语义按钮不出现在 OHOS layout，则只接受排除
控制条/时钟的中央视频裁剪区帧变化，并将结果标记为“semantic state unavailable”，不
伪装成语义 playing 通过。Slider 的百分比文本也会保留为位置证据。该模式用于在 native
surface 的无障碍树不完整时继续采样，但最终播放中 20 周期仍需实体机连接稳定且无 HDC
观测失败的完整轮次。

补充验证：中央视频裁剪帧差、Slider 百分比解析和 OHOS 脚本语法检查均已通过；media-kit
三个独立 OHOS contract probe 也通过。重新运行模拟器脚本后，HAP native diagnostics 门禁
通过，但视频页记录 `video controls not exposed` 并拒绝全屏点击，符合模拟器不支持
`VideoController` 的 fail-closed 边界。当前 HDC 目标只有 `127.0.0.1:5555`，实体机
`2PM0223A18006914` 已离线；因此播放中 20 周期必须待实体机恢复后继续，模拟器结果不替代它。

构建脚本新增并实际生成了签名产物清单
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-hcpp-input-cancel-fix-signed.hap.manifest.txt`：
本次 HAP SHA-256 为
`766e97e3141d8c25bd28255350bc1830d782ba18bfae61174e701f908c396198`，ABC SHA-256 为
`5672930a62f11cad09b5aff9de159964a7cce2eeed1fc97c537bb360340fefbb`，并记录
`libflutter.so`、`libmpv.so`、HCPP marker 和 `cancelTimestamp` marker。该清单补强最终
产物身份，但不替代源代码→HAR→展开副本的逐级 hash，也不替代实体机播放验收。

随后重新执行播放中 20 周期：脚本先将恢复的片源通过当前 Slider seek 到 `0%`，避免从
历史末尾位置开始导致视频自然结束；第 1 至 17 周期均保持视频主体帧变化，方向退出/进入
校验通过，未见灰屏。第 17 周期进入全屏点击后，OHOS `uitest dumpLayout` 服务卡死，
原脚本的单次 HDC 调用没有超时保护，整轮因此无效。现已为每个 HDC 调用加入可配置的
60 秒单次超时（`VERIFY_HDC_COMMAND_TIMEOUT`，可按需覆盖），超时只进入既有 retry/fail-closed 路径，
不会无限等待控制条。该轮仍不能计入完整 20 周期，必须在 HDC 观测稳定时重跑。

## 2026-09-09 播放中 20 周期有效完成

清理冲突的旧 `uitest start-daemon singleness` 后，使用同一签名修复版 HAP、同一片源并
先 seek 到 `0%`，重新完成播放中 20 个完整退出/进入全屏周期。有效 artifact 为
`/tmp/piliplusx-ohos-verify-20260909-171201`：

- `cycle-1` 至 `cycle-20` 全部完成；退出方向 `portrait` 20/20，进入方向 `landscape`
  20/20。
- 20/20 播放采样都记录了排除控制条和时钟的中央视频主体 `frame=changed`；部分采样的
  无障碍树没有暴露播放按钮，因此按脚本约定标记为 `semantic state unavailable`，不冒充
  语义 playing。第 19、20 周期同时有 `before=playing after=playing` 样本。
- HAP native diagnostics、HDR decision evidence、HCPP 日志均通过；本轮没有观察到灰屏。
- `color verdict` 仍为 `INCONCLUSIVE`，因为截图帧差不能替代同源同帧的显示仪器或主观
  高光/颜色验收。

这轮满足“持续播放中 20 次全屏进出”的回归门槛，但不关闭 SDR/PQ/HLG 双向可见输出、
竖屏主体触控矩阵、surface destroy/recreate、前后台压力和 macOS 回归等其他计划项。

## 2026-09-09 持续触控期间 surface 重建实验

使用 `tool/ohos/verify_surface_recreate_real_device.sh` 在同一实体机上完成了两段连续播放
验证：先建立播放中全屏基线，再从横屏视频区域开始 8 秒拖动，约 0.6 秒后执行
`aa force-stop`/`aa start`，最后重新搜索同源片段并完成一次连续播放全屏周期。artifact：
`/tmp/piliplusx-surface-recreate-20260909-r2`。

- 重建前后连续播放均有视频主体帧进展；两段全屏周期方向校验通过，HDR decision 通过，
  未把冻结帧结果计入灰屏结论。
- 日志显示旧进程 `46763` 被销毁，新进程 `48281`/`49622` 建立；重建后出现新的
  `nativeSurfaceReady`、新的 surface ID，并出现旧 surface `Cannot find surface`，可作为
  surface 销毁/重建的实机证据。
- 重建初期出现 `EGL_BAD_MATCH`、旧 buffer queue 找不到 surface，以及一次
  `output=toneMappedSdr`；随后同一重建链恢复到 `output=nativeHdr`、`nativeOutputActive=true`。
  这说明生命周期期间存在需要继续分析的短暂输出状态，不足以宣称 SDR/HDR 可见亮度稳定。
- 本轮没有采集到 Flutter 层 Down/Move/Cancel/Up 的成对事件，因此 pointer 终止链仍是
  未闭环项；不能据此宣称“按住期间销毁”已经安全。下一步应在 embedding 输入转发处加入
  可关联的 pointer id、时间戳和 Cancel 原因日志，并以旧 generation 拒绝迟到回调。

## 2026-09-09 HCPP 输入关联诊断首轮

使用包含 ArkTS HCPP owner/request 日志的 HAP
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-pointer-trace-signed.hap`，在实体机连续播放中
完成 1 次全屏进出，artifact 为 `/tmp/piliplusx-pointer-trace-verify-20260909`。本轮记录了
16 个 `hcpp_input stage=owner` 和 16 个 `stage=napi-request`，attachment epoch 为 1，事件
时间戳单调递增；Dart `PlayerTouchTrace` 也观察到对应的 Down/Up。

但最终 HAP 的 `libflutter.so` SHA 未变化，native NAPI 的
`HCPP_POINTER stage=napi-item`/实际 `DispatchPointerDataPacket` 日志没有随本轮部署。因此
本轮只证明 ArkTS owner 到 NAPI request、再到 Dart 可观察事件的链路，不能宣称已经证明 native
NAPI dispatch 成功。native engine trace 是归因增强，不应阻塞 ArkTS→Dart 端到端生命周期
验证；只有在 ArkTS 已提交 Cancel 而 Dart 未收到，或出现只能由 native 转换/目标 shell
解释的断点时，才把 native engine 重建提升为关键路径。下一步优先增加进程不退出的 hide
场景，验证恰好一次 synthetic Cancel、旧 attachment 的迟到事件被拒绝，以及新 attachment
能重新接收 Down。

force-stop/start 仅作为冷启动的 surface/进程身份控制变量；被杀死的旧 Dart 进程不应被要求
发送 Cancel，也不能用它暴露或排除“播放中切换全屏颜色变灰”。灰屏回归仍严格使用持续播放。

进程存活探针 `/tmp/piliplusx-process-live-exit-20260909` 前后 PID 均为 `54029`，但本轮
`Back` 没有形成可确认的页面 dispose/recreate 或 Cancel 事件，故不计入通过。探针下一版必须
先用语义布局确认播放器页和可退出路径，再验证 view dispose、attachment epoch 变化、恰好一次
Cancel、旧事件拒绝和新 Down；不能只以 PID 未变化作为成功条件。

随后将探针改为默认在两次 Back 前保持一条脚本化长拖动，并补充 `action=dispose` 与
`stage=cancel-request` marker。HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-pointer-trace-dispose-signed.hap`
的 `modules.abc` 门禁通过，且 `libflutter.so` SHA 仍为未重建的
`e5f127f6790674923d7ebfa746ba00f3e03b66b50111bf32a7bd74aef6d50162`。实体机在安装后掉至
HDC `USB Offline`，所以按住期间的 Cancel 仍未获得真机证据；模拟器不能替代该验收。

设备恢复后，使用同一 HAP 的 artifact `/tmp/piliplusx-process-live-exit-20260909-r7` 完成了
一次进程存活 page-exit 探针：PID 前后均为 `9053`，布局从全屏 Slider 变为首页，记录到
HCPP owner/request Down、Dart PointerDown、owner/request Up、Dart PointerCancel，随后
`action=dispose`。由于 Up 先于 dispose，未出现 `stage=cancel-request`；这不是 synthetic
Cancel 通过，而是说明当前 HDC/uiInput 序列仍无法让 dispose 与 active pointer 重叠。
下一步应使用应用/系统生命周期入口触发 hide/dispose，不再依赖同一 uiInput 服务的并发。

为保证诊断 HAP 的实际代码版本，`build_sign_hap_test.sh` 现同步临时 workspace 下所有
解析到的 `@ohos/flutter_ohos` 副本并清理生成 build 目录；新 HAP 的 ABC marker gate 已
通过。native engine trace 编译仍未完成：dev engine 缺少 Skia/依赖路径；这限制了 native
`DispatchPointerDataPacket` 的内部归因，但不阻止先验证现有 ArkTS Cancel 提交和 Dart
观察结果。

## 2026-09-09 process-live 钩子修正与当前边界

新 HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed-r2.hap`
已完成远端构建、HCPP ABC marker gate、签名和 `verify-app`。Dart 静态分析、相关
Flutter 单测、OHOS 脚本语法检查和 `git diff --check` 均通过。

此前的 app-side 一次性钩子在播放/全屏条件尚未满足时只可靠地重臂一次；同时一次
`Get.back()` 在全屏 `PopScope` 中只可能退出全屏，不能保证退出页面。现已改为：

- 每次真实 PointerDown 后持续检查“已播放且全屏”，不满足就继续重臂；
- 满足条件后先走正常 fullscreen back，再在 120ms 后走正常 page back；
- 不直接调用 HCPP Cancel，仍由正常页面/PlatformView dispose 路径产生生命周期事件。

同一 HAP 的连续播放基线 artifact `/tmp/piliplusx-process-live-test-baseline-20260909-r4`
完成 1 次全屏周期，视频主体帧有变化，HDR decision evidence 通过；该结果只证明诊断
钩子未破坏基本播放，不是生命周期或灰屏结论。

随后 r9 进程存活探针捕获了真实 Down/Up，但没有出现 `process-live-test` 触发或
页面 dispose；检查确认 r9 使用的是旧的一次性逻辑，不能计入通过。重新构建后的 r5
实体机基线因目标在安装前变为 `USB Offline` 而未执行，不能计为播放失败。

因此当前仍未关闭的唯一关键运行时证据是：在实体机 HDC 稳定时，用最新 r5 HAP 在持续
播放、全屏、PointerDown 保持期间完成正常全屏退出和页面退出，并观察恰好一次
`stage=cancel-request`、`action=dispose`、旧 attachment 隔离及新 attachment 的
Down。若实体机再次掉线，必须保留该轮为环境阻塞，不得用模拟器替代。

## 2026-09-09 architect 终审后的生命周期修正

独立 architect 终审否决了上一版诊断方案的三个不足：`Get.back()` 不能保证先退出
全屏，epoch 只是日志字段而非来源身份，脚本只按独立日志数量计数而没有关联同一
pointer/view。现已完成对应修正：

- app-side hook 改用生产中的 `PlPlayerController.onPopInvokedWithResult(false, null)`；
  先等待可观测的 fullscreen 状态退出，再请求页面 pop，不再依赖固定两次 `Get.back()`；
- `PlayerTouchTrace` 记录活动 pointer，生命周期动作只有在原 pointer 仍处于 Down 时
  才继续；pointer 已 Up/Cancel 或全屏退出超时则放弃本轮并重新武装；
- `HcppInputRect` 每个 attachment 使用新对象，ForEach key 包含 attachment epoch；
  ArkUI block 将不可变 epoch 传入 dispatch，dispatch 入口拒绝 stale attachment，并保留
  `activeTouchPointers.attachmentEpoch` 校验；
- external-hook 脚本按同一 pointer 关联 owner Down、page-pop、Cancel、同一 view/epoch
  的 dispose，并要求至少一个 Dart Cancel；只出现三条独立日志不再通过；
- process-live define 由 `kDebugMode` 双重限制，构建脚本拒绝在 release HAP 注入，避免
  诊断钩子改变生产行为。

embedding contract test 已加入 stale attachment 拒绝断言。最终诊断包
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed-r5.hap` 已完成
构建、ArkTS/HCPP marker gate、签名和 `verify-app`；manifest 中记录
`attachmentEpoch=1`、`stale-attachment=1`。release define 负向检查也返回预期的 code 2。

上述代码和产物证据仍不等于实体机生命周期通过：当前 HDC 仍只有模拟器，尚未取得 r5
在真实播放/全屏/活动触点下的 page-pop、Dart Cancel、dispose 和重建后新 Down 样本。

## 2026-09-09 r6 产物更新与当前剩余验收

契约检查器已更新到 epoch-aware 的 `hcppInputRectKey`/`hcppOverlayRectKey` 签名，并补充
`traceSeq`、`ownerSeq`、`stale-attachment` 断言；ArkTS 全触摸类型测试改为合法的
pointer-owner 序列。契约脚本通过，主工程 17 项针对性 Flutter 测试通过，静态分析、脚本
语法和 diff-check 通过。

最新可试跑产物为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-test-signed-r6.hap`，其
HAP SHA-256 为 `67bd8365b7df036bf7bf51d94393a9b6334dd7d7dde83ec42b42ca57ec2ebb28`，
并已通过签名和 `verify-app`。r5 不再代表当前最新 embedding 源代码。

剩余工作严格按以下顺序执行：

1. 等待实体机 `2PM0223A18006914` 稳定出现在 HDC，安装并启动 r6。
2. 用脚本在持续播放、全屏、原始 PointerDown 保持期间验证同一 embedding owner 的
   Down → page-pop → Cancel → dispose 链，以及重建后的新 attachment Down；不把冻结帧
   进出全屏当作灰屏回归结论。
3. 在实体机完成播放中多轮全屏切换、SDR/PQ/HLG 切换、surface 重建、竖屏视频主体控制条
   和滑动手势回归，并保留截图、布局、Hilog、帧进展和色彩输出证据。
4. 依据上述证据再做最终 architect review，并更新本计划和运行状态；在此之前不宣称
   灰屏、HDR、触控或生命周期问题已解决。

## 2026-09-09 终审后第二轮修正状态

最新 architect 终审确认 r6 仍不能直接进入实体机最终验收，补充发现：OHOS 全屏原生
接口提前返回 success、detach 残留 pending overlay、Axis/Hover/dispose 的旧 attachment
边界、Cancel ownerSeq 被 Move 覆盖，以及播放中脚本只在切换前采样。上述代码和判据已在
本地修正，并增加 dispose/reuse 与 pending-overlay 定向 embedding 测试。

当前必须重新冻结候选包：r6 不包含这些修正。r7 构建在源同步阶段因 `dev` SSH
`172.24.136.84:1040` 超时而未产生 HAP；在 r7 成功构建、签名、marker/库身份核对前，
不得安装或引用 r6 作为最终验收包。r7 之后仍需先做实体机单次播放闭环，再做生命周期、
每轮全屏后可见视频变化、SDR/PQ/HLG、surface 重建、竖屏触控和 macOS 回归。

## 2026-09-09 r7 复测后的计划校正

r7 已完成构建和签名，最新实体机复测使用 `2PM0223A18006914`，确认搜索流程可达视频、
首帧较慢、HDR native 前置条件通过，画面能够正常播放。该轮尚未进入有效的全屏循环，
不改变“连续播放状态下灰屏尚未验收”的结论。

脚本现在必须先解决测试前置状态：应用可能从上次会话恢复横屏全屏，且 OHOS UI dump 在
该状态只暴露 XComponent/Slider，不暴露真实全屏按钮。已删除会选中透明 Text 的右下角
结构候选；没有可验证的语义按钮就停止。后续实现顺序为：

1. 为控制层补充稳定、可见、可由 UI dump 解析的全屏动作语义，或提供等价的测试语义入口；
2. 脚本只通过该语义入口归一化初始窗口态，再执行连续播放中的进入/退出全屏；
3. 每次切换后等待 `playing`，采集可见视频帧变化和 HDR/output 日志；
4. 通过单次循环后再扩大到多次循环，随后继续生命周期、surface、竖屏触控和 SDR/PQ/HLG
   验收。

冻结帧进出全屏仍只作为布局、方向、surface 和 HDR 决策控制样本，不作为历史灰屏回归
结论；灰屏判据必须保持播放中连续状态。

## 2026-09-09 r9-r11 方向策略修正

OHOS 不应直接加入全局 `PlatformUtils.isMobile`，否则会重新触发曾导致白屏的移动端启动
初始化；但 OHOS native fullscreen 也不能继续把 phone 退出方向固定为 portrait。应用启动和
native fullscreen 退出必须共享 `Pref.horizontalScreen` 策略，由 `harmonyChannel`/media-kit
OHOS 适配执行。

本轮已完成：启动时 OHOS `setWindowOrientation`；native fullscreen 退出携带
`allowLandscape`；控制条保持显式 Semantics identifier/label，隐藏或锁定时同时排除 pointer
和 semantics；脚本对每次播放中切换执行语义按钮定位、方向检查、控制条状态和中央视频帧
变化检查；r11 实机单周期通过，buffering 则 fail-closed。

后续必须按顺序完成：用新增的 unknown 播放语义重唤醒重试重新收集 r11 20 周期结果；完成 process-live、surface recreate、SDR/PQ/HLG
和竖屏主体触控回归；补充同一 surface/frame 的色彩输出证据，区分画面持续变化和亮度/色彩
变灰；最后由新的 architect 从原始问题和当前代码做最终审核。

## 2026-09-09 灰屏现场后的计划重排

r11 20 周期长跑在第 16/17 周期人工确认灰雾后停止。当前证据表明播放没有停止，但画面对比度
明显下降；因此 `frame changed` 只能证明播放活动，不能证明颜色正确。

architect review 指出：第 17 周期 resize 后 NativeWindow 色彩 setter 已执行并成功，优先级
最高的调查对象是旋转/resize 后实际 buffer、VO/WSI 与 RenderService 的色彩解释/生效时序，
而不是在 Flutter 全屏回调中重复 HDR decision。第 13、14、16 周期节点色彩状态从对照 7 变为
4，第 16 周期还出现 surface 与实际队列 buffer 尺寸不一致。

下一步严格按此顺序：

1. 将 Hilog 采集窗口延长到覆盖完整长跑，并检查采集进程未提前退出；
2. 关联 native 单调时间、surface/VO 身份、swapchain generation、实际 buffer extent/format/
   colorspace、首个 present、setter readback 和 RenderService 节点状态；
3. 脚本增加 `COLOR_CONTRACT_MISMATCH` 门禁：PQ 输出从基线节点状态 7 变 4 时立即停止并保留
   灰屏现场；
4. 在证据闭环前不修改为固定延迟或重复 HDR 初始化；之后再做单变量 VO/WSI 实验，并以同源
   同 PTS 参考或人工实屏证据判断 visual-color。
### 诊断脚本实现状态

上述第 1、3 项已先落地为可复核工具：`verify_hdr_real_device.sh` 现在为长跑保留足够的
Hilog 采集窗口，并调用 `inspect_render_service.py` 对视频 surface 建立运行内基线。发现
同一 surface 的 `colorSpace` 变化时，脚本输出 `COLOR_CONTRACT_MISMATCH`、停止后续点击，
并保留现场。`VERIFY_REQUIRE_COLOR_CONTRACT=1` 可将 RenderService 快照缺失也变为失败。

工具用法示例：

```bash
VERIFY_REQUIRE_COLOR_CONTRACT=1 \
  tool/ohos/verify_hdr_real_device.sh \
  --source BV1vY4y1N7TY --cycles 20 --out /tmp/piliplusx-ohos-color-gate
```

离线检查已有快照：

```bash
python3 tool/ohos/inspect_render_service.py \
  /path/to/*-renderservice.txt \
  --baseline /tmp/render-service-color-baseline.json
```

门禁成功后仍需继续完成 native 单调时间、swapchain、首个 present、setter readback 与
RenderService 的关联采集，再进行单变量 VO/WSI 实验和 visual-color 验收。

## 2026-09-09 fixed producer extent 负结果与下一调查层级

按 architect 建议完成了单变量诊断：只在 debug HAP 中固定 mpv producer extent 为
`2520x1260`，Flutter 几何、HDR setter、VO、解码器和生命周期保持不变。固定版本为
`PiliPlusX-ohos-fixed-producer-20260909-signed.hap`，SHA-256 为
`e1a3fd8e4eb4e231716bf02ec4ec4bc2404824f93753fdbc71270dd8653e0de6`。

实机结果是否定的：播放中切换全屏/竖屏后出现持续灰屏，方向切换不能恢复。日志确认每次
提交的 producer extent 都是 `2520x1260`；RenderService 也确认视频 surface 的默认尺寸
和实际 buffer 都保持 `2520x1260`，但节点色彩状态为 `colorSpace=4`、`uifirstColorGamut=4`、
`NodeColorSpace=4`。这排除了“buffer 尺寸变化单独导致灰屏”的解释，不能据此改成固定尺寸
生产方案。

下一步不再继续调几何尺寸或增加时延，而是核对当前 HAP 的 native 诊断 provenance，确保
包含 VO/WSI target mapping 与 color hint 记录；然后在一次播放中关联 target mapping、
color hint、setter readback、首个 present、RenderService 节点状态和 surface generation。
只有确认消费者收到的色彩解释路径后，才选择 VO/WSI 层的最小修复。`no dirty buffer` 若来自
Flutter 主 surface，必须排除在视频 queue 因果链之外。

## 2026-09-10 mapping/hint 证据后的决策

mapping 诊断 native 已实际进入 HAP 并在实体机运行。3 周期持续播放脚本目录为
`/tmp/piliplusx-ohos-fixed-producer-mapping3-3cycles-20260910`；HAP manifest 固定记录
`libmpv_sha256=a4fee672e49d82912d22644c80a383807c241fdaec96003d9dfebdaba924fc75`。

证据将候选层级从“producer extent/resize”推进到“VO/WSI 动态色彩输出”：
1. mpv `OHOS target mapping` 和 `color hint after set_color` 连续报告 PQ target
   (`target_trc=12`, `hint trc=12`, `strict=1`)；因此不能说 decoder 或 mpv target
   mapping 没有识别 HDR。
2. 同时 `OHOS color contract` 的动态 setter `attempted/result` 全为 0，readback 为
   `space=0/25`；RenderService 视频节点始终为色彩状态 4，而不是历史正常样本的 7。
3. 画面截图在首个稳定全屏样本起即灰雾化，且后续方向切换不恢复；固定 producer extent
   只能证明尺寸不是充分修复条件，不能作为生产方案。

因此下一单变量实验必须留在 OHOS VO/WSI：确认动态 color-space、metadata、white-point
setter 的调用条件、返回码和实际 consumer 生效时序；同时保留 mpv mapping、surface id、
generation、RenderService node state 和截图。禁止回到 Flutter 层重复 HDR 初始化、固定
延迟或继续调几何尺寸，直到明确为什么动态 setter 没有进入 attempted/result。

## 2026-09-10 consumer readback recovery 首轮通过

已新增 `tool/ohos/ohos-consumer-color-recovery.patch`，把故障处理放在 OHOS VO 的
consumer readback 边界：desired color space 与 NativeWindow readback 不一致时，失效所有
动态色彩缓存；下一帧按当前 HDR source 重新写入，而不是依赖旧 cache 或 Flutter 层重复
初始化。Recovery HAP 的 native SHA 为
`4edc0e8a4e89b3c58f36a620786f02a99c5e9e3ee3e3485b789e4cc73e9885de`。

实机 3 周期结果支持该方向：4 次出现 `desired=31 actual=25` 后，均能观察到下一次
`attempted=1` 且 readback 回到 `31`；RenderService 全部采样为 `colorSpace=7`，视觉截图
不再持续灰雾。此结果是根因级诊断通过，不是完整回归通过；正式接受条件仍为 30 周期以上、
多个 HDR/SDR 源、PQ/HLG 往返、surface recreate、生命周期和竖屏视频主体触控，并经新的
architect 独立终审。

## 2026-09-10 recovery patch 构建链与门禁收敛

已按 architect 终审意见把 recovery patch 从“远端源码手工应用”收敛为可重建输入：
`tool/ohos/ohos-consumer-color-recovery.patch` 已加入
`/Users/wuweiwei1/src/ohos-native-build/libmpv-ohos-build/patches/mpv/`。补丁内部复用
`invalidate_output_color()`，避免 consumer readback 失配路径和已有 VO invalidate 路径各自
维护一份缓存字段清单。

同时修正 native `patch.sh` 外层 process-substitution 的位置。此前它只打印
`OHOS HDR lifecycle/color contract checks passed`，没有真正遍历 patch 目录；现在会进入每个
依赖目录并执行幂等 patch 检查/应用。由于本机没有完整 ffmpeg checkout，当前只确认 recovery
patch 对 native source 的 `git apply --check` 通过；不能把本机缺依赖当成编译验证。

实体机脚本门禁也已收紧：要求 native diagnostics 时四个 marker 必须全部存在，可选校验
HAP 内 `libmpv.so` SHA；要求 RenderService color contract 时，稳定全屏首个基线默认必须是
`colorSpace=7`。这能阻止“脚本通过但首个稳定帧已经是灰色状态”的假阳性。正式验收仍未关闭，
必须完成动态 producer extent 的至少 30 周期、SDR/PQ/HLG 与 source/metadata 切换、暂停/后台
返回、surface recreate 及竖屏视频主体触控矩阵。

## 2026-09-10 chain HAP 长跑边界

从远端 mpv HEAD 临时 worktree 重新应用三层 native patch chain 后，native 编译和 HAP
签名均通过。HAP 内 `libmpv.so` SHA 为
`7a1e0b453e2c03677775084df358f27e6dbf7e6b35c615740c925dda997c4055`，并通过 native marker、
HCPP marker 和 HAP 完整性校验。

30 周期实体机脚本在第 16 周期因方向门禁停止，而非颜色门禁停止。第 1--15 周期均完成
播放中退出/进入全屏；稳定采样全部为 `colorSpace=7`，PQ readback 为 `31`。第 16 周期的
退出阶段仍为 portrait、`colorSpace=7`，进入按钮语义状态已变为“退出全屏”，但窗口实际仍
为 portrait；Hilog 没有 `COLOR_CONTRACT_MISMATCH`，说明这是 OHOS fullscreen/orientation
事务不一致，不能归因于 HDR 灰屏修复失败。

当前接受状态仍为 incomplete：颜色 recovery 已有 15 周期连续实机证据，但需要先解决或
单独收敛方向事务重试/失败证据，再完成 30 周期及 SDR/PQ/HLG、source/metadata、暂停/后台
返回、surface recreate、竖屏视频控制条矩阵。

## 2026-09-10 全屏方向事务门禁修复与 HDR 源矩阵

针对第 16 周期“逻辑已进入全屏、窗口仍为 portrait”的证据，media-kit OHOS
`Utils.enterFullScreen/exitFullScreen` 不再把 `setPreferredOrientation` 的请求回调当作
物理旋转完成：现在监听 `windowSizeChange`，等待实际窗口宽高达到目标方向，5 秒超时则将
native fullscreen 请求失败返回给 Dart，不提交错误的逻辑全屏状态。进入/退出、尺寸事件和
超时尺寸均写入 Hilog，便于把方向事务失败与颜色 contract 失败分开分析。

方向门禁 HAP 已构建并签名：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-orientation-gate-20260910-final-signed.hap`，
HAP SHA-256 为 `fd40c23e0980d4a860e2dbb0a174fceae9279fab0d0ff05def60ad7f8d3f30f7`，
内嵌 libmpv SHA-256 仍为
`7a1e0b453e2c03677775084df358f27e6dbf7e6b35c615740c925dda997c4055`，完整性校验通过。
由于本轮设备端 HDC 当前为 Offline，尚未把该 HAP 计入实机验收。实机长跑脚本现在默认
执行 `power-shell wakeup`，并临时将自动熄屏延长到 1 小时，退出时用 `timeout -r` 恢复；
可通过 `VERIFY_KEEP_SCREEN_ON=0` 显式关闭。源矩阵封装为
`tool/ohos/verify_hdr_source_matrix_real_device.sh`，每个源独立目录、独立门禁和独立结论。

HDR 源矩阵候选固定为：真彩 HDR `BV15z4y1Z734`；HDR Vivid 候选 `BV121421y7PM`；HLG
测试信号候选 `BV1ZB4y1F7jf`；PQ/HLG/SDR 对照候选 `BV1tM4y1L7EF`。候选来源只用于
启动脚本，最终格式必须由 Hilog 的实际 transfer/metadata/color contract 证明，不能由
标题或 BVID 名称推断。正式顺序仍是先用方向门禁完成连续播放全屏轮次，再执行这些源的
SDR/PQ/HLG 往返、source/metadata 切换和生命周期矩阵。

模拟器短测目录为 `/tmp/piliplusx-ohos-orientation-sdr-emulator-cycle1-20260910`：最终 HAP
能够安装、启动并完成搜索，但视频页出现 `EGL_BAD_SURFACE`，控制条无进度条，脚本在首次
控制条操作前停止。该结果不能替代实体机方向/HDR 验收，也不作为颜色恢复失败结论；实体机
仍需 Online 后按相同脚本重新验证。

## 2026-09-10 reapply-color-after-resize 杜比视界门禁结果

在 OHOS OpenGL/Vulkan resize 完成后立即调用 `vo_ohos_reapply_color()`，使 NativeWindow
consumer 色彩状态失效后不必等待下一帧才恢复。修正版 native `libmpv.so` SHA-256 为
`f68b7b2dc7613268a9db505a138cd165ebbb2128810b40d407b0eefe2f6bb2ae`，签名 HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-reapply-color-after-resize-20260910-r4-signed.hap`。

真实杜比视界源 `BV1vY4y1N7TY` 在实体机完成 30/30 次播放中全屏往返；91 次播放进度
观察、120 次 RenderService 色彩契约采样均通过，所有采样保持 `color_space=7`，无
`COLOR_CONTRACT_TRANSIENT`/`COLOR_CONTRACT_MISMATCH`。Hilog 证明实际路径为
`source=dolbyVision` → `output=nativeHdr`/`surface=native-hdr`，且
`nativeOutputActive=true`。

该证据关闭了自动化播放和输出契约门禁，但不能关闭视觉颜色门禁。由于每张截图对应不同
PTS，脚本继续输出 `color verdict: INCONCLUSIVE`；必须补充同源同帧或等价的实屏颜色
参考，且验证条件仍须保持播放中切换全屏，不能改成冻结帧来宣称灰屏问题已解决。在此门禁
关闭前，严格冻结 HDR Vivid、HLG、SDR/PQ 等其它格式测试。

## 2026-09-10 杜比视界视觉回归门禁关闭

在同一 r4 HAP、同一实体机和同一 DV 源 `BV1vY4y1N7TY` 上追加 3 次持续播放中的短程对照，
完成 3/3 周期、10 次播放进度观察和 12 次 RenderService 色彩契约采样；短测 Hilog 没有
consumer color mismatch。全屏立即、稳定及回切截图未见持续灰雾或明显颜色跳变。

结合 30/30 长跑，当前“播放中切换全屏变灰”的杜比视界回归门禁关闭，允许按既定顺序进入
其它格式矩阵。该结论不等同于显示仪器色准认证，不扩展到所有 DV profile 或动态元数据
直通；后续格式仍必须以实际 transfer、metadata、NativeWindow readback 和 RenderService
状态逐项验收。

## 2026-09-10 方向门禁包上的 DV 重验与其它格式矩阵边界

最新方向门禁 HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-orientation-gate-20260910-final-signed.hap`
在实体机上对 DV 源 `BV1vY4y1N7TY` 完成 30/30 次持续播放全屏往返、91 次进度观察；稳定
RenderService `colorSpace` 全部为 7，无颜色契约瞬态或失配，实际窗口方向每轮通过。证据目录为
`/tmp/piliplusx-ohos-orientation-dv-cycles30-20260910`。

随后执行其它格式：`BV15z4y1Z734` 完成 30/30 轮且颜色契约异常为 0，但 Hilog 证明实际格式
为 `hdr10/pq`，不能作为 HDR Vivid 证据。`BV121421y7PM` 首轮因短素材结束 fail-closed；
缩短采样间隔后的重跑完成 21/30 轮，随后因 `unknown + frame unchanged` 停止；再次重跑时
发现 USB 系统对话框和恢复路径的全屏语义不同步，仍不能计为通过。当前实体机需重新 Online
后继续从失败源重跑。

补测样片 `BV19VBUBHEBK`（标题标注 HDR Vivid）和 `BV1HBxxePEHo`（标题标注 HLG）后，实际
Hilog 均为 `source=hdr10`、`transfer=pq`，不能作为 HDR Vivid 或 HLG 证据。两次单轮播放
均在播放中切换全屏后遇到 `buffering -> unknown`，脚本按门禁停止；控制条语义重试本身已
成功，不将这两次结果记为格式或颜色通过。

## 2026-09-10 process-live 生命周期门禁通过

使用专用 debug HAP `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-20260910-signed.hap`
在实体机完成正式 process-live 复跑，目录为 `/tmp/piliplusx-ohos-process-live-20260910-r17`，
脚本返回码为 0。该轮在持续播放、全屏和活动 drag 条件下关联到稳定 PID、同一
PlatformView/epoch 的 owner Down、owner Cancel、NAPI Cancel、attachment dispose、
app-side page-pop 和 Dart PointerCancel；旧的字段顺序、事件名、日志 flush 和时序误判已由
脚本修正。该门禁现已关闭，但它不替代重建后持续播放、格式切换或竖屏触控验收。

surface recreate 实验 `/tmp/piliplusx-ohos-surface-recreate-20260910-r1` 已在实体机完成：
连续播放 baseline 完成一次全屏往返并观察到视频帧变化；随后脚本在活动 drag 期间执行
force-stop/start，捕获旧 surface `Cannot find surface`、窗口销毁和新 Flutter native window
重新 `SetDisplayWindow` 的日志，并取得重启后的布局/截图。该实验是冷重启与 surface 边界证据，
不能替代旧进程 graceful dispose、重建后继续播放或灰屏/颜色稳定性验收。

## 2026-09-10 process-live 实体机证据与脚本门禁修正

使用带 `PILIPLUS_PROCESS_LIVE_TEST=true`、`PILIPLUS_PLAYER_TOUCH_TRACE=true` 的专用 debug HAP
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-process-live-20260910-signed.hap`，实体机证据目录
`/tmp/piliplusx-ohos-process-live-20260910-r8` 已捕获完整链路：同一 view/epoch 的 owner Down、
owner Cancel、NAPI Cancel、attachment dispose，随后 app-side page-pop 和 Dart PointerCancel，
进程 PID 保持稳定。该轮初始脚本因三处日志字段假设错误而返回失败，未把它直接记作脚本门禁
通过：修正了 live Hilog 延迟刷新、`activeOwner` 关联、`epoch/platformViewId` 字段顺序、
`owner ... TouchType=Cancel` 事件名，以及真实的 Cancel-before-dispose 顺序。修正后的脚本
仍需在稳定全屏播放场景下取得一次返回码为 0 的复跑；r9 因方向未切换而未形成该复跑。

## 2026-09-10 格式门禁脚本收紧与当前短测

源矩阵脚本新增实际格式门禁：HDR Vivid 和 HLG 源必须分别在自身 `hilog.txt` 中出现
`source=hdrVivid` 与 `transfer=hlg`（字段命名变化只能通过显式正则覆盖），不能用标题、BVID
或 `colorSpace=7` 推断格式。相关规则和日志延迟重抓参数已写入实体机操作说明。

实体机短矩阵目录 `/tmp/piliplusx-ohos-hdr-matrix-20260910-format-gate` 的首个真彩候选
`BV15z4y1Z734` 在进入横屏后因 `playing -> unknown` 且帧不变而 fail-closed，未计为通过；
Hilog 实际识别为 `source=hdr10, transfer=pq`，随后进入 `output=nativeHdr`。这次结果同时
确认当前脚本不会把短素材/网络停滞误报为格式通过。

## 待办：真实 HLG / HDR Vivid 样片

按当前验收决定，暂时跳过 HLG 与 HDR Vivid 的实体机长跑，不把缺少可靠输入误写成格式通过。
已检查候选及结论如下：

- `BV1ZB4y1F7jf`、`BV11b4y1d7Cr`：标题/搜索摘要标注 HLG，但实体 Hilog 均为
  `source=hdr10, transfer=pq`。
- `BV121421y7PM`、`BV19VBUBHEBK`、`BV1SmtKzQEpi`：标题/搜索摘要标注 HDR Vivid；前两者
  实际为 `source=hdr10, transfer=pq`，后者在当前短测中未满足 `nativeHdr` 前置条件。

恢复条件：取得可下载或可由产品页面稳定播放的真实样片后，先用实际 transfer/metadata 和
Hilog 确认格式，再分别执行至少 30 轮持续播放全屏往返、颜色契约、source/metadata 切换和
视觉对照。此待办不影响已关闭的 DV 门禁，也不允许用 PQ 样片替代 HLG/Vivid。

源矩阵脚本已增加 `--skip-hdr-vivid --skip-hlg` 显式选项；跳过项会记录原因并返回退出码 3，
表示矩阵不完整，不能被 CI 或人工报告解释为通过。

## 2026-09-10 实体机离线时的本地验证

实体机 `2PM0223A18006914` 当前为 HDC `USB Offline`，`hdc tconn` 重连返回
`CreateConnect failed`，不能继续执行 PQ/SDR、竖屏触控或重建后的真实呈现验收。
离线期间完成播放器定向 Flutter 测试 17/17，以及本轮修改文件的精确 `flutter analyze`；
精确 analyze 无问题。全目录 analyze 仅有既有 `mpv_convert_webp.dart:65` 的 lint 信息，
不扩大本轮修改范围。

## 2026-09-10 macOS 构建回归边界

实体机离线期间使用 `caffeinate -dimsu flutter build macos --debug --no-pub` 成功生成
`build/macos/Build/Products/Debug/PiliPlusX.app`。构建输出提示 `flutter_inappwebview_macos`
尚不支持 Swift Package Manager；该警告未导致构建失败。此结果只关闭 macOS debug 构建门禁，
不关闭 macOS 播放、HDR/DV 可见输出或产品交互回归。

随后启动该 debug app，5 秒后进程 `PiliPlusX` 仍在运行，`System Events` 能发现对应应用进程；
这只关闭 macOS debug 启动烟测，不替代视频播放、HDR/DV 输出或交互验收。

## 2026-09-10 PQ/SDR 源方向门禁失败

实体机恢复 Online 后，`BV1tM4y1L7EF` 的 3 轮短测及一次重跑均在首次全屏点击后停止：按钮
语义为“全屏”且点击成功，但 `08-fullscreen-stable` 实际仍为 portrait。Hilog 同时证明源为
`source=hdr10, transfer=pq`，并最终进入 `output=nativeHdr`，因此未计入 PQ/SDR 颜色或周期通过。
同一设备、同一 HAP 对 DV 源完成 1 轮进入/退出/再次进入横屏，脚本返回码 0；这次对照把 PQ
失败范围缩小到源级/会话级方向事务，不能归因于已关闭的 DV 颜色回归。

之后复核发现 OHOS `dumpLayout` 对实际可见 Flutter 控制条也可能报告 `opacity=0`，因此
opacity 不能作为唯一门禁；脚本继续要求点击前重新唤醒并获取最新的
`visible/enabled/clickable` 节点。新的 DV 回归因应用未进入预期视频/搜索页提前停止，仅作
环境/前置失败记录，不覆盖既有 DV 证据。

## 2026-09-10 PQ 短片自动退出复核

诊断 HAP 已以更高版本号构建、签名并安装。DV `BV1vY4y1N7TY` 使用脚本完成首次进入、退出、再次进入横屏，且播放帧持续变化；证据目录为 `/tmp/piliplusx-ohos-dv-control-BV1vY4y1N7TY-20260910-cycle1-r5`。

PQ `BV1tM4y1L7EF` 诊断日志证明原生进入横屏和实际 `windowSizeChange` 均成功，随后短片接近结束时收到应用 `exitFullScreen`，回到竖屏；缩短稳定等待后首次方向检查通过，但播放进展检查读到 `paused`。architect 建议优先使用长 PQ/SDR 源验证，并区分既有完成自动退出策略，暂不修改 OHOS Utils 或全屏队列。

## 2026-09-10 长 PQ 源验证结果与格式待办

按 architect 建议使用约 305 秒的 `BV15z4y1Z734` 做连续播放控制组。两次脚本运行均进入横屏并稳定得到 `2720x1260`，但播放进展门禁在 `0%` 处持续 `buffering`，最终为 `before=buffering after=unknown frame=changed`。该结果支持“全屏方向事务已打通”，但不能作为 PQ/HDR10 播放或颜色验收通过；后续应在网络/源播放稳定后重跑同一脚本。

HLG 与 HDR Vivid 当前未找到可用的真实产品样片，按用户要求暂时跳过，记录为待办；不得用标题标注为 HLG/Vivid、但实际元数据为 PQ/HDR10 的视频替代验收。

后续扩大 PQ 循环时，默认语义播放门禁在全屏后遇到 `unknown` 且滑块位置不可用，虽然中央视频裁剪区变化，仍按 fail-closed 停止；这说明脚本仍需区分“无障碍语义缺失”和“真正暂停/缓冲”。已加入显式的 `VERIFY_ALLOW_VISUAL_PLAYBACK=1` 诊断开关，但它只证明中央视频帧变化，不关闭完整播放状态门禁，默认仍关闭。另一次尝试在进入视频页截图前因 HDC 变 Offline 停止。

在实体机短暂恢复在线后，长 PQ 源单轮重跑成功建立 `playing`，完成进入横屏、稳定窗口
`2720x1260` 和中央视频帧变化，并取得 `output=nativeHdr`；证据目录为
`/tmp/piliplusx-ohos-pq-long-BV15z4y1Z734-20260910-cycle1-r3`。这只证明单轮方向和帧进展
前置通过，不能替代 PQ 多轮或视觉颜色验收。

随后 3 轮和关闭 seek 重置的重跑均未形成完整通过：一个在 `unknown + frame changed` 且无有效
Slider 位置时被默认门禁拒绝，另一个在进入视频页截图前因 HDC Offline 停止。诊断开关仍只用于
明确标记“仅视觉帧进展”，不改变默认 fail-closed 规则。

## 2026-09-10 PQ 3 轮通过与控制条时序修复

`r6` 曾复现第二次全屏按钮语义节点存在、但实际窗口保持竖屏；Hilog 没有第二次
`FullscreenTrace trigger`。根因定位为循环路径在点击前执行截图，控制条在截图期间超时隐藏，
导致最新语义节点与实际可点击 overlay 不再同步。脚本已改为循环点击前只重新 dump 并立即点击，
点击后的 immediate/stable 截图继续保留。

修复后的长 PQ `BV15z4y1Z734` `cycles=3` 在 `r2` 完成 3/3 轮和 10 次播放进展观察，HDR
decision 为 `source=hdr10, transfer=pq, output=nativeHdr`；这关闭了该脚本时序修复的 3 轮方向/帧进展门禁，不能替代颜色视觉验收。

30 轮尝试在第 4 轮因片源 91%→97% 接近结束而停止，短片长度不足以支持无重启的 30 轮长跑；
应换更长 PQ 源，或显式使用已记录的片尾重启策略，不能把该轮计为 30 轮通过。

同一修正版脚本对 SDR 源 `BV1GJ411x7h7` 完成 3/3 轮全屏往返和 10 次播放进展观察；Hilog
确认 `source=sdr, transfer=sdr, output=sdr, surface=texture`，脚本输出 `Texture/SDR evidence: PASS`。
证据目录为 `/tmp/piliplusx-ohos-sdr-BV1GJ411x7h7-20260910-cycles3-r1`。这只关闭 SDR
方向/帧进展门禁，颜色视觉对照仍未完成。

surface recreate 脚本随后完成同一 DV 源的连续播放基线、活动拖动中的 force-stop/start、旧 surface
销毁和新 native window `SetDisplayWindow` 重建，并取得重启后截图；证据目录为
`/tmp/piliplusx-ohos-surface-recreate-20260910-r3`。该结果不扩展为 graceful dispose、重建后
继续播放或竖屏主体触控通过。

## 2026-09-10 竖屏方向跨层修正

首次新 HAP 实测虽然播放器侧记录了竖屏源，但 OHOS 原生 `media-kit_video` 仍将
`Utils.enterFullScreen()` 写死为横屏，说明方向状态没有跨越播放器到原生窗口的接口边界。
现已将 `landscape` 参数贯穿 Dart 全屏事务、`MethodChannel` 和 media-kit ArkTS 窗口实现；
竖屏进入/退出全屏都保持 portrait。新 HAP `2026091202` 已构建、签名、分块传输、哈希核对
并安装成功；运行时复测因设备锁屏待解锁后继续，尚未宣称通过。

随后发现“portrait 窗口但逻辑按钮仍为全屏”的跨层问题，最终方案将竖屏全屏明确为应用内
全屏事务：系统栏由播放器事务管理，原生窗口方向/尺寸事务仅保留给横屏源。`2026091203`
已构建并签名；实体机分块传输中途 HDC Offline，待重连后继续安装和运行时验收。

`2026091204` 进一步移除竖屏应用内全屏事务中的系统栏调用，使逻辑全屏提交不依赖进程级
系统 UI 副作用。实体机 `cycle1-r7` 已证明竖屏进入/退出/再次进入的语义状态和 portrait
方向均正确，并观察到播放帧进展；`cycles=3` 因 HDC 在启动前再次 Offline 尚未执行。

随后实体机恢复，`2026091204` 的 `cycles=3` 已完成：3/3 轮 portrait 方向和语义状态通过，
9 次播放进展观察通过，片尾恢复策略也取得了有效帧进展。证据目录为
`/tmp/piliplusx-ohos-vertical-BV1Wp4y1P7KU-20260910-cycles3-r2`。

## 2026-09-10 输出重建修正后的实体机重入边界

`2026091301` 已包含输出事务所有权修正并在实体机安装。脚本新增
`VERIFY_REUSE_CURRENT_APP=1`：不执行 `force-stop/aa start`，复用现有 PID；同时新增搜索结果页
识别、语义 `first-video` 点击和“视频 0/没有数据/点击重试”处理。

验证结果分层记录：基线 `/tmp/piliplusx-ohos-owner-r1-baseline-r2` 的播放/横屏全屏往返通过；
正常 page-exit 的 PID `61567` 保持不变，并采集到 owner/NAPI Cancel 与 attachment dispose。
第二轮 page-exit 的 PID `64659` 也保持不变。但同进程重入目录
`/tmp/piliplusx-ohos-owner-r1-same-process-reentry-r5` 仍因搜索结果无数据未进入新视频页，
没有形成新 attachment/nativeSurfaceReady、nativeHdr 或重入后播放帧证据，故未关闭“重建后继续
播放”门禁。

## 2026-09-10 surface recreate r4 边界结论

实体机恢复连接后重新执行 `tool/ohos/verify_surface_recreate_real_device.sh`，证据目录为
`/tmp/piliplusx-ohos-surface-recreate-20260910-r4`。连续播放基线完成一次横屏全屏往返并观察到
帧进展；随后在持续 4 秒脚本拖动期间 force-stop/start。日志确认旧 surface 的
`Cannot find surface`/窗口销毁，以及新进程 `56367` 的 `SetDisplayWindow` 和
`ReleaseOffscreenWindow`，并保存了重启后的布局和截图。

本轮只扩大了冷启动/Surface 边界证据，不扩大为 graceful dispose、重建后继续播放或颜色稳定性
通过。process-live 的旧进程 Cancel-before-dispose 已有独立实体机门禁，不应与本轮 force-stop
证据合并。若要关闭“重建后继续播放”，下一步需要可控的不杀进程 detach/recreate 入口，并在
同一源上验证新 attachment、连续帧进展和旧 attachment 事件隔离。

## 2026-09-10 输出重建事务所有权修正

architect 复核确认 `_rebuildVideoOutput` 在释放旧输出、创建新输出的多个 `await` 之间，原先
没有检查播放器是否仍归当前 controller 所有；页面 `dispose()` 可能先清空播放器引用，随后旧
事务迟到提交新的 `_videoController`。这属于应用侧输出重建事务的生命周期竞态，不应通过增加
force-stop 次数或重新设计 HDR 状态解决。

现已在 `lib/plugin/pl_player/controller.dart` 的既有重建事务中加入独立的
`_videoOutputTransactionGeneration`：开始重建时记录事务代数，`dispose()` 立即使其失效，旧
player 不再是当前 owner 时停止提交；异步创建出的过期 controller 会走
`disposeForRebuild()` 清理。该代数与 HDR source generation 分离，避免把“源仍相同”和“页面
仍存活”混为一层状态。

静态与定向验证：`flutter analyze --no-pub lib/plugin/pl_player/controller.dart` 无问题，
播放器相关 Flutter 测试 17/17 通过。实体机下一步必须验证同进程正常退出播放器后重新进入同一
视频：PID 保持不变，旧 attachment/output dispose、新 attachment/nativeSurfaceReady、输入
接管、连续帧进展和一次全屏往返均需分别采集；不能用 r4 冷重启证据替代。

实体机重连后的 `r7` 复测已重新确认分层边界：杜比视界冷启动基线
`/tmp/piliplusx-ohos-owner-r7-dv-baseline` 的播放中全屏往返通过，page-exit PID `18536`
保持不变；但同进程回入后搜索结果进入“视频 0/没有数据”，连续语义重试仍未形成新的目标视频
页，因此没有产生新 attachment/nativeSurfaceReady/nativeHdr 或重入后帧进展证据。验证脚本已补充
“打开结果后再次确认目标详情页”的 fail-closed 门禁，避免把网络/详情加载失败误报成全屏或 HDR
回归结果。当前架构门禁仍未关闭，下一步仍是网络可用时完成同 PID 的真实视频重入。

## 2026-09-11 同进程重入输入边界复核

同一 PID `18536` 经脚本化 page-exit、返回、重新搜索和语义点击后，目录
`/tmp/piliplusx-ohos-owner-r8-direct-reopen` 证明目标视频页可以恢复并继续出帧。随后同进程
复测目录 `/tmp/piliplusx-ohos-owner-r8-same-process-reentry-success2` 和再次复测 `r9` 均出现
同一边界：语义按钮为“全屏”，HCPP overlay Down/Up 为 accepted，但点击后 orientation
仍为 portrait，未形成 `FullscreenTrace`，所以问题发生在全屏回调进入之前或 Flutter 指针包命中
之前，不能归因到方向 API。

architect 独立复核要求优先验证输入身份、Down/Cancel/Up 终止契约和实际部署的 native engine，
不把 `platformViewId=1`、坐标或 attachment 映射单独定性为根因。当前 HAP 的 `libflutter.so`
经字符串核对不含 dev 源码新增的 `HCPP_POINTER` native trace，故必须先解决 native engine/安装
产物一致性，再做一次单次 Down/Up 的 ArkTS→NAPI→PointerDataPacketConverter→Dart 贯通追踪。
设备随后为 `USB Offline`，本结论停在证据记录，不计同进程重入通过。

为验证指针身份冲突假设，已将 HCPP 注入设备 namespace 的所有权收敛到 ArkTS embedding：
`HCPP_INJECTED_DEVICE_BIAS = 1 << 40`；C++ NAPI bridge 不再重复加偏移，只透明转发
`PointerData.device`。这样旧 `libflutter.so` 与未来重建的 native bridge 共享同一协议，避免同进程
重入时与旧 XComponent pointer state 使用相同 device 身份。相关 ArkTS 单测已增加设备身份断言。

新 HAP `2026091302` 已构建、签名、verify-app 和包内 marker/hash 检查通过，产物为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-owner-device-bias-20260911-r1-signed.hap`，但因实体机
当前 `USB Offline` 尚未安装。该修改仍需用同进程重入脚本验证；若仍失败，再进入坐标、view 存在性
和 PointerDataPacketConverter 四段贯通诊断，不应直接回退到点击延时或方向 workaround。

构建后复核发现 `1 << 40` 在 ArkTS/JavaScript 中是 32 位位运算，上一版 `2026091302` 未真正
使用高位 device namespace，已明确废弃。现已改为精确数值 `1099511627776`，同步加强单测阈值，
并重新生成 `2026091303` HAP：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-owner-device-bias-20260911-r2-signed.hap`，SHA-256
为 `9eccbbeaf5a8a37af99897c34d4ed6a408c2cbd64a57382170e463000a7a57d0`。该包仍未进行实体机
安装和运行验收。

又核对出 NAPI `device` 读取原先使用 `napi_get_value_int32`，所以 `2^40` 即使在 ArkTS 中正确
也会被 bridge 截断。最终协议改为 ArkTS 使用 32 位安全 namespace `1048576`，C++ 使用
`TouchGetInt64` 读取并透明转发；这兼容当前旧 native HAP，也兼容未来 native 重建。此前
`2026091302/1303` 废弃。最终候选 HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-owner-device-bias-20260911-r3-signed.hap`，已完成
构建、签名、verify-app 和 marker/hash 校验，仍待实体机安装与同进程重入验收。

## 2026-09-11 r4b 全屏事务队列复核

新增 `FullscreenPlatformTrace` 仅用于定位平台事务边界。r4b 冷启动实体机基线通过；同一 PID
退出页面、脚本化重搜并回入同一视频后，触控 Down/Up 已到达 Dart，`FullscreenTrace` 也执行，
但新的全屏请求只有 `enqueue owner=2`，没有 `start`。这证明当前失败发生在
`lib/plugin/pl_player/utils/fullscreen.dart` 的进程级 `_platformTail` 之前，尚不能归因于
HCPP 命中或 MethodChannel handler 丢失。

后续应为平台队列补齐操作名、owner、start/finish/error 和页面清理边界，找出未完成的旧操作；
确认具体是 SystemChrome、原生全屏调用还是 OHOS `getLastWindow` 后，修复对应完成/失败契约。
保留 owner 串行语义，不以清空 Future、固定延时或并发绕过作为修复。

r5 实体机复测补充：直接脚本化回入目标视频后，单次全屏往返以及随后 3 个连续退出/进入周期均
通过；每个原生全屏事务均出现 `start/finish`。因此 `_platformTail` 阻塞不是每次重入必现，不能
仅凭 r5 通过断定页面生命周期已完全闭环。

随后 r6 日志明确定位了一个实际未完成操作：controller dispose 后，`preferred-orientation`
完成，而 `show-system-bar` 只进入 `start` 没有终态。OHOS native fullscreen 已由 media-kit
窗口管理系统栏，故 r7 在 dispose cleanup 中跳过 OHOS 的通用 `SystemChrome` 系统栏恢复，
保留 owner 串行队列和其它平台行为。r7 实体机冷启动全屏基线通过；从首页脚本化回入后的
owner=2 同进程 3 周期全屏和播放帧进展通过。仍需补充页面 dispose 后新 attachment 的独立门禁，
以及同源同帧颜色对比。

## r8 生命周期验证脚本边界

当前源代码诊断包在实体机上完成了 Dolby Vision 冷启动全屏/播放基线。process-live 外部 hook
同时确认进程 PID 保持不变，并在日志中观察到同一触点的 page-pop、PointerCancel、global route
removed、播放器 dispose 和 nativeSurfaceDestroyed。旧脚本的 HCPP owner/cancel/napi/attachment
匹配器与当前包的日志格式不一致，因此验证脚本改为显式区分应用页面生命周期门禁与 HCPP attachment
协议门禁：前者本轮通过，后者保留为未观测，不允许自动互相替代。当前仍待最终生产包的同进程重入
复测，以及同源同帧颜色对比。

## r9 生产包验收边界

生产包 `2026091310` 在实体机完成冷启动和同进程 3 周期 Dolby Vision 全屏往返：播放中退出
全屏回到 portrait 后继续出帧，再进入 landscape 后继续出帧，均未复现 r6 的平台队列卡死或持续
灰屏。该结果确认 r7 的 OHOS 系统栏清理边界修复在生产包中生效，但不替代同源同帧颜色验证；
HLG/HDR Vivid 样片仍保留为待办。

## r10 requestId 诊断结果

为排除 Hilog 延迟/乱序造成的错误归因，r10 为一次全屏请求生成唯一 requestId，并贯通 Dart、
MethodChannel、ArkTS handler 与窗口方向回调。实体机 3 周期脚本测试通过，证明请求链路在当前
包中可以按请求一一对应；不应再以相邻外层时间戳推断 handler 丢失。

同包 30 周期压力测试未通过正式门禁：第 3 周期在方向已经完成且画面帧仍推进后，播放器语义状态
连续 15 次为 `unknown`。该失败保留为播放/网络前置条件失败，不降低门禁，也不引入固定延时或
方向 workaround。下一步是获得稳定的播放态后重跑 30 周期；若再次失败，优先分析播放状态来源
与网络缓冲边界，而不是继续修改全屏事务。

## r10 Dolby Vision 30 周期门禁关闭

在搜索等待扩展到 30 次、播放接近片尾时使用已有结束源重置机制（阈值 80%，不放宽播放或方向
断言）后，实体机目录 `/tmp/piliplusx-ohos-fullscreen-request-trace-r10-cycles30-restart80-20260911-174606`
完成 30/30 周期并返回 0。每个周期都验证了播放中退出到 portrait、播放进展、进入 landscape、
再次播放进展；第 24 周期发生一次受控的片尾重置并通过后续验证。该证据足以关闭 Dolby Vision
播放中全屏往返的 30 周期门禁。颜色客观对比仍未完成，HLG/HDR Vivid 仍是待办，不能将本门禁
结果扩展为所有 HDR 格式或颜色问题已解决。

## r11 交付前剩余门禁

生产签名包 `2026091312` 已在实体机完成冷启动 3 周期复验；Dolby Vision 的 30 周期播放中全屏
门禁已由 r10 关闭。当前生产包默认不启用 `PlayerTouchTrace`，因此实体机上下滑探针即使执行了
`uiInput swipe`/`drag`，也不能作为亮度/音量滑动或 Flutter Down/Move/Up/Cancel 的证据。

最终交付前仍需按原计划完成：

- 使用显式 trace 的 debug 诊断包完成真实左右边缘上下滑和终止事件验证，并恢复安装生产包；
- 生产包 page-exit、surface destroy/recreate 和新 attachment 的独立实体机门禁；
- 同源同帧实屏颜色/灰屏对比；
- SDR/PQ 切换、竖屏视频主体控制条及竖屏滑动专项验收；
- 在可用真实样片出现后再执行 HLG/HDR Vivid，当前继续记录为待办。

以上项目未完成前，不能把 Dolby Vision 全屏 30 周期通过扩大解释为整个播放器架构整改完成。

## 2026-09-13 r22 architect 终审与代码收敛

独立 architect 基于当前代码、实际 `media-kit` sibling、native 补丁、验证脚本和 r21 实机
证据复核后，确认整改方向总体正确，但指出三项必须修复的生命周期缺口：native surface
销毁后恢复 Texture 前必须清除 mpv 的 PQ/HLG target 并显式恢复 SDR；输出重建的 fallback
创建完成后必须重新检查事务 generation，过期 controller 只能释放不能发布；OHOS dispose
必须按实际使用的 native fullscreen backend 对称执行退出清理。上述三项已分别落在
`media_kit_video` 的 destroy/resume 路径和 PiliPlusX 的 output fallback/fullscreen cleanup
路径，不能仅凭既有 r21 运行结果关闭。

architect 同时指出单指手势在 1 像素级别抢占 arena 会偷走轻微 tap 抖动。现已将播放器 tap
和单指手势共享 `kPlayerTapSlop=2.0`；业务层仍保留标准 `kTouchSlop`，以兼顾 OHOS 父级
Scrollable 的仲裁时序与点击语义。对应测试覆盖了 tap jitter 不触发方向过滤、超过共享阈值
才进行 arena claim；竖屏中心/边缘及横屏亮度/音量的 r21 实机证据仍需在新包上复跑。

本次 architect 终审仍不通过，原因不是方向错误，而是以下真实验收尚未完成：新代码尚未重新
构建安装并执行 surface destroy 后恢复播放；未形成同进程活动 pointer Cancel → 新 attachment
→ native ready → 持续出帧的闭环；颜色同源同帧对照仍为 `INCONCLUSIVE`；HLG/HDR Vivid
继续按用户决定保留待办；macOS 共享代码回归尚未完成。旧 HCPP attachment protocol 与
应用页面生命周期 verdict 继续分开记录。

### r22 实施后脚本复验结果

r22 已完成开发包构建安装，补齐了 media-kit native surface destroy 后清除 HDR target 并在
Texture 恢复时显式恢复 SDR、输出 fallback 的 generation 检查、OHOS native fullscreen 对称
清理，以及 tap/单指 arena 共用的 2px 阈值。

- 竖屏中心动态矩形滑动已在实体机观察到完整播放器接管链；播放器下方区域仍应由推荐列表滚动。
- r22 DV 3 周期全屏/播放回归通过；颜色仍未形成客观同源同帧结论。
- 横屏边缘脚本虽返回 `No Error`，但没有采集到亮度/音量 recognizer 和数值变化，故不关闭该门禁。
- 冷重启 surface 脚本通过新 Flutter surface/native window 和播放进展检查，但不冒充同进程
  native video surface 重建或 PointerCancel 闭环。

下一步先修正/隔离横屏边缘手势采集窗口并取得真实亮度/音量记录，再实现同进程 surface
destroy → native ready → 播放恢复的脚本门禁；随后完成 HDR→SDR→HDR 同进程同源同帧显示比较
和 macOS 共享代码回归。HLG/HDR Vivid 没有可靠样片时继续保留待办。

media-kit 共享回归补充：OHOS 控制器不再直接访问 `PlatformPlayer` 的 protected
`releaseCallbacksActive`，改为 `NativePlayer.isReleaseCallbacksActive` 只读封装；定向
`dart analyze` 已从 1 个 warning 降为 0 个 warning（仅保留 2 个既有 doc comment info）。

r25 已把该 accessor 纳入实体机包并复验：持续播放基线通过，process-live 应用生命周期门禁
通过且 PID 稳定；HCPP attachment protocol 仍未观测。可用真彩/PQ 源 3 周期通过，HLG/HDR
Vivid 继续按要求跳过。矩阵对照源的页面 portrait 不等于视频竖屏，脚本已改为只有显式
`VERIFY_SOURCE_PQ_HLG_SDR_VERTICAL=1` 才传入竖屏约束，避免方向误判；该源仍因控制条语义
不稳定而未关闭。

对真正竖屏源 `BV1Wp4y1P7KU`，r25 首轮和第二轮全屏往返均保持 portrait 并有播放帧进展；
第三轮因源过短自然结束后恢复未稳定，故仍不关闭长周期竖屏门禁。该证据确认竖屏“不旋转”
路径已可工作，但不能替代控制条长期稳定性和颜色验收。

r25 竖屏中心手势脚本随后在全屏稳定前置处观察到实际窗口为 landscape，按 fail-closed 规则
停止，未产生手势结论；目录为 `/tmp/piliplusx-ohos-vertical-gesture-r25-center-20260913-212431`。
该轮不能替代已通过的短周期 portrait 证据，也不能归因于推荐列表滚动。

### r25h 同进程 surface 重建闭环

新增 `tool/ohos/verify_surface_page_exit_reentry_real_device.sh`，并修正主 gate 对空搜索结果页
的归一化。实体机目录 `/tmp/piliplusx-ohos-surface-page-exit-reentry-r25h-20260913-215135`
完成了完整应用层闭环：同一 PID=`32340` 下，旧 `platformViewId=0` dispose 后出现
`nativeSurfaceDestroyed`，随后重入创建新 texture、新 `platformViewId=1` 和新
`nativeSurfaceReady`；新旧 surface ID 分别为 `25683904435488` 与 `25683904435489`。重入后
全屏方向往返、HDR decision 和视频主体帧进展均通过，关闭此前未完成的同进程 surface
重建门禁。HCPP attachment protocol 仍作为独立统计保持 `NOT OBSERVED`，不能与应用层
生命周期证据混并。

### r25i 触控边界结论

用户实测的“竖屏状态上下滑动滚动下面推荐列表”与当前页面结构一致：播放器位于
`ExtendedNestedScrollView` 的 header，推荐内容位于 body；播放器的
`MouseInteractiveViewer` 只覆盖视频矩形。该行为应作为边界回归，而不是通过全页透明层抢占
Scrollable。播放器外拖动必须继续交给推荐列表，播放器内拖动才由播放器 recognizer 根据
起点、方向和 fullscreen 状态分类。

实体机 r25i 的动态 `drag` 仍因控制条重现不稳定而未形成完整 Move/accept/pan 链，说明剩余问题
是运行时输入采样与控制条时序证据不足，不能用 `uiInput` 返回 `No Error` 或推荐列表滚动结果
替代播放器手势通过结论。
### 2026-09-13：触控边界落地

针对竖屏滑动进入推荐列表的问题，采用“PointerDown 时按实际播放器几何范围过滤外层 Scrollable 入场”的边界方案。播放器区域内外分别固定所有权，播放器自身继续使用正常业务 slop；不以扩大 overlay、全局滚动物理或降低阈值作为最终修复。Flutter SDK、`extended_nested_scroll_view` 和构建脚本均已纳入可重复补丁链，后续实体机只验证行为，不手工修改 SDK。

### 2026-09-13 architect 终审复核

独立 architect 复核指出：方向正确，但在实体机验收前不能关闭整改。已据此补齐普通 CI 与 OHOS CI 的依赖补丁入口，锁定状态下播放器区域仍拒绝外层入场，增强真实 `ExtendedNestedScrollView` 测试为“区域内外过滤结果 + 外层 offset”断言，并为 Flutter 源码变换加入部分应用和源片段唯一性校验。r31 已重新构建签名通过；实体机因 HDC `Offline` 尚未安装回归。

后续修正覆盖了 architect 复核中发现的干净 SDK 分支差异，并验证本机已有自定义 Flutter 补丁状态可幂等重跑（`Flutter pointer filter: 0 file(s) changed`）。最新 r32 已在干净 OHOS 构建链上重新构建、签名和 `verify-app`。macOS debug 构建回归也通过，产物为 `build/macos/Build/Products/Debug/PiliPlusX.app`；这只关闭构建门禁，不替代 macOS 实机 HDR/播放视觉验收。

最终复核后的交付链补充：`patch.ps1` 在普通平台补丁完成后应用 Flutter pointer-filter API，并在 `pub get` 后应用 `extended_nested_scroll_view` 依赖补丁；OHOS workflow 在依赖解析后执行同一依赖补丁，并运行播放器嵌套手势回归。上述静态/CI 链路已闭合，实体机安装与持续播放中的手势、控制条和颜色视觉门禁仍保持独立未关闭。

### 2026-09-14 后续构建门禁

全量 `flutter test` 共 59 项通过；`flutter build macos --debug` 成功生成
`build/macos/Build/Products/Debug/PiliPlusX.app`。该结果只证明共享代码可编译和单元/组件测试通过，
不替代 macOS HDR 视觉回归。实体机 HDC 当前无目标，OHOS 播放、灰屏、HCPP 和持续手势门禁继续保持未关闭。

### 2026-09-14 实体机重连后的新证据

同一 r32 候选包已完成播放器内竖滑与播放器下方推荐列表的正反边界验收；两个脚本均通过。
同时修复了版本更新检测将推荐标题误判为弹窗、以及推荐列表脚本释放无关全屏 gate 后污染 verdict
的两个脚本问题。真彩 Dolby Vision 3 周期回归通过；30 周期回归因第 2 周期退出全屏后语义播放
状态变为 `unknown` 而 fail-closed，不能计为 30 周期通过。慢启动 HDR 等待窗口已从默认约 8.5
秒延长到约 24.5 秒，并保持可配置；不以视频帧变化替代稳定播放语义。颜色同源同帧、HCPP
attachment Cancel/surface 生命周期和完整 DV 长周期门禁仍待继续验证。

为区分控制条超时和播放缓冲，新增 debug-only `player-state` trace，并用新签名 HAP 完成 3 周期
真彩回归。trace 显示 `playing=true` 仅初始化一次，之后持续发生 `buffering=true/false` 抖动；
因此 30 周期第 4 周期的失败属于真实播放/缓冲不稳定，而非仅由控制条无障碍节点超时隐藏造成。
后续应先取得稳定播放前置，再继续 DV 长周期；不得改为用 slider 或视频帧变化替代播放状态。

### 2026-09-14 buffering 来源诊断门禁

architect 复核指出，当前 30 周期失败不能先归因于控制条：state-trace 已显示数秒级真实
buffering，且旧脚本曾在 `before=playing after=buffering frame=changed` 时由
`slider-plus-video-frame` 弱证据放行。现已收紧脚本，任一采样端为 buffering 时不再接受
position+视频帧或 restart-position 作为稳定播放证据。

下一步固定同一 debug HAP 及其实际 media-kit/HAR/native 身份，关闭 process-live 注入，记录
media-kit 原始 `core-idle`、`paused-for-cache`、缓存水位、position、seek/EOF、surface/output
generation 与 fullscreen requestId 的同一时间线。只有完成该归因后才选择修复层级：缓存先耗尽
进入数据供给/缓存配置；派生状态错序进入 media-kit 归并层；停顿紧随输出重建进入 OHOS VO
生命周期；仅当底层播放稳定而无障碍节点丢失时才调整控制条展示。暂不新建控制条状态机，也不
放宽 30 周期门禁。

## 2026-09-14 方向事务修复后的复验边界

为处理长周期中退出全屏后偶发保持横屏的问题，`PlPlayerController` 在 OHOS 全屏请求队列
处理期间忽略中间方向事件，避免过期方向回调向同一 owner 追加 enter/exit 请求。定向 Flutter
测试 19 项通过；新 debug HAP
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-orientation-guard-20260914-signed.hap`
已签名并通过 `verify-app`。实体机在线时使用该包完成 4 个热缓存 Dolby Vision 周期，包含
片尾重启路径，方向与播放推进均通过，artifact 为
`/tmp/piliplusx-ohos-dv-orientation-guard-4cycles-20260914-1200`。

按同一条件继续执行 20 周期时，第 4 周期方向仍正确恢复 portrait；随后设备 HDC 变为
`USB Offline`，布局 dump 无输出，脚本 fail-closed 停止，artifact 为
`/tmp/piliplusx-ohos-dv-orientation-guard-20cycles-20260914-1230`。该轮不计入 20 周期通过，
也不构成播放器断言失败。实体机恢复 Online 后必须从头重跑完整 20 周期。

验证脚本同时修正了播放状态重试：控制条超时后每次重试从最新布局重新唤醒，避免把隐藏控制
条误判为 `unknown`。热缓存、不 seek 的一周期诊断显示全屏尺寸变化发生时没有新增
`core-idle/paused-for-cache`，但颜色仍未形成同源同帧结论。

本轮静态复核时实体机仍为 `[Empty]`，未重复物理测试。Flutter 定向测试 25 项通过，播放器
全屏相关 `flutter analyze` 通过，全部 OHOS shell 脚本 `bash -n` 通过，macOS debug 构建成功。
上述证据不关闭实体机 20 周期、同源同帧颜色、HCPP protocol Cancel、surface 生命周期或手势
专项门禁。

独立 architect 随后确认 `PlPlayerController` 的方向监听入口只在 `PlatformUtils.isMobile` 下
注册，而该条件不包含 OHOS；新增的 OHOS transaction guard 没有可达性证据，已撤回。正式验证
器现默认拒绝 `playing→unknown` 等弱播放证据，`VERIFY_ALLOW_WEAK_PLAYBACK_EVIDENCE=1` 仅
允许诊断运行，不能计入正式周期。恢复设备后应先采集当前 HAP 的方向事件、requestId、窗口尺寸、
surface generation 和 buffering 的统一时间线，再决定 native barrier 或应用队列的修复层级。

当前源码对应的新 debug HAP 已重新构建、签名并通过 `verify-app`：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-strict-playback-20260914-signed.hap`，SHA-256 为
`6990d0577efcd5a5bdb769720581b22cb2a1c9edd7df6f80bb90f8588e131c5b`。构建完成时 HDC 仍为
`[Empty]`，尚未安装或运行该候选包。

根据 architect 对原生完成屏障的复核，`media-kit` OHOS `Utils.ets` 已改为只有在
`setPreferredOrientation` 成功且窗口几何匹配时才完成方向事务；窗口尺寸事件先到不再提前
resolve，API 失败仍立即 reject。基于该源码重新构建签名 HAP：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-strict-barrier-20260914-signed.hap`，SHA-256 为
`1f04308443e7aec50ef0ec94f53edf34d52d857c09c7d28d3bb5eff493e0cdc6`，并通过 `verify-app`。
构建后 HDC 仍为 `[Empty]`，尚未安装或进行实机验证。

进一步修复同一 controller 的 surface-loss 恢复：`nativeSurfaceDestroyed` 现在只在 controller
已 dispose 时清除 native candidate；存活 controller 会保留候选资格，使新的 XComponent 和
generation 能重新发出 `nativeSurfaceReady`，再恢复 native 输出/HDR。该改动已重新构建签名并
通过 `verify-app`：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-surface-recovery-20260914-signed.hap`，SHA-256 为
`80bb0fe32240220a8affed08b892e53d99426af2c98486865f8fcdba85e80de2`。HDC 仍为 `[Empty]`，
尚未安装或实测。

## 2026-09-14 HDC 恢复后的触控边界证据

上述 `[Empty]` 状态已过时；实体机 `2PM0223A18006914` 后续恢复 Online，并使用同一份
surface-recovery HAP 完成了两条相反边界的脚本验收：

- 播放器下方推荐列表脚本通过，artifact 为
  `/tmp/piliplusx-ohos-recommendation-scroll-20260914-154126`。列表文本锚点在竖向拖动后上移，
  证明外层推荐列表仍可滚动。
- 竖屏播放器中心竖滑脚本通过，artifact 为
  `/tmp/piliplusx-ohos-vertical-gesture-windowed-20260914-154454`。同一 pointer 依次记录了
  `outer-scroll pointer-rejected`、`accept-single-pointer action=fullScreen`、`gesture pan-start`
  和 `gesture pan-update type=fullscreen`；因此播放器区域内的指针所有权和手势仲裁成立，
  推荐列表滚动不能解释为播放器区域内的事件丢失。
- 对应 Flutter 交互测试 11 项全部通过；竖屏专项脚本现在默认
  `VERIFY_REQUIRE_HDR=0`，因为它验证的是输入边界，不应被 HDR 源前置条件阻塞。HDR 播放/全屏
  门禁仍保持严格要求，未被放宽。

随后使用同一候选包执行严格一周期 Dolby Vision 复验，artifact 为
`/tmp/piliplusx-ohos-dv-surface-recovery-1cycle-154924`。该轮在进入周期前再次 fail-closed：
全屏后出现 `playing → buffering`，同时记录 `paused-for-cache=true`；随后发生
`nativeSurfaceDestroyed(generation=2)`、`nativeSurfaceReady(generation=3)`，恢复后再次进入
buffering。该证据进一步说明当前首要未闭环项是播放/输出重配置期间的缓存状态与 Surface/VO
恢复，而不是播放器区域手势所有权；仍不能放宽播放门禁或把一周期算作通过。

同一候选包的严格 Dolby Vision 20 周期尝试仍未通过：
`/tmp/piliplusx-ohos-dv-surface-recovery-20cycles-20260914-151941` 在第 1 周期退出全屏时，
语义树虽暴露“退出全屏”，但 Flutter 没有产生对应退出事件；进一步的一周期诊断
`/tmp/piliplusx-ohos-dv-control-wake-recover-1cycle-153649` 显示播放期间发生
`paused-for-cache` 抖动和 `nativeSurfaceDestroyed(generation=1)` →
`nativeSurfaceReady(generation=2)`，重建后播放状态恢复但采样帧未变化。该结果保留两个未关闭门槛：
控制层可点击时序，以及 Surface/VO 重建后的真实连续帧恢复。不能把本轮触控通过或 Surface
ready 事件当作 HDR 颜色、长周期播放或 HCPP Cancel 通过。

## 2026-09-14 native surface handoff A/B 复验

基于上述时间线，media-kit OHOS 控制器已移除 `nativeSurfaceDestroyed` 后立即执行的
`ResumeTexture -> SDR VO restart` fallback。Surface 短暂丢失时保持 native handoff 状态，等待
下一代 `nativeSurfaceReady` 直接重新挂接，避免额外的 Texture/SDR BufferQueue 和播放状态重启。
media-kit P1 contract test 通过，新的开发 HAP 为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-native-surface-handoff-20260914-r17-signed.hap`。

实体机一周期 artifact `/tmp/piliplusx-ohos-native-surface-handoff-1cycle-1604` 证明该改动
确实消除了 `ResumeTexture` 日志，但仍在后续重配置期间失败；日志中出现：

- `MAPPER_SRV ReAllocMem failed, ec = -5`；
- HCPP `PlatformViewsControllerHybrid ... dispose (HCPP) done`，随后
  `nativeSurfaceDestroyed -> nativeSurfaceReady`；
- `EGL_BAD_MATCH` / `Could not create EGL surface`；
- 播放位置归零及 `playing/buffering` 重置。

随后使用 `OHOS_DIAGNOSTIC_FIXED_PRODUCER_EXTENT=true` 的单变量 A/B 包
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-fixed-producer-20260914-r18-signed.hap`
和 artifact `/tmp/piliplusx-ohos-fixed-producer-1cycle-1609` 复验；仍出现相同的
`ReAllocMem`、HCPP dispose 和 EGL 错误。因此当前根因不能归结为 mpv producer extent
在方向切换时的重新分配，而已收敛到 OHOS Flutter/HCPP 合成层的 RenderService 资源重分配
失败。固定 producer extent 仅保留为诊断开关，不能升级为正式修复。

当前修复边界：保留 native surface handoff 改动；不再增加颜色 setter、Texture fallback
或播放状态 workaround。下一步应在 Flutter/OHOS embedding/HCPP 合成层取得 RenderService
资源失败的最小复现与 Surface buffer 数量/尺寸证据，再决定是否降低 HCPP overlay 的资源占用
或改变平台视图生命周期。严格 Dolby Vision 长周期、同源同帧颜色和 HCPP attachment/cancel
门禁继续保持未关闭。

## 2026-09-14 HCPP dispose 因果边界复核

继续检查远端 Flutter OHOS embedding 源码后确认：`PlatformViewsChannelHybrid.dispose()`
只会处理 Flutter/Dart 通过 `flutter/platform_views_2` 明确发出的 `dispose` 消息；它随后调用
`PlatformViewsControllerHybrid.dispose()`，销毁 `EmbeddingNodeController`/wrapper 并调用
`platformView.dispose()`。`OHOSExternalViewEmbedder` 的 `EndFrame()` 只清理过期几何缓存，
不会自行向该 channel 发出 dispose。

因此实机日志中的顺序必须拆开解释。r18 artifact
`/tmp/piliplusx-ohos-fixed-producer-1cycle-1609` 在 `16:10:30.801` 先记录
`pause=true`，同时 RenderService 报 `ReAllocMem failed, ec=-5`；随后在
`16:10:30.834` 收到 `flutter/platform_views_2 dispose id=0`，再于
`16:10:30.844` 出现 `OhosNativeSurface onDestroy`。这证明 HCPP 的 dispose 是明确的
Dart/Flutter 平台视图生命周期动作，而不是可以直接等同于 mpv VO 的 dispose。当前仍有两种
待区分路径：

1. Flutter widget/output 重建先移除了 PlatformView，RenderService 的分配失败是并发结果；
2. RenderService 先失败并破坏了布局资源，应用随后因状态/布局变化移除 PlatformView。

当前代码中最需要取得证据的是 `_videoController` 是否在同一时间窗被置空、
`_rebuildVideoOutput()` 是否被调用、以及 `PlatformViewLink` 是否因 widget identity 变化进入
dispose。没有这三项时间线前，不应把 HCPP dispose 修改成吞掉请求，也不应继续添加颜色或播放
状态 workaround。远端 embedding 的 `dispose`/`createForPlatformViewLayer`/`onEndFrameHybrid`
源码复核已完成；下一步是给应用输出重建入口补带原因和 transaction generation 的诊断，并用同一
次全屏操作复验。
## 2026-09-14 r19 输出重建诊断复验

r19 已安装到实体机 `2PM0223A18006914`，严格 Dolby Vision 单周期 artifact 为
`/tmp/piliplusx-ohos-output-trace-1cycle-1622`。门禁仍失败：`before=playing after=playing`，但
采样帧未变化，不能算真实播放通过。

本轮日志再次确认：`ReAllocMem failed, ec=-5` 与 `EGL_BAD_MATCH` 持续出现；随后收到
`flutter/platform_views_2 dispose`，再出现 `OhosNativeSurface onDestroy` 和
`nativeSurfaceDestroyed`。但日志中没有新增的 `[OhosOutputTrace] rebuild-*` 或
`video-params topology-change` 记录。因此当前证据不支持“PiliPlusX 的
`_rebuildVideoOutput()` 主动触发了这次 HCPP dispose”；更接近于 Flutter/HCPP 合成层或其布局
资源异常导致平台视图生命周期被销毁，应用随后重新创建 view。该结论仍需在更早的 output/widget
生命周期入口补齐诊断或在 embedding 层取得对应 dispose 调用栈后最终确认。

剩余硬门槛：RenderService/HCPP `ReAllocMem` 资源失败的最小复现与根因、Surface/VO 重建后
连续帧恢复、严格 Dolby Vision 多周期播放，以及播放期间全屏/退出全屏后的颜色与亮度稳定性。
竖屏播放器中心手势与推荐列表边界已有脚本证据，但实体机连续手势和控制条超时窗口仍需在真实
连续播放通过后复验。HLG/HDR Vivid 样片仍按待办处理，未阻塞当前 Dolby Vision 根因收敛。
## 2026-09-14 r22 native candidate 生命周期修复复验

r21 追踪确认 `VideoState` 未销毁，但 OHOS HCPP 子树在 `_visible=false` 时被条件渲染移除：
`id/rect/candidate` 仍有效，随后才收到 `nativeSurfaceDestroyed`。因此 HCPP dispose 的直接
触发点是视频宽高短暂归零造成的 UI 子树卸载，而不是 `_rebuildVideoOutput()`。

r22 在 media-kit 中保持已经挂载的 OHOS native candidate，不因临时 decoder visibility loss
卸载；同时用 `nativeSurfaceGeneration` 作为 `PlatformViewLink` key，仅在明确的 Surface
generation 变化时重建 XComponent。实体机 artifact 为
`/tmp/piliplusx-ohos-surface-mount-fix-1cycle-1646`：全屏/退出全屏期间未再出现
`PlatformViewsControllerHybrid dispose (HCPP)`、`OhosNativeSurface onDestroy` 或
`nativeSurfaceDestroyed`，说明这条 UI 生命周期回归已被消除。

本轮严格播放门禁仍失败：`before=playing after=playing` 但帧未变化；日志仍有短时
`paused-for-cache`、`buffering` 和 `demuxer-cache-time` 低水位，且 RenderService 仍报告
`ReAllocMem failed, ec=-5`。因此 Surface 提前卸载问题已取得实体机修复证据，但连续帧恢复、
网络/缓存稳定性、HDR 亮度颜色以及多周期 Dolby Vision 仍未通过，不能将本轮视为最终验收。
## 2026-09-14 r22 延长播放与画面证据

使用同一 r22 包延长严格门禁等待 30 秒，artifact 为
`/tmp/piliplusx-ohos-surface-mount-fix-1cycle-1650`。播放位置确实从约 54 秒推进到 65 秒，
说明网络/解码链并非完全停死；但脚本仍报告 frame unchanged，且进度采样后的截图显示视频
区域为黑色。采样过程中在控制条唤醒/中心点击后出现 `playing=false`、位置归零，再次进入
`playing=true/buffering=true`；同时 HCPP input 日志持续 `displayed=0`。因此当前剩余问题已从
“Surface 被提前销毁”进一步收敛为：控制条唤醒或布局切换后，HCPP overlay 的显示状态与 mpv
播放输出脱钩，导致画面黑屏/不更新；这不能用网络缓存单独解释。

r22 的 Surface 生命周期修复仍有效：该 artifact 没有 HCPP dispose、`onDestroy` 或
`nativeSurfaceDestroyed`。下一步应追踪 `displayed=0` 的 Flutter external-view geometry/layer
路径，以及中心点击后播放器位置归零的调用链；在这两项闭环前，不进入多周期 HDR 颜色验收。

## 2026-09-14 r23 播放器重试与 surface resize 交叠证据

r23 在 controller、OHOS video controller 和实机脚本中加入了 `[OhosPlaybackTrace]`，artifact
为 `/tmp/piliplusx-ohos-playback-trace-1cycle-1700`。全屏稳定截图仍有真实视频画面；随后播放
期间发生 `refreshPlayer(position=3.537s, playing=true, buffering=true)`，紧接着出现
`OHOS resize begin/end: 2520x1260`，播放器状态短暂变为 `playing=false, position=0`，再恢复为
`playing=true` 并回到约 3 秒，但恢复后的截图视频区域仍为全黑。同期没有
`flutter/platform_views_2 dispose`、`OhosNativeSurface onDestroy` 或 `nativeSurfaceDestroyed`。

这证明 r22 已解决的 PlatformView 提前卸载不是当前黑屏的充分原因；当前时间线存在两个相互
交叠的触发因素：网络/缓存低水位触发 `refreshPlayer`，以及控制条唤醒/布局变化触发 native
surface resize。尚不能把黑屏单独归因于 HCPP `displayed=0`，因为远端 embedding 源码表明该
字段只描述 HCPP 输入矩形可见性，不等价于视觉 layer 是否绘制。

当前剩余硬门槛：在隔离网络重试与 resize 的条件下确认 mpv/VO 首帧是否恢复；修复 resize 后
HDR native output 的连续帧恢复；再复验播放中全屏/退出全屏的亮度颜色稳定性、连续 Dolby
Vision 多周期播放、竖屏视频区手势不穿透推荐列表，以及 HDR Vivid/HLG 样片（暂列待办）。

## 2026-09-14 r24-r25 buffering overlay 交互修复

r24 的原因追踪确认，r23 中的 `refreshPlayer(reason=unspecified)` 并非来自 surface 生命周期，
而是来自视频视图中的 buffering overlay：该 overlay 在播放 buffering 时覆盖视频主体，并将
`onTap` 直接绑定到 `refreshPlayer()`。控制条自动隐藏后，脚本或用户对视频主体的唤醒点击
因此会被错误解释为“重开播放器”，造成位置归零、resize 与播放器重启交叠，最终出现黑屏。

r25 移除了 buffering overlay 对视频区点击的拦截，保留加载提示为纯视觉层；只有明确的 HDR
输出初始化失败提示仍允许点击重试。Flutter analyzer 和播放器/手势测试 17 项通过。

实体机 r25 artifact 为 `/tmp/piliplusx-ohos-buffer-overlay-fix-1cycle-1720`。脚本结果为：

- HDR decision evidence: PASS；
- 4 个播放采样均 `playing` 且 `frame=changed`；
- 播放中退出全屏、再次进入全屏，以及转场后播放采样均通过；
- 本轮没有 `[OhosPlaybackTrace] refreshPlayer`、HCPP dispose、`onDestroy` 或
  `nativeSurfaceDestroyed`；
- RenderService 仍报告 `ReAllocMem failed, ec=-5`，并有早期 `EGL_BAD_MATCH`，但未阻止本轮
  连续帧恢复；颜色结论仍为 inconclusive，尚未完成同源同帧亮度/色彩验收。

因此“加载层误拦截视频唤醒手势导致重开和黑屏”已取得代码与实体机回归证据；剩余重点转为
RenderService 资源错误是否影响长周期稳定性、Dolby Vision 多周期颜色/亮度验收、竖屏视频区
上下滑手势与推荐列表边界的实体机专项，以及 HLG/HDR Vivid 样片待办。

## 2026-09-14 斜向手势误触发 seek 的修复计划与代码约束

新增交互问题：稍倾斜的上下滑动会被播放器误识别为 seek。根因是原先的方向条件同时使用
`dx > 3 * dy || dy <= 3 * dx`，除极少数情况外总有一项成立，导致接近对角线的手势也进入
horizontal seek 分支。

已落实第一步修复：新增 `isPlayerHorizontalSeekDelta` 和共享主导比例常量，只有水平位移严格
超过垂直位移 3 倍才允许进入 seek；垂直主导和接近对角线的手势交给竖向手势/推荐列表边界。
边界单测覆盖 `30:9` 可 seek、`30:10` 临界拒绝和 `30:15` 对角线拒绝。Flutter analyzer
和播放器/手势测试已通过。

待实体机专项确认：在竖屏视频页面分别执行明显左右滑、轻微斜向上/下滑和明显上下滑，验证
seek、全屏/亮度/音量手势及推荐列表滚动没有互相穿透；该专项仍不能由本地单测替代。

## 2026-09-14 r25 长周期验证边界与脚本防护

r25 的 20 周期验证 artifact 为
`/tmp/piliplusx-ohos-buffer-overlay-fix-20cycles-1830`。第 1--6 周期完成；第 5 周期
触及自然 EOF，脚本回到起点后重新取得了 `playing + frame=changed` 证据；第 7 周期也通过了
一次可恢复的转场后重启。第 8 周期退出全屏后的前置截图仍显示视频画面、播放控制条和原生黑色
XComponent，RenderService 的 color contract 也保持有效。

但约 30 秒后的采样布局根节点已经变为 `com.sydxky.hapkit`，不再是目标包
`com.example.piliplusx`；此后旧脚本仍尝试从错误应用布局寻找视频并重复点击，最终以
`video surface not found` 失败。该结果不能归因于播放器黑屏或 HCPP dispose，也不能算 20 周期
通过。脚本现已在播放状态重试前校验根布局的前台包名，发现应用切换即记录
`foreground-app-mismatch` 并停止输入，避免向错误应用发送触控。

仍需重新在目标应用持续位于前台、设备保持唤醒的条件下完成长周期 Dolby Vision 验证；当前
RenderService `ReAllocMem failed ec=-5`、颜色/亮度主观验收和竖屏手势专项仍未闭环。

## 2026-09-14 r26 斜向手势与竖屏边界实体机验收

r26 签名包为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-gesture-dominance-fix-20260914-r26-signed.hap`。
在实体机 `2PM0223A18006914` 上使用脚本完成以下验证：

- 竖屏边缘上下手势：通过，日志记录 `reject-portrait-edge`，未进入 seek；
- 竖屏中心上下手势：通过，日志记录播放器接受 center vertical gesture；
- 推荐列表边界：通过，列表文本锚点从 `2069` 移到 `1891`，确认上下滑动能滚动推荐列表；
- 两次专项的播放门禁均为 `playing + frame=changed`，全屏保持 portrait。

因此“稍倾斜的上下手势误触发 seek”已完成代码修复和竖屏实体机边界回归。仍缺少的是
真实斜向轨迹本身的实体机专项（明确的水平、接近临界的斜向、明显垂直三组），以及与此无关的
长周期 Dolby Vision、RenderService 资源错误和同源同帧颜色/亮度验收。

## 2026-09-14 控制条唤醒脚本修正与 r26 短周期边界

r26 的一次短周期 artifact 为 `/tmp/piliplusx-ohos-buffer-overlay-fix-r26-3cycles-1935`。
第 1 周期在退出全屏前播放帧仍正常变化，截图显示视频画面和控制条均可见；失败原因是旧脚本
在每次寻找全屏按钮前无条件点击视频中心，随后布局只暴露 Slider，且控制条按钮已被该点击隐藏。

验证脚本现已增加 `ensure_fullscreen_controls_visible`：先从最新布局查找全屏按钮，只有确实未
暴露时才唤醒控制条，避免把一次合法的可见窗口切换成隐藏窗口。该修改已通过 `bash -n`；需要
在实体机前台稳定为目标应用的条件下重新执行短周期和长周期验证。

本轮另一次启动失败的 artifact 为 `/tmp/piliplusx-ohos-buffer-overlay-fix-r26-1cycle-1945`：
搜索输入后的布局根包变成 `com.tencent.wechat`，不是目标应用，脚本已 fail-closed 停止。该
结果是实体机前台状态漂移，不作为播放器故障证据；当前设备需要保持 PiliPlusX 在前台后再继续
验证。

## 2026-09-14 斜向 seek 三轨迹实体机专项闭环

修正 `tool/ohos/verify_player_seek_direction_real_device.sh` 的证据采集时序。OHOS 的
`uiInput` 返回后，Flutter settings-log 到长期 `hilog` 读流存在数秒延迟；逐次读取即时
`hilog -x` 会误判为“播放器没有收到手势”。脚本现在保持 fullscreen gate 暂停，等待异步日志
转发完成后，从同一进程的 gate 日志按注入顺序读取三条 `gesture move-filter` 决策，再释放 gate
继续执行诊断收尾。

r26 实体机专项 artifact：
`/tmp/piliplusx-ohos-seek-direction-r26-20260914-183636-retry`。

- 明显水平滑动：`horizontal`，进入 seek；
- 接近 2:1 的斜向滑动：`reject-portrait-edge`，未进入 seek；
- 明显竖向滑动：`fullscreen`，未进入 seek；
- 播放门禁：`playing + frame=changed`；
- 脚本结论：`PASS (only clear horizontal swipe entered seek)`。

因此“稍倾斜的上下手势误触发 seek”已完成代码、单测和真实实体机三轨迹验证，不再列为剩余
问题。仍需独立处理 HCPP 控制条唤醒、Dolby Vision 长周期以及同源同帧颜色/亮度验收。

本轮还确认了脚本证据边界：`hilog -x` 的逐次快照不能作为异步 Flutter touch trace 的唯一
来源；脚本必须保留 gate 的长读流，并在释放 gate 前等待日志转发完成。该规则已写入脚本注释，
避免后续把“日志未及时出现”误报为“手势未到达 Flutter”。

## 2026-09-14 r26 播放中退出全屏的 HCPP 输入断点

使用已修正控制条唤醒逻辑的 r26 包重新执行 Dolby Vision `BV15z4y1Z734` 一周期脚本，artifact
为 `/tmp/piliplusx-ohos-buffer-overlay-fix-r26-1cycle-184008-retry2`。进入全屏后、退出操作
前的播放样本通过：`playing + frame=changed`。但脚本从语义布局点击“退出全屏”后，
`09-cycle-1-exit-fullscreen-stable.json` 仍为 landscape，按钮语义仍为 `退出全屏`，因此本周期
不通过。

该点击的日志链为 HCPP `overlay Down/Up` 与 `napi-request`，但没有随后对应的 Flutter
`PlayerTouchTrace`；同一阶段持续出现 `hcpp_input publish ... rects=1 displayed=0`，并伴随
RenderService buffer queue / metadata 错误。说明当前最小断点是“ArkUI overlay 已收到触摸并
请求 NAPI，但 Flutter pointer route 没有产生业务点击”，不能继续把它解释为单纯的全屏方向
切换等待或网络缓冲。下一步应在真实 HAP 的 NAPI dispatch、Flutter pointer packet 和 overlay
命中坐标之间增加一一对应的序列证据，再决定修复 embedding 还是应用侧控制层。

## 2026-09-14 HCPP 输入层序 A/B 修复与三周期回归

针对上一节的断点，在 OHOS embedding 的 `FlutterPage.ets` 中将
`HcppInputRectLayer` 放到 `FlutterOverlayBlock` 之上，使完整 DISPLAY 区域的输入由统一
`input` owner 接管；不改变 native `libflutter.so`，也不在播放器控件层增加重复点击 workaround。
本地 `tool/ohos/build_sign_hap_test.sh` 已加入幂等补丁和顺序门禁，保证外部 engine checkout
刷新后仍会应用同一修复。

A/B 包：
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-hcpp-input-zorder-20260914-signed.hap`。

实体机一周期 artifact：
`/tmp/piliplusx-ohos-hcpp-input-zorder-20260914-rerun3`。

实体机三周期 artifact：
`/tmp/piliplusx-ohos-hcpp-input-zorder-20260914-3cycles`。

结果：

- 一周期和三周期均完成播放中进入/退出全屏；退出后为 portrait，重新进入为 landscape；
- 三周期共取得 10 次 `playing + frame=changed` 语义播放采样，HDR decision evidence 通过；
- 退出按钮事件在 Flutter 侧出现 `PlayerTouchTrace`，并产生
  `FullscreenTrace trigger status=false`，证明点击已跨过 HCPP 到 Flutter 业务层；
- 同源 HAP 的 `libflutter.so` SHA 为
  `e5f127f6790674923d7ebfa746ba00f3e03b66b50111bf32a7bd74aef6d50162`，仍是未重建 native
  engine，故本结论归因于 embedding 输入层序，不宣称 native engine trace 已重建；
- 两次前置采样因视频自然暂停被脚本拒绝，随后从起点恢复并重新取得播放证据，未把暂停样本
  计入通过；
- 颜色 verdict 仍为 `INCONCLUSIVE`，同源同帧亮度/颜色验收及 Dolby Vision 长周期仍待完成。

## 2026-09-14 r26 20 周期回归的异步方向采样边界

尝试执行 20 周期 Dolby Vision 回归，artifact 为
`/tmp/piliplusx-ohos-hcpp-input-zorder-20260914-20cycles`。第 1--16 周期完成；第 17 周期
在视频自然到达 100% 后由脚本恢复到起点并重新取得 `playing + frame=changed`，随后点击进入
全屏。脚本的稳定采样暂时读到 portrait 并退出，但同一 artifact 的 hilog 随后出现
`fullscreen orientation request settled ... landscape=true`、`windowSizeChange ... landscape=true`
和 `handler enter result=success`，说明该次请求最终完成，现有单次稳定采样把异步旋转误报成失败。

因此本 artifact 不能作为 20 周期通过，也不能据此认定全屏业务失败。验证脚本已增加有限的方向
重采样：初次采样失败后最多等待 6 次、每次 1 秒；仍未达到期望方向时继续 fail-closed。该
调整只放宽验证时序，不改变播放器全屏逻辑，并保留每次重采样的布局和事件证据。

当前仍待重新执行完整长周期，以及同源同帧颜色/亮度验收；HLG/HDR Vivid 样片尚未纳入。

随后使用方向重采样脚本重新执行 20 周期，artifact 为
`/tmp/piliplusx-ohos-hcpp-input-zorder-20260914-20cycles-rerun`。第 1 周期的进入全屏
`landscape`、退出全屏 `portrait` 均通过，说明重采样没有掩盖方向错误；但退出后视频接近源末尾，
自动恢复分支最终仍取得 `paused + frame=unchanged`，脚本按播放门禁 fail-closed 停止。
因此完整 20 周期尚未通过，当前需要优先拆分验证“接近 EOF 的恢复播放”和“正常播放中的全屏长周期”，
不能把该结果归因为 HCPP 控制条点击失败。

对 EOF 恢复重试逻辑的 3 周期验证 artifact 为
`/tmp/piliplusx-ohos-hcpp-input-zorder-20260914-3cycles-recovery-rerun`。第 1 周期的进入、退出
及恢复后播放均通过；第 2 周期在恢复过程中设备 HDC 断开，导致布局抓取失败。本次不计为播放器
失败，也不计为回归通过。脚本同时补充了布局抓取失败即停止恢复分支的 fail-closed 保护，避免在
空布局上继续发送点击或产生空坐标证据。

脚本修订后的本地门禁：`bash -n`、`git diff --check` 通过；针对手势方向、播放器命中区域、
触控 trace 和全屏 owner/request queue 的 Flutter 测试共 26 项通过，相关模块 `flutter analyze`
无问题。该本地证据不替代实体机长周期和颜色/亮度验收。

另外，验证脚本的设备前置检查已从“目标名存在”收紧为 `hdc list targets -v` 中目标状态为
`Online` 或 `Connected`；`USB Offline` 和空列表会在任何唤醒、安装或布局操作前直接停止，避免
产生伪运行证据。

第三轮修正后 3 周期实体机 artifact：
`/tmp/piliplusx-ohos-hcpp-input-zorder-20260914-3cycles-recovery-rerun4`。

- 3/3 周期完成全屏进出，方向均符合预期；
- 周期 2、3 的片尾暂停均使用失败采样的最新布局恢复到起点，随后取得
  `playing + frame=changed`；
- 共 10 个语义播放采样通过，HDR decision evidence 为 `PASS`；
- 颜色 verdict 仍为 `INCONCLUSIVE`，不作为颜色/亮度问题的关闭证据。

该结果关闭了验证脚本的过期布局 seek/唤醒缺陷，下一步扩大到 20 周期压力回归。

## 2026-09-15 r26 20 周期长跑的 HCPP 输入交付边界

方向重采样、EOF 恢复和周期起点布局修正后，使用同一签名 HAP 执行第二次 20 周期回归，
artifact 为 `/tmp/piliplusx-ohos-hcpp-input-zorder-20260914-20cycles-final-rerun`。
第 1--10 周期完成，期间片尾恢复多次使用失败采样产生的最新布局成功回到起点，并重新取得
`playing + frame=changed`。第 11 周期在播放中点击语义全屏按钮后，方向连续初始采样及 6 次
重采样仍为 portrait，脚本按 fail-closed 停止；因此该轮不能计为 20 周期通过。

本次失败不是单纯的方向异步采样：Hilog 在该点击窗口记录了 `hcpp_input` 的 `input` 路由
`seq=413/414` 以及随后 `overlay` 路由 `seq=415/416` 的 Down/Up 和 `napi-request`，但
没有出现与最后一次 overlay 点击对应的 Flutter `PlayerTouchTrace`、`FullscreenTrace` 或
全屏业务请求。相同时间段连续出现
`hcpp_input publish viewKey=oh_flutter_1 rects=1 displayed=0`。这说明当前长周期问题已缩小到
PlatformView/HCPP 的显示状态、attachment/ownership 与 overlay 触点交付之间的边界；不能继续
通过放宽测试等待时间或在 Flutter 全屏逻辑中增加 workaround 处理。

下一步必须做最小 A/B 证伪：保留现有 Flutter 业务代码和脚本，在 embedding 层分别记录每次
`displayed` 状态、overlay block 的命中/转发结果、attachment epoch/owner 变化，并把最后一次
`seq` 与 Flutter trace 做同一时间线关联。若 `displayed=0` 时 overlay Down/Up 始终没有 Flutter
trace，应修 HCPP attachment/层级生命周期；若已有 Flutter trace 而全屏请求缺失，才转查 Flutter
overlay hit testing 或业务状态。未完成该 A/B 前，不宣称 z-order 修复已通过长周期，也不宣称
颜色/亮度问题已关闭；颜色 verdict 仍为 `INCONCLUSIVE`。

## 2026-09-15 r26 实际编译 embedding 后的 20 周期结论

前述 A/B 诊断发现构建脚本最初修改的是 embedding 仓库的 legacy 副本
`src/main/FlutterPage.ets` / `src/main/PlatformViewsControllerHybrid.ets`，而 HAR/HAP 实际编译
的是 `src/main/ets/embedding/ohos/FlutterPage.ets` 和
`src/main/ets/plugin/platform/PlatformViewsControllerHybrid.ets`。因此旧的 r26 长跑不能证明
z-order 修复已经进入最终 ABC。构建脚本现已改为操作实际编译路径，并在 embedding HAR 构建前
清除限定的 generated `flutter/build/default`，同时在 HAP 内校验诊断字段，避免再次产生“源文件
已改、最终包未改”的假 A/B。

实际编译上述 embedding 的 r4 诊断包为
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-hcpp-state-trace-r4-20260915-signed.hap`，实体机
20 周期 artifact 为 `/tmp/piliplusx-ohos-hcpp-state-trace-r4-20260915-20cycles-reset`：

- 20/20 周期完成 portrait → landscape → portrait → landscape → portrait 全屏往返；
- 62 次 `playing + frame=changed` 语义播放采样通过，HDR decision evidence 为 `PASS`；
- 期间第 2、4、6、8、10、12、14、16、18、20 轮附近多次出现播放暂停，均由最新布局 seek/播放
  恢复分支成功恢复，未误计为全屏失败；
- HCPP 共记录 424 个 owner 事件和 424 个 NAPI 请求，无 stale attachment、不可见新 Down、
  无 geometry 或 dropped owner 记录；所有样本均为
  `sourceVisible=true inputVisible=true displayed=false hasGeometry=true attachmentEpoch=1`；
- `displayed=false` 在成功的 20 周期中持续存在，因此它不是触控交付失败的充分条件。实际结论
  应回到“错误 ETS 副本未进入最终 HAP”这一构建集成缺陷，不能把 `displayed` 标记本身当作
  HCPP 根因；
- 颜色 verdict 仍为 `INCONCLUSIVE`，本轮只关闭实际 embedding z-order/全屏输入长周期门禁，
  不关闭同源同帧亮度、灰屏恢复或 SDR/HDR 切换验收。

该结果使“实际编译包的 HCPP 全屏输入交付长周期”达到通过；后续若再出现全屏点击失效，必须
首先核对最终 HAP 的 embedding source/ABC marker 和版本，再进入 Flutter 业务或 native engine
排查，不能只检查工作树中的 legacy ETS 副本。

## 2026-09-15 r26 当前包竖屏不旋转与手势复核

使用实际编译 embedding 的 r4 HAP 运行脚本化竖屏专项时，横屏源 `BV15z4y1Z734` 的边缘手势
运行不能作为竖屏结论，脚本按 fail-closed 返回 `NOT OBSERVED`；该结果已归类为样片方向不匹配，
没有记为播放器回归。

随后使用标记为竖屏的 `BV1vY4y1N7TY` 并传入 `--vertical`。窗口基线为 portrait，但点击全屏后
稳定布局实际为 landscape，脚本按“竖屏全屏必须保持 portrait、不得旋转”的既定约束停止，artifact
为 `/tmp/piliplusx-ohos-vertical-r4-20260915-edge-vertical`。因此当前 r4 包不能关闭竖屏全屏不旋转
门禁，也不能据此判定边缘上下滑已被播放器拒绝；需要先收敛竖屏全屏方向，再重新执行边缘/中心手势
专项。现有同源的 `fullscreen-gate` 日志仍显示 HCPP owner/NAPI 输入链存在，问题不应先归因于
触控丢失。

斜向 seek 误触发问题本身仍保持已关闭结论：代码阈值、单测和 r26 三轨迹实体机专项均证明只有
明显水平滑动进入 seek；本轮的竖屏失败是方向约束失败，不推翻该结论。

补充复核：`BV1Wp4y1P7KU` 才是当前计划确认的真实竖屏样片。使用 r4 HAP 的实体机脚本复测后，
竖屏边缘上下手势得到 `reject-portrait-edge`，中心上下手势得到播放器的
`accept-single-pointer` / `gesture pan-start` / `gesture pan-update type=fullscreen`，两项均 PASS。
两次运行都保持 fullscreen portrait，并取得 `playing + frame=changed`；artifact 分别为
`/tmp/piliplusx-ohos-vertical-r4-20260915-edge-known-vertical` 和
`/tmp/piliplusx-ohos-vertical-r4-20260915-center-known-vertical`。此前使用非确认竖屏源产生的
landscape 结果不再作为方向或手势结论。

同一 r4 HAP 的三轨迹 seek 专项首次暴露脚本固定等待 10 秒的时序误报：第三条 `fullscreen`
决策在释放前尚未写入快照，但释放后的同进程日志已存在。脚本现改为轮询三条
`gesture move-filter` 决策，达到三条或超时后才释放 gate。修订后 artifact 为
`/tmp/piliplusx-ohos-seek-direction-r4-20260915-known-vertical-rerun`，决策为
`horizontal`、`reject-portrait-edge`、`fullscreen`，最终 verdict 为
`PASS (only clear horizontal swipe entered seek)`。

## 2026-09-15 r4 真 Dolby Vision 与颜色 contract 复核

使用真正的 Dolby Vision 源 `BV1uZ4y1U7h8` 在实际编译 embedding 的 r4 HAP 上完成 3 周期播放中
全屏进出，artifact 为 `/tmp/piliplusx-ohos-dv-bv1u-r4-20260915-cycles3`：

- 3/3 周期完成 landscape → portrait → landscape 往返；
- 11 次 `playing + frame=changed` 语义样本通过；第 3 周期退出阶段一次自然暂停由最新布局恢复，
  随后重新取得播放证据；
- Hilog 明确记录 `source=dolbyVision`，最终决策为
  `output=nativeHdr, surface=native-hdr, sourceProcessing=dolby-vision-converted-to-hdr`；
- 12 个 RenderService 稳定颜色样本全部为 `colorSpace=7`，没有 `COLOR_CONTRACT_MISMATCH`；
  期间出现的 consumer readback mismatch 均触发动态颜色缓存失效和下一次重写；
- 脚本颜色 verdict 仍为 `INCONCLUSIVE`，因为它不把截图或 RenderService contract 冒充为同源同帧
  的实屏视觉验收。

因此 Dolby Vision 的播放、输出决策、方向和颜色 contract 门禁已通过；尚未关闭的只是实屏视觉
亮度/颜色主观验收，以及用户指定暂缺样片的 HLG/HDR Vivid 待办。

随后按用户指定顺序执行可用格式矩阵，artifact 为
`/tmp/piliplusx-ohos-hdr-matrix-r4-20260915-available`：真彩/PQ 长源 `BV15z4y1Z734` 完成
3/3 周期，HDR decision、方向、播放帧和稳定颜色 contract 均通过；HDR Vivid
`BV121421y7PM` 与 HLG `BV1ZB4y1F7jf` 因没有可靠格式样片而按要求跳过。PQ/HLG/SDR 对照源
`BV1tM4y1L7EF` 本轮在播放前置阶段持续 paused，脚本拒绝使用该样本作为播放证据并停止，
因此该对照源仍是待重跑项，不能计为格式通过。

补充 SDR 脚本复测：源 `BV1GJ411x7h7` 在 r4 HAP 上完成了播放前置、播放帧推进和第 1 次进入全屏，
但退出全屏后的 RenderService 颜色契约采样返回不可用（`status=2`），脚本按 fail-closed 停止，
没有伪计为 3 周期通过。该 artifact 为 `/tmp/piliplusx-ohos-sdr-r4-20260915-cycles3`；因此 SDR
同源同帧对照及完整 3 周期仍待在稳定播放状态下重跑。

随后以同一源进行重跑时，脚本已越过安装超时问题并取得播放帧推进，但该次当前页面的全屏稳定
方向为 `portrait`，而未传入竖屏约束的 SDR 门禁期望 `landscape`，遂 fail-closed 停止；artifact
为 `/tmp/piliplusx-ohos-sdr-r4-20260915-cycles3-retry3`。这次不计为 SDR 通过，也不把它解释成
颜色故障；需先确认源方向/搜索结果与既有 SDR 证据一致，再重跑完整对照。

该轮后续竖屏专项因实体机 HDC 间歇性 `Connect server failed`，未生成播放进度采样的 after-layout，
脚本已补充布局/截图产物存在性检查，现会明确报告 `after-sample layout/frame unavailable` 并
fail-closed，不再由 Python 缺失文件 traceback 混淆根因。该轮仍不计播放或颜色通过。

## 当前完成审计（2026-09-15）

已关闭：斜向 seek 误触发、播放器内外竖屏触控所有权、竖屏全屏不旋转、实际编译 embedding 的
HCPP 输入层序、Dolby Vision/PQ 的短周期输出决策与稳定颜色 contract，以及 Flutter 播放器单测。
相关实体机证据和脚本路径均保留在上文，不能扩大解释为实屏亮度验收。

未关闭：Dolby Vision 更长周期、正确 SDR 源的完整 3 周期、surface 销毁/重建后的持续播放与
Cancel 生命周期、HDR/SDR 同源同帧亮度/灰屏恢复、macOS 视觉回归，以及 HLG/HDR Vivid 样片。
截至本次审计，实体机 `2PM0223A18006914` 的 HDC 状态仍为 `USB Offline`，因此这些实机项不作
通过或失败的推断。

## 2026-09-15 实体机恢复在线后的搜索前置复核

实体机随后恢复为 `Connected`。使用严格脚本分别搜索计划中的真实 Dolby Vision 源
`BV1uZ4y1U7h8`、历史可复现 DV 长源 `BV1vY4y1N7TY`，以及确认竖屏源 `BV1Wp4y1P7KU`；三次
运行均停在搜索结果阶段，未出现目标视频结果，未进入播放器、全屏或颜色门禁。artifact 分别为：

- `/tmp/piliplusx-ohos-dv-r4-20260915-20cycles-final`；
- `/tmp/piliplusx-ohos-dv-r4-20260915-bv1v-20cycles-final`；
- `/tmp/piliplusx-ohos-recommendation-scroll-r4-20260915-final`。

这些运行只能证明当前搜索/网络前置不可用，不能计为 Dolby Vision 长周期失败，也不能替代
推荐列表边界验收；待搜索结果恢复后继续执行原脚本。

随后搜索前置短暂恢复：使用确认竖屏源 `BV1Wp4y1P7KU` 的推荐列表专项在当前 r4 包上通过，
列表文本锚点从 `y=2069` 移至 `y=1891`，artifact 为
`/tmp/piliplusx-ohos-recommendation-scroll-r4-20260915-recheck`。紧接着重跑播放器内中心竖滑时，
搜索结果再次未出现，artifact 为 `/tmp/piliplusx-ohos-vertical-gesture-r4-20260915-recheck`，
该次不计手势失败；推荐列表正向证据有效，播放器内专项需在搜索稳定后重跑。

搜索恢复后再次重跑播放器内中心竖滑专项，`BV1Wp4y1P7KU` 保持 fullscreen portrait，取得
`playing + frame=changed`，并记录 `outer-scroll pointer-rejected`、`accept-single-pointer`、
`pan-start`、`pan-update type=fullscreen` 完整接管链，脚本 verdict 为 PASS。artifact 为
`/tmp/piliplusx-ohos-vertical-gesture-r4-20260915-final`。该轮颜色 verdict 仍为
`INCONCLUSIVE`；切换过渡采样不可用不影响本手势门禁结论。

surface 重建探针随后以 `BV15z4y1Z734` 重试，仍在目标视频搜索阶段停止，artifact 为
`/tmp/piliplusx-ohos-surface-recreate-r4-20260915-retry2`；未产生 continuous baseline，故不对
surface destroy/recreate 行为作成功或失败推断。

会议浮层消失后，使用横屏历史 DV 源 `BV1vY4y1N7TY` 完成一次新的 surface 重建探针。连续播放
基线、全屏往返和 HDR decision/frame progression 均通过，随后持续拖动期间执行冷重启；artifact
为 `/tmp/piliplusx-ohos-surface-recreate-r4-20260915-dv-no-overlay`。生命周期日志确认新进程
`15013` 重新执行 `OnSurfaceCreated` 与 `SetDisplayWindow`，但同时出现
`OnSurfaceChanged XComponentBase is not attached`，并伴随旧 surface `Cannot find surface`。
因此本轮关闭“冷重启后 surface 身份重建可观测”这一诊断门禁，但不关闭旧 Dart isolate Cancel、
重建后持续播放或 surface attachment 完整性验收。

对当前设备布局的复核发现播放器包虽然仍存在，但同时可见外部 Feishu “会议中”系统浮层。
这解释了部分搜索前置不稳定现象；验证脚本已增加 `foreground-system-overlay` fail-closed
诊断，后续需先清除该测试环境浮层，再重跑搜索和生命周期专项。

## 2026-09-15 上次 architect review 后变更的独立复核

本轮启动新的 architect 实例，基于当前代码、脚本、文档和已留存实机日志独立审核；结论为“不
通过，需局部返工，不需要推翻整体方案”。视频呈现与 Flutter 输入分离、推荐列表 pointer-down
准入、全屏请求串行化、HDR candidate/active proof 分离、实际 ETS 路径修复和颜色 contract 与
实屏亮度分离等方向得到认可，但以下结论不能继续扩大为已关闭：

1. **P1 手势方向锁定过早。** `PlayerScaleGestureRecognizer` 在约 2px 的早期位移上分类并抢占
   arena，后续仅按距离继续；例如先出现 `(3,0)` 再转为竖滑仍可能提交 seek，且 2--18px
   抖动会取消点击类手势。应在有效移动阈值处按累计位移确认方向，再锁定；保留 pointer-down
   外层准入，不用两个层级重复解决所有权。
2. **P1 Cancel 可能被当成正常结束。** `PointerCancelEvent`、第二指接管或 surface detach
   触发结束回调时，播放器仍可能提交 `seekToPos`。需区分正常 Up、Cancel、多指接管；Cancel
   只撤销预览并清理 seeking 状态。
3. **P1 全屏清理不应依赖当前源方向。** `_executeFullScreenRequest` 和恢复逻辑需要记录本
   owner 实际执行过的原生平台效果；OHOS 竖屏不旋转策略应限定平台，不能让换源后的
   `_isVertical` 跳过桌面原生退出或 dispose 清理。
4. **P1 输出重建需纳入 source generation。** `_rebuildVideoOutput` 当前主要检查 transaction/
   player/disposed，换源复用同一 Player 时旧源异步结果仍可能发布能力、触发 fallback 或写回
   HDR 状态。每个异步提交点都需验证 source generation，并区分“事务过期”与“真实失败”。
5. **P1 长周期门禁不能任意恢复 paused。** `verify_hdr_real_device.sh` 当前将 paused 与接近片尾
   合并处理，可能把非 EOF 的异常暂停自动恢复后继续计周期。只有有当前位置、duration 或
   completed 证据的 EOF 才能恢复；非 EOF 暂停应失败并单独报告。
6. **P2 脚本 verdict 仍需分层。** seek 脚本应将事件与注入窗口关联并验证实际 seek；HCPP
   `NOT OBSERVED`、冷重启采集失败、缺 attachment 不能只靠上层退出码继续形成综合 PASS。应
   分离 application、attachment、playback 机器可读 verdict。
7. **P2 构建输入尚未与 CI 收敛。** 有效 embedding 修复集中在本地专用 HAP 构建脚本，需把
   ETS/HAR/package 修改变成共享、版本化输入，并记录 source revision、patch hash、构建模式
   和 defines，确保 CI 候选包与实机包同源。

因此“斜向 seek 已关闭”收窄为“指定轨迹/指定包通过”，不能覆盖方向锁定和 Cancel 缺陷；
surface 冷重启中观察到新 PID 的 `OnSurfaceCreated/SetDisplayWindow`，但同时有
`OnSurfaceChanged XComponentBase is not attached` 和旧 surface `Cannot find surface`，仅证明
重建可观测，不关闭同进程 detach、旧 owner Cancel、新 surface attachment 和持续播放门禁。

## 2026-09-16 architect 复核后的首轮落实

新的独立 architect 复核确认整体分层方向正确，但仍不通过最终架构验收；本轮先落实不依赖
实体机的高价值修正：

- 验证脚本的全屏 request gate 现在记录每次点击前的 hilog 字节偏移，只接受该点击之后的
  Flutter `FullscreenTrace trigger status=true/false`；初始进入、循环切换、重试和状态归一化
  不再用整份历史 hilog 或仅 native 完成日志作为本次按钮输入证据。
- 全屏控制条重试在每次失败后重新唤醒并抓取新布局，再解析新坐标；不复用上一次解析出的
  全屏按钮坐标。surface page exit/re-entry 外层同时消费子脚本 `verdict.env`，只有
  `overall=PASS` 才能形成综合 PASS，`INCONCLUSIVE` 不再因退出码为 0 被吞掉。
- 复用同一个 Player 换源时，`open()` 完成后按当前 source generation 重绑播放器监听器；
  旧源重叠 open 不得拆除新源监听器。输出重建释放旧 `VideoController` 后，按 controller
  identity 从当前树中 detach，避免 generation 过期时仍暴露已释放 controller。
- 将 layout-only 全屏策略收窄到 OHOS 竖屏；桌面竖屏视频仍执行原生窗口全屏。手势 recognizer
  对 mouse 的固定 precise-pointer pan slop 增加内部 18px 暂挂门禁，避免鼠标 3px 移动先被
  Scale 基类接受而跳过播放器方向分类；新增相应单测。

本轮静态证据：Dart analyze、shell/Python 语法、`git diff --check` 通过；相关 Flutter 测试
20 项通过。尚未因此关闭实体机全屏请求链、播放中 PQ/DV 多轮灰屏、HDR/SDR 同源同帧颜色、
同进程 surface attachment/re-entry、真实 Cancel 交错和 macOS 回归；这些仍必须使用脚本化
实体机/平台证据验证。最新实体机运行仅到首页搜索阶段，不能替代后续门禁。

architect 给出的最小返工/验证集：累计位移方向确认、Cancel/第二指测试、换源并发与输出重建
过期测试、横源 native fullscreen→竖源→退出/销毁、同进程 detach→重入持续播放、非 EOF paused
门禁注入测试；之后再继续 DV 长周期、SDR 三周期及 HDR/SDR 同源同帧视觉对照。HLG/HDR Vivid
样片仍按用户决定暂列待办，不阻塞当前返工。

## 2026-09-15 P1 局部返工进展

根据上述独立复核，已完成第一轮代码返工（尚未进行实体机重验收）：

- `player_gesture_recognizer.dart` 将单指方向准入从 `2px` 延后到累计 `18px` 方向确认阈值；
  新增 Cancel/多指接管的粘滞终止标记，避免 Flutter 清理 tracking 后 `_onPanEnd` 把取消当成
  正常 Up。
- `view.dart` 的水平 seek 在取消或多指接管时只清理预览并恢复 native position，不提交
  `seekToPos`。
- `controller.dart` 的输出重建事务捕获 `sourceGeneration`，所有异步发布、HDR dataspace
  回写和 fallback 前均检查事务仍属于当前 source；全屏清理新增实际原生效果标记，不再由当前
  视频方向决定是否调用 native exit。
- `verify_hdr_real_device.sh` 的周期重启只接受布局中显式 `state=completed` 的 EOF 证据，
  不再把 Slider 的 `100%` 或任意 paused/unknown 当成可恢复条件。

当前自动验证：播放器相关 Flutter 测试及手势专项均通过；shell 语法和 `git diff --check`
通过。仍需补充 Cancel 实际 widget 回调、换源/输出异步并发、横源切竖源全屏清理、同进程
surface detach/重入，以及实体机和 macOS 验收。

## 2026-09-15 实现后最终 architect 复核与第二轮修正

最终独立复核发现第一轮返工仍有四项 P1，已继续修正：

- `MouseInteractiveViewer` 原先把非 iOS `touchSlop` 设为 `4px`，会让 Scale 基类在自定义
  `18px` 方向准入前接受 arena；现统一使用 `kPlayerDirectionQualificationSlop=18px`，触屏、
  mouse 和 trackpad 不再出现“已接受但尚未分类”的路径。
- `_rebuildVideoOutput` 的 `isCurrent()` 现同时比较 source、transaction、player 和 dispose
  状态；正常发布、HDR dataspace、两级 fallback 的异常/完成路径均在异步边界重新检查，过期
  source 不得降级当前能力或写回错误。
- 全屏 native enter 在发起平台调用前登记可能的清理责任，dispose 清理在队列稳定后再决定；
  新 owner 对 desktop/OHOS 也执行初始 native reconciliation，退出不再依据当前视频方向猜测。
- 长周期脚本的 `read_playback_state` 增加显式 completed/replay 识别，周期恢复只接受
  `state=completed`；Slider 的四舍五入百分比和任意 paused/unknown 均不能授权重启。

本轮最终审查确认 Cancel/multi-pointer sticky 顺序本身正确，但真实 widget 的慢速分段手势、
控制器异步交错、原生 enter 部分失败、dispose 期间 enter、新 owner 接管仍需定向测试；实体机
当前因系统锁屏尚未完成本轮候选包验收，不能把构建或 Flutter 测试结果扩大为实机通过。

## 2026-09-15 r2 候选包实体机复核

使用 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-p1gesture-r2-20260915-signed.hap`（已通过
签名、HCPP marker 和 manifest SHA 校验）运行脚本化实体机验证。斜向 seek 专项通过：
`direction decisions: horizontal reject-portrait-edge fullscreen`，且 gate 记录
`playing + frame=changed`；artifact 为
`/tmp/piliplusx-ohos-seek-direction-p1-r2-20260915`。这只关闭“明显水平/斜向/竖向三轨迹”
的候选包验收，不替代 Cancel、慢速分段轨迹和播放中全屏长周期。

竖屏专项在两种唤醒方式下均未进入手势门禁：底部 `video-wake` 位于控制条/进度条附近，未能
恢复 seek 后播放；改用 `VERIFY_WAKE_MODE=video-center` 后，目标搜索在 8 次重试内未产生
`02-filled.json`。两轮均由脚本 fail-closed 停止，不能计为播放器手势失败。期间日志观察到
`OH_NativeImage_AcquireNativeWindowBuffer` 和 EGL surface 警告，需在搜索稳定且取得播放器
前置证据后单独关联，不能仅凭本轮前置失败定位为手势根因。

同时修正 `verify_hdr_real_device.sh` 的 completed 识别：页面常驻的“再看”不再被视为 EOF，
只有 `重播/已结束/播放完毕/播放完成` 等明确完成文案才允许周期恢复；Slider 显示的 `100%`
仍不能单独授权重启。

## 2026-09-15 当前执行检查点

最新候选包仍为 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-p1gesture-r2-20260915-signed.hap`，SHA-256
为 `586aeb8ce21f7783135588eaad88c945789b414cb0d16909c8f6adb37ec341f6`。本轮静态检查、全量
Flutter 测试和核心分析均通过；实体机 `2PM0223A18006914` 连续权威探测为 `USB Offline`，因此
本轮没有新增实机通过证据。设备恢复 `Online/Connected` 后，必须从该候选包重新执行竖屏手势、
推荐列表边界、播放中全屏循环、surface 重入和颜色对照；旧 artifact 不得替代这些门禁。

## 2026-09-15 r2 实体机恢复后的复核

设备恢复 `Connected` 后使用同一 r2 HAP 执行了脚本化复核：

- seek 方向 artifact `/tmp/piliplusx-ohos-seek-direction-p1-r2-retry-20260915`：
  `horizontal / reject-portrait-edge / fullscreen`，斜向和竖向均未进入 seek，方向 verdict
  为 `PASS`；但该轮播放进展为 paused/frame unchanged，只计方向门禁，不计播放门禁。
- 确认竖屏源 `BV1Wp4y1P7KU` 显式传入 `--vertical` 后，artifact
  `/tmp/piliplusx-ohos-vertical-gesture-p1-r2-online-vertical-20260915`：fullscreen 保持
  portrait，播放前后帧变化，中心竖滑记录 `gesture verdict: PASS`。同源播放器外推荐列表
  artifact `/tmp/piliplusx-ohos-recommendation-scroll-p1-r2-online-20260915` 的文本锚点
  `2069 -> 1891`，推荐列表滚动 verdict 为 `PASS`。
- 首次使用该竖屏源但未传 `--vertical` 的运行按方向不匹配 fail-closed；使用 `BV15z4y1Z734`
  或历史 DV 源时，r2 在不同运行中出现 portrait/landscape 不一致，不能把这些运行当作稳定
  的方向或颜色通过证据。需继续区分源方向识别、全屏状态和播放前置。
- 播放中全屏诊断 artifact `/tmp/piliplusx-ohos-hdr-toggle-p1-r2-online-20260915` 在首次
  进入横屏、退出后取得帧变化，但语义播放状态出现 `unknown`，严格门禁按设计停止；弱证据
  运行未形成完整三轮，不能宣称灰屏已解决或三轮通过。
- surface/page 重入脚本在 fullscreen stable 前置未生成，当前候选包未取得同进程重入证据。

architect 随后复核认为，本轮 portrait/landscape 差异首先应排查全屏按钮请求是否真正进入
Dart/native 链路，不能直接修改方向状态机；`--vertical` 只是验证器预期，不改变应用方向。
据此补强验证器：`verify_surface_page_exit_reentry_real_device.sh` 现在等待 fullscreen direction、
controls 和 playback 全部完成后的 `VERIFY_PAUSE_AFTER_READY_FILE` barrier，不再仅凭
`08-fullscreen-stable.json` 提前触发 page-exit；`verify_hdr_real_device.sh` 对 buffering 未稳定
和 semantic unknown 分开记录。前置未通过仍保持 fail-closed，弱证据模式仍只能作诊断。

随后用 r2 HAP 和 `BV1Wp4y1P7KU` 运行 surface recreate 探针，artifact 为
`/tmp/piliplusx-ohos-surface-recreate-p1-r2-online-20260915`；因当前播放未进入 `nativeHdr`
而在全屏前置停止。该结果只说明本轮生命周期实验未执行，不对 surface destroy/recreate 成功
或失败作判断。

进一步对齐 Hilog 后确认：某些 portrait 运行中，脚本点击语义上的 fullscreen 节点虽然返回
`No Error`，但没有产生 `FullscreenTrace trigger status=true`；事件只落到视频区 tap。此前的
竖屏 gesture PASS 不能反推 fullscreen 按钮点击可靠，因为后续 video-center 唤醒可能触发了
逻辑全屏。验证脚本现加入“点击后必须观察 Flutter fullscreen request trace”的硬门禁；若控制条
已过期，则重新唤醒、重新抓布局并重试新坐标，禁止复用旧坐标。最新重试运行在播放器启动前
`01-home.json` 采集失败，未形成新的播放器结论。

## 2026-09-16 architect 复核后的按钮命中证据

独立 architect 复核后继续收紧了验证边界：`ComBtn` 的全屏入口现在统一经过
`_onFullscreenButtonTap`/`_onFullscreenButtonSecondaryTap`，并记录
`fullscreen-button callback`；实体机脚本的全屏门禁必须同时看到该回调和同方向的
`FullscreenTrace`，不再接受视频区手势产生的全局请求。

使用新构建 `/Users/wuweiwei1/Downloads/PiliPlusX-ohos-architecture-callback-trace-20260916-signed.hap`
在 `2PM0223A18006914` 上验证 `BV1Wp4y1P7KU`：搜索、播放和帧变化均通过；截图中控制条和
全屏图标可见，语义树报告全屏按钮 bounds `[1113,1751][1227,1848]`。但对该坐标连续执行
HDC `uiInput click` 没有产生任何 Flutter pointer 或 `fullscreen-button callback`，脚本因此
按 fail-closed 停止。同期视频中心点击能产生 `_onTapUp`，证明设备输入链路并非整体失效；此前
仅按 `FullscreenTrace` 的通过结论不再有效。

当前最重要的未决问题已收敛为“底部控件的实际命中区域/坐标映射与语义树不一致”，候选层级是
播放器 Stack/动画后的 hit-test、OHOS Flutter 输入映射或 accessibility bounds，而不是继续
增加等待时间。下一步应先对同一时刻采集控件 RenderBox bounds、pointer 坐标和按钮 callback，
再决定修复 Flutter 控件布局还是 OHOS 输入层；在此之前不宣称播放中全屏或灰屏问题已修复。

随后在 settled-render 候选包上补充了同帧 RenderBox 证据：设备 viewport 为
`1260x2720,dpr=3.25`，控制条显示完成后 Flutter RenderBox 为
`(342.7,538.8)-(377.7,568.8)`，换算为物理屏幕坐标正好是
`[1113,1751][1227,1848]`。这排除了“语义 bounds 与 Flutter 动画终点坐标不一致”，但仍未
解释该区域为何没有产生 pointer；故问题继续保留在 FlutterSurface 的区域输入分发或 OHOS
XComponent 命中边界，不能用代理按钮或猜测坐标掩盖。

本轮通过实际编译包的 ArkUI 诊断确认：`FlutterSurface area viewId=oh_flutter_1` 为
`(0,0) size=(387.6923,836.9231)`，配合 `dpr=3.25` 正好覆盖 `1260x2720` 全窗口，
排除了主 XComponent 下部尺寸不足。最新对照中按钮区的 HDC `click` 无事件、短 `swipe`
只有 down，且未结束的 pointer 可影响后续输入；后续应优先验证 OHOS 事件序列的
owner/capture 和过滤状态，不能继续修改 Flutter 控件布局。

## 2026-09-16 上次 review 后重点变更的独立复核

针对上一轮 review 后的重点修改，新的 architect 基于当前代码、构建脚本和实体机事实重新
判断，结论是 Flutter 层的方向收敛基本正确，但不能把它当作底部控件问题已经解决：

- 不建议继续增大 Flutter `touchSlop`、增加透明代理按钮、合成 `PointerUp`，或在 down 时
  直接触发全屏。这些做法会掩盖事件所有权/捕获问题，并可能破坏推荐列表滚动和取消语义。
- 下一步最高价值的证据是同一干净进程、同一坐标矩阵下的 `FlutterSurface` 原始
  `down/move/up/cancel`、Flutter global route、全屏按钮 callback 三组日志；必须分别比较
  视频中心和底部全屏按钮，且每次实验确认没有遗留 active pointer。
- 需重点复核 OHOS `FlutterSurface` 的实际命中/捕获链和
  `ohos_touch_processor.cpp` 的 `activeFingerIds_`：缺失 up/cancel 会使后续按钮 down 被
  过滤；按钮区 swipe 只有 down 的现象与此假设一致，但当前仍是待证据的根因假设。
- `FlutterSurface` 已确认覆盖全窗口，因此不能再以“XComponent 高度不足”作为解释。当前
  诊断构建在源码中加入了原始 touch 日志，但实体机此刻为 `[Empty]`，尚未完成运行时读取。

本轮可复核证据：诊断 HAP
`/Users/wuweiwei1/Downloads/PiliPlusX-ohos-input-surface-trace-20260916-signed.hap`
已构建、签名和 `unzip -tq` 校验通过，SHA-256 为
`6ed765cac38919b8cb62c167eb85d79bddd68fbcebd984cab6894a1d23db4367`；自动安装因目标
`2PM0223A18006914` 当前未连接而失败。Dart analyze 无问题，播放器/手势专项 Flutter 测试
`29` 项全部通过。以上只证明静态和模拟器层检查，不能替代实体机触摸、播放中全屏及 HDR/灰屏
验收。

下一步保持 fail-closed：设备恢复 Connected 后安装该诊断包，执行按钮区/视频区的干净进程
对照并记录原始事件序列；只有据此确认事件 owner/capture/filter 层级后，才决定是否修改
OHOS embedding。HLG/HDR Vivid 样片仍按既定待办，不阻塞这项触摸根因定位。

验证脚本的 gesture 摘要现同时输出 `FlutterSurface area/touch`、Flutter
`PlayerTouchTrace` 和 HCPP `Down/Move/Up/Cancel` 记录，便于在控制条短时可见的窗口内完成
同一次运行的证据归因；该改动仅影响诊断输出。

## 2026-09-16 实体机原始事件复核结果

设备恢复后，使用上述诊断 HAP 执行了
`/tmp/piliplusx-ohos-input-surface-trace-20260916-run1`。`BV1Wp4y1P7KU` 的搜索、播放状态
和帧变化均通过；但首次及两次 fresh-layout 重试点击全屏按钮均未观察到按钮 callback、
Flutter global route 或 `FullscreenTrace`，脚本按设计 fail-closed。同期中心点击产生完整的
global route down/up（例如 pointer 10，逻辑坐标约 `(193.8,308.3)`），并触发 `_onTapUp`
及控制条显示，说明 Flutter 业务链路和设备输入链路不是整体失效。

本次 HAP 的 `FlutterSurface area` 记录为 `(0,0)`、`387.6923×836.9231`，但
`FlutterSurface touch` 计数为 0；中心点击仍有 native XComponent 到 Flutter 的 global route，
因此该 ArkUI `.onTouch` 诊断钩子不是主 XComponent 的实际事件入口。HCPP 记录持续为
`rects=0`，当前运行是 texture 路径。该结果把下一步从“修正 Flutter 控件 bounds”进一步收敛
到 native XComponent touch callback 的命中/捕获边界；不能据此直接修改按钮或把
`activeFingerIds_` 清空策略当作已验证根因。

随后在同一进程、同一按钮 bounds 上追加了脚本化 swipe 对照：
`1170,1799 -> 1170,1679 velocity=800` 产生 Flutter global route 的完整
`down/move/up`；`1px` swipe 和 `uiInput click` 则只产生 down 或无事件，均未产生按钮
callback。该结果证明 HDC `uiInput click` 与真实触摸序列并不等价，不能单凭 click 失败断言
真实手指命中失败；同时也暴露了短 swipe 留下未完成 pointer 的测试污染风险。下一步应使用
合法的物理点击/录制回放或 native NDK 事件日志建立等价 tap，再判断语义透明节点是否真的
改变命中目标。

补充源码事实：`OhosTouchProcessor::shouldDropTouchEvent` 在 `CANCEL` 时只删除当前
`id`，而 `OhosTouchProcessor` 的析构函数没有额外清空 `activeFingerIds_`。这使“多指/异常
捕获只收到部分终止事件后，后续同 ID down 被当作 duplicate”成为可验证的候选根因；在没有
实体机原始序列前暂不改动该共享过滤器，避免把正常跨组件 pointer 生命周期误判为异常。

## 2026-09-16 上次 review 后重点变更的再次独立架构审核

本次让新的 architect 基于当前代码、测试、诊断 HAP 和实体机原始日志重新审核，未要求其
为现有假设背书，也未修改代码。结论如下：

1. 视频输出、交互层、控制条分离，以及由控制器持有逻辑全屏状态、由平台辅助层串行化
   窗口副作用的总体方向合理；全屏状态机不是当前按钮入口丢失的首要修复层级。
2. 不能再把 `FlutterSurface.onTouch=0` 解读为主 surface 没收到触摸。OHOS 原生
   `XComponent` 存在 NDK `DispatchTouchEventCB -> OnDispatchTouchEvent ->
   OhosTouchProcessor` 路径，可能绕过 ArkUI ETS `.onTouch`。同理，`activeFingerIds_`
   残留、HDC click 被归类为 mouse、以及 embedding 过滤，当前都只是候选假设。
3. “控制条可见、语义 bounds 正确、截图可见”仍不能证明实际 hit-test 穿过真实的
   `ComBtn -> _controlLayer -> AppBarAni -> Column/ClipRect -> Stack`。现有 hit-test
   单测使用简化 harness，未覆盖这棵真实树。`MouseInteractiveViewer` 是视频区域的
   sibling，不是全屏按钮的祖先；按钮未出现其 Listener 日志本身不构成异常证据。
4. 同坐标 `10px/120px` swipe 已出现 Flutter global `down/move/up`，但没有 tap callback，
   只能说明事件进入 Flutter 并参与了命中/手势竞争；120px 本来就不应期待 tap，10px
   仍缺少按钮级原始事件、控制条状态和 gesture arena 结果。HDC `click` 与真实物理 tap
   也不能默认等价。

因此下一步严格按以下顺序执行：

1. 在不改变命中行为的前提下补充观察点：按钮 subtree 的原始 down/up/cancel、tap-down/
   cancel、当时 `showControls`/`controlsLock`/动画值、祖先尺寸及实际 hit-test path。
2. 在同一干净进程、同一坐标矩阵中对比真实短 tap、HDC click、短/长 swipe；每个样本先
   确认 pointer 已终止，出现 down-only 就隔离该样本，避免污染后续实验。
3. 只有证据确认事件在 OHOS NDK 入口、过滤器或 embedding 分发层丢失，才修改对应原生
   层；若已命中按钮但 tap 被取消，则修复 Flutter recognizer/arena；若未命中，才检查
   控制层祖先边界、动画和遮挡。禁止先加透明代理按钮、合成 `PointerUp`、down 时触发
   全屏或继续调大 slop。
4. 按钮 callback 稳定后，再恢复全屏事务、方向、帧进展和 HDR/灰屏生命周期门禁；HLG/
   HDR Vivid 样片继续保留在待办，不作为本轮触控根因的替代验证。

本次审核结论：当前修改方向“基本正确但未通过最终验收”；下一项工作是证据型 hit-test
和原生入口对照，不是继续堆叠全屏或手势 workaround。

## 2026-09-16 按钮级诊断与脚本时序复核补记

在诊断 HAP 中为真实 `ComBtn` 增加了 observation-only 的 pointer-down/up/cancel 记录，
使用 `Listener.deferToChild`，未改变其 GestureDetector、命中区域或手势竞争。Dart analyze、
播放器 hit-test/touch-trace 专项测试通过；诊断 HAP 重新构建、签名并安装成功。

实体机上的最小脚本 A/B 已成功：中心唤醒后约 `0.25s` 点击已确认的按钮坐标，日志完整出现
`fullscreen-button pointer-down`、`fullscreen-button pointer-up`、`fullscreen-button callback`
及 `FullscreenTrace trigger status=true`。因此当前 `ComBtn`、Flutter callback、全屏请求入口和
设备输入链路可以在干净短序列中正常工作。

随后完整 `verify_player_vertical_gesture_real_device.sh` 仍未通过。其失败路径的关键事实是：

- 前置搜索、播放、seek 和播放中帧进展门禁通过；
- 语义节点只能以 fresh/opacity-fallback 方式定位时，后续完整流程仍可能先对已隐藏的按钮
  坐标发送一次无效 click；
- 该输入可能产生未完成或未到达 Flutter 的 pointer 状态，之后的唤醒/按钮重试没有 callback；
- 直接读取 hilog 判断当前控制条可见性不可靠，实体机采集文件存在数秒发布延迟；
- `hdc shell sh -c` 在本机设备组合调用返回 `No Error`，但没有可归因的 Flutter pointer，
  已排除为可靠的原子输入方案。

本轮因此只保留了两项脚本改进：普通 painted target 直接点击；fresh target 的失败重试使用
同一坐标的相邻 wake/click，并明确记录每次尝试。完整门禁仍按 fail-closed 处理，不能以最小
A/B 代替完整播放中全屏验收。下一步应在测试流程层解决“首次无效 click/前置点击序列”与
pointer 清理的可观测性，优先使用干净进程、单一准备动作和合法的真实短 tap；在此之前不修改
`activeFingerIds_`、Stack 顺序或全屏状态机。

## 2026-09-16 日志观测污染复核与单试次门禁

针对 run12/run13 的实体机产物再次让新的 architect 独立审核。结论是：优先级应放在
verifier 的输入编排和日志观测污染，当前证据不足以把问题归因于 Flutter/embedding 边界、
控制条实现错误或 `activeFingerIds_` 残留。

确认的事实：

- Flutter 日志正文与 hilog 外层时间出现约 1–16 秒延迟；因此持续 hilog 文件中的“最新
  控制条状态”不能作为点击瞬间的实时状态，也不能用文件字节 offset 严格划分一次输入。
- 中心点击是 toggle，不是保证显示；在某些前缀中所谓 wake 实际把 `showControls` 从 true
  切为 false。
- `fullscreen-button-fresh` 只是放宽 opacity 的解析模式，不代表时间新鲜、按钮已绘制或
  坐标一定可命中。
- 最小干净进程 A/B 已得到完整按钮 down/up、callback 和全屏 request；完整 verifier 的
  失败重试则混入了多次输入，不能作为同一试次的根因证据。

已落实的测试边界调整：全屏关键输入现在停止持续 hilog，清空设备日志，只执行一个输入
试次，等待 Dart/engine 日志排空后再离线判定；成功后才恢复持续采集。失败不在同一进程
继续重试，而记录 `inconclusive` 并停止，避免 pointer、控制条状态和迟到日志互相污染。
`events.tsv` 现在同时记录可靠的 UTC 秒时间和 Python monotonic 时间，修复原先在 macOS
上显示为 `.3NZ` 的伪毫秒时间。

run13 的搜索、播放和非冻结播放进度证据通过，但单次全屏输入在完整排空窗口内没有形成
可关联的按钮 callback/request，脚本按新的单试次规则停止；这不是全屏功能通过，也不是
原生事件丢失的定论。后续应按 architect 建议做 A/B/C/D 四组独立新进程实验：短前缀与
完整前缀、持续 hilog 与动作后取日志分别交叉对照；每组只执行一次 wake/button，先定位
“长前缀”和“持续采集”哪个变量改变结果，再决定是否需要产品层修复。

## 2026-09-16 连接与模拟器复核补记

本轮再次执行 `hdc kill -r` 后，实体机仍无 USB 枚举，`hdc list targets -v` 为 `[Empty]`；
`ssh dev` 可用，但这只代表构建主机在线，不代表实体机在线。尝试启动本机 ARM64
HarmonyOS `Mate 60 Pro+` 模拟器后，实例进程退出，HDC 曾短暂显示
`127.0.0.1:5555 TCP Offline`，`hdc tconn` 失败，未形成可用模拟器运行证据。因此本轮没有
安装或运行诊断 HAP，也没有扩大模拟器/构建证据的解释范围。

## 2026-09-16 单试次按钮脚本与布局复用复核

已新增 `tool/ohos/verify_player_button_input_trial_real_device.sh`。在播放页已有同方向
布局时，使用 `--button-layout <layout> [--wake-layout <layout>]`；`--mode post` 表示动作
后取 hilog，`--mode continuous` 表示动作期间持续采集。脚本只执行一次，不截图、不导航、
不重试；前提、布局来源、输入和 verdict 写入 evidence 目录的 `events.tsv` 与 `hilog.txt`。

独立 A 组（post）使用 run13 的窗口化布局成功观察到完整按钮 down/up、callback 和 request。
A 进入 layout-only 全屏后，直接复用窗口化按钮布局执行 B 失败；日志显示按钮实际从物理
`[1113,1751][1227,1848]` 移到约 `[1129,2587][1227,2671]`，证明跨全屏状态复用布局是
无效实验。该事实解释了此前完整 verifier 的部分失败，不能归因于持续 hilog 或原生过滤器。
重新取得目标方向布局并等待动画 settled 后，才能进行有效的持续采集对照。

随后补齐了方向与观测模式：A（post、窗口化布局、enter）成功；C（continuous、窗口化
布局、enter）成功；全屏后使用重新采集的 settled 布局执行 B（continuous、exit）也成功。
B 的首次误报已修正为脚本缺少 `--expected enter|exit`，并非输入链路失败。三次有效单试次
均观察到按钮 down/up、对应 callback 和同方向 `FullscreenTrace`，说明持续 hilog 本身和
按钮命中边界目前没有足够证据构成根因；跨状态复用布局则已被实证排除。

脚本示例：

`tool/ohos/verify_player_button_input_trial_real_device.sh --button-layout <layout> --wake-layout <layout> --mode post --expected enter`

进入全屏后必须重新 dump 并等待 settled，再将 `--expected` 改为 `exit`；不得复用进入前
的按钮 bounds。完整播放/多次切换/HDR 生命周期门禁仍需在此单试次证据基础上继续执行。

补充实测：使用全屏后的 settled 布局、`--expected exit --mode continuous`，单试次脚本成功
观察到 pointer down/up、按钮 callback 和退出 request；随后使用窗口化布局、`--expected
enter --mode continuous` 也成功。完整 verifier run14 仍未形成动作日志，而 run14 结束后
立即复用其窗口化布局的单试次也未形成 callback，说明 full verifier 的前置输入序列仍会
改变后续进程/设备状态。该现象尚不能归因于某个 Flutter 控件或 OHOS 原生过滤器；后续
必须增加“每组独立 force-stop/start + 页面准备完成”边界，并把首次全屏输入作为唯一待测
动作，避免在同一进程连续重试。

最短前缀补测 run15（`VERIFY_RESET_PLAYBACK_START=0`）仍未通过：搜索与窗口化方向识别通过，
但全屏单试次清空日志并排空后没有产生任何该试次的 Flutter pointer 记录。该结果只能说明
full verifier 的页面准备/控制条 settled 前置条件仍未被证明，不能说明设备或播放器按钮链路
失效；独立单试次 A/C/B 在同一诊断 HAP 上已经可以成功。下一步应把“页面准备完成”的证据
单独做成门禁（目标视频、播放状态、帧变化、控制条 settled），再注入唯一按钮动作，不应
继续在同一 full verifier 进程中增加重试。

已将准备阶段实现为 `VERIFY_PREPARE_ONLY=1`：P3 成功完成目标视频搜索、portrait 方向、
播放状态与非冻结帧变化检查，并生成 `prepared-player.txt`（包含 PID、方向、布局路径及
布局来源）。随后使用该布局调用单试次按钮脚本，动作后排空仍未出现按钮 pointer。这个结果
表明“准备成功”还不能推导“退出准备脚本后输入 attachment 仍然有效”；下一步要把前台
应用/Flutter view attachment 的存活状态作为独立门禁，记录准备结束、单试次开始和 pointer
事件的进程与时间关联，再决定是否需要调整 embedding 生命周期。
补充 run16：将 full verifier 的 `HDC_TIMEOUT_BIN` 置空后，最短前缀仍未在单试次排空窗口内
产生按钮 pointer 记录；因此 HDC timeout 包装不是主要变量。对照脚本在同一设备上仍可完成
单次 enter/exit。full verifier 下一步必须把“页面准备完成”和“唯一按钮动作”拆为两个
独立脚本阶段，不能继续在现有长流程中叠加等待或重试。

P3 后续稳定性补测：准备阶段记录 PID `48203`，结束脚本后设备曾出现空布局；等待约 12 秒
后目标视频与“暂停”状态恢复，但前台应用 PID 已变为 `48311`。使用准备阶段布局执行单试次
仍无任何 pointer。由此确认“目标页面可识别”不等于“同一 FlutterSurface/input attachment
已稳定”；准备 artifact 必须增加结束后 PID、FlutterSurface area/viewId 和一次安全的
中心 tap 验证，未满足时不得进入按钮坐标试验。当前不应继续修改播放器按钮或原生活动指针
过滤器。

## 2026-09-16 上次 review 后重点变更的实现后独立复核

针对本轮 source generation、播放器输出重建、手势方向容错、按钮触控诊断以及单试次实机
脚本的重点变更，另起 architect 实例进行实现后复核。结论是总体架构方向正确，但当前不能
宣布触控、全屏或 HDR 已收敛。

### P0：先闭合验证证据链

- P3-post-stable 在 16:38 使用旧坐标 `(1170,1799)`；attachment gate 在 16:39 才取得
  中心 global down/up 和新的 settled bounds。两批证据不能拼接为“稳定 attachment 下按钮
  仍失效”。最新 settled bounds 换算到物理坐标约为 `[1129,2588]-[1228,2672]`。
- 当前 verifier 仍需拒绝过期或跨场景布局，明确区分逻辑全屏状态，并关联准备结束与动作
  时的 PID、FlutterSurface/viewId、事件时间、pointer、callback 和 request。默认 wake
  可能把已显示的控制条切换为隐藏，固定等待也会与控制条超时竞争；callback/request 的
  两个独立 grep 不能证明属于同一输入试次，更不能证明全屏事务已完成。
- 因此下一步优先修改 `verify_hdr_real_device.sh` 与
  `verify_player_button_input_trial_real_device.sh`：前置布局、attachment、状态和时间关联
  不成立时立即停止，不追加点击碰运气。保留分阶段日志，失败按 inconclusive 记录。

已先落实单试次脚本的第一步门禁：`--button-layout` 现在只作为准备阶段参考；脚本在动作前
重新抓取当前布局，若控制条不可见则只执行一次当前布局解析出的 video-center wake，随后再次
抓取布局，再解析并点击当前 fullscreen button。`--no-wake` 在当前布局没有按钮时直接失败。
最终 PASS 还必须在同一排空日志中按顺序观察到 fullscreen-button pointer down/up、对应
callback 和同方向 `FullscreenTrace` request。这样旧坐标、跨全屏布局复用和独立 grep 误报
都会变成明确失败或 inconclusive，而不是继续点击。

### P1：独立整改 controller 生命周期竞态

architect 从代码推导出以下三个应补定向测试并单独修复的问题；这些问题尚不能直接归因于
P3 按钮失败：

1. 旧 source 的 native attempt 完成时，generation 不符可能导致 in-flight 标记不清除，
   新 source 也未重置，后续 native HDR 尝试可能永久被阻挡。
2. 非最后一个引用释放时可能失效 rebuild 并取消 display listener，存活 controller 由此失去
   输出或显示变化监听。
3. source generation 尚未覆盖完整异步事务；listener 在 open 后才重绑，存在旧 source
   回写、codec probe 污染新 source 以及 metadata 窗口丢失风险。

### 暂停扩大的方向

当前 `CommonBtn` 的 `Listener` 仅作观察，gesture recognizer 的方向判定边界基本正确，暂不
继续修改其行为。没有直接证据前，不修改 slop、Stack 顺序、代理按钮、合成 PointerUp、
down 直接全屏、`activeFingerIds_` 或原生全屏状态机。

### 最小复核矩阵

1. 验证编排自检：旧布局、错误全屏状态、过期可见窗口和迟到日志均不得误报 PASS，也不得
   继续注入动作。
2. 单次 enter：短前缀/完整前缀分别配合 post/continuous，四组独立新进程；要求当前布局
   有效，并关联 `pointer down/up -> callback -> 同方向 request`。
3. 单次 exit：竖屏、横屏各一次；进入后重新采集 settled 布局，验证 exit commit、方向和
   播放继续。
4. controller 竞态：切源时 configure/rebuild、非末引用释放、最终 dispose/新 owner；要求
   无旧源回写、永久 in-flight、失效输出发布或监听丢失。
5. 产品回归：竖/横屏播放中各 3 个完整周期，再恢复既定长周期与重入测试；持续出帧，
   native HDR 和颜色亮度分别验收。

本轮定向测试实际通过 63 项，`dart analyze`、脚本语法检查和 `git diff --check` 通过；
这些结果不覆盖上述 controller 竞态，也不替代实体机验收。当前执行顺序固定为：先修验证
编排并保留诊断包，再补 controller 竞态测试和修复，最后重新构建并恢复完整全屏/HDR 门禁。

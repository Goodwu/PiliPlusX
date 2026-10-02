# 跨平台播放器测试方案（Android 首验）

## 目标

建立统一命令、场景、证据目录与结论模型的播放器自动化测试框架。首版实现 Android、OHOS、iOS 三端的适配接口和场景；Android 为首个实际运行验收平台。macOS 复用框架和场景定义，后续再接入桌面输入与窗口适配。

首轮覆盖播放核心回归和 HDR 自动链路验证，使用固定 BV。允许默认关闭的诊断观测；实际屏幕色彩和亮度观感不属于自动化通过条件，必须报告为未验收。

## 架构与接口

代码目录为 `tool/player_test/`，使用 Python 3.11+ 实现编排与判定器；现有 Bash 脚本在迁移期保留为兼容入口。

```text
CLI / 配置 / 设备锁
        |
场景编排器 ---- 证据判定器 ---- 报告生成器
        |
平台驱动（Android / OHOS / iOS / macOS）
        |
系统输入、布局、截图、日志、应用观测
```

统一入口：

```bash
python3 -m tool.player_test doctor --platform android --device SERIAL
python3 -m tool.player_test run --platform android --device SERIAL \
  --suite core --profile diagnostic --artifact /abs/app.apk --out /abs/results
python3 -m tool.player_test run --platform android --device SERIAL \
  --suite hdr --profile diagnostic --out /abs/results-hdr
python3 -m tool.player_test report /abs/results
```

`--device` 必填；`--artifact` 存在时才安装，省略时必须核验已安装候选身份。`--suite` 支持 `smoke`、`core`、`hdr`、`stress`，并可用 `--case` 限定单一场景。`--profile` 为 `release` 或 `diagnostic`；诊断观测不可用时，严格依赖观测的用例应给出 `INCONCLUSIVE`，不能降级为通过。

平台驱动提供以下接口：

```text
preflight, capabilities, app_identity
install, launch, terminate, foreground_identity
open_source, back, home, activate
snapshot_ui, screenshot, tap, swipe
start_logs, log_cursor, read_events, collect_crashes
output_evidence, restore, close
```

驱动将原生布局转为统一节点：语义标识、可见性、可操作性、边界、坐标空间、窗口身份、采样时间与布局版本。场景代码不得持有设备绝对坐标。

| 平台 | UI 与系统适配 | 首版状态 |
| --- | --- | --- |
| Android | Appium UiAutomator2；ADB、logcat、dumpsys、截图 | 首个实测平台 |
| OHOS | HDC uitest；hilog、RenderService、HCPP/Surface | 复用既有严格验证器并逐场景迁移 |
| iOS | Appium XCUITest/WebDriverAgent；设备日志和截图 | 实现驱动；签名与 WDA 就绪后实测 |
| macOS | 后续 Appium Mac2；应用绝对路径、窗口、unified log | 只定义能力与接口 |

OHOS 保留 HCPP、NativeWindow、RenderService 等专项断言；不得将 HDC 机械替换为 ADB。iOS 运行前必须检查应用签名、WDA 签名与设备信任。

## 场景、定位与观测

固定片源以版本化 JSON 清单维护 BVID、分P、方向、测试区间、预期格式、画质和权限条件。初始候选为：重入 `BV1T7t96BECu`、竖屏 SDR `BV1sA4y1D7ZA`、Dolby Vision `BV1vY4y1N7TY`、HDR `BV15z4y1Z734`、HDR Vivid `BV121421y7PM`、HLG `BV1ZB4y1F7jf`。运行前必须复核片源可访问性与实际格式；不得随机替换片源。

| 场景 | 默认次数 | 必需结论 |
| --- | ---: | --- |
| 起播 | 1 | BVID/分P 身份、播放位置、可见视频区域推进 |
| 暂停恢复、Seek | 各 1 | 状态或位置正确，恢复后持续出帧 |
| 全屏、竖屏视频 | 各 3 | 输入、状态、布局或方向、持续播放 |
| 页面重入 | 5 | 同进程身份、恢复出图、无本轮新增 ANR/崩溃 |
| 前后台、手势、推荐列表 | 各 3 | 对应状态变化且没有错误手势接管 |
| HDR 矩阵 | 每源 1；stress 30 | 输入、解码、输出和切换恢复分别判定 |

控制条操作按连续批次执行：确认当前应用与页面 → 必要时唤醒 → 获取当前可见目标 → 校验仍有效 → 注入一次系统输入 → 验证状态。批次外的旧布局和旧坐标不可复用；目标过期可重新准备一次，已发出输入后不得自动补点。

在现有 `pl-player-fullscreen-toggle` 基础上，为播放/暂停、进度条、播放器区域、返回、画质菜单、分P和推荐列表补充稳定语义标识。新增默认关闭的 `PILIPLUS_TEST_OBSERVABILITY`，兼容已有 `PlayerTouchTrace`。它输出带会话 ID、递增序号和单调时钟的 JSON 事件，覆盖：候选身份、source、播放器和 source/output generation、播放状态、输入、全屏、输出建立/释放、HDR 探测/选择/配置/回读。观测只记录事实，不能驱动业务行为。

## 证据、HDR 与结论

每次运行创建独立目录：

```text
manifest.json    候选、设备、依赖、配置和诊断开关
events.jsonl     归一化事件及原始日志引用
actions.jsonl    每次动作的前置、输入与后置证据
cases/           布局、截图、原始日志和崩溃材料
summary.json     权威机器可读结论
junit.xml        CI 结果
report.html      人工审阅报告
```

截图只分析当前视频区域，并与播放位置推进共同构成帧推进证据；单次非零图像差不通过。静态片段、覆盖、截图不可用或日志截断应为证据不足。

HDR 按能力、选择、解码、输出、恢复、观感六层记录。能力层只证明环境可支持；选择层绑定实际选流；解码层记录 codec、位深、transfer 与元数据；输出层必须绑定当前视频输出对象的配置回读和呈现证据；恢复层复核全屏、重入和 SDR/HDR 切换后状态。首轮观感固定为未验收。

Android 当前 `configureOutput.active` 只反映窗口 HDR 模式设置，不能作为视频 Surface 实际 HDR 输出的通过证据。OHOS 的 NativeWindow/RenderService/HCPP 与 iOS 对应渲染后端证据均须独立采集。无法读取时报告 `INCONCLUSIVE`，不以能力声明替代输出证据。

用例状态为 `PASS`、`FAIL`、`BLOCKED`、`INCONCLUSIVE`、`ERROR`、`SKIP`。退出码为：0 全部必需项通过，1 产品失败，2 工具或配置错误，3 环境阻塞或证据不足；混合结果按 `ERROR > FAIL > 未完成 > PASS` 取值。HDR 不支持设备只能通过降级策略用例，不能通过原生 HDR 输出套件。

## 实施与验收顺序

1. 建立 CLI、配置、设备锁、驱动抽象、证据 schema、离线重放与报告；为旧布局、错误 PID、乱序/重复日志、历史 ANR、截图噪声和日志中断写判定器测试。
2. 实现 Android 驱动，先迁移既有重入 ANR 场景，再接入起播、控制、全屏、手势、前后台和 HDR 套件。在实际运行前重新核验设备序列号、系统、分辨率、HDR 能力和候选身份；再以第二台设备或模拟器证明不依赖固定坐标。
3. 统一入口调用既有 OHOS 脚本并保存原始结果；逐场景迁移，离线重放既有证据后在同一真机复跑，保留 PID、view、epoch、generation、输入顺序和色彩契约。
4. 实现 iOS 驱动并先验证导航、布局、输入和日志；真机/WDA/签名缺失时可交付实现及离线测试，但明确为未完成实机验收。
5. macOS 后续接入窗口、鼠标键盘和显示专项；移动端方向、音量手势按能力排除，EDR 与显示切换单独验收。

Android 首验通过条件：固定 BV 身份、5 轮重入、3 轮全屏/前后台、暂停/Seek/手势完成，测试窗口无新增 ANR、崩溃或持续无帧。HDR 框架通过条件是能正确保存矩阵证据并区分能力不足、产品失败和证据不足；原生 HDR 输出是否通过取决于实际运行结果。

更新 `TASKS.md` 和当前 conversation，保留每个平台独立的代码、离线验证、设备运行和 HDR 自动链路状态。该方案只保存设计，尚未创建 `tool/player_test/`、未迁移现有脚本、未运行 Android 首验。

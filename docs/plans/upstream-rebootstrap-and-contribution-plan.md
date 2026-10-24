# 上游重建、功能迁移与社区贡献计划

状态：待方案评审，禁止执行
更新时间：2026-09-05
适用仓库：PiliPlusX、media-kit、libmpv-ohos-build

## 1. 文档目的

本计划用于把当前建立在多层 fork 和长期集成分支上的工作，迁移到直接跟踪活跃
上游的干净仓库。迁移不采用整体 merge 或一次性 rebase，而是逐项完成：

```text
识别功能 → 判断归属 → 设计最小变更 → 从目标上游重做或挑选 → review
→ 自动化验证 → 目标平台运行验证 → 产品集成 → 按需提交上游 PR
```

本文既是方案设计，也是后续任务拆分规范。每个子任务都必须具备明确输入、操作边界、
输出、验证命令、验收条件和停止条件，使不了解完整历史的执行者也能安全工作。

在本计划通过评审以前，不执行 GitHub 仓库重命名、删除、重新 fork、remote 修改、
代码迁移、push、issue 评论或 PR 操作。

## 2. 目标与非目标

### 2.1 目标

1. 把 `bggRGjQaUbCoE/PiliPlus` 设为应用代码的主要跟踪上游。
2. 把 `media-kit/media-kit` 设为播放框架的主要跟踪上游；在 OHOS 正式合入前，
   只维护从官方最新主分支派生的最小 OHOS fork。
3. 把 `mpv-ohos/libmpv-ohos-build` 及其真实源码、补丁和产物链设为 OHOS
   libmpv 的独立依赖层。
4. 保留现有仓库和提交历史，作为迁移来源、产品回滚基线和证据档案。
5. 每项功能只进入一个明确的归属层，避免应用逻辑、播放器框架和二进制依赖耦合。
6. 所有准备提交社区的改动都从目标上游最新主分支建立干净分支。
7. 形成可持续同步、回滚、验证和上游贡献流程。

### 2.2 非目标

- 不要求把所有现有定制都提交给上游。
- 不以保持旧提交 SHA 或旧分支拓扑为迁移成功条件。
- 不在迁移阶段顺带重构无关代码或升级全部依赖。
- 不把编译成功、模拟器启动、日志声明或能力探测当作真机播放/HDR 验收。
- 不把 `media-kit` OHOS 支持、HDR、Darwin 生命周期和 libmpv 更新放进同一个 PR。
- 不直接把 GPL-3.0 的 PiliPlusX 代码复制进 MIT 的 media-kit 或 libmpv 构建仓库。

## 3. 方案编写与复核基线

### 3.1 本地 PiliPlusX 编写快照

截至 2026-09-04：

- 当前分支：`fix/darwin-video-output-rebuild-barrier`。
- 当前提交：`d2578d584ae86a3540d3e08512d1fdac1e866256`。
- `origin` 指向 `cnctem/PiliPlusX`。
- `personal` 指向 `Goodwu/PiliPlusX`。
- 当前工作树在本计划编写前为空。
- `pubspec.yaml` 中 media-kit 相关 git 依赖统一指向
  `Goodwu/media-kit@0fa6afe9cd9af8d8437919257d81a27c643f2f63`。

以上是计划编写快照，不是执行时自动更新的状态。进入 `INV-01`、`INV-02` 或任何
仓库变更任务前，执行者必须重新记录当前分支、HEAD、工作树、remote、`pubspec.yaml`
和 `pubspec.lock`；不得因为本文仍显示旧 HEAD 就覆盖新提交或清理现有工作树。

现有状态文档中仍有 `73536ef...` 或 `ad22c36a...` 等历史候选 SHA。它们是阶段性
证据，不得直接作为新基线。任务 `INV-03` 必须解释每个 SHA 的祖先关系、有效改动和
验证状态，最终只选择一个新的集成候选。

### 3.2 远端角色

```text
应用：
bggRGjQaUbCoE/PiliPlus        主要应用上游
cnctem/PiliPlusX              只读参考上游
Goodwu/PiliPlusX              当前产品/历史 fork

播放器：
media-kit/media-kit           主要框架上游
bggRGjQaUbCoE/media-kit       社区参考 fork
Goodwu/media-kit              当前产品/历史 fork

OHOS libmpv：
mpv-ohos/libmpv-ohos-build    目标构建链上游
ErBWs/libmpv-ohos-build       PR #1326 当前引用的实现来源之一
ErBWs/mpv:feat-ohos-support   PR #1326 提到的 mpv 源码/补丁来源之一
```

### 3.3 media-kit PR #1326 快照

截至 2026-09-05 复核，官方 `media-kit/media-kit:main` 为
`c533e446755f51cf53c7e57aea873f2aa5355f81`，`media-kit/media-kit#1326`：

- 状态为 Open；目标为 `media-kit/media-kit:main`。
- 包含 20 个提交、63 个文件、约 1255 行新增。
- GitHub 报告存在冲突，不能直接合并。
- 同时包含 media-kit 核心条件处理、OHOS libs 包、OHOS video controller、ETS
  texture 管理和测试应用。
- `media_kit_libs_ohos` 的 CMake 当前下载固定 SHA256 的
  `libmpv_aarch64.zip`，解压到 `libs/arm64-v8a` 并链接 `libmpv.so.2`。
- 下载产物来自独立的 `libmpv-ohos-build` release，因此 media-kit PR 的可复现性、
  ABI、许可证和供应链完整性依赖该外部项目。
- 当前路径只覆盖 ARM64；不能据此宣称 OHOS x86_64 模拟器可播放。
- 官方 `main` 不存在 `media_kit_libs_ohos`，因此官方发布包不能直接替代当前 OHOS
  依赖；非 OHOS 平台切回官方也不能据此宣称已完成整个项目的官方切换。

PR #1326 是必须对齐的已有社区工作，不应在没有沟通的情况下提交一份内容重叠的
巨型替代 PR。

### 3.4 原生依赖基线

各平台实际下载 URL、固定版本、摘要和当前 fork 差异见
[media-kit 原生依赖来源与跟踪基线](../reference/media-kit-native-dependencies.md)。
截至本次复核：

- 官方 Android main 消费 `media-kit/libmpv-android-video-build v1.1.7`，即使该构建
  仓库已有更新 Release，也不能自动视为 media-kit 已采用；
- 官方 iOS/macOS 消费 `media-kit/libmpv-darwin-build v0.7.2`；
- 官方 Windows 消费 `media-kit/libmpv-win32-video-cmake 20241021`，并额外下载
  非 media-kit 组织下的 ANGLE `v1.0.1`；
- 官方 Linux 使用系统 `libmpv`/`libepoxy`，另下载 mimalloc 源码；
- 官方没有 OHOS libmpv 下载链，当前 fork 则依赖独立的 OHOS Release。

版本跟踪必须区分“media-kit 构建声明”“构建仓库最新 Release”“产品 lock”和
“本地未发布候选”四种状态。任何 URL 与摘要不匹配的本地产物都不得作为社区 PR、CI
或干净环境的输入。

## 4. 目标仓库拓扑与命名

### 4.1 推荐拓扑

```text
bggRGjQaUbCoE/PiliPlus
└── <contribution-owner>/PiliPlus         直接 fork，应用上游贡献
    └── product/piliplusx                 产品集成分支，可选

media-kit/media-kit
└── <contribution-owner>/media-kit        直接 fork，框架上游贡献
    └── integration/piliplusx             产品验证分支，不用于直接 PR

mpv-ohos/libmpv-ohos-build
└── <contribution-owner>/libmpv-ohos-build
    └── release/<toolchain>-<mpv-version>  可复现构建与发布

历史仓库：
Goodwu/PiliPlusX-legacy
Goodwu/media-kit-legacy
```

`<contribution-owner>` 优先使用新的组织。原因是仅重命名现有 fork 不会改变 fork
父仓库，也通常不会释放同一 fork network 下的第二个 fork 名额。使用新的组织可以
在不删除历史仓库的情况下建立直接 fork。

在 OHOS 被官方合入前，推荐让产品需要的 media-kit 子包都来自同一个、紧跟官方
`main` 的最小 fork SHA。不要临时拼接多个互不对应的官方和第三方 package 版本；若
确需只 override OHOS 包，必须先证明 `media_kit`、`media_kit_video` 与平台 libs 的
API/版本约束可组合，并提供整组一键回滚。

### 4.2 仓库角色约束

| 仓库/分支 | 可写内容 | 禁止内容 |
| --- | --- | --- |
| `PiliPlusX-legacy` | 历史 tag、旧分支、迁移说明 | 迁移开始后的新功能开发 |
| 新 `PiliPlus` fork 的 `main` | 仅同步官方 main | 直接开发、强制改写历史 |
| `upstream-pr/app-*` | 单一通用应用改动 | OHOS/HDR/media-kit 混合改动 |
| 新 `media-kit` fork 的 `main` | 仅同步官方 main | 产品特判和 PiliPlusX 命名 |
| `upstream-pr/media-*` | 单一通用框架改动 | 应用业务、私有发布依赖 |
| `integration/piliplusx` | 已 review 候选的组合验证 | 直接作为社区 PR head |
| `libmpv-ohos-build` | 构建脚本、patch、SBOM、release | PiliPlusX 业务逻辑 |

## 5. 迁移治理模型

### 5.1 功能单元

每个迁移单元必须满足：

- 一个问题或能力；
- 一个主要代码归属仓库；
- 一个回滚边界；
- 一组独立验收条件；
- 能在不合并其他迁移单元时 review；
- 如果依赖其他单元，在任务单中明确写出任务 ID 和最低版本/SHA。

禁止以“同步旧分支”“迁移所有 HDR 改动”“移植 OHOS”作为单个任务。

### 5.2 功能清单模板

每项功能建立一条记录：

```text
ID：APP-xxx / MK-xxx / MPV-xxx / INT-xxx
名称：
问题陈述：
用户可见行为：
旧仓库来源分支与提交：
目标仓库与目标分支：
许可证：
依赖任务：
涉及文件：
明确排除：
迁移方法：重做 / cherry-pick -x / format-patch 后编辑
最小测试：
平台运行验证：
回退方案：
社区 issue/PR：
状态：待盘点 / 待设计 / 实施中 / 已验证 / 已提交 / 已合入 / 产品保留
证据位置：
```

### 5.3 归属决策树

```text
是否包含 Bilibili/PiliPlus UI 或业务状态？
├── 是 → 应用层
│   ├── 是否对原版 PiliPlus 通用？
│   │   ├── 是 → bgg 上游候选
│   │   └── 否 → PiliPlusX 产品保留
│   └── 不得进入 media-kit
└── 否 → 是否修改 Player、VideoController、native renderer 或通用生命周期？
    ├── 是 → media-kit 候选
    └── 否 → 是否构建/打包 OHOS libmpv？
        ├── 是 → libmpv-ohos-build
        └── 否 → 重新 review 归属，停止实现
```

### 5.4 分支与提交规则

- 分支必须从目标仓库最新主分支创建，不从产品集成分支创建上游 PR。
- 分支名：`upstream-pr/app-<issue>-<slug>`、
  `upstream-pr/media-<issue>-<slug>`、`build/ohos-<slug>`。
- 优先重做小型修改；只有旧提交边界干净时才 `cherry-pick -x`。
- 每个提交应能通过对应层的最小测试；提交说明使用仓库现有风格，如
  `fix(scope): ...`、`feat(scope): ...`、`build(scope): ...`。
- 禁止在功能提交中混入格式化全仓、依赖大升级或生成产物。
- PR 前执行 `git range-diff`，确认迁移过程中没有漏掉有意修改或带入无关修改。

## 6. 总体阶段与依赖顺序

```text
阶段 0：方案批准
  ↓
阶段 1：只读盘点与历史归档
  ↓
阶段 2：GitHub 仓库重建和干净基线
  ├── 应用基线
  ├── media-kit 基线
  └── libmpv 构建基线
       ↓
阶段 3：低风险应用功能迁移
       ↓
阶段 4：libmpv OHOS 可复现供应链
       ↓
阶段 5：media-kit 通用生命周期
       ↓
阶段 6：media-kit OHOS 最小支持
       ↓
阶段 7：PiliPlusX OHOS 消费侧
       ↓
阶段 8：HDR 公共契约和各平台原生输出
       ↓
阶段 9：持续同步、发布与旧仓库冻结
```

阶段 4 是阶段 6 的前置条件；阶段 5 与阶段 4 可并行，但生命周期 PR 不得依赖
OHOS 或 HDR。阶段 8 必须在 SDR 播放和输出释放稳定后开始。

## 7. 可拆分任务清单

以下任务的“执行者”均不得擅自扩展范围。遇到停止条件时，应保留工作树和日志，
报告具体证据，不得自行 merge、force-push、关闭 PR 或删除仓库。

### GATE-00：方案批准

输入：本文档及关联状态文档。
操作：由维护者 review 仓库命名、所有权、迁移顺序和 PR 策略。
输出：批准意见或修订清单。
验收：维护者明确允许进入 `INV-01`。
停止条件：未批准；不得开始任何 GitHub 变更。

### INV-01：盘点 PiliPlusX 产品差异

依赖：`GATE-00`。
输入：当前分支、`dev-new`、`bggRGjQaUbCoE/PiliPlus:main`、
`cnctem/PiliPlusX:dev-new`。
操作：

1. fetch 所有远端，不修改工作分支；
2. 记录每条基线 SHA 和提交日期；
3. 分别输出 commit-only 和 path-level diff；
4. 按“通用应用、PiliPlusX 产品、OHOS、media-kit 消费、HDR、构建/CI、文档”分类；
5. 对 merge commit 展开来源，避免把上游已存在的提交算作本地功能；
6. 为每个候选创建功能清单记录，不迁移代码。

建议命令：

```bash
git fetch --all --prune --tags
git log --left-right --cherry-pick --oneline <upstream>...<product>
git diff --stat --find-renames <upstream>...<product>
git diff --name-status --find-renames <upstream>...<product>
git log --first-parent --oneline <product-base>..<product-head>
```

输出：应用功能清单、来源提交表、疑似重复项。
验收：每个差异至少归入一类；未确定项明确标记，不凭猜测归属。
停止条件：基线 SHA 不明确、远端不可访问、工作树发生变化。

### INV-02：盘点 media-kit 差异

依赖：`GATE-00`。
输入：`media-kit/media-kit:main`、`bggRGjQaUbCoE/media-kit`、
`Goodwu/media-kit` 所有相关分支和 PiliPlusX 当前锁定 SHA。
操作：

1. 建立提交祖先图；
2. 分离 upstream 已有改动、OHOS、通用生命周期、HDR API、平台 native 输出、CI；
3. 检查 `0fa6afe9...`、`73536ef...`、`ad22c36a...`、`cc7b62b...` 的祖先关系；
4. 对每个 media-kit 包列出实际修改文件；
5. 标记哪些改动已被官方 main 的后续实现替代。

输出：media-kit 功能清单和 SHA 关系图。
验收：任何候选提交都能说明“来自哪里、解决什么、是否仍需要”。
停止条件：缺少远端分支或不可验证提交来源。

### INV-03：证据与文档漂移审计

依赖：`INV-01`、`INV-02`。
操作：逐项核对 `docs/status/`、`docs/reviews/`、`docs/plans/` 中的分支名、SHA、
构建状态和真机状态；历史快照保留，当前状态错误则单独提出文档修订任务。
输出：漂移清单。
验收：当前依赖 SHA 与历史 SHA 不再混用；构建、运行、HDR 三种证据分级明确。

### ARCH-01：建立可恢复归档

依赖：`INV-01`、`INV-02`、维护者批准远端变更。
操作：

1. 为两个现有远端仓库创建 mirror clone；
2. 校验所有 heads/tags 数量和关键 SHA；
3. 创建不可变迁移起点 tag；
4. 导出仓库设置、Actions 状态、release、开放 PR/issue 列表；
5. 记录恢复方法。

输出：两份镜像、校验报告、恢复说明。
验收：从镜像可解析所有关键提交；远端任何变更前完成校验。
停止条件：镜像不完整、LFS/大文件缺失、关键 SHA 无法解析。

### REPO-01：重命名历史仓库

依赖：`ARCH-01`、维护者明确批准。
操作：在 GitHub 重命名为约定的 `*-legacy` 名称；更新仓库描述为只读历史来源；
不删除分支、不关闭 PR、不改变默认分支。
输出：新 URL 和重定向验证记录。
验收：旧 URL 可重定向，关键分支/tag 可浏览，clone/fetch 正常。
停止条件：GitHub 提示依赖、Pages、Actions 或包发布将不可恢复地受影响。

### REPO-02：创建三个直接 fork

依赖：`REPO-01`。
操作：优先在新组织下分别从三个目标上游 fork；仅复制默认分支；启用必要 Actions，
不添加产品代码。
输出：三个直接 fork URL 和 parent 验证截图/记录。
验收：仓库首页显示预期直接父仓库，默认分支与上游 SHA 一致。
停止条件：账户已有 fork 导致 owner 不可选；不得删除旧仓库绕过，返回维护者决定。

### REPO-03：重配本地 remote

依赖：`REPO-02`。
操作前记录 `git remote -v`；建议命名：

```text
origin             新产品/贡献 fork
upstream-app       bggRGjQaUbCoE/PiliPlus
reference-cnctem   cnctem/PiliPlusX
legacy-app         旧 Goodwu/PiliPlusX-legacy
```

media-kit 与 libmpv 使用独立 clone，不把不同项目全部塞进应用仓库 remote。
输出：remote 清单和 fetch 结果。
验收：每个 remote 的 fetch/push URL 与角色一致；上游 remote 禁止 push。
停止条件：任何 URL 指向不明仓库或存在未备份本地-only 分支。

### BASE-APP-01：应用官方基线验证

依赖：`REPO-02`。
操作：从 `upstream-app/main` 创建临时验证分支；严格使用上游声明工具链；运行依赖解析、
format check、analyze、tests 和一个风险最低的 release build。
输出：命令、工具版本、退出码、产物摘要和上游基线 SHA。
验收：建立“零本地改动”的可复现基线；若上游本身失败，单独记录，不带修复进入迁移。

### BASE-MK-01：media-kit 官方基线验证

依赖：`REPO-02`。
操作：按官方工作区结构运行 CI 中等价的 format、analyze、test 和可用平台构建；记录
Flutter/Dart、native 工具链和主分支 SHA。逐平台审计实际下载 URL、摘要算法、固定
版本、构建仓库最新 Release、许可证和是否使用系统库；OHOS 缺失也必须作为基线结果。
输出：官方 main 基线报告和原生依赖差异表。
验收：后续每个 media-kit PR 都能与同一基线比较。

### BASE-MPV-01：libmpv 构建基线审计

依赖：`REPO-02`。
操作：不先构建；审计源码版本、submodule/download URL、patch 顺序、工具链、目标 ABI、
release 产物结构和许可证。
输出：依赖锁定表和不可复现项列表。
验收：每个下载输入都有版本/commit、哈希、许可证和用途。

### APP-01：迁移低风险通用应用修复

依赖：`BASE-APP-01`、`INV-01`。
选择条件：不依赖 OHOS、HDR、PiliPlusX 命名或 media-kit fork。
操作：每个修复单独分支；先确认 bgg main 尚未等价修复；重做或 `cherry-pick -x`；
补充回归测试。
输出：一个功能一个候选 PR。
验收：diff 只包含问题相关文件；上游基线测试不退化。
停止条件：发现需要产品特判或同时升级多个依赖，重新分类。

### APP-02：迁移通用播放状态逻辑

依赖：`APP-01`、`BASE-MK-01`。
范围：仅应用消费者侧的播放状态、错误恢复和 controller 调用顺序。
排除：media-kit native 生命周期、HDR surface、OHOS plugin。
验收：SDR 点播、暂停、seek、换源、退出、重复进入均通过；无法运行的平台标记待验证。

### MPV-01：固定 OHOS native 依赖清单

依赖：`BASE-MPV-01`。
操作：固定 OHOS SDK/NDK、CMake/Meson/Ninja、mpv、FFmpeg、libass、libplacebo 及其他
依赖版本；记录下载哈希、许可证和 patch 来源。
输出：机器可读 lock/manifest 和人类可读依赖表。
验收：没有浮动 branch、无哈希 URL 或无法追溯的预编译输入。

### MPV-02：规范 patch 队列

依赖：`MPV-01`。
操作：按依赖和目的拆分 patch；每个 patch 有说明、上游来源、适用版本、许可证和
`git apply --check`/等价验证；广告过滤等产品功能不得进入通用基础产物。
输出：最小 OHOS patch 队列。
验收：纯净源码加 patch 可重复得到相同源树；移除任一可选产品 patch 不影响基础播放。

### MPV-03：可复现 ARM64 构建

依赖：`MPV-02`。
操作：在干净 runner 构建；禁止引用开发机绝对路径；记录完整命令、环境变量白名单、
ELF 动态依赖、导出符号和压缩包内容。
输出：ARM64 `libmpv.so*`、必要运行库、build manifest、SHA256、许可证包、SBOM。
验收：第二个干净环境能从相同输入重建；如果二进制字节受时间戳影响，至少保证
源码/配置/符号/依赖一致并解释差异。

### MPV-04：ARM64 运行验证

依赖：`MPV-03`。
操作：在 OHOS 实体机加载动态库并运行最小播放器；验证启动、首帧、音频、seek、
销毁和重复打开。
输出：设备型号、系统 API、包 SHA、日志和画面证据。
验收：动态库可加载且基础 SDR 播放通过。
停止条件：只有 HAP 构建或安装成功，不得标记完成。

### MPV-05：x86_64 可行性与产物

依赖：`MPV-03`。
操作：确认所有依赖可由 OHOS x86_64 toolchain 构建；不得重命名 ARM64 或使用普通
Linux x86_64 库；构建并检查 ELF machine、动态依赖和 HAP 路径。
输出：可用产物或带准确阻塞项的可行性报告。
验收：只有 x86_64 原生产物加模拟器加载/播放证据才算完成。

### MPV-06：发布和消费契约

依赖：`MPV-03`、`MPV-04`；x86_64 可后续增加。
操作：使用不可变 tag 发布；资产名包含版本和 ABI；release 附 SHA256、SBOM、许可证、
构建 manifest、源码/patch commit；定义 media-kit CMake 如何选择 ABI 和校验。
输出：可供社区引用的 release。
验收：下载 URL 对应资产的实算摘要与声明一致；删除本地缓存后 media-kit 能按
manifest 下载并验证；校验失败必须 fail closed。本地 archive 与公开 URL 不一致时
不得标记完成。

### MK-01：与 media-kit #1326 对齐

依赖：`INV-02`、`BASE-MK-01`、`BASE-MPV-01`。
操作：形成一份不发出的评论草稿，说明已完成的验证、准备提供的可复现 libmpv 链、
建议拆分方式、愿意协作的具体部分和与现有 PR 的差异。提交评论属于外部写操作，
必须由维护者单独批准。
输出：评论草稿和重叠文件表。
验收：不宣称取代原作者工作，不重复提交未沟通的大 PR，不夹带 PiliPlusX 需求。

### MK-02：通用 dispose/create 生命周期修复

依赖：`BASE-MK-01`、`INV-02`。
范围：仅通用或单个平台可独立证明的输出释放竞态。
操作：先确认官方 main 是否已有同等修复；建立最小复现；补测试；再移植 completion
barrier、幂等 dispose 或 handle 串行化中真正必要的部分。
排除：OHOS 注册、HDR API、PiliPlusX 调用方、工具链固定。
验收：测试先失败后通过；dispose 完成契约明确；无固定延时；现有平台测试通过。

### MK-03：OHOS 核心平台识别

依赖：`MK-01`、维护者对拆分方向无反对意见。
范围：条件导入、平台枚举、native library/asset/temp-file 的最小 OHOS 兼容。
排除：video texture、预编译 libmpv 包、测试应用、硬件解码。
验收：非 OHOS 平台行为和 API 不变；OHOS 分支可静态分析并有单测。

### MK-04：`media_kit_libs_ohos` 包

依赖：`MPV-06`、`MK-03`。
操作：新增最小 package；按 ABI 下载不可变 release；校验 SHA256；准确描述包用途；
补 CHANGELOG、README、LICENSE/第三方许可证和离线缓存行为。
验收：ARM64 包构建、库路径/SONAME/依赖检查通过；不支持 ABI 明确失败，不静默打包
错误架构；空缓存能从公开 URL 获取与声明 SHA256 一致的资产。

### MK-05：OHOS video controller 和 texture 输出

依赖：`MK-03`、`MK-04`。
范围：Dart controller、MethodChannel、ETS texture registry、surface ID/尺寸和销毁。
操作：从 PR #1326 和本地改动中逐文件 review；先保持最小 SDR；保留 idempotent dispose；
surface 创建失败向 Dart 返回明确错误；不得吞掉错误后伪装成功。
验收：真机首帧、尺寸变化、旋转/前后台、seek、重复 create/dispose 和多次换源通过。

### MK-06：OHOS 测试工程与 CI

依赖：`MK-05`。
操作：提供最小官方测试应用；CI 至少完成静态检查、package build、HAP 内容和 ABI 检查；
真实设备结果单独记录。
验收：CI 不依赖 PiliPlusX；构建证据与运行证据分栏；所有下载输入固定。

### MK-07：OHOS 硬件解码

依赖：`MK-05` 完成 SDR 稳定性验收。
操作：单独设计硬解能力检测、codec profile、失败回退和性能验证；不得把 `hwdec=auto`
等同于硬件解码成功。
验收：日志、系统解码器、功耗/帧率和画面共同证明；失败时稳定回退软件解码或 SDR。

### INT-APP-MK-01：PiliPlusX 消费新的 media-kit 候选

依赖：`MK-02` 或 `MK-05` 对应候选已 review。
操作：所有 media-kit 子包一次性固定到同一完整 SHA；更新 lock；禁止部分包跨 SHA；
运行应用层回归。在 OHOS 未上游化期间，该 SHA 应来自直接基于官方 main 的最小 fork；
“官方 hosted package + OHOS fork package”的混用必须另建兼容性任务证明，不能默认采用。
验收：依赖来源、resolved-ref、包版本一致；旧 SHA 可一键回滚。

### APP-OHOS-01：迁移 OHOS 应用兼容层

依赖：`INT-APP-MK-01`、`INV-01`。
范围：应用条件导入、插件可用性、OHOS Flutter 3.44.9 兼容、构建准备脚本。
排除：media-kit 内部修改、libmpv 构建、HDR 宣称。
验收：完整 `lib/main.dart` HAP 构建；主平台源码和 lock 不被准备脚本修改；漂移时失败。

### APP-OHOS-02：OHOS SDR 真机回归

依赖：`APP-OHOS-01`、`MPV-04`。
操作：验证安装、启动、首页、登录态、点播首帧、音画、seek、字幕、弹幕、亮度/音量、
前后台、旋转、退出和重复播放。
验收：使用当前候选 SHA 的实体机证据；模拟器不替代视频首帧验收。

### HDR-01：迁移通用 HDR 状态模型

依赖：`APP-OHOS-02` 或至少所有目标平台 SDR 生命周期稳定。
操作：拆分 source metadata、capability、candidate、active、fallback；删除 PiliPlusX 命名
对 media-kit 公共接口的渗透；默认 fail closed。
验收：能力存在不等于输出激活；探测失败和配置失败均回退可播放 SDR。

### HDR-02：平台原生输出

依赖：`HDR-01`、`MK-02`。
操作：Android、Apple、Windows、Linux、OHOS 各自独立任务和分支；每个平台只修改
自身 native 层与公共契约必要部分。
验收：沿用 HDR 状态矩阵和设备证据模板；一个平台通过不提升其他平台状态。

### FREEZE-01：冻结旧仓库

依赖：所有保留功能已迁移或明确放弃，产品发布通过。
操作：旧仓库 README 标记归档、迁移目标和最后支持版本；开启 GitHub Archive 前再次
核对开放 PR、release、issue 和恢复镜像。
验收：新仓库包含所有继续维护的功能；旧仓库只读；回滚路径经过演练。

## 8. PR 提交顺序设计

### 8.1 应用上游建议顺序

1. 已有通用 bug 修复，按问题逐个提交。
2. 不改变公共依赖的播放状态修复。
3. 独立的平台构建兼容修复。
4. 可被原版接受的 UI/交互功能。
5. 只有在 media-kit 官方接口稳定后，提交相应消费侧调整。

PiliPlusX 重命名、OHOS 产品发布、专属渠道和实验 HDR 不作为 bgg PR 的前置内容。

### 8.2 media-kit 建议顺序

推荐依赖序列：

```text
MPV 可复现 release
  → 通用平台识别
  → media_kit_libs_ohos
  → OHOS texture/controller
  → OHOS 测试与 CI
  → 硬件解码
  → HDR/色彩空间（后续独立提案）
```

生命周期竞态修复与上述 OHOS 序列并行，但保持独立 PR。若官方维护者要求单个 OHOS
PR，则仍保持上述提交序列，并保证每个提交可 review、可回退；不要 squash 成一个
无法追踪的巨型提交后才请求 review。

### 8.3 PR 前置检查

每个 PR 必须满足：

- 已搜索 issue、开放 PR 和 main，确认没有重复实现；
- 有问题陈述和最小复现；
- 分支基于目标上游最新 main；
- diff 中没有 merge commit、产品命名、私有 URL 或无关格式化；
- 新行为有测试，平台特有行为有目标构建；
- PR 描述列出已验证与未验证内容；
- 二进制依赖有来源、版本、SHA256、许可证、SBOM 和重建方法；
- 同时记录框架实际消费版本和构建仓库最新 Release；二者不一致时解释为何不升级；
- 在空缓存中验证每个 Release URL 与摘要，禁止依赖开发机残留 archive；
- 对破坏性 API、额外依赖和包体积变化明确说明；
- 维护者未回复时不反复开重复 PR 催促。

## 9. 验证矩阵与证据等级

### 9.1 证据等级

| 等级 | 定义 | 可证明 | 不可证明 |
| --- | --- | --- | --- |
| E0 | 源码 review | 设计和静态边界 | 可构建、可运行 |
| E1 | 静态检查/单测 | API 和纯逻辑 | native 加载、画面 |
| E2 | 目标平台构建 | 工具链和打包 | 安装、首帧 |
| E3 | 安装/启动 | manifest、Ability/进程 | 视频可播放 |
| E4 | SDR 运行 | 首帧、音画、seek、生命周期 | 原生 HDR |
| E5 | HDR 真机 | native surface、色彩空间、亮度/EDR | 其他设备泛化 |

任务不得越级标记。例如 OHOS HAP 包含 ARM64 `libmpv.so` 只能达到 E2；必须在实体机
完成首帧和生命周期才能达到 E4。

### 9.2 最小回归集合

所有播放器相关迁移至少检查：

```text
首次播放 → pause/resume → seek → 画质切换 → 换源
→ 前后台 → 旋转/窗口变化 → 播放结束 → dispose → 再次播放
```

生命周期修改额外执行高频重复 create/dispose；HDR 修改额外执行：

```text
SDR → HDR10/PQ → HLG → Dolby Vision fallback → SDR
```

## 10. 回滚策略

- 每个产品集成提交记录旧/新依赖 SHA。
- media-kit 所有子包必须同 SHA 升级和同 SHA 回滚。
- libmpv release 不覆盖既有 tag 或资产；坏产物发布新修订并废弃旧版本。
- 上游 PR 分支失败时回滚产品集成，不修改官方跟踪分支。
- 任何输出能力失败都回退现有 Texture/SDR；不通过固定延时掩盖竞态。
- 删除或 archive GitHub 仓库属于最后阶段，必须通过独立批准。

## 11. 子任务交接格式

执行者完成任务后只返回以下结构，避免结论不清：

```text
任务 ID：
基线 SHA：
实际修改文件：
执行命令及退出码：
产物及 SHA256：
通过的验收项：
未通过/未执行项及原因：
工作树状态：
提交 SHA（如授权提交）：
PR/issue（如授权创建）：
建议下一任务：
```

禁止只回复“构建成功”“CI 通过”“应该可以”。

## 12. Review 决策点

进入执行前，维护者需要明确确认：

1. 新直接 fork 使用哪个 GitHub 组织/账户；
2. 两个旧仓库的最终名称；
3. 是否保留一个独立 PiliPlusX 产品仓库，还是在新 PiliPlus fork 的产品分支维护；
4. `libmpv-ohos-build` 以 `mpv-ohos` 上游为主，还是新建中立构建仓库；
5. 与 PR #1326 的协作方式：向原 PR 贡献、共同重写，或经维护者同意后提交拆分 PR；
6. 首批应用迁移功能的优先级；
7. 哪些现有 HDR/OHOS 改动确定只保留在产品层。
8. OHOS 合入前是否采用“全部相关子包统一指向最小 fork SHA”的推荐过渡策略；若否，
   需要批准混合官方/分叉 package 的兼容性与回滚设计。

## 13. 关联资料

仓库内资料：

- [media-kit 输出重建修复计划](media-kit-output-rebuild-plan.md)
- [全平台原生 HDR 计划](native-hdr-development-plan.md)
- [非 HDR 全平台可用计划](sdr-cross-platform-plan.md)
- [media-kit PR #2 历史审查](../reviews/media-kit-pr-2-review.md)
- [OHOS 适配记录](../platforms/ohos-adaptation.md)
- [OHOS 开发总结](../status/ohos-development-summary.md)
- [HDR 验证账本](../status/hdr-verification.md)
- [media-kit 原生依赖来源与跟踪基线](../reference/media-kit-native-dependencies.md)

外部基线：

- [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)
- [media-kit/media-kit](https://github.com/media-kit/media-kit)
- [media-kit PR #1326](https://github.com/media-kit/media-kit/pull/1326)
- [mpv-ohos/libmpv-ohos-build](https://github.com/mpv-ohos/libmpv-ohos-build)
- [GitHub fork 概念与网络关系](https://docs.github.com/en/pull-requests/reference/forks)
- [GitHub fork 工作流](https://docs.github.com/en/pull-requests/how-tos/work-with-forks)

本文件当前停在 `GATE-00`，等待方案 review；任何执行任务均未开始。

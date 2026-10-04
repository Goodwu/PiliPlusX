# macOS 共享核心独立候选入口

`scripts/build_macos_shared_candidate.py` 将 sealed 输入、共享构建、精确 runtime 嵌入和候选封装接成一个显式入口。consumer 不修改原 App；普通构建仍执行最终运行库门禁。正式 CI 接线已纳入修复，锁固定共享 recipe/Swift bridge 的本地提交 `252c5851e2ebbcb0876f3bb819303c21fbfe29cd`；未推送且 hosted fresh 尚未运行。

## 输入与调用

先按 [输入准备说明](macos-shared-input-preparation.md) 生成 sealed inputs。所有路径显式传入，使用独立、真实路径；没有开发者 `/private/tmp`、`/opt` 或本机目录默认值。候选和日志父目录须存在；App、两份 sidecar 和 log 输出本身须不存在。work、published、candidate、两份 sidecar、logs 互不嵌套，并与所有源输入及仓库分离。

```bash
python3 scripts/build_macos_shared_candidate.py \
  --input-app "$NORMAL_UNIVERSAL_APP" \
  --inputs "$SEALED_INPUTS" \
  --recipe "$SHARED_RECIPE" \
  --work-dir "$SHARED_BUILD_WORK" \
  --published-dir "$SHARED_BUILD_OUTPUT" \
  --output-app "$INDEPENDENT_CANDIDATE_APP" \
  --log-dir "$NEW_RUN_LOG_DIRECTORY" \
  --input-kind unknown --jobs 4
```

源 App 必须是已签名的 arm64+x86_64 Runner，包含两架构的共享 Swift bridge marker。它可以是普通或诊断构建；`--input-kind normal|diagnostic|unknown` 只记录调用方声明，默认 `unknown`，不根据文件名推断正式产品状态。来源摘要、Runner/bridge 静态结果和诊断声明写入候选证据。marker 仅是静态前提，真实 backend probe 由既有 packager 完成。

已有 builder-owned work 的继续构建必须显式 `--resume`。入口先要求其 deps 和 archive 路径属于所选 sealed inputs；现有 builder 仍重新验证全部源码、参数、依赖、工具链和已发布文件身份，并真实执行 compile/no-op。构建后入口再次完整核对 state、完整源码、recipe、published 文件集合与 SHA，拒绝仅凭已有库继续。fresh 模式要求 work/published 都不存在。

加 `--check-inputs` 只运行 CPU 输入校验：源 App 树、universal Runner、逐 ABI bridge marker、源 App 签名、真实 sealed verify、20 项 runtime 的整文件身份和路径计划。它不会构建、封装、运行 backend/GPU probe 或发布候选；也不表示现有 work 的工具链已完成 resume 验收。

## 实际执行顺序与失败边界

1. 对原 App 普通文件 SHA、目录权限和符号链接目标字符串建立完整树身份。符号链接必须指向 App 内的现存对象；FIFO/device 等特殊文件拒绝。原 App 始终只读。
2. 调输入 preparer 的真实 `--verify`，按两 ABI lock 构造相同 universal 整文件 runtime 计划。拒绝路径逃逸、ID 歧义、薄片摘要、缺 ABI 和输入树外的二进制。
3. 调同一共享 builder，使用 sealed config/lock 和固定 mpv0.41 archive。构建后的 dependency identity 必须与 sealed lock 完整 JSON 一致；全部 source/recipe/build/publication 身份校验。
4. 在本次私有 staging 中复制 App 并嵌入真实依赖闭包：当前为 16 个 flat dylib 和 4 个 framework 二进制。flat 库保留精确 bytes；framework 仅替换已有 `Versions/A/<name>`，保留原 framework metadata/resources。拒绝缺少 metadata 的 framework，不制造假 framework。替换后预验现有签名，不能对已锁二进制重新签名或修改安装 ID 来“通过”。
5. 封装前再次真实 sealed verify。调用现有 `package_macos_shared_build.py`，在私有 staging 内生成新 App 和两份 sidecar。它执行完整 source/build/exact-runtime 绑定、正常 0.41/closure/NOW/signature 门禁与两架构 image-bound backend 创建/empty-target probe。源 App 的 framework 与自身签名不修改；packager 只签新的 Mpv framework 与候选 App。
6. 对完成封装的 App 再核对 locked runtime 整文件 bytes、两 ABI ID 和最终 bundle gates；再次核对 sealed 输入、原 App 完整树身份。全部检查通过才记录候选证据并发布。
7. 两份 sidecar 用 exclusive hardlink 发布，App 最后用 no-replace rename 发布；preflight 包括所有输出路径。失败仅回撤本次发布且 inode 未被他人替换的 sidecar，绝不删除外部冲突文件。私有 App 由本次 temporary staging 回收，原 App、sealed inputs、work/published 和失败日志保留。

App 与 sidecars 是三个文件系统对象，不能承诺三者单次原子事务。App 最后出现，可作为完成信号；强制终止可能留下仅 sidecar 的结果，重试不能覆盖，应选新输出路径并审查残留。普通异常的回撤有测试覆盖。

## 日志与验收

每次使用全新的 log 目录。阶段命令和明确失败退出码保存在各 log；`result.json` 记录成功、仅输入检查或失败，源 App 身份和输入构建的种类声明。最终 `.shared-core.json` 追加 consumer、sealed manifest 和 build identity 证据，`.shared-backend.json` 保留实际探针证据。日志不等于已发布候选，也不等于视频/视觉验收。

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s test -p prepare_macos_shared_inputs_test.py -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s test -p build_macos_shared_candidate_test.py -v
```

consumer 测试使用真实独立目录、字节、符号链接及 hardlink/inode 行为；编译、签名和封装工具边界由 mock 控制，覆盖整链顺序及失败不发布，不能代替真实构建/GPU。真实 fresh 构建与最终候选封装必须另行串行运行，记录实际 gate 退出码。该候选始终标记视频内容/可见验收 pending，不能据此启用 CI 默认或宣称 DV P5 颜色、流畅度通过。

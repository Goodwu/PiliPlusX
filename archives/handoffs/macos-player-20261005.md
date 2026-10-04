# macOS PiliPlusX agent 交接（2026-10-05）

## 目标与授权

完成 macOS PiliPlusX 剩余工作；防止未来最终包重新嵌入 mpv 0.36；P5/P8.4/HDR 使用共享 mpv/libplacebo 色彩核心。用户允许性能优化另开专题，不新增专门卡顿实验；必要回归顺带记录 GPU/thermal。用户现要求保存交接、提交并推送，不代表发布 Release、合并或完成全部验收。

新 agent 先读 AGENTS.local.md → routing.md → docs/README.md → TASKS.md → archives/conversations/player-architecture-remediation.md 的唯一 Current State。继续同目标，不重跑已证步骤、不沿用旧候选的接受结果。适用 native Agent Team；共享构建、测试及 Git 串行。

## 仓库、提交与工作目录

- 产品：/Users/wuweiwei1/src/PiliPlusX，分支 fix/darwin-video-output-rebuild-barrier，推送到 personal=https://github.com/Goodwu/PiliPlusX.git。origin 是 cnctem 上游。
- 产品前一已审提交：f3ceacb468d7d35ac8e3b75a825286f1a72dcaac（86路径）。本交接提交仅追加派生 plist 修复与账本/交接。
- 核心：/Users/wuweiwei1/.codex/worktrees/macos-reviewed-r4/media-kit，分支 codex/macos-shared-hdr-fix，origin=https://github.com/Goodwu/media-kit.git。
- 核心提交：252c5851e2ebbcb0876f3bb819303c21fbfe29cd，父 d24a59537faa8fde59b53d5b0c151b5c44a795bc。46个已审代码节点+两份hook所需上下文；原 /Users/wuweiwei1/src/media-kit Android dirty未纳入。
- 聊天工作目录：/Users/wuweiwei1/.codex/worktrees/9d4f/media-kit；这里保留原有实验/audit，不能整体stage。
- 隔离集成：/Users/wuweiwei1/src/media-kit-build/shared-source-product-integration-20261005-r1/product。包含产品86已提交节点与本次六已审实现节点，Flutter缓存保留；不是新Git checkout，也不是hosted fresh。
- 核心实际构建源：/Users/wuweiwei1/src/media-kit-build/shared-source-derived-validation-20261005-r4/source；其原46节点对应252c5851。主两个包path override在此，其余八libs为既有本地wrapper，不能宣称全依赖均hosted固定解析。
- 正式锁 scripts/macos-shared-ci-inputs.lock.json reviewed_media_kit_revision=252c5851e2ebbcb0876f3bb819303c21fbfe29cd，SHA 8c3ec367b8d89e74d0b2ce6beefb74e240a5defa85846b8bc899b54a69766ab9，两严格常量同摘要，87 CPU测试及pin Critical PASS。

## 本次 bootstrap 修复及证据

R1 Release编译/签名通过，但guard先运行、ProcessInfoPlistFile随后覆盖pending；普通guard因旧mpv拒绝。R2加目标plist input解决顺序，但guard后写未建模签名依赖，最终CodeSign未重跑，strict signature失败。两个失败App已完整保留，禁止播放/分发；不要手工补签或仅clean掩盖。

新方案：Runner前部 Prepare读取原模板，确定性生成 DERIVED_FILE_DIR/PiliPlusX-BundleInfo.plist；Debug/Profile/Release三配置INFOPLIST_FILE统一指向派生文件。原 Enforce保留36framework与target plist共37inputs；bootstrap严格只读验证bool true，legacy拒绝pending。生成器拒绝未知/空模式、symlink/别名/污染模板，保留占位符，相同bytes不改inode/mtime，变化原子替换。ensure CLI现在为APP_PATH MODE两个参数，库内调用已同步。

六实现文件及绑定：macos/Runner.xcodeproj/project.pbxproj、scripts/prepare_macos_bundle_info.py、scripts/ensure_macos_mpv_bundle.sh、test/macos_shared_bootstrap_test.py、test/macos_bundle_info_test.py、docs/plans/macos-shared-candidate-bootstrap.md。准确SHA见 implementation-review/source-binding.json。设计V2 PASS_DESIGN_FOR_IMPLEMENTATION，实现V2 PASS_SOURCE_FOR_REAL_BUILD，28项CPU及额外失败路径独立PASS。

真实Release矩阵根目录：/Users/wuweiwei1/src/media-kit-build/macos-postcommit-diagnostic-bootstrap-20261005-r3。

- incremental-first、incremental-repeat-1、incremental-repeat-2：构建0，pending true，strict signature0，普通guard pending拒绝1。重复轮跳过CodeSign但plist bytes未变且签名有效。
- missing-target-and-derived：移走target和derived并执行assert不存在后构建0，自动恢复，pending/签名/拒绝门PASS。target缺失有build-command记录；derived缺失未单独落exists=false历史JSON，仅当时命令与备份，独立审核可保留证据不足。
- template-change：仅private模板加测试字段，最终字段正确并重新签名；template-restored恢复主模板原字节，最终签名/标记通过。主仓模板未改。
- unknown-mode：构建1，明确未知模式失败，旧App plist SHA未变、旧签名仍有效。
- switch-to-legacy：同目录无pending、双ABI mpv0.41/闭包/加载/签名及ordinary guard0；显式复用主仓build/native-deps缓存，未放宽门。
- switch-back-bootstrap：同目录pending true、strict0、ordinary pending拒绝1；当前private App就是此中间包，禁止直接作为最终候选播放。

每轮 result.json/build.log 保存精确argv/env/plist前后与strict/ordinary检查。extract_logs.py保存原SLF及selected graph，实际producer名称为Process PiliPlusX-BundleInfo.plist；不能仅按旧名称Process Info过滤。template-restored原SLF因Xcode日志保留策略已删除，明确记录缺失，不能补造ordering；其它关键轮原SLF已保存。

private PBX由构建工具自动改写，SHA 01ccfedc1b1d6632635fd5e133e3eb5b7da40ffc2d1a69219ac7e4cc41291c80；effective-project.pbxproj/diff绑定实际构建。最终独立语义检查仅Pods lock check移到Prepare之前，SPM对象/37inputs/三配置未变；最终V2结论 PASS_RELEASE_BOOTSTRAP_MATRIX_WITH_LIMITS，见 runtime-review。不要将private字节不等误称审查源仍逐字一致。

## 最终候选与可见验收边界

旧正常SharedR4Normal.app已通过双ABI0.41/21binary闭包/加载/签名/backend及V1绑定，但BV1heam6TExz窗口卡顿FAIL。旧诊断SharedR4LocalHDR.app P5颜色PASS，实际HDR输出UNKNOWN，严重卡顿FAIL；HLG严重卡顿FAIL；PQ颜色亮度高光PASS、开头卡顿后改善，非完整流畅PASS。用户以前多个候选流畅/颜色正常只属于原候选。最新诊断autoplay修正尚未最终封装或播放。

P8.4源代码条件RPU映射通路存在，但同PTS实际metadata生效未证；当前GL libplacebo→线性BT2020 RGBA16F→Metal EDR，不是系统native DV直通。HDR实际EDR/目标/同帧输出仍未闭环。native RGBA16F与完成帧发布窄PASS不等于全部HDR验收。

Chrome VT实际输入HEVC Main10/BT2020 HLG、用户60fps顺畅低GPU；iOS BiliHD同机P5 BV1Gt26BJEBT基本顺畅，实际profile/res/fps未独立绑定。Homebrew mpv MysteryBox也卡顿，不能唯一归因libplacebo。性能架构设计已留 REQUEST_CHANGES/后续整改，不在本轮实现。

## 下一步，按顺序

1. 核推送receipt与远端refs，确认核心commit可从正式锁的远程获取；推送成功不等于hosted fresh CI通过。
2. 读 bootstrap-derived-info-runtime-review 最终结论。若derived缺失历史证据不足，必要时单独复测并先记录target/derived exists=false；不要只重写历史记录。Debug/Profile实际构建路径仍未验证。
3. 对当前已签bootstrap执行完整shared consumer。旧normal consumer-command.json提供参数；recipe用derived-r4/source/tool/shared_gpu_next、inputs用shared-ci-prepared-inputs-r2/inputs。可在核source/recipe/sealed输入身份后显式--resume旧normal work及published，但输出App/log用全新目录，保留旧候选，不称hosted fresh。
4. scripts/build_macos_shared_candidate.py --input-app private Release App --inputs sealed inputs --recipe derived-r4 recipe --work-dir reviewed reusable work --published-dir reviewed published --output-app NEW.app --log-dir NEW/logs --jobs 2 --resume --input-kind diagnostic。先--check-inputs，仅通过后真实执行。不得手工清source pending。consumer必须私有stage清标记、重签并完成双ABI/闭包/加载/签名/backend，source tree不变。
5. 独立绑定新source/产物后再启动唯一App，做最终操作/长播/退出重入及HDR技术证据/可见验收。性能仍后续专题，必要测试顺带GPU/thermal，温度/频率目前不可用记null。
6. 远程全新CI/正式发布验证、受影响Android/iOS回归仍开放。无合并/Release授权；不要完成goal。

资源：最近Data可用约2.9GiB，privateRelease Products约847MiB/intermediates533MiB，Debug/Profile若新增缓存可能耗空间。不要删除未映射回归worktree、失败App或证据；先只读盘点。

## 保留的dirty与证据索引

不提交三份既有dirty：scripts/build_macos_goodwu_hdr.sh、scripts/build_macos_shared_candidate.sh、scripts/native/shared_backend_perf_probe.c。逐字备份及tracked diff在 /Users/wuweiwei1/src/media-kit-build/macos-agent-handoff-20261005/excluded-dirty-snapshot 与 excluded-tracked.diff。核心原仓Android dirty完整保留。索引并不代表这些内容已审核或提交。

[evidence index](macos-player-20261005.evidence-index.json)列出本地447份重要报告/JSON/日志原路径与SHA（包括已冻结的最终runtime审核）。完整App、源码构建依赖仍在原本目录，不能从metadata索引重建二进制。提交/推送最终receipt将保存在 /Users/wuweiwei1/src/media-kit-build/macos-agent-handoff-20261005/submission-receipt.json，并在Current State记录。

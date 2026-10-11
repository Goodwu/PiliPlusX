# MK-ROUTING-20261011 App

## Current State

2026-10-12：最新已完成联合源码验证为App b969fc289945ea0aa762de3a3ce026301bb17ec0 + media-kit bd9b9f852949af8980faaad337064a0830c405da。App run38153119252 attempt1实际执行192 Flutter、244 Python、bundle、10包源码绑定及远端新鲜度通过；严格分析34 info、0 warning、0 error，整体失败。终态中央6110898494、App6110898811；不是下述旧向量的重标。

CORE-CI03在中央6110943824认领文本控件、Web、生命周期及包名迁移。当前改动尚未提交、尚未全量验收；隔离Flutter3.47.2/私有pub-cache依现有patch.ps1 android配置，前后10包绑定一致，原共享SDK/cache未改。控件与Web行为回归正在执行；包名规范化须同步OHOS准备脚本，不能以name判断跳过工具链转换。产品experimental默认false保持。

OHOS包名兼容准备已修复：五项约束逐scope严格接受唯一old/new，小写包名不再跳过Dart/Flutter/flex/material转换；未知、缺失及重复字段/section拒绝。目标10项及关联19项通过，V1独立重跑目标10项通过、核对关联日志。仅脚本和新回归测试进入此检查点；真实OHOS pub/HAP/native及设备验收未执行。证据/tmp/mk-core-ohos-package-{before,after,related}.log。

CORE-CI04a已定位Release Python随机失败：PBX模板插值后扫描双下划线误拒合法临时路径。两文件修复保留payload/ABI/来源/签名检查，本机目标38及关联177项通过；V1独立重跑目标38通过并核对关联177日志，无阻塞发现。此检查点仅提交这两文件和当前记录，其他CI03/OHOS改动仍待验证；不等同真实Xcode签名验收。证据/tmp/mk-core-ci04a-before.log、/tmp/mk-core-ci04a-inputs.log、/tmp/mk-core-ci04a-related.log。

Release iOS兼容准备失败进一步定位为固定缩进匹配：当前view.dart仍有pointerDownFilter调用（10空格），prepare_standard_flutter_package_compat.py与macOS候选源码允许差异检查固定12空格。不能按“调用已删除”绕过断言；后续应统一严格匹配语义、覆盖实际源码缩进并保留未知变更拒绝。此项尚未修复。

### 接手时状态（历史溯源）

CORE继任登记media-kit PR4 comment6110756605，继续唯一routing/MK-ROUTING-20261011/PR1。App生产代码本阶段未修改，汇总台账归并CORE-CI02/F01终态。权威公共上下文在media-kit archives/conversations/media-kit-routing-20261011.md；v3与takeover仍为接手入口。

App569138fa+库6e7570fc在run38146940852第二次App job114499858358执行192Flutter、bundle/10包来源/新鲜度成功，34info/0error/0warning；同AppSHA此前244Python保留，不声称再次执行。artifact11705617556为实际向量，11705292989为旧库，不混用。终态6110417510，库6110447335。此次文档checkpoint没有改标旧测试为新SHA。

DEVICE继续原native构建/实机，DV0011095a43审查未闭环；续审6110762843。CORE-R01a只改库SurfaceTexture依赖与mismatch隔离；Appcontroller/hdr_output、SDK、native配方未认领改动。下一步最新组合验证、34info、Release CI和真实auto/prefer/require闭环。experimental默认false保持。

## History

- 2026-10-11：CORE继任从当前远端569138fa建立同分支独立worktree，保留默认checkout .zcodeignore；归并已完成F01/CI02与旧分析债务状态。

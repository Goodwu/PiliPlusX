# 中间产物清理

## Current State

2026-10-05：用户授权清理media-kit与PiliPlusX不再使用的中间产物。确认无相关构建进程，限定删除Git未跟踪的build内编译intermediates、Xcode模块/编译缓存与测试缓存。删除后逐路径确认不存在。完整清单：`archives/experiments/intermediate-cleanup-20261005.json`。

保留所有源码及原dirty修改、App/APK/outputs、证据日志、源码快照、依赖前缀与实验worktree；media-kit-build及/private/tmp实验不删除，仍存在未完成验收和失败复现用途。下次构建会重新生成缓存，耗时可能增加。未提交推送。

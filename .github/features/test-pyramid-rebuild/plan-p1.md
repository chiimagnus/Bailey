# P1 · 合并宿主测试目录与开发规范

**Goal:** 两类测试，取消宿主内部 Unit/Integration 目录。既有测试方法、断言、Target 与运行机制全部保持不变。

<a id="p1-t1"></a>

## P1-T1 迁移目录并同步开发规则

**Files:** `BaileyTests/`，`AGENTS.md`、`docs/testing.md`、`docs/development.md`、`docs/architecture.md`、`docs/README.md`、`CONTRIBUTING.md`、PR 模板与仍待执行的 Feature 计划。

1. 预检旧目录 47 个 Swift 文件、文件哈希、相对目标冲突和 Xcode 的 `PBXFileSystemSynchronizedRootGroup`。通过 `git mv` 合并到 `BaileyTests/<领域>/`，删除空的 Unit／Integration 目录。不要因移动文件而更名方法、修改 helper 或生产代码。
2. 由 `docs/testing.md` 统一定义宿主和完整 App 两种测试：前者含纯逻辑、真实 Git／文件与最小原生组件；后者只覆盖宿主不能证明的真实用户交互。同步所有现行开发入口及尚未执行的计划，清除 Unit/Integration 配比、路径及三层 Gate。历史审计记录按当时版本保留。
3. 不增加 Test Target／工程文件手工登记或 CI 脚本，保留 Makefile 选择器和 Dev 运行锁。核对已搬迁源码内容完全一致、宿主 XCTest 总数及代表性跨领域类实际发现和运行；文档链接／锚点、计划 Todo 与 `git diff --check` 都要通过。

**验收:** 47 个文件逐字节相同；549 个宿主方法（本次源码基线）全部仍被发现，跨领域定点宿主测试 0 失败；`Unit/` 和 `Integration/` 不存在。完整 E2E 是下一阶段工作，不把目录合并宣称为性能优化或已减少 UI。

**提交:** 此任务的目录迁移、长期规范与计划同步一个原子提交；不触碰正式 App 或用户 SSH。

## Phase Audit

P1 核对方法数量、文件哈希、Xcode 测试发现和选定宿主实际退出码。P2 保持待执行，不能把 P1 的成功视为已精简 133 项 UI。

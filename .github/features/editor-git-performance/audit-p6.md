# Audit P6 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p6.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P6-T1 完成同机综合复测与真机验收
- [x] P6-T2 核销文档、引用与本地证据

## 任务到文件的映射

- **P6-T1 综合复测**：同阶段实施 HEAD `0644d347`；产品入口与状态所有者沿 `Project → FileTab/DiffTab → GitCommandExecution/WorkspaceBackend → DiffNativeSurface/STTextView` 核对。实际验证日志、一次性脚本、真窗口截图和资源读数保留在被忽略的 `build/performance/final/`，详见 `evidence-p6.md`。覆盖最终 XCTest、真实 Windows SSH、独立安装签名、隔离完整 App、标签释放及空闲采样；没有修改产品源码。
- **P6-T2 文档与证据核销**：`docs/README.md`、`docs/features/{editor,git,diff,files,ssh}.md`、`docs/{testing,development,architecture,standards,ui,signing}.md`、Feature `idea.md/plan-p5.md/plan-p6.md` 等 23 份相关文档；CodeGraph 复核实际消费者、原生 TextKit 与共享文件树。只有 `todo.toml`、`evidence-p6.md` 和本阶段审计记录本地状态，无新产品提交。

## 发现项

- **未发现新的已证实且尚未修复的产品缺陷。** P5 所有旧实现清理与真实消费者验证已有本阶段交叉检查，P6 无额外生产代码改动。
- **首轮验证工具限制，不当作产品 Bug**：2026-10-16 Peekaboo 的隔离 App 后台 AX 返回 `incomplete accessibility read`，不能安全后台点击；当时未为测试抢占用户桌面。Instruments `xctrace --attach` 提示进程不存在，尽管 `ps` 能找到；原生弱引用、`vmmap`、`leaks` 和 RSS 仅为部分替代证据。10-17 获得用户限定扩展屏的前台授权后补测，且从系统日志定位了 Instruments 工具链故障，见下方补验。
- **截至 10-16 的未验收边界**：独立完整 App 菜单、IME／撤销／保存、前台滚动、GPU 合成和用户正式进程重启恢复当时均未测。10-17 已补验其中的真实前台菜单、中文输入、滚动、撤销／重做与磁盘保存；仍不能称完整功能 E2E、GPU 硬件分析或正式进程重启恢复全部通过。

## 修复日志

- P6 本身是验收阶段，无新的生产逻辑修复，也未将前阶段必要清理延期到此阶段。保留仍承担数据保护的保存、只读、容量、冲突索引与远端目标身份检查。
- 一次性生命周期测试最初在原生表面尚未挂载窗口时检查 `surface.window`，错误地失败 4 次；将测试同步点改为确实完成 NSWindow 挂载后，12 轮创建/关闭全绿、残留弱引用 0/0/0。仅修正实验测试方法，临时 XCTest 文件已移出正式测试目标。
- 重新构建后发现构建包与旧安装整包有差异，按开发规范同盘暂存、验证身份与签名、整包原子替换、再严格验签和逐文件比较；成功清理所有旧包/安装临时目录，不重启用户原进程。没有逐文件覆盖或建立第二 Bundle ID。

## 验证日志

- `make test`（`build/performance/diff/p5-final-full.log`）→ **315 tests，0 failures，3 SSH skipped**，不充作实机验收。
- `KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`（`build/performance/final/p6-windows-full.log`）→ **315 tests，0 failures，0 skipped**；真实 SSH 外部 Git 刷新、交互式 Rebase、Ref/ZIP/Stash/Clean/Ignore 三项均 `passed`，分别为 75.031/45.602/155.399 秒。另有独立临时 SSH Diff 五来源/CRLF/无效 revision 测试 **1/1 passed**，日志 `p6-real-ssh-diff.log`。
- `make build`、`make build:release`（P5 日志）及最终 `make test ONLY_TESTING=KeroTests/WorkspaceContentIdentityTests` **3/3**、再次 `make build` 均成功。Debug/Release 严格 codesign 验签；正式 `/Applications/Kero.app` 与最终 Debug 包 `diff -qr` 零差异，已安装，正式 Kero PID 42850 保持，**未重启**。
- 隔离真实 App 合成仓库的五次独立启动到实际 Diff AX 文本：中位 1770.693ms、最大 1795.291ms，包含 `open` 和 AX 检测开销；原生截图可见折叠、行号、语法颜色；另有文件编辑器截图和真实 AX 原文。P5 同机 30 次串并捕获与原生 TextKit A/B 保留在 `evidence-p5.md`，不能把不同样本耗时拼作整体性能提升。
- 30 次后台 1 秒采样：RSS 中位 270.16MiB、增量 +0.05MiB，CPU 中位 0.0%、最大 0.1%；`leaks` 0 bytes；12 轮 FileTab/DiffTab/DiffNativeSurface 原生挂载关闭，弱引用均释放，临时生命周期测试 1/1 passed。长期内存/前台唤醒和 Instruments Allocations 未得出结论。
- 相关 23 份文档、170 条本地 Markdown 相对文件链接核验无死链；生产代码和长期文档没有新增未提交改动；`git diff --check` 与 Feature `todo validate` 通过。全部详细日志、截图、单次源码在 `build/performance/final/`，本地证据在 `evidence-p6.md`。

## Gate（是否允许进入下一阶段）

- 结论：**Go — P6 验收资料核销通过，当前 Feature 无待执行阶段**。
- 理由：仍成立的 P6 验收目标有同机真实性能观测、315 项完整真实 SSH 绿测、隔离真实 App 的内容/窗口显示、原生资源释放证据、Debug/Release 和最终整包安装可复核；没有已证实未修复的生产缺陷。明确保留不能安全自动完成的前台 E2E 和独立工具不足，不以结果缺失夸大功能或宣称“所有场景均已穷尽”。

## 最终状态与剩余风险

- 当前状态：**Resolved（P6-T1/T2，Feature 所有已实施阶段完成）**。本次阶段审计不制造空提交；2026-10-17 用户另外授权整理文档、合并 `main` 和提交 PR，不属于 P6 性能测试。
- 剩余限制：2026-10-17 已在独立扩展屏补验菜单、IME/撤销/重做/失焦保存及 Diff 滚动；ScreenCaptureKit 仅证明窗口画面采集，不等同 GPU 合成耗时或硬件计数器。`xctrace` 在 macOS 27.2 与现有 Xcode 27.0 beta 上受 `DTServiceHub` 私有 entitlement 版本拒绝阻塞；多场景完整 E2E、正式用户进程重启恢复仍未验证。应在兼容工具链可用后补测，用户已要求暂停测试。

## 后续补验与剩余 Gate（2026-10-17）

- 用户允许仅在 Superconnect Display（显示 ID 6）使用隔离完整 App。已通过真实菜单切换、Split/Unified、Diff 滚动、中文拼音候选上屏、Undo/Redo 和失焦保存到磁盘；逐项真实 UI 与持久化证据见 `evidence-p6.md` 的追加验收节。正式用户 Kero 未重启。
- ScreenCaptureKit 精确隔离窗口采集完成动态 22 秒、1,187 次采样回调、0 采集错误。回调间隔 p95 35.71ms 并不能代表真实 GPU 合成性能，未做独立同场景前后 GPU 对照。
- `xctrace` 的根因已定位为**当前 macOS 27.2 拒绝 Xcode 27.0 beta 的 `DTServiceHub` 私有版本 entitlement**，不是遗漏 Kero 开发者权限；未做不安全签名绕过。用户要求暂停测试，兼容工具链下的 Instruments 与正式进程重启恢复均列为未测，不影响已证实的 P6 任务完成判断。
- 本次记录属于补充历史 Gate 的现场证据，不重新运行实现测试、不改变已完成的 task 状态、不宣称合并新 `main` 后测试仍绿。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

# Audit P1 - event-driven-workspace-refresh

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/event-driven-workspace-refresh/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 本机 Files 改为 FSEvents 目录刷新

## 任务到文件的映射

- P1-T1：`204e74a`；审计修复 `885d188`
  - 原生通知：`Bailey/Git/GitFileEventWatcher.swift`
  - 文件树／缓存／索引失效：`Bailey/Files/FileTreeModel.swift`
  - 可见面板生命周期、移除本机定时查询：`Bailey/UI/Panels/ToolPanelView.swift`
  - 回归：`BaileyTests/Files/FileTreeTests.swift`；既有 `ProjectFileIndexTests`、`GitStatusModelTests` 和 `PanelContextTests`
  - 长期文档：`docs/features/files.md`、`docs/features/git.md`、`docs/features/command-palette.md`、`docs/testing.md`

## 发现项

## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:463-477`
- 摘要：`MustScanSubDirs 缺少条目变更标志时跳过父目录，可能漏掉整目录重命名`
- 风险：`系统报告子树失同步而未附带 ItemRenamed 时，仅重查旧子树不能发现父目录下的新目录名，Files 和后续路径仍显示旧内容`
- 预期修复：`发生 MustScanSubDirs 时一并重新核验受影响子树的已缓存祖先；只排除无关的兄弟子目录，保留正常事件的局部刷新`
- 验证：`先以目录移动+MustScanSubDirs 模拟复现，再运行 FileTreeTests 和严格签名构建`
- 解决证据：`Red: /tmp/bailey-event-p1-audit-f01-red-20261025.log 目录移动后旧行未替换；Green: /tmp/bailey-event-p1-audit-f01-green-20261025.log 2/2；/tmp/bailey-event-p1-audit-all-tests-20261025.log 69/69；make build:dev / make build:ui 验签构建成功；commit 885d188`


F-01 已复现并修复；无其它已确认的代码缺陷。未能实测的完整 App 路径列在下方，不记为已经通过。

## 修复日志

- `204e74a`：复用原生 FSEvents，不新增 Files 轮询／Watcher 框架；按实际磁盘重新读取受影响目录。解决 `/var` 与 `/private/var` 路径映射、压缩目录与外部符号链接、根变化、旧目标回调、后台释放和 `⌘P` 深层索引失效。
- `885d188`（F-01）：`MustScanSubDirs` 不保证包含 `ItemRenamed`。先用实际移动目录 + 只有失同步标志复现旧行未更新，再恢复必要的父目录复查；保留无关兄弟目录无需重读的优化。
- 被替代的本机 Files 2 秒分支已删除；SSH Files 2 秒、SSH Git 5 秒及终端存活／cwd 探测未改变。Git 原有 `onChange` 使用目录级 FSEvents，Files 独立订阅文件事件，不把 Git 快照当目录真源。

## 验证日志

- 实测主机：macOS **27.2**（26B5101f），本机 APFS。`make test`：**616 项、8 项因外部环境跳过、0 失败、退出码 0**（日志 `/tmp/bailey-event-p1-full-host-20261025.log`；在审计补测前）。`make test:FileTreeTests,ProjectFileIndexTests` 审计后复验：**69 项、0 失败、退出码 0**（`/tmp/bailey-event-p1-audit-all-tests-20261025.log`）。此前 Git + PanelContext 相关定向 **119 项、1 项 SSH 跳过、0 失败**。最终 `make build:dev`、`make build:ui` 完整退出码 0（`/tmp/bailey-event-p1-audit-{dev-build,ui-build}-20261025.log`）；`make build` 也通过严格 codesign，但执行于审计修复之前。UI build-only 不等于 UI E2E。
- 真实本机磁盘与 FSEvents：根目录与展开目录创建／删除、跨目录移动、160 次突发创建、原子路径/缓存刷新、中文／空格／NFC-NFD／换行名称、符号链接项目根、展开及压缩目录的外部符号链接、移走／重建根后重新打开、监听关闭时不变和恢复时补验。**超过 10 秒静置根目录读取次数不增加**；突发事件的目录重读次数明显低于逐事件查询（断言小于 30 次），均使用真实临时目录与最终树行断言。
- 受控事件序列：`MustScanSubDirs` 树内目录及父目录／压缩链，`KernelDropped` 重扫所有已缓存目录，`RootChanged` 保留不可读根的有效旧行；旧项目事件不得覆盖新根，连接代次隔离沿用 `PanelSyncQueue`。`files.exclude` 隐藏目录、未展开深层目录的新增／删除和内容修改与 `⌘P` 索引代次分离；不为了搜索扫描整棵树。相同目录快照不重复发布树行和索引代次。
- **F-01**：Red `/tmp/bailey-event-p1-audit-f01-red-20261025.log` 证实目录移动后错误旧行；Green `/tmp/bailey-event-p1-audit-f01-green-20261025.log` 2/2；随后 69 项 FileTree／Index 全部通过，`885d188` 提交并严格签名构建通过。
- **明确延期／未测**：① 正式 App 的鼠标/菜单/AX 焦点与真实 Finder GUI 联动、后台／跨窗口切换由用户明确要求当前跳过 GUI 自动化；只有宿主与 UI 编译，不能算 UI 通过。② macOS 最低支持版 15.6 无真机，系统兼容性需后测。③ 非 APFS／网络卷和权限拒绝／卷卸载／高资源占用的实机异常未触发，需在可控独立环境验收。④ 同根 Files + Git 原生监听的长期 CPU／内存和真实 GUI 闪烁尚无定量长时测量，不能宣称已达到实际性能预算。⑤ Windows SSH 实机不属于本机 P1 的改造范围，保留其原定时刷新；全量 8 个跳过不能冒充远端完成。
- 文档一致性：`docs/features/files.md` 已限定本机 FSEvents／SSH 轮询边界，`docs/features/git.md` 保持 Git 独立刷新，`docs/features/command-palette.md` 说明深层路径索引失效，`docs/testing.md` 说明宿主与原生 GUI 的能力边界；计划中的老测试类名已换成当前存在的类。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（**仅允许继续独立的 P2 技术探索，不代表 P1 完整 GUI／多平台验收已通过**）
- 理由：本机实现、Red→Green、真实文件事件、全量宿主、最终定向与严格签名均完成；用户明确批准本轮跳过需要交互授权的 GUI E2E，尚未验证的环境不作为 P2 调查的依赖。上线前仍须单独补验这些项目。

## 最终状态与剩余风险

- 当前状态：`Resolved`（F-01；P1 的完整 App 验收仍延期）
- 剩余风险：真实 GUI/多窗口/中文界面、macOS 15.6、非 APFS 卷及异常资源条件、双 watcher 长时资源统计均未由本机证明。应用正式安装、替换、发布或对全部环境给出 Go 结论前必须补齐。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


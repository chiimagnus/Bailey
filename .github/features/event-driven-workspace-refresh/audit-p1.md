# Audit P1 - event-driven-workspace-refresh

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/event-driven-workspace-refresh/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 本机 Files 改为 FSEvents 目录刷新

## 任务到文件的映射

- P1-T1：原实现 `204e74a`；历史审计修复 `885d188`；本轮修复 `b8c6867`。独立比对后续 `2f5fac7`（SSH 单独事件链）、`bdbcafe`（⌘P 共享订阅）及当前真实消费者。
  - 原生通知：`Bailey/Git/GitFileEventWatcher.swift`
  - 文件树／缓存／索引失效：`Bailey/Files/FileTreeModel.swift`
  - 可见面板生命周期、移除本机定时查询：`Bailey/UI/Panels/ToolPanelView.swift`
  - 回归：`BaileyTests/Files/FileTreeTests.swift`；既有 `ProjectFileIndexTests`、`GitStatusModelTests` 和 `PanelContextTests`；隔离完整 App `WorkspaceLocalFileEventsUITests.swift`
  - 长期文档：`docs/features/files.md`、`docs/features/git.md`、`docs/features/command-palette.md`、`docs/testing.md`

## 发现项

## 发现 F-04

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:431`
- 摘要：`顶层符号链接根的父目录监听可能退化为全盘 FSEvents`
- 风险：`项目根为 macOS /tmp 等顶层符号链接时其父目录是 /，FSEvents.paths 的包含路径去重会把工作区物理根覆盖为 /，扩大为全盘递归监听，产生不合理 CPU/内存风险。`
- 预期修复：`仅给具备有界父目录的根符号链接订阅父目录；遇到文件系统 / 顶层别名禁止全盘订阅，保持既有目标本身事件及重新激活后的重读，并明确该特殊别名变更无实时通知保证。`
- 验证：`审查 GitFileEventWatcher.paths 的祖先路径去重及 FileTreeModel 根路径物理解析；受控目录下重定向和无关兄弟事件宿主回归，以及带有真实顶层别名的被动路径校验。`
- 解决证据：`commit b8c6867; native /tmp /var /etc top-level symlinks checked; testTopLevelRootSymlinksNeverWatchFilesystemRootRecursively PASS in /tmp/bailey-event-p1-posttidy-tests.log; bounded root parent watcher still passes retarget test. Top-level link itself retargets only reconciled on activation (no full-root FSEvents).`


## 发现 F-03

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:552`
- 摘要：`普通文件纯内容事件反复重列父目录，形成无效 IO`
- 风险：`FileEvents 对每次编辑产生 ItemModified，现有刷新代码不区分结构事件与纯内容事件，频繁写入时每批重列同一目录；这不是目录项变化，违反 Files 按需读盘和最少 IO 的 P1 目标。`
- 预期修复：`仅结构变更、目录自身事件或明确失同步刷新目录；普通文件纯内容事件不重列，Git ignore/index 与文件索引例外仍需通知。`
- 验证：`FileTreeTests 独立临时根写入现有文件内容、发送真实 ItemModified 标志，断言目录读取次数不变而新增/移除/原子替换仍更新磁盘行。`
- 解决证据：`commit b8c6867; Red /tmp/bailey-event-p1-independent-red.log parent list count 2 versus 1; Green /tmp/bailey-event-p1-posttidy-tests.log 5/5, Git ignore/index unaffected; full make test 646 executed 14 authorized environment skips no failure`


## 发现 F-02

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:407`
- 摘要：`根目录为外部符号链接时重定向链接不会触发 Files 刷新`
- 风险：`FSEvents 只监控解析后的物理目标，链接自身在父目录中被原子替换指向新目标时不触发旧目标事件，Files 继续展示旧目录；用户后续文件操作可能经原路径作用于新目标。`
- 预期修复：`复用既有 FSEvents 在链接根父目录接收重定向事件，按真实根与当前代次重扫、更新监听，过滤同级无关变化；不新增 watcher 框架或周期轮询。`
- 验证：`隔离 FileTreeTests 使用真实原生 FSEvents 原子重定向项目符号链接根，核对旧行消失/新行出现及监听释放，随后定向 build/test`
- 解决证据：`commit b8c6867; Red /tmp/bailey-event-p1-independent-green.log stable native link retarget failed; Green /tmp/bailey-event-p1-posttidy-tests.log 5/5 includes outside-parent retarget, watcher rebind, unrelated sibling no read and watcher release; host 102/102 executed with 1 SSH skip; signed Dev GUI PASS`


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


**独立复核结果：**历史 F-01 的必要代码与测试仍然有效；本轮在当前源码上独立复现 F-02、F-03，并查出 F-04 的全盘监听隐患。F-02 第一次在监听刚启动时意外通过，加入 1.2 秒静置后稳定复现 Red，证明不能将初始化遗留事件误判为监听覆盖。四项 Finding 现已全部核销，均有对应实际提交和测试。

## 修复日志

- `204e74a`：复用原生 FSEvents，不新增 Files 轮询／Watcher 框架；按实际磁盘重新读取受影响目录。解决 `/var` 与 `/private/var` 路径映射、压缩目录与外部符号链接、根变化、旧目标回调、后台释放和 `⌘P` 深层索引失效。
- `885d188`（F-01）：`MustScanSubDirs` 不保证包含 `ItemRenamed`。先用实际移动目录 + 只有失同步标志复现旧行未更新，再恢复必要的父目录复查；保留无关兄弟目录无需重读的优化。
- `b8c6867`（F-02/F-03/F-04）：项目根是符号链接且其父目录不是文件系统 `/` 时，复用**同一条** FSEvents 流观察链接 inode 重定向，实际重读并重新绑定新的物理目标；父目录无关兄弟文件不触发树重读。按结构／目录／链接标志读取父目录，纯普通文件内容修改不重列，Git ignore/index 仍走原有 ⌘P 索引失效。根级符号链接（`/tmp`、`/var`、`/etc`）绝不扩张为监听整个 `/`；链接自身改指向需重新激活／显示时核验。未新建第二套 watcher、轮询或持久后台服务。
- 被替代的本机 Files 2 秒分支已删除；SSH Files 2 秒回退、SSH Git 5 秒及终端存活／cwd 探测均是仍在使用的**独立**职责，未删除。Git 原有 `onChange` 回调由 `GitStatusModel` 消费、Files 另需 `onEvents` 文件标志与路径；代次、旧监听取消、根缓存可信保护均有真实消费者和竞态测试，不能视为废旧兼容或冗余围栏。

## 验证日志

- **本轮全量宿主：**`make test` → **646 项执行、632 passed、14 skipped、0 failed、exit 0**，`/tmp/bailey-event-p1-full-host-20261026.log`，xcresult `build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_02-05-43-+0800.xcresult`。运行于顶层别名限制的最后微调前，不能冒充微调后的全量重跑；微调后又通过下述 5 项受影响定向测试。14 项跳过有外部/SSH 环境门槛，不代表这些条件已通过。
- **最终微调验证：**`/tmp/bailey-event-p1-posttidy-tests.log`，5/5 PASS / exit 0；xcresult `build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_02-16-29-+0800.xcresult`。根链接重指向**不在链接父目录内**的另一物理根，随后在新目标建文件，真实事件仍更新；父目录无关兄弟变更不产生目录重读，隐藏后释放监听；`/tmp`／`/var`／`/etc` 顶层别名不会导致 FSEvents 全盘订阅；普通内容事件无重列、原子替换结构事件与 Git index 语义保持正确。
- **构建签名：**`make build:dev` → exit 0，`codesign --verify --deep --strict build/DerivedData-Dev/Build/Products/Debug/Bailey.app` → exit 0（`/tmp/bailey-event-p1-final-build.log`）。最后仅作常量复用与附加路径数组的等价整理后，又跑 5 项目标用例并由 `make test` 完成 App 编译签名；正式 Bailey App 未启动、替换或发布。
- **本轮 Red：**`/tmp/bailey-event-p1-independent-red.log`，纯文件 `ItemModified` 使已读根目录查询由 1 次升至 2 次；`/tmp/bailey-event-p1-independent-green.log`（F-02 修复前，故仍有一个失败）在启动事件静置 1.2 秒后真实原子覆盖项目根链接，旧目标保留超过测试等待时间，稳定复现缺少重定向监听。两条均是真实磁盘；F-03 使用注入的真实 SDK 事件标志。
- **本轮 Green／宿主：**`/tmp/bailey-event-p1-final-green.log`，4/4 通过；随后 `/tmp/bailey-event-p1-host.log`，`make test:FileTreeTests,PanelContextTests,ProjectFileIndexTests` **102 项、101 passed、1 skipped、0 failed、exit 0**，真实 xcresult：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_01-59-30-+0800.xcresult`。包含旧根失效、失同步、原生普通／链接目录变更、根链接改指向后**继续追踪新目标**、父目录无关兄弟操作不额外重读、隐藏时释放、原子文件→目录链接、⌘P Git 索引等条件；跳过的是 P3 提供的需指定授权 Windows SSH 夹具，并非本机 P1 失败。
- **本轮 Git 共用能力回归：**`make test:GitStatusModelTests` **49/49 通过，exit 0**；真实 xcresult：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_02-02-31-+0800.xcresult`。覆盖 Git 本机事件、后台暂停恢复、linked worktree 元数据、图谱缓存与新旧仓库身份，证明没有删除 Git 专用监听语义。
- **本轮完整 App：**`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceLocalFileEventsUITests/testRealLocalFilesRefreshAndCatchUpWhenPanelIsHidden` **1/1 通过，exit 0**；真实 xcresult：`build/DerivedData-Dev/Logs/Test/Test-Bailey-UI-2026.10.26_02-00-32-+0800.xcresult`。独立 Bailey Dev 从 Files 操作真实外部创建／重命名／删除，切 Git 后隐藏期间产生的新文件在重新进入 Files 时读取成功，核对磁盘字节；正式安装的 Bailey 未受影响。
- **历史基线（2026-10-25，不能代替本轮）：**实测 macOS **27.2**（26B5101f），本机 APFS。`make test`：**616 项、8 项因外部环境跳过、0 失败、退出码 0**（日志 `/tmp/bailey-event-p1-full-host-20261025.log`；在审计补测前）。`make test:FileTreeTests,ProjectFileIndexTests` 审计后复验：**69 项、0 失败、退出码 0**（`/tmp/bailey-event-p1-audit-all-tests-20261025.log`）。此前 Git + PanelContext 相关定向 **119 项、1 项 SSH 跳过、0 失败**。最终 `make build:dev`、`make build:ui` 完整退出码 0（`/tmp/bailey-event-p1-audit-{dev-build,ui-build}-20261025.log`）；`make build` 也通过严格 codesign，但执行于审计修复之前。UI build-only 不等于 UI E2E。
- 真实本机磁盘与 FSEvents：根目录与展开目录创建／删除、跨目录移动、160 次突发创建、原子路径/缓存刷新、中文／空格／NFC-NFD／换行名称、符号链接项目根、展开及压缩目录的外部符号链接、移走／重建根后重新打开、监听关闭时不变和恢复时补验。**超过 10 秒静置根目录读取次数不增加**；突发事件的目录重读次数明显低于逐事件查询（断言小于 30 次），均使用真实临时目录与最终树行断言。
- 受控事件序列：`MustScanSubDirs` 树内目录及父目录／压缩链，`KernelDropped` 重扫所有已缓存目录，`RootChanged` 保留不可读根的有效旧行；旧项目事件不得覆盖新根，连接代次隔离沿用 `PanelSyncQueue`。`files.exclude` 隐藏目录、未展开深层目录的新增／删除和内容修改与 `⌘P` 索引代次分离；不为了搜索扫描整棵树。相同目录快照不重复发布树行和索引代次。
- **F-01**：Red `/tmp/bailey-event-p1-audit-f01-red-20261025.log` 证实目录移动后错误旧行；Green `/tmp/bailey-event-p1-audit-f01-green-20261025.log` 2/2；随后 69 项 FileTree／Index 全部通过，`885d188` 提交并严格签名构建通过。
- **明确未测边界**：① 本轮只独立通过 Files 的本机真实 GUI 事件用户路径；Finder 系统拖放、后台多窗口、原生辅助功能完整矩阵属于其他联动阶段，不推断全通过。② macOS 15.6 真机没有可用环境，不能以 27.2 代替。③ 非 APFS／网络卷、卷卸载、权限拒绝和高资源负载实机异常未独立执行。④ Files/Git 双原生监听的长期 CPU／内存及闪烁未作定量长时验收。⑤ **顶层别名本身的重定向不提供实时保证**，以 App 再激活／显示重读替代监听整个 `/`。⑥ Windows SSH 属独立 P2，仍保留定时回退；14 个环境跳过不冒充远端验证。
- 文档一致性：`docs/features/files.md` 已限定本机 FSEvents／SSH 轮询边界，`docs/features/git.md` 保持 Git 独立刷新，`docs/features/command-palette.md` 说明深层路径索引失效，`docs/testing.md` 说明宿主与原生 GUI 的能力边界；计划中的老测试类名已换成当前存在的类。

## Gate（是否允许进入下一阶段）

- **P1-T1 当前 macOS 27.2／本机 APFS／普通项目根：`Go`。**原子提交已在真实生产代码消费链中使用；F-01～F-04 `Resolved`，Red→Green、102 项范围宿主、49 项 Git 状态、646 项全仓宿主、1 项真实 GUI、最终 5 项顶层边界与构建签名均有独立退出证据。
- **P1 跨全部环境／直接发布 Gate：`No-Go`。**缺 macOS 15.6、非 APFS/网络卷、后台多窗口/极端资源及长期监听资源数据；顶层别名链接自身不能保证即时感知。已通过环境不能替代未测条件。P2 独立探索不被这些缺口阻塞。

## 最终状态与剩余风险

- 当前状态：**F-01～F-04 全部 `Resolved`**，本轮修复独立提交 `b8c6867`（5 文件，包含真实 App 与宿主回归及功能文档）。`todo.toml` 原始任务提交 `204e74a` 保留以便逐 commit 追溯；审计结果记录在本文件。
- 剩余风险：顶层符号链接自身重定向仅在 App 激活／再次显示时核验；macOS 15.6、非 APFS／网络卷与极端权限／负载、完整多窗和 Finder GUI、双监听长时资源均未实测。**正式安装、替换、发布或宣称全环境通过前需额外验收**。本轮未碰正式 App，未修改其他 P 或他人并发工作。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


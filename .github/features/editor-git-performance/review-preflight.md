# 执行前独立复核（2026-10-16）

## 范围与证据边界

基线：`8ccd4d51acc21498425dce789de6e4d8c58010f6`，开始时工作树干净。本轮不读取已有 `audit*.md` 或 `review.md`，不继承其中的结论；只修订需求、实施计划与任务说明，不实施性能改动。

先同步 CodeGraph，再沿真实入口核对源码、依赖、文档和测试。这里的覆盖指本 Feature 的完整执行链，不表示逐行审计了无关终端、浏览器、隧道或第三方全部源码。源码能证明的缺口与需要运行才能判定的性能问题分开记录。

| 链路 | 核对的生产实现与消费者 | 核对的验证入口 |
| --- | --- | --- |
| 文件打开／恢复／追加／保存 | `Project.openFile/makeContent/ignoreGitPaths` → `FileTab` → `WorkspaceBackend`、`LocalWorkspaceBackend`、`SSHWorkspaceBackend` → `SourceTextEditor`；`Project` 的 Git 保存／重载和关闭保护 | `FileTabTests`、`WorkspaceIdentityTests`；原生保留、工作区关闭相关测试入口 |
| 根高亮／嵌入语言／坐标 | `SyntaxHighlighting`、`SyntaxHighlightPlugin`；锁定 Neon 的 `TreeSitterClient`、`Highlighter`、`TokenApplication`、`TreeSitter+Extensions`；SwiftTreeSitter 的 Parser、InputEdit、Point、Tree；STTextKitPlus 的位置转换；Vendor STTextView 的字体事务、修改事件和 AX 文本写入 | 当前没有独立 `editor-highlighting` 检查；应在现有 XCTest 目标补 `NativeUI/Editor/SyntaxHighlightingTests.swift`，而非复建旧 runner |
| Git 刷新与动作 | `ContentView.syncGit`、`ToolPanelView` → `GitStatusModel.sync/refresh/runGitStatus/applyRepository/loadMoreCommits/perform` → `GitCommandExecution`、远端批协议；`GitPanel`、`RecentCommitsView`、`BottomToolbarView` 的字段消费者和动作资格 | `GitStatusModelTests` 的临时失败／换通道／分页回归，`GitWorkspaceActionTests` 的同路径双分组回归，`GitExternalRefreshTests` 的前台／隐藏／后台刷新 |
| Files 和 Git 树 | `Project.syncFiles`、`PanelContext` → `FileTreeModel` → local/SSH list → `TreeDisplayModel.Traversal/pathRows`；`GitStatusModel.fileDecoration`、Git 分组行与共享行消费者 | `FileTreeTests`、`TreeRowHitTestingTests`、`PanelContextTests` |
| 原生 Diff | `Project.openDiff/openHistoricalDiff`、恢复及 Dock 挂载 → `DiffTab.reload/recomputeDisplay/refreshEditDecorations/expandRun/save` → `GitHistoricalFileLocator`、共享后端／Git 执行器 → `DiffEngine`、`DiffSyntaxHighlighter` → `DiffNativeSurface`、`DiffTextView` 的文档、装饰、滚动与原生写入 | `DiffTabTests`、`GitHistoryFileTests`；现有 CRLF 检查只断言存在增删及双栏等高，不能证明逐行切分正确 |
| 连接与目标 | `SSHHostWorkspaces`、`RemoteConnection.run/check`、`SSHWorkspaceBackend` → `Project.connectedWorkspace/rebindRemoteTabs` → 文件／Diff 只读及代次 | `RemoteLifetimeTests`、`WorkspaceIdentityTests`、现有 file/diff 换连接保存测试；真实 SSH 仍须专用获准主机 |
| 构建与规范 | 根 AGENTS、docs 索引、architecture/standards/testing/development/ui、editor/diff/git/files/ssh 功能页、贡献与安全；Makefile、工程、scheme、Package.resolved | 一个 Swift 6 XCTest 目标；Debug／Release；只用 `make test`／`make build` |

## 必须修订的计划问题

### 1. 失效技术栈和验证入口（高）

P5 仍安排 Pierre 副本、JS 身份 hash、WebView 编码与 worker；全计划仍安排已删除的 `scripts/check.sh`、`check-*.swift` 和 Swift 5 独立编译。当前工程只用原生 Diff，且已有 XCTest。顶部“旧方案”警告不能让下面的待办安全可执行。

处理：直接替换这些实施步骤、文件与验收命令；不重新安装依赖，不迁移不存在的脚本，不给已删除引擎做正确性补丁。

### 2. 错把跨分组重复路径当作多余防护（高）

P4-T3 要把 `applyRepository` 的字典改为唯一键构造，但 `parseStatus.addEntry` 当前按 `path + tracked/untracked` 去重，不是全局路径唯一。`git rm --cached` 保留工作文件时会产生 `D.` 和 `?` 两条同路径记录。真实临时 Git 核验得到两条 `retained.txt`；仓库已存在 `testIndexDeletionAndSamePathUntrackedRemainSeparateGitRows`。

处理：不删除模型层的跨分组聚合语义，不能改成会 trap 的构造。装饰只产出一个确定值，两个业务行仍独立；不借性能任务改变现有优先结果。GitPanel 已分组之后的映射可依分组内唯一性精简，但不是必做性能措施。通用 pathRows 的去重也不类推删除。

### 3. 懒加载遗漏非视图消费者（高）

P2-T1 规定只有 onAppear 发起初读，却未修改 `waitForText`。`Project.ignoreGitPaths` 调 `openFile` 后立即等待：SwiftUI 尚未挂载时，没有 reloadTask，原 waitForText 会直接失败。旧计划只迁移两份旧检查，也会漏掉当前 FileTab、关闭、身份等测试的同步初始化假设。

处理：统一按需入口同时服务视图和等待消费者；未显示、无人消费的恢复标签才保持懒加载。保留“任务被挂载／激活替换后等待最新读取”的现有契约；同 task 迁移全部实际受影响 XCTest，不留同步兼容入口。

### 4. 首次解析与编辑桥接仍有真实缺口（高）

当前首次通知把 `[0,N)` 当旧范围又传 delta=N，Neon 会请求 2N；transformer 把 TextKit 段落／UTF-16 列直接当 Tree-sitter 的 LF 行／字节列。修改后又重算旧 NSTextRange，且没调用 Highlighter.didChangeContent。两次 root/injection 回调可跨编辑版本，第二次失败仍提交第一次的 tokens。

处理：保留直接契约修复；先 Red，再 Green。只用一个 coordinator 编辑版本保护整次交付，不复制 Neon 的根解析队列、pending edits 或版本管理。坐标性能实验必须对照修正后的实现，不能继续把已删除 position 调用当热点。

### 5. 固定主机断线和原生只读未闭环（高）

`SSHHostWorkspaces.setConnected` 只写静态字典；固定主机的 connectedWorkspace 无条件返回 backend，项目重绑没有该状态来源。SourceTextEditor.apply 未设置 isEditable。另一个需要一起核验的真实底层边界：Vendor STTextView 的 setAccessibilityValue 直接设置 text，没有 isEditable 判断；原生 Diff 子类已经为此提供了两处保护，普通编辑器没有。

处理：接入现有 Project 的重绑和原生只读，不新增连接管理者、探测循环或永久离线锁。若在 Vendor 原生写入所有者修共同 AX 边界，同 task 删除 DiffTextView 被替代的重复保护并登记补丁；测试可选取／复制但不可经 AX 替换。未知初连与显式重试仍能实际读取，断线不得阻断重连。

### 6. 查询缓存漏了 Diff 这个真实消费者（中）

当前 HighlightQueryCache 同时被编辑器和 DiffSyntaxHighlighter.context 使用。原 P3-T5 只治理 root／embedded，会保留另一条并发冷编译路径。embedded 失败仍 invalidate，固定坏资源会反复编译。

处理：失败闭环必修；在途共享只在多标签 trace 证明值得时做，但一旦做，就同时接入编辑器根、嵌入语言和 Diff，删除各自重复 compile/pending。不预定新文件、protocol、TTL、资源自动恢复或预编译全语言。

### 7. Git 计划重复修复已落地行为，且遗漏周期触发（中）

同 root/scope 换 backend 时，sync 现已增加 contextGeneration 并失效旧 worker；失败保留快照也已有测试。当前可见 Git 面板前台每 2 秒、本机以外每 5 秒周期刷新，不能按旧文当作只有事件驱动，更不能为详情复用删除轮询。

处理：这些是必须保留的行为，不再列成尚缺实现。known mutation 可以提出 core/totals 更新；周期／激活／未知命令／手动刷新仍做保守 full，避免只凭 HEAD 不变永远看不到外部 refs/stash/config 变化。Observation 不继续按 @Published 去重套路增加赋值围栏。

### 8. 原生 Diff 读取保护已有部分修复，loading 仍有缺口（高）

gitContent 已区分部分失败并检查 size、原字节和 UTF-8；reload 也已有 editing/dirty 检查，不能再次宣称它把“所有错误当缺失”。但是 updateEditedContent 在 dirty 时增加 reloadGeneration，旧读取随后在清 isLoading 前退出；现有在途测试不检查这个 loading，回原文后 refreshWhenSelected 仍可能被卡住。没有编辑的进入 edit 路径则已有完成清 loading 的测试，不应一概写成全坏。

处理：用当前 DiffTabTests 的受控读取补“输入→旧读取完成→撤销／保存→复选仍可刷新”检查，修拥有者的任务收尾。Git missing 继续依赖 stderr 片段、size/blob 分别解析可变 spec 的边界在同 task 用结构化 metadata/OID 收敛；正常 unborn、删除和冲突 stage 选择不是兼容层，不删除。

### 9. 新原生 Diff 的 CRLF 分行错误未列入计划（高）

DiffLineSplitter.lines 逐 Swift Character 比较 `== "\n"`。Swift 把 CRLF 作为一个 Character，该比较不会命中；本轮语言契约核验 `"a\r\nb\r\n"` 的 Character LF 为 0、scalar LF 为 2。于是多个 CRLF 物理行可能被当作一个 DiffSourceLine，源范围、行号、行内强调和编辑 ghosts 都受影响。现有检查仅要求行数左右相等和有中文／增删，不足以捕获。

处理：P5 对共享 splitter 先补精确 LF／CRLF／混合换行／尾换行／Unicode 回归，再用 UTF-16 code unit 或 Unicode scalar 的 LF 遍历修复；不规范化原字节，不另留 Character 算法兼容分支。同步验证 review 和 edit decorations。

### 10. 原生 Diff 的真实热点应替换旧 JS 设计（中）

recomputeDisplay 已把 line diff、两侧 captures 与 DiffComputation.build 放 detached；expandRun 已复用 DiffCore/runs。仍值得测量的是：先等待 query 才开始 core；统一／左右／edit 多份派生计算；MainActor 三份 attributedDocument；appearance 变化重走完整 parse/diff；120ms edit debounce 后仍可积压未合作取消的 detached 计算；edit 几何从文首计段落。它们是候选，不是已测瓶颈或必须全改的设计。

处理：只选 trace 主导的一项；优先复用当前 inputs／版本与稳定快照。不得删除滚动重入、内容高度、空范围、实际范围裁切或保存身份保护来换数字。当前 review 高亮另有每侧 1,500,000 字节策略，5 MiB 是文本显示上限；不能把接近上限的 plain diff 误判为高亮已完成，也不在本 Feature 擅自扩大能力。

## 补核：共享边界的真实遗漏

- **远端未跟踪统计分帧（中）：** RemoteCommands.untrackedLineCountsCommand 输入用 NUL，但输出把未经编码的 path 插入换行记录；parseUntrackedLineCounts 按换行拆。文件名若含换行和形如数值字段的片段，可被当成额外行数记录。唯一生产消费者只把 lines 求和，不使用 path。P4-T1 应优先删无消费者的输出路径，保留最小数值帧／预算校验，而不是保留旧输出或增加通用协议。已有测试只用普通路径，需在同一 XCTest 补特殊路径和帧错误。
- **原生 Diff 旧派生快照重新获胜（高）：** reload 更新 oldContent/newContent 后 recomputeDisplay 保留旧 displayInputs；新的 B 计算在途时，旧 A fold 可进入 expandRun，取旧 core 并增加 displayGeneration，从而取消 B 后发布 A。仅检查最终回调 generation 不够，因为旧输入被创建成了新任务。P5-T3 在加载／派生身份拥有者失效旧 inputs，并验证“显示 A→加载 B→B 计算中展开旧 fold→最后显示 B”；不把已可达正确性缺口推给条件性能 task，不添加第二套 generation。
- **文本规范等价不等于字节相同（高）：** SourceTextEditor 的回写比较、FileTab 的 dirty/matches、DiffTab 的 hasChanges／dirty／内容更新和 DiffEngine 的行／token 比较均使用 String／Substring ==。本轮 Swift 核验 `é` 与 `e` + U+0301 相等且 hash 相同，但 UTF-8 不同、UTF-16 长度为 1／2。字节变更可因此跳过回写／保存或不显示 Diff，不能把这种“省工作”当性能收益。P3-T2 在所有相关文本拥有者使用标准库字节精确比较、删除重复前置比较并用真实保存／reload／Diff 回归闭环；保留 hash 后精确确认，不做全仓路径／Ref 比较替换，不增加归一化或缓存层。P5-T2 继续复用同一 DiffEngineTests。

## 收敛与清理决定

关键定位（均为本轮未修改的生产源码）：Git 双分组与去重 `kero/Git/GitStatusModel.swift:3054`；非视图读取 `kero/Editor/FileViewerView.swift:120`、`kero/Workspace/Project.swift:484`；高亮初始化／事件 `kero/Editor/SyntaxHighlightPlugin.swift:151`、`kero/Editor/SyntaxHighlightPlugin.swift:50`；Query 消费者 `kero/Git/DiffSyntaxHighlighter.swift:45`；固定主机状态 `kero/Remote/SSHHostWorkspaces.swift:52`、`kero/Workspace/Project.swift:404`；AX 写入 `Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Accessibility.swift:139`；统计分帧 `kero/Remote/RemoteCommands.swift:291`；CRLF `kero/Git/DiffEngine.swift:30`；旧派生输入 `kero/Git/DiffViewerView.swift:443`、`kero/Git/DiffViewerView.swift:513`；字节判等 `kero/Editor/FileViewerView.swift:211`、`kero/Git/DiffEngine.swift:120`。

- 删除旧栈、旧 runner、独立脚本测试、JS hash 补丁和其所有待办引用，而不是保留“将来重新核对”。
- 不预建 Rope、LanguageLayer fork、行索引、后台子树引擎、共享编译器服务、诊断框架或 Git fingerprint；条件措施先以一个最小实验回答是否需要。
- P1 样本与证据默认留本地；不为准备样本强制增加永久生成器。只对选中的可比路径按测试规范统计，不做全部语言／容量／布局／SSH 的笛卡尔积。
- P6 只综合复测与核销文档，不承接任何前面任务的旧代码删除、必要测试或文档同步；无新事实不制造最终文档提交。
- TDD 区分真实缺陷／新行为与纯性能替代：前者先 Red，后者先保留绿色行为基线并做等价与测量，不机械要求本来正确的 undo／字体断言先失败。
- 安装、备份清理和重启不在计划中另立规则，直接遵循 development.md：实现验收后默认整包安装、失败恢复、不留旧备份、不重启；本轮纯计划不安装。

## 本轮实际核验

- `rtk codegraph sync`：索引已是最新；explore/node 后按真实源码补读。
- 原生 Swift 一次性语言核验：CRLF 的 Character LF=0，scalar LF=2；不是 App 测试或性能结果。
- 原生 Swift 规范等价核验：String equal=true、UTF8 equal=false、UTF16 lengths=1/2、hash equal=true；只证明语言契约，不冒充真实编辑／保存回归已运行。
- Python TemporaryDirectory 内真实 Git `init/add/commit/rm --cached/status --porcelain=v2 -z`：确认同路径两条记录；不改用户仓库／global config，不连接远端，临时目录随上下文清理。首次含 `rm -rf` trap 的 shell 请求被环境拒绝，未执行；随后使用标准临时目录生命周期，没有改审批或绕过清理限制。
- 核对四篇 Zed 一手文章，保留增量／快照／真实 profiling 的方法依据，不据此断言 Kero 存在相同进程风暴或性能收益。
- 计划结构、task 锚点、实际文件／测试类、相对链接和旧入口残留检查以本轮最终工具输出为准。
- `feature_tool.py todo validate` 通过；22 个 task 的锚点、当前顺序、pending／空 commit 保持一致。8 份当前 Markdown（需求、6 个 phase、此记录）的本地链接／标题核对通过；现行正文无旧 runner、Swift 5 独立编译或 Pierre 包接入步骤。历史 review/audit 未纳入检查或替换。`git diff HEAD --check`／索引差异检查通过；没有把仅检查空的未暂存 diff 当成全部差异验收。

本轮没有运行 XCTest、构建、Instruments、App UI 或真实 SSH；没有删除生产代码，没有安装或重启 Kero。源代码缺口仍待对应任务 Red／Green 与真实用户路径验证；计划修订不是这些功能已修复的证据。已有历史 review/audit 原样保留，不作当前执行依据。

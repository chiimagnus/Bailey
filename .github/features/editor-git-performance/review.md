# Git / 编辑器优化：执行前源码审查

## 结论与边界

2026-10-12 对照 `6ded14307c2e28c2d8915ff2d41f71518ad620a3` 重新审查。旧计划不能直接执行：既有实现、入口、验证命令和应用替换规则已变化，而且把若干正确性缺口藏在条件性能任务之后。

本轮更新 `idea.md`、六份阶段计划和 `todo.toml`，未修改生产代码、依赖或正式应用，未读取任何 `audit*.md`。本文是执行前证据，不是阶段实现审计或发布通过证明。源码缺口仍须按修订任务修复；本轮没有耗时基线、真实 SSH 或 App 交互验收。

先做 P1-T1 → **P1-T3 首次解析/坐标修复** → P1-T2 可运行基线，再按 P2–P5 的真实依赖实现。已有 task ID 保留，新增前置 task 由 feature 工具登记；不能把“文档修订完成”写成任务 completed。性能候选没有热点时可以不实现，明确的正确性修复不能因此跳过。

## 阅读与追踪范围

先核对全仓 Swift 文件清单、CodeGraph 与功能文档，再逐段读取下列执行链。核心文件按完整实现审查，窗口/终端/浏览器等外围按实际接入与副作用路径阅读；不声称所有无关功能或第三方生成资源已完成逐行质量审计。

| 路径 | 核对的实现与最终效果 |
| --- | --- |
| 文件加载、重载、保存 | `FileViewerView.swift` / `FileTab` 全部实现；Project 的 openFile/openFileToSide/makeContent、路径重命名、断线 rebind；到 backend.write 的磁盘副作用与保存基线 |
| 原生编辑与查找 | `SourceTextEditor.swift`、`EditorFind.swift` 完整实现；字体/文本装入、委托、输入回写、原生 find、光标/滚动恢复与视图销毁 |
| 高亮 | `SyntaxHighlightPlugin.swift`、`SyntaxHighlighting.swift` 完整实现；root query、injection query、fragment parse、谓词、缓存、颜色应用与弱引用 |
| 本地后端与 Git 执行 | `WorkspaceBackend.swift`、`LocalWorkspaceBackend.swift`、`GitCommandExecution.swift` 完整实现；文件描述符/限额、登录 shell 环境、argv、双流排空、超时与实际 Git 输出 |
| Git 状态与写操作 | `GitStatusModel.swift` 全部实现；状态/缓存/分页/互斥、HEAD/upstream 校验、discard/trash 后续动作、草稿清理、refs/log/index 副作用 |
| Git 消费者 | `GitPanel.swift`、`RecentCommitsView.swift`、`BottomToolbarView.swift` 完整实现；amend/菜单/行数/历史、确认期间的文件指纹和目标、四类树行 |
| Files 与共享树 | `FileTreeModel.swift`、`FileTreePanel.swift`、`TreeDisplayModel.swift`、`TreeRowStyle.swift` 完整实现；压缩、懒加载、排序、命中、忽略与目录优先级、外部变化和 symlink 边界 |
| 挂载与刷新入口 | `ContentView.swift`、`WorkspaceDockView.swift`、`ToolPanelView.swift`；PaneLayoutView 的原生内容挂载/拖动、Panes 的内容保存/dirty 观察、TerminalManager 的打开/保存/快照与恢复 |
| SSH | `PanelContext.swift`、`SSHWorkspaceBackend.swift`、`RemoteCommands.swift`、`RemoteConnection.swift`、`SSHHostWorkspaces.swift`；interactive master 与固定主机两条 runner、batch/stdin/read/write、状态归属与重连 |
| diff App 路径 | `DiffViewerView.swift` 完整实现、Project.openDiff/openCommitDiff；两侧读取、真实缺失/失败、编辑回调、保存、长生命周期 host 与重挂载 |
| 锁定高亮依赖 | Neon Highlighter/TokenApplication/TextSystemInterface/TreeSitterClient/输入编辑；SwiftTreeSitter Parser/Point/Tree 与 Layer 公开接入、snapshot、resolveSublayers；STTextKitPlus position；STTextView 字体/属性、replaceCharacters、delegate proxy、plugin setup；tree-sitter lexer 的换行/字节规则 |
| 锁定 diff 依赖 | PierreMultiDiffView、DiffWebViewCoordinator、PierreMultiDiffInput、完整 diff-entry.js/worker-entry.js/bundle.js、Package.swift、包检查入口、锁定 npm 配置及上游维护说明 |
| 验证与构建 | `scripts/check.sh`、相关独立检查、App dylib 检查/启动方式；工程 actor/concurrency/Debug 设置、Package.resolved；README、功能维护文档和 AGENTS 的授权/验收边界 |

这张表记录本次取证边界，不是要求实施时穷举无关源码；每项改动仍须读当时工作树并验证最终效果。审查期间 Git 环境工作由另一条工作流提交为 `6ded143`，未被本轮 stage、回滚或改写。

## 必须修正的计划缺口

“实测”仅指下文说明的检查或纯函数核验；源码能证明的路径不冒充 UI 复现。

| 优先级 | 当前证据与影响 | 计划中的处理 |
| --- | --- | --- |
| 高 | 首次 root parse 将 `[0,N)` 当旧范围再加 delta=N；真实 Neon 请求终点 2N，已超出当前文档。错误的 `.zero` 回退不能提供正确 Point | 新增 [P1-T3](plan-p1.md#p1-t3)，先修正确性，再取可运行基线；删除错误初次通知 |
| 高 | UTF-16 parser 的 Point.column 是字节；Kero 直接传 TextKit UTF-16 offset。段落行号也不等于只按 LF 分行的 Tree-sitter row | P1-T3 修单位与行定义；[P3-T3](plan-p3.md#p3-t3) 只测正确算法的扫描成本，不把修复等到索引准入 |
| 高 | STTextView 在 will/did 传同一个旧 NSTextRange；Kero 在已修改文档里重新换算它。且没有调用 Highlighter.didChangeContent，validSet/pendingSet 没有正常移位 | [P3-T1](plan-p3.md#p3-t1) 捕获旧 NSRange、补 Neon 通知；覆盖尾删、全删和 pending 编辑的实际生产桥接 |
| 高 | base query 与 injection query 分别合法不代表同版；injection stale 时代码仍交付旧 base。Neon 的旧 failure 回调还可能清新请求同范围 pending | P3-T1 在整次 provider 交付边界使用一个 edit revision；P3-T7 复用，不叠版本，不以 noChange 掩盖旧结果 |
| 高 | injectedHighlightsQuery 编译失败仍 remove pending + invalidate，下一次又编译同一固定坏查询；闭环没有终点 | [P3-T5](plan-p3.md#p3-t5) 必修固定资源失败结果；共享在途仍条件准入，不自动 retry/TTL |
| 高 | DiffTab.gitContent 把任何非零退出当 missing，坏 size 默认为 0；启动、传输、坏仓库也可能显示空内容或继续 fallback | [P5-T2](plan-p5.md#p5-t2) 从成功的 index/tree 元数据判缺失，按对象 ID 读 blob；删除旧 spec 失败吞并，不删除真实冲突选择 |
| 高 | DiffTab.reload 只有启动时检查 edit/dirty；结果晚到只验 generation/readOnly。进入 edit 但尚未 dirty 可被覆盖，dirty 后旧任务又可能留下 isLoading | P5-T2 同 task 处理编辑/保存失效与 loading 归属，实际验证 WebView 内容、undo 和磁盘，不能只看 early return |
| 高 | 生产 JS 函数对 `fixture.txt`、空 before、review 的 ` a` 与 `!@` 给出相同 itemVersion=1381271817，内容高亮键也相同。依赖将相同 version 当“不更新记录” | [P5-T4](plan-p5.md#p5-t4) 内容身份必修；明确相等 + 单调版本，删除旧 hash/key，无磁盘兼容迁移。纯函数碰撞已测，真实 CodeView 页面结果仍须实施时验收 |
| 高 | 首次加载懒化后，workspace-identity/pane-retention 仍按同步 init 立即编辑；content=.loading 会使 dirty/save 不成立，也有远端直接构造后等待自启的用法 | [P2-T1](plan-p2.md#p2-t1) 同 task 迁移既有检查到显式加载/等待文本，不保留同步兼容入口迁就旧测试 |
| 高 | FileViewer 有只读横幅，SourceTextEditor 没设置原生 isEditable。固定 sshHost 的 connectedWorkspace 又无条件返回缓存 backend，状态未驱动 Project rebind | P2-T1 沿两类 SSH 来源完成真正只读/重连链；未知首次状态不能禁止连接，断线失败不能清掉内容；不另建连接管理框架 |
| 高 | 旧计划要求退出/替换/重启正式 App，并在 P6 删除安装备份，与当前 AGENTS 授权及保护用户命令的规则冲突 | 全阶段改为同签名隔离实例；正式包替换另需授权，用户手动重启/确认恢复，备份不擅删 |
| 中 | 当前 StatusResult 没有 loadedDetails；applyRepository 全量写空值会清详情。canAmend 却依赖 recentCommits，toolbar 行数缺 readiness | [P4-T1](plan-p4.md#p4-t1) 明确 core/details 结果与最小就绪语义；amend 用核心 hasHead，详情失败不擦核心，缓存不把未加载当空成功 |
| 中 | worker deadline 未覆盖 untracked/operation 等调用；RemoteConnection master check 另用 5 秒。外层 watchdog 只拒绝晚结果，不代表实际工作已停止 | P4-T1 沿真实 runner 传剩余预算；分阶段后 watchdog 不清成功核心，计数/SSH 检查看实际工作而非 spinner |
| 中 | textLineCount 仅读前 stat size 后读到 EOF；远端 wc/tail 也在 stat 后无界读。文件增长会绕过现行统计预算 | P4-T1 替换计数路径时同时删除无界循环，覆盖 per-file/总字节预算与实际读量，不把预算当纸面常量 |
| 中 | 同 root/scope 换连接时 GitStatusModel.sync 替换 backend，却未必使旧 worker 的 generation 失效 | P4-T1 用已有 PanelContext 目标/请求代次链验证并修复，不能凭“机器相同”接收旧连接结果，也不比较每次新建的 backend wrapper 地址冒充稳定连接身份 |
| 中 | Project 的已有 diff tab 分支仍直接 reload，历史“选回”已免读不等于“再次点 Git 行”免读 | P5-T1 区分入口计数；P5-T2 在相应入口删除重复读取，live 元数据变化保留必要刷新 |
| 中 | Swift cleanup 未清 pendingOperations，也没调用 JS cleanup；error 只写 DiffLogger。原计划把已有 JS 能力当成 App 已执行/已有用户恢复 | P5 修正事实；改异步时同 task 清自己的输入/任务并提供可见失败。未取得关闭 trace 不断言泄漏，也不自动增加 worker 恢复框架 |
| 中 | 新脚本的旧命令漏 LocalWorkspaceBackend/GitCommandExecution，TreeDisplayModel 路径已移；独立类型壳已无必要 | 复用 check.sh 的真实输入，扩展 git-panel-state / workspace-identity；新检查同 task 注册，依赖模块用 GeneratedModuleMaps |

## 当场收敛的过度设计与清理归属

下列是计划删改决定，**不代表生产代码已经删除**。每一项替代接入和删除都属于同一任务，不在 P6 才处理。

| 删除 / 简化 | 对应任务与保留边界 |
| --- | --- |
| delete：本地同步 init + 远端 init 自启的双轨、readImmediately、无消费者说明 | P2-T1；仍有同步项目根消费者的 stat/gitRoot helpers 不删 |
| shrink：FileTab 发布处重复 path/cancellation 比较 | P2-T1；所有 path/cancel 都先改变 reloadGeneration，保留代次 + dirty/readOnly 和任务句柄归属检查 |
| delete：高亮无效 `.font` 写入及“未来其他 token 属性”分支 | P2-T2；保留纯颜色、metadata 过滤、零范围与弱视图引用 |
| delete：textViewDidChangeText 的重复旧全文比较 | P3-T2；保存基线准确比较仍保留，撤销回原文不能永远 dirty |
| delete：已共享编译后每 coordinator 的 pending/重复闭包 | P3-T5 准入共享的同 task；没准入不先搭 cache service |
| delete：每次片段 new Parser/full parse 的旧路径 | P3-T7，只有现有 Parser/Tree 原型通过才替代；不双跑，不留备用旧算法 |
| delete：Layer 双原型与默认接入产品的预设 | P3-T6/P3-T7；锁定 Layer 没有 root-tree 接入，resolve 也未删除消失的范围，不为实验建第二份 root parse/fork |
| delete：SSH batch miss/失败后逐命令重取的备用路径 | P4-T1；传输/坏帧成为明确阶段失败，正常 non-repo/unborn 仍正确处理 |
| shrink：模型/UI 对已被 parseStatus 去重的 entries 再做 first-wins 备用字典 | P4-T3；保留 porcelain 真正会重复的 producer 去重、通用 pathRows 和历史输入契约 |
| delete：refs/config fingerprint 全套探测的预设 | P4-T2；先 known worktree/index 复用、unknown full，保留最后事件合并与操作互斥 |
| delete：cat-file batch 新协议、Git 版本能力探测、旧算法双轨 | P5-T2；先结构化 metadata 的正确性、有限读取/复用，残余热点有证据才重开设计 |
| delete：旧 DiffTab spec reader 与“失败是缺失”恢复 | P5-T2；真实 stage 0/2/1/HEAD 选择、symlink、raw-byte/5 MiB 和错误反馈仍保留 |
| delete：JS 32 位内容扫描/key 兼容路径 | P5-T4；当前 item 单调身份不重置串旧缓存，不靠换 fileID 丢编辑器/undo |
| delete：未经实验的自定义 diff worker/备用计算路线 | P5；固定版本现有入口不满足就报告限制，不先搭双轨 |
| shrink：新增脚本只测依赖、不测 Kero 桥接；为测试强制拆文件/造类型壳 | P1/P2/P3/P4/P5；复用实际 App 模块与已有测试 seam，必要生产 helper 与脚本共同使用 |

不删除真实边界：原子写入与失败保留、断线不写本机、HEAD/upstream/确认目标验证、原始字节/NUL/UTF-8/容量检查、管道排空/timeout、symlink 循环界限、TextKit 空范围保护、键盘与无障碍。第三方未被 Kero 调用的公开能力也不自动算旧代码，不能在 vendoring 时裁剪整套单文件/annotation API。

## 实际验证

- `bash scripts/check.sh git-panel-state file-tree-navigation remote-commands panel-targets`：四项通过；分别证明临时 Git 最终操作/草稿、真实树导航/创建边界、远端命令纯逻辑、延迟目标隔离。不是新版分阶段实现或真实 SSH 验收。
- `bash scripts/check.sh git-execution`：通过；包括 GUI-like PATH、登录 shell 噪声/变量、实际本地接收仓库与 LFS 对象、启动失败拒绝写操作、超时/残留 helper 管道、原始字节/上限与受控远端映射。推送仅现有检查生成的本地接收仓库，无网络发布。
- `build/plan-review-editor-git.swift` 链接现有真实 TreeSitterClient/SwiftTreeSitter/JSON grammar：确认 N=7 的旧初始化表达请求 offset=14；完整 UTF-16 parse 的 EOF column=14 字节。使用 `-parse-as-library` 和当前 GeneratedModuleMaps；只核对依赖契约，不冒充实际 Kero 插件/实机验收。
- 追加 emoji 恰跨默认 UTF-16 读取 chunk 的独立 Parser/full-parse 对照：EOF 均为 2054 字节，未复现仅凭 String+Data 源码怀疑的截断。因此不加入额外 byte-snapshot reader/fork。初始范围问题也不等于已复现 App 启动崩溃：Kero 当前 `.zero` 回退会掩盖无效位置，P1-T3 修输入契约，不以推测的崩溃宣称性能收益。
- Node 从锁定 diff-entry.js 读取并执行原 contentVersion 函数：确认两种不同 printable 内容的 itemVersion 与高亮键碰撞，未修改 checkout、安装 npm 依赖或模拟整个 CodeView。
- 实际只读 Git 命令核验 NUL 的 index/tree 帧：README 的 metadata 结构成立，不存在路径为成功空输出；唯一临时目录中 `rev-parse --verify --quiet HEAD` 对 unborn 返回 1，对普通非仓库返回 128。说明 P5-T2 的缺失判定有真实命令证据，不只引用协议；未验证未来 reader 算法。
- `todo validate`、任务实际 anchor/本地链接检查与 `rtk git diff --check`：交付前核对。未来脚本未生成、未运行，不将计划中的命令写成已经通过。

原生 App、Instruments、WebKit 实际绘制、读取竞争、固定主机重连和真实 SSH 均须实施时完成，当前没有这些验收证据。性能数字仍为空，不把现有检查打印的树耗时当作前后比较。feature 文件保持工作树修改，未擅自提交或推送；原始一次性检查在 build 中，不入库。

## 外部契约核对

- [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)：caller actor 继承与 `@concurrent` 的边界；工程自身声明与真实 trace 才决定某段是否离开主线程。
- [Tree-sitter parsing](https://tree-sitter.github.io/tree-sitter/using-parsers/2-basic-parsing.html)：坐标/输入契约结合锁定 lexer 与 Swift wrapper 核对，不直接以当前网页替代固定源码。
- [git ls-files](https://git-scm.com/docs/git-ls-files)、[git ls-tree](https://git-scm.com/docs/git-ls-tree)、[git rev-parse](https://git-scm.com/docs/git-rev-parse)、[git cat-file](https://git-scm.com/docs/git-cat-file)：NUL metadata/对象读取；批协议文档不代表必须新增 batch 服务。
- [Apple 响应性](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)：交互延迟与主线程时间分开，100 ms 不是“全部打开流程保证值”；本机 xcdocs 无该条目后使用 apple-docs 读取核对。

这些依据只支持对应设计边界，不替代本功能的测量或正式应用验收。

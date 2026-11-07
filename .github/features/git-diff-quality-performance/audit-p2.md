# Audit P2 - git-diff-quality-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/git-diff-quality-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 修复原生首帧布局和滚动几何的共同根因
- [x] P2-T2 消除逐键正文全量回读及重复判定
- [x] P2-T3 统一实时折叠编辑坐标和手动展开行为
- [x] P2-T4 收敛 Unified Split 滚动与原生绘制
- [x] P2-T5 验证 Git 行浏览、折叠 AX 与焦点动作

## 任务到文件的映射

- P2-T1（`c8d92f1a`）
  - `Bailey/Git/DiffTextView.swift`：单一内容存储、折叠元素枚举、固定 LF 可见几何、100k 冷跳及删除行占位。
  - `Bailey/Git/DiffNativeSurface.swift`、`Bailey/Editor/NativeCodeTextView.swift`、`Bailey/Editor/NativeTextLineIndex.swift`：首屏装配与实时内容/行索引。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyTests/Git/DiffFoldLiveMutationTests.swift`、`BaileyTests/Editor/TextCoordinateIndexTests.swift`、`docs/features/diff.md`。
- P2-T2（`ee85f511`）
  - `Bailey/Git/DiffNativeSurface.swift`、`Bailey/Git/DiffViewerView.swift`、`Bailey/Editor/NativeCodeTextView.swift`、`Bailey/Editor/SourceTextEditor.swift`：原生变化范围、写入原文字节与已保存基线。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`、`docs/features/diff.md`、`docs/features/editor.md`。
- P2-T3（`4127eead`）
  - `Bailey/Git/DiffTextView.swift`、`Bailey/Editor/NativeTextLineIndex.swift`、`Bailey/Git/DiffViewerView.swift`：折叠唯一实时坐标、Find/Replace/选区与版本。
  - `BaileyTests/Git/DiffFoldLiveMutationTests.swift`、`BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`、`docs/features/diff.md`、`docs/ui.md`。
- P2-T4（`036873d5`）
  - `Bailey/Git/DiffNativeSurface.swift`、`Bailey/Git/DiffTextView.swift`、`Bailey/Git/DiffViewerView.swift`、`Bailey/Workspace/Project.swift`、`Bailey/Editor/NativeCodeTextView.swift`：Split/Unified、虚拟删除行和原生生命周期归属。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyTests/Workspace/NativePaneRetentionIntegrationTests.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`、`docs/architecture.md`、`docs/features/diff.md`、`docs/features/editor.md`。
- P2-T5（`a9e41fc1`）
  - `Bailey/Files/FileTreeModel.swift`、`Bailey/Files/FileTreePanel.swift`、`Bailey/Git/GitPanel.swift`、`Bailey/Git/DiffTextView.swift`：Git 选择与折叠 AX，以及 Files 跨 await 对象代次保护。
  - `BaileyTests/Files/FileTreeTests.swift`、`BaileyTests/Git/GitStatusModelTests.swift`、`BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyUITests/Git/GitChangesUITests.swift`、`docs/features/files.md`。

## 发现项

## 发现 F-02

- 任务：`P2-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:112`
- 摘要：`GUI冷启动偶发不挂载测试专属Git工作区`
- 风险：`本机同一GitHistoryUITests首个冷进程已出现窗口但30秒内未出现bailey.dock.files，导致历史二进制与超限文件无法进行真实UI校验`
- 预期修复：`跟踪BAILEY_UI_TEST_PROJECT从首次隔离启动到项目/Files Dock实际出现的状态与失败终态，区分加载缺失和AX可见性，不增加盲等或重新建窗`
- 验证：`隔离首次GUI启动与该测试的窗口、项目和Files Dock可见证据；make test:ui ONLY_TESTING=BaileyUITests/GitHistoryUITests/testBinaryAndOversizeHistoricalRevisionsShowNativeReadRestrictions`
- 解决证据：`f6573679: 隔离GUI冷启动以唯一绝对路径bailey.project.row验证项目已挂载，不再以bailey.dock.files存在判断；5次不同测试独立冷启动均通过，Binary/Oversize作为首例通过；Peekaboo AX实测同一隔离会话项目行与Files Dock均存在。build/git-history-audit-20261107.log:944-1049,1684-1698。`


## 发现 F-01

- 任务：`P2-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/RecentCommitsView.swift:1656`
- 摘要：`历史提交文件右键上下文菜单在真实 Bailey Dev GUI 中不可访问`
- 风险：`5条GitHistoryUITests中4条实际历史文件行已存在且可命中，但右键后Reset/View/Compare菜单项不出现，相关重置和历史比较最终字节未被GUI证明；整套UI命令退出65`
- 预期修复：`沿TreeFileRow与ContextMenuClickTarget到原生右键事件/NSMenu追踪排查，区分产品菜单被吞与XCUITest显示坐标合成失效；在真实所有者根修，不以重试或Sleep掩盖`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/GitHistoryUITests；真实右键菜单AX/动作与Git磁盘字节核对`
- 解决证据：`f6573679: GitHistoryUITests完整5/5通过、0失败，右键NSMenu键盘操作到达View/Compare/Open/Reset且真实Git Index/HEAD/文件字节符合预期；原生菜单项XCUITest直接枚举假失败。build/git-history-audit-20261107.log:1684-1698。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- <fill after fixes>

## 验证日志

- `<command>` -> `PASS | FAIL`；完整退出码与测试后的必要构建/签名检查：`<实际结果>`
- 受影响功能全部已识别的适用环境、条件、异常／极端情况及组合：`<核销范围与实际结果；不以代表性用例替代>`
- 已核对的触发前提与最终用户可观察结果：`<实际证据>`
- 逐项跳过／未测条件、具体原因、影响、替代证据、补验方法与 Gate 影响：`<逐项记录；没有则写无>`
- 当前文档归属、事实、索引／锚点与未测声明：`<实际核对结果>`

## Gate（是否允许进入下一阶段）

- 结论：`Go | No-Go`
- 理由：`<一句话>`

## 最终状态与剩余风险

- 当前状态：`Open | Resolved`
- 剩余风险：`<if any>`

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


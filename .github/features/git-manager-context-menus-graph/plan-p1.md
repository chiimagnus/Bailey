# P1：保留真实 Commit 拓扑与 Ref，完善 Recent Commits 视图

**Goal：** 不重做 Git 后端、不增加冗余查询，把 Recent Commits 改为 `design.html` 的双行提交布局、真实分叉/合并图谱与有类型的 Ref Badge。

**Non-goals：** 不改 Files 共享树、Changes、仓库工具栏或提交框；不创建远端分支/Tag 管理页、线性/合并模式切换或第三方图谱引擎。

**Approach：** 先恢复解析时丢失的父提交与 Ref 类型，再就地替换 `RecentCommitsView` 的单车道绘制和单 Badge 显示；左键展开历史文件保持原行为。

**Acceptance：** 提交标题后紧跟 Ref；下行呈现短 SHA、作者及右对齐相对时间；蓝色主干与彩色分支按完整父 SHA 绘制正确的分叉/合并，历史文件展开后线条连续；同 Commit 多 Ref 的类型和命中正确；分页、Diff 及无障碍不回归。

**Rules：** 遵守 `AGENTS.md` 的 MVVM + Observation 目标：当前 `GitStatusModel` 是唯一 Git 状态 owner，另一份进行中的重构计划将其就地升级为 `@Observable` ViewModel（名称不变）。实施前先核对其实际迁移进度，不创建平行 Git 状态或新服务；图谱为纯派生显示。保持 `TreeRowSurface` / `TreeFileRow` 的 hover、无障碍、滚动、折叠、本机和 SSH 数据范围。

<a id="p1-t1"></a>
## P1-T1 完整父 SHA 与有类型 Ref

**Files / 锚点：** `kero/Git/GitStatusModel.swift` 的 `RecentCommit` / `runGitStatus` / `parseRecentCommits`，`kero/UI/Panels/ToolPanelView.swift` 的历史文件 Diff 调用方；`KeroTests/GitStatusModelTests.swift`。

**已知事实：** 当前 `git log` 已一次返回 `%P`（全部父 SHA）、`%D`（Refs）、`%h`（短 SHA）、`%an`（作者）及 `%ct`（时间）；`RecentCommit` 已有 `shortHash` / `author` / `relativeDate`，无需增加元信息查询。但 parser 只保留首父 `parentHash`，`primaryReference` 只取一个字符串，不能可靠识别 `HEAD -> main`、`origin/main` 与 `tag: v...`。

**实施：**
1. 在 `RecentCommit` 存完整 `parentHashes` 和有类型的 Ref（当前本地 / 其他本地 / 跟踪引用 / Tag，保留实际名称和顺序），不增加第二个 Git 命令。历史 Diff 仍以 `parentHashes.first` 作为首父，避免两份父 SHA 真源。
2. 保留合并提交的每个 parent；兼顾 root/unborn、缺 decorations、多个 Tag/Branch 同指一个 Commit、带斜杠的本地分支；不能把所有带 `/` 的名字都识别为远程引用。结合现有 `git log -n` 的排序检查子提交是否始终先于加载的父提交，只有存在真实错序时才在同一次日志调用中调整排序。
3. 更新消费旧 `parentHash`/`references` 的调用点与测试；删除被替代的旧字符串推断逻辑，不留并行版本。

**验证：** `make test ONLY_TESTING=KeroTests/GitStatusModelTests SIGNING=adhoc`；用线性、双父、root、多个同 SHA Ref、含斜杠本地分支的 Git fixture 核对完整父 SHA 与引用类型；短 SHA/作者/时间仍取既有字段，历史 Diff 仍选择首父，不丢文件变化。

**提交边界：** Model/parser、必要调用方、回归测试一次提交。

<a id="p1-t2"></a>
## P1-T2 最小车道布局与 Ref Badge 独立命中

**Files / 锚点：** `kero/Git/RecentCommitsView.swift` 的 `commitRow`、`primaryReference`、`CommitTreeRails`、`commitFiles`；必要时只新增同一 Git 模块内的纯拓扑布局类型；相关 XCTest 与 Git 维护文档。

**已知事实：** 目前每行绘制一条固定 X=14 蓝色直线；完整提交行由单个 `Button` 包住，Ref 只是普通 `Text`，无法区别右击 Commit 与右击 Branch/Tag。

**实施：**
1. 按实际 parent SHA 计算主干与分支车道：以当前分支的第一父提交链作为蓝色主干，其余分支采用稳定的不同颜色，真实 merge 用平滑连接；不存在分叉时自然只占一条车道，**不提供模式切换**。HTML 的演示算法把侧分支复用同一条副车道，仅适用于不重叠样例；生产图谱须让同时活跃的分支占不冲突的车道。展开文件、分页不改变拓扑颜色；未加载父 SHA 不虚构连接。
2. 使用 SwiftUI `Canvas` 或既有绘图方式融入当前历史列表 gutter，不新增独立 Git Graph 页面或滚动容器。按设计稿将一条 Commit 调整为**两行**：标题与紧随其后的 Ref；下一行左侧短 SHA 与作者、最右侧相对时间；有细分隔线。保留 Kero 深色底色、蓝色主色、可配置的 `fontScale`、行 hover/selection 和 `TreeDisplayModel` 历史文件树；不可照抄 HTML 的固定 57px 行高。
3. 分离 Commit 标题左键展开、短 SHA 点击复制、Commit 行右键与本地 Branch/Tag Badge 的独立命中；跟踪引用只展示、不加专属菜单。多个 Ref 按标题后排列，窄空间可折叠，但**必须提供能访问全部 Ref 的 `+N` 入口**：HTML 当前仅显示不可点击的 `+N`，是原型局限而非产品验收标准。截断不能挤掉右对齐时间或误触发 Commit。

**验证：** 用受控 Git fixture 检查普通单车道、双父合并、同时活跃多分支、同 SHA 的多个 Ref、分页边界与展开文件后的连续线段；核对双行标题/Badge/SHA/作者/时间、窗口变窄后 `+N` 真正可操作、右键命中、键盘和 VoiceOver。只对照 `design.html` 的**分叉/合并设计**，不寻找已删除的线性模式，也不把 HTML 原型视为 SwiftUI 实机通过。

**提交边界：** 真实图谱+徽章可点击结构及相应测试一次提交；本 task 不加入任何新的 Git 写命令。

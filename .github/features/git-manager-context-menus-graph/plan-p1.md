# P1：保留真实 Commit 拓扑与 Ref，完善 Recent Commits 视图

**Goal：** 不重做 Git 后端、不增加冗余查询，用现有 `git log` 数据画正确的线性/分叉/合并提交图谱，使 Ref Badge 能独立命中。

**Non-goals：** 不改 Files 共享树、仓库工具栏和提交框；不创建远端分支/Tag 管理页，不引入第三方图谱引擎。

**Approach：** 先恢复解析时丢失的父提交与 Ref 类型，再就地替换 `RecentCommitsView` 的单车道绘制和单 Badge 显示；左键展开历史文件保持原行为。

**Acceptance：** 单父线性一条车道；双父合并能按真实父 SHA 画至少两条正确连接；非加载父节点不伪造终点；同一 Commit 的分支和 Tag 有独立命中区；30 条分页与 Git Diff 不回归。

**Rules：** 遵守 `AGENTS.md` 的 MVVM + Observation 目标，不新建平行状态源；当前模型仍由 `GitStatusModel` 拥有，图谱为纯派生显示。保持 `TreeRowSurface` / `TreeFileRow` 的 hover、无障碍、滚动、折叠、Mac 与 SSH 数据范围。

<a id="p1-t1"></a>
## P1-T1 完整父 SHA 与有类型 Ref

**Files / 锚点：** `kero/Git/GitStatusModel.swift` 的 `RecentCommit` / `runGitStatus` / `parseRecentCommits`，`kero/UI/Panels/ToolPanelView.swift` 的历史文件 Diff 调用方；`KeroTests/GitStatusModelTests.swift`。

**已知事实：** `git log` 当前命令已有 `%P`（全部 parents）和 `%D`（所有 decorations），但 parser 把 `%P` 变成第一项 `parentHash`，`RecentCommitsView.primaryReference` 只挑首个字符串，且不能可靠区分 `HEAD -> main`、`origin/main`、`tag: v...`。

**实施：**
1. 在 `RecentCommit` 存完整 `parentHashes` 和结构化 Ref（local / tracking / tag，保留原顺序及名称），不增加第二个 Git 命令。当前历史 Diff 所用的首父 SHA 通过 `parentHashes.first` 派生，避免双份真源。
2. 保留 merge commit 的每个 parent；兼顾 root/unborn、缺 decorations、多个 Tag/Branch 同指一个 Commit、带斜杠的本地分支与重复 Ref；不把所有带 `/` 的名字识别为 remote。
3. 更新消费旧 `parentHash`/`references` 的调用点与测试；删除被替代的旧字符串推断逻辑，不留并行版本。

**验证：** `make test ONLY_TESTING=KeroTests/GitStatusModelTests SIGNING=adhoc`（实际命令按当前 Makefile/XCTest target 验证）；直接给 parser 的线性、双父、root、同 SHA 多 Ref 样本，确认完整 parent 数组与正确 Badge 身份；已有历史 Diff 仍选择首父，不丢文件变化。

**提交边界：** Model/parser、必要调用方、回归测试一次提交。

<a id="p1-t2"></a>
## P1-T2 最小车道布局与 Ref Badge 独立命中

**Files / 锚点：** `kero/Git/RecentCommitsView.swift` 的 `commitRow`、`primaryReference`、`CommitTreeRails`、`commitFiles`；必要时只新增同一 Git 模块内的纯拓扑布局类型；相关 XCTest 与 Git 维护文档。

**已知事实：** 目前每行绘制一条固定 X=14 蓝色直线；完整提交行由单个 `Button` 包住，Ref 只是普通 `Text`，无法区别右击 Commit 与右击 Branch/Tag。

**实施：**
1. 以有序 Commit 列表及全部 parent SHA 计算最小连续车道；线性只占一列，真实合并/分叉才引入额外车道。颜色按车道稳定分配，不因滚动/展开改变拓扑。未加载父 SHA 保持边界连线，不凭猜测伪造连接；分页后增量重算保持已加载行关系。
2. 使用 SwiftUI `Canvas` 或既有绘图方式融入现有行 gutter；不新建滚动容器/完整 Git Graph 独立页面。保留当前面板行高、字重、蓝色 Accent 和 `TreeDisplayModel` 历史文件树。
3. 将 Commit 左键展开与独立 Branch/Tag Badge 控件分离，完整 Badge 可右击且不会落入父 Commit 的 Context Menu。支持多个 Ref，不隐藏 Tag；需要裁剪时优先保持可访问的完整名称和菜单命中。

**验证：** 构造仅线性、两分支汇合、多个 Tag 指向同 SHA、分页末端、展开历史文件的临时 Git fixture；检查真正的拓扑几何、键盘、VoiceOver 名称、macOS 鼠标右击命中。对照 `design.html` 的线性和合成分叉状态检查视觉；不把 HTML 的模拟分叉当真实 App 已实现。

**提交边界：** 真实图谱+徽章可点击结构及相应测试一次提交；本 task 不加入任何新的 Git 写命令。

# P2：引用分组、彩色标签与独立操作

**Goal：** 让 Git Graph 的本地／远端 Branch、Tag、HEAD 引用使用同一提交节点颜色，并呈现参考中的复合分段标签及独立操作。

**Non-goals：** 不改 Git 引用真实身份、OID 或写操作策略；不新建 Fetch、Remote 管理器、标签数据库或独立偏好。

**Approach：** T1 先在现有 `parseRecentCommits → RecentCommitsView.referenceBadge/referenceActions` 路径中让**符号远端 Ref（包括 `remote/HEAD`）作为只读 Ref 立即显示**，不建立尚未使用的分组 helper。T2 由 `GitPanel` 传入现有 `remotes`，同一 task 同时完成纯分组、可操作复合标签和消费 P1 palette 的替换；复用现有 Ref 菜单和写操作校验。**不修改 `remoteBranch(named:)` 的唯一合法操作归属算法，也不保留第二套中间呈现路径。**

**Acceptance：**
- 本地／远端同提交且同 branch 后缀，合成一个外框、内部各段独立；分歧时不合并。
- 当前本地分支、其它分支、仅远端、Tag、真实与符号 `remote/HEAD` 各有正确 icon、字体、颜色和操作；Detached HEAD 沿用真实 HEAD 圆点与 SHA 入口，不冒充本地 Branch。
- 现有 `+N`、长名称、窄侧栏、整行点击、Tag 点击与键盘操作不退化；无需新增 Git IO。

**Rules：**
- “同名”按**配置 remote 的最长完整前缀**剥离后，与本地 branch 名严格相同；不能按首个斜杠或字面 `origin` 猜测，更不能把 HEAD 符号引用当可写 Branch。
- 标签色直接消费 `CommitGraphLayout.Row.node.color`，不再取决于 `Reference.Kind`。
- 每段持有完整 Ref 名称和类型，Git 回调使用原始身份而非拼接的可见短文案。
- 不修改 Git 核心／详情分批刷新、操作资格保护、远端选择和 SSH 执行器。

<a id="p2-t1"></a>
## P2-T1 按 symref 分类远端别名并接入只读展示

**类型／依赖：** 独立可用的解析与展示修正；依赖 P1 已稳定的图谱渲染，不依赖复合标签。

**根因与调用路径：** `GitStatusModel.runGitStatus → parseRefSnapshot → parseRecentCommits → model.graphCommits → GitPanel.changeList → RecentCommitsView.referenceStrip/referenceBadge/referenceActions`。现有 `parseRecentCommits` 过滤全部 `GitRef.symbolic != nil` 的远端 refs，普通 Ref 在独立 Badge 中展示。实际隔离 Git 仓库的 `--decorate=full` 和 `for-each-ref` 证实符号 `origin/HEAD` 与真正直连的 `upstream/HEAD` 都会出现在同一提交的装饰中，**仅 `%(symref)` 不同**。两者必须分别显示，符号别名不能被现有 `.remoteBranch` 写动作识别。

**文件／锚点：**
- `kero/Git/GitStatusModel.swift`：`RecentCommit.Reference.Kind`、`GitRef.symbolic`、`parseCommitReferences`、`parseRecentCommits`、`recentCommitLogArguments` 和 `runGitStatus` 的 `.full/.historyOnly` 双入口；只增加实际被 UI 消费的只读别名类别。
- `kero/Git/RecentCommitsView.swift`：直接在既有 `referenceBadge` / `referenceActions` 的 switch 中消费新增只读别名 Kind，外观仍沿用当前原生按钮直到 T2 统一替换，不新增独立分组 renderer。
- `kero/Git/GitPanel.swift`：原有 `RecentCommitsView(...)` 产品链路和 `presentRemoteBranchAction` 的合法性检查，T1 不新增传参、不改动作。
- `KeroTests/Integration/Git/GitStatusModelTests.swift`：`testGitGraphUsesCommitDateOrderWithoutBreakingMergeParents`、含特殊命名 refs 的真实临时仓库。
- `KeroTests/Integration/Git/GitRemoteBranchActionTests.swift`：`testSymbolicRemoteHEADIsHiddenButRealHEADBranchRemains` 与长 remote 前缀用例；更新断言为“显示但不可写”，不能删掉该保护。
- `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：符号别名只展示与独立复制入口的测试，不能把仅修改模型字段当成 UI 已生效。
- 文档 owner：`docs/features/git.md` 的 Ref 解析、只读别名和展示；交互合同实际变化时同步 `docs/ui.md`。

**步骤：**
1. **Red：** 在现有 `GitRemoteBranchActionTests` 的临时 Git 复用真实直连 `origin/HEAD` 和符号 `upstream/HEAD → upstream/main`，分别断言 `.remoteBranch` 可操作与新展示性别名 Kind；补一个非 `/HEAD` 名称的符号 remote ref，确认同一语义，而非根据后缀猜类型。同一提交上的正常远端 refs 必须完整保留。`.historyOnly` 与完整刷新解析相同。增加 `RecentCommitsViewTests` NativeUI：别名**确实显示、可复制但无写菜单**。不建立尚未被界面消费的复合分组类型。
2. **最小解析：** `parseRecentCommits` 当前已有 `refsByName` 参数，且 `.full/.historyOnly` 都会传入同一个 `for-each-ref` 格式的快照；这里**不具备也不需要**额外 `remotes` 参数。将现有“一律过滤符号远端”分支替换为语义分类：`GitRef.symbolic != nil` 的 `.remoteBranch` 投影为**只读 `.remoteAlias`**（名字原样保留），`symbolic == nil` 的仍是普通 `.remoteBranch`。这样 `origin/HEAD` 和其它真实符号别名采用同一简洁规则，不为 `/HEAD` 增加例外；新增 Kind 在原 View switch 中穷尽处理，只提供 `.help`／复制原完整名，不提供 Checkout/Fetch/Merge/Pull/Delete/Archive。无需新 Git 查询、额外安全围栏或状态缓存。
3. **当场接入：** 修改原有 `referenceBadge/referenceActions` 一个入口即时展示新 Kind，保留当前其它 Ref 的现行 UI 行为。`GitPanel.presentRemoteBranchAction` 和 `GitStatusModel.remoteBranch(named:)` 继续只认 `.remoteBranch`、真实 OID 和配置的 remote；从类型与模型两层证明符号别名不可成为写目标。此 task 没有无人消费的 helper／备用旧路径。
4. **旧路清理：** 在**本 task** 删除旧“所有符号 remote 无条件丢弃”的过滤特例并用一处单一分类取代；不新增旧/新 parser 开关，不为只读别名增加第二条远端命令路径。保留失联时旧图只读、Ref OID 与当前窗口校验等真正的数据安全保护。
5. **Green/Refactor：** 跑 `make test ONLY_TESTING=KeroTests/GitRemoteBranchActionTests`、`KeroTests/GitStatusModelTests`、`KeroTests/RecentCommitsViewTests` 中新别名用例，核对模型字段、实际显示与上下文菜单都通过，详情失败仍只读。更新 `docs/features/git.md` 的符号远端别名显示和仅复制规则；同 task 独立提交。

**本 task Acceptance：** 产品 Git Graph 中，全部 `symref` 远端别名（含 `remote/HEAD`）正确可见、可复制且没有可写远端菜单；真正非符号的同名分支仍保留完整操作。无需在 parser 猜配置 remote 或检测名字后缀，也没有仅供 T2 消费的半成品 helper；分组与外观留给 T2 一次完成。

<a id="p2-t2"></a>
## P2-T2 替换 Ref Capsule 为复合矩形标签并保留分段操作

**类型／依赖：** 实现；依赖 P1-T2 palette 与 P2-T1 已在产品接入的只读别名类型；复合分组从零到消费者均在本 task 内完成。

**根因与调用路径：** `GitPanel.changeList → RecentCommitsView.referenceStrip → referenceGroup → referenceBadge → referenceActions`。当前所有 Branch/Tag 各是一枚全色 Capsule，既无 Ref 的真实复合展示，也无与图谱同色的图标，`ViewThatFits` 只知道原始 Ref 数量。此 task **同时**完成纯分组、唯一消费者接入、复合视觉和旧 badge 删除，不能先提交一个无产品调用者的展示模型。

**文件／锚点：**
- `kero/Git/RecentCommitsView.swift`：`referenceStrip/referenceGroup/referenceBadge/referenceActions`、`stashBadge`、`copy`，实现同一文件内最小纯值显示分组并让其被实际 UI 使用；消费 P1 同一 Git Graph palette。
- `kero/Git/GitPanel.swift`：只在此 task 通过已有唯一调用点传 `model.remotes`，不改 Git 写操作路由。
- `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：`testNativeContextMenuAtDirectReferencesContainsOnlyTheSelectedObjectActions`、`testTagBadgeDoesNotToggleExpandedCommitClosed`、`testLongCommitMessageCanScrollHorizontallyInNarrowSidebar`、`testManyParallelBranchesDoNotScrollWholeGraphSideways`；补纯值复合分组与实际原生分段命中／菜单／溢出用例。
- 文档 owner：`docs/ui.md` 的 Git 图谱特有标签与子片段点击；`docs/features/git.md` 的 Ref 操作入口。

**步骤：**
1. **Red：** 先在现有 XCTest owner 增加分组纯值用例：同一 OID 的 `main + origin/main`、`topic + origin/topic + upstream/topic`、独立远端、本地/远端同后缀却位于不同 OID、`foo/bar`、remote 名 `origin` 与 `origin/team` 前缀重叠、无配置 remote 但有旧 tracking ref、多本地 refs／Tag 共 OID、逗号／Unicode 与 40／64 位哈希。断言每组可还原原始 Ref、不重名误配；再在真实 `NSHostingView` 用实际可访问区域点击 `main | origin | upstream` 每段，核对剪贴板、右键菜单与整行展开状态。`main` 不含远端 Delete、`origin` 不含本地 Rename，符号 alias 无写菜单。**Tag 左键只能展开/定位，第二次不收起；“View Tag Details”仅在原右键。** 同时覆盖 SHA、Stash、`+N`、窗口 resize，旧固定 x/y 断言改成语义命中，不能删除有效测试。
2. **绘制：** 对照上游 `web/styles/main.css` 的 `.gitRef`：约 18pt 高、5pt 圆角、1pt 细边框、半透明灰底；以 SwiftUI SF Symbol 或 Kero 自绘简单分支／Tag 图标制作左侧约 18pt 高的图谱色小块，背景和文字使用现有 Kero 主题，不拷贝其 SVG。当前分支边框与 node 同色、名称加粗；remote 子片段细竖分割、斜体且可单独 hover。单本地、单远端、单 Tag、复合分支使用**一套基础标签外观**，不是四种特判 Capsule；轻微主题差异可接受，但整体轮廓、几何和配色关系必须对齐。
3. **同 task 构造且实际使用：** `GitPanel` 仅传已解析的 `model.remotes`；在 `RecentCommitsView` 以同一 commit 的完整 refs 按配置 remote 的**最长前缀 + 完整 branch 后缀**匹配本地 refs，组合成可还原原始 Ref 的显示组。当前分支优先；本地一段可接多远端，未配对的 remote/Tag/符号 HEAD 保持独立。每段使用原始 `Reference` 复用 `referenceActions → GitPanel.*Action → GitStatusModel` 资格/OID/窗口核对。优先沿用独立 Button、`.contextMenu`、`.help`，不构建第二套事件分发；`TreeRowSurface` 外层 `.onTapGesture` 不能误触发展开，若冲突只在本 commit row 的动作汇聚点修。符号 HEAD 仅复制与原名提示。
4. **自适应与菜单：** 复用已有 `ViewThatFits → referenceGroup → +N`，只把候选排列单位改为复合视觉组；`+N` 按**隐藏真实 Ref 数**计，每条原始 local/remote/Tag（包括复合组内的 remote）在菜单中仍有独立操作项，符号 alias 仅复制。长文字采用既有中间截断与 `.help` 全名，不能因复合组太长挤没最低可读标题或遮住远端片段；窄侧栏、持续拖宽缩窄、字体放大后不让整张图横滚。用 32+ Ref 同节点检查 `ViewThatFits` 多候选不会无谓构建成倍的重型视图；若确有测量热点，就简化现有候选构造，不另造布局器或加定时缓存。
5. **特殊对象：** Tag 使用图谱色 icon，轻量／附注类型的菜单资格保留；Detached HEAD 由空心当前节点与完整 SHA 识别，不再伪装一个普通分支标签（若当前项目明确依赖裸 `HEAD` 文案，须保留可访问名称提示）。Stash 的文字标签也改用同一中性圆角外观但保留独立 archivebox icon、完整 `stash@{n}`、重复 OID 不合并、Apply／Pop 等专属操作；不要保留旧全色 Capsule 作为第二套标签实现。共享 Files／CHANGES／STAGED 树样式和全局 Theme 不动。
6. **Green/Refactor：** 跑 `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests`、`KeroTests/GitRemoteBranchActionTests`，并验证 `GitStashActionTests` 的展示身份。深／浅主题及浅色 Ghostty 背景、真实面板 260pt／宽窗口中对照圆角、颜色、间距、菜单、hover 与 `.accessibilityLabel`。**同 task** 删除旧 `referenceBadge` 的 Capsule、按类型硬编码系统色、`stashBadge` 旧全色样式和未使用的重复渲染辅助，不额外封装 Theme 或保留兼容模式；同步文档并原子提交。

**本 task Acceptance：** `main | origin`、`topic | origin | upstream` 共用一个外轮廓，内有独立可命中、正确菜单的分隔段；彩色小图标与该提交节点轨道同色；任何真实 Ref 都可访问且不可串目标；窄侧栏不出现无意义的整体横向滚动。

## Phase 完成与审计

P2 每个 task 各自完成测试、接入、旧路清理、owner 文档和原子提交，再按 `executing-plans` 进入审计。`audit-p2.md` 仅审计开始时由工具生成，不在计划阶段预建。
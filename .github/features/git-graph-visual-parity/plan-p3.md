# P3：提交行交互、节点悬停与整体视觉验收

**Goal：** 完成图谱／Ref 与提交信息的同一行视觉层级、弱化和悬停状态，确保复刻结果在真实 Kero 侧栏中可用，而不是只在纯数据测试中正确。

**Non-goals：** 不搭建 WebView Git Graph、全新工具栏、可调整表格列、Git 比较／Code Review 或专用遥测平台；不以用户当前仓库做破坏性自动测试。

**Approach：** 使用现有 `TreeRowSurface` 将第一行调成“图谱｜Ref 组合｜标题”；第二行保留 Kero 的 SHA／作者／相对时间，这是只复刻**图谱与标签**的有意取舍，而非声称整个 Git Graph Webview 已逐像素相同。Merge 弱化仅作用于提交消息。用现有本地 snapshot 在节点 hover 提供最小可用的原生提示，再按静态截图、原生操作和少量复杂 DAG 组合验收；必要的修复、测试与旧路清理属于各自 task，不留到最终批处理。

**Acceptance：** 两张参考截图中的全部有确定证据的视觉差距均有对应实现／测试／对比证据，复合 Ref 与拓扑和实际 Git 状态联动。局部 hover/menu 不阻断整行点击、文件展开或窗口切换；性能、字体、暗亮主题无明显回退。

**Rules：**
- 必须使用当前 `TreeRowSurface` / `LazyVStack` 的原生生命周期，不能重造一份 Git graph 列表或第二套引用绘制器。
- 只从 View 已有 `commits`、`refs`、`graph.rows` 展示鼠标提示，不为 hover 发 Git/SSH 命令，也不构建第二套完整祖先缓存。
- 基础无障碍、键盘、中文／emoji、不同字体缩放、窗口主题都属于必要回归。图形颜色不可成为唯一的状态指示。
- 现有 staged/unstaged/历史文件树行不因 Git Graph 外观改版而改变。

<a id="p3-t1"></a>
## P3-T1 对齐提交行顺序、密度与状态视觉

**类型／依赖：** 实现；P1、P2 完成后。

**根因与路径：** `GitPanel.changeList → RecentCommitsView.commitRow → TreeRowSurface`。当前第一行 `subject` 在 `referenceStrip` 之前；`subject` 自带可横向滚动的 Button，后接高优先级标签，调整顺序后容易被 `ViewThatFits` 挤没标题；作者在第二行用斜体衬线，而参考使用普通 UI 字体；Merge 文案没有弱化。必须保持已有第二行和独立控件命中，不顺手修改共享树行。

**文件／锚点：**
- `kero/Git/RecentCommitsView.swift`：`commitRow`、`TreeRowSurface` 样式边界、`referenceStrip`、文本 `ScrollView(.horizontal)`、`relativeDate`、`onTapGesture`。
- `kero/Git/GitPanel.swift`：当前面板 `padding(.horizontal, 6)` 与 `historyCollapsed`；只在确有布局冲突时微调调用点。
- `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：整行坐标点击、标题可点击、窄／宽视图、展开文件、Stash 和各种右键的既有用例。
- `docs/features/git.md`：第一行显示顺序和内嵌文件展开；`docs/ui.md`：仅图谱区域的独立视觉说明，保留共享树原先规则。

**步骤：**
1. **Red：** 在已有 `NSHostingView` 宿主的 260pt／宽侧栏、默认与放大字体中核对第一行 Ref→标题顺序、Merge 只淡化正文、HEAD 标记、滚动与展开文件。修复后的参照图应可看到参考中 HEAD 前方小圆环提示（当同布局容得下时）；不能只通过图谱节点的颜色判断 HEAD。现有硬编码 x/y 的点击测试须重新按实际控件区域定位，但不得删除有效命中断言。
2. **布局：** 直接交换现有 `commitRow` 第一行内容顺序为 `referenceStrip → subject`，保留现成 `gutter` 与文字局部横向滚动；复合标签先按当前可用宽度收起至 `+N`，给 subject 留最低可读空间。第二行 SHA 复制、作者与日期右侧保留；只在这条提交行将斜体衬线作者改为普通系统 UI 字形。行高、baseline、间距按真实参考画面对照定稿，始终按 `fontScale` 缩放，不单独引入尺寸配置。
3. **视觉状态：** Merge 判定只用 `commit.parentHashes.count > 1` 且排除 Stash。参考 `.commit.mute` 仅对提交**标题文字**降不透明度；选中／hover 恢复标题可读，Ref、图谱颜色和菜单保持不淡化。HEAD 应由 `.currentBranch`／`.detachedHead` 真实引用识别，与 P1 空心节点一致，不按行首或 `main` 名称推断。非 Merge、Stash 保持正常；保留 Kero 当前全行展开语义。
4. **命中和滚动：** 复核 graph gutter、Ref 各段、Tag、SHA、Stash 的独立动作，普通留白继续整行展开；Tag 连续两次点击**不收起**是现有合同。`+N` 中选定 Ref 的动作仍绑定所在仓库和实际 OID。加入空标题、长中文／emoji／作者、多个 Tag+Branch、相对日期变化、历史文件展开后继续滚动及 pane 拖宽缩窄；只测这些可达风险，不追加无关 Git 写操作。
5. **Green/Refactor：** 运行 `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests` 和受影响的共享树命中回归 `make test ONLY_TESTING=KeroTests/TreeRowHitTestingTests`，复核 Git 面板的完整展开／关闭路径；更新上述 owner 文档。删除旧的 subject-first 布局与多余的视觉 fallback，不在全局 Shared 树里增加不可维护的 Git 特判，原子提交。

**本 task Acceptance：** 第一行标签在消息左侧、标签图标与节点同色；Merge 标题弱化不影响 Ref 对比；当前 HEAD 小圆环与图谱节点一致；第二行、历史文件、全部独立菜单仍能工作。截图与实际 `NSHostingView` 点击同时验收，不把低层布局检查当 E2E。

<a id="p3-t2"></a>
## P3-T2 节点悬停信息与跨场景最终验收

**类型／依赖：** 图谱局部交互实现 + 跨任务验证；依赖 P3-T1。每个此前任务已经就地通过对应测试，本 task 不代替它们的验收。

**根因与路径：** 参考 `web/graph.ts` 的点悬停可提示提交、包含它的 Branch／Tag／Stash、HEAD 关系；Kero 的 `CommitGraphRails Canvas` 装饰层目前 `.allowsHitTesting(false)`，但已有标题和 Ref `.help`、整行点击、`TreeRowSurface.onHover`。直接让 Canvas 参与命中会破坏现有全行点击；应复用这些原生控件能力，只有真正缺少节点悬停区域时才加局部命中代理，不建独立 tooltip 生命周期管理。

**文件／锚点：**
- `kero/Git/RecentCommitsView.swift`：`commitRow` 的 node hit area、`CommitGraphRails` 的 `laneX`／中点位置、局部 hover 状态和 tooltip；按需添加最小私有辅助方法，不另起一个全局 hover 服务。
- `kero/Git/CommitGraphLayout.swift`：只有已加载图谱的纯查询确实需要时才加只读 ancestry 辅助；优先从 `RecentCommit.parentHashes` 直接计算，不重复储存完整 DAG。
- `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`、`KeroTests/Unit/Git/CommitGraphLayoutTests.swift`、`KeroTests/Integration/Git/GitStatusModelTests.swift`：新增 hover/hit/生命周期和 HEAD 可证明包含关系的断言。
- 文档 owner：`docs/ui.md` 的图谱 hover；`docs/features/git.md` 的 loaded DAG 范围及标签、tooltip 状态；验证规则只引用 `docs/testing.md`，不抄一份新政策。

**步骤：**
1. **Red：** 在已有 `NSHostingView` 中实际悬停提交节点及附近空白，确认前者显示正确的 SHA／已知 Ref，而点击两处均只展开一次；hover 和右键 Ref、滚轮、面板折叠／切项目互不影响。已有 `.help` 够用就用，不额外实现多窗口悬浮框、关闭计时器或鼠标事件总线；必要时只加与 `CommitGraphRails.laneX` 同一几何来源的局部透明命中区域。
2. **HEAD／分支归属：** 文案尽量对齐参考的“提交属于哪些 refs、是否在 HEAD 中”，但只能用**当前已加载图谱**计算；能沿父边从实际 HEAD 到达的提交才可肯定“在 HEAD 中”，因为分页缺父／HEAD 未加载不能判否；若无法可靠证明就省略结论。关联 Branch/Tag/Stash 名称沿已加载子边查找或只展示直接装饰，不能把不确定内容写成已证实，也不新增每次 hover 的 Git/SSH 请求、跨页长期祖先缓存或庞大 tooltip 引擎。
3. **轻量呈现：** 优先用系统 `.help` 显示提交短／完整 SHA 和可确认的引用事实；若必须加点命中区域，用现有 node lane 几何放在可见行上，点击转发同一个 `toggle`，绝不产生“双 toggle”或覆盖 Ref 按钮。颜色留给已实现的节点／标签，tooltip 不强制实现上游 Web 样式和彩色箭头。禁止把 tooltip `@State` 放在整个 `RecentCommitsView` 上引发每次鼠标移动全量 `CommitGraphLayout` 重新计算。
4. **视觉对照：** 复用 P1／P2 已有的确定性合成 Git 历史与原生宿主；无需再建立第二套测试平台。现成 VS Code Git Graph 可用时用同 fixture、同主题、同窗口尺寸抓对照；否则对照用户截图与固定上游源码，标明未实测的视觉项，不另行安装 IDE。每个任务已就地检查其核心视觉；本阶段仅确认三者整合：
   - 第 1 层：颜色序列、路径保持、合并线交汇处、曲线／线宽／描边、空心 HEAD／Stash。
   - 第 2 层：Branch/Tag 图标、Ref 标签高宽圆角、灰底与彩边、组合片段边线／斜体、当前分支粗体；`origin/HEAD` 与 Tag 实际出现在正确提交。
   - 第 3 层：标签在消息左侧、Merge 弱化、标题／SHA／作者／时间、选中/hover、全名提示及响应式裁切。
   - 对照必须写明尺寸、缩放、字体、外观和参考 commit；不把不同 DPI 的两张原截图硬作逐像素相等。记录差距、逐项闭环；不能以“算法通过”取代视觉验收。
5. **高价值边界（组合覆盖，不做笛卡尔全排列）：**
   - 图：unborn／单线／多 tip、双父／Octopus／交叉 Merge、独立 root、缺页、30→60 的真实 Git 分页、300／1000+ 合成行与超过 12、30 条并行车道；Stash 同 OID 不同 selector／base 缺页。
   - 引用：同名本地／多远端同 OID、分歧 OID、远端前缀重叠与已移除 remote、符号与真实 `/HEAD`、Detached HEAD、轻量／附注 Tag、多 ref 同提交、逗号／斜杠／Unicode 和 40／64 位 Hash。
   - 原生：约 260pt 和 400pt+ 侧栏、默认／放大字体、深／浅及 Ghostty 自定义主题、2x 显示比例、动态改变面板宽度、完整菜单命中、键盘焦点与基础辅助功能；已展开历史文件同时在 `gitViewMode` 的 tree/list 两种模式保持轨道贯穿，复核上下／左右停靠及第二窗口切项目。
   - 状态：首次加载、2s／5s 自动更新、Ref 详情失败保留只读旧图、历史分页中途失败／重试、切仓库与 SSH 掉线后恢复；只在合成／获授权环境运行，真实 SSH 未授权则明确未测。
   - 性能：现有 `CommitGraphLayout.init` 从 SwiftUI body 重建；对实际改动涉及的 30、300、1000 行进行有界布局／滚动对比，排查重复全量分配，按 `docs/testing.md` 记录数据，**不凭空设定硬阈值或新增长期 benchmark 框架**。
6. **最终验证：** 在此前每个 task 的针对性 XCTest、原生操作、文档与原子提交已经通过的前提下，集中跑 `make build`、`make test`；检查执行总数、失败和 skipped，不能把宿主 NativeUI 当独立进程 E2E。实际隔离 `--isolated-ui-test` Kero 走一次“图谱→复合标签→右键→历史文件→刷新／分页”完整路径，真实 SSH 仅按 `docs/testing.md` 授权 fixture 执行，跳过则标记未验收。必须保留用户当前 App、共享设置和其他 AI 的工作树；失败回到所拥有的任务修根因，不在这里加通用 workaround。
7. **收尾不是延迟清理：** 这里只对照已完成的 P1/P2/P3 变化，检查各 task **已在当次**删除固定 HEAD 蓝色、按 lane 着色、旧色盘、Ref Capsule、重复组装和 subject-first 布局；发现残留退回所属 task 处理并补相应回归。完善发生真实变化的 `docs/features/git.md`／`docs/ui.md`，核对锚点与 `git diff --check`；可比截图／录屏与原始测试输出放本地非入库 `build/`，不污染产品 commits，也不触碰并行修改。

**本 task Acceptance：** 颜色、标签、节点、行顺序、hover 与 Ref 实际操作在同一原生 Git 视图中完整联动；所有计划中的单元、集成与原生场景都有可查的通过记录或明确未测限制，失败不得标记完成。

## Phase 完成与审计

P3 所有 task 完成后由 `executing-plans` 进入本 phase 审计。`audit-p3.md` 应基于 task→实际 commit→源码与真实用户路径形成独立证据；本轮只有写计划，不创建审计、不改源码、不提交或推送。
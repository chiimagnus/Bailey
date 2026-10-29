# Bailey 交互状态架构与 VS Code 行为对齐

## 为什么要做

Bailey 的文件树、Git Changes、Git Graph、Projects、Dock 标签以及命令面板，
曾各自管理蓝色描边、主题选中底色、灰色浏览底、悬停、键盘输入、右键菜单及文件打开。
前次仅共享高亮组件，尚未充分核对各领域的**状态含义、所有权与事件因果关系**；
还曾误将原生 Settings 侧栏纳入共享样式，后以 `9c84d355` 回撤。

当前已能从源码确认：Files 以 `selectedPath` 代表 Focus、`selectedPaths` 代表 Selection，
而 `selectRange` 会覆盖不相邻选择；Git Changes 的 `explicitlySelectedChange` 只存一个对象；
Git Graph 的展开集合由窗口级 `GitStatusModel` 持有，
其游标、临时菜单目标由 `RecentCommitsView` 持有，彼此语义独立；
Dock 一组只保留一个展示项、一个菜单上下文，不支持 VS Code 式多标签选择。
这些不是单纯颜色差异，必须按原生输入事件、模型状态、命令目标和可见效果一起治理。
此外，Dock 从文件 A 切换至 B 后，Files 旧 Selection=A 与 Displayed=B 各绘制一层不同灰底；
Git Changes 也可能保留旧选择并另绘当前 Diff。固定版本 VS Code 的 Explorer/SCM
均默认在活动编辑器改变时自动定位并选择匹配资源。Bailey 此处不是有意保留的产品差异，
必须修复跨组件同步及多余的 Displayed 常驻底色，而不只是调灰色透明度。

本 Feature 在**完全审查上游真实代码后**实现对齐，不先写补丁；
本轮不读取或继承已有 audit 结论；重新下载固定提交的源码，独立核对。
源代码、许可证、映射、差异、删旧边界和组合验证记录在
[`source-review.md`](source-review.md)。旧 `vscode-source-audit.md` 只保留历史，
不再作为执行依据或当前验证矩阵。
各 phase/task 必须按该表先核对相应 upstream 入口，再审 Bailey 的真实调用链。

## 术语与改造边界

Focus、Selection、Anchor、Expanded、Active、Hover、Displayed、Context Target
是本 Feature 用来分析交互的八类概念，**不是 VS Code 官方统一的“8 状态模型”**，
也不是要求每个组件补齐八个字段。Bailey 已有其中大多数状态，本次沿现有所有者修正具体差异，
不推倒重建，也不以字段同名、数量齐全或集中存储作为验收。

- **Focus 分两层：** 列表保留的行游标不等于实际输入焦点；
  `selectedPath/selectedChange/selectedRowID/cursorProjectID` 的名字不能代替行为判断。
  原生输入仍由当前窗口的 firstResponder 及控件实际反馈确认，失焦无需销毁有效游标。
- **语义分开不等于独立存储：** 合法的只读派生、成员约束和明确动作联动继续保留。
  例如 VS Code 的 `activeEditor` 由组内 Selection 首项取得；
  Bailey 的 `DockGroup.selected` 表示展示项，不是未来新增的标签多选集合。
  Displayed 可由现有内容推导，Context Target 可通过本次菜单事件传递，不另建全局字段。
  但 **活动编辑器变化是明确事件**：VS Code Explorer/SCM 的 Auto Reveal 会据此更新树的
  Focus 游标与 Selection（不抢真实键盘输入），不能把独立语义误写成禁止事件联动。
- **只增加确有需求的状态：** Git Changes 和 Dock 补资源／标签多选与 Anchor；
  Graph 的展开、比较两端不变成通用多提交 Selection，Projects 不增加文件式多选。
  Palette／Ctrl+Tab 保留暂态机制，Settings 保持原生 List，Hover 留在局部视图。
- **差异不是自动成立的缺陷：** 先核对已授权行为和真实组合，再决定是否修改。
  右键清除背景并绘制临时描边是 Bailey 的现行视觉约定，不因不同于 VS Code 就取消。

## 目标

1. **逐层吸收 VS Code**：基础 List/Tree 的 Focus、Selection、Anchor、Context、Hover、
   稳定 identity、折叠、Keyboard/Pointer/AX；Explorer 的导航、目录压缩、文件打开、文件操作；
   SCM Changes 的资源多选、分组、Diff、Stage/Unstage；内置 SCM History Graph 的提交/文件节点；
   编辑器标签的 active/selected、多选、组/窗口、拖放、菜单及快捷键。
2. **Git Graph 双源对齐**：分析 VS Code 内置 History Graph 和 mhutchie Git Graph 扩展的
   提交展开、比较、ref 标签、Stash、图谱几何、行状态和菜单；Worktree 是 Bailey 自有能力，
   在 Bailey 原生 SwiftUI/AppKit/现有 Git 后端上独立实现可观察等价行为。
3. **状态语义稳定**：Focus 游标、明确 Selection、多选 Anchor、Displayed 文件/Diff、
   Expanded 目录/提交、Hover、菜单 Context Target、活动 Dock Group 和真实 NSWindow
   firstResponder 不再被误当成彼此；不能仅凭某个状态变化擅自触发另一个动作。
   一次明确动作可更新多个状态，合法派生不复制成另一份可写真源。
4. **一个事件只有一个明确意图**：左键、修饰键、右键、双击、Space/Return/方向键、
   文件打开、Git Diff、项目切换、标签选择/拖放/关闭和命令路由都由唯一入口决定，
   不能在 View/Model/Window 三处重复“猜测”行为。
5. **视觉可复核**：蓝框/主题底色/悬停/右键临时描边遵循对应 UI 类型的
   已验证状态组合，不能用同一个“选中”布尔值代替全部事实。
   Explorer/SCM Changes 不因 Displayed 单独常驻第二条灰底；
   切换文件标签后旧选中 A 应按 Auto Reveal 更新为 B，而不是 A、B 各灰一行。
   Files/Git 树可共享行渲染，Dock Tab 可有独立标签视觉变体，
   Settings 使用 SwiftUI 原生 List。
6. **干净模块化**：数据真源留在现有领域所有者；跨模块通过明确用户意图及有效身份交接，
   清理重复判断、旧分支和无用兼容代码，不创建全 App FocusManager、万能 SelectionStore、
   全局菜单监听器或额外的一整层 Coordinator/Protocol。
7. **任务可独立验收**：每个 task 有源码证据、Red→Green（如确有缺陷）、实现/旧路径删除、
   宿主和实际 GUI 验收、同步当前所属文档、一个功能一个 Git 提交。
   `todo.toml` 是唯一实时任务真源，不在计划文档重复进度。

## 明确产品范围与复刻边界

- **Included：** Files / File Manager、Git Changes / Git Manager、Git Graph、Projects、
  Dock／文件与工具标签、Command Palette、Ctrl+Tab 切换预览，以及因它们而必要的
  编辑器/终端/Diff 原生输入交接和双窗口命令路由。
- **Included（新能力）：** VS Code 式 Git Changes 资源多选与批量操作、
  Dock 内同组文件/工具标签的多选、范围锚点和批量拖动。
  真实操作能力不足时应依据业务合法目标分组拒绝/禁用，不能假装一组 Git 操作都能批量执行。
  Files 本机多选外拖必须逐项向 Finder 提供 URL，不能只导出被拖行一个文件。
  Dock 内部拖动限同项目同窗口 Move；Option 仍 Move，不新增内容克隆或跨窗口转移后端。
- **Included（Graph 目标）：** 扩展式 Commit Details、与另一提交的比较意图、
  分支/远端/标签/Stash/Worktree 独立菜单、父子链键盘导航、
  视觉/图谱身份和刷新恢复的全面行为对照。
  Git Graph 扩展的危险 ref 双击动作与 Bailey 此前“标签单击统一展开”冲突；
  **不得把 checkout/rebase/reset 直接绑到标签双击**。
  保留多展开与普通方向键仅移动游标；新增普通提交双端比较及修饰键父子导航，
  不引入扩展单详情覆盖或其 ref 双击 Checkout。
- **Preserved：** Bailey 现有固定标签（无自动替换的 preview-tab 生命周期）、
  本机/SSH 工作空间模型、SwiftUI + AppKit + TextKit 2、任意 Dock 工具可停靠、
  原有 Git 数据安全与原生系统菜单。
  如果全面源码对照表明某项 VS Code 行为必须新增生命周期或改变用户明示规则，
  在对应 task 先记录影响和可接受方案；不得在“重构”中偷偷改变。
  Files 折叠后清不可见 Selection、压缩行按明确段/整行末级操作、
  菜单期仅描边、Graph 展开无持续底色是现有契约，作为明确差异保留，不能宣称逐项相同。
- **Excluded：** Settings 窗口；VS Code DOM、Electron、Webview 存储和 CSS 代码；
  重写文件/SSH/Git 服务、Git Graph 整套后端或引入 Git Graph 源代码。
  扩展许可证禁止向 Bailey 分发其衍生源代码/资源，只有可观察语义独立复现。
  VS Code 主仓库为 MIT，移植适用片段需履行其许可和 NOTICE 要求。
- **外部历史：** 旧的 `context-menu-and-tree-selection` 计划已于 `304fd7df` 删除，
  不得依赖其已不存在的文件。原来菜单按键蜂鸣、视觉反馈及系统富类型剪贴板
  未完成验收的事实，在 P2 本 Feature 重新列作**待复核而非已通过**；
  只用当前源码/测试/历史提交核对，避免平行实现重复监听。

## 不可破坏的不变量

- **唯一所有者**：
  `Project.fileTree` 持 Files 路径选择/展开；
  `GitStatusModel` 持 Git 数据、Git Changes 选择/游标、Graph 展开及目录折叠，
  `GitPanel` 处理 Changes 输入和临时菜单，`RecentCommitsView` 持 Graph 游标/菜单目标；
  `DockWorkspaceModel` 持组布局/活动/每组标签选择；
  `WorkspaceWindowModel` 只管本窗口跨模块交接；
  真正输入以 key window 的 NSWindow.firstResponder 为准。
  Git Graph commit ID、工作树身份、文件完整路径和标签 UUID 不得混成一个“全局 selected ID”。
- **活动编辑器与树同步**：切换 Dock 文件/Diff 标签时，若当前 Files/SCM 树可见且资源属于
  对应项目、机器、仓库及有效范围，遵循 VS Code 默认 Auto Reveal 定位并选择匹配行，
  同时更新树游标，但不把原生 firstResponder 从 Editor/Terminal/输入框抢走；
  无匹配、被排除或暂时不可见时不伪选其它文件。后台迟到的同步不得覆盖更新的活动标签。
- **输入与命令目标**：编辑器 NSTextView、Ghostty、浏览器、TextField、Sheet/Palette
  在拥有 firstResponder 时不被后台 Files/Git/Dock 改写键盘输入。
  菜单有效时显式目标优先，菜单关闭即撤销，主菜单快捷键仍只有一个动作实现。
  当前 Bailey Files、SCM Changes 与 Dock 对集合外右键均先建立临时 Context，
  不强制替换原 Selection；各自的集合内/外菜单动作按本领域合法目标解析，
  不统一成同一种“右键选中”。树鼠标 Shift、树键盘 Shift、Tab Shift 分别有自己的规则。
- **数据保护**：未保存文件保存失败禁止关闭/覆盖，Git index/HEAD/refs 修改按原有确认和
  重新验证执行；SSH 断线或切机器拒绝对过期目标执行且绝不回退本机。
  任何多选/批量操作必须逐项明确目标及失败/部分成功语义。
- **刷新恢复**：只有项目+机器+连接+仓库身份一致，且节点仍存在，才延续游标、
  选择/锚点；临时菜单/拖放只在本次动作有效时继续，目标变化立即取消，不在刷新后复活。
  图谱渲染和树结构更新不得重建编辑器/WebView/终端或丢失当前滚动。
- **最小可见差异**：UI 变化只能来自明确列入对齐的行为差异，其他图标/布局/文案/颜色/
  动效/快捷键/语音辅助和跨系统行为都按现状守住。
  VS Code 上游行为≠已授权直接改变 Bailey 的每个产品决定；
  对冲突先以真实界面比较记录选择。

## 来源与决策基线

参考 [本轮独立源码映射与差距表](source-review.md)，固定：

- VS Code 主仓库 `microsoft/vscode@4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e`：
  List/Tree/Explorer，SCM Changes/History Graph，EditorGroup/Tabs/Drag & Drop、Palette/Views。
- Git Graph 扩展 `mhutchie/vscode-git-graph@d7f43f429a9e024e896bac9fc65fdc530935c812`：
  Commit Details、ContextMenu/Graph/Ref 行为与标签外观；**源代码不得复制分发**。
- Bailey 本轮基线 `e0e29d2c323aa0f60c76ed1051543fcdc7ee8149`；
  实施前以当前 HEAD 和工作区差异重新核验，不假设 `origin/main` 最新，也不为此擅自 fetch/push。

## 交付和验收

- **P1**：Files 的 Focus/Selection/Anchor、树 identity 与 AX/视觉；修正不连续 Shift 选择。
- **P2**：Files 打开/预览意图、Dock 编辑器变化的 Explorer Auto Reveal、
  文件菜单/Edit、压缩目录、DnD 和原生 firstResponder。
- **P3**：SCM Changes 的活动编辑器 Auto Reveal、资源集合/批量操作；History/Git Graph 的提交/比较/上下文、
  拓扑与异步身份，均在现有数据后端上实现。
- **P4**：Projects、Dock 每组标签多选/Anchor、标签/组拖动、关闭/活动组和 Palette/Tab Switcher；
  核对所有标签切换入口均触发 P2/P3 的一次明确编辑器变化，而非重绘推断。
- **P5**：跨 Files/Git/Graph/Dock/Windows 的真实组合回归、语义/视觉/AX 与简化审计；
  不是把前四阶段应该完成的旧代码清理或文档同步拖到最后。
- **逐 task**：对照 upstream 入口 → 查 Bailey 领域 owner 和最终副作用 → 验证 Red（有缺陷时）
  → 最小迁移与删旧路径 → 宿主/隔离 GUI/主题/语言/设备/容量/SSH 可行组合核验
  → 更新 `docs/features/*.md` 与 `docs/ui.md` → 单一原子 Git 提交 → todo 回写。
- **无必要改动**：若现有实现已经满足该 task，记录实际源码与运行证据，
  不为凑提交制造重构；用任务工具的 `--no-commit-reason` 说明无变更原因，
  仍须满足该任务的验收。
- **每阶段**：必须通过 `phase-complete` 和独立 `plan-task-auditor` Gate 再前进；
  新发现会更改需求的真实差异更新 `idea.md` 和对应 task，不为已知问题留空白验收。

### 应测维度（实际测试脚本使用 `docs/testing.md`）

状态组合：无/单/多/不连续/锚点撤销/焦点集合内外；右键先后/菜单中/退出；
Hover/Displayed/Expanded/Focused/Selected 交错，活动/失焦及两个窗口；
正常鼠标/触控板/键盘与 IME/VoiceOver；文件/目录/紧凑段、Git 分组/状态、
Commit/Refs/Stash/Worktree、工具/文件/Diff/终端/浏览器标签；
长/短名称、空/单/巨量数据、主题/字体/宽度、中/英；
本机与合法 Windows SSH、失联/重连/切换身份；滚动/刷新/重排/拖动/关闭；
真实磁盘、Git index/HEAD/refs、原生剪贴板与未保存保护。

完整取值和组合矩阵见 `source-review.md`。测试不能只证明某个 View 被点或
某个回调收到数据，必须验证正确文件/标签/命令结果。
当前环境若不可获得 macOS 15.6 真机、实体触控板、中键、真实 Windows SSH 断线、
系统富类型剪贴板等，在 task 中按具体阻碍、影响、补测条件逐项保留，
不得冒称“全部完成”。

执行前复核仅交付源码依据、计划与机械校验，不能当作实现、Red→Green 或阶段 Go。
后续实施按用户明确授权的阶段推进，实时状态只由 `todo.toml` 维护；
P1 的实际命令、结果与未覆盖条件记录于 `evidence-p1.md`，不扩大到 P2。
运行态旧路径在对应替换任务立即删除；不新增旧名 alias、Feature Flag 双轨、
复制/跨窗传输框架或无证据的多层请求代次。已有快照的最小解码、连接身份、
保存否决、不可覆盖文件操作和 Discard 审核有真实用途，不归类为“多余安全围栏”。

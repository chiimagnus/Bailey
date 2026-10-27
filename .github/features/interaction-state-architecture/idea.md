# Bailey 交互状态架构与 VS Code 行为对齐

## 为什么要做

Bailey 的文件树、Git Changes、Git Graph、Projects、Dock 标签以及命令面板，
曾各自管理蓝色描边、主题选中底色、灰色浏览底、悬停、键盘输入、右键菜单及文件打开。
前次仅共享高亮组件并未统一**状态所有权与事件因果关系**；
还曾误将原生 Settings 侧栏纳入共享样式，后以 `9c84d355` 回撤。

当前已能从源码确认：Files 以 `selectedPath` 代表 Focus、`selectedPaths` 代表 Selection，
而 `selectRange` 会覆盖不相邻选择；Git Changes 的 `explicitlySelectedChange` 只存一个对象；
Git Graph 的 `expandedCommitIDs`、`selectedRowID`、`contextRowID` 各自独立；
Dock 一组只保留一个展示项、一个菜单上下文，不支持 VS Code 式多标签选择。
这些不是单纯颜色差异，必须按原生输入事件、模型状态、命令目标和可见效果一起治理。

本 Feature 在**完全审查上游真实代码后**实现对齐，不先写补丁；
源代码、许可证、映射、差异和组合验证记录在
[`vscode-source-audit.md`](vscode-source-audit.md)。
各 phase/task 必须按该表先核对相应 upstream 入口，再审 Bailey 的真实调用链。

## 目标

1. **逐层吸收 VS Code**：基础 List/Tree 的 Focus、Selection、Anchor、Context、Hover、
   稳定 identity、折叠、Keyboard/Pointer/AX；Explorer 的导航、目录压缩、文件打开、文件操作；
   SCM Changes 的资源多选、分组、Diff、Stage/Unstage；内置 SCM History Graph 的提交/文件节点；
   编辑器标签的 active/selected、多选、组/窗口、拖放、菜单及快捷键。
2. **Git Graph 双源对齐**：分析 VS Code 内置 History Graph 和 mhutchie Git Graph 扩展的
   提交展开、比较、ref 标签、Stash/Worktree、图谱几何、行状态和菜单；
   在 Bailey 原生 SwiftUI/AppKit/现有 Git 后端上独立实现可观察等价行为。
3. **状态语义稳定**：Focus 游标、明确 Selection、多选 Anchor、Displayed 文件/Diff、
   Expanded 目录/提交、Hover、菜单 Context Target、活动 Dock Group 和真实 NSWindow
   firstResponder 不再互相推导、互相覆盖。
4. **一个事件只有一个明确意图**：左键、修饰键、右键、双击、Space/Return/方向键、
   文件打开、Git Diff、项目切换、标签选择/拖放/关闭和命令路由都由唯一入口决定，
   不能在 View/Model/Window 三处重复“猜测”行为。
5. **视觉可复核**：蓝框/主题底色/弱灰底/悬停/右键临时描边遵循对应 UI 类型的
   已验证状态组合，不能用同一个“选中”布尔值代替全部事实。
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
- **Included（Graph 目标）：** 扩展式 Commit Details、与另一提交的比较意图、
  分支/远端/标签/Stash/Worktree 独立菜单、父子链键盘导航、
  视觉/图谱身份和刷新恢复的全面行为对照。
  Git Graph 扩展的危险 ref 双击动作与 Bailey 此前“标签单击统一展开”冲突；
  **不得把 checkout/rebase/reset 直接绑到标签双击**，必须先完成交互差异核定。
- **Preserved：** Bailey 现有固定标签（无自动替换的 preview-tab 生命周期）、
  本机/SSH 工作空间模型、SwiftUI + AppKit + TextKit 2、任意 Dock 工具可停靠、
  原有 Git 数据安全与原生系统菜单。
  如果全面源码对照表明某项 VS Code 行为必须新增生命周期或改变用户明示规则，
  在对应 task 先记录影响和可接受方案；不得在“重构”中偷偷改变。
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
  Git Changes、RecentCommitsView 持局部选择/游标/展开；
  `DockWorkspaceModel` 持组布局/活动/每组标签选择；
  `WorkspaceWindowModel` 只管本窗口跨模块交接；
  真正输入以 key window 的 NSWindow.firstResponder 为准。
  Git Graph commit ID、工作树身份、文件完整路径和标签 UUID 不得混成一个“全局 selected ID”。
- **输入与命令目标**：编辑器 NSTextView、Ghostty、浏览器、TextField、Sheet/Palette
  在拥有 firstResponder 时不被后台 Files/Git/Dock 改写键盘输入。
  菜单有效时显式目标优先，菜单关闭即撤销，主菜单快捷键仍只有一个动作实现。
- **数据保护**：未保存文件保存失败禁止关闭/覆盖，Git index/HEAD/refs 修改按原有确认和
  重新验证执行；SSH 断线或切机器拒绝对过期目标执行且绝不回退本机。
  任何多选/批量操作必须逐项明确目标及失败/部分成功语义。
- **刷新恢复**：只有项目+机器+连接+仓库身份一致，且节点仍存在，才延续游标、
  选择/锚点和临时上下文；菜单/拖放请求不是可持久化恢复状态。
  图谱渲染和树结构更新不得重建编辑器/WebView/终端或丢失当前滚动。
- **最小可见差异**：UI 变化只能来自明确列入对齐的行为差异，其他图标/布局/文案/颜色/
  动效/快捷键/语音辅助和跨系统行为都按现状守住。
  VS Code 上游行为≠已授权直接改变 Bailey 的每个产品决定；
  对冲突先以真实界面比较记录选择。

## 来源与决策基线

参考 [完整源码映射与差距表](vscode-source-audit.md)，固定：

- VS Code 主仓库 `microsoft/vscode@4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e`：
  List/Tree/Explorer，SCM Changes/History Graph，EditorGroup/Tabs/Drag & Drop、Palette/Views。
- Git Graph 扩展 `mhutchie/vscode-git-graph@d7f43f429a9e024e896bac9fc65fdc530935c812`：
  Commit Details、ContextMenu/Graph/Ref 行为与标签外观；**源代码不得复制分发**。
- Bailey 当前基线在 `35e45134`、设置回撤 `9c84d355` 之后；
  后续并行提交需以实施时 `origin/main` 和当前工作区实际差异重新核验，不覆盖别人的改动。

## 交付和验收

- **P1**：Files 的 Focus/Selection/Anchor、树 identity 与 AX/视觉；修正不连续 Shift 选择。
- **P2**：Files 打开/预览意图、文件菜单/Edit、压缩目录、DnD 和原生 firstResponder。
- **P3**：SCM Changes 的资源集合/批量操作；History/Git Graph 的提交/比较/上下文、
  拓扑与异步身份，均在现有数据后端上实现。
- **P4**：Projects、Dock 每组标签多选/Anchor、标签/组拖动、关闭/活动组和 Palette/Tab Switcher。
- **P5**：跨 Files/Git/Graph/Dock/Windows 的真实组合回归、语义/视觉/AX 与简化审计；
  不是把前四阶段应该完成的旧代码清理或文档同步拖到最后。
- **逐 task**：对照 upstream 入口 → 查 Bailey 领域 owner 和最终副作用 → 验证 Red（有缺陷时）
  → 最小迁移与删旧路径 → 宿主/隔离 GUI/主题/语言/设备/容量/SSH 可行组合核验
  → 更新 `docs/features/*.md` 与 `docs/ui.md` → 单一原子 Git 提交 → todo 回写。
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

完整取值和组合矩阵见 `vscode-source-audit.md`。测试不能只证明某个 View 被点或
某个回调收到数据，必须验证正确文件/标签/命令结果。
当前环境若不可获得 macOS 15.6 真机、实体触控板、中键、真实 Windows SSH 断线、
系统富类型剪贴板等，在 task 中按具体阻碍、影响、补测条件逐项保留，
不得冒称“全部完成”。

**本轮边界：只做完整源码审查、Feature Plan 与机械校验；不运行产品构建、
不提交功能代码、不替换或重启正式 Bailey。**

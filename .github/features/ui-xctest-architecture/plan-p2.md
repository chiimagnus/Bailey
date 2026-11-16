# P2｜收紧 Files、Dock 与原生内容的 GUI 测试边界

**交付：** 让文件操作、共享树、Dock 状态、主题和原生内容的条件矩阵由宿主覆盖，
完整 Bailey Dev 只承担真实 Finder、系统菜单、前台键鼠、窗口、PTY、WebKit 与恢复路径。
直接复用已存在的原生宿主测试，不为缩短时间再建通用视图驱动；
无法证明的界面接线始终保留实际 App 验收。

## 方案与已有基础

当前剩余 **113 个 UI 方法**分布于 Files 51、Workspace 59、Editor 3。
它们混合了两种性质：可直接运行的文件／状态／本地原生视图验证，
以及必须由 XCUITest 的真实前台输入才可证明的系统级行为。

- `BaileyUITests/Files/WorkspaceFilesUITests.swift` 同时测试
  真实 Finder 文件拖放／系统剪贴板与已由
  `FileTreeModel`、`FileTreeTests` 提供的选择和文件操作语义。
- `BaileyUITests/Workspace/WorkspaceDockUITests.swift` 的
  多选、拖动、组状态和标签操作已有
  `DockWorkspaceTests` 的原生模型验证，但窗口标题栏双击、
  系统菜单跟踪、⌘W 的原生焦点和跨组拖动并不能由模型替代。
- `WorkspaceRetentionUITests` 的部分主题／字号／布局断言已有
  `GitGraphPaletteTests`（60 个主题）、`AppSettingsTests` 和原生编辑器宿主测试；
  真正经 Settings 改变已挂载界面、Ghostty／WebKit、重启恢复仍需要真实应用。
- 编辑器的 3 个 E2E 方法数量少，负责真正的键盘操作与保存。
  不以追求用例数量为由迁移到丧失真实输入的宿主测试。

实际用户入口为 `Bailey Dev` →
`WorkspaceDockView`／`FileTreePanel`／`SourceTextEditor`／
`TerminalHostView`／`Browser` →
`WorkspaceWindowModel`／`FileTreeModel`／`PaneTab`／`WorkspaceBackend` →
原生窗口、文件字节、SSH 目标或会话恢复。
其中原生 Tree 行和 Dock 组件由同一状态所有者交付，
所以迁移的宿主测试不能复制一套只在测试中成立的状态或绕过最终 IO。

P2 必须复用现存的
`BaileyTests/Files/FileTreeTests.swift`、
`SSHFileTreeLiveTests.swift`、
`BaileyTests/Workspace/ProjectFileIndexTests.swift`、
`PanelContextTests.swift`、`DockWorkspaceTests.swift`、
`WindowOwnershipIntegrationTests.swift`、
`WindowCloseIntegrationTests.swift`、
`NativePaneRetentionIntegrationTests.swift`，
以及编辑器／Diff 原生测试。
此前提交 `add2a99b` 已用启动参数代替大量普通 Add Folder 选择器，
无需重新引入一个额外 GUI 启动捷径。

## 任务

<a id="p2-t1"></a>
### P2-T1｜消除共享树／文件操作的重复状态查询与测试路径

- **位置：** `BaileyUITests/Files/SharedTreeUITests.swift`、
  `WorkspaceFilesUITests.swift`；
  `Bailey/Shared/Tree/TreeRowStyle.swift`、
  `Bailey/Files/FileTreePanel.swift`、`FileTreeModel.swift`；
  `BaileyTests/Files/FileTreeTests.swift`、
  `BaileyTests/Workspace/PanelContextTests.swift`、
  `WindowOwnershipIntegrationTests.swift`。
- **实施：** 逐项核对 16 个 SharedTree、33 个 WorkspaceFiles 方法。
  `FileTreeTests` 已测试压缩目录多段、真实 IO、多选锚点、
  Files／Git 共享样式、原生按钮语义和坏符号链接；
  保留由它直接证明的所有环境／极端条件，不重复增加矩阵。
  对同一真实 UI 状态反复 `waitForExistence`、
  `isSelected`、AX 遍历的步骤，确认不是分别证明时序后，
  可以在一次已到达的原生视图状态中读取当前行集合；
  仍须通过真实菜单、逐层目录点击、Cmd／Shift 键鼠和磁盘字节
  证明实际用户操作，不能将它们移成对模型的直接赋值。
  对 `SharedTreeUITests.testGitCompactSegmentsUseTheirRealChangesHistoryAndWorktreePaths`
  等需要从 Files／Changes／History／Worktree 多入口独立命中的用例，
  区分必要的切换次数与重复的检查。
  每次确认宿主已覆盖且其它 UI 仍证明同一用户入口，
  即在**本任务**删除旧 AX 步骤或整个重复方法、
  不再使用的本地测试 helper；不修改生产文件树语义。
- **判据：** 实际图标／行层级、中文路径、压缩目录各层的
  不同命中、Focus／Selection／Context Target 与键盘所有者不混同；
  实际创建／复制／移动／删除的文件字节和权限准确。
  `SharedTreeUITests.testCompactFoldersStayCompactedWithAccessibleComponentActions`
  依赖真实 AX 子节点、菜单与剪贴板，不会仅因为宿主选择集合正确而删除。
  对比修改前后 AX 查询、真实点击和时间，任何简化不能失去对菜单
  取消／旧目标失效／跨机器的验证。
  仅测试入口或覆盖归属变化时同步
  [测试规范](../../../docs/testing.md) 与相关
  [Files 契约](../../../docs/features/files.md) 的受影响部分。

<a id="p2-t2"></a>
### P2-T2｜保留 Finder／文件选择器／SSH 的真实路径，删除等价夹具步骤

- **位置：** `BaileyUITests/Files/WorkspaceFilesUITests.swift`、
  `WorkspaceLocalFileEventsUITests.swift`、
  `WorkspaceFileIndexRefreshUITests.swift`；
  `BaileyUITests/Support/WorkspaceUITestSupport.swift` 的
  `finderDragSource`／`choose`／`selectSSHFolder`／
  `clipboardItems`；
  `BaileyTests/Files/SSHFileTreeLiveTests.swift`、
  `BaileyTests/Workspace/ProjectFileIndexTests.swift`、
  `BaileyTests/Remote/SSHWindowsFileEventsTests.swift`。
- **实施：** 本机文件事件、索引和授权 Windows SSH 的断线／重连矩阵
  优先使用已有真实后端宿主测试，避免在 App 内重放一遍纯列表状态。
  **保留** Finder 真正拖出 fileURL、本机接受／SSH 拒绝的正反对照，
  NSOpenPanel 与中文长路径、剪贴板原类型恢复、
  命令面板对外部文件的显示、双窗机器目标与最终文件字节；
  不把 `FileTreeModel.importFromFinder` 调用当成 Finder→App 测试。
  针对现有 `WorkspaceUITestSupport.choose` 与
  手工 `clipboardItems` 的多重备份／还原，
  只在验证没有测试中途必须观察的回滚动作，
  且不会丢失懒加载剪贴板数据后，于**本任务**删除等价的重复层；
  不清除保证用户剪贴板和输入法不被污染的唯一所有者。
  再检查已迁移为 `BAILEY_UI_TEST_PROJECT` 项目预载后
  是否仍有仅为普通用例保留的旧原生选择器调用；只有专门验证
  Add Folder／系统 Picker 的用例继续打开真实选择器。
  `BAILEY_P4_TEST_SSH_HOST` 仍须显式授权，
  SSH 测试只操作经校验的随机临时远端目录，
  不动正式 Bailey／用户 SSH master。
- **判据：** 本机和远端的最终目录、文件字节、机器身份与权限准确；
  同一真实 Finder 拖动在 Mac 成功、在 SSH 拒绝，且保护文件不变；
  操作后输入法／剪贴板按真实项类型完整恢复。
  授权 SSH 缺失时保留明确的 `XCTSkip`，但结果标为未验，
  不能因跳过或模拟后端声称通过。仅删已证明等效的旧夹具步骤；
  校验远端路径、防命令注入及旧连接身份的保护不得删除。

<a id="p2-t3"></a>
### P2-T3｜修复 Dock／窗口真实失败并消除重复检查

- **位置：** `BaileyUITests/Workspace/WorkspaceDockUITests.swift`、
  `WorkspaceWindowsUITests.swift`、`WorkspaceSmokeUITests.swift`；
  `Bailey/UI/WorkspaceDockView.swift` 的
  `DockTreeView.divider`、`DockTabGroupView.tabStrip`／
  `handleMenuKeyDown`；`Bailey/Workspace/DockWorkspaceModel.swift`；
  `BaileyTests/Workspace/DockWorkspaceTests.swift`、
  `NativeContentIdentityIntegrationTests.swift`、
  `WindowOwnershipIntegrationTests.swift`、
  `WindowCloseIntegrationTests.swift`。
- **实施：** 先核对已有原生宿主对标题栏留白、标签溢出、
  多选批量移动／关闭和菜单目标的实际断言，
  不引入整套真实 `WorkspaceDockView` 新宿主。
  对 `testAllThreeDockGroupsSupportBlankHeaderDoubleClick`：
  CI 已在右组出现 **7 pt 空白**，失败前提是“必须 >12 pt”；
  `DockTabGroupView.tabStrip` 的真实空白触发条件由
  `tabStripContentWidth` 和组宽决定，
  要复核用户契约究竟要求可点击留白，还是始终要求 12 pt；
  若生产确实挤没可操作区域则根修布局，
  否则修改**无根据的测试尺寸假设**但仍实际执行右组双击缩放。
  对 `testChineseTabContextMenuUsesNaturalWidth`：
  CI 在 Close 菜单的 `label.contains("⌘W")` 失败；
  从 `DockTabGroupView.projectTabMenu` 的 badge 到原生 NSMenu
  与 AX label 逐层复核，区分产品快捷键不可用和 AX 不在 label 中显示，
  并核对中文与英文的真实快捷键及原生菜单尺寸。
  Git 分隔条失败由 P1-T2 与此处共享同一 `DockTreeView.divider` 根因，
  只在真正的生产所有者修复一次，不创建两套事件转换 workaround。
  真实窗口拖动／双击、Tab／Divider 拖动、菜单期间 ⌘W、
  多窗口焦点及保存否决均保留 GUI。
  `testThirtyRealDockSwitchesKeepExplorerSelectionAndMeasureEndToEndResponse`
  的 30 次真实切换就是端到端时序测量，不能用宿主点击一次替代。
  对已由宿主证明的重复模型断言，连同旧 UI helper 在**本任务**删除，
  不到 P3 再清理。
  `DockSavedItem.info` 虽是历史值，`docs/features/settings.md` 明确要求
  在已有窗口快照恢复时过滤它；这是当前持久化数据契约，
  不是本次可以为了减少测试代码而删除的兼容分支。
- **判据：** 三个旧 CI 失败各自有明确前提、真正根因及复验；
  中／左／右真实可用标题栏空白、窗口缩放和当前菜单快捷键可操作，
  点击／拖放不误移动系统窗口；
  中文英文菜单及 ⌘W、其他前台快捷键按目标执行一次。
  原生保存失败仍能阻止关闭，跨窗不串目标。
  `NativeContentIdentityIntegrationTests` 证明原生组件，
  `WorkspaceDockUITests` 证明外层系统事件，两者不能互相冒充。
  若产出产品修复，仅在本任务修改其最小所有者并补 Red→Green，
  同步 [Dock 契约](../../../docs/features/dock.md) 和
  [测试规则](../../../docs/testing.md)。

<a id="p2-t4"></a>
### P2-T4｜只保留必要的主题／编辑器／终端／浏览器全 App 验证

- **位置：** `BaileyUITests/Workspace/WorkspaceRetentionUITests.swift`、
  `BaileyUITests/Editor/EditorHighlightingUITests.swift`、
  `EditorNavigationUITests.swift`；
  `Bailey/App/AppSettings.swift`、
  `Bailey/Editor/SourceTextEditor.swift`、
  `Bailey/Git/DiffNativeSurface.swift`、
  `Bailey/Terminal/TerminalHostView.swift`、
  `Bailey/Browser/BrowserView.swift`；
  `BaileyTests/Settings/AppSettingsTests.swift`、
  `BaileyTests/Editor/NativeEditorLayoutTests.swift`、
  `NativeEditorCompositionTests.swift`、
  `NativeSyntaxHighlightingTests.swift`、
  `BaileyTests/Git/NativeDiffTabTests.swift`、
  `BaileyTests/Workspace/NativePaneRetentionIntegrationTests.swift`。
- **实施：** 检查 17 个 Retention、3 个 Editor GUI 方法，
  将实际重复于 `AppSettingsTests`、`GitGraphPaletteTests`
  60 主题矩阵、原生 TextKit／Diff 的纯状态与静态颜色断言交回宿主；
  **不新增第三套主题像素计算器或全窗口测试驱动**。
  真正通过 Settings 更改已打开页面的实时外观、场景恢复、
  Unicode 输入与 ⌘S／Undo、10k 行远距导航，
  以及浏览器 WebKit、Ghostty 实际 Shell／Find／PTY，
  继续要求真实 App，保留像素或最终文件字节检查。
  对 `testBuiltInDefaultAndCatalogPalettesRepaintWithoutSwitchingDock`
  一类长流程，区分每次切换独有的即时重绘不变量与
  重复进入 Settings 后的相同 AX 查询；只合并不丢时序的检查。
  系统自动外观切换须原有外部 opt-in，不允许为减少 skip
  擅自更改用户系统设置。
  真正已由宿主覆盖、且被其他 E2E 覆盖入口的方法，
  在**本任务**删除旧方法／脚本及其私有 helper；
  未被替代的编辑器实际输入、文件保存、Finder→Ghostty/WebKit
  和浏览器表单不删除。
- **判据：** 动态换主题后各个已挂载面板、TextKit、WebKit、
  终端都实时更新，不错认已关闭内容；重启后设置按约定恢复。
  真实 Shell PID 不变、浏览器表单／历史不断、
  文件字节与 IME／Undo 正确。
  现有主题及原生组件测试在自身覆盖层仍完整；
  无真实 App 的系统输入、浏览器、Terminal、外部拖放结果时不能给 E2E 通过。
  仅在长期规则发生变化时同步
  [测试规范](../../../docs/testing.md) 及实际受影响的功能文档；
  不为纯测试迁移改写无关功能契约。

## 阶段验收

所有适用条件由宿主验证数据、原生组件和异常的宽矩阵；
真实 App 继续逐项验证不可能由宿主重现的系统动作，
不能以一个“代表性 GUI 用例”豁免另一种独立交互。

| 结果 | 条件、边界与组合 | 不可替代的实际验收 |
| --- | --- | --- |
| 共享树和文件 | 空／大目录、短／长中文路径、压缩多层目录、同名不同根、符号链接、外部替换、文件与目录选区、Cmd/Shift/Range、取消和错误 | 原生行分段与菜单、快捷键路由；创建／复制／移动／删除后的正确磁盘路径及字节 |
| 文件焦点与菜单 | Files／Editor／Terminal 焦点、不同 Dock 组／窗口、系统 Edit／Project 菜单、右键前后／取消、Esc／⌘W、重命名草稿与冲突 | 真正的系统输入、菜单生存期与命中，焦点从不误写另一控件 |
| 拖动与窗口 | 普通／按 Option、多文件／非选中行、压缩目录段、Finder fileURL、本机和 SSH、窄宽窗口、标题栏及分隔条、双击系统缩放 | 真实拖动源与落点，前后磁盘字节、窗口位置／尺寸和原生标签归属 |
| 异步与远端 | 缓存／冷读取、快速切换、外部文件事件、断网／断连／重连、旧结果晚到、Windows 路径与 shell 保护 | 真实本机及获授权 SSH 的目录／索引、正确窗口和机器、失败不回退污染 |
| 原生内容 | 明／暗及自定义主题、9／18pt 字号、10k／100k 行、32MiB、Unicode／CRLF／IME、Undo／Redo、多文件／跨窗／重挂载 | 原生像素和输入时间、完整原字节、真实编辑器键盘与重启恢复 |
| 浏览器／终端 | 浏览器表单与上传、真实 Ghostty PTY/Find、输入法与菜单交接、Finder→WebKit/Ghostty、窗口重开／关闭／取消 | WebView 不重新创建、PID 不变、真实文件传递或拒绝、保存失败不得强退 |

- 先运行宿主受影响的 `make test:FileTreeTests,DockWorkspaceTests,`
  `NativePaneRetentionIntegrationTests,WindowOwnershipIntegrationTests` 等真实存在的类，
  再按具体改动补 `PanelContextTests`、`ProjectFileIndexTests`、
  `WindowCloseIntegrationTests`、原生编辑器及远端测试；
  一并执行 `make build:ui`。完整阶段归宿见 P3。
- 真实 UI 只在独立图形会话运行本阶段留下的相关方法。
  `testAllThreeDockGroupsSupportBlankHeaderDoubleClick` 和
  `testChineseTabContextMenuUsesNaturalWidth` 已知失败必须有真实
  Red→Green 或明确环境阻塞证据；不能调整阈值或禁用。
- 真实 SSH 未授权／系统外观切换不允许／没有独占 GUI 时，
  逐个记录未运行方法、宿主替代证据、环境缺口、风险与补验。
  中文输入、剪贴板和外部拖放涉及系统权限时，
  不使用当前正式 Bailey 或用户 GUI 桌面作为替代测试环境。

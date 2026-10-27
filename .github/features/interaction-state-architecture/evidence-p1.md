# P1 实施与验证证据

本页记录实际执行及覆盖边界；任务状态只见 `todo.toml`。生产基线为 `11fa5c46`。
环境：Apple Silicon、macOS 27.2（26B5101f）、Xcode 27.2（27B5038j）、Python 3.14.7。
只使用根 Makefile 和现有 XCTest；未操作正式 Bailey 的进程、用户 SSH master 或原有任务。
用户明确允许 GUI 回归期间独占桌面焦点。

## P1-T1

- 源码：固定版本 `MouseController.changeSelection` 的 Anchor 连续岛；
  `listCommands.expandMultiSelection` 的前后 Focus 成员调整。没有移植 DOM 代码或新增状态容器。
- Red：两个新增宿主用例在旧实现失败，完整日志 `/tmp/bailey-p1-t1-red.log`。
  穷举 6 行的 64 种集合 × 6 个 Anchor × 6 个目标，以及 64 集合 × 6 游标 × 2 方向。
- Green：`make test:FileTreeTests`，84 tests / 0 failures；
  `/tmp/bailey-p1-t1-green.log`，xcresult `Test-Bailey-2026.10.27_18-33-15-+0800.xcresult`。
  包含 Unicode、空选择、集合外游标、锚点取消／全选、首尾不动、连续反向及真实复制结果与字节。
- GUI：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests/testModifierMultiSelectionDoesNotOpenOrCollapseFiles`，
  1 test / 0 failures；`/tmp/bailey-p1-t1-ui.log`，
  xcresult `Test-Bailey-UI-2026.10.27_18-35-23-+0800.xcresult`。
  真实 ⌘／Shift 点击、键盘扩选／反向、右键取消、AX 集合及未新增 FileTab 均断言。
- 测试自身修正：批量文件操作按后端顺序返回，比较成功源集合与真实字节，不要求等同 UI 本地化排序；
  GUI 在右键后 Focus=C，⌘A 后 Shift+↓ 应移除 C，而非沿用旧断言“C 仍选中”。未改变生产契约迎合测试。
- `make build:dev`、Dev Bundle ID／完整验签和 `git diff --check` 通过；
  `/tmp/bailey-p1-t1-build.log`。
- 删除：键盘共用鼠标区间覆盖的分支、⌘A 的旧隐式 Anchor、一次 by:2 伪按键测试；
  文件操作、稳定路径和真正数据保护不改。同步 `docs/features/files.md`。

## P1-T2

- Red：`testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot` 的旧拖动有效性两项断言失败；
  `/tmp/bailey-p1-t2-red.log`。新路径投影链同时确认现有改名／移动／删除／过滤规则成立。
- Green：`make test:FileTreeTests,PanelContextTests`，103 tests / 0 failures；
  `/tmp/bailey-p1-t2-green.log`，xcresult `Test-Bailey-2026.10.27_18-39-49-+0800.xcresult`。
  包含 1000+／Unicode、空树、折叠祖先、同路径重建、过滤不复活、晚到旧连接、失败保留与换机器清理。
- 真实 SSH：按 `docs/testing.md` 已授权的 windows，两个同名环境变量均传入 Makefile；
  精确执行 SSHFileTreeLiveTests 的目录批读／失败隔离、复制移动删除和改名三个方法，
  3 tests / 0 failures / 0 skipped；`/tmp/bailey-p1-t2-ssh.log`，
  xcresult `Test-Bailey-2026.10.27_18-41-06-+0800.xcresult`。
  独立临时 master 和专属 `/tmp/bailey-*` 目录均按现有测试清理；没有使用用户 master。
  新断言验证实际移动后的游标／Selection、删除后的可见祖先和源／目标二进制字节。
- Windows 原生软链接创建返回 status=1；该分支未执行，不能以三个用例通过声称软链接全测。
  本机真实链接与同路径替换已在 Files 宿主覆盖；远端原生链接需具备相应权限的专属环境补验，
  不为测试修改 Windows 系统权限。硬链接与大小写改名分支本次实际执行。
- GUI：`WorkspaceFilesUITests/testRealSettingsExcludeAndFileTabRevealHiddenRow`，1 test / 0 failures；
  `/tmp/bailey-p1-t2-ui.log`，xcresult `Test-Bailey-UI-2026.10.27_18-42-21-+0800.xcresult`。
  真实隔离 Settings 配置、隐藏／Reveal／再次隐藏／恢复默认和实际文件内容均验证。
- `make build:dev`／验签、`git diff --check` 通过。删除重复移动／改名状态映射，
  两入口复用现有 FileTreeModel 内唯一 `remapPaths`；没有新增兼容 alias 或请求代次。

## P1-T3

- Red：新增真实 App 用例确认 Changes 压缩行没有分段 AX／菜单；
  `/tmp/bailey-p1-t3-red.log`，`Test-Bailey-UI-2026.10.27_18-46-36-+0800.xcresult`。
  第一次测试编译的 Data／String 断言类型错误先修正，不计为产品 Red。
- Green：`make test:FileTreeTests,GitGraphPaletteTests`，90 tests / 0 failures；
  `/tmp/bailey-p1-t3-host.log`，`Test-Bailey-2026.10.27_18-48-22-+0800.xcresult`。
- GUI：SharedTreeUITests 的分段各级新建、保持压缩及中间段点击、Git 三处新分段、
  非压缩目录行尾暂存四方法，4 tests / 0 failures；`/tmp/bailey-p1-t3-ui.log`，
  `Test-Bailey-UI-2026.10.27_18-49-25-+0800.xcresult`。
  实际 Git 中间段忽略规则为 `/a1/b1/` 而非末级；History 与 Worktree 三段均执行相对／绝对复制，
  同时核对 AX 路径、HEAD／index／文件字节，剪贴板完整备份并恢复。
- Files 原有压缩模型的逐段新建、祖先改名、内部 Drag 身份与懒读取一起回归。
  本 task 没有实现系统多项外拖；该后端及原生拖动会话仍归 P2-T4，不以模型测试冒充系统 Drop。
- 共享 `TreeCompactSegment` 取代 Files 重复呈现，并接入 Changes／History／Worktree；
  从枚举直接传递索引，删除旧 firstIndex 失败时落到第 0 段的 fallback。
  原生菜单和实际业务 owner 保留，不增全局状态或第二条文件／Git 操作路径。
- `make build:dev`／验签、`git diff --check` 通过；files／git 功能页同步。

## P1-T4

- 实际缺陷是 `selectionEnabled == false` 时以 focusRing 作为 AX Selected；
  不是现有配色优先级错误。删除该字段、所有调用参数及旧 fallback，不保留兼容入口。
- 先尝试最小 NSHostingView 的公开 accessibilityChildren：本机返回空数组，无法建立测试前提；
  该夹具和探针删除，改为扩展现有真实 App 用例，不引入私有 AX 桥或假造组件结果。
- 有效 Red：`GitChangesUITests/testGitGraphSpaceExpandsCommitWhenChangesListIsEmpty`，
  目录 Focus、文件 Focus、Displayed Diff、菜单取消四项 AX 断言失败；
  `/tmp/bailey-p1-t4-red-ui.log`，`Test-Bailey-UI-2026.10.27_18-59-06-+0800.xcresult`。
- Green：`make test:FileTreeTests,GitGraphPaletteTests,DockWorkspaceTests`，115 tests / 0 failures；
  `/tmp/bailey-p1-t4-host.log`，`Test-Bailey-2026.10.27_19-03-02-+0800.xcresult`。
  6 个视觉标志全部 64 组合 × Light／Dark × 默认／Ayu Light+Dracula 共 256 组，
  同时测中心 fill 与边界 stroke。GitGraphPaletteTests 继续验证全部 60 个主题及原生不重挂载。
- 旧像素夹具用白底却没有固定浅色环境，组合执行时其 Displayed 阈值失败；
  修正夹具的 colorScheme，不放松阈值、不改生产色值；深色由新矩阵独立覆盖。
- GUI：AX、新旧 Files 失焦底色、Graph Light／Dark × Tree／List 与 Worktree 共 7 方法全过；
  `/tmp/bailey-p1-t4-ui.log`，`Test-Bailey-UI-2026.10.27_19-05-00-+0800.xcresult`。
  随后补实际历史 Diff 正文断言，单项再次通过：`/tmp/bailey-p1-t4-ax-ui.log`，
  `Test-Bailey-UI-2026.10.27_19-10-16-+0800.xcresult`。
- Projects 当前项目、Palette 暂态高亮、Ctrl+Tab 候选及标签壳的调用语义逐一核对，未强行套用资源 Selection；
  RowHighlightStyle 生产绘制未改，Settings 未动；`docs/ui.md` 同步。
  Dev build／验签与 diff 检查通过。

## P1-T5

- Red：最初新增 Home／End／Page Up／Down 宿主测试在旧键盘入口失败，
  `/tmp/bailey-p1-t5-red.log`；调整原生宿主夹具后，
  根目录重挂载用例仍失败，`/tmp/bailey-p1-t5-native.log`。
- 根因：SwiftUI 重挂载时，旧 `TreeKeyboardView` 的 `updateNSView`
  可以在新宿主 `makeNSView` 之后运行，旧视图再次写入
  `TreeKeyboardOwner.view`，覆盖仍附着窗口的新宿主。
  删除 `updateNSView` 中冗余的所有权登记，只在 `makeNSView` 登记；
  未新增计时器、重试或窗口级焦点容器。
- 夹具修正：`NSTextField` 不再直接插入 `NSHostingView`，
  而放入共同的 AppKit 容器；重挂载测试明确等待替代宿主进入窗口，
  不再把旧宿主当成有效目标。保留真实 firstResponder／输入保护断言。
- Green：`make test:FileTreeTests,DockWorkspaceTests,PanelContextTests,DockFocusIntegrationTests,GitGraphPaletteTests`，
  **137 tests / 0 failures**，`/tmp/bailey-p1-t5-host.log`；
  含根路径更换、同一 SSH 根重连、空树、80 行、三档字号 × 两种视口高度、
  Home/End 上下界、分页、Selection／Anchor 保持及拒绝不合法输入。
- 补验中文「拼音」及日文「にほんご」原生 marked-text：
  专项宿主 **1 test / 0 failures**，`/tmp/bailey-p1-t5-ime-green.log`；
  这些是原生 field editor 合成组词，不冒充系统中文／日文输入法实机切换。
- GUI：真实中文 Bailey Dev 的 Home/End、连续翻页、滚动可见性、
  不改变 AX Selection、Space 打开实际文件并校验内容，
  **1 test / 0 failures**，`/tmp/bailey-p1-t5-ui-navigation-3.log`。
  首次 Page Down 不必滚走首行：已核对固定版 VS Code 的
  `List.focusNextPage` 先到当前视口末行的语义，
  删除了「第一次必滚动一页」的错误测试预期，未为迁就断言修改生产行为。
- GUI：Palette 取消与恢复、rename/new-file Escape、编辑器与 Terminal 接管、
  Files／Git 切换、亮色失焦选区，
  **5 tests / 0 failures**，`/tmp/bailey-p1-t5-ui-focus.log`。
  中文 Palette 从编辑器交接及两个原生窗口分别保存／恢复输入焦点、
  核对文件字节和跨窗隔离，
  **2 tests / 0 failures**，`/tmp/bailey-p1-t5-ui-windows.log`。
- 一次调试重跑中独立 GUI 启动夹具未出现，随后正式复验成功；
  `/tmp/bailey-p1-t5-ui-diag.log` 是运行环境失败记录，
  不将其计为产品分页行为的 Red 或已修复的产品 bug。
- `make build:dev` 成功，Apple Development 签名通过；
  `/tmp/bailey-p1-t5-build.log`；`git diff --check` 通过。
  `make build` 正式 Debug 成功且完成深度验签；`/tmp/bailey-p1-formal-build.log`。
  以同卷暂存、验签、整包替换更新 `/Applications/Bailey.app`，安装后复验通过，
  主程序与 dylib 的源/目标字节一致，旧包备份已清理；
  原正式进程 PID 24069 未退出或重启。同步 `docs/features/files.md`，
  未引入向后兼容双轨。
- 未核销：macOS 15.6 真机、实际中文／日文系统 IME 组合、实体触控板与
  VoiceOver 真人朗读。当前宿主／GUI 是可执行替代证据，
  不能声称这些物理与旧系统条件也已实测。

## 尚须区分的外部条件

- 当前系统是 27.2，没有可运行的 15.6 macOS 实例；部署目标与 SDK 编译不等于最低系统运行。
  影响原生事件／像素兼容性；需在 15.6 真机补同一宿主与 GUI 测试，不能声称最低系统实测通过。
- 实体触控板、中键和真实 VoiceOver 朗读无法由 XCUI 合成事件证明；
  替代证据为原生点击、键盘、AX 和宿主像素，设备体验仍需人工实测。
- 已安装 VSCodium 1.126.04524，不能当作计划固定 VS Code 提交的运行二进制；
  上游算法以固定源码核对，实际 GUI 结果只归属本轮 Bailey Dev。

以上不是对后续任务的预先跳过；阶段结束逐项补充安全可执行条件及剩余门禁。

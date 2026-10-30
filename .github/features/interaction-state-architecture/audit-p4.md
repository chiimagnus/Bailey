# Audit P4 - interaction-state-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/interaction-state-architecture/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P4-T1 整理 Projects 游标和活动项目
- [x] P4-T2 整理 Dock 标签展示激活和关闭
- [x] P4-T3 整理命令面板与 Ctrl+Tab 临时选择
- [x] P4-T4 实现 Dock 标签多选与范围锚点
- [x] P4-T5 核销多标签批量拖动与 Move 边界
- [x] P4-T6 统一 Dock 标签右键关闭与专属视觉
- [x] P4-T7 统一多窗口多组原生焦点交接

## 审计范围与方法

从固定 VS Code 源码语义、P4 计划、当前实际源码及 Git 提交独立检查，
不继承 P1–P3 或其它历史审计文件的结论。
先沿 View → Project／Window → Dock owner → 原生对象／文件字节阅读实际路径，
再核对有内容的测试断言和真实 App E2E；没有凭测试名称代替结果检查。

## 任务到文件的映射

| 任务 | 实际生产入口与状态所有者 | 重要回归与现行文档 | 实现提交 |
| --- | --- | --- | --- |
| T1 | `ProjectsPanelView` 的 cursor/context/drag、`WorkspaceWindowModel.selectedProjectID` | `WorkspaceIdentityTests`、`WorkspaceDockUITests`；`docs/features/projects.md` | `e4f0231e` |
| T2 | `DockWorkspaceModel` group.selected/root、`Project.selectTab`、`DockTabGroupView`、Settings 布局解析 | `DockWorkspaceTests`、`AppSettingsTests`、Dock GUI；`docs/features/dock.md`、`settings.md` | `d6783953` |
| T3 | `TabSwitcherController`、`WorkspaceWindowModel`、`ContentView`、`CommandPaletteView` | `NativePaneRetentionIntegrationTests`、`WorkspaceIdentityTests`、Palette GUI；`docs/features/command-palette.md` | `b2f79898` |
| T4 | `DockWorkspaceModel.extendedSelections`、`Project.selectTab/closePanels`、`DockTabPointerView`、`TabItemChrome` | `DockWorkspaceTests`、`NativeContentIdentityIntegrationTests`、组选区 GUI；`docs/features/dock.md`、`docs/ui.md` | `3ae33e96`；GUI `d2902830` |
| T5 | `DockTabDragCoordinator`、`DockWorkspaceModel.move/updateLayout`、`Project.movePanels` | `DockWorkspaceTests`、`NativePaneRetentionIntegrationTests`、跨组拖动 GUI；`docs/features/dock.md` | `be19f43b`；GUI `b31fbaef` |
| T6 | `DockWorkspaceModel.commandTargets`、`WorkspaceWindowModel.closePanel`、`Project.closeBatch`、`DockTabGroupView` | `WindowCloseIntegrationTests`、`NativeContentIdentityIntegrationTests`、5 项菜单 GUI；`docs/features/dock.md`、`Interface.xcstrings` | `67f87ec8`；GUI `cedbe306`、`eaa551f8` |
| T7 | `BrowserAddressField`／`BrowserWebViewRepresentable` 原生焦点交接、`DockGroupFocusReader`、窗口归属 | `NativePaneRetentionIntegrationTests`、`DockFocusIntegrationTests`、浏览器／双窗 GUI；`docs/features/browser.md`、`docs/architecture.md` | `60635f9f`；GUI `f2ec9ade`、`84c8ae7b` |

## 实现独立复核

- **T1–T3：** Projects 按现存 UUID 解析游标及 Return／Space，
  后台 Context 不能更改当前项目。Dock 非空组的展示来自合法 `DockGroup.selected`，
  同组选择只经一次 owner 动作，无变化布局不发布额外快照。
  新布局配置不再接受 `info`；只保留旧窗口快照解码时忽略该历史条目。
  Ctrl+Tab 项目切换取消旧预览；Palette 切项目按 UUID 而非捕获数组下标。
- **T4：** 显示标签、当前活动组、组内集合、Anchor 与真实键盘焦点没有合成一个状态。
  Shift 只处理 Tab 的上游范围语义，⌘ 切换集合；AppKit 鼠标按下保留拖动意图，
  未拖动的普通松开才收成单选。AX Selected 和真实 Tab 高亮已连接。
- **T5：** Batch Move 从同一份原 root 对完整组选区操作，
  只提交一次更新；同组 index 折算、边缘新组、原组变空的折叠和取消／无效源／失效目标
  有模型及原生组件用例。PTY／WebView／编辑器原生对象不克隆，
  外部 Finder 投放仍沿原路径，不误传内部 Dock 组选区。
- **T6：** 右键 Context、关闭按钮、中键、主菜单 ⌘W 由同一个组合法目标解析；
  选区内操作批量关闭、集合外仅处理命中对象。
  Close Others 不自动激活后台标签，Close Right 不包含工具。
  保存失败和取消必须保留尚未轮到的浏览器、终端、文件与工具；
  在异步保存等待期间变脏的内容也会先确认。
  NSMenu 跟踪期间的单次按键监听保留现有窗口与启用态核验，
  不额外注册系统快捷键。
- **T7：** Browser 地址栏和 WKWebView 已删除提前确认请求及固定 6×50ms 轮询；
  原生视图挂载、目标窗口成为 key、真正获得第一响应者后才消费请求，
  旧宿主卸载不能清掉新宿主回调；窗口/项目切换失效检查仍由现有 owner 授权。
  未增全局 FocusManager，也未删除仍需服务于通用 AppKit 控件的
  `DockGroupFocusView.containsResponder` 可见范围检查。

**确认保留而非旧债：** `DockSavedItem.info` 的历史数据解码、
文件写入失败和取消确认、窗口／SSH 归属验证、原生焦点停车、
窗口事件菜单边界，以及 Finder 外部投放处理。没有证据支持删除它们。

## 发现项

独立复核当前版本尚未发现符合准入门槛的未解决生产代码 finding。
曾失败的旧 GUI 用例属于测试前提错误，已在正式审计前修正并独立重测；
不把它误报为待处理的 Dock 状态 bug。

## 修复日志

- `eaa551f8`：旧工具菜单用例在滚动窄标签条之前就调用 `git.click()`，
  AppKit 并未选中 Git，后续第二次 ⌘W 实际关闭原活动 Projects。
  修正为先使 Git 的几何中心进入其自身 ScrollView，可见且 AX Selected 才继续，
  继而右键关闭 Files、二次 ⌘W 关闭 Git。
  修复前单项失败，修复后单项通过；同一最终 HEAD 上 5 项菜单 GUI 连跑全通过。
  另一次测试期间曾出现其它 Bailey Graph Dev 的系统崩溃提示，
  但**不能**以其存在解释所有失败：在没有提示时未滚动测试也能稳定失败。
  没有为测试修正增改 Dock 生产分支，也没有更改其它 App 的进程。

## 验证日志

### 已完成的真实执行

- 任务定向：T1 112 宿主／4 GUI，T2 105 宿主／3 GUI，
  T3 93 宿主（1 环境条件跳过）／3 GUI；
  T4 组选区、原生键盘与 AX 宿主和 3 GUI；
  T5 85 宿主、42 项重点复测、真实两标签跨组拖动；
  T6 135 宿主、原生中键专项、真实菜单五项联跑；
  T7 85 跨窗口／原生宿主、21 专项宿主、重复 ⌘L／Palette 与双窗 GUI。
  以上为不同时间点的重叠测试，不得相加当作唯一测试数量。
- `make test:DockWorkspaceTests,WindowCloseIntegrationTests,FileTabPersistenceTests,NativePaneRetentionIntegrationTests,NativeContentIdentityIntegrationTests,DockFocusIntegrationTests,WorkspaceIdentityTests,SessionStoreTests,FinderDeliveryIntegrationTests,AppSettingsTests,ProjectFileIndexTests,WindowOwnershipIntegrationTests`：
  **208 项，207 通过、1 跳过、0 失败**；实际测试套件成功。
- `make test:ui ONLY_TESTING=<五项 Dock 菜单与 ⌘W 方法>`：
  **5 项全部通过，完整退出码 0**；
  包括上文已修正的窄组滚动、后台菜单和组选区关闭。
- `make test:ui ONLY_TESTING=<八项 Dock／Browser／双窗口方法>`：
  **8 项全部通过，完整退出码 0**；
  三文件多选后双标签跨组 Move、Files Auto Reveal、
  WebKit 未提交表单及磁盘字节、双窗地址栏 ⌘L 归属、
  Palette 拿走／归还焦点均检查了真实结果。

- **正式全量：** `make test` 退出码 0，
  `Executed 723 tests, with 15 tests skipped and 0 failures`，
  合计 **708 通过、15 跳过、0 失败**。
  15 项全部是缺乏获授权目标的 Windows SSH 实机用例，涵盖
  Git 交互式 Rebase、远端刷新与写入、文件索引、
  SSH 实际文件树、复制/保存、监控和连接恢复。
  明确环境前提不满足才跳过，不属于生产执行后的失败。
- **正式构建：** `make build:dev` 和 `make build`
  都退出码 0、`** BUILD SUCCEEDED **`；
  `codesign --verify --deep --strict` 对最终两份 App 均通过。
  Bundle ID 分别为 `chiimagnus.bailey.dev`、`chiimagnus.bailey`。
- **本机整包安装：** 将正式 App 在 `/Applications` 同卷暂存，
  验签、原子替换、再验签，失败路径具备恢复旧包能力；
  最终 `/Applications/Bailey.app` 是 **v0.4.0 Build 56**，
  签名有效、临时安装目录和旧包备份均已清理。
  既有正式 Bailey 进程 PID 54502 未被退出、启动或重启；
  仍运行旧代码，需用户自行下次启动才加载新包。

### 实际覆盖的边界

- **集合／索引：** 空／单／多、不连续、Shift 反向 Anchor、
  ⌘ 单项切换、活动 Displayed 与额外 Selected；
  同组插入区间与 index 越界、工具 singleton 混合选区。
- **移动与生命周期：** 四个边缘／空组／中央、跨组来源折叠、
  失效成员和源布局／重复 Drop／取消／失焦／原生重挂载；
  屏幕真实拖动后 Tab 数、UUID、未选项以及文件字节保留。
- **关闭与数据：** 主菜单／右键菜单／中键／按钮、集合内外目标、
  后台右键不激活、保存失败／取消、脏稿与工具混合、
  异步保存期间新变脏的编辑、原生 Session／Browser 保留。
- **焦点与恢复：** 当前窗口真实 firstResponder、多个项目与原生窗口、
  Ctrl+Tab／Palette 取消及迟到操作、WebKit 表单／网页状态、
  TextKit 编辑器与终端对象身份、快照恢复与无效 `info` 配置读写。
- **配置与字节：** 新布局合法/非法字段、加载时不写原 TOML、
  其后修改普通偏好的规范化；本机真实文件、Unicode 内容和
  Git／SSH 后端相关模型不变量；未保存文件失败时不静默覆写。

### 未覆盖及其影响

- **macOS 15.6 的实际机器：** 当前在 macOS **27.2**、
  Xcode **27.2**（Build 27B5038j）上完成自动测试，
  未在最低目标版本启动真实 App。
  已在本机编译目标和现有兼容 API；实际最低版本视觉／窗口事件行为尚不可宣称已验证。
  补验：用 macOS 15.6 真机／CI 的 Dev App 运行 P4 Dock/窗口专测。
- **Windows 实机 SSH 联合 GUI：** 相关受控后端与模拟宿主测试通过，
  但全量宿主有 **15 项独立实机 SSH 环境条件测试跳过**
  （含 `ProjectFileIndexTests.testAuthorizedWindowsSSHProjectIndexGitAndPlainRealFiles`）：
  没有设置对应测试所要求的获授权隔离目标（例如 `BAILEY_P3_TEST_SSH_HOST`）。
  涵盖跨项目文件/Git、重连和监控，不是 P4 标签逻辑执行后的失败；
  不能把这些测试冒充真实跨机 Dock 拖动和断线后的原生焦点验收。
  补验：配置获批准的独立 SSH 目标，运行隔离数据与 E2E，不碰用户现有 SSH master。
- **物理中键、触控板、多语言 IME、VoiceOver、高对比与特殊尺寸设备：**
  已由真实 App 的修饰键/窄宽标签条、AX Selected、AppKit 合成中键、
  原生 TextKit 控件宿主、中文字符串和 SwiftUI 状态逻辑覆盖可自动核验部分；
  未在对应专用硬件／辅助功能模式上逐项人工操作。
  补验：真实中键及触控板拖动、高对比／深色外观、中文 IME 候选与 VoiceOver 实际朗读；
  不把默认系统主题的 E2E 冒称全部外观组合。

### 现行文档与删除边界

已核对 `docs/features/projects.md`、`dock.md`、`browser.md`、
`settings.md`、`command-palette.md`、`docs/ui.md` 与 `docs/architecture.md`。
功能页说明当前状态真源、范围与真实文件／原生保留不变量；
P4 实现已移除静默 `info` 新布局接受、重复工作标签选择、
固定焦点轮询及反复触发单项布局 Move 的旧路径。
测试文件和新增本地化字符串均由现行编译与 XCTest 引用，不是脱离生产功能的占位。
尚未给最低系统／SSH 真机等未执行场景贴已通过标签。

## Gate（是否允许进入下一阶段）

- 结论：**Go（P4 通过，可进入 P5）**。
- 理由：P4-T1–T7 的实现、删旧、当前文档、独立提交和 `todo.toml`
  已完成并可追溯；`phase-complete --phase p4` 通过。
  当前本机安全可执行的 **723 项完整宿主、13 项核心 GUI**、
  Dev／正式构建、签名与整包安装均已验收通过；
  未发现未解决、经真实路径证实的 P4 生产 finding。
  不具备最低系统／独立 Windows SSH／特殊物理辅助设备的执行环境，
  相关结果明确不属于已通过范围，对本机 P4 Gate 不构成阻塞。

## 最终状态与剩余风险

- 当前状态：**Resolved**。
- 剩余风险：最低 macOS 15.6 真机、获授权 Windows SSH 实机联合 GUI、
  物理中键／触控板、中文 IME 候选、VoiceOver 与高对比等设备级验收尚未执行。
  这些不应被本机自动测试覆盖结论替代；已在上文给出明确补验路径。
  当前本机已复现的 P4 用户路径没有尚待修复的生产缺陷。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

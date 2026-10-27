# Audit P1 - interaction-state-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/interaction-state-architecture/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 修正不连续选择的锚点范围扩选
- [x] P1-T2 树刷新与折叠保持稳定身份
- [x] P1-T3 统一紧凑目录分段与命中区域
- [x] P1-T4 对齐共享树行视觉与无障碍状态
- [x] P1-T5 统一树键盘焦点与原生输入交接

## 任务到文件的映射

- P1-T1：`Bailey/Files/FileTreeModel.swift`（selectRange／moveSelection）、
  `BaileyTests/Files/FileTreeTests.swift`、`BaileyUITests/Files/WorkspaceFilesUITests.swift`、
  `docs/features/files.md`；提交 `2d23de91`。
- P1-T2：`FileTreeModel.swift`（sync／rebuild／remapPaths）、
  `BaileyTests/Files/{FileTreeTests,SSHFileTreeLiveTests}.swift`、
  `docs/features/files.md`；提交 `209ce031`。
- P1-T3：`Bailey/Shared/Tree/TreeRowStyle.swift`（TreeCompactSegment）、
  `Bailey/Files/FileTreePanel.swift`、`Bailey/Git/{GitPanel,RecentCommitsView}.swift`、
  `BaileyUITests/Files/SharedTreeUITests.swift`、`docs/features/{files,git}.md`；
  提交 `7fc68f08`。
- P1-T4：`TreeRowStyle.swift`（RowHighlightStyle／TreeFileRow／TreeFolderRow）、
  `FileTreePanel.swift`、`GitPanel.swift`、`BaileyTests/Files/FileTreeTests.swift`、
  `BaileyUITests/Git/GitChangesUITests.swift`、`docs/ui.md`；
  提交 `eed33ff7`。
- P1-T5：`FileTreePanel.swift`（FileTreeScrollView）、
  `TreeRowStyle.swift`（TreeKeyboardHost）、`FileTreeTests.swift`、
  `WorkspaceFilesUITests.swift`、`docs/features/files.md`；
  提交 `2af17ba`。

## 发现项

## 发现 F-03

- 任务：`P1-T5`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`Bailey/App/WorkspaceApplication.swift:486`、`Bailey/App/BaileyApp.swift:17`、`BaileyUITests/Support/WorkspaceUITestSupport.swift:91`
- 摘要：`初始 WindowGroup、系统场景恢复、应用快照恢复与测试补窗存在重复开窗路径`
- 风险：`独立 GUI 记录实际包含 29 个窗口，仅 1 个加载预载项目；同一隔离运行对应的 SessionStore 并无 29 个待恢复窗口。测试等待首窗仅 1 秒后发出 ⌘⇧N 也可能与系统首窗竞争。`
- 预期修复：`复用已有 didReopenWindows 与窗口登记，在首个 scene 出现前不抢建窗口；已登记而未附着时不误判无窗口；保留用户主动新窗与正常重启恢复`
- 验证：`WindowOwnershipIntegrationTests/testPendingFolderDoesNotOpenSecondWindowWhileFirstSceneIsRegisteredButUnattached；WorkspaceSmokeUITests/testPreloadedProjectLaunchCreatesOneMainWindow；WorkspaceWindowsUITests 双窗；Xcode 27.2 启动器目前发生 childPID 内部错误`
- 解决证据：`提交 db470062 已避免首 Scene 未登记时抢建窗口；提交 fe77590b 在系统 Scene 边界明确默认呈现首窗并关闭 SwiftUI 自动 Scene 恢复，仅由 WorkspaceApplication/SessionStore 恢复其它窗口，同时删除 UI Runner 的 1 秒后快捷键补窗和重启补窗旧路径。make build:ui、make build（深度验签）、git diff --check 通过。隔离 Bailey Dev 真实 GUI 通过预载项目单窗（AX 包含 startup.txt）、明确新建双窗、关闭其中一窗、全部关闭后重新打开并恢复原项目/文件；/tmp/bailey-p1-f03-reopened-tree.json。Xcode 27.2 在 UI 测试枚举、跳过枚举直接 test、宿主 WindowOwnershipIntegrationTests 均于测试开始前报 IDELaunchServicesLauncher childPID > 0，日志 /tmp/bailey-p1-f03-ui-test.log、/tmp/bailey-p1-f03-ui-no-enumeration.log、/tmp/bailey-p1-f03-host-final.log；独立 GUI 证据不能替代 XCTest，Gate 仍 No-Go。`


## 发现 F-02

- 任务：`P1-T5`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`BaileyUITests/Files/WorkspaceFilesUITests.swift:1152`
- 摘要：`连续 Page Down 在整组 GUI 运行中未满足实际滚动验收，单项通过但组内不稳定`
- 风险：`组内至少一次连续分页后首行仍被判定可点击；修正为可见几何断言后重测被 GUI 启动／辅助功能匹配故障阻断，无法排除产品交互或运行器时序问题`
- 预期修复：`在可用的隔离 GUI 会话中记录两次按键后的焦点行与视口坐标，区分真实滚动失效和 AX 快照失效；只修复有证据的根因，不增加延迟补丁`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests/testHomeEndAndPageKeysScrollFocusedFilesWithoutOpeningOrSelectingThem，及与其他 UI 用例的联合运行`
- 解决证据：`原生 NSScrollView 连续分页的真实视口位移已有 1/0（/tmp/bailey-p1-independent-audit-t5-native-scroll.log）；正式单项 GUI 曾 1/0（/tmp/bailey-p1-t5-ui-navigation-3.log），联合 GUI 中的首行 isHittable 断言失败（/tmp/bailey-p1-independent-audit-ui.log）。已改为行几何位移断言，但后续 GUI 仍因窗口/AX 问题未运行到断言。检查 FileTreeModel.moveSelection → FileTreeScrollView.onChange(scrollTo) 与原生 TreeKeyboardHost 后，尚无证据证明生产 PageDown 错误；不要仅凭 AX 失败调整滚动行为。Xcode 27.2 启动器继续阻断补验，保留 Open，待同一独立 GUI 会话内核对真实焦点、两次 PageDown 的焦点路径和首行视口坐标后决定是否需要生产修复。`


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:835`
- 摘要：`SSH 新连接目录尚未验证时 Copy/Paste 与创建仍能写入旧行目标`
- 风险：`同一远端重新连接后根目录列举失败但 stat/copy/create 可用时，旧快照行仍可能向变更过的远端路径写入新文件，违背 P1-T2 的未核验只读边界`
- 预期修复：`复用现有 canMutateCurrentFiles，在所有文件修改入口统一阻断未核验通道，不引入新连接状态或 fallback`
- 验证：`FileTreeTests/testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot 的 Red/Green 与真实文件字节、随后恢复可写；相关 host/GUI 回归`
- 解决证据：`修正 mock pwd -P 后旧代码 Red 7 failures：/tmp/bailey-p1-independent-audit-f01-red2.log；统一 guard 后 Green 1/0：/tmp/bailey-p1-independent-audit-f01-green.log，真实复制/文件/目录字节和重连恢复写入；原生 Files 87/0；GitWorkspace 5/0，GitUncommitted 4/0；Dev/正式 Debug 编译验签通过；commit 4274b5cb99a7038b263a9f5746f9899842840f60。Windows live 验证因 Xcode launcher internal error 未启动，另列环境缺口。`


- 本轮仅将真实写入 Red 与未核销的实际 GUI 验收列为发现项，不将猜测记为缺陷。

## 本轮独立逐提交复核（不采用旧审计结论）

本轮从 `todo.toml`、五个原始 commit diff、当前 CodeGraph 调用链和独立运行结果重新取证。

| Task | Commit | 生产链与旧实现清理 | 独立结论 |
| --- | --- | --- | --- |
| P1-T1 | `2d23de91` | `FileTreeRow.selectForClick → FileTreeModel.select/selectRange`；`handleKey → moveSelection`，鼠标连续岛与键盘单步增减独立；旧通用范围算法已替换 | 已接入，未发现新缺陷 |
| P1-T2 | `209ce031` | `Project.syncFiles → FileTreeModel.sync/rebuild/remapPaths`；旧展开路径重复映射已删除；重连旧快照保留但旧拖放失效 | 发现 F-01：复制／新建曾绕开未核验写入门禁；`4274b5c` 已修复 |
| P1-T3 | `7fc68f08` | `TreeCompactSegment` 被 Files、Git Changes、History／Worktree 实际使用，分段 `path` 传至菜单、复制和 Git index 操作；Files 重复悬停段和 index=0 fallback 已删除 | 已接入；真实 Git 文件／index 结果已验 |
| P1-T4 | `eed33ff7` | `TreeFileRow/TreeFolderRow` 的 AX selected 仅来自 Selection，不再用焦点冒充；`RowHighlightStyle` 的 Hover/Displayed/Context 各自作用 | 已接入；明暗主题、AX 和组内失焦核对；图谱像素宿主测试出现时序不稳定 |
| P1-T5 | `2af17ba3` | `FileTreeScrollView.handleKey → moveSelection`；SwiftUI 视口更新和原生 `TreeKeyboardHost`；旧宿主 `updateNSView` 不再抢键盘所有权 | 已接入；原生连续分页及实际滚动位置通过，GUI 整组分页回归仍有 F-02 |

没有以“代码有 guard”为由删掉本机/SSH 边界、文件字节保护、
未保存编辑器、field editor／IME 和正在使用的原生菜单生命周期。
本轮只删除了已证明错误的 Copy 特例，没有新增兼容分支或备用协调器。

### 本轮独立测试与局限

- 修复前：`make test:FileTreeTests,PanelContextTests,GitGraphPaletteTests,DockWorkspaceTests,DockFocusIntegrationTests,AppIdentityTests`
  **145/0**，日志 `/tmp/bailey-p1-independent-audit-host.log`。
- F-01：正确模拟 `pwd -P` 后，旧实现 **Red 7 failures**，
  `/tmp/bailey-p1-independent-audit-f01-red2.log`；
  修改后 **Green 1/0**，`/tmp/bailey-p1-independent-audit-f01-green.log`；
  验证未核验期间 Copy／Create 拒写、重连成功后实际恢复 Copy／Create，
  并核对文件内容与目录存在。
- 修复后：8 类宿主测试共 **154 项，2 次失败断言**，
  其余均通过；失败全部来自 `GitGraphPaletteTests` 图谱主题重绘等待，
  单独重跑该方法 **1/0**。日志
  `/tmp/bailey-p1-independent-audit-fix-host.log`、
  `/tmp/bailey-p1-independent-audit-theme-solo.log`。
  不能将两次条件超时抹成“154 项全部通过”。
- P1-T5 连续两次分页的原生 NSScrollView 实际可见偏移测试 **1/0**，
  `/tmp/bailey-p1-independent-audit-t5-native-scroll.log`。
- 本轮 GUI 联合运行 **12 项／2 失败**：
  一项 Files 压缩段因初始测试窗口缺失失败，
  一项连续 PageDown 的 `isHittable` 断言失败；
  其余 10 项（含真实 Git index、亮暗、Selection、分屏与双窗口）通过。
  `/tmp/bailey-p1-independent-audit-ui.log`。
  已改为实际坐标滚动断言，但新一轮 **2 项均在 UI 元素匹配阶段失败**，
  未执行到滚动；`/tmp/bailey-p1-independent-audit-ui-recheck.log`。
  此处不能认定真实交互已回归完整。
- Windows SSH 实机回归使用文档授权的独立 `windows` 主机参数，
  两次均在 `xcodebuild -enumerate-tests` 期间触发 Xcode 27.2
  `IDELaunchServicesLauncher childPID > 0` 内部断言，**没有进入测试**。
  日志 `/tmp/bailey-p1-independent-audit-f01-ssh-live.log` 及
  `/tmp/bailey-p1-independent-audit-f01-ssh-live-retry.log`；
  不能冒充 SSH 实机验证通过。此前 P1-T2 的历史 3/0 不能取代新修复后的复验。
- `make build:dev`、`make build` 均退出 0，
  正式构建完成 `codesign --verify --deep --strict`。
  安装到 `/Applications/Bailey.app` 后重新验签，并比对主程序与 dylib 字节；
  未退出或重启用户运行中的 App。
  日志 `/tmp/bailey-p1-independent-audit-dev-build.log`、
  `/tmp/bailey-p1-independent-audit-formal-build.log`。

## 修复日志

- P1-T5 执行期间已通过实际 Red→Green 修复重挂载的旧原生键盘宿主
  覆盖新所有权问题：删除 `updateNSView` 重复登记，保留
  `makeNSView` 唯一登记；对应提交 `2af17ba`。
- 本轮独立复核新增 F-01，修复提交 `4274b5cb`：旧的 Copy 特例被删除，
  未核验连接上的所有文件修改入口复用已有门禁；相应宿主测试、
  原生滚动断言及 Files 功能文档已同步。五个原任务提交未改写，
  没有向 P2/P3/P4/P5 扩大范围。

## 验证日志

- P1-T1：`make test:FileTreeTests` **84/0**，
  以及真实修饰键与右键 GUI **1/0**；6 行全部 64 种 Selection
  ×6 Anchor×6 Target，前后方向与实际复制字节；见 `evidence-p1.md#p1-t1`。
- P1-T2：`make test:FileTreeTests,PanelContextTests` **103/0**，
  获授权的真实 Windows SSH **3/0（0 skipped）**，隐藏／Reveal GUI **1/0**；
  验证同根重连失败保留、晚到结果隔离、1000+／Unicode、
  删除折叠路径与真实文件操作；见 `evidence-p1.md#p1-t2`。
- P1-T3：`make test:FileTreeTests,GitGraphPaletteTests` **90/0**，
  三类 Git 树与 Files 压缩路径 GUI **4/0**；
  精确分段右键、复制、stage、根目录与真实 index/文件字节；
  见 `evidence-p1.md#p1-t3`。
- P1-T4：`make test:FileTreeTests,GitGraphPaletteTests,DockWorkspaceTests`
  **115/0**，真实 AX/亮暗主题／Graph／Worktree GUI **8/0**；
  6 旗标 × 两种外观 × 两套主题共 256 组像素，
  及 60 个主题变化；见 `evidence-p1.md#p1-t4`。
- P1-T5：`make test:FileTreeTests,DockWorkspaceTests,PanelContextTests,DockFocusIntegrationTests,GitGraphPaletteTests`
  **137/0**，中文／日文合成 marked-text 专项 **1/0**；
  原生 GUI 导航 **1/0**、Palette／rename／Terminal／编辑器／亮色 **5/0**、
  中文命令面板／双原生窗口 **2/0**；所有 Git/文件真实副作用及
  独立窗口字节已断言；见 `evidence-p1.md#p1-t5`。
- `make build:dev`、正式 `make build`、Apple Development 签名及
  `codesign --verify --deep --strict`、`git diff HEAD --check` 全部通过。
  `/Applications/Bailey.app` 已经同卷整包替换并复验二进制字节一致，
  原 PID 24069 未退出/重启，旧包备份清理完成；
  P1 实际运行日志在 `evidence-p1.md` 按任务记录。
  不把失败的第一次 GUI 夹具或错误的 PageDown 断言作为产品修复证据。
- 核对生产链：Selection／Anchor 不等于焦点、Context Target 不打开文件、
  Show／Expanded 根范围隔离、紧凑段携带真实路径、AX Selected 只表达
  Selection、原生 firstResponder 不被不可见树/旧宿主复写。
  `docs/{architecture,ui,testing,development}.md` 的既有职责不改变；
  Files／Git 局部文档与本阶段实际代码一致，无多余双轨兼容入口。

### 环境与极端条件核销

- **已执行**：Apple Silicon／macOS 27.2／Xcode 27.2，Development 签名，
  英文／简中真实 App，亮／暗与多主题，三档字号×两档视口，
  0/1/80/1000+ 行、Unicode／深目录／过滤／压缩／长横向滚动，
  Shift／⌘／多选／边界钳制，菜单取消／改名／新建／Palette／编辑器／
  Terminal／Git／两窗口，异常晚到／断线／同根替换，
  真实本机与授权 Windows SSH 文件副作用。
- **未实测：macOS 15.6**（没有对应真机／VM）：
  原生键盘、SwiftUI 滚动与 AX 仍存在旧系统兼容风险；
  当前 SDK 编译不可取代最低系统验证。
  补验：15.6 真机执行 P1 文件树宿主和导航／焦点/AX GUI。
- **未实测：实体触控板中键、VoiceOver 真人朗读**（当前未提供硬件／辅助功能人工环境）：
  可能存在手势／朗读呈现差异；原生事件、XCUI AX、像素替代测试已通过。
  补验：实体设备逐项手动验收，记录焦点/Selection/Context 的实际声音与视觉。
- **未实测：实际中文／日文系统输入法组合**（未切换用户系统输入源）：
  真实 IME 面板和复杂候选交互未获得系统级证明；
  AppKit field editor 的中日 marked-text 合成及真实中英界面已通过。
  补验：具备输入源的隔离图形会话下验证组词期间导航不截获、不损坏编辑内容。
- **未实测：Windows 原生软链接创建权限分支**（远端拒绝创建）：
  本机链接、硬链接与远端普通文件通过，不声称全部远端符号链接情况通过。
  补验：具备相应权限的隔离 Windows 账号下重跑既有 SSH LiveTests。
- **未实测：Windows SSH 真实断网与两窗口 GUI 的合成组合**
  （单项连接隔离／宿主、双本机窗口 GUI 均已测；未破坏用户 SSH master）：
  在跨窗连线切换时可能存在额外时序风险。
  补验：隔离 SSH master 与专属 Windows 沙盒中同时运行真实双窗断线恢复。
- **本轮基础设施／GUI 记录**：新出现初始窗口缺失、AX 匹配错误、
  Xcode `childPID > 0` 内部断言以及分页合并运行不稳定。
  前三项有明确运行器证据，不等同于生产缺陷；分页场景仍需区分。
- **Gate 影响**：即使忽略没有设备的 15.6／触控板等条件，
  当前仍有 F-02 和可执行 GUI／SSH 补验未核销，不能按旧日志给出 Go。

## Gate（是否允许进入下一阶段）

- 结论：**No-Go（本轮独立审计未完成全部门禁）**
- 理由：P1-T2 的实际写入缺陷已修复并验签安装，但 P1-T5 的联合 GUI 滚动验收 F-02
  仍未确定根因；XCTest 启动／AX 故障阻断补验，真实 Windows SSH 测试在 Xcode 内部崩溃时未开始。
  不因已有阶段已标记完成或旧审计为 Go 而放行下一阶段。

## 最终状态与剩余风险

- 当前状态：**Open（F-01 已解决；F-02 未核销）**
- 剩余风险：连续分页的整组 GUI 结果尚待确认，Xcode 27.2 的 App/UI 启动不稳定、
  修复后的 Windows SSH 实机测试未执行；macOS 15.6、真实中日系统 IME、
  实体触控板／VoiceOver、远端软链接及 SSH 断网×双窗联合 GUI 仍待专用环境补验。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


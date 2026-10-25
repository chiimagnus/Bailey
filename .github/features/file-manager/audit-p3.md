# Audit P3 - file-manager

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/file-manager/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 Files 隐藏规则及设置持久化
- [x] P3-T2 扩展 Cmd+P SSH 文件快速打开
- [x] P3-T3 定位当前文件并保护机器身份

## 任务到文件的映射

- **P3-T1 `c8d9f70`**：`Bailey/App/{AppSettings,SettingsView}.swift`、`Bailey/Files/{FileTreeModel,FileTreePanel}.swift`、FileTree/AppSettings 测试、Settings/Sidebar 中文资源及 `docs/features/{files,settings}.md`。
- **P3-T2 `59ae5ac`**：`Bailey/Workspace/{ProjectFileIndex,Project,LocalWorkspaceBackend}.swift`、`Bailey/UI/CommandPaletteView.swift`、ProjectFileIndex 测试、Interface 中文资源及 `docs/features/{command-palette,ssh}.md`。
- **P3-T3 `1ab3053`**：`Bailey/Files/FileTreeModel.swift`、`Bailey/UI/WorkspaceDockView.swift`、`Bailey/Workspace/WorkspaceWindowModel.swift`、FileTree 测试及 `docs/features/{files,editor}.md`。

## 发现项

## 发现 F-05

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/ProjectFileIndex.swift:46`
- 摘要：`SSH 快速索引仅通过字符串相等阻止 HOME 和根目录，规范路径及软链接别名可绕过`
- 风险：`项目目录被设为远端 HOME/、HOME/.、符号链接至 HOME 或 // 时可能扫描整份账户或文件系统，造成大量远端 IO 与无关文件结果`
- 预期修复：`对限制目录比较远端物理路径，避免通过本机路径规范化误处理其他机器的路径；保持现有文件索引身份`
- 验证：`make test:ProjectFileIndexTests`
- 解决证据：`提交 1d5c738；隔离 SSH runner 模拟 HOME/.、HOME 软链接别名及 //，旧实现 Red 3 次；改为同一远端命令查询 cwd/HOME 物理路径并拒绝等价根目录后 Green；联合宿主 123 项全部通过，无实际 HOME 扫描。`


## 发现 F-04

- 任务：`P3-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:124`
- 摘要：`本机有效的文件符号链接无法定位到 Files`
- 风险：`已打开的本机文件软链接在 FileTab 中正常存在，却因本机 stat 的 isRegular 为 false 被 Reveal 拒绝；同种 SSH 软链接行为不同`
- 预期修复：`定位时将已存在且实际指向普通文件的本机软链接视为可定位文件，继续拒绝失效或非普通文件链接与越根目录路径`
- 验证：`make test:FileTreeTests,ProjectFileIndexTests`
- 解决证据：`提交 6de79e5；新增 FileTreeTests.testRevealLocalFileSymlinkSelectsItsOwnRowAndRejectsInvalidTargets 先 Red（3 条断言失败），修复后 make test:FileTreeTests 68 项全部通过；本机有效链接定位自身行，失效/目录/越根链接仍拒绝。`


## 发现 F-03

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/ProjectFileIndex.swift:162`
- 摘要：`非 Git SSH 文件索引一次目录列举未受输出上限保护`
- 风险：`单个超大目录的 SSH 列举结果会在结果数量上限检查前全部经网络收集并驻留内存，可能导致高内存占用或长时间阻塞`
- 预期修复：`只为远端文件索引对目录批量列举加远端字节上限，沿用既有目录解析和不完整结果提示，不改变普通 Files 树读取`
- 验证：`make test:ProjectFileIndexTests,RemoteCommandsTests`
- 解决证据：`提交 1d5c738；新增 SSH 虚拟 runner 测试，旧实现 Red：远端目录缺限额时报 unavailable；改为远端执行 head 截断并复用 Git 统一校验后 Green，正向目录与 Unicode 路径用例通过；本次 make test:ProjectFileIndexTests,RemoteCommandsTests,AppSettingsTests,PanelContextTests,FileTreeTests 123 项通过。`


## 发现 F-02

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Workspace/ProjectFileIndex.swift:loadRemote;Bailey/UI/CommandPaletteView.swift`
- 摘要：`Windows MSYS2 real SSH index and reconnect require authorized temporary host`
- 风险：`Mac POSIX real files and mocked SSH runner tests do not verify Windows MSYS2 remote HOME, UTF-8 NUL Git, latency, disconnect and actual FileTab destination`
- 预期修复：`Use approved Windows SSH test connection and temp repo under isolated user to verify bounded Git index, nongit fallback, errors, disconnect, reconnect and opened tab identity; never borrow active user master`
- 验证：`make test:SSHFileTreeLiveTests`
- 解决证据：`2026-10-26：真实 Windows/MSYS2 经 Mac SSH 直连完成 testAuthorizedWindowsSSHProjectIndexGitAndPlainRealFiles 1/1 通过（43.161s），验证 Git tracked/untracked/ignore、中文/Emoji、非 Git 文件、HOME 限制、测试专属 master 断开后重连、读删及清理；同机 Bailey Dev testAuthorizedWindowsSSHCommandPaletteOpensRealRemoteFiles 独立完整通过（108.004s；联合复跑 99.177s），验证 Git/非 Git 项目的 Cmd+P 文件标签、Windows 实际字节、Finder 远端禁用、Reveal 选中及本机同名文件不改动，提交 6176600。待补：完整 Bailey Dev 在真实 SSH 控制链路断开、重连后的同一文件标签恢复 UI 联合路径；原生 XCTest 沙盒内关闭 Dev master 返回 255，不能把宿主 reconnect 与正常 UI 组合等同该场景。证据 build/p3-live-host-execution-retry.log 与 build/p3-ui-final-test.log。`


## 发现 F-01

- 任务：`P3-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/App/SettingsView.swift:FileManager;Bailey/Files/FileTreePanel.swift`
- 摘要：`Settings Exclude and File tab reveal native GUI E2E requires macOS Automation Mode authorization`
- 风险：`Host tests verify glob, disk, tree and async selection but not actual Settings Form, mouse menu, scrolling, native focus, Chinese/English or Accessibility`
- 预期修复：`When the user can authorize Automation Mode, run isolated Bailey Dev E2E for Settings File Manager apply/restore, excluded show, right-click reveal and Mac Finder gating`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests`
- 解决证据：`2026-10-26：隔离签名 Bailey Dev 的 testRealSettingsExcludeAndFileTabRevealHiddenRow 完整通过（80.747s；联合重跑 78.755s）。真实 Settings 表单应用/拒绝无效 Glob、持久化/恢复默认、隐藏/临时显现目录、从 FileTab 右键 Reveal 选中对应行、本机 Finder 菜单存在、内容原始字节保持；提交 6176600。日志 build/p3-ui-specialized-test-2.log / build/p3-ui-final-test.log。尚未验证 Finder 实际打开窗口、macOS 15.6/触控板/VoiceOver，见最终状态。`




## 修复日志

- `c8d9f70`：替换硬编码 `.git` 隐藏，Files 的 Glob 规则只在写盘成功后生效，隐藏／恢复可复用已读目录缓存。
- `59ae5ac`：SSH `⌘P` 复用远端 Git／目录后端、NUL 文件名解析和扫描预算；断线拒绝本机回退，删除旧 `Project.panelRoot` 同步路径。
- `1ab3053`：标签定位展开并选中本机／SSH Files 的同机文件，必要时临时显示排除项，远端标签不提供 Finder；修复在途刷新期间定位的等待竞态。
- `6de79e5`（本轮 P3-T3）：允许 Files 定位根目录内的有效本机文件软链接，仍拒绝失效、目录与越界链接。
- `1d5c738`（本轮 P3-T2）：SSH 非 Git 目录列表在远端限流；在同一次远端命令中比较项目与 HOME 的物理路径，拒绝路径别名绕过。
- `dff9512` 属后续 P4-T1：外部变化使已打开 ⌘P 索引失效，固定 SSH 重连废弃旧结果。
- `6176600`（本轮 P3）：增加真实 Windows SSH 索引及隔离 Bailey Dev 的 Settings／⌘P／文件定位 E2E；仅 Files 临时显示菜单新增无障碍标识。

## 验证日志

- **P3-T1**：FileTree／AppSettings／PanelContext 宿主 62 项全部通过；`make build:dev` 签名成功，`make build:ui` 仅构建成功。验证默认 `.git`、显式 `[]`、Glob／Unicode、无效值、写入失败不更新有效规则、缓存隐藏与恢复。
- **P3-T2（初始验收）**：ProjectFileIndex／PanelContext／RemoteCommands 宿主 42 项全部通过；`make build:dev` 签名成功。验证本机 Git tracked/untracked、受控远端 Git/NUL、非 Git 回退、断连及权限错误、超限与目录软链接；真实 Windows 当时未测，见下方补验。
- **P3-T3**：文件树／面板／文件标签／身份宿主 115 项全部通过，文件树竞争补测 43 项通过；Dev 签名与 UI 目标仅构建成功。验证临时显现隐藏祖先、目录链接越界拒绝、目标失效和刷新在途后的正确选择。
- **本轮独立验证（2026-10-26）**：新增 P3-T3 文件链接回归先 Red（3 条断言失败），再执行 `make test:FileTreeTests`，68 项通过；P3-T2 超大非 Git 目录先 Red（旧实现错误分类），远端 HOME／根目录别名先 Red（3 次），修复后执行 `make test:ProjectFileIndexTests,RemoteCommandsTests,AppSettingsTests,PanelContextTests,FileTreeTests`，123 项通过，零失败。包含正向 SSH 目录 NUL／Unicode 列表、SSH Git、权限及断连、Settings 写盘及缓存、文件树竞争；验证产物见 `build/DerivedData-Dev/Logs/Test/`（当地时间 00:31 与 00:41）。
- **真实 Windows SSH（2026-10-26）**：使用独立 SSH master 和专属 `/tmp/bailey-p3-*` 目录；`testAuthorizedWindowsSSHProjectIndexGitAndPlainRealFiles` 通过（1/1，43.161 秒），覆盖 Git／非 Git、Unicode、忽略规则、HOME 限制及 master 关闭后重连。测试产生的 Windows 临时目录已核实清理。
- **隔离 Bailey Dev（2026-10-26）**：Settings 修改／恢复排除规则与隐藏文件定位 E2E 通过；真实 Windows Git／非 Git 文件从 ⌘P 打开、核对远端实际字节、远端禁用 Finder 及 Reveal 选中对应行 E2E 通过；中文界面焦点恢复通过。首次联合 4 项有 3 项通过，暗色共享树测试把“行选中”误认为“键盘焦点”；修正与源码不变量冲突的旧断言后，暗色／亮色两个共享树原生回归分别通过（2/2，`build/p3-final-shared-tree-test.log`），没有将此前联合失败误报为全组通过。
- **剩余验证**：同一 Bailey Dev GUI 在真实 SSH master 断开→重连之后恢复文件标签的完整组合未验证（原生 UI 测试进程不能关闭另一 App 的 master）；Finder 实际唤起窗口、macOS 15.6、物理触控板与 VoiceOver 未实际覆盖。F-01 已核销，F-02 保持 Deferred；以上不冒充全条件通过。
- 文档按实际业务归属更新：`docs/features/{files,settings,command-palette,ssh,editor}.md`。

## Gate（是否允许进入下一阶段）

- **结论：Go（允许继续 P4）；完整环境与 SSH 断连→重连 GUI 联合验收仍为 No-Go。**
- **理由**：三个 P3 task 已核对真实生产调用链；F-03 至 F-05 原有根因修复回归通过，F-01 已经真实 Settings／Files UI E2E 核销。Windows/MSYS2 SSH 索引、重连及实际 GUI 文件打开分别通过；F-02 所要求的同一 GUI 断连恢复组合尚未核销，不能将独立两层结果当作完整验收。

## 最终状态与剩余风险

- **当前状态：P3 正常路径已通过真实 GUI 与 Windows SSH；F-02 仍 Deferred。**
- **剩余风险**：同一个 Bailey Dev 窗口的 SSH 断开／恢复完整交互、macOS 15.6、真实 Finder 副作用、触控板与 VoiceOver 尚缺直接证据；必须按场景单独核销，不能泛称全量通过。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


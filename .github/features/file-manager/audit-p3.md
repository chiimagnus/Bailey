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

## 发现 F-02

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Workspace/ProjectFileIndex.swift:loadRemote;Bailey/UI/CommandPaletteView.swift`
- 摘要：`Windows MSYS2 real SSH index and reconnect require authorized temporary host`
- 风险：`Mac POSIX real files and mocked SSH runner tests do not verify Windows MSYS2 remote HOME, UTF-8 NUL Git, latency, disconnect and actual FileTab destination`
- 预期修复：`Use approved Windows SSH test connection and temp repo under isolated user to verify bounded Git index, nongit fallback, errors, disconnect, reconnect and opened tab identity; never borrow active user master`
- 验证：`make test:SSHFileTreeLiveTests`
- 解决证据：`No authorized disposable Windows SSH test host in current environment; remote-command fake and local POSIX file fixtures passed 42 targeted host tests, production 59ae5ac and reconnect dff9512 have not been live-tested.`


## 发现 F-01

- 任务：`P3-T1`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/App/SettingsView.swift:FileManager;Bailey/Files/FileTreePanel.swift`
- 摘要：`Settings Exclude and File tab reveal native GUI E2E requires macOS Automation Mode authorization`
- 风险：`Host tests verify glob, disk, tree and async selection but not actual Settings Form, mouse menu, scrolling, native focus, Chinese/English or Accessibility`
- 预期修复：`When the user can authorize Automation Mode, run isolated Bailey Dev E2E for Settings File Manager apply/restore, excluded show, right-click reveal and Mac Finder gating`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests`
- 解决证据：`User absent, explicitly postpones biometric/password-gated GUI automation; c8d9f70 and 1ab3053 host suites 62, 115, 43 passed, Dev and UI build-only pass; actual native interaction not run.`




## 修复日志

- `c8d9f70`：替换硬编码 `.git` 隐藏，Files 的 Glob 规则只在写盘成功后生效，隐藏／恢复可复用已读目录缓存。
- `59ae5ac`：SSH `⌘P` 复用远端 Git／目录后端、NUL 文件名解析和扫描预算；断线拒绝本机回退，删除旧 `Project.panelRoot` 同步路径。
- `1ab3053`：标签定位展开并选中本机／SSH Files 的同机文件，必要时临时显示排除项，远端标签不提供 Finder；修复在途刷新期间定位的等待竞态。
- `dff9512` 属后续 P4-T1：外部变化使已打开 ⌘P 索引失效，固定 SSH 重连废弃旧结果。

## 验证日志

- **P3-T1**：FileTree／AppSettings／PanelContext 宿主 62 项全部通过；`make build:dev` 签名成功，`make build:ui` 仅构建成功。验证默认 `.git`、显式 `[]`、Glob／Unicode、无效值、写入失败不更新有效规则、缓存隐藏与恢复。
- **P3-T2**：ProjectFileIndex／PanelContext／RemoteCommands 宿主 42 项全部通过；`make build:dev` 签名成功。验证本机 Git tracked/untracked 范围，受控远端 Git/NUL、非 Git 回退、断连及权限错误、超限与目录软链接；真实 Windows 未测。
- **P3-T3**：文件树／面板／文件标签／身份宿主 115 项全部通过，文件树竞争补测 43 项通过；Dev 签名与 UI 目标仅构建成功。验证临时显现隐藏祖先、目录链接越界拒绝、目标失效和刷新在途后的正确选择。
- **GUI 延期**：原生 Settings、⌘P、文件标签右键、Finder 实际副作用和真实滚动／焦点未执行完整 E2E。用户不在电脑前，无法通过 macOS Automation Mode 生物识别授权；F-01 Deferred，不得以宿主或 UI 构建冒充执行通过。
- **环境延期**：获授权的 Windows/MSYS2 SSH、macOS 15.6、物理触控板与完整跨窗口组合未实测；F-02 Deferred。用户返程可授权后执行隔离 Dev 和专用 SSH 测试，补验实际目标路径、文件内容及窗口归属。
- 文档按实际业务归属更新：`docs/features/{files,settings,command-palette,ssh,editor}.md`。

## Gate（是否允许进入下一阶段）

- **结论：Go（允许继续 P4，不代表完整 GUI 验收通过）。**
- **理由**：三项功能代码与相关宿主、Dev 签名构建已通过；F-01/F-02 获用户授权延期，不得在最终 P4 Gate 中核销。

## 最终状态与剩余风险

- **当前状态：Deferred（真实 GUI 与 Windows SSH）。**
- **剩余风险**：原生菜单/焦点/滚动、远端 Windows shell 输出及断线重连的完整 App 用户流仍需真实授权环境证据。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


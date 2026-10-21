# P1 基线与验证证据

本页记录同一 Feature 在实施前后的**实际**产品验证。实时任务状态只看 [todo.toml](todo.toml)，不能从本页推断完整 E2E 或当前 App 已发布。

## 原始实现（P1-T1）

- 版本：`origin/main@097dac7a78b3308cde950d43446b635fcb1ff3d6` 上仅有计划／开发规范提交，无产品 Swift 变更；实施前 HEAD `8660233d3210537251ecd1fc2fca30beec8e3d12`。
- 机器：Apple Silicon，macOS 27.2 (26B5101f)，Xcode 27.2 (27B5038j)，最低部署目标 macOS 15.6；后者未作真实运行验证。
- `make doctor`：退出 0。
- `make test:SessionStoreTests,WorkspaceWindowIsolationTests,WorkspaceWindowCloseTests,DockFocusP2RegressionTests,PaneRetentionTests DERIVED_DATA=build/DerivedData-workspace-refactor`：退出 0，**76 executed，70 passed，6 skipped，0 failed**；`** TEST SUCCEEDED **`。isolated XCTest 宿主不等于正式 App GUI E2E。
- 六项跳过分别是 Palette 保持编辑器输入、Palette 取消恢复 Files、编辑器切 Files、Palette 打开时 Files 不抢焦点、Palette 取消恢复 Git、Files 改名／草稿的原生焦点；均要求可独占系统 key window，当前不允许抢占用户 Bailey。**这六项不计通过**。
- 覆盖范围：受控 NSWindow／NSHostingView 的双窗口、快照、关闭、原生输入目标、Shell／编辑器保留及其 XCTest 夹具；没有建立独立 App 的 Finder/Dock、Settings 重启、通知点击和真实 SSH master 的外部系统证据。
- 性能／内存：本基线没有可比较 Release GUI 的 heap／CPU／帧序列，不声称等价或提升。
- 证据来源：`build/DerivedData-workspace-refactor/Logs/Test/` 的本次 `.xcresult` 和未入库的 `/tmp/bailey-p1-baseline-test.log`。日志含运行期信息，不复制到仓库。

## 现行模型与失效边界

旧 `TerminalManager` 的静态 `registry`、`pendingRestores`、`pendingHistories`、`pendingExternalFiles`、`pendingDirectories`、`windowOpener` 和 `isQuitting` 与单窗项目状态混在一个类型；每创建一份经理对象即在 init 中进行读取、登记、认领和退出通知订阅。Finder Apple Event 在 delegate 的 `applicationWillFinishLaunching` 前后可到达，不能按 View 初始化次数代表窗口数。重复 `WindowRootView.init` 的 @State 包装创建风险未经真实多次构造实验前**不能视为已消除**。

关键目标：应用级 owner 是唯一可遍历的窗口登记和外部路由源，SwiftUI 视图初始化不登记／不消费恢复，实际窗口装配时只认领一次；局部 `WorkspaceWindowModel` 只持有本窗项目／响应者／内容。旧保存、外部投递、机器和原生宿主守卫不得减少。

## 未验收的真实环境及处理

- macOS 15.6 真机、CI Xcode 26.6、不同分辨率/显示器：本机无对应环境；不能以部署目标编译代替运行。补验各环境的窗口冷启动、Finder、多窗口和关闭。
- Finder「打开方式」、Dock 真实拖放、语言重启及点击系统通知：正式 Bundle ID 与用户现有 Bailey 共用路由；不在用户运行时抢占目标或重启。需要获准的独占 GUI/系统会话，不能由 XCTest 事件发送或 NSHostingView 测试冒充。
- 真实 Windows SSH handoff：没有使用专属 socket/master，不调用用户正在工作的认证通道。P1-T2 可用受控本机 socket 证明接线，真实 SSH 仍待独立验收。
- 视觉对照与真实输入：基线有原生窗口 XCTest 行为，不具备完整 App 截图／逐帧录屏及六条被跳过的前台焦点步骤。P1 其它受影响路径可独立继续实现和验证；缺少关键完整 GUI 证据时，审计 Gate 必须据实记为待验收／No-Go，不能宣称完整完成。

## P1-T2 应用级／窗口级职责迁移

- 新的 GUI 应用所有者：`BaileyApplicationDelegate.workspace: WorkspaceApplication`。在 App 中只注册一次跨窗列表、恢复快照认领、Finder 批次／恢复队列、500ms 合并保存、终止保存、Git 工作树使用范围以及终端通知和私有 SSH 会话定位；没有注册表 static 镜像。
- 单窗所有者：`WorkspaceWindowModel`。由 SwiftUI 的纯 `State(initialValue:)` 构造，在真正场景 onAppear／NSWindow attach 时向应用注册；移除旧 `TerminalManager.swift` 及其所有生产和 XCTest 引用，不保留 alias／旧静态路由。
- Project 的原生保存确认使用所属窗的弱闭包（即使项目是直接赋值／append），不再扫所有窗口；多窗口关闭仍只注销被关闭的窗口。
- 测试 A：`make test:SessionStoreTests,PanelContextTests,WorkspaceIdentityTests,FileTabTests,PaneRetentionTests,DockWorkspaceTests,WorkspaceContentIdentityTests,DockFocusP2RegressionTests,WorkspaceWindowCloseTests,WorkspaceWindowIsolationTests,AppMenuIsolationTests,AppIdentityTests,RemoteLifetimeTests DERIVED_DATA=build/DerivedData-workspace-refactor` → 退出 0，**194 executed，6 skipped，0 failed**。包含新增的 SwiftUI 模型推测构造／恢复只消费一次、不同应用 owner 隔离、受控 Unix socket→实际 SSHService→所属 TerminalSession 的成功与拒绝路径（含非法 token、跨 owner、关闭后重放），不连接真实 SSH。
- 测试 B：`make test:GitStatusModelTests,GitCommitDialogTests,GitExternalRefreshTests,GitHistoryFileTests,GitInteractiveRebaseTests,GitRefReplacementTests,GitRemoteBranchDialogTests,GitStashDialogTests,GitTagDialogTests,GitWorkspaceMenuTests DERIVED_DATA=build/DerivedData-workspace-refactor` → 退出 0，**96 executed，2 skipped，0 failed**。两项跳过分别是授权 SSH Rebase 与真实 SSH Git 外部刷新。
- 最后修正直接赋值／移除项目时的所属窗口回调解除后，重新运行 `make test:SessionStoreTests,WorkspaceWindowIsolationTests,WorkspaceWindowCloseTests DERIVED_DATA=build/DerivedData-workspace-refactor` → 退出 0，**54 executed，5 skipped，0 failed**；确保最新绑定清理的生产代码也得到实际验证。
- `make build DERIVED_DATA=build/DerivedData-workspace-refactor` → 退出 0，`BUILD SUCCEEDED`、`codesign --verify --deep --strict` 通过，未安装／启动正式 App。
- 仅通过源码单向装配与可执行 XCTest 验证；完整独立进程 Launch Services、语言重启、通知点击与未抢占系统键盘的真实 GUI E2E 仍属未执行，不能将此段写成零 UI/UX 变化的全环境证明。P1-T1 的六项原生焦点 Skip 未被这次重构消除。
- 已知待核对边界：`isWorktreeInUse` 仍保留原算法，即先按 Project.panelContext.scope 筛项目；本机 FileTab 放在 SSH 项目时可能被提前过滤。按原计划先保持旧行为，若证实遗漏，另做明确的缺陷验证及修复，不在纯重构中偷偷改变。

## P1-T3 追证

实施后记录新 API 的所有调用方、异步身份失效、测试和文档完整校验。

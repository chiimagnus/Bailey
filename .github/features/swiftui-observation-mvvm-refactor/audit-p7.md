# Audit P7 - swiftui-observation-mvvm-refactor

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p7.md`
- feature 目录：`.github/features/swiftui-observation-mvvm-refactor/`
- 粒度：`phase`

## 任务看板

- [x] P7-T1 SSH、Git 和文件后端的 Swift 6 并发边界收敛
- [x] P7-T2 终端、编辑器与 WebKit 的 Swift 6 actor／delegate 边界
- [x] P7-T3 正式切换 Swift 6 语言模式并使构建／测试全通过

## 任务到文件的映射

- **P7-T1 `7e763e7`**：`kero/Remote/SSHWorkspaceBackend.swift`（删除重复 Darwin 导入）；核对 `RemoteConnection`、`KeroSSHBridge`、`LocalWorkspaceBackend`、`WorkspaceBackend`、Git 执行与隧道 runner 的并发安全职责。
- **P7-T2 `1abc0ad`**：`SyntaxHighlighting.swift`／`SyntaxHighlightPlugin.swift`、`DiffSyntaxHighlighter.swift`／`DiffViewerView.swift`／`DiffTextView.swift`、`BrowserView.swift`、`KeroTerminalView.swift`、`TerminalNotificationService.swift`、`TerminalHistory.swift`、`SourceTextEditor.swift`、`WindowChrome.swift`／`BottomToolbarView.swift`／`TabSwitcherView.swift`、`LocalWorkspaceBackend.swift`／`WorkspaceBackend.swift`／`SessionStore.swift`；`DiffTabTests.swift`、`PaneRetentionTests.swift`。
- **P7-T3 `31175d8`**：`kero.xcodeproj/project.pbxproj`、`KeroSSHBridge.swift`、`KeroTerminalView.swift`、`ProcessWorkingDirectory.swift`、`ProjectsPanelView.swift`、`RemoteLifetimeTests.swift`。
- **本阶段审计 `8450b9d`**：`AGENTS.md` 和 `DiffTextView.swift` 仅修正文档／注释，未修改运行逻辑。

## 发现项

## 发现 F-04

- 任务：`P7-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Workspace/SessionStore.swift:61`
- 摘要：`独立 UI Test 实例共享固定 UserDefaults suite 与独立历史文件，启动可恢复其他测试实例残留项目`
- 风险：`隔离 UI 测试曾意外显示历史测试的非本次临时文件；后续自动点击可能操作错误项目，测试之间历史文件还可相互覆盖`
- 预期修复：`仅隔离实例使用每次运行独立的快照域与历史路径，允许显式 UUID 关联两次测试进程执行重启恢复；正式 App 存储身份保持不变`
- 验证：`SessionStoreTests 隔离测试；真实签名 Debug 进程通过独立 UUID 启动，AX 内读出唯一临时项目及 B 文件内容；make test 和 build 验签`
- 解决证据：`efd34c7: 实机隔离 Debug 首次启动确实读到了旧 suite 中非本次临时项目；按运行 UUID 隔离快照域/临时历史后，使用独立签名 Debug App+显式 UUID 的新测试进程仅读取临时 Git 项目及 A.txt 内容，后台 AX 点击 B.txt 后能读到 B.txt 实际内容，未触碰正式 App。SessionStoreTests 6/6、全量 95/95，Debug/Release 构建与严格验签通过。回切 A 的后台 AXPress 失败，未称完整 E2E。`


## 发现 F-03

- 任务：`P7-T3`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`kero.xcodeproj/xcshareddata/xcschemes/kero.xcscheme`
- 摘要：`重构零 UI/UX 差异缺少可点击完整 App 的独立 E2E 证据`
- 风险：`组件 XCTest 全绿仍可漏掉文件/Diff/窗口焦点跨控件缺陷；实际出现过 A-B-A 串文，当前背景隔离实例 AX 元素不完整`
- 预期修复：`在不影响正式同 bundle ID Kero 的独立桌面环境中引入可运行的 XCUITest/原生 GUI 自动化，覆盖完整点击流程、无保存/SSH 风险和重启恢复`
- 验证：`真正 XCUITest/原生 GUI 回归结果与对应基线；当前只有隔离 Debug 冷启动+只读 AX，不能称 E2E`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-02

- 任务：`P7-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`KeroTests/references/check-file-tree-navigation.swift:1`
- 摘要：`KeroTests/references 历史 Swift 5 @main 检查脚本已完全脱离当前 XCTest 目标`
- 风险：`Xcode 排除清单仍需逐项维护，旧脚本含停用架构和过时路径、可能误导后续测试`
- 预期修复：`删除不参与构建的旧 references 脚本，移除无用途的 Xcode 测试目标例外条目，更新实际测试入口文档；让源码只保留一套 XCTest`
- 验证：`make test; make build; make build:release; 现行 XCTest 仍覆盖 89 项且 references 无消费者`
- 解决证据：`d0d1989：移除未由 Makefile/Xcode 执行的 12 个 references/check-*.swift（2094 行）和 Xcode test target 的 21 行已失效例外清单；仍保持现行 XCTest 93/93、Debug/Release build 严格验签通过；脚本可由 Git 历史追溯。`


## 发现 F-01

- 任务：`P7-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`AGENTS.md:13,35-36; kero/Git/DiffTextView.swift:115-120`
- 摘要：`当前维护规范仍声明 Swift 5 与 Observation 尚未迁移，Diff 注释仍称非隔离后台创建装饰，与已验证 Swift 6/MainActor 代码不一致`
- 风险：`后续开发按过时规范恢复旧发布链或把 TextKit 属性跨线程传递`
- 预期修复：`仅更新当前维护规范中的语言模式与 Observation 状态、原生 Combine 例外，以及 Diff 实际并发所有权说明；保留历史计划原文`
- 验证：`核对项目 Swift 6 build settings、源码实际 @Observable/Combine 使用与 diff 后台/主 actor 路径；git diff --check`
- 解决证据：`Commit 8450b9d 更新 AGENTS.md 与 DiffTextView 注释；xcodebuild showBuildSettings 确认 Swift6 MainActor，源码确认 NSTableView 使用 Combine；git diff --check 通过；此前 XCTest75/75 与 Debug/Release build/codesign 通过。`


## 修复日志

- 审核三个提交的源码、产品调用链及验证记录；后台 socket 的请求／JSON 编解码／主 actor 审核／后台回复实测通过，保留原有队列与超时机制；Git／文件后台 IO 未出现 Swift 6 编译诊断，未改写有效 runner。
- Tree-sitter 后台只传纯语法标识，解析器指针在工作线程创建；Diff 后台计算纯差异与 capture，主 actor 生成 `NSColor`、富文本与装饰；原生观察者在隔离析构中释放，WKDelegate 回调签名匹配 SDK；旧的跨线程 AppKit 渲染路径已删除。
- `31175d8` 把 App/Test 两配置实际切至 Swift 6，修正完整 Release 编译中发现的非隔离 SSH 服务、计时器等警告，并新增 UNIX socket 真实传输回归。
- F-01 → `8450b9d`：更新权威维护规范中的 Swift 6／Observation 现状、原生 Combine 合法例外，并移除 Diff 注释中的错误线程声明。
- 计划校对：`todo.toml` 实际有 **23 项已完成**（原 P7 计划误写为 22），已修正本地 `plan-p7.md` 计数，不动历史 `idea.md`。

## 验证日志

- `rtk codegraph sync` 后逐个 `explore/node` 核对真实入口及 P7 提交的调用路径；`rg` 检索自有 `@Published`、`ObservableObject`、`@StateObject`、`@ObservedObject`、`objectWillChange`：仅 `TunnelManager.$tunnels/$states` 为 `NSTableView` 原生 Combine 事件订阅，其余自有 UI 状态使用 Observation；原生表格不创建重复状态。
- `xcodebuild -showBuildSettings`（与 Makefile 一致的本机离线包选项）→ PASS：`EFFECTIVE_SWIFT_VERSION=6`，`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`，`MACOSX_DEPLOYMENT_TARGET=15.6`；工程 `objectVersion=77`、App／Tests 各 Debug／Release `SWIFT_VERSION=6.0`。
- `make doctor` → PASS（Xcode 27.0）；`make test ONLY_TESTING=KeroTests/RemoteLifetimeTests` → **4/4 PASS**（含真实本机 UNIX socket 后台请求→主 actor→回复及拒绝结果）；P7-T2 的 Diff／PaneRetention／WorkspaceIdentity 针对性测试分别 **11/11、12/12、4/4 PASS**。
- **最终 `make test` → 75/75 PASS**（`/tmp/kero-p7-t3-full-test-final.log`）；最终 `make build` → PASS（`/tmp/kero-p7-t3-debug-build-final.log`）；`make build:release` → PASS（`/tmp/kero-p7-swift6-release-after-dto.log`）。Makefile 的 Debug／Release 严格验签 PASS，另复验 `codesign --verify --deep --strict` Release PASS。Release 仅有系统 AppIntents 元数据未依赖的提示，无自有并发隔离警告。
- 原生隔离 Debug（非正式安装包）验证：真实 TextKit Split Review Diff 显示变更文字和颜色；README 编辑器语法高亮与文件内容可见，切换标签后终端 Shell PID 不变；受控 XCTest 覆盖真实 WebKit JS alert/confirm/prompt Sheet、Diff AX 折叠激活、编辑／撤销／滚动／重挂载、跨窗口原生确认以及语义快照、sidecar／Info 过滤。截图存 `/tmp/kero-p7-t2-*.png`，没有写入用户数据。
- `git diff --check`、`feature_tool.py todo validate` 和 `phase-complete --phase p7` → PASS；23/23 状态均为 completed，各实现任务对应有效本地提交。

## Gate（是否允许进入下一阶段）

- 结论：**Go**
- 理由：23 项任务的 P7 最终配置、真实 Swift 6 诊断修复与外部效果测试均有源码及构建证据，Debug／Release／XCTest 全部通过；唯一审计 finding 已解决，没有留下已证实的 P7 正确性阻塞项。

## 最终状态与剩余风险

- 当前状态：**Resolved**（本阶段 F-01 已关闭，无 Open finding）。
- **现存、非本次重构修复的关闭风险**：`Project.closeBatch`（`Project.swift:630`）逐项确认后立即删除标签，后续取消不会恢复之前已关闭的标签；`TerminalManager.close(_:)`（`TerminalManager.swift:360`）直接终止项目，`WindowRootView.onDisappear`（`keroApp.swift:67`）关闭后才进入 `windowClosed()`，没有对所有未保存编辑统一先行确认。这些路径在原计划 `idea.md` 已列明，修复会改变既有关闭交互，违反本次重构的 UI/UX 零变化约束；没有将其冒称本次解决，须独立获准修改产品行为。
- 剩余验证边界：当前隔离窗口受可用屏幕范围限制，未获得与 P1 旧 1800×1130 截图**完全同尺寸**的终验像素对比，不能宣称所有界面逐像素零差异；已保留各阶段同环境原生截图、P7 Native TextKit／编辑器实操与 75 项自动测试。没有授权使用专用真实 SSH master，因此仅受控 backend／真实本地 socket 验证，不声称远程端到端完成。没有安装／退出／重启正式 `/Applications/Kero.app`，未做正式包重启恢复、远端 CI 或下载包 Gatekeeper 验收，这些不在本地构建证据内。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


## 2026-10-14 独立重审：P7（不继承旧审计结论）

| todo 任务 | 原提交核对 | 当前执行路径／独立证据 | 判定 |
| --- | --- | --- | --- |
| P7-T1 | `7e763e7` | 消除 SSH 后端重复导入并核对原有独立进程 runner、Pipe/Socket 生命周期；RemoteLifetimeTests/GitExecutionTests 仍实际运行。 | 不删除用来保证防死锁的独立 IO 边界 |
| P7-T2 | `1abc0ad` | Terminal/AppKit/Editor/WebKit 原生回调的 Swift 6 actor 隔离，当前 Diff 和 Browser/Editor native 路径仍调用；PaneRetentionTests/DiffTabTests 覆盖时序。 | 有真实调用方；未引入平行兼容回调 |
| P7-T3 | `31175d8`，规范同步 `8450b9d` | App 和 XCTest Debug/Release `SWIFT_VERSION=6.0`；单 scheme、唯一 Kero.app。只用当前 Xcode 构建及验签，不额外装旧工具链。 | 编译／签名作为机械 gate；真实 UI/UX 不等于编译通过 |

**额外测试治理**：`157e4fc` 建立 `docs/TESTING.md`、AGENTS、PR 证据要求和跨标签／双窗口 XCTest；`c1848ca` 将隧道 Debug 启动自检迁至 XCTest；`d0d1989` 删除 12 份未参与构建的旧脚本（2094 行）及工程例外。明确需求/文档驱动与 TDD 红绿循环、单元/组件/工作区/真正 E2E 的边界；当前尚无安全的独立 XCUITest 环境，不能中断用户正在运行的同 Bundle ID App。

### 2026-10-14 总 Gate（独立复核）

- **范围**：按现存 `todo.toml` P1-T1 至 P7-T3 共 23 项逐项对照原提交、后续替代实现、当前调用方与对应 XCTest。P1-T1 是无独立代码提交的基线工作；P5-T4 与 `3918150` 的 P5-T3 合并提交，不能虚构额外实现提交。本机 `evidence/p1-baseline/` 有真实原始截图及多阶段对照，但未覆盖所有交互及同条件逐像素回归。
- **已解决的本轮发现**：P1-F-01（过期双身份脚本，`157e4fc`）；P3-F-02（临时失败清空 Git，`0e46a97`）、P3-F-03（`git log` 单点失败被当作空历史，`2af09b2`）；P4-F-05（Diff A-B-A，`ceceeb1`）、P4-F-06/F-07（隧道自检及非法端口崩溃，`c1848ca`）；P5-F-01（Files A-B-A，`5edfccd`）、P5-F-02（单窗关闭失败未保护，`085849b`）；P6-F-01（同仓库换 SSH 连接排队，`62a31cf`）；P7-F-02（失效测试脚本，`d0d1989`）、P7-F-04（UI 隔离串用其他测试快照，`efd34c7`）。上述均有对应真实受控或原生宿主回归。
- **本轮验证**：`make test` **95/95 PASS**；`make doctor`（Xcode 27.0）、`make build`、`make build:release` **PASS**，Debug/Release `codesign --verify --deep --strict` **PASS**。曾观察到 XCTest 测试插件出现在 Debug 产物而导致封装验签失败；重新执行正常 Debug 构建后 `PlugIns/KeroTests.xctest` 消失且签名正常，未增设新构建后处理。签名 Debug `/Applications/Kero.app` 已按最终 95/95 代码**整包替换并复验**（可执行文件 SHA-256 `62e6a1e3476e8d40c5030c899718875ef28314aa19db58363def55e282bec2f3`）；正式进程 PID 29911 保持运行、**未退出/重启**，正式重启恢复未测。用唯一测试 UUID 启动第二个真实签名 Debug App，AX 观察只含临时项目、A.txt 和 B.txt；背景点击 B 后读取到 B 的真实文本，回点 A 时 AXPress 未派发，因此只确认 A→B，不宣称 A→B→A 端到端通过。本次隔离进程、临时项目及其唯一设置域已清理。
- **仍未消除／未验收**：P7-F-03（尚无独立 XCUITest、未完成完整真实用户 A→B→A 点击与窗口焦点 E2E；已完成安全独立 App 的部分后台 AX 实机操作）；另有批量关闭中途取消不回滚的旧产品行为。真实 SSH 断线重连和同条件明暗/多窗口 UX 视觉对照未运行。不要为消除这些空缺而修改用户配置或启动同 Bundle ID 的前台 XCUITest。
- **Gate：No-Go（完整重构 UX / E2E 验收）**。本轮已修复单独关窗丢编辑、独立 UI 测试串用历史快照，并通过 95 项 XCTest、Debug/Release 验签及已安装 App 的原地替换验收；但完整原生点击、跨窗口焦点、实机 SSH 与同条件视觉仍未完成，不得把受控模型与组件测试称为所有 UI 已通过。不重新执行已退出的 Pierre/WebKit Diff 或多 App 身份路线。

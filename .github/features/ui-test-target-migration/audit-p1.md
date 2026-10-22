# Audit P1 - ui-test-target-migration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/ui-test-target-migration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 按方法核对旧测试与行为归属
- [x] P1-T2 修复独立 Runner 和现有十条真实 UI 路径
- [x] P1-T3 核对 Unit/Integration 中混入的原生 UI 用例

## 任务到文件的映射

- P1-T1：`migration-inventory.md` 原始 329 方法、`BaileyTests/{NativeUI,WorkspaceUI}` 23 个文件、`BaileyUITests` 和 Scheme/Target；按 A19/B87/C223 分类并保留逐方法行号。
- P1-T2：`BaileyUITests/Support/WorkspaceUITestSupport.swift`、Files/Git/Workspace UI 测试、`Bailey/UI/Components/WorkspaceChrome.swift`、`Makefile`、`docs/testing.md`，提交 `70a103d`、`f712d52`；`9177817` 提前核销 P4-T1 原生焦点测试一项。
- P1-T3：`Bailey/App/AppSettings.swift`、`BaileyTests/Integration/Settings/AppSettingsTests.swift`、`BaileyTests/Integration/Workspace/SessionStoreTests.swift`、`docs/features/settings.md`、`docs/features/tunnels.md`；提交 `a7e4834`，SessionStore 中两项 UI 装配保留至 P4-T4。

## 发现项

## 发现 F-05

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift:1091`
- 摘要：`Dock 移动后原生编辑器保持 Undo/滚动的宿主测试在完整 PaneRetention 类中失稳`
- 风险：`独立窗体装配、焦点/重挂载可能未完成，或者生产生命周期有回归；目前无法以某轮通过替代稳定验证`
- 预期修复：`归 P4-T5：按原测试移动前后校验相同原生编辑器、Undo/滚动和实际文件写入，在具备真实 Key Window 的 GUI E2E 复现；用定位模型测试保留内部身份不变量，再同任务移除旧宿主用例`
- 验证：`P4-T5：真实 App Dock 移动/重新挂载与编辑器 Undo/滚动；原生身份/内存确认；完整 make test`
- 解决证据：`PaneRetentionTests 20 项类内执行（2026-10-22 19:35）Dock 移动原生保留测试在源码 L1091 settle 超时；两次前面的全量运行未失败，说明不稳定但没有足够证据归因；已明确归 P4-T5 实际 Key Window、多 Dock 重挂载/Undo/滚动/文件字节。`


## 发现 F-04

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift:639-644`
- 摘要：`五编辑器关闭后释放弱引用在全量宿主中偶发超时，独立方法与首轮全量通过`
- 风险：`可能是 AppKit/SwiftUI 关闭时序，亦可能是真实资源滞留；缺少 retained file/editor 的区分证据，不能作为长期内存验收通过`
- 预期修复：`归 P4-T5：先在同一宿主受控窗口/五编辑器组合复现及逐对象记录未释放对象，再用真实 App 生命周期、Instruments allocations/heap 和无 GUI 所有权断言验证根因与释放，完成替代后删旧宿主压力方法`
- 验证：`P4-T5：同条件五个编辑器打开关闭循环、弱引用和 heap/Instruments 证据，独立 App UI 复核，最终完整 make test`
- 解决证据：`第一轮宿主全量此方法 0.928 秒通过；第二轮完整宿主相同方法 10.645 秒超时，独立定点 0.941 秒通过，PaneRetention 类本方法 0.841 秒通过。生产泄漏根因未知，P4-T5 明确负责原生弱引用、heap/Instruments 与实际 App 生命周期，最终 Go/No-Go 阻塞。`


## 发现 F-03

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyTests/Integration/Settings/AppSettingsTests.swift:22-166`
- 摘要：`306条低层基线和新增主题隔离回归未执行，SessionStore两项原生装配仍待迁移`
- 风险：`临时配置与单例主题分离虽经编译，但实际Observation/主题传播和复位行为未通过XCTest验证；阶段不能放行`
- 预期修复：`独立宿主Runner执行 AppSettingsTests、SessionStoreTests 及受影响非UI回归，核对无共享配置写入；两个真窗口用例在P4-T4获得独立UI与纯状态等价证据后再删除`
- 验证：`独立Runner: make test:AppSettingsTests,SessionStoreTests SIGNING=adhoc；记录实际passed/failed/skipped与副作用`
- 解决证据：`AppSettingsTests+SessionStoreTests 16/16 退出码0（2026-10-22 18:23）；第一轮宿主全量 636 实际执行，除了 P4 伪前台测试外 0 失败、8 条明确获授权 Windows SSH 条件 skip。a7e4834 消除临时 AppSettings 原生副作用。SessionStore 仍保留两项真实窗口测试明确归 P4-T4，不声称已迁走。`


## 发现 F-02

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:30-69`
- 摘要：`本机文件选择器依赖固定英文 Add/Open，树行查询调用方仍在整App范围使用 firstMatch`
- 风险：`中文面板按钮可能找不到；Files/Git Graph/Changes并列展示相同相对路径时可能命中非目标文件行`
- 预期修复：`取得真实AX树后，使用当前Sheet和真实窗口/面板约束查询，按语义选择系统按钮，不依赖单一英文标题；加入双组及双窗口同名用例`
- 验证：`独立Runner测试中文/英文文件选择、两个同名目录、同时显示Files/Git Changes/Graph、跨窗口目标归属`
- 解决证据：`P1 corrected hardcoded English Add/Open/Cancel with native OKButton/Escape; English+Chinese incl long Unicode real App passed, same basename two directories passed; window-scoped AX queries a33641e verified by 13/13 UI. Same relative path in simultaneous Files/Git Graph/Changes and two windows is not claimed verified and belongs to P3-T2/P4-T1/T2; source path semantics also need CI validation on Xcode 27.`


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:6-24`
- 摘要：`现有10条和新增同名路径UI用例只编译未运行，无法确认真实AX和启动链路`
- 风险：`构建绿色不能排除按钮查询、Sheet、焦点或同Bundle ID冲突；计划P1-T2的真实GUI验收门槛未满足`
- 预期修复：`在真正独立的GUI Runner/登录会话执行 make test:ui SIGNING=adhoc 及10+1定点测试；核对xcresult实际执行数量、失败/跳过和数据结果，再逐根因修正`
- 验证：`独立Runner: make test:ui SIGNING=adhoc；xcresulttool get test-results summary 验证11项以上真实执行`
- 解决证据：`13/13 UI XCTest complete (build/DerivedData/Logs/Test/Test-Bailey-UI-2026.10.22_19-37-14-+0800.xcresult): result Passed; 0 failed/0 skipped; DEVELOPER_DIR specified, a33641e updated actual window scoping and Xcode Git binary, f712d52 fixed Git sandbox and Chinese picker, 9177817 native focus E2E replaces fake offscreen test.`


发现项状态通过 `feature_tool.py finding resolve` 记录，以下为发现与证据。

## 修复日志

- `70a103d`：夹具创建即登记清理、文件路径 AX 匹配及旧重复 teardown 删除、Git 子进程 stdout/stderr 规避管道反压。
- `a7e4834`：仅 `AppSettings.shared` 同步全局主题，临时配置不污染运行中应用；新增主题隔离回归，删除旧 `NSApp.appearance` 恢复，纠正配置大小写。
- `f712d52`：替换 XCTest 沙盒下不能使用的 `/usr/bin/git` xcrun 包装器；本地化系统文件对话框以 `OKButton` 确认、Escape 取消；新增中文和长 Unicode 路径测试。
- `9177817`：旧宿主测试的 `NSApp.isActive=false`、`NSWindow.isKeyWindow=false`，触发生产代码正确焦点保护。新建真实前台 App 的编辑器 → Command Palette → File Manager → 方向键/空格 E2E，1/1 通过；立即删除失效宿主测试，保留原生焦点保护；其余旧类方法 2/2 通过。
- `a33641e`：宿主 `make test` 加与 UI Test 相同的 App 进程拒绝执行；File/Git AX 查询限定当前窗口；Git 从 CI 的 `DEVELOPER_DIR` 选用 Xcode 原生 Git，缺失回退 CLT，避免在 Xcode Runner 上找不到 CLT。。

## 验证日志

- Debug/Release App、UI Runner、宿主 `build-for-testing` 均已通过 Xcode 27.2 编译及相应签名验证；最终 commit 后仍需复核。
- `make test:AppSettingsTests,SessionStoreTests SIGNING=adhoc`：16/16 passed、0 failed，配置主题隔离/Observation 与 SessionStore 状态和原生窗口测试真实执行。
- `make test:ui SIGNING=adhoc`：2026-10-22 19:00:05 xcresult 完整执行 12/12 passed、0 failed、0 skipped，226 秒、退出码 0；后新增前台焦点回归定点 1/1 passed；完整现行 13/13 于 `Test-Bailey-UI-2026.10.22_19-37-14-+0800.xcresult` 连续 Passed、0 failed、0 skipped、完整退出码 0（约 257 秒）。
- 第一轮完整宿主 `make test SIGNING=adhoc`：636 项，8 条合法 SSH/Windows 实机条件 skipped，仅旧伪前台焦点方法产生 3 条失败断言，命令非零；删除失效旧方法后预计 635 项，第二轮完整执行 635 项，8 skip、626 passed、仅 P4-T5 `PaneRetentionTests.testClosingMountedFiveFileTabsReleasesTheirNativeDocuments` 失败；独立同方法 1/1 通过，完整 `PaneRetentionTests` 20 项又暴露 `testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll` 失稳。两项都是未完成的 P4-T5 旧原生宿主测试，按 F-04/F-05 明确 No-Go，未以加超时掩盖。
- 可用环境实测：macOS 27.2、Xcode 27.2、ad hoc、英文与中文 GUI、Unicode 长文件路径、同名不同目录、Git 工作区/图谱、真实编辑保存、系统 Sheet 确认/取消、Command Palette 前后台键盘及双窗口基础操作。E2E 验证实际文件 Tab、磁盘字节与窗口数量，而非纯事件派发。
- 明确的范围外补验：Xcode 26.6 的发布流水线、macOS 15.6 真机、真实物理中文 IME、Windows SSH 8 条条件用例，以及同一窗口同时挂载多个 Files/Git 树、多窗口同名目标；后续 P2–P5 按域验证，不在 P1 静默视作已通过。直接把超长中文路径输入系统「前往文件夹」的失败尚未归因为产品缺陷；已分离为中文系统 Sheet + 文件树长 Unicode 路径通过，原生路径直输边界仍留在相应领域测试。
- 文档归属：`docs/testing.md`、`docs/features/settings.md`、`docs/features/tunnels.md` 已与修复提交同步；`migration-inventory.md` 保持旧 329 项原始基线与已核销归属，进度仍以 `todo.toml` 为准。

## Gate（是否允许进入下一阶段）

- 结论：**Go（仅 P1 阶段门槛；最终宿主全绿仍 No-Go）**。
- 理由：原 329 项分层与额外 Unit/Integration 混入已逐方法核对；13 项现行 App E2E 全量真实通过；AppSettings/SessionStore 16 项定点真实通过；CLI/沙盒/Sheet/安全隔离修复已提交。完整宿主仅剩两项 P4-T5 原生窗口生命周期失稳，其根因和等价迁移本来归 P4-T5，已在本阶段发现并登记为需后续核销的 High finding；不提前宣称最终 make test 通过。

## 最终状态与剩余风险

- 当前状态：**Resolved（P1 范围完成）**；F-02、F-04、F-05 在后续 P3/P4 前保留 `Deferred`、按原生生命周期证据最终关闭。
- 剩余风险：同屏不同树行/双窗重名仍需 P3/P4 E2E；两项 P4-T5 原生窗口资源与 Dock 重挂载 intermittent failures 必须根因复现、修复、替代断言并通过最终 `make test`；8 项获授权 Windows SSH 实机条件未在本机执行。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

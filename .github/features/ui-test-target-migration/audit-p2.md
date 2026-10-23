# Audit P2 - ui-test-target-migration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/ui-test-target-migration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 编辑导航、原生输入、IME 和撤销
- [x] P2-T2 文件标签、真实读写、保存冲突与断线恢复
- [x] P2-T3 语法高亮、主题、组合字符与原生颜色
- [x] P2-T4 Diff 原生绘制、编辑、展开及真实保存

## 任务到文件的映射

- **P2-T1（旧 38 项）**：`BaileyTests/Integration/Editor/NativeEditorLayoutTests.swift` 28 项、`NativeEditorCompositionTests.swift` 10 项；`TextCoordinateIndexTests.swift` 9 项补充坐标回归；`BaileyUITests/Editor/EditorNavigationUITests.swift` 3 项验证独立 App 的实际输入与字节。
- **P2-T2（旧 49 项）**：`BaileyTests/Integration/Files/FileTabPersistenceTests.swift` 33+16 项；`BaileyUITests/Files/WorkspaceFilesUITests.swift` 9 项及 `BaileyUITests/Support/WorkspaceUITestSupport.swift` 验证文件树、原生选择器、焦点、同名路径和最终保存。
- **P2-T3（旧 22 项）**：`BaileyTests/Integration/Editor/NativeSyntaxHighlightingTests.swift` 22 项及 `BaileyUITests/Editor/EditorHighlightingUITests.swift` 真实 Swift、Markdown/TSX/HTML/CSS 与各自纯文本截图颜色及原字节。
- **P2-T4（旧 35 项）**：`BaileyTests/Integration/Git/NativeDiffTabTests.swift` 35 项、`BaileyTests/Unit/Git/DiffEngineTests.swift` 6 项辅助算法测试；`BaileyUITests/Git/WorkspaceGitUITests.swift` 验证真实 Git Changes、Git Graph 和 Split／Unified／Edit／Undo／Redo／⌘S。
- **共享测试入口**：`BaileyUITests/Support/WorkspaceUITestSupport.swift` 按真实 AX 语义输入，Dev App 激活后及系统选择器路径输入框获得焦点后暂选 ABC、清理时恢复原拼音；`Bailey/Git/DiffViewerView.swift` 的 AX ID 不改变产品视觉；`docs/testing.md`、`docs/development.md`、`docs/features/editor.md`、`docs/features/diff.md` 已同步。

## 发现项

## 发现 F-05

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/EditorNavigationUITests.swift:112`
- 摘要：`全量GUI中Unicode真实编辑在app.typeKey(Cmd-Z)上耗时逾90秒并被XCTest键盘事件合成超时，独立复测41秒可通过`
- 风险：`应用级AX按键目标在重型10万行测试后出现跨进程事件定位卡顿，导致原生Undo/Redo真实回归不能稳定完成；不能以偶发单测绿色掩盖全量失败`
- 预期修复：`在已明确获得焦点的原生编辑器XCUIElement上直接发送Cmd-A/Z/Shift-Z/S，而非每次向整个XCUIApplication寻找键盘事件目标；不改动编辑器生产逻辑或跳过字节、Undo断言`
- 验证：`独立EditorNavigationUITests/testUnicodeReplacementUndoRedoAndRealSave及21条完整BaileyUITests，核对真实文件字节、0跳过及xcresult退出码`
- 解决证据：`2026-10-23: 全套旧App级Cmd-Z在XCUITest Find Target Application约61s及Synthesize事件约90s卡住；改由已真实点击的原生XCUI textView.typeKey发送Cmd-A/X/Z/Shift-Z/S；保留原Unicode、磁盘、UndoRedo断言。定点32s通过及完整21条21/21、0跳过通过，未更改生产编辑器。`


## 发现 F-04

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Workspace/WorkspaceSmokeUITests.swift:17`
- 摘要：`完整GUI中真实Command Palette第一次Escape未清除已有查询，结果第二次才关闭；先前验收中又曾通过，行为随输入法/事件分发状态变化`
- 风险：`键盘Esc有时被输入法组合或事件处理抢占，命令面板查询不按约定清空，焦点恢复有不确定性；用户可见交互回归可能被非确定性测试掩盖`
- 预期修复：`获取真实输入法和Escape前后状态；追踪原生TextField以及SwiftUI onKeyPress/onExitCommand分发，仅在确认根因后修改拥有输入状态的最小位置，同时保留真实App键盘证据`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceSmokeUITests/testIsolatedLaunchAndPaletteKeyboardFocus；执行整套21条GUI并核对0失败0跳过`
- 解决证据：`2026-10-23: 失败现场ESC_DIAG AFTER_FIRST_ESCAPE的XCUIElement.value已为\"\"且ABC，旧XCTNSPredicateExpectation value!=z及闭包都超时误报。改为原生输入元素当前AX value直接断言空，再第二Escape检查消失，定点1/1与完整21/21真GUI通过。未修改产品CommandPaletteView，因为Escape实际已正确处理。`


## 发现 F-03

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:9`
- 摘要：`Bailey Dev已运行时21条UI测试全部XCTSkip，xcodebuild却返回TEST SUCCEEDED和0退出码`
- 风险：`正式CI及本机有遗留开发版进程时所有E2E可全跳过并假绿，导致功能未验证却放行；此处不得直接结束未知归属Dev进程`
- 预期修复：`保留拒绝终止现有Bailey Dev的保护，但将XCTSkip改成明确测试失败，只有测试拥有的实例才交由其teardown终止；继续按xcresult检查执行和跳过数量`
- 验证：`make test:ui；xcrun xcresulttool get test-results summary核验passed>0 skipped=0；含预存Dev场景验证不能假绿`
- 解决证据：`2026-10-23: 启动仅自建受控Bailey Dev PID 2758后运行UI定点，测试抛BaileyUITestLaunch拒绝操作且make退出码2，现有进程仍活；经PID+绝对命令匹配后单独清理。正式21条套件实际21 passed、0 skipped、make exit0，xcresult复核 result Passed，已消除全XCTSkip假绿。`


## 发现 F-02

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:27`
- 摘要：`公共GUI测试在激活Bailey Dev之前选择ABC，首次系统选择器仍可能恢复拼音输入源导致路径不完整`
- 风险：`当macOS按应用/文档恢复输入源时，TISSelectInputSource在Runner中成功并不保证后续Bailey Dev输入字段沿用ABC；真实文件选择器/编辑器的键盘测试可能偶发失败或产生错误文件路径`
- 预期修复：`将输入源切换移至Bailey Dev激活并确认前台之后，对系统选择器聚焦字段执行显式ASCII选择；保留每例结束时恢复用户原输入源的逻辑`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/EditorHighlightingUITests；make test:ui 完整App GUI套件；退出后核查输入源恢复`
- 解决证据：`2026-10-23: 前台Bailey Dev激活后TISSelectInputSource ABC，NSOpenPanel PathTextField获得焦点后再选ABC；XCUI输入完整路径后读回实际字段并直接校验。完整21/21 UI套件含中文长路径、100k、不同目录同名保存均通过、0跳过，退出后系统拼音com.apple.inputmethod.SCIM.ITABC恢复，UnicodeHex未启用。早期失败未取得精确字段值，不声称已证明唯一根因；保留不一致时的当前输入源/期望/实际日志。`


## 发现 F-01

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/EditorHighlightingUITests.swift:6`
- 摘要：`高亮跨进程视觉回归仅比较 Swift 与纯文本；P2 计划规定 Markdown/TSX/HTML/CSS 和嵌入语言的真实 GUI 着色`
- 风险：`这些语言即使整个渲染链退化为纯文本，现有完整 GUI 20 项仍可能全部通过；低层颜色测试不能证明从完整 App 打开的文件类型真的接入了原生高亮`
- 预期修复：`沿真实 Files 打开路径增加同源纯文本对照，分别确认 Markdown/TSX/HTML/CSS 的当前文本视口确实出现语法着色并保持源文件字节，不为测试注入应用内部状态`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/EditorHighlightingUITests；make test:NativeSyntaxHighlightingTests；make build:ui`
- 解决证据：`2026-10-23: XCUITest独立Bailey Dev真实读取Markdown含Swift fence、TSX、HTML含script/style、CSS、Swift并比对同文本plain；XCTest附件10图已导出并目视核对，磁盘字节一致。完整make test:ui DERIVED_DATA=build/DerivedData-P2-MultiLanguage 21/21通过、0失败、0跳过、exit0；xcresult Test-Bailey-UI-2026.10.23_03-50-02-+0800.xcresult。`


截至本次审查，P2 本机复核中**没有未修复的、已证实的产品代码回归**。实施期发现的输入法复原／AX 类型／本地化搜索／原生 Diff 颜色采样／测试偏好污染均已由 `2c7b51b` 根因修正，并有完整运行证据。原先 Git 测试点击宽度为零的隐藏 AX 标签，改用真实 ⇧⌘G 用户入口，三项全部实测通过。

本阶段剩余的未验证条件列于验证日志，不以未经验证的 CI、SSH 或实体设备结果推定通过。

## 修复日志

- `b094047`、`5bc6fe2`、`7e27b61`、`6b65c00` 保留 P2 四任务所有旧方法与必要原生契约，按源码去向迁移；非目标旧路径已从 Git 索引消失。
- `2c7b51b`：Apple Development 签名 GUI 测试；测试入口原先在启动 Dev 前选择 ABC，后续发现这一时机可能遭应用级输入法恢复覆盖（见 F-02）；每条用例退出仍恢复拼音并取消 XCTest 暂时启用的 Unicode Hex Input；中文与英文命令面板走对应本地化文本；Git 通过实际快捷键而非隐藏元素；AppKit 控件按真实 `RadioGroup` AX 类型查询。
- 同一提交：Diff 位图转 sRGB 通道读取，保留现有容差和红绿／删除 ghost 断言；使用每例独立 UserDefaults 解决持久化 Edit 模式阻止正常重载的超时，不删除生产保护；新增真实 Split→Unified 双区域和 Edit／Undo／Redo／保存字节断言。
- 本阶段没有改动或重启正式 `/Applications/Bailey.app`，也没有更改授权范围外的仓库或用户文件。

## 验证日志

- **环境**：2026-10-23，macOS 27.2（26B5101f）、arm64，Xcode 27.2（27B5038j），独立 `chiimagnus.bailey.dev`，个人 Apple Development 签名。`codesign --verify --deep --strict` 对 Bailey Dev 和 UI Runner 都通过；Runner Team ID 为本机开发身份；正式 Bailey 进程 `21030` 保持存活。
- **原方法覆盖**：从当前受测 Swift 源文件重新扫描：P2-T1 28+10、T2 49、T3 22、T4 35，**144/144**；对应旧 NativeUI 源文件已不存在。独立 `BaileyUITests` 现有 **21 个**方法，且未导入 Bailey 产品模型；`migration-inventory.md` 保留逐方法映射。
- **宿主**：`make test:FileTabPersistenceTests,NativeFileTabTests,NativeSyntaxHighlightingTests,NativeDiffTabTests DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，106/106，0 failures，exit 0**（`/tmp/bailey-p2-host-106-final.log`）。覆盖保存事务／失败保留、原生视图、Tree-sitter 高亮/异步、Diff 行/像素/异步折叠/撤销。没有删除原始 35 个 Diff 契约断言。
- **本轮完整宿主 XCTest（2026-10-23）**：`make test DERIVED_DATA=build/DerivedData-P2-Acceptance` → **635 个被发现，627 Passed，8 Skipped（真实 Windows SSH 环境不满足），0 Failed，exit 0**。经 `.xcresult` `Test-Bailey-2026.10.23_04-02-27-+0800` 二次核对，特别确认 `GitHistoryFileTests` 21/21、`RecentCommitsViewTests` 48/48、`NativeSyntaxHighlightingTests`22/22、`NativeDiffTabTests`35/35、`WorkspaceWindowIsolationTests` 42/42、`PaneRetentionTests`20/20。8 条跳过源于授权 Windows SSH 缺位，不应算 Passed；没有因失败删测试。
- **独立正式身份构建**：`make build DERIVED_DATA=build/DerivedData-P2-FinalProduction` → `BUILD SUCCEEDED`、exit 0，产物独立路径中 Bundle ID `chiimagnus.bailey` 严格签名 `codesign --verify --deep --strict` 通过，未安装/替换/启动 `/Applications/Bailey.app`。仅观察到供应商 Tree-sitter 编译的既有 C/C++ 警告和无 AppIntents 依赖元数据告警，不影响成功退出。
- **底层补测**：`make test:NativeEditorLayoutTests,NativeEditorCompositionTests,TextCoordinateIndexTests,DiffEngineTests DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，53/53，0 failures，exit 0**（`/tmp/bailey-p2-editor-core-final.log`）。包含输入法组合的 AppKit 契约、十万行坐标和 Diff 算法，不冒充实体拼音选字。
- **完整 App E2E**：`make test:ui DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，20/20，0 failures，exit 0**（`/tmp/bailey-p2-ui-full-20-final.log`）。通过 Swift／纯文本截图颜色比较、十万行首尾输入和精确保存、中文长路径系统选择器、同名不同路径文件、键盘焦点和中英文 Palette、Git Changes／Graph、真实 Diff Edit／Undo／Redo／⌘S、双窗口及设置。
- **P2 后续完整 GUI 审计（21条）**：`make test:ui DERIVED_DATA=build/DerivedData-P2-MultiLanguage` → **21/21 通过、0 失败、0 跳过、exit 0**，`.xcresult` `Test-Bailey-UI-2026.10.23_03-50-02-+0800` 的 `Passed`、`passedTests=21`、`skippedTests=0` 已独立核对。新增 Markdown／TSX／HTML／CSS 同内容纯文本截图和字节检查，与 Swift 共 2 项高亮 E2E；导航3项、Files9项、Git/Diff3项、Palette1项及窗口3项全部通过。首次全21项曾有 Unicode app级 Cmd-Z 键盘合成超时、Palette 旧谓词假阴性，见 F-04/F-05；新完整绿灯不是重新解释原失败。
- **假绿反向验证**：独立 Bailey Dev 已运行时，明确拒绝启动第二 Runner 测试且测试以非零退出码失败；运行中的 Dev 未被杀，之后只清理已确认属于本轮自建的实例（F-03）。GUI结束后 `TISCopyCurrentKeyboardInputSource` 返回原拼音 `SCIM.ITABC`，启用列表不含 Unicode Hex Input。签名严格验签 Bailey Dev 和 UITest Runner 均通过，正式 Bailey PID 21030 一直运行。
- **增强 Split E2E**：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests/testWorktreeDiffEditsAndPersistsRealGitFile DERIVED_DATA=build/DerivedData-P2-Acceptance` → **PASS，1/1，exit 0**（`/tmp/bailey-p2-diff-split-exit-edit.log`）。先切 Review，实际点 Split 并核对两个原生文本区域，再 Unified、Edit、Undo／Redo 和最终 UTF-8 文件字节；支持从用户保存的 Edit 模式开始。
- **系统输入复核**：每次正常 GUI 用例后恢复系统拼音；整套 20/20 结束后读取 macOS 已启用输入法：ABC、拼音保留，`Unicode Hex Input` **不在列表**。未对 `/Applications/Bailey.app` 进行启动、退出、替换或重签名。
- **未测／条件性边界**：① **macOS 15.6 真机**不可用；可用27.2和原生 contract 为替代，但不能证明最低系统版本 GUI 兼容，需该系统 Runner 复测，发布全平台 Gate 阻塞。② **GitHub CI ad-hoc UI Runner**尚无此提交的远端 Job；本机强制 ad-hoc 曾遭系统拒绝 UI 权限，本机开发签名成功不代表 CI 成功；需提交/推送授权后查看 GitHub Actions 真实结果，CI Gate 阻塞。③ **真实 Windows SSH 断线／重连／多机器归属 GUI**未执行；受控后端保存、旧结果失效测试已通过，仍不能取代经授权远端 E2E，相关远端 Gate 阻塞。④ **实体拼音候选、其他物理触控板与外接显示设备**未验；ABC 路径和 AppKit 组合输入契约通过，但不能声明真实候选/设备组合通过；按设备可用性补测。⑤ GUI 未单独遍历 Markdown／TSX／HTML/CSS 的全部主题、字体、最窄窗口和动态外观组合；已有 22 条原生语法高亮测试及 Diff 明／暗像素合约通过，完整视觉矩阵仍须补验。以上条件不推断为产品 bug，也不纳入本次代码提交。
- **文档/命令**：`AGENTS.md` 保护正式 App 的约束、`docs/testing.md` 与 Makefile 的 `test:ui` 目标、`docs/development.md` 本机签名指导、`docs/features/editor.md` 和 `docs/features/diff.md` 已核对；相关路径、类名、测试结果与源码一致。`git diff --check`、`todo validate` 均通过，Feature 状态和审计文件按 Skill 默认保留本地，不提交。

## Gate（是否允许进入下一阶段）

- 结论：**Go（仅 P2 迁移与进入 P3）；跨环境／发布最终 Gate 仍 No-Go。**
- 理由：P2 旧方法 **144/144** 均有新归属，5 个审计 finding 已以真实 Red/Green 验证关闭；全量宿主 **627/635 Passed（8 项仅因真实 Windows SSH 缺位而跳过）**、完整 Dev App UI **21/21**、正式身份 `make build` 与签名均通过。上述未执行环境属于本次无法取得的外部验证，已明确独立阻塞 **跨平台兼容/CI/发布 Gate**，不掩盖它们，但不再阻止经审计的本机 P2 测试分层实施进入 P3；这与 P1 阶段的条件性 Go 门槛一致。

## 最终状态与剩余风险

- 当前状态：**Resolved（P2 本机迁移实现与审计；P3 可执行）；环境补验仍 Open（不属于已完成测试声明）。**
- 剩余风险：待获得 CI Runner、macOS 15.6 和经许可的 Windows SSH／实体输入设备后逐项补验。最终全项目分离目标仍含 P3／P4／P5，当前 P2 不冒称所有旧 UI 宿主测试均已删除。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


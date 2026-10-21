# Focus 执行证据

环境：Apple Silicon，macOS 27.2 (26B5101f)，Xcode 27.2 (27B5038j)，现有 Bailey scheme / XCTest。正式 Bailey PID 48459 不退出、不重启、不输入；用户已明确允许隔离实例前台鼠标、键盘和截图验收。计划、状态、审计与本文件不提交。

## P1-T1

- `DockWorkspaceTests.testToolsAreNotTheMostRecentWorkContentAndCloseTheirOwnPanel` 在旧实现失败；工具仍返回旧 Browser，⌘W 关闭了工作标签。Red 原始输出：`~/Library/Application Support/rtk/tee/1792514645_make_tes_161da1.log`。
- 首次多缓冲夹具仅赋值 `FileTab.text`，没有调用 `refreshDirtyState`，未建立脏状态；此轮不算有效保存 Red。修正夹具后临时恢复旧 `autoSaveEditedTabs`，等待 8 秒后第一文件仍脏，保存 Red：`1792514778_make_tes_2182bb.log`。没有隐藏或禁用失败用例。
- Green：`make test ONLY_TESTING='BaileyTests/DockWorkspaceTests BaileyTests/SessionStoreTests BaileyTests/WorkspaceWindowIsolationTests'`，完整退出 0，35 tests，0 failures；原始输出 `1792514809_make_tes_bbf0c6.log`。
- 覆盖：工具/工作内容目标、各工具关闭、重复选择同一 MRU、8 个工作标签与 6+ 横纵嵌套、移动/移除/恢复/无效组 ID、其它组 selected 不变、纯活动切换零快照事件且编码结果一致；两个独立脏文件最终磁盘字节；既有窗口隔离、快照测试。
- 原生菜单和 first responder 联动依赖 P1-T2，继续同阶段接入，不以模型测试冒充 GUI。

## P1-T2

- 真实 Red：同签名 Debug 隔离 App PID 77581，窗口 201329，仅打开 `/tmp/bailey-focus-ui.Lsas8s`。点击 File Manager 标签后 AX 焦点仍为原编辑器；键入 `RED_TOOL_INPUT` 后原编辑器正文出现该字节。Peekaboo 类型工具返回 dispatch 未验证，随后重新读取 AX 确认了实际错误，没有把派发当结果。证据：`/tmp/bailey-focus-red-ui.json`、`/tmp/bailey-focus-before.png`、`/tmp/bailey-focus-before.mp4`。已仅结束该隔离 PID。
- 扩展回归发现中间布局回退引发移动自动保存：`PaneRetentionTests.testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll` 的 Undo/磁盘断言失败。根因是先移除源组、回退工具、再激活新组。改为由 `DockWorkspaceModel.updateLayout` 一次确定最终布局和活动目标，不对同一活动内容触发失焦。
- 两个原生测试以前只 `orderFront`，却要求后台窗口主动抢焦点；修正为 `NSApp.activate` 与实际 key window，保留生产代码的前台限制。不是删除断言或允许后台聚焦。
- 针对性 Green：Dock 8 tests、上述移动/Browser 原生回归 2 tests、工具/原编辑器真实失焦与 Unicode 保存 1 test，共 11 tests，0 failures，完整退出 0；输出 `1792515162_make_tes_cbba31.log`。
- 扩展 Green：`make test ONLY_TESTING='BaileyTests/PaneRetentionTests BaileyTests/WorkspaceContentIdentityTests BaileyTests/WorkspaceWindowIsolationTests BaileyTests/TreeRowHitTestingTests BaileyTests/DiffTabTests BaileyTests/EditorTextInputTests BaileyTests/DockWorkspaceTests'`，完整退出 0，101 tests、0 failures，输出 `1792515414_make_tes_7a6e09.log`；`make build` 与严格验签完整退出 0，输出 `1792515425_make_build.log`。
- 隔离 App PID 81401 / 主窗 201894：File Manager 获得活动组后不再保留旧编辑器 AX 焦点；使用不重新聚焦窗口的原始前台输入 `RAW_TOOL_INPUT` 后，编辑器正文无该字节。真实 ⌘W 只移除 File Manager 标签，工作区仍有独立「甲.swift」工作标签，Git 仍可见。Settings 的真实 ⌘W 只关闭 General 窗口，主窗口仍在。离开编辑器后磁盘确有 `GREEN_FOCUS_中文😀`。证据 `/tmp/bailey-focus-p1-green-ui.json`、`/tmp/bailey-focus-p1-green.png`、临时文件最终字节。
- 工具差异：Peekaboo `type --pid … --foreground` 的窗口聚焦准备会重新选择原生编辑器，因此该工具路径确实向临时文件插入过 `MUST_NOT_ENTER_EDITOR` 的一部分；随后重新观察、使用无聚焦准备的原始前台输入，才作为工具区域不漏输入的结果。没有把旧树行的文件名误当工作标签，⌘W 使用独立标签名称精确核对。测试实例均已按精确 PID 清理，正式 PID 48459 未操作。
- 完整原生回归中系统未必授予 XCTest 前台。工作区测试仍验证区域状态、原对象和最终字节；只有真的 key/active 时要求自动 first responder 转移。组件 Browser 使用注入的 `canFocus` 作为唯一请求许可，生产许可由 Dock 所属窗口检查，不额外复制全局焦点状态。独立 App 已补真正前台键入与 ⌘W/Settings 结果。

## 覆盖核销范围

- 状态维度：组 selected / 最近工作标签 / 活动区域 / 原生响应者；工具、空组、Terminal、TextKit、Browser 地址/正文、Diff review/edit；新建、重命名、查找、Palette、Sheet、Settings。
- 布局维度：单组、三组、横/纵/6+ 嵌套，切组/切项目/切窗口、移动/合并/边缘分割/取消/关闭/恢复；hover 不激活，落地才激活，身份与 Undo/滚动保留。
- 数据维度：本机临时文件、Unicode/emoji、多个脏缓冲、文件与 Diff、失败保留、异步保存期间的新编辑；不使用正式用户项目作夹具。
- 界面维度：明暗、窄宽、长标题、大字号、键盘与基础 AX；不修改共享用户设置以换取测试覆盖。
- 环境缺口逐项核销：macOS 15.6 机器不可用，使用 SDK 可用性与当前系统 NativeUI 替代，旧运行时待独立机器补验；专用授权 SSH 主机未由本次用户指定，不借用现有 master，受控后端和本机保存替代但不证明真实网络/断线；当前没有独立 XCUITest target，工作区 XCTest 不冒充 E2E，独立隔离 App 另行核对实际输入与磁盘。上述不是已通过的实机条件。

## P2-T1

- 旧外观基线：`/tmp/bailey-focus-before.png` 与录屏；多个 selected 背景不能标出活动区域。
- `make test ONLY_TESTING='BaileyTests/DockWorkspaceTests BaileyTests/WorkspaceWindowIsolationTests'` 完整退出 0，30 tests、0 failures；`make build` 严格验签退出 0。日志分别为 `1792515699_make_tes_5ff559.log` 与 `1792515706_make_build.log`。
- 独立 App PID 83245 / 窗口 201988：原编辑组→Git，只出现一个整体内描边；Settings key 时主窗边框消失、各组 selected 背景保留、尺寸未变。真实截图 `bailey-focus-outline-projects.png`、`bailey-focus-outline-git.png`、`bailey-focus-outline-inactive.png`；视频 `/tmp/bailey-focus-outline.mp4`。只结束此测试 PID。

## P2-T2

- Palette 真实 Red：PID 83245 中从编辑器打开 ⌘P，执行 File Manager，关闭后 first responder 又成为旧 NSTextView，证据 `/tmp/bailey-focus-palette-red.json` / `.png`。
- 修复后 PID 84667 / 窗口 202143：相同动作后 AX 为原窗口／区域空焦点而非旧编辑器，原始输入 `PALETTE_MUST_NOT_LEAK` 未进入正文；⌘W 只移除 Files，独立「甲.swift」标签仍在。证据 `/tmp/bailey-focus-palette-green.json` / `.png`。
- Palette 取消：⌘P 的实际 first responder 是 AXTextField；Escape 后为原编辑器 AXTextArea；真实输入 `CANCEL_RESTORED中文😀`、⌘S 后核对磁盘字节。
- 原生 Terminal 输入：真实键入 Shell 命令，最终 `/tmp/bailey-focus-ui.Lsas8s/terminal-marker` 为 `TERMINAL_INPUT_OK`。拖动前后通过 Shell 自身写下 `$$`，`shell-pid` 与 `shell-pid-after-drag` 均为 84821，证明不是重建 Shell 冒充焦点恢复。
- 真实拖放：文件从窄左组拖到右边缘，新增工作组后 AXTextArea 位于 x=1009；Terminal 从原组拖到 Git 底边，再合并入文件所在组。只有落地才换活动组。截图 `bailey-focus-after-drag.png`、`bailey-focus-terminal-moved.png`、`bailey-focus-merged-terminal.png`；视频 `/tmp/bailey-focus-drag.mp4`。一次源标签被裁剪的拖动虽然工具报成功，但实际未移动，因此不计作通过；先显式选中使其可见，再重新拖动并按坐标/标签/输入核对结果。
- Find 停车路径：Terminal 查找框实际 AXTextField（x=1496,y=94.5），切到同组文件后原 Terminal 停车，实际焦点变为右组 NSTextView；真实输入 `PARKED_FIND_REAL_FIELD_OK` 后 ⌘S 核对文件字节，旧查找关闭恢复没有抢回停车表面。`/tmp/bailey-focus-parked-find-green.json`。
- 双主窗：通过真实 File → New Window 建立 202194，旧 202143 的 key=false；背景截图 `/tmp/bailey-focus-second-window-inactive.png` 无边框。空新窗口的 ⌘F 不操作旧文档，⌘W 只关闭新窗口，旧主窗恢复 key。正式 App PID 48459 未操作。
- 原生所有权边界回归明确检查可见编辑器、活动工具、同窗停车 Surface、隐藏标签、换项目、已关闭编辑器与窗口。额外矩阵为 2 外观 × 3 尺寸 × 4 内容目标，使用长中文/emoji 文件名，核对原文本视图、正文与磁盘；不改共享用户设置。
- 该轮 32 项 Dock/窗口边界测试与 `make build`/严格验签完整退出 0，日志 `1792515915_make_tes_ed6320.log` / `1792515922_make_build.log`；此前跨原生保留/身份回归为 54 tests、0 failures，日志 `1792515883_make_tes_6c11d6.log`。
- 窄 Find 真实取证显示字段 x=-88；新增 NativeUI Red 在 150/210 pt、明暗两态得到 minX=-65.5/-35.5 四次失败（`1792516213_make_tes_bb247c.log`），不能称为可用输入。`ViewThatFits` 保留所有功能改为窄栏两行，150/210/400/900 pt × 2 外观全部 Green；连同边界 33 tests、0 failures（`1792516291_make_tes_5ace4c.log`）。
- Find 延迟 UI 与恢复还核对实际可见宿主、前台组以及仍开启/已关闭状态，防止重挂载的 onDisappear 抢走新查找框。`TerminalFind` 有界持有原 Surface；已核对 Surface.events 对 Session 是 weak，没有回边循环，不再依赖对异步 UI 不安全的 unowned 生命周期假设。

## 授权与剩余环境补验

- P2 审计 F-01 实际发现：隔离 PID 37568 中把开启 Find 的终端移入左窄组，字段为 x=8,width=160，输入查询成功，但活动边框随后跳到右 Files，Escape 后 AXWindow 接收焦点，Shell marker 未产生。截图 `/tmp/bailey-focus-final-narrow-find.png`、`/tmp/bailey-focus-final-find-loss.png` 和 AX 查询内容保留。该轮不算关闭恢复通过。
- 初次尝试以 XCTest 自动获得系统前台作为前提，启动时未成立；`bailey-focus-find-restore-red.log` 的初始等待失败不是有效产品 Red，相关依赖前台的草稿已删除。一次误启动的并发定位命令在进入构建前已取消，不将其当作验证结果。
- 改为真实 `ContentView` 中直接建立原生 field editor，不假装系统前台：`/tmp/bailey-focus-field-owner-red.log` 的归属用例两项 Red，正确左组返回 false、错误右组返回 true。进一步诊断 `/tmp/bailey-focus-field-owner-diagnostic.log`：实际输入框 bounds 为 164×15，而 SwiftUI 返回的 visibleRect 为 (-6,-88.5,1800,732)，跨越整窗；旧代码误用这个中心。根因修复在共享 `DockGroupFocusView.containsResponder` 将 visibleRect 与自身 bounds 取交集，保留文本视口裁剪和停车拒绝，不增加延时、重试或查找特判。该回归同时检查实际输入内容进入 TerminalFind.query；最终前台 Shell 字节仍由独立 App 补验。
- F-01 Green：`/tmp/bailey-focus-field-owner-green.log` 为 73 tests、0 failures、退出 0；提交 `9c95cc2`。PID 40540 同 UUID 恢复窄左终端，实际字段 x=8,width=160，键入 `NARROW_GREEN_中文` 后边框仍在左组；Escape 后 AXTextArea 为源 Surface (x=2,width=212)。真实 Shell 命令生成 `/tmp/bailey-focus-ui.Lsas8s/narrow-marker`，内容 `NARROW_RESTORED_OK`。证据 `/tmp/bailey-focus-audit-find-typed.{json,png}`、`bailey-focus-audit-find-dismissed.json`、`bailey-focus-audit-find-green.png`。
- 空组真实拖放的诊断：直接窗口截图不包含系统通知。多次“已派发”实际上被右上角持续的「正在后台运行的 App」通知横幅遮住，原生鼠标事件没有送到 Bailey；桌面截图 `/tmp/bailey-focus-desktop-overlay.png` 和 System Events 命中 NotificationCenter 证实，不据此改产品。仅将本次测试窗口移到 y=200、1800×900，避开横幅后 PID 41259 把 Git 从原右组真实拖入中央空组：`Add Panel` 消失，Git 标签从 x=1567 移到 x=221，Files 留在右组 x=1467。截图 `/tmp/bailey-focus-empty-real-after.png`。诊断日志和临时 mouse trace 均未进入提交，所有诊断改动已移除，测试 PID 已清理。

- 收尾边界 Red：`/tmp/bailey-focus-final-boundaries-red.log` 中 5 个用例共 37 个失败（含恢复组 ID 超时）。空组移动覆盖 3 工具 × 中央/四边，真正的 `Project.selectTab` 暴露纯焦点仍请求快照；恢复组 ID 后原生读点仍持有旧 ID；停车前即解除回调的测试暴露依赖卸载时机的问题。
- 第一轮修正后 `/tmp/bailey-focus-final-boundaries-probe.log` 的 38 项中仍有 6 个断言失败：3 个像素误报，3 个实际工作区停车回调被旧宿主晚到的 update 重装。最终从 `TerminalHostView.updateNSView` 的物理 Surface 所有权拒绝过期宿主，不在每个回调叠补丁。
- `/tmp/bailey-focus-final-boundaries-green.log`：39 tests，0 failures，完整 `TEST SUCCEEDED`。包括上述全部入口、真实布局恢复保留编辑器身份、150/210/400/900 pt × 明暗 Find、窗口所有权与停车生命周期。
- 首次全量 `make test` 启用真实 `windows` SSH，`/tmp/bailey-focus-full-test.log`：573 tests，仅原有行号背景像素用例 3 项断言失败。诊断确认 cache 位图的原始 RGB 与主题完全相同，`colorAt` 的 calibrated RGB 再转换时改变了数值。提交 `5f12573` 为测试目标声明 sRGB 并按真实位深读通道，原容差不变，不修改产品主题；针对性明暗用例已 Green。其余实际 SSH/PTY/Git/8 MiB 保存与恢复用例通过；完整重跑以最终记录为准。
- 真实 Windows 主机不能创建测试符号链接（`P4_LIVE_SYMLINK_UNAVAILABLE status=1`），因此该分支没有执行，不能用 XCTest 零 skip 冒充该能力已覆盖。本机及受控后端的路径/符号链接回归是替代证据；在具备创建权限的远端补验，影响是 Windows 特有 symlink 实机路径未获本轮证明，不阻塞不改变路径解析的焦点实现。
- 最终全量：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test`，`/tmp/bailey-focus-full-green.log`，578 tests、0 failures，完整退出 0。原始结果 `build/DerivedData/Logs/Test/Test-Bailey-2026.10.21_01-32-41-+0800.xcresult`。真实 SSH 的已执行用例均 passed；未将上面的 symlink capability 分支算作覆盖。
- F-01 修复后最终冻结版本 `9c95cc2` 再跑相同完整命令：`/tmp/bailey-focus-final-full.log`，579 tests 全部 passed，0 failures、0 skipped，完整退出 0；结构化 xcresult 已核对。结果包 `build/DerivedData/Logs/Test/Test-Bailey-2026.10.21_02-07-22-+0800.xcresult`。此记录替代前一轮作为最终源码全量证据；Windows 符号链接能力限制仍如实保留。
- 最终 Release 优化 XCTest：`make test CONFIGURATION=Release SIGNING_FLAGS=ENABLE_TESTABILITY=YES ONLY_TESTING='BaileyTests/DockWorkspaceTests BaileyTests/PaneRetentionTests BaileyTests/WorkspaceWindowIsolationTests BaileyTests/WorkspaceContentIdentityTests BaileyTests/DiffTabTests BaileyTests/EditorTextInputTests BaileyTests/SessionStoreTests BaileyTests/TreeRowHitTestingTests'`，119 passed、0 failed、0 skipped，退出 0。日志 `/tmp/bailey-focus-audit-release-test.log`，结果 `Test-Bailey-2026.10.21_02-22-51-+0800.xcresult`。随后以普通配置重新构建，不保留 Release 测试专用 testability 设置。
- `make build` 最终 Debug 严格验签退出 0（`/tmp/bailey-focus-audit-final-debug-build.log`），测试 PlugIns 已被普通构建移除。2026-10-21 02:27 本地整包安装：同磁盘暂存 ditto、暂存包严格验签、目录原子 rename、安装后严格验签与可执行 SHA-256 相同，退出 0，临时备份清理完毕；`/Applications/Bailey.app` 的 ID 仍为 `chiimagnus.bailey`，SHA-256 为 `7b1e1a3fdbdf59bd102c951cf14d06218d260c0ebac73b4dec1e5badff848502`。正式 PID 48459 持续运行，未退出/启动/重启；安装不等同当前进程已加载新代码。
- 最终普通 `make build:release` 严格验签退出 0（`/tmp/bailey-focus-audit-final-release-build.log`），没有测试 PlugIns，最低系统 Mach-O `minos=15.6`、SDK=27.2。最终 Debug/Release 使用同一正式 Bundle ID，无新增开发版身份；未推送或发布。
- 安装后的额外 Release 独立 GUI 尝试 PID 67650 不能读取 AX 窗口；进一步核对工具状态，Screen Recording、Accessibility、Event Synthesizing 均变为 false，System Events 返回 -1743。此前同一工具的 Debug 前台验收成功；这里只记录安装后的时间关联，不臆断权限变化的因果，也不把「窗口不可访问」当产品无窗口/焦点失败。Release 进程 sample 显示正常 AppKit 主循环，但这不证明输入行为；该追加 GUI 未完成，只有 119 项优化原生测试和已完成的 Debug 独立 App 作为不同层级替代证据。未重启正式 App、未修改隐私设置以强行换覆盖率，已仅清理 PID 67650。权限恢复后在独立环境补验 Release GUI，不阻塞本计划已完成的同源码签名 Debug GUI、构建与测试交付。
- 收尾检查时发现计划/证据文件已经暂存；本次未对功能目录执行 git add 或提交，也不擅自撤销既有暂存。所有产品代码、测试和当前文档已原子提交；功能目录留本地供复核。
- 最终产品提交 diff 与工作树 `git diff --check` 均通过。既有暂存的两个审计旧快照仍有生成器尾空行提示；工作文件已规范化，不覆盖既有索引来掩盖该提示。该本地计划索引不在产品提交或构建输入内。

- 用户随后明确完整授权且要求不再重复询问；最终全量测试使用文档既有 `windows` 主机、测试专用 UUID ControlPath 与临时仓库，已沿 `SSHHostCommandRunner` 核对不会借用用户 master。该轮实机结果以最终日志为准，覆盖核销范围中此前“未授权主机”的记录仅描述早期状态。
- macOS 15.6 没有实机／虚拟机，只有当前 macOS 27.2 与部署目标编译检查；旧系统须在对应设备补验，不把它写成通过。
- 没有独立图形登录会话，VoiceOver 全程语音走查与长时间五分屏后台资源观测没有冒充完成；现有标准按钮/字段 AX、实际键盘、原生对象保留/释放与大文件回归提供替代证据，但不等同该专项实测。
- 嵌入式 WebKit 使用既有 NativeUI 正文、表单/历史/重挂载回归；本轮 Peekaboo 不操作浏览器内容，不能将其它控件的端到端证据当成网页全交互 E2E。无独立嵌入浏览器自动化端点，后续须在受控 App GUI 对网页输入单独补验。
- 真实中文输入法候选窗口/切换输入法没有逐项实测：本轮实际键入的是 Unicode 文本，不能冒充拼音候选交互。现有 `EditorTextInputTests` 与高亮 composition 用例核对 marked text、选择、提交和 Undo；后续在独立图形会话以真实 IME 补验。对本轮未改动的输入法协议没有已证实缺陷，不阻塞当前焦点交付，但不作全输入法兼容承诺。
- 没有为验证而改变共享用户大字号/系统键盘导航设置或剪贴板。原生字体/几何、Unicode 组合输入、Undo 与多尺寸矩阵提供替代证据；大字号 Dock 布局与真实 Cmd-C/V 跨区域还须在独立设置/剪贴板环境补验，不冒充本轮独立 App 已做。其不阻塞当前标准设置下的输入归属、保存与菜单结果交付，不是任意设置已认证。
- 五个并发原生编辑器/多轮释放、十万行工作区与六组以上模型布局均已在现有测试执行；持续数小时的五分屏 GUI/VoiceOver 专项不是短时 E2E 的等价物。没有长期稳定资源指标，不以本轮结果作内存/FPS 性能承诺；后续独立会话持续运行并采集 Instruments 后再给该结论。

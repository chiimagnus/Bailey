# Audit P4 - swiftui-observation-mvvm-refactor

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/swiftui-observation-mvvm-refactor/`
- 粒度：`phase`

## 任务看板

- [x] P4-T1 清理未接入产品的 SSH 会话临时端口转发链
- [x] P4-T2 终端会话和查找条的 Observation／原生事件桥
- [x] P4-T3 文件编辑标签的可观察状态与可靠保存
- [x] P4-T4 差异标签和 WebKit 渲染器的可观察状态
- [x] P4-T5 浏览器标签 Observation 与 WKWebView delegate/KVO 适配

## 任务到文件的映射

- P4-T1
  - `kero/Remote/RemoteConnection.swift`、已删除的 `PortForwardController`；`RemoteLifetimeTests`、`RemoteCommandsTests`、`WorkspaceIdentityTests`；实际隧道入口 `keroApp/TunnelManager/TunnelSettingsView`。
- P4-T2
  - `TerminalSession`、`TerminalFind`、`TerminalFindBar`、Ghostty 原生事件、`Project.scheduleRemoteTabRebind`；`PaneRetentionTests`。
- P4-T3
  - `FileViewerView`、`SourceTextEditor`、`EditorFind`、`PaneTab`、`WorkspaceChrome`；`FileTabTests`、`PaneRetentionTests`、`WorkspaceIdentityTests`。
- P4-T4
  - `DiffViewerView`、`PaneTab`、`WorkspaceChrome`；Pierre 原生宿主两个文件、工程依赖引用、出处与许可证；`DiffTabTests`、依赖/Git/终端文档。
- P4-T5
  - `BrowserView`、`Project`、`TabSwitcherView`、`WorkspaceChrome`；`PaneRetentionTests`、`SessionStoreTests`。

## 发现项

## 发现 F-07

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/Tunnels/TunnelDefinition.swift:216`
- 摘要：`tunnels.toml 的无限大/NaN 端口进入 Int(Double) 时会让 App 直接崩溃`
- 风险：`用户手动编辑或损坏的配置文件会在启动隧道加载时触发 Swift Fatal error，整个 Kero 启动失败；当前 Debug 自检未覆盖异常输入`
- 预期修复：`TunnelStore.parse 用 Int(exactly:) 安全转换端口数值，跳过单条非法隧道并保留其余有效条目，不新增冗余配置恢复逻辑`
- 验证：`make test ONLY_TESTING=KeroTests/TunnelStoreTests/testMalformedPortsDoNotCrashOrCorruptValidTunnels; make test; make build:release`
- 解决证据：`c1848ca：传入 local-port=1e309、nan 的独立 XCTest 先触发真实 Swift Fatal error，后改为 Int(exactly:) 仅跳过无效条目；TunnelStoreTests 4/4、全量 93/93、Debug/Release 验签通过。`


## 发现 F-06

- 任务：`P4-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Remote/Tunnels/TunnelManager.swift:47`
- 摘要：`隧道核心配置检查仍以 Debug App 启动时 assert 自检执行，正式 XCTest 不运行该用例`
- 风险：`开发版每次启动执行无关测试，而 CI 和 XCTest 无法单独枚举、报告或复现隧道配置解析和端口冲突回归`
- 预期修复：`将 TunnelStore 的纯配置、转发与冲突自检转为正式 XCTest，删除生产 Debug 启动时的 runSelfCheck 及过时检查脚本说明`
- 验证：`make test ONLY_TESTING=KeroTests/TunnelStoreTests; make test; make build:release`
- 解决证据：`c1848ca：删除 TunnelManager.start 中 DEBUG runSelfCheck 和 TunnelDefinition.swift 中 81 行断言自检；迁入 TunnelStoreTests 4 个 XCTest 用例覆盖有效/无效规则、绑定端口与本地/反向转发；完整 XCTest 93/93、Debug/Release 构建与严格签名校验通过。`


## 发现 F-05

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/DiffViewerView.swift:790`
- 摘要：`跨历史 Diff 标签 A-B-A 时 SwiftUI 复用错误 NSView 内容`
- 风险：`标签身份和原生 Diff 文档不一致，用户会查看另一提交的文本`
- 预期修复：`对每个 DiffTab 保留独立原生视图并在 SwiftUI 挂载边界按标签 ID 区分身份`
- 验证：`make test ONLY_TESTING=KeroTests/DiffTabTests/testSwitchingLoadedDiffTabsKeepsEachNativeDocument`
- 解决证据：`ceceeb1：独立 DiffTab 原生内容身份恢复；新增 DiffTabTests A-B-A 原生宿主回归；2026-10-14 全量 XCTest 84/84 与签名 Debug 构建通过。`


## 发现 F-04

- 任务：`P4-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`KeroTests/DiffTabTests.swift:372`
- 摘要：`原生 Diff 回归的固定延迟输入在全量测试中未产生编辑，缺少实际 DOM 输入目标的同步证据`
- 风险：`单类通过不能证明全套验收稳定；派发到过期或未就绪的 DOM 不能代表真实编辑`
- 预期修复：`读取实际渲染器和 DOM 状态，消除固定延迟和悬空目标的假设，不延长超时或重试输入`
- 验证：`全量失败日志定位、原生事件目标检查、针对性及全量 XCTest`
- 解决证据：`807d666；实测XCTest非激活DOM selection为0，删除手工Range/固定等待，真实编辑键盘事件同步；Diff7/7、全量59/59、build/严格验签PASS，日志/tmp/kero-p4-audit-final-{tests,build}.log。`


## 发现 F-03

- 任务：`P4-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:125`
- 摘要：`合并的断线与新连接事件跳过只读状态后，文件和差异标签仍使用旧通道`
- 风险：`同机器的新连接不能接管保存；旧写入可在目标已更换后清除未保存标记`
- 预期修复：`在真实后端身份边界识别连接更换，保留同连接身份且不制造强引用环；文件与差异切换同时失效旧请求`
- 验证：`控制后端在途写入加真实 Project 连接替换事件，验证无本机回退、dirty 保留及旧结果拒绝`
- 解决证据：`d7d9a2b；evidence/p4-t4/channel-handoff.md：File5/5、Diff7/7、Remote3/3、Identity4/4、build/严格验签PASS。原错误已复现；F-04原生输入同步仍独立Open。`


## 发现 F-02

- 任务：`P4-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Editor/SourceTextEditor.swift:61`
- 摘要：`临时 View 重挂载重新创建 STTextView，丢弃原生撤销栈`
- 风险：`P4 明确要求的撤销保留未满足；已有测试仅在重挂载之前撤销`
- 预期修复：`由现有文件标签持有唯一原生编辑资源，临时宿主不重建编辑器；验证重载和释放边界`
- 验证：`PaneRetentionTests 原生重挂载后的 undo/redo、滚动、身份、干净重载和最终释放`
- 解决证据：`de63012；旧实现原生挂载后撤销回归 FAIL，修复后 PaneRetention5/5、FileTab4/4、build/严格验签 PASS；首次挂载与切回各330813原生像素采样0差异。evidence/p4-t3/validation.md。`


## 发现 F-01

- 任务：`P4-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`docs/BROWSER.md:14`
- 摘要：`维护文档仍承诺已删除的信息面板和从未接入产品的会话转发`
- 风险：`用户与后续维护者依赖不存在的产品入口和生命周期保证`
- 预期修复：`删除死路径承诺，保留真实长期隧道及 SSH 安全边界`
- 验证：`核对 keroApp/TunnelManager/TunnelSettingsView 调用链与文档链接`
- 解决证据：`0fe2a8c；源码入口与三个文档链接核对通过，git diff --check PASS。未建立 SSH 或隧道。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- F-01：`0fe2a8c` 删除不存在的 Info/会话转发文档承诺，保留真实设置长期隧道。
- F-02：`de63012` 文件标签保留真实 TextKit 资源、撤销与滚动，实际重载失效旧 owner，关闭释放。
- F-03：`d7d9a2b` 在同机器多通道交接处按后端身份失效旧请求；不以只读中间态为前提，连接与后端无强环。
- F-04：`807d666` 测试通过真实渲染器键盘事件建立光标，删除固定延迟和失效 DOM Range；不改产品 JS。

## 验证日志

- 原生挂载后撤销回归：旧实现 FAIL，修复后 `PaneRetentionTests` 5/5 PASS；900px 滚动、实际重载、旧回调、释放覆盖。首次挂载与切回编辑区 330,813 原生像素采样均 0 差异。
- 通道交接旧实现 FAIL；`FileTabTests` 5/5、`DiffTabTests` 7/7、`RemoteLifetimeTests` 3/3、`WorkspaceIdentityTests` 4/4 PASS。实际写入与本机 sentinel 证明目标保护，不只验证事件。
- `make test` -> 59/59 PASS，`/tmp/kero-p4-audit-final-tests.log`。之前全量失败和诊断日志保留，不冒称从未失败。
- `make build`、`codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app` -> PASS，`/tmp/kero-p4-audit-final-build.log`。
- 受影响的终端/SSH/File/Diff/Browser 中旧 ObservableObject/Published/objectWillChange/UI wrapper 已删除；Browser 的 Combine 只负责真实 WK KVO。真正 Tunnel NSTableView 的 Combine 属计划保留边界。
- `rtk git diff --check` -> PASS；计划/图片/日志未提交，正式 PID 60367 未操作。用户要求的当前 Xcode 单一验收已更新 idea/plan-p7，不再要求其他版本。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：四项有证据的发现均已修复提交；唯一资源所有权、实际保存目标与生命周期回归通过，原生内容区零差异，允许继续 P5。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：真实 SSH、物理 Diff 键盘输入、跨窗口手动拖动与正式 App 重启恢复未测，不冒称通过；P5 继续窗口菜单/焦点/停靠验收。当前仍 Swift 5 语言模式，Swift 6 真正切换归 P7。既有项目/窗口/批量关闭 UX 缺陷按用户确认的纯重构边界单独记录，不声称已修复。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


## 2026-10-14 独立重审：P4（不继承旧审计结论）

| todo 任务 | 原提交／后续修复 | 当前执行路径／独立证据 | 判定 |
| --- | --- | --- | --- |
| P4-T1 | `a7f83ce`，后审 `c1848ca` | per-session 死转发已删除，真实 `TunnelManager` 仍被 App/设置消费；将启动时的自检移为 TunnelStoreTests，异常 TOML 端口复现启动崩溃后改为安全解析。 | F-06/F-07 已解决；保留真实隧道事件桥 |
| P4-T2 | `7664467` | TerminalSession/RemoteConnection/TerminalFind 状态由 Project/Terminal View 原生消费；PaneRetentionTests、RemoteLifetimeTests 覆盖进程与变更。 | 有现行消费者，无旧 Combine UI 广播 |
| P4-T3 | `5bd9e26`，`de63012`，`d7d9a2b` | FileTab 保留 STTextView/保存基线与 SSH 机器身份，`SourceTextEditor` 的 Coordinator 及窗口第一帧恢复可达；FileTabTests 对接真实读写/断连。 | 保留稳定原生视图，跨工作区测试已增补 |
| P4-T4 | `ee243e0`，`807d666`；后由 `6b3081b` 替换 Pierre；`ceceeb1` | `DiffTab` Git/SSH 读取由现行 `DiffNativeSurface` 消费，Pierre WebKit 渲染已删除；`ceceeb1` 解决 A→B→A 旧 NSView 身份污染（F-05），有红绿原生回归。 | 当前仅维护 TextKit；原任务 WebKit 方案已退出生产 |
| P4-T5 | `b1c3550` | BrowserTab Observation 状态由 BrowserView 与 TabSwitcher 消费，WebKit KVO 订阅必要；PaneRetentionTests 覆盖 native WebView 内容与滚动重挂载。 | 不删除必要 KVO 桥 |

**阶段门槛**：后审增加跨文件／Diff／浏览器 ContentView 切换及隧道 TOML 边界测试；其中崩溃复现红／绿，最终 XCTest 93/93、Debug/Release 构建与验签通过。真实用户点击、SSH 实机、跨进程恢复与 GUI 截图对照仍待独立验收。

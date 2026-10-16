# Audit P2 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 统一按需加载、解码与断线只读
- [x] P2-T2 移除高亮无效字体事务

## 任务到文件的映射

- P2-T1
  - `e82cd03`：FileViewerView、LocalWorkspaceBackend、SourceTextEditor、Project、SSHHostWorkspaces；DiffTab 加载失效、Vendor AX 所有者与 Diff 重复 override 删除；七组受影响 XCTest 及 editor/ssh/diff/development 文档。
- P2-T2
  - `b440eb0`：SyntaxHighlightPlugin、SyntaxHighlightingTests、editor/testing 文档；原生单变量对照与 sample 归 `evidence-p2.md`。

## 发现项

## 发现 F-09

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Editor/SourceTextEditor.swift:213; kero/Editor/FileViewerView.swift:276-305`
- 摘要：`刷新失败后保留旧预览却仍允许原生编辑及写回磁盘`
- 风险：`Red 38 个 FileTabTests 中 2 项失败：瞬时读取失败后 editor.isEditable 仍为 true；模拟编辑并保存的确发起了旧缓存写盘，若外部文件已变更会覆盖新字节。`
- 预期修复：`由 FileTab.reloadError 驱动现有原生 isEditable 资格，刷新成功前允许选择复制但拒绝编辑；模型保存入口同样禁止把未校验旧缓存写回，成功重读后自动解锁，不增加另一套确认 UI。`
- 验证：`Red build/p2-audit-stale-write-red2.log；Green FileTabTests native disabled/AX/undo 恢复以及 backend.write 0调用后续正常保存，定向和完整回归。`
- 解决证据：`Red build/p2-audit-stale-write-red2.log：原生编辑器刷新失败后仍可编辑且后台确实发出过期写；FileTab 保存前禁止 stale buffer write，SourceTextEditor 原生 isEditable 临时只读但仍能选择复制/查找，成功重读后恢复编辑/AX/undo/save。Green build/p2-audit-38-green.log FileTabTests 38/38，PaneRetentionTests 12/12 build/p2-audit-pane-final.log。`


## 发现 F-08

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:126-131; kero/Workspace/Project.swift:518-526`
- 摘要：`刷新失败保留旧预览后 Git Ignore 仍把旧文本当成最新磁盘内容并追加`
- 风险：`受控现有 FileTab 初读 old-rule 成功；刷新失败保持旧显示后 waitForTextBeforeAppending 返回成功，随后 appendText 写旧缓存；真实磁盘外部规则可能丢失。`
- 预期修复：`FileTab 的非视图追加前置读取必须检验本次磁盘刷新确已成功；失败显式抛错并保留编辑、不进入 append/save。`
- 验证：`新增 FileTabTests.testAppendRejectsStaleCachedTextWhenFreshReadFails 实测 Red 四个断言失败；修复后 Green，后续成功刷新可以继续追加；现有 GitWorkspaceMenuTests 和真实 SSH 验证。`
- 解决证据：`Red build/p2-audit-append-stale-red.log 4个断言：刷新失败后旧内容仍被 Git Ignore 消费并追加。FileTab.waitForTextBeforeAppending 检查 reloadError 并拒绝附加，原规则不变；恢复后重新读取外部规则且追加正常。Green build/p2-audit-38-green.log，GitWorkspaceMenuTests 7/7 build/p2-audit-gitignore-final.log。`


## 发现 F-07

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:304-350`
- 摘要：`干净已加载文件一次瞬时读取失败直接清空旧正文和编辑器身份`
- 风险：`受控后端读取先成功再临时抛错，刷新后 FileTab.text 从原文变空、content 转 unavailable、reloadRevision 递增，原生编辑器与撤销可能被拆卸；真正恢复需再触发重读。`
- 预期修复：`在 FileTab 读取所有者区分首次加载、文件确实不存在/超限和已加载视图的瞬时 I/O 错误：后者保留先前正文、原生编辑器、undo，显示明确刷新失败反馈；成功后清反馈。`
- 验证：`FileTabTests 先 Red（33 tests 中 transient case 3断言失败），修复后 Green；增加真实原生挂载稳定回归和初读失败/明确文件删除反证；本机/SSH、make test/build。`
- 解决证据：`受控已加载文本瞬时读取抛错，原文被清空且 reloadRevision 增加；Red build/p2-audit-extreme-red3.log。FileTab 对非缺失/超限临时错误保留旧内容和原生 TextKit，reloadError 展示中英警告并于恢复清理；图片回归、真实 native undo、后续文件真删除路径 Green build/p2-audit-38-green.log。`


## 发现 F-06

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:142-153,304-351`
- 摘要：`已加载文件在途刷新被连续激活反复取消重读`
- 风险：`实测初读之后一次暂停刷新期间12次窗口激活使总读取次数达到14，旧任务继续占用IO/SSH，后到结果因代次失效丢弃，拖慢文件重新可用。`
- 预期修复：`FileTab 唯一刷新所有者合并在途重复触发，并至多补一次刷新以获得在途期间发生的后续磁盘变化；路径/断线/dirty 仍取消旧任务。`
- 验证：`受控 EditorWorkspaceFixture 在途读+12次激活先 Red；修改后在途仅1次、完成后至多1次补读，后发外部修改可见；FileTabTests、GitWorkspaceMenuTests、真实 SSH、make test/build。`
- 解决证据：`受控 actor 首读成功后暂停重载，12次激活造成 14 次读；Red build/p2-audit-extreme-red3.log。FileTab.refreshPending 只允许在途1次+完成补读1次，三次读观察最新外部内容；撤销脏编辑和 SSH 断线立即取消补读；Green build/p2-audit-38-green.log 38/38。`


## 发现 F-05

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Workspace/Project.swift:518-526; kero/Editor/FileViewerView.swift:111-133`
- 摘要：`Git Ignore 在已加载但外部改动的干净 .gitignore 标签上追加旧缓存并覆盖新磁盘内容`
- 风险：`ignoreGitPaths 经 openFile 复用已存在标签，waitForText 对 .text 直接结束；用户/外部工具更新磁盘后在标签未被刷新时调用 Ignore，旧内容写回覆盖外部变更，违反保留原文与数据完整性契约。`
- 预期修复：`文件标签提供清洁文本在非视图追加前刷新磁盘的单一方法；加载中的读取合并、未保存草稿不重新读取；Git Ignore 复用该方法后再追加和保存。`
- 验证：`GitWorkspaceMenuTests 使用真实本地仓库外部修改 .gitignore，先 Red 再 Green；现有原生 dirty/undo 和首次创建路径保持 Green，全量 make test / build`
- 解决证据：`真实磁盘 Red: build/p2-audit-ignore-red.log，新 .gitignore 保留旧 cached-rule 覆盖外部 external-rule，1测试2断言失败。Green: build/p2-audit-ignore-green.log GitWorkspaceMenuTests 全通过（已有原生 dirty/undo/新建与新增外部变更用例）；FileTab.waitForTextBeforeAppending 在干净已加载文件且无在途读时先刷新，dirty / loading / in-flight 保留旧语义。获授权 Windows 独立 /tmp 临时 SSH 仓库专属 master 真实运行 build/p2-audit-ssh-actual.log，GitWorkspaceSSHTests 1/1 通过（102.862s），包含真实 SSH 外部变更后的再次追加，测试自行清理。`


## 发现 F-04

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:459-472`
- 摘要：`全局激活通知导致其他窗口已加载文件无关重复读取，同次激活可能重复触发`
- 风险：`FileViewerView 无窗口身份过滤，所有 mounted 文件同时收到 NSApplication / NSWindow 通知并调用 reloadFromDiskIfClean；每次都会取消在途且发起新 IO，窗口增多时放大主流程读盘或远程读取，违背 P2 按需与去重。`
- 预期修复：`用原生 NSView 弱引用确定实际所属 NSWindow，仅本窗口成为 key 时刷新；删除两条无关窗口广播。SwiftUI controlActiveState 方案经原生测试证实无法可靠识别后未保留。`
- 验证：`原生双 NSWindow/FileViewerView 真实切焦点前后 readCount 证据，FileTabTests Red->Green、原生图片/文本恢复、make test / build`
- 解决证据：`Red 原生双 NSWindow（build/p2-audit-window-red2.log）：切 A 时 B 的已加载文件 readCount 1->2。使用 SwiftUI controlActiveState 实测两个窗口均为 key，不能可靠区分，已完全移除该试验。AppKit NSView 弱关联实际 NSWindow，单一 didBecomeKey 仅通知所属窗口，删除 didBecomeActive 广播：build/p2-audit-window-owned-green.log 正向及跨窗口 Green；build/p2-audit-filetab-second-round.log FileTabTests 31/31（含真实 PNG 预览与文件切窗测试）。`


## 发现 F-03

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`KeroTests/NativeUI/Editor/FileTabTests.swift:208-242`
- 摘要：`P2-T1 缺少真实本地符号链接、有效图片及失效图片回退路径回归`
- 风险：`既有 FileTabTests 已覆盖模拟后端非法 UTF-8 和容量，但未覆盖本机真实文件符号链接、有效 PNG、无效图片回退及其文本容量限制；这些属于 plan-p2 的实际验收路径。`
- 预期修复：`在现有 FileTabTests 添加使用本地真实文件与符号链接、无效图像字节的结果断言，不增加新实现或模拟专属解析器。`
- 验证：`make test ONLY_TESTING=KeroTests/FileTabTests；相关编码/容量/回退断言及完整 make test`
- 解决证据：`本机真实临时文件与符号链接/UTF-8/有效PNG/无效PNG/超限PNG验证，KeroTests.FileTabTests 29项全部通过；日志 build/p2-audit-filetab-final.log；旧模拟后端二进制覆盖保留，没有新增产品专属后备兼容实现。`


## 发现 F-02

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:450-461`
- 摘要：`窗口激活通知绕过统一首次加载入口，取消正在进行的初次读取`
- 风险：`onReceive 直接调用 reloadFromDiskIfClean，导致慢速本机/SSH 首次读取被取消重启，重复工作并推迟可输入时间。`
- 预期修复：`视图激活走已有 refreshWhenSelected 合并在途初读；显式的已加载文件外部刷新仍可重载。`
- 验证：`FileTabTests 添加原生视图初读慢速期间窗口 key 通知回归；make test ONLY_TESTING=KeroTests/FileTabTests`
- 解决证据：`Red: build/p2-audit-red.log，原生 NSWindow didBecomeKey 的在途初读被重启到 2 次；Green: build/p2-audit-green-filetab.log 27/27，testWindowActivationDoesNotRestartInFlightInitialRead 通过，仅1次读；两处激活通知改共用 refreshWhenSelected；离线状态保留不自动重试守卫。`


## 发现 F-01

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:160-178`
- 摘要：`固定 SSH 主机断线后重连会读取从未被消费的恢复标签`
- 风险：`rebindRemoteTabs 遍历所有标签；恢复时直接 reloadFromDiskIfClean，触发未展示标签的网络读取，违背 P2 懒加载验收。`
- 预期修复：`仅已请求过读取的标签自动恢复；未消费标签保持懒加载，保留已展示标签的重连恢复。`
- 验证：`FileTabTests 添加固定主机断线重连的未消费和已消费读取次数回归；make test ONLY_TESTING=KeroTests/FileTabTests`
- 解决证据：`Red: build/p2-audit-red.log，FileTabTests.testUnconsumedRemoteTabRemainsLazyAcrossReconnect 失败；Green: build/p2-audit-green-filetab.log 27/27，通过未消费重连0次 IO、显式消费后只读取1次及已消费恢复；生产修改 FileTab.hasReadDemand/rebindWorkspace，原生入口保持懒加载。`


独立逐任务复核后，无需要阻止进入下一阶段的未解决 finding；未读取旧 audit／review 结论。

## 修复日志

- 实施中已闭环固定 host 断线、初读失败状态、在途 rename、Diff loading 失效及 SessionStore 间接构造测试迁移，见任务提交与 evidence-p2。审计没有以新 caller guard 替代根因，也不制造空修复提交。

## 验证日志

- 实际 Red/Green：固定主机 disconnect；Diff 读中输入及 disconnect 的 loading 两断言；缺失文件重新创建后同标签需求重试。最后 FileTabTests 21 / 0 failures、DiffTabTests 16 / 0 failures。
- 字体替换前后 SyntaxHighlightingTests 2 / 0 failures，真实 comment 渲染属性、原文、clean、字体切换及 undo 不变。
- 临时实验类已移回 build；最终组合 `make test` 249 / 0 failures / 3 SSH skipped，`make build`／严格验签通过。本地 Vendor AX 修改此前 Debug/Release／严格验签通过。
- `evidence-p2.md` 的同加载器、仅字体 A/B 两边各 2×30，额外 sample 分开；没有把 firstColor／nativeInstall 叫作绘制或高亮全部稳定，单阶段变慢也已保留。
- 初始读取与显示／waitForText 的共享入口、同代次句柄收尾、保存目标代次的路径覆盖已核对；固定 host 通知弱订阅和仅显式需求探测不形成后台循环；真实原生断线只读、重连同表面及 undo 已运行。
- readImmediately、同步 init、init 自动启动、通用正文样式分支、Diff AX 重复 override 及已证明冗余的保存目标比较都在原任务删除；必要输入／范围、保存、容量和身份保护保留。
- editor/ssh/diff/development/testing 文档同任务更新；现行计划同步 loading 提前归属及实施授权，不改写旧审计。`git diff HEAD --check`／`git diff --cached --check` 通过。

## 2026-10-17 独立复审（P2 专属）

- 逐任务核对：P2-T1 → `e82cd03`（懒加载、断线只读、Diff 失效、AX）；P2-T2 → `b440eb0`（高亮只写临时前景色）。按当前文件的实际读取、保存、连接通知、原生编辑器和高亮插件调用链复核，不以既有 audit 结论作为证据。后续 P3/P5 等对共享文件的修改只作为回归影响检查，不混入 P2 修复提交。
- F-01：恢复未消费 SSH 文件标签时提前读远端；引入真实读取需求标记，重连只恢复已消费标签。F-02：App/窗口激活取消在途初读；统一走合并初读入口，断线时仍不触发未获授权的自动 SSH 探测。二者新测试在修复前实测 Red（FileTabTests 27 项中 2 项失败）；修复后 Green（27 / 0）。
- F-03：原有模拟后端二进制／容量测试存在，但真实本机符号链接、有效 PNG 与失效 PNG 后备路径缺回归；新增真实临时文件覆盖符号链接、有效图片预览、图片字节无效、图片内容实际为 UTF-8、超限图片的文本后备容量。最新 FileTabTests：29 / 0。
- 当前独立组合 `make test`：338 tests / 0 failures / 5 skipped（其中未授权的真实 SSH 专项测试未作为已通过）；`make build` + `codesign --verify --deep --strict` 通过。全量 XCTest 于新添 F-03 测试前编译，其后单独重跑最新 FileTabTests 29 / 0；环境中同时有其他阶段审查的构建／代码更新，不把测量耗时当作性能基线。
- P2 补充修复提交 `c502a76`（F-04/F-05）：从 index 按 hunk 选择性暂存六个 P2 文件，特意不纳入同一 `FileViewerView.swift`、`docs/features/editor.md` 的 P3 并行改动；原始 P2-T1/T2 实施及 F-01/F-02/F-03 提交 `e82cd03`、`b440eb0`、`f631b6d` 均保留。读取、窗口和 Git Ignore 继续沿用唯一 FileTab 所有者，不留另一个兼容加载器。

## 2026-10-17 继续审查补充

- F-04：双 NSWindow 原生回归实际 Red，切到 A 后另一个窗口 B 的 readCount 从 1 增加至 2（`build/p2-audit-window-red2.log`）。初试 SwiftUI `controlActiveState` 在该宿主的两个窗口恒为 `.key`，被验证为不正确并彻底删掉。最终通过弱引用 NSView 定位当前 NSWindow，仅所属窗口 key 事件刷新；文本与真实 PNG 预览路径均 Green，`FileTabTests` 31/31（`build/p2-audit-filetab-final2.log`）。
- F-05（High）：真实临时 `.gitignore` 在外部改写后被已加载旧文本覆盖，新增测试 Red 为 1 测试 2 失败断言（`build/p2-audit-ignore-red.log`）。`FileTab.waitForTextBeforeAppending` 为干净已加载缓冲读取当前磁盘内容，复用已有在途读取且保留 dirty 草稿及原生撤销；`GitWorkspaceMenuTests` 全部 Green（`build/p2-audit-ignore-green.log`）。
- 真实 Windows SSH：在专属 socket 和测试自建 `/tmp/kero-p4-git-*` 远端仓库验证外部 `.gitignore` 改写后再次追加；`GitWorkspaceSSHTests` 1/1 通过、102.862 秒，测试后清理临时目录和 master（`build/p2-audit-ssh-actual.log`），不复用用户会话。
- P2 最终验证：F-04 后的 full suite 350 tests / 0 failures / 5 skipped（`build/p2-audit-full-second-round.log`）；F-05 后定向 FileTabTests 31/31、GitWorkspaceMenuTests 7/7、真实 Windows SSH 1/1；`make build DERIVED_DATA=build/DerivedData-P2-F05` 严格验签通过。最后一次整仓库 `make test` 353 tests / 4 failures / 5 skipped（`build/p2-audit-full-final-all.log`），失败来自 P3 `EditorTextInputTests`（2 断言）、P4 `RemoteCommandsTests`（1）、P5 `DiffTabTests`（1）；其他阶段并行处理，P2 不侵入其源码，不冒称整仓库通过。

## 2026-10-17 极端条件追加复审

- F-06：已加载文件的一次在途刷新被 12 次焦点事件取消重启，实测累计读数 14（`build/p2-audit-extreme-red3.log`）；在 `FileTab` 刷新所有者内合并重复事件，读取完成后至多再读取一次，读数降为 3 且显示最新外部字节。待执行的补读在 dirty edit、断线、目标变化时失效，不回写旧请求。
- F-07：干净文件临时 I/O 故障时旧 `text` 清空、原生编辑器被替换；Red 测试实证。现在对临时故障保留原生 TextKit、旧内容、撤销与图片预览并显示中英双语警告；真实删除与超限仍按原契约显示不可用，成功刷新清除状态。
- F-08：保留旧内容后，Git Ignore 不得绕过本次失败刷新来消费过期缓存；受控 Red 实证会追加旧规则，修改 `FileTab.waitForTextBeforeAppending` 的成功契约后，失败阻止追加和写入，恢复后可再读取最新内容。
- F-09：刷新失败后仍可编辑和真实写盘的两项 Red 测试失败已复现；现在由 `reloadError` 驱动原生 `STTextView.isEditable` 与模型保存资格，成功重读前保留只读原文且 backend `write` 零调用，恢复后同一编辑器继续修改、Undo、Save。只保留原有 `FileTab` 所有者，没有新增保存/重试服务。
- 定向 Green：FileTabTests 38/38（`build/p2-audit-38-green.log`），GitWorkspaceMenuTests 7/7（`build/p2-audit-gitignore-final.log`），SyntaxHighlightingTests 18/18（`build/p2-audit-highlights-final.log`），PaneRetentionTests 12/12（`build/p2-audit-pane-final.log`）。授权的真实 Windows SSH `GitWorkspaceSSHTests` 1/1、103.214 秒（`build/p2-audit-ssh-extreme-final.log`），专属临时 master 和文件夹，测试清理。整仓 XCTest 使用已获授权 Windows：`build/p2-audit-all-windows-final.log` / `build/p2-audit-all-summary.json`（`xcresulttool get test-results summary`），共 368，366 passed，2 failed，0 skipped。失败是 P3 的 `EditorTextInputTests/testInputGeometryAfterEditorDetachesDoesNotUseDisposedWindow` 独立进程 crash，以及 P4 的 `RemoteCommandsTests/testSSHFileRenamePreservesDanglingSymlinksAndRejectsOccupiedDestinations` 并发目录竞态断言；均非 P2 修改，P4 代码在测试启动后另行提交修复，不能视为复验通过。
- 本轮仅 P2 五个文件的提交：`02d67dc`。严格区分先前 `c502a76` 和其他 AI 的 P3/P4/P5 提交，未混入跨阶段修改。旧的重复全局窗口通知、init 预读、字体重复事务不再恢复。
- 独立 App：Debug 包已用 `open -g -n -a ... --args --isolated-ui-test` 启动，创建独立 PID 10227，不使用用户正式快照/隧道。Peekaboo 4.6 AX 检查仅得到不在屏幕上的像素窗口、无可复用元素树；其他 P1/P3 实例和用户正式 Kero 正在运行，为避免抢焦点未强行执行 `⌘⇧A`、512KiB/4MiB 文件选择、真正重启 E2E。仅终止本次 PID，确认用户/其他 AI 的三个 App 实例存活。两份 UTF-8 合成 fixture 大小正确，独立菜单 E2E 不宣称通过。

## Gate（是否允许进入下一阶段）

- 结论：`Go（仅 P2）`；整仓库 No-Go：P3 测试崩溃与 P4 SSH 重命名测试失败，须由对应阶段独立修复并复测。
- 理由：正常与已证实失败路径到达真实磁盘、原生文字／颜色／撤销，旧路径同任务删除；组合自动回归与构建通过，纯性能措施有单变量等价与测量依据。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：真实 Windows SSH Git Ignore 已验收；正式安装、独立 App 菜单 E2E 和用户重启恢复未验收；beta Instruments 受 AMFI 限制。P3 崩溃与 P4 重命名测试失败仍待对应审查处理，P2 的 Go 不代表整仓库 Gate 通过。并行源码仍在修改，不安装混合构建或重启用户 Kero。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

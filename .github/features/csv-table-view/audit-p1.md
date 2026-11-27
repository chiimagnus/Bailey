# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go（本轮 P1 专项）；共享最终整合另见 P2 F-12。
- **依据**：独立复审两个任务及实际调用链，F-07、F-08 经 Red/Green 修复于 `e7c26698`、`71e76441`；本机 CSV 核心 53/53、真实共享文件切换和原生宿主通过，直接关闭路径新增受影响宿主 79/79；正式 Debug 与严格验签通过。历史记录仅供追溯，本轮不运行完整 App GUI。
- **现行 AX 验收**：依[共享验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)，下文 VoiceOver 记录仅为历史证据，专项语音不再阻塞。
  已有实际表格和基础 AX 证据可复用，发现新的相关缺陷时再定点核验。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；可执行项仍需验收。

## 任务与改动

- **P1-T1 原文 UTF-16 字段索引与有界类型路由**：`DelimitedTableIndex` 与
  `FileTab.delimitedSnapshot` 从唯一 TextKit 原文取得字段；`TextFileEncoding` 保留 UTF‑8 CSV 字段、旧 GBK LFS 和条件写入契约。
- **P1-T2 共用文件展示模式，交付可访问的只读原生表格**：`Project.setFilePreviewMode`、
  `DockItem.filePreview` 与 File 菜单统一分发；`CSVTableView` 只显示、
  `DelimitedTablePresentation` 计算原行映射，不写入数据。产品契约见 [文件编辑器](../../../docs/features/editor.md#读取与原生内容)。

## 2026-11-26 独立逐提交复审

以 `788a46a6` 为起点重新读取 idea、plan、todo、原提交 diff 和当前生产调用链，不以既有 audit 为证据。
- P1-T1 `1c9aefcc`、`50fc8b13`、`0897e227`：`FilePreviewKind`、`TextFileEncoding`、`FileTab.delimitedSnapshot` → `DelimitedTableIndex.parse`；UTF-16 原区间、分隔符、容量、取消及编码路由均进入实际文件视图。当前索引 17 项全部通过。
- P1-T2 `24019b00`、`49a9e09d`、`2a5408d5`：`Project`／`WorkspaceWindowModel` → `FileViewerView` → `CSVTableView`／`DelimitedGrid`；排序、筛选、选区、复制、Find 使用当前投影而非第二份正文。F-07 经真实 marked-text 宿主 Red/Green，`e7c26698` 让 FileTab 拒绝切换时 Dock 同步保持原布局；没有新增组合输入状态或旁路。
- 基线 169 项（166 通过、3 样本跳过、0 失败）；修复后 171 项（168 通过、3 样本跳过、0 失败），见 `/tmp/bailey-csv-fresh-baseline.U1YAA6Ut`、`/tmp/bailey-csv-audit-green.b8rGMPOC`。此前逐提交复审所覆盖的 49 项 CSV 核心，本次已扩为 51 项。正式 App GUI 未运行，不冒称覆盖。
- 清理核对：没有独立 CSV 展示菜单、临时正文或旧查找匹配索引；`canPreviewMarkdown` 仍由真实 Markdown 滚动同步、链接路由和菜单调用，不是废弃兼容入口。

## 发现项

## 发现 F-08

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/Project.swift:766-774; Bailey/Workspace/DockWorkspaceModel.swift:641-645`
- 摘要：`直接关闭并排预览绕过文件拥有的原生输入结束边界`
- 风险：`中文组合期间关闭预览会直接修改 Dock 并卸载正在编辑的表格；模式切换的拒绝语义未覆盖关闭命令`
- 预期修复：`让 FileTab 负责结束当前输入的统一边界，Project 在移除并排预览前尊重其结果，保持无内容的预览仍可关闭`
- 验证：`真实原生 marked-text 宿主，经 Project.closePanels 关闭并排预览，验证拒绝期间 Dock/首响应者/原字节不变；确认后关闭成功并保存、撤销准确`
- 解决证据：`71e76441；真实 Project.closePanels + 原生 marked-text Red 2 断言失败 /tmp/bailey-csv-companion-red.rZTiDC06；Green 79/79 含 Dock、窗口关闭、原生输入、保存及字节/Undo /tmp/bailey-csv-companion-green.vwP6GWdH；正式 Debug 构建与严格验签 /tmp/bailey-csv-companion-build.diJNRAkL。FileTab.finishDelimitedInput 统一保存/展示/关闭预览入口，不复制输入状态。`


## 发现 F-07

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/Project.swift:148-153; Bailey/Editor/FileViewerView.swift:612-620`
- 摘要：`FileTab 因原生 CSV marked text 否决展示切换后，Project 仍无条件变更 Dock companion`
- 风险：`从默认表格请求并排时同时出现两个表格；从并排关闭预览可能提前卸载输入，打断组合输入并使网格所有权冲突`
- 预期修复：`让 FileTab 的展示模式切换明确返回是否接受；Project 仅在接受时更新同一 Dock 布局，复用真实原生输入结束边界`
- 验证：`真实 Project/FileViewerView 原生 field editor marked text：默认表格→并排、并排→源码均验证布局、唯一文档和输入保持；提交组合后切换、Undo 和实际保存字节`
- 解决证据：`e7c266989943e0bb38d700e3731ad034b5fd81c8；Red /tmp/bailey-csv-audit-red.mPfINPoJ，4 条断言失败；Green /tmp/bailey-csv-audit-green.b8rGMPOC，真实项目两种模式切换、组合输入、保存与 Undo 通过。`


## 发现 F-06

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/CSVTableView.swift:1017-1033`
- 摘要：`旧查找结果在隐藏查找后仍随投影变化自动选择；Next/Previous 使用独立 matchIndex 而非当前真实 caret`
- 风险：`排序/筛选/重建后实际选区被隐藏查找覆盖；手动移动光标后下一匹配可能跳错`
- 预期修复：`将隐式选中限定为可见查找结果变化，显式导航使用实际 caret 与已有 findStep；删独立 matchIndex`
- 验证：`挂载原生 CSV：查找、隐藏、手动选中、排序、验证选区保留与下一/上一匹配、保存原字节`
- 解决证据：`2a5408d5；原生挂载 Red 3 失败→Green；排序后手动选区不被隐藏查找覆盖，下一/上一按实际 caret，原字节/dirty/Undo 不变；CSV Dev 49/49、正式 Debug 构建及严格验签均退出0；/tmp/bailey-csv-find-red.4fHnrpog、/tmp/bailey-csv-find-green.cSZoBuQP、/tmp/bailey-csv-find-build.LtUMXNbQ`


## 发现 F-05

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/DelimitedTableIndex.swift:100-114`
- 摘要：`自动分隔符探测仅需任意多字段记录，未排除行宽不一致或词法非法的候选`
- 风险：`合法 CSV 的普通数据中出现分号或 Tab 会被误判为歧义，正常网格被禁止编辑；分号表格的逗号小数同样受影响`
- 预期修复：`在有明确合法候选时只考虑采样内完整且结构一致的多列记录；无一致候选仍允许部分坏表及显式选择；采样截断不视为文件结束`
- 验证：`新增 CSV/TSV/分号分隔符真实样本与原有歧义、截断测试；确认 FileTab.canEditDelimited 及原文字节`
- 解决证据：`0897e227；六组真实文件Red 13断言失败，Green CSV Dev 48/48，正式Debug make build严格验签；/tmp/bailey-csv-delimiter-red.aPvPLtC5、/tmp/bailey-csv-delimiter-green.RCsao0Vp、/tmp/bailey-csv-p1-build.Vis1KhpJ`


## 发现 F-04

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/CSVPreviewUITests.swift:4`
- 摘要：`CSV 后台标签与另一窗口的主菜单目标未经过真实交叉验证`
- 风险：`后台右键或前台快捷键可能误改同名标签或另一 Dock`
- 预期修复：`在隔离双窗以同名不同内容的 CSV 组合测试命中标签和前台快捷键，拖窄并排 Dock 后核对原生表格`
- 验证：`隔离 Bailey Dev 双窗作用目标、实际窄栏单元格及原字节`
- 解决证据：`提交 d9ea3c56。两个真实隔离窗口、同名不同内容；后台右键只改目标，Cmd+Shift+V 只改前台窗口，真实 Dock 拖窄后核对原生单元格和三个原文件。`


## 发现 F-03

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/CSVPreviewUITests.swift:1`
- 摘要：`阶段已验证 Finder 投递与恢复的宿主路径，但未证实它们实际出现在完整 App 表格里`
- 风险：`宿主成功不排除 Apple Event 投递与冷启动时未渲染默认表格`
- 预期修复：`通过系统文件投递打开隔离 Bailey Dev，再正常退出和同一会话 ID 重启核对可见值`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/CSVPreviewUITests；真实表格及原文件字节`
- 解决证据：`提交 785d1c9。真实 NSWorkspace Apple Event 投递给唯一隔离 Dev PID，原生表格出现实际值；Cmd+Q 后同会话冷启动，核对原生单元格与原字节。四个 CSV GUI 均通过。`


## 发现 F-02

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Files/DelimitedTablePresentationTests.swift:8`
- 摘要：`大表极值已实际滚动，但阶段还未核销重复挂载、深浅外观和旧表清空`
- 风险：`一次正常虚拟化不能证明原生表更新和退役不保留过期行`
- 预期修复：`在隔离 AppKit 窗口中反复安装、选中、卸载原生表，记录两种外观、释放与内存证据`
- 验证：`make test:DelimitedTablePresentationTests，记录 100 次真实挂载／卸载的结果`
- 解决证据：`提交 98c5e09b。隔离 AppKit 两种外观交替 100 次真实挂载／选中／清空，旧表 0 行、无旧选区；约 0.47 秒，峰值 RSS 213958656→216465408 字节。`


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/DelimitedTablePresentation.swift:52`
- 摘要：`分隔符或列数变化时，旧列筛选仍可应用到已经不存在的列`
- 风险：`筛选不到任何行，而且当前表头不再提供清除旧筛选的入口`
- 预期修复：`按当前索引中的列范围统一核对展示设置；分隔符改变时丢弃不再代表相同字段的设置`
- 验证：`make test:DelimitedTablePresentationTests；核对列消失和换分隔符后的真实投影与控件状态`
- 解决证据：`提交 98c5e09b。旧实现回归真实返回 []; 修复后表格投影 [1, 2]，同分隔符保留合法筛选，换分隔符清除旧列设置。61 项有关宿主通过。`


## 验证与未覆盖

- 2026-11-24：冻结提交 `05696bb5` 的 Debug、Release、UI Test Target 构建及签名通过；真实样本、授权 Windows SSH、隔离 APFS 卷与完整宿主 `make test` 1366/1366 通过，0 失败、0 跳过，2007.208 秒。日志：`/tmp/bailey-seven-20261124-svg-final-full.log`。仅核销宿主证据，完整 App GUI 与实体设备条件仍保留原阻塞，不据此改为 Go。

- macOS 27.3／Xcode 27.2、Apple Silicon。本轮按用户确认不要求 macOS 15.6 实机验收。
- 178 项相关宿主、3 项完整 GUI、`make build` 和后置签名检查均以退出码 0 完成。
  包含实际 Files 路由、跨窗 Finder 宿主投递、冷恢复宿主、跨后缀移动、Windows Tailscale 读取原字节、
  2,501 列与十万行的真正末端布局、英语与中文错误展示、筛选／排序、按键查找焦点和复制后的实际剪贴板。
- 审计补测的 61 项宿主全部通过；深浅外观交替的 100 次原生挂载均清空旧行与选区，
  0.47 秒，过程峰值 RSS 213958656 → 216465408 字节；不是 100 次完整 App 窗口运行证据。
- 完整 `make test` 以退出码 0 完成：1,271 项记录、22 项条件跳过、0 失败。
  完整套件未传远端环境变量；CSV 真实 Windows Tailscale 路径已在上述 178 项单独验收。
- 扩大后的 4 项 CSV 完整 GUI 逐项通过，覆盖真实 `NSWorkspace` 文件事件、正常退出与冷启动、
  原生表格单元格和冷恢复后的磁盘字节；其同批次的 SVG 失败不计入 CSV 的结果。
- 独立的第 5 项 GUI 通过：两窗口同名文件、后台标签原生右键、当前窗口 `⌘⇧V`、
  并排表格实际拖窄 75 点的手势，以及三个原始文件字节。
- 真实 VoiceOver 播报和巡览尚未执行；XCTest 已从系统 AX 树定位表格与单元格，并实际验证键盘焦点，
  但还不能证明播报顺序和跨 Dock 巡览。需在独占 Dev 桌面时手工核对，阻塞 P1 完整门禁。
- 本机只有 2× 内置屏，尚无 1× 设备。原生滚动及双窗窄 Dock 的 2× 结果已测，
  不能证明 1× 下的字形和分隔线可见性；有相应设备时复跑同一 GUI。
- 真实 Windows Tailscale 和本机路径已测。
- 最终 e4267d71：共享读取、文件归属、原生生命周期与 330 项受影响宿主回归全过（含 JPEG 边界补测）；此前 CSV 专项及隔离 GUI 证据不变。共享记录见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。

- 2026-11-26：最终版 d542f533 的隔离 Dev 中真实 VoiceOver 进入原生表格第 1 行（共 2 行），读出表头 Name、单元格 SampleAlpha、同一行数值 12345 及选中态。CSV 源字节一致；其余交叉条件仍按阶段验收。
  证据 `/tmp/bailey-final-vo-exclusive.sOoDThsY/vo.log`。

## 2026-11-27 后续回归

以下为此前本地提交的补验记录（从任务备注迁移），原阶段审计结论不变。

超长逻辑记录跨越 16384 字符预算时延伸完整记录采样，修复合法极宽 CSV 误判只读；
逗号、分号、Tab、引号换行与真实歧义均回归。最终 Debug 相关 42/42、Release 72/72。

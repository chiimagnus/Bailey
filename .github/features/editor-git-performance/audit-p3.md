# Audit P3 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 补齐编辑后的高亮范围更新
- [x] P3-T2 恢复字节精确文本契约并删除重复比较
- [x] P3-T3 验证并收敛坐标扫描热点
- [x] P3-T4 验证并优化根解析调度
- [x] P3-T5 修复查询失败闭环并按需共享编译
- [x] P3-T6 验证嵌入语言复用方案
- [x] P3-T7 接入已验证的子区域复用措施
- [x] P3-T8 修复原生组合输入结束时丢字
- [x] P3-T9 核实解析输入分块边界并按实证修复
- [x] P3-T10 修复解析队列失效范围的旧坐标交付
- [x] P3-T11 清理插件依赖与无用主题包装
- [x] P3-T12 修复长文档反向定位的视口错误

## 任务到文件的映射

- P3-T1
  - `kero/Editor/SyntaxHighlightPlugin.swift`；`SyntaxHighlightingTests`；`docs/features/editor.md`
- P3-T2
  - `SourceTextEditor.swift`、`FileViewerView.swift`、`DiffViewerView.swift`、`DiffEngine.swift`；FileTab／DiffTab／DiffEngine 回归；editor.md／diff.md
- P3-T3
  - `TextCoordinateIndex.swift`、coordinator 接入；固定 seed 与真实 Parser 对照
- P3-T4
  - `SyntaxHighlightPlugin.swift` 初始化阈值；原生输入与关闭释放回归
- P3-T5
  - `HighlightQueryCache` 与 root／embedded／`DiffSyntaxHighlighter`；`HighlightQueryCacheTests`
- P3-T6
  - 本地 `evidence-p3.md` 与 build/performance 下原型／sample；未提交原型
- P3-T7
  - `SyntaxHighlightPlugin.swift` 当前 revision 的 NamedRange→Task、裁剪和失效；真实围栏／HTML／释放回归
- P3-T8
  - `Vendor/STTextView/.../STTextView+NSTextInputClient.swift`；`EditorTextInputTests` 与系统 NSTextView 对照
- P3-T9
  - `SyntaxHighlightingTests` Unicode 分块／TextKit 快照对照；未新增 reader
- P3-T10
  - `Vendor/Neon` 核心、Xcode 同身份本地覆盖、许可证资源；连续排队编辑真实最终颜色回归
- P3-T11
  - 四处应用 import、SyntaxHighlighting 颜色字典、Package.resolved；主题等价性与唯一包图
- P3-T12
  - `Vendor/STTextView/.../STTextView+Scrolling.swift`；`EditorNavigationTests`；development.md／editor.md／testing.md

## 本轮逐任务／逐提交独立核对（2026-10-17）

以下依据 `todo.toml`、各提交的 diff、当前生产调用链和永久回归重建；此前的 audit 结论不作判据。所有列出的实施提交均可从当前 HEAD 追溯。

| 任务 | 核对的实际提交 | 生产入口与最终副作用／验收 |
| --- | --- | --- |
| P3-T1 | `9467448c` | STTextView 文本变化 → coordinator → Neon 回调；旧编辑的成功／失败不再交付，实际前景色与当前 AST 对照 |
| P3-T2 | `8533dd10` | FileTab 脏状态、写盘／重载、DiffTab 比较、DiffEngine 行／词级相等及原生 delegate；UTF-8 原字节而非 Unicode 规范等价 |
| P3-T3 | `8b3b2deb` | TextCoordinateIndex 的 LF 起点索引真实挂入 parser locationTransformer／编辑更新；400 次种子编辑与 Parser Point 对照 |
| P3-T4 | `aae214d9` | TreeSitterClient 同一队列阈值设为 0，非空编辑后台解析，实际输入／颜色／关闭释放回归，不另建 parser |
| P3-T5 | `312fa77b` | HighlightQueryCache 的 pending／complete 归 root、embedded 和 DiffSyntaxHighlighter 共享；失败、取消和语言／种类隔离测试 |
| P3-T6 | **无提交（按计划）** | evidence-p3.md 同机原型和取舍：同次编辑缓存收益明显；不引入跨编辑子树引擎，非产品文件 |
| P3-T7 | `a001e095` | 当前编辑版本片段 Task、root／child 范围裁剪、变更重置 valid、实际 markdown／HTML／TSX 颜色、关闭释放；本次新增 F-01 |
| P3-T8 | `f87b416f` | 原生 NSTextInputClient 的 unmark／最终输入使用真实正文与标记范围；与系统 NSTextView、Undo 对照 |
| P3-T9 | `82352859` | UTF-16 reader 边界、CRLF／emoji／组合字符及编辑后 AST／原字节对照，真实未复现缺陷故没有产品补丁 |
| P3-T10 | `f772bec3` | 本地唯一 Vendor/Neon 核心修复排队失效范围变换，后台/主线程版本检查、连续编辑实际着色；本次新增 F-02 |
| P3-T11 | `0953fa3`、`8275787a` | 移除 STPluginNeon 空字体及 Theme 包装，唯一 Neon runtime／资源来源、暗亮配色等价、清理锁文件；不伪称 118 MiB 语法资源已去包 |
| P3-T12 | `3a137533` | STTextView 原生定位使用 relocation 建议锚点及真实显示矩形；长文档正反向 60 次与固定行高、文首末端 |

## 发现项

## 发现 F-07

- 任务：`P3-T8`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextInputClient.swift:201-214`
- 摘要：`输入法firstRect跨多行请求虽返回首行矩形，却从未写回actualRange，违反NSTextInputClient多行契约`
- 风险：`输入法无法确认首段矩形实际覆盖的字符，后续候选位置/请求范围可能错误`
- 预期修复：`沿用现有TextKit enumerateTextSegments返回的首段range输出实际NSRange，正常窗口继续返回对应屏幕矩形，拆卸窗口仍安全退出`
- 验证：`原生多行窗口Red实际actualRange保持NSNotFound；修复后校验首行实际范围非空且小于请求总范围、命中坐标有效、拆卸窗口及EditorTextInputTests全部Green`
- 解决证据：`Apple NSTextInputClient官方firstRect(actualRange:)跨行必须给第一段真实字符范围；真实NSWindow多行测试修复前Red actualRange=NSNotFound：build/performance/p3-audit-actualrange-red.log，修复后p3-audit-ime-geometry-green.log 9/9；TextKit首段range来自枚举而非猜测，正常屏幕坐标有效；p3-audit-extreme-combined.log 107/107；p3-audit-extreme-release-final.log Release构建及严格签名通过；提交66f6de2。`


## 发现 F-06

- 任务：`P3-T8`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextInputClient.swift:190-218`
- 摘要：`输入法几何回调在窗口拆卸后仍用 window!，原生复现 characterIndex(for:) 崩溃`
- 风险：`切换/关闭标签时输入法候选框或异步命中查询晚到，可使 Kero 主进程因 nil window 强制解包而崩溃`
- 预期修复：`在两个屏幕坐标转换入口共同读取有效 window，已拆卸时返回无效索引/空屏幕矩形；不保留旧窗口或添加重试/等待`
- 验证：`真实 NSWindow→拆卸→NSTextInputClient 几何回调 XCTest 修复前进程崩溃 Red，修复后 Green；正常窗口屏幕矩形/命中仍与系统 NSTextView 行为对照；相关原生及完整测试`
- 解决证据：`原生已挂载NSWindow→拆卸→characterIndex(for:)修复前宿主Fatal nil window：build/performance/p3-audit-detached-input-red.log；同路径Green：p3-audit-detached-input-green.log，空矩形/NSNotFound验证；p3-audit-ime-geometry-green.log 9/9含正常窗口坐标；p3-audit-extreme-combined.log107/107；p3-audit-extreme-release-final.log严格验签；提交66f6de2。`


## 发现 F-05

- 任务：`P3-T8`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextInputClient.swift:65-126`
- 摘要：`setMarkedText 首次调用 replacementRange=NSNotFound 且当前选区非空时只插入，不替换选中内容；直接 unmark 后留下重复原文`
- 风险：`系统中文等组合输入覆盖选区时产生错误正文，后续 Undo 无法恢复预期选中原文，影响用户数据完整性`
- 预期修复：`把首次隐式替换解析为当前真实 selectedRange，统一用于首次标记范围、被替换原文快照与文字事务；后续标记更新仍复用现有范围逻辑`
- 验证：`原生 STTextView 与 NSTextView 同一窗口环境测试先 Red 再 Green；校验组合过程、直接确认、Undo/Redo、含 Unicode 的非空选区、最终输入与完整 EditorTextInputTests/全量 XCTest`
- 解决证据：`真实STTextView/系统NSTextView同一窗口原生Red：build/performance/p3-audit-implicit-selection-red.log（选区原文残留），Green：p3-audit-implicit-selection-green.log；p3-audit-ime-extremes.log 7/7 含Unicode CRLF首尾与非空选区、直接确认/最终提交及Undo/Redo；p3-audit-ime-real-save.log真实FileTab dirty、UTF8保存、Undo再保存均一致；p3-audit-extreme-combined.log 八组107/107；p3-audit-extreme-release-final.log Release构建与strict验签通过；提交66f6de2。`


## 发现 F-04

- 任务：`P3-T8`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextInputClient.swift:40-124; Vendor/STTextView/Sources/STTextViewCommon/STMarkedText.swift:6-19`
- 摘要：`输入法直接unmarkText接受已标记文字后无法撤销：组合中所有replace关闭Undo注册，unmark只清理属性；与已挂载系统NSTextView的原生Undo行为不一致`
- 风险：`使用输入法确认中文等组合输入后用户Cmd+Z无法撤销刚确认的文字；首段替换已有正文后最终提交也可能不能完整回退`
- 预期修复：`在已有STMarkedText记录开始组合前的被替换正文；在提交时用原生UndoManager登记一次可恢复原文的操作，保留既有insertText提交和撤销／重做语义，不重造输入系统`
- 验证：`已挂载NSTextView对照原生Red（false vs true、Undo内容不符）；补选区替换与最终提交撤销回归，Green后运行EditorTextInputTests、SyntaxHighlightingTests、FileTabTests及Makefile构建`
- 解决证据：`原生挂载NSTextView对照首次Red：p3-audit-mounted-undo.log 不可撤销，与系统原生 false vs true，Undo文案不等；增加组合原文记录及真实UndoManager分组，直接unmark与insertText确认统一产生完整Undo/Redo。中间验证曾触发CoalescingUndoManager未分组异常，已从根因改用begin/endUndoGrouping。p3-audit-ime-final.log 5/5 Green，包含非空替换选择、直接unmark、最终提交和redo；p3-audit-syntax-followup.log 18/18，p3-audit-neighbor-tests.log 64/64。独立提交 a2bbe7d。`


## 发现 F-03

- 任务：`P3-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Editor/SourceTextEditor.swift:116-124; kero/Editor/FileViewerView.swift:218-225`
- 摘要：`已挂载文件的扩展名变更只更新FileTab.path，原生STTextView仍持有首次打开时的语法插件；Markdown与Swift间重命名后颜色不刷新`
- 风险：`文件重命名后长期显示错误语法颜色；如通过重建编辑器解决还会破坏未保存缓冲和撤销记录`
- 预期修复：`从唯一的FileTab.updatePath通知原生编辑器，在同一STTextView上替换语法插件、终止旧异步交付并清除旧颜色，保留编辑与Undo所有权`
- 验证：`新原生重命名回归先Red后Green；多次支持/不支持语法切换和Undo、旧回调释放；SyntaxHighlightingTests和完整Makefile验证`
- 解决证据：`实际SourceTextEditor挂载后原生扩展名改名 Red：p3-audit-rename-red.log，1/1 timedOut；修复为FileTab.updatePath驱动同一STTextView卸载旧语法插件、停止过期查询并装入新插件。p3-audit-rename-cycle-green.log .swift→.md→.txt→.swift 连续切换、前景色、新编辑器身份/Undo保留 1/1 Green。p3-audit-syntax-followup.log 18/18，p3-audit-neighbor-tests.log 64/64。独立提交 9428427。`


## 发现 F-02

- 任务：`P3-T10`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Vendor/Neon/Sources/Neon/Highlighter.swift:18-22,118-120`
- 摘要：`最小Neon核心保留visibleLookAheadLength和visibleLookBehindLength两个公开配置字段，但真实高亮请求仅读取requestLengthLimit；全仓无消费者`
- 风险：`无效配置误导维护者且违反最小运行时清理要求，不影响当前着色正确性`
- 预期修复：`删除无消费者的两个无效字段，保留仍在使用的requestLengthLimit和可见范围算法`
- 验证：`全仓引用检查；SyntaxHighlightingTests、Neon构建及git diff-check`
- 解决证据：`全仓扫描visibleLookAheadLength/visibleLookBehindLength仅原Vendor/Neon定义、无真实调用；两项字段已删除并保留requestLengthLimit；p3-audit-syntax-green.log 16/16，p3-audit-build.log Debug和p3-audit-release.log Release均构建验签成功；git diff --check通过。`


## 发现 F-01

- 任务：`P3-T7`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Editor/SyntaxHighlightPlugin.swift:373-378; Vendor/Neon/Sources/Neon/Highlighter.swift:167-194`
- 摘要：`嵌入语法查询首次编译完成时，仅invalidate重发，未推进当前高亮结果版本；同文本版本下已在途的旧root-only请求仍可在新请求后交付，覆盖新嵌入语法颜色并被记为valid`
- 风险：`初次打开Markdown/HTML多语言文件时，编译和渲染交错可使旧样式残留直到下次编辑或滚动；T1陈旧编辑过滤不覆盖此路径`
- 预期修复：`由现有SyntaxHighlightCoordinator在嵌入查询可用并invalidate之前推进同一个高亮交付代次；不加新状态或重复回退`
- 验证：`新增真实tokenProvider在途查询准备后的乱序交付回归，Red→Green；SyntaxHighlightingTests、完整build/test`
- 解决证据：`原生回归先Red：p3-audit-query-ready-red.log 1/1失败（旧请求仍交付）；复用现有highlightRevision后同一回归Green：p3-audit-query-ready-green2.log 1/1通过；p3-audit-syntax-green.log 16/16通过；p3-audit-build.log Debug通过且strict签名通过；p3-audit-release.log Release通过且strict签名通过；完整p3-audit-full-test.log 344项中5跳过、1个非P3 SSH重命名失败，P3相关套件全部通过。`


2026-10-17 持续从源码、平台契约、真实回调及提交独立复核，F-01～F-07 全部修复并验证；前一轮“无新增缺陷”的结论仅保留为历史记录，不用于本轮 Gate。

## 修复日志

- F-05：原生 `NSTextView` 对照发现首次 `replacementRange=.notFound` 与非空选区时，STTextView 留下选中的旧文字。原生 `p3-audit-implicit-selection-red.log` Red；在首次组合开始处将隐式范围解析为 `selectedRange()`，合并到已有显式替换与原文快照数据流，不添加缓存／双轨。`p3-audit-implicit-selection-green.log` Green，Unicode/CRLF、全选／中间／尾部选区及两类提交的 6 种组合 `p3-audit-ime-extremes.log` Green。
- F-06：拆卸窗口后再询问 `characterIndex` 可直接触发 `window!` 崩溃；`p3-audit-detached-input-red.log` 原生 Red（崩溃）。复用 AppKit 有效 window 守卫，拆卸返回无效索引／零矩形，`p3-audit-detached-input-green.log` Green，无重试队列。
- F-07：`firstRect(forCharacterRange:actualRange:)` 在跨多行情况下不写 `actualRange`，与 Apple NSTextInputClient 契约冲突；`p3-audit-actualrange-red.log` Red。复用 TextKit 现有片段范围，避免 `.rangeNotRequired`，只返回首段对应区间；`p3-audit-ime-geometry-green.log` 9/9 Green。
- 新增实际磁盘及资源验收：`p3-audit-ime-real-save.log` 原生编辑→dirty→真实 UTF-8 写盘→Undo→再次写盘 Green；`p3-audit-repeated-grammar-green.log` 同编辑器 24 次语言切换后旧协调器弱引用全部释放。`p3-audit-extreme-combined.log` 8 组共 107 项，0 失败。
- F-03：FileTab 重命名只更新路径，旧 STTextView 的语法插件未变。原生测试先 Red（`.swift` 改 `.md` 后旧颜色不消失）；在相同 STTextView 上支持卸载插件、取消旧请求、清除临时颜色及按新路径加载。连续 `.swift → .md → .txt → .swift` Green，保存编辑缓冲和撤销历史；提交 `9428427`，日志 `p3-audit-rename-red.log`、`p3-audit-rename-cycle-green.log`。
- F-04：与已挂载系统 NSTextView 对照，直接 unmark 后 Undo 缺失，先 Red；在 STMarkedText 保存开始组合前的原文，直接确认和插入最终文本时用原生 UndoManager 分组记录完整撤销。修复未打开 Undo 分组造成的原生异常后，选区替换、直接确认、撤销／重做均 Green；提交 `a2bbe7d`，日志 `p3-audit-mounted-undo.log`、`p3-audit-ime-final.log`。
- 独立补充 160 次可复现 Unicode/CRLF 编辑与新鲜 Parser AST、原字节对照（Green）；不新增防御性包装。
- 本轮 F-01：真实嵌入编辑器回调中模拟首次查询编译就绪，修复前新 XCTest Red（旧请求仍交付，1 失败）；复用唯一高亮交付版本使旧请求丢弃，修复后单例 Green、16 项 SyntaxHighlightingTests 全 Green。日志：`build/performance/p3-audit-query-ready-red.log`、`p3-audit-query-ready-green2.log`、`p3-audit-syntax-green.log`。
- 本轮 F-02：删除 Vendor/Neon/Highlighter 中两项无任何真实读取路径的配置字段，不替换仍生效的 `requestLengthLimit`。Debug App 独立构建通过：`build/performance/p3-audit-build.log`。
- 已复现的旧坐标、IME、围栏旧色、反向定位已在所属任务修复并留下永久回归，不重复记作未解决项。
- 核对实际 delegate proxy：will／did 的 replacementString 非可选，插件事件的可选闭包签名不能作为新增空输入围栏的依据。
- 用户允许恢复 Xcode GUI 自动格式重排后，只恢复 project.pbxproj 到当前 HEAD；新本地包引用保留。

## 验证日志

- **本轮最终验证（提交 `66f6de2` 后）**：macOS 27.2（26B5101f）、Xcode 27.2 beta（27B5038j）、arm64。八组 P3 关联 XCTest 107/107、0 失败（`build/performance/p3-audit-extreme-combined.log`）；Debug 构建／严格验签通过（`p3-audit-extreme-debug.log`），最终 Release 构建／严格验签通过（`p3-audit-extreme-release-final.log`）。整仓 `make test DERIVED_DATA=build/DerivedData-P3`：**372 项、366 通过、6 跳过、0 失败**，日志 `build/performance/p3-audit-extreme-full-final.log`，包含 F-05～F-07 回归；不能借用之前 357 项的旧结果冒充新版本。
- **补充 Release 测试配置边界**：尝试 `make test CONFIGURATION=Release DERIVED_DATA=build/DerivedData-P3 ONLY_TESTING=...`，XCTest 未执行即编译失败（`build/performance/p3-audit-release-native-tests.log`）：现有 scheme `TestAction buildConfiguration=Debug`；Release `kero.swiftmodule` 不带 `-enable-testing`，无法被测试代码 `@testable import kero` 导入。这不是生产 Release 编译失败，也不是 P3 测试用例失败；**不修改发布模块设置为测试特化模式**。正式 Release App 构建与严格签名已有独立成功证据。
- **再审全量 XCTest 已恢复全绿**：`make test DERIVED_DATA=build/DerivedData-P3`，实际执行 357 项、6 跳过、0 失败（351 通过）。记录：`build/performance/p3-audit-full-followup.log`；含 P3 新增回归和同轮 Git/SSH 关联测试。此前 344 项中的 SSH 重命名失败是旧运行证据，本轮不再复现，不能继续称为当前阻塞。
- 再审 Debug 验收：`make build DERIVED_DATA=build/DerivedData-P3` 成功，`codesign --verify --deep --strict` 成功；日志 `build/performance/p3-audit-debug-followup.log`。
- 再审 Release 验收：`make build:release DERIVED_DATA=build/DerivedData-P3` 通过，`codesign --verify --deep --strict` 通过；日志 `build/performance/p3-audit-release-followup.log`。未安装、启动或重启用户正在使用的 Kero App。
- 再审提交：`9428427`（6 文件）和 `a2bbe7d`（5 文件），仅涉及 P3 功能与文档；保持 P1/P2/P4/P5 及其并行工作区改动原样。`p3-audit-ime-final.log`：5/5；`p3-audit-syntax-followup.log`：18/18；`p3-audit-neighbor-tests.log`：64/64（FileTab 31、DiffTab 27、原生定位 2、查询缓存 2、坐标索引 2）。本轮扩展名与输入法的系统原生对照均从 Red 变为 Green。
- 本轮 P3 独立原子提交：`c38930a`，仅 `SyntaxHighlightPlugin.swift`、`Vendor/Neon/Highlighter.swift`、`SyntaxHighlightingTests.swift`、`docs/development.md` 四个文件；未纳入 P1／P2／P4／P5 的并行改动。
- **2026-10-17 P3 独立复验**：`make test DERIVED_DATA=build/DerivedData-P3 ONLY_TESTING=KeroTests/SyntaxHighlightingTests`：16 项、0 失败（含 F-01 Red→Green）。`make build DERIVED_DATA=build/DerivedData-P3` 与 `make build:release DERIVED_DATA=build/DerivedData-P3`：Debug／Release 均成功，`codesign --verify --deep --strict` 均成功；`git diff --check` 通过。
- **历史第一轮全量失败（已被新轮全绿结果覆盖）**：`make test DERIVED_DATA=build/DerivedData-P3`：344 项，338 通过、5 跳过、1 失败；唯一失败为并行 P4／SSH 所有权的 `RemoteCommandsTests.testSSHFileRenamePreservesDanglingSymlinksAndRejectsOccupiedDestinations`，报 `notFound`（`RemoteCommandsTests.swift:123`）。本轮 P3 没有修改 Git/SSH 源码，P3 相关高亮 16、FileTab 29、DiffTab 26、EditorTextInput 3、EditorNavigation 2、DiffEngine 4 等全部通过。日志保存在 `build/performance/p3-audit-*.log`；不能表述为“全量绿色”。
- `make test`：最终 P3 280 tests、0 failures、3 专用 SSH skipped（p3-t12-test.log）。
- 76 项联合定向通过；Debug／Release 构建和严格整包验签通过。恢复工程格式后 `make build` 再通过（p3-restored-project-build.log）。均使用 Xcode beta。
- 正常路径及实际边界：原生当前 AST／颜色、NFC→NFD 实际写盘与 Git、连续编辑和 undo／redo、未知／删除围栏、取消首个编译等待者、关文档释放、远距离前后定位实际几何。
- 源码复核到 FileTab／DiffTab 的序列写盘、编辑期基线保留、Neon 队列和谓词版本校验、TextSystemInterface 实际 rendering attributes、TextKit 定位副作用；不存在新旧解析器双轨。
- 当前文档归属、事实、导航及补丁表已随提交更新；远程资源包仍存在且只有一个本地 Neon 运行时，未冒称完整去包。性能数字区分 provider、原生定位和完整 App。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（P3 自身及本轮要求的 XCTest、Debug／Release 验证通过）
- 理由：F-01～F-07 全部有确定性来源、根因修复与原生／字节级验证；本轮原子提交 `66f6de2`，107 项 P3 关联 XCTest 与最新 372 项全量 XCTest 均无失败；两种构建及严格验签均成功。先前 SSH 的单次失败已保留为历史日志，不再构成当前 Gate 阻塞。

## 最终状态与剩余风险

- 当前状态：`Resolved`（本轮已验证的 P3 正确性问题均闭环）。
- 剩余边界：本轮未在最低 macOS 15.6 系统上运行，未做完整 App 独立进程键盘／物理屏幕 E2E；Instruments 受本机 beta 系统签名限制，不宣称 Allocations／长时间 RSS 已验收。长行 TextKit 原生布局成本仍在；最终 372 项中 6 项条件测试跳过，不能算已执行的真 SSH 测试。完整 App 综合路径、长时间内存取样及安装归相应综合验收，不把原生 XCTest 当完整 App E2E，也不改动或重启用户当前运行的 Kero。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


# Plan P2 — 编辑器、输入、高亮和 Diff

**Goal:** 完整核销 Editor 与 Diff 的 **144 个旧测试方法**：`EditorNavigationTests` 28、`EditorTextInputTests` 10、`FileTabTests` 49、`SyntaxHighlightingTests` 22、`DiffTabTests` 35；让直接模拟原生窗口的 UI 验证迁往 `BaileyUITests`，把可纯化的文本与存储不变量保留在 `BaileyTests`。

**Non-goals:** 不更换 TextKit 2/Neon，不重做编辑器布局、Diff UI 或快捷键，不顺手改字体、主题和保存机制。实际 Git 历史操作归 P3。

**Approach:** 复用现有 `WorkspaceUITestSupport` 与受控临时目录；每个旧方法依照 [迁移清单](migration-inventory.md) 提取用户动作及纯逻辑不变量，分别经真实 App 与 Unit/Integration 守住。**新测试证明覆盖的同一任务，立即删旧方法及其独占 fixture，并同步修掉 CI 中引用的旧类名**；不等待 P5。

**Acceptance:**
- 144 个旧方法在 `migration-inventory.md` 各有具名替代行为、有效夹具、测试结果或需要明确补验的能力差异；不能用 1 条保存冒充编辑器所有测试。
- 从真实 App 菜单/Files → 原生编辑器或 Git Changes → Diff，键盘输入、滚动、渲染、Undo、保存／失败／重试、窗口隔离和关闭释放可观察地保持原有行为。
- TextKit 布局、语法 token、行号颜色和 Diff 像素这类 UI 内部或算法断言分别用足够强的视觉结果、用户操作或独立数据断言保留；不因 XCUITest 不能直接取指针而删除保障。
- 覆盖验证通过后，4 项任务各自删除负责的旧 suite 文件；不留重复 NativeUI 测试双轨。

**Rules:** 文档 owner 是 `docs/features/editor.md`、`docs/features/diff.md` 与必要的 `docs/ui.md`。测试重构不改变任何正常产品 UI/UX；不在用户正式 App 会话启动 E2E。

---

<a id="p2-t1"></a>

## P2-T1 编辑导航、原生输入、IME 和撤销

**Own old tests:** `BaileyTests/NativeUI/Editor/EditorNavigationTests.swift`（28）及 `EditorTextInputTests.swift`（10），合计 38。参见 `migration-inventory.md#p2-t1--38-条`。

**Files/anchors:** `Bailey/Editor/{SourceTextEditor,NativeCodeTextView,NativeTextLineIndex,EditorFind}.swift`、`Bailey/Editor/FileViewerView.swift`；目标 `BaileyUITests/Editor/EditorNavigationUITests.swift`／`EditorInputUITests.swift`（按实际职责最小拆分）；纯文本几何算法必要时使用 `BaileyTests/Unit/Editor/TextCoordinateIndexTests.swift` 或新增职责相同的逻辑单测。

**Step 1 — 旧断言与输入夹具：**
- 逐项保留 `docs/testing.md#性能与内存测量` 中既有编辑器回归：382／1,000／10,000／100,000 行、折行两态、首/中/末每处 30 次编辑、至少 17 次交错远跳；冷/热可见首帧、长无空格行与变高内容、删除最长行后横向范围、滚轮与最远端、选区/滚动位置及窗口/字号变化。不因跨进程难测就以一次 `typeText` 替代视口生命周期证据。
- 枚举 10 项原生输入：连续输入、选区替换、组合输入 mark/unmark/commit/cancel、隐式／显式 replacement range、中文／Unicode／组合字符、多光标、Undo/Redo、编辑器卸载与再挂载、输入几何跟随真实编辑器。注明原测试中对内部 `NSTextView` 的独占断言是否必须拆为纯逻辑或真实 GUI。
- **在本 task 内**核实真实 TextKit 输入与像素/AX 的跨进程可观测性：`XCUIElement.typeText` 并不自动证明真实拼音输入法 composition；需用实际输入法/专用 GUI 条件补验的行为保持明确 Gate，不能把普通键入当作 composition 覆盖。

**Step 2 — 实现与替代清理：**
- 用真实 App 创建/打开文件，靠 UI 的导航快捷键、滚动条、滚动和选择交互核对实际可见行、AX 文本与最后选区；对重绘保持和 Undo 以真实输入后的文档及磁盘字节为最终证据。
- 将纯坐标换算、UTF-16 与 grapheme、range 变换等和 UI 无关的约束保留/转移至 Unit；需要颜色、视口、光标位置或键盘归属的仍由 E2E 与原生/像素对照负责。
- 新测试必须操作真正挂载的原生编辑器、证明输入/布局错误可检测。原 38 条全部核销后删两个旧文件及宿主 helper；**同任务修改 `.github/workflows/ci.yml` 的 `Bailey/Editor/*` 选择分支**，只引用仍存在且覆盖实际语义的非 UI 类。若被选类为空须使 CI 明确失败/退回全量，不接受 Xcode `-only-testing` 静默执行零项。
- 同任务更新 `docs/features/editor.md`、`docs/ui.md`、`docs/testing.md` 的实际测试入口；**首个旧原生 UI suite 真正删除时**，同步修改 `AGENTS.md` 对 `BaileyTests`/`BaileyUITests` 的长期目标及过渡事实，不能仍把“宿主原生测试必须保留”作为现行强制规范，也不能提前宣称目录已清空。

**Step 3 — 验证：**
- `make build:ui SIGNING=adhoc` 及专用 Runner 上 `make test:ui SIGNING=adhoc ONLY_TESTING="BaileyUITests/EditorNavigationUITests BaileyUITests/EditorInputUITests"`（类名以最后落地值为准）；同步按现行 Makefile 执行受影响的 `TextCoordinateIndexTests` 与已存在编辑器宿主测试直至清理完成。全部成功、0 个非理由跳过。
- Coverage：382／1,000／10,000／100,000 行、折行两态、首/中/末各 30 次编辑与 17 次交错远跳；长行/删除最长行后的滚动范围、字号/视口/主题、中英与真实 IME 组合确认/取消/Undo、重挂载、Tab、多光标、Unicode/UTF-16 与编辑后文件字节。按 `docs/testing.md` 分开测裸 TextKit 与真实 Neon/TreeSitter 的热操作（≥30 次，median/p95/worst），不新造硬预算；删除旧类时同步更新 `docs/development.md` 和 `docs/testing.md` 中点名该类的调用指南。
- Uncovered：真实物理 IME 及当前不存在的设备/OS 单独列明限制、替代证据与 Gate；无法得到的 UI 几何证据不得因算法 Unit 绿色被宣布通过。
- **Commit boundary:** 导航和输入的 UI/纯逻辑覆盖 + 两套旧文件删除 + 相应文档，独立提交并关联实际验证。

<a id="p2-t2"></a>

## P2-T2 文件标签、真实读写、保存冲突与断线恢复

**Own old tests:** `BaileyTests/NativeUI/Editor/FileTabTests.swift`（49）。

**Files/anchors:** `Bailey/Workspace/{PaneTab,Project,WorkspaceWindowModel,WorkspaceBackend}.swift`、`Bailey/Remote/{RemoteConnection,SSHWorkspaceBackend}.swift`、`Bailey/Editor/FileViewerView.swift`、`BaileyUITests/Files/WorkspaceFilesUITests.swift`；模型事务测试归 `BaileyTests/Integration/Files`／`Workspace`，不直接挂 `NSHostingView`。

**Step 1 — 拆 49 条验证链：**
- 按真实入口区分首次惰性加载、文件改名/符号链接、无效 UTF-8、二进制、过大/只读、图片预览、用户保存/自动保存、失败重试、失活写盘、可编辑 AX 内容、脏态/撤销、窗口关闭否决、多文件异步交错、SSH 延迟和断线、远端与本机工作区的目标身份。
- 将依赖可控后台 `WorkspaceBackend`／continuation 的乱序、错误、竞争和字节精确性仍保留在**非 UI Integration**；从用户操作验证这些不变量在真实 App 中表现为正确数据、提示、重试和恢复。不能只测 `FileTab.isDirty` 改变而漏最终磁盘。
- 以原 49 条中已识别的容量门槛和路径规范作为真实 fixture 参数，不把旧源文件内的 mock 成功误认为远端实测。

**Step 2 — 替代与清理：**
- 扩展现有 `WorkspaceFilesUITests`，经 File Manager / Open File 与真实文本编辑器完成打开、保存、关闭、再次打开、切窗口、重命名、拒绝保存、背景窗口已有脏文件等路径；只修改 UI AX 语义不足的地方。
- 原 49 项中的暂停读/写、continuation 乱序、断连恢复及失败留存使用当前 `FileTab`/`WorkspaceBackend` 真实非 UI 状态测试或最小可测试逻辑，不为了 XCUI 用例制造 UI 专用故障注入后门；只把实际可由 App 触发的保存/读取失败作为 E2E。旧 49 项逐条替代后移除 `FileTabTests.swift` 与旧窗口 fixture；同任务移除 CI 中该类名及相应文档引用，不让增量测试空跑。
- 影响 `docs/features/editor.md`／`docs/features/projects.md`／`docs/features/ssh.md` 的验证入口当任务更新，不改保存、关闭或远程回退的现行产品契约。

**Step 3 — 验证：**
- P1 安全 Runner 上执行 `BaileyUITests/Files` 相关测试，非 UI 测试用 `make test:类名1,类名2` 人工点名同根因相关类；合格的结果须包括磁盘 bytes、失败后编辑内容未丢、文件无串窗/串机、恢复后 Undo 正确。
- Coverage：空/Unicode/过大/二进制/非法字节/只读/不存在、内部最大读取边界与前后一字节、改名/符号链接/重复打开、首次载入晚返回、刷新错误与恢复、保存中再次编辑与改名、关闭/退出时脏缓冲、同名本机/SSH、断连/重连/目标切换的时序组合。
- Uncovered：Windows SSH 实机若无授权，保留非 UI 后端测试、单独记录真实远端 GUI 缺口及可能影响；非 UI 故障注入不能冒充真实网络时序。
- **Commit boundary:** 49 条逐项核销、UI 与非 UI 对应测试、删除源套件、关联功能文档和实际验证。

<a id="p2-t3"></a>

## P2-T3 语法高亮、主题、组合字符与原生颜色

**Own old tests:** `BaileyTests/NativeUI/Editor/SyntaxHighlightingTests.swift`（22）。

**Files/anchors:** `Bailey/Editor/{SyntaxHighlighting,SyntaxHighlightConfiguration,NativeCodeTextView,SourceTextEditor}.swift`、`Bailey/App/Theme.swift`、现有 `BaileyTests/Unit/Editor/{HighlightQueryCacheTests,TextCoordinateIndexTests}.swift`；确有需要时补非 UI token parser 测试，UI 目标可为 `BaileyUITests/Editor/EditorHighlightingUITests.swift`。

**Step 1 — 明确两类不同事实：**
- 非 UI：Neon/TreeSitter parser capture、UTF-16 chunk、嵌套语言、查询时序、失效 token 剔除、编辑变换范围、取消/过期返回、coordinator 生命周期的可纯化部分。
- 真 UI：Swift/Markdown/TSX/HTML/CSS 的可见语法颜色、选区与高亮不污染正文/字体/Undo、浅/深主题、语言随改名切换、删除所有内容/插入/撤销/多光标／Unicode 组合后当前视口实际色彩。
- 无法通过 XCUITest 直接取 `NSTextStorage` token 时，优先把计算搬非 UI 测试，并在 App 截图/可访问内容上证明最终渲染，必要时用可重复截图的可观测差异；不在测试中引入私有 parser-to-UI 通道。

**Step 2 — 实现与清理：**
- 独立 Runner 以相同字体/外观/尺寸获取原生视觉与字节证据，覆盖嵌套高亮、多次异步编辑和关闭后旧请求不能重染。颜色取样遵守 `docs/testing.md` 已有的 sRGB 目标色彩空间、像素位深和原容差；不得通过改变颜色空间或放宽阈值制造通过。
- 拆分原 22 项，真实 parser/token/旧请求废弃的逻辑仍由非 UI 测试精确断言，视觉输出在真实 App 验证。替代成功后同任务删除 `SyntaxHighlightingTests.swift` 及独占宿主 helpers，清掉 CI `Bailey/Editor/*` 中旧类名；不触动仍有调用方的生产 `SyntaxHighlighting`、`TextKit 2` 及安全失效校验。
- 当场更新 `docs/features/editor.md`、`docs/ui.md`、`docs/testing.md` 及 `docs/development.md` 中仍引用 `SyntaxHighlightingTests` 的上游升级/高亮回归入口，不能只删类不更新长期受测契约。

**Step 3 — 验证：**
- 非 UI parser 的原生查询输出精确比对、E2E 真正渲染截图/可见文本与 Undo 后 bytes、针对性 Unit 与专用 Runner UI 测试均需要真实执行。
- Coverage：Markdown fence 各语言、含中文/emoji/组合字符、LF/CRLF、UTF-16 边界、撤销、多个文件／Diff 颜色协调、主题切换与字形大小、队列排队/取消/过期解析、删除尾部及全文、100k 行／既有 token 性能夹具。
- Uncovered：截图若不能稳定辨别真实颜色/像素应记录能力缺口和补验方法；不得用文本 bytes 正确代替“颜色正确”。
- **Commit boundary:** parser 非 UI 测试、真实高亮视觉 E2E、旧高亮宿主删除、文档同步与结果。

<a id="p2-t4"></a>

## P2-T4 Diff 原生绘制、编辑、展开及真实保存

**Own old tests:** `BaileyTests/NativeUI/Git/DiffTabTests.swift`（35）。

**Files/anchors:** `Bailey/Git/{DiffViewerView,DiffNativeSurface,DiffTextView,DiffSyntaxHighlighter,DiffEngine,GitPanel}.swift`、`Bailey/Workspace/PaneTab.swift`；可新增 `BaileyUITests/Diff/DiffEditorUITests.swift`，非 UI 算法复用 `BaileyTests/Unit/Git/DiffEngineTests.swift` 和相关 `Integration/Git` 类。

**Step 1 — 核实原生与模型断言：**
- 将 35 项分成真实用户可见的 split/unified、删行 ghost 与行高、背景色/对齐、fold/unfold、滚动同步、Diff 编辑/Undo/保存/恢复、文件/历史切换和 AX，及纯 Git blob/index 读取错误、LF/CRLF/裸 CR、Unicode、二进制和大对象限制。
- 读 `DiffNativeSurface` 与 `DiffTextView` 实际共用 TextKit 的装配/保存路径，避免只验证按钮选择、漏掉真实差异文件对应的 worktree/index 内容。具有危险性的 Git 操作仅在唯一临时仓库执行。

**Step 2 — 替代与清理：**
- 从真实 Git Changes、已暂存区、历史提交进入 Diff，操作视图模式切换、折叠、水平/垂直滚动、切到编辑、模拟失败、保存并重新打开；截图与 AX 断言确认红绿背景/删除 ghost 的存在和位置，而非把它写成数据模型测试。
- 纯 Git revision 读取、Unicode 行切分、过期读取消/保存竞态由非 UI 直接校验；对应 E2E 证明渲染、编辑、保存、实际 index/工作区结果。原 35 项逐条完成后同 task 删除 `DiffTabTests.swift` 和独占 fixture；**同步更新 `.github/workflows/ci.yml` 中 `Bailey/Git/Diff*.swift` 的旧类名列表**以及当前 `docs/testing.md` 选择指引。
- 同步 `docs/features/diff.md`、`docs/features/editor.md`、`docs/testing.md` 以及 `docs/development.md` 中仍引用 `DiffTabTests` 的升级/回归命令；同任务删 CI 旧类和无用宿主 helper。

**Step 3 — 验证：**
- 新 `BaileyUITests/Diff` 的真实 App 用例 + Git index/HEAD/工作区内容 + 非 UI `DiffEngineTests` 与相关集成测试，在 CI GUI Runner 和可用 OS 分别执行，核对完整命令结果而非单独 `testcase passed`。
- Coverage：单/多文件、分屏/统一、删光所有行与 ghost EOF、行号/首字形/查找栏几何、长单行与 LF/CRLF/裸 CR、Unicode 分段、binary、未合并 index、缺失 revision、读写失败/迟到、保存中再次编辑、换窗/项目、浅深主题、窄宽面板、滚动、实际 fold/AX；像素取样保留现行色彩空间与容差。
- Uncovered：原生几何/像素、TextKit 视口以及某些中间帧无法从 XCUI 直接读取；先执行已知能发现差异的渲染/AX/交互对照，若仍不能证明原不变量，则保留等价的非 UI 测试或明确旧项不能删除，不用「截图已附」冒充像素断言。
- **Commit boundary:** 35 条旧方法逐项去向、Diff E2E 与非 UI 算法、删除旧 source、文档和真实结果。

---

## Phase Audit

实际执行完成 P2 全部 tasks 后生成 `audit-p2.md`；核对 144 条方法映射、对应旧 5 个 suite 清理、原生可见结果与模型值的一致性、保存失败/撤销/极端输入、专用 GUI Runner 与所有无法补验的明确边界，不接受“数量接近”代替行为等价。

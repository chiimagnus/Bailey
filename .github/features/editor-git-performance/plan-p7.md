# P7：Tree-sitter 插件隔离对照与条件迁移

**目标：** 判断能否用官方 [STTextView-Plugin-TreeSitter](https://github.com/krzyzanowskim/STTextView-Plugin-TreeSitter) 替代旧的 STTextView-Plugin-Neon／本地 Neon／本地 TSX 维护链，保持 Kero 原生编辑器和 Diff 的既有行为，降低长期维护成本。

**非目标：** 不把 Kero 改成通用 IDE，不主动添加 LSP／补全，不重写解析器；不为了删包改写 TextKit／终端；不在本阶段改 Git Diff 的 Myers／Patience 算法。上游插件内置的 38 种语法允许保留，不为裁成三种语法另建私有 fork；Kero 仍以 Swift、TypeScript／TSX、Rust 为日常重点，既有 JSON、Markdown、Shell、配置及嵌入语言能力不得回归。语言实际识别范围如无需求不主动扩大。

**顺序：** P4 当前 Git 工作完成后执行本阶段；P7 判定与可能的迁移完成后才执行原 P5 Git／Diff 性能任务，最后 P6 综合复测。不要重开已审计完成的 P3，也不要把插件迁移夹进 P4 的 Git 状态提交。新候选未通过 Gate 时保留现有 Neon，不为完成阶段强行迁移。

**实际源码边界：**
- 入口 `kero/Editor/SyntaxHighlighting.swift`：`SyntaxLanguage`、`SyntaxHighlighting.plugin(for:)`，语言与查询映射／继承；`SourceTextEditor.swift` → `STTextView.addPlugin`。
- 高亮 `kero/Editor/SyntaxHighlightPlugin.swift`：`SyntaxHighlightCoordinator`、`HighlightQueryCache`、版本校验、Markdown／HTML 注入、临时前景色；`TextCoordinateIndex.swift` 维护 LF／UTF-16 点。
- 另一消费者 `kero/Git/DiffSyntaxHighlighter.swift` 共用语言、查询编译与颜色；替换时不能仅证明 Source 编辑器能着色。
- 构建 `kero.xcodeproj/project.pbxproj`、Package.resolved、`Vendor/Neon`、`Vendor/TreeSitterTSX`、`Vendor/STTextView`；`NOTICE.md` 与 `docs/development.md` 维护来源／许可证。
- 既有回归 `SyntaxHighlightingTests`、`HighlightQueryCacheTests`、`TextCoordinateIndexTests`、`EditorTextInputTests`、`EditorNavigationTests`、`DiffTabTests`、`DiffEngineTests` 与 `PaneRetentionTests`。
- 候选上游固定对照 revision `346bbce977ce6a485ff9ad5696bebbe8790241e9`：`Sources/STPluginTreeSitterCore/{TreeSitterClient,SyntaxHighlightService}.swift`、`Sources/STPluginTreeSitterAppKit/{Coordinator,TreeSitterPlugin}.swift`、`Sources/TreeSitterResource/TreeSitterLanguage.swift`、Package.swift。实际迁移前复核目标修订，不盲目跟随 main。

## 已知风险与准入

1. 新插件包从 STTextView 2.4.0 起依赖；Kero 的 `Vendor/STTextView` 基于 2.3.11 并持有输入法、行号、滚动、只读等真实补丁。必须核对 API 和补丁覆盖，不能只靠相同 SwiftPM identity 认为兼容。
2. 新包 `TreeSitterResource` 实际连接 38 种解析器／38 个查询资源 target；包本体额外有 6 个 target，总计 82。直接添加整个产品会增加编译工作和 App 代码体积，不能拿 257 MB 源码 checkout 或 138 MB Release 构建目录冒充安装大小。用户允许全量语言，不因此维护瘦身 fork；记录相同构建设置下的真实 App、压缩包与首次构建对照。
3. 上游 `Coordinator.updateViewportRange` 在视口变化时调用 `requestInitialHighlighting` → `TreeSitterClient.resetDocument`，即全文解析。实际隔离 Release 对 93,000 UTF-16 单元重复重解析 8 次，中位约 63.4 ms。属于源码可达性能风险；单项函数时间不是实际滚动时延。必须同机实测长文档前后滚动、连续输入及颜色追上。不得为新依赖接受可复现的反复全文解析卡顿，也不在 Kero 外再维护一个本地解析引擎。
4. 上游隔离语法捕获：Swift／Rust／Markdown 能返回 token，但小样本 TypeScript 只有 1 个 capture，TSX 只有 2 个；**只能证明解析成功，尚不能证明旧的 JSX、字符串、注释等高亮等价**。现行 Kero 使用继承查询、独立 TSX 和注入资源；先核对真实渲染颜色、查询组合与注入，不以 token 非空为通过。
5. 原生界面仍必须使用 Kero 长生命周期的 STTextView，标签重挂载不丢选区／滚动／撤销；只允许更新临时前景色，不修改文本、字体、保存状态。SwiftUI 桥接和 STTextView 本地修复不因插件更名而更换。

<a id="p7-t1"></a>
## P7-T1 新旧插件隔离对照与迁移 Gate

**类型：** 必须先完成的本地实验；无产品代码／依赖迁移。

1. 复用 `build/performance/editor-git-20261016/` 已有样本、原生 XCTest 和记录；候选检出目录仅放 `build/performance/editor-git-20261016/plugin-treesitter-compare/`，不污染 `kero.xcodeproj`、共享 `build/DerivedData` 或安装的 Kero。对旧版锁定包和候选版本固定 commit、Xcode、架构、优化、窗口、文本、缓存条件。
2. 先在隔离包证明 Swift／TypeScript／TSX／Rust／Markdown 的解析、capture 名称／范围和真实更新；补齐当前薄样本未证明的 TS/TSX JSX 标签／属性、注释、字符串，Markdown 围栏、HTML script/style 嵌入，中文／emoji、CRLF 和同版连续编辑。对照现行 `SyntaxHighlightingTests` 的原生文本颜色、取消、Undo、重新挂载和版本失效边界；不能拿上游两项单测代替 Kero 原生集成回归。
3. 验证 `Coordinator.updateViewportRange` 的全文 reset 风险，按 P1／P3 同机样本测新旧首屏、重复前后滚动、输入返回、高亮追上、内存与关闭后释放；热路径每侧 30 次并报中位／p95／最差，冷加载独立采样。现有 P3 实测与本候选测试不完全同构，未经相同条件重跑不得报速度倍率。
4. 对照候选 STTextView 2.4.0 的接口、Kero 本地 2.3.11 修复及 Swift 6 并发构建；若必须升级上游 STTextView，逐项证明 IME、焦点、行号、滚动、Find、只读、固定行高仍成立，不以构建通过替代。
5. 记录当前同设置 Debug／Release App 大小、首编译时间和压缩包大小；候选全面构建后测实际安装包增量。区分语法对象代码、查询 bundle、符号与覆盖率插桩，不把 checkout、测试二进制或 Xcode cache 加到 App 体积。
6. **Gate：** 行为等价且无显著高亮／输入／滚动退化、能复用上游实现而非新建本地 fork、版本兼容明确，才允许 T2。若捕获缺失／全文重解析／API 不兼容无法在上游解决，记录复现和保留旧实现的结论；T2 不创建无收益代码。候选优先向上游反馈，不在 Kero 补写第二套服务。

**证据：** `evidence-p7.md` 和以上本地实验目录；无产品变更不提交。实测属于隔离组件，不称完整 App E2E。

<a id="p7-t2"></a>
## P7-T2 按 Gate 迁移依赖、接入与原子清理

**类型／前置：** 条件实现；必须有 P7-T1 通过的真实证据。若 Gate 未通过，记录不迁移理由并结束任务，不强行替换。

1. 在同一个实现任务中通过工程原生 SwiftPM 装入经验证的插件版本，复用其语言资源、TypeScript／TSX／Rust 解析与符合需求的高亮生命周期。优先实际复用官方插件；仅在现有 Kero 必要视图／查询语义尚未被上游覆盖时保留最薄适配，不为减少包数再造高亮状态机。正式引入前完整确认 STTextView 2.4.0 要求与 `Vendor/STTextView` 的替换／升级边界。
2. 迁移 Editor + DiffSyntaxHighlighter 共享查询、资源和主题，保留项目内的字节准确、LF/UTF-16、旧任务失效、注入及颜色字体契约。必要真实缺陷先回归 Red，再 Green；迁移保持旧绿色等价测试，不制造降质通过的断言。
3. **及时删旧**：取消 `STTextView-Plugin-Neon` 及仅它需要的依赖；确认无消费者后删除 `Vendor/Neon`、`Vendor/TreeSitterTSX`、旧 SyntaxHighlightPlugin 桥接／Theme 等代码及不再使用的 package pin、文档引用／NOTICE。删除前逐项确认许可证／资源来源，不能删掉仍有实际使用者的 SwiftTreeSitter 和 Git Diff 高亮资源；不留“双引擎”回退开关。
4. 同提交更新 `docs/features/editor.md`、`docs/development.md` 与确实影响的 `docs/features/diff.md`／`docs/testing.md`、NOTICE。按原生 build/test 入口运行相关高亮、输入、Diff、Dock 及完整 `make test`、`make build`、`make build:release`，分别签名校验；隔离 App 检查 Swift／TSX／Rust 输入、查找、嵌入颜色、滚动、撤销／保存、标签切换与关闭。Debug 安装按开发规范进行，**不得把用户正在运行的 Debug Kero 换成 Release** 或强制重启；不推送。
5. 在相同编译／覆盖率设置下记录旧／新 App 和安装包、冷构建、首屏／输入／滚动对照；没有实际收益或存在高亮缺陷则撤销候选迁移，不保留兼容实现或额外配置。

**提交：** 只有确实迁移并经验证时原子提交应用、依赖图、删除旧链、回归与文档；证据文件按 Skill 只留本地。P7 完成后才解除 P5 Git Diff 工作的顺序门槛。

## 阶段核销

P7-T1 的 Gate 结果必须可复现、说明未验证之处；无论采用或不采用都要记录。未通过则明确继续保留现有 Neon／TSX 并注明待解决上游问题，不能在 P6 冒称迁移或已减小安装体积。若通过并迁移，旧路径、补丁来源、许可证、依赖图、Debug／Release 体积与原生回归必须由 P7-T2 当场闭环。

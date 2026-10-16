# P7：Tree-sitter 插件隔离对照与迁移 Gate

本文件归档 2026-10-16 基于 `crhllll@7f5352e` 的隔离实验；测量属于当时的代码和环境，并非后来提交或安装版本的编译、测试结果。Gate 未通过，因此未更换 Kero 的正式依赖和正在使用的 Debug App。预审数据来自当时工作区 `build/performance/editor-git-20261016/plugin-treesitter-compare/`，后续数据来自独立 worktree 的 `build/performance/plugin-compare/`；二者不能混称同一次测试。

## 当前完成的静态检查

- 官方候选 [STTextView-Plugin-TreeSitter](https://github.com/krzyzanowskim/STTextView-Plugin-TreeSitter) 实验修订 `346bbce977ce6a485ff9ad5696bebbe8790241e9`；SwiftPM 从 STTextView 2.4.0 起依赖，支持 SwiftTreeSitter 0.25，产品依赖的 `TreeSitterResource` 引用 38 个语法 target 和相应 38 个查询资源 target。候选源目录下载约 257 MB **不是安装体积**。
- Kero 当前 `Vendor/STTextView` 基于 2.3.11，仍有真实 IME、滚动、只读等本地补丁；当前源映射主要向现有 20 语言 + TSX 暴露功能，不因候选多语言自动改变映射。
- 候选 `Coordinator.updateViewportRange` 每次变化请求 `requestInitialHighlighting`，最终调用 `TreeSitterClient.resetDocument`；这是已确认源码路径，不是已经执行的完整 App 滚动基准。
- 候选包自身现仅发现 `TreeSitterClientTests` 一组 2 项，不足以证明真实 Kero 的注入语法、滚动、输入和 Diff 路径。

## 前次预审的隔离检查（原工作区）

1. `upstream-test.log`：候选 Debug 包从源码全量构建完成（约 71 秒，隔离构建，非 Kero 项目构建），上游 2 项 XCTest 通过。
2. `kero-isolated-comparison.log`：增加仅在忽略的隔离目录存在的 3 项测试。Swift／TypeScript／TSX／Rust／Markdown 各语法能返回范围合法的 capture；30 次文首插入后的增量结果范围合法；同一 93,000 UTF-16 单元 Swift 文本 reset 8 次。Debug 3/3 通过，reset 中位约 318.1 ms。
3. `kero-release-comparison.log`：相同 3 项隔离 XCTest 在 Release 下 3/3 通过（包构建约 66.8 秒），reset 8 次中位约 63.4 ms、最差约 64.2 ms。**注意并非与现行 Kero 相同条件的滚动性能对照**。
4. 当前短样本捕获类型：Swift 11 个、Rust 9 个、Markdown 15 个；TypeScript 仅 1 个 `type.builtin`，TSX 仅 2 个 `keyword`／`type`，目前不能证明用户可见语法颜色等价；正式 Gate 需真实 JSX／注释／字符串及嵌入语言逐项验证。
5. 正式 Release 包当前 `build/DerivedData/Build/Products/Release/Kero.app` 约 84 MiB、安装的 Debug `/Applications/Kero.app` 约 95 MiB；Release Mach-O 带 `__LLVM_COV` 约 18.7 MiB 和约 2.0 MiB 的覆盖率数据。需要禁用／固定相同插桩口径才能对比新插件的体积。独立包 `.build/out/Products/Release` 约 138 MB **不是 Kero.app 体积**。
6. 用户提出 `build/DerivedData` Finder 显示约 48 GB；2026-10-16 同机 `du -sh build/DerivedData` 实测约 3.4 GiB、整个 `build/` 约 7.7 GiB，Finder 差异尚未解释。实际 Debug App 身份通过 `kero.debug.dylib` 核对；未清理共享构建缓存、不退出或重启用户 Kero。

7. 单独比对候选 Release 编译产物的解析器目标：相对于当前 20 语法加 TSX，候选新增 17 种；这些新增解析器的 C `parser.o`／`scanner.o` 中 `__text + __const + __data` 原始 section 载荷合计约 **15.03 MiB**，对应 object 文件总大小约 **18.2 MB**。这只是链接前的目标文件静态对照，不是最终 App 的增量；链接器去重／裁剪、查询 bundle、覆盖率插桩及其他代码都会影响实际安装包。

## 2026-10-16：独立 worktree 的真实 Gate 验证

- **基线与隔离**：从与 `origin/crhllll` 一致的 `7f5352e6d74ff18c6cfda290650e28cf2548276e` 创建 `/Users/chii_magnus/Github/kero-worktrees/treesitter-plugin`，分支 `feat/editor-treesitter-plugin`。候选源码检出到工作树忽略的 `build/performance/plugin-compare/upstream/`，固定上游 `346bbce977ce6a485ff9ad5696bebbe8790241e9`，不改主应用 SwiftPM／Vendor，不安装／重启 `/Applications/Kero.app`。
- **上游自身验证**：`swift test --package-path build/performance/plugin-compare/upstream --jobs 4 --filter TreeSitterClientTests` 编译通过；**2 项通过、0 失败**，见 `upstream-test.log`。使用了上游 STTextView 2.4.1 和独立 SourcePackages，与 Kero 固定的本地 2.3.11（9 项实际补丁）不同。
- **增补负向证明**：只在忽略的上游实验目录增加 `KeroGateTests.swift`，检查真实返回的 Tree-sitter token，而非单纯检查 query 文件名。相同 4 项 Gate 用例分别以 Debug／Release 构建执行：**每组 2 通过、2 失败、5 条断言失败**，完整日志 `gate-debug.log`／`gate-release.log`。TypeScript 的 `// hello` 注释与 `"world"` 字符串缺失 `comment` 和 `string`；TSX `<main title="hello">` 缺失 `tag`、`attribute`、`string`。打印的原始捕获集合分别为 `typescript: [type.builtin]` 和 `tsx: [keyword, type]`。Swift／Rust／Markdown 的初始捕获和 Unicode／CRLF 范围合法通过。
- **根因已定位**：新插件的 `TreeSitterLanguage.configuration` 单独读取各自目录的 `highlights.scm`，TypeScript／TSX 的文件只包含本语言特定的查询，未合并 JavaScript 基础查询与 `highlights-jsx.scm`。当前 Kero `SyntaxHighlighting.highlightsData(for:)` 明确合并这些查询，已有原生颜色回归验证。候选默认 `TreeSitterPlugin` 构造接口仅暴露 `theme`／`language`，不能无损注入 Kero 当前继承查询，故不是改几行工程依赖就能做到等价。
- **复现计算成本**：在同一 93,000 UTF-16 单元 Swift 文本上进行 **30 次**连续 `TreeSitterClient.resetDocument`，Debug 中位／p95／最差为 **317.57／321.72／334.26 ms**，Release **65.22／70.65／76.99 ms**。候选 `Coordinator.updateViewportRange → requestInitialHighlighting → performReset → resetDocument` 在每次视口范围变化时可达全文解析；当前结果只证明这一单步成本，未冒称它就是物理滚动帧时延，也未做同配置 Kero 热路径 A/B。
- **兼容风险**：候选包要求 STTextView 2.4.0+，隔离解析到 2.4.1；已对比代码路径，Kero `Vendor/STTextView` 的原生输入法、滚动、辅助功能等补丁不能凭版本号视为已覆盖。无需进入迁移才发现不可逆问题。
- **同基准旧版 Kero 原生测试**：首次 worktree SwiftPM 包图缺少已存在的 Ghostty 162 MB 二进制 artifact 登记，Xcode 因此在 `Resolve Package Graph` 发起网络下载。对照主工作区相同的 9 个远程依赖 revision、目标文件和上游校验和后，**只在 worktree 忽略的 `build/SourcePackages/workspace-state.json` 写入正确的现有框架路径**，没有修改工程、Package.resolved 或主工作区缓存。`xcodebuild -resolvePackageDependencies` 随后通过（`package-resolution-fixed.log`）。重新运行原生 XCTest：`SyntaxHighlightingTests` **15/15**、`HighlightQueryCacheTests` **2/2**、`DiffTabTests` **19/19**、`EditorTextInputTests` **3/3**，**合计 39/39 通过，0 失败**；日志依次为 `kero-baseline-fixed.log`、`kero-baseline-query-cache.log`、`kero-baseline-diff-tab.log`、`kero-baseline-text-input.log`。未退出、重启或替换当前用户的 `/Applications/Kero.app`。

### 结论：No-Go（当前上游 346bbce）

**不采用新插件替换 Neon，不扩展正式 Kero 的 38 种语法，也不新增 Kero 自维护的 Tree-sitter 插件 fork。** TypeScript／TSX 是用户明确的核心语言，高亮退化已经由同机可复现用例直接证实；只要这个强制门槛失败，继续花费完整 App 首屏／滚动 A/B、增量包体积和多窗口迁移验收就无法改变本次“不准合入”的结论。原 P7-T2 条件没有成立，按计划不修改产品代码、依赖、许可证与长期开发文档，避免把错误高亮部署给用户。此前的两次原生 Kero 基线运行曾因缺少 SwiftPM artifact 登记卡在依赖解析，现已定位并只修复 worktree 缓存；正式旧版 Kero 的 **39 项原生 XCTest 全部通过**。候选插件自身 Gate 仍是 Debug／Release 均 2/4 未通过，属于独立复现的兼容缺陷；没有做迁移后的 Kero 原生 A/B、实际滚动与 App 体积测试，不将其冒充已完成。

**重评条件**：上游实现 TypeScript／TSX 继承和 JSX 查询合并，取消视口变化时无谓的全文 reset，并用 Kero 所需的 IME／滚动／同版颜色等价测试证明与原生 STTextView 版本兼容。届时重新执行本阶段的热路径 A/B 与实际 App 大小对照，再决定是否移除本地 Neon／TSX。

**归档说明**：已把关键输入、失效捕获、提交版本、测量口径、结果和修复原因记录在本页及 `audit-p7.md`。上文 `.log` 和临时 `KeroGateTests.swift` 属于本次被忽略的隔离工作目录，删除 worktree 时一并清理；它们不是仓库内长期可访问的附件。重评时应按本页的输入和测试断言重新复现，不能把旧测试记录当成新版本通过。

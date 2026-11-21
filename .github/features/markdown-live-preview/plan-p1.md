# P1｜安全 Markdown 预览、Front Matter 与 File 菜单

交付在同一文件标签安全排版 Markdown／GFM（`.md`／`.markdown`／`.mdx`），正确识别 `SKILL.md` 元数据，并由系统 File 菜单双向切换。

## 技术决定

- **扩展名选择：**`.mdx` 与 `.md` 同一源码／预览路径；Swift Foundation `AttributedString(markdown:)` 已在隔离运行中保留 `import`、`<Chart series={values} />`、`{score + 1}` 和组件标签的可读文字，无 JS 运行时。但这是普通 Markdown 解析而非 MDX 兼容承诺；后续必须检查 preview 实际不丢内容、内容不执行、关闭保存无损。
- **SPM：**[Textual 0.5.0](https://github.com/gonzalezreal/textual) 作为 SwiftUI 原生 Markdown 排版，使用其 Foundation `AttributedString` 解析能力；不同时引入 `swift-markdown` 充当第二个普通 Markdown 解析器。
  Textual 自带代码高亮、表格和通过 `SwiftUIMath` 支持的数学排版；它的 `CodeBlockStyle` 提供语言标记，但没有公开源代码字符串，**不能据此认定 Mermaid 和复杂内联 HTML 已能直接嵌入**。
- **SPM：**[Yams 6.2.2](https://github.com/jpsim/Yams) 解析 YAML Front Matter；[SwiftSoup 2.14.4](https://github.com/scinfu/SwiftSoup) 解析、净化**受支持的静态 HTML 片段**，不用 WebKit 渲染 Markdown。
  SwiftSoup 的默认 allowlist 可能允许远程 URL；必须自建仅准许受控相对资源的列表，且真实读取仍通过后端权限验证。
  **Textual 的默认 `imageAttachmentLoader` 会使用 URLSession 下载图片**，不可照搬；必须通过 `.textual.imageAttachmentLoader(customLoader)` 注入自定义 `AttachmentLoader`，只准经 `WorkspaceBackend` 授权的当前项目内静态资源，禁用外网与不受控 `file:`，并用 `.environment(\.openURL, OpenURLAction { … })` 拦截链接点击。
- **需要验证的边界：**先用真实 `SKILL.md`、GFM、嵌套 HTML、代码围栏测试 Textual 的结构信息与自定义附件。
  若无法保留 Mermaid／原始 HTML／脚注所需节点和源码区间，再评估仅为 AST 增加 [swift-markdown](https://github.com/swiftlang/swift-markdown)，而非先上两套解析器或写正则拼装完整 Markdown。
  **判定方式：**从真实 `SKILL.md` 获取 Front Matter、`mermaid` 完整围栏、HTML/音视频节点和原文位置，证明能渲染为原生 View；缺任一关键结构即切换到 AST 方案，不把其丢失伪装成普通文本。
- **离屏解析已验证：**Textual 的默认 `StructuredText(markdown:)` 在主 actor 解析；隔离基准中 500／5,000／20,000 行约需 11／119／502 ms，不能每次击键都同步解析。
  已验证 `Task.detached` 后台执行 `AttributedString(markdown:, including: \.textual)`，把不可变结果交给轻量自定义 `@MainActor MarkupParser`，再由 `StructuredText(versionKey, parser: preparedParser)` 渲染。生产版须按文件身份／代次取消过期解析；这里仅实测解析，不冒充 SwiftUI 完整布局性能。
- **已经验证：**上述三个 SPM 在 Swift 6.4.2、Xcode 27.2 下联合解析/编译通过；未接入 Bailey，也未通过真实 GUI 与负载验收。最低 macOS 15.6 不提高。
  真正引入 Bailey Xcode 工程时按 [开发依赖规范](../../../docs/development.md#依赖与本地补丁) 更新 Package.resolved 和第三方许可／NOTICE，不能将此隔离探针误认为已正式安装。

## 方案与真实入口

现有 `Project.openFile` → `FileTab`（`Bailey/Editor/FileViewerView.swift`）→ `FileViewerView` 管理文件读取、唯一原生 `NSTextStorage`、保存及重载。
解析 HTML 不得引入第二份可写源文件；Markdown 生成的是只读显示快照。
Textual 排版只读显示结果；Front Matter 必须先在文首提取，不交给正文渲染器。
结构缺失时执行上述有界 AST 兼容性实验，**禁止**通过简单正则模拟完整 CommonMark、HTML 或 JSX。
Front Matter 用无执行能力的 YAML 数据解析器，作为文档头部元数据，而不是普通段落或可执行配置。
权限检查必须延伸到图片和媒体资源的实际解码请求，不能只验证文本 URL。

全局 `⌘⇧V` 只由 `Bailey/App/BaileyApp.swift` 的 `CommandMenu("File")` 注册；
右键菜单如需同一组合键，使用原生局部绑定，不在 View／Editor 另建全局监听。
沿用现有 Save 的 `WorkspaceWindowModel.selectedProject?.focusedContent` 和前台主窗口校验；
`WorkspaceDockView.projectTabMenu` 的显式右键视图选择只作用被右键的文件标签，不推断它是当前输入焦点。
主菜单动作的可用性、标题和目标由当前有效文件显示模式决定；
右键菜单只操作本次命中的文件标签，不改变主菜单命令目标。

## 任务

<a id="p1-t1"></a>
### P1-T1 Markdown／GFM、Front Matter 与安全静态资源

- **位置**：`FileTab` 原生正文读取、`FileViewerView` 新增只读渲染、既有 `WorkspaceBackend` 资源读取和 `BaileyTests/Files`。
- **实施**：`.md`／`.markdown`／`.mdx` 一律路由到本 Markdown 阅读器；CommonMark/GFM、标题锚点、表格、任务清单、围栏代码和安全内联 HTML；
  仅在 BOM 后文首检测配对 `---` 的 YAML Front Matter，保留全部原文字节，允许文件标签右键查看解析出的元数据。
  相对位图通过 Textual **自定义 `AttachmentLoader`** 按当前文件实际项目、机器和获准目录定位；
  SVG 保持局部替代文本，P2-T3 随原生 SVG 解码接入。绝不使用默认网络 loader；
  外部链接由原生 `OpenURLAction` 拦截并显式交给 Browser，不直接系统打开，失败以局部替代文本展示。
- **验证**：后台解析与主 actor 应用结果分离；测量 2,000～20,000 行及现有 32 MiB 文本边界的解析、布局和主线程卡顿（上述 502 ms 是纯解析基准，非 GUI 指标）；
  `.mdx` 混排 GFM、Front Matter、`import`／`export`、JSX 组件及花括号表达式在预览中仍可读但不执行；以真实渲染和解析器输出交叉核验，而非“能编译”；`SKILL.md` 多行 YAML 值、注释、空值、自定义 YAML 标签、未闭合／非头部横线；
  GFM 的表格、任务清单、删除线、自动链接、代码围栏的完整源片段/语言信息、Unicode、HTML 节点是否可映射原生 View；
  SVG/PNG 丢失、转义路径、权限、文件更名、SSH 与同名本地文件；恶意标签及完全离线验证。
  用 URLSession 拦截／无网络环境确认 Markdown 资源、emoji attachment 与普通链接**都不会借 Textual 默认 loader 向外发请求**。
  若 Textual 不支持必要结构，记录失败输入及追加 AST 库的直接理由，再开展实现；不能把富媒体需求降级为普通代码块而宣称完成。

<a id="p1-t2"></a>
### P1-T2 统一 File 菜单快捷键和动态置灰

- **位置**：`BaileyApp.swift` 的 File `CommandMenu`、`WorkspaceWindowModel` 当前活动文件路由、`WorkspaceDockView.projectTabMenu`、`FileTab` 的单份显示状态和 `docs/features/editor.md`。
- **实施**：在 Open File 与 Save 间常驻一个命令：
  `Button(当前是源码 ? "显示预览" : "显示源码")`、
  `.keyboardShortcut("v", modifiers: [.command, .shift])`、
  `.disabled(!canToggleSourcePreview)`。
  源码→预览；预览→源码；并排→源码；CSV 则对应表格／源码。
  文件标签右键提供「源码／预览」；「并排」随 P2-T1 的真实 Dock 展示者接入。
  右键菜单不重复注册全局按键。
  格式支持、内容可用性及是否为当前真实活动 Dock 文件共同决定启用状态；
  工具栏／终端／Browser／普通代码及失去窗口焦点时系统菜单项置灰。
  只读允许切换；预览出错仍允许返回源码。
- **验证**：实际 File 菜单在支持／不支持格式、两窗、多个 Dock、后台右键标签、查找／设置焦点、关闭／重载及错误渲染时动态正确；
  单次按键只执行一次、无响铃、菜单项不消失、不触发别的窗口；屏幕阅读器可识别禁用状态。

## 阶段验收

首轮实施前先完成 Textual 的真实 `SKILL.md`／`.mdx` 普通 Markdown 语义／代码围栏／HTML 节点边界测试，确认所需 AST 数据可用；
再运行 `make build:ui`、宿主格式识别／权限／菜单路由测试和隔离 Bailey Dev 完整菜单／编辑 GUI 测试。
编辑和打开预览前后，文件原始字节与所有 TextKit Undo 仍一致。

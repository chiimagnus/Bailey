# 模块化重构：执行前独立审查

日期：2026-10-12。源码基线：`335a940`；`051c1fe..335a940` 的 `kero/`、`docs/`、`scripts/`、Xcode 工程没有差异。

本次从源码、当前文档和只读运行证据重新判断，没有读取或引用已有 `audit*.md`。交付是修订 Feature Plan，不是执行重构，也不是任何 Phase 的实现审计通过证明。

## 结论

计划方向成立，但原计划遗漏了真实的状态寿命、机器身份和最终操作目标问题，也误认了一些共享组件及验证入口。仅移动文件不能解决这些问题。

已在原有任务中修正这些遗漏，没有新增 Phase、Task、生产协议或服务层。本次审查只修改 Feature 文档，没有写产品源码、用户配置、会话数据或 todo 执行状态；读取基线时 18 个 Task 全部为 pending。

清理与职责调整必须在同一任务完成。P5 只检查遗漏和最终行为，不承担积攒下来的死代码、兼容分支或旧路径清理。

**并行变更边界：** 收尾时工作区已由另一轮执行推进 P1：一次观察中 P1-T1/T2 已 completed、P1-T3 为 in_progress，共享树迁移提交为 `26a3f4e`。两份新路径的共享实现与本次读取基线逐字节相同。本次没有回退这些变更或把 todo 改回 pending；这份审查覆盖下面注明的源码基线，不为并行实现签发 Phase Gate，实时执行状态以 todo 为准。

## 阅读范围与证据边界

### 自有实现

逐文件读取了全部 64 份手写 Swift 实现，包括大文件中的模型、私有类型、扩展和文件末尾 helper；没有只看符号索引或抽样读入口。

| 基线目录 | Swift 数量 | 核对的真实执行链与归属 |
| --- | ---: | --- |
| App | 6 | 启动/隔离入口、窗口创建、菜单与快捷键、设置读写、主题、Finder 服务 |
| Workspace | 6 | Project 创建/关闭/恢复、目标选择、两层布局、文件树、backend 与快照 |
| Terminal | 15 | 窗口协调、session/PTY、AppKit/Ghostty 挂载与焦点、查找、历史、通知、进程目录 |
| Git | 3 | 状态刷新与操作、双管道执行、远端批次、工作/暂存/历史树、Diff 原始字节 |
| Editor | 6 | FileTab 加载/保存/重绑定、编辑器状态、查找、语法高亮；其中 1 份图标文件为生成物 |
| Browser | 1 | BrowserTab、WKWebView 的持有与复用、导航/弹窗/查找、视图重挂载 |
| Remote | 12 | 交互 SSH、桥接与 passthrough、固定主机 backend、会话转发、长期隧道、远端 UI |
| UI | 14 | 根 View、Dock、Pane、命令面板、混合工具面板、项目列表、共享树行与 chrome |
| Support | 2 | 主 actor 桥与 FPS 生命周期 |

基线共 65 份 Swift：64 份手写实现 + 1 份生成资源。基线的 Files/Info 实现还在 Workspace、Terminal 和混合工具面板中；目录数量不是重构是否完成的证据。

其他自有内容：

- 全部 5 份 `scripts/` 脚本，以及 `shell-integration/zsh/.zshenv`。
- 根 `README.md`、适用 `AGENTS.md`，以及 `docs/` 的全部 13 份文档：导航、产品、开发验证、性能、安全、依赖、本地化、设置、项目、终端、Git、编辑器、浏览器。
- 当前 Feature 的 idea、五份分阶段计划和 todo；工程文件、scheme、workspace、包解析锁定、Info.plist、entitlements、忽略规则与子模块声明。
- 生成图标的运行代码和生成脚本逐段阅读；四份完整映射表自动检查语法、重复键及 SVG/light 资源存在性。没有把生成数据和图片伪称为逐行手工代码审查。
- 十份本地化目录与三份资产目录做完整 JSON/结构检查；这不是逐条翻译质量或视觉验收。

### 外部实现只沿实际契约深入

沿 Kero 的调用追入当前使用的 GhosttyKit：surface 创建/释放、detach/reparent、可见性、输入、剪贴板确认和屏幕导出。五份相关活跃源码与对应上游副本逐文件比较一致；同时核对依赖包声明、补丁来源和导出临时文件补丁。

STTextView 核对本项目实际适配与三份补丁文件中的行号、横向宽度、递归尺寸更新、短文档点击区域、空高亮范围边界。TreeSitterTSX 核对包装与解析器/查询的来源契约。

没有声称人工通读全部 Vendor、生成 C grammar、二进制框架或每张 SVG。它们不是本次修改范围；真实调用依赖的外部行为没有在仓库边界提前停止。SwiftUI 状态寿命另外核对了 [Apple 的 StateObject 契约](https://developer.apple.com/documentation/swiftui/stateobject)：输入改变不等于身份改变，身份改变才会重置所持有的状态。

## 必须修正的遗漏

### 1. Info 可以把旧机器的 PID 交给新 backend

源码：`kero/Terminal/SessionInfoModel.swift:68`、`kero/Terminal/SessionInfoModel.swift:98`、`kero/Terminal/SessionInfoModel.swift:124`。

`sync` 先替换 backend/机器信息；刷新在进行时直接返回，旧行暂时保留。异步结果只比较 shellPid，不区分机器；kill 又使用当前 backend。A、B 两个目标具有相同 PID 时，旧结果可发布，旧行操作也可能发给 B。

修订：[P2-T5](plan-p2.md#p2-t5)。目标改变时让旧操作行失效；请求和延迟菜单动作捕获各自原目标，模型在回写/实际 kill 入口核对，不只靠清空数组。进程目标不随无关目录变化失效；沿现有刷新合并方式保证最后一个目标仍会刷新。不是给每次 await 或每个按钮叠加检查，更不增加全局安全框架。

必须验证延迟返回、同 PID 跨机器、旧菜单在新目标已有同 PID 行后仍不能发 kill，以及最后一次刷新确实完成。

### 2. 根目录的异步身份不完整，且两处选择逻辑可能读到不同项目

源码：`kero/UI/ContentView.swift:107`、`kero/UI/Panels/ToolPanelView.swift:350`、`kero/Workspace/Project.swift:183`。

根 View 在解析 root 后只比较项目 ID；工具面板的 epoch 包含连接，却没有覆盖 cwd/foreground，并在判断时读取 manager 当前项目。机器 scope 也不能区别同一主机的不同交互连接。

修订：[P2-T5](plan-p2.md#p2-t5)。在已有 Project 目标选择处统一请求身份，而不是在两个 View 拼两份字符串或新建 Coordinator。只纳入该分支实际使用的输入：固定目录不随无关终端 cd/SSH 改变而失效；自动跟随才绑定 cwd、foreground、会话和连接。

保留已有 FileTreeModel 的 root/scope 回写判断、Git 的请求代次及 PanelSyncQueue；它们保护不同职责，不是重复围栏。

### 3. File/Diff 构造把明确的本机身份误当成“没传”

源码：`kero/Editor/FileViewerView.swift:80`、`kero/Git/DiffViewerView.swift:144`、`kero/Workspace/Project.swift:169`、`kero/Terminal/TerminalManager.swift:1049`。

固定本机目录的项目可以有正在 SSH 的上下文终端。Project 已经传入本机 backend 和 nil 机器身份，两种构造函数却用 `?? session.workspaceIdentity` 回退成远端身份。随后标签复用、只读/重绑定和快照过滤都依赖这个错误值。

修订：[P3-T5](plan-p3.md#p3-t5)。唯一创建者 Project 明确传 backend 和可选身份；删除构造函数的默认、optional backend 和 session 回退，不在复用、保存和快照处分别补丁。PaneTab 的 contextSession 仍用于面板上下文，不代表文件所在机器。

验收不能止于编译：固定本机目录 + SSH 上下文下的 File/Diff 必须仍属于本机、可复用、可保存恢复；远端断线不误写本机，重连可重新绑定。

### 4. Files 和命令面板还有最终操作目标的遗漏

源码：`kero/UI/Panels/ToolPanelView.swift` 的创建完成回调与远端删除 modal；`kero/UI/CommandPaletteView.swift:156`、`kero/UI/CommandPaletteView.swift:348`。

文件模型已捕获 backend/root/scope，但创建完成后的 openFile 通过 manager 当前项目执行；删除确认后也可能使用已经改变的面板目标。命令面板始终用本机 Git/FileManager 索引，却未排除远端目标；任务只按 root 字符串识别，结果再交给当前项目打开。

修订：[P2-T5](plan-p2.md#p2-t5)。补齐进入删除操作和应用创建后续打开动作的两个真实边界；重命名回调已捕获 workspace，不重新造管理者。命令面板维持本机索引，绑定项目/目标/root、清除失效文件行，保留普通目录枚举和子模块 fallback；不借重构新增 SSH 搜索。

### 5. 会话转发的记录属于连接，不属于可卸载工具 View

源码：`kero/UI/WorkspaceDockView.swift:461`、`kero/UI/Panels/ToolPanelView.swift:40`、`kero/Remote/PortForwardController.swift:19`。

Dock 通过条件分支挂载工具内容。切换、关闭或跨组重挂载不保证保留这个 View 的身份；View 里的 Registry 会消失，SSH master 的实际转发却不因此结束。同一 TerminalSession 还能替换连接，因此简单按 session 保存也不正确。Info 只是普通可选引用读取 controller，没有直接观察其发布变化。

修订：[P2-T4](plan-p2.md#p2-t4)。RemoteConnection 持有一个现有 controller，controller 弱持有连接；请求临时取得强引用，UI 直接观察同一份端口表。删除旧 Registry，不复制状态或引入应用级注册中心。

源码没有用户取消会话转发的按钮或菜单。删除死取消链，不为验收创造新 UI。临时失联后的记录清空也不证明 master/监听已退出；必须分别记录退出交互 SSH 与网络失联的真实监听结果。

### 6. 连接与缓存 backend 已经有强引用循环

源码：`kero/Remote/RemoteConnection.swift:73`、`kero/Remote/SSHWorkspaceBackend.swift:38`。

RemoteConnection 惰性强持有两个 backend，backend.runner 再强持有同一个连接。仅处理 controller 的反向引用，仍不能恢复连接释放的不变量。

修订：[P2-T4](plan-p2.md#p2-t4)。现有 backend 构造无 I/O，按需返回、由真实使用者持有即可；不新增 weak-runner 协议或缓存容器。保留 liveness 3 秒和普通请求超时；身份比较连接 id，不比较临时 adapter 地址。验证最后一个实际使用者释放后连接可释放。

### 7. Git 提交草稿也不应该归临时 View

源码：`kero/UI/Panels/ToolPanelView.swift:868`、`kero/UI/Panels/ToolPanelView.swift:982`、`kero/UI/Panels/ToolPanelView.swift:1565`。

commitMessage 是 GitPanel 的 @State，面板移除后输入会随身份失去；当前重置又只看仓库路径，没有区分机器。清空成功消息也仍由 View 决定。

修订：[P2-T2](plan-p2.md#p2-t2)。窗口级 GitStatusModel 用已有“按范围保存状态”的简单字典持有草稿，键为机器 scope + 已确认 repoRoot。删除 View 的重复状态；失败保留、用户已改写保留、成功只清空匹配仓库与提交文本。弹窗、过滤、hover 仍属于 View，不把所有状态升格，也不增加磁盘草稿功能。

### 8. 共享组件的消费者范围比原计划更广

源码：`kero/UI/Panels/ToolPanelView.swift:2225`、`kero/UI/Panels/ProjectsPanelView.swift:117`、`kero/UI/Panels/ProjectsPanelView.swift:150`。

GitSectionHeader 同时服务 Git 四处和 Info 四处，不能随 GitPanel 移成 Git 私有定义。ChromeIconButton 由 Projects 与 Dock 共用；FPSBadge 实际仅由 Dock 挂载，却定义在项目列表文件中。ToolPanel 不是这两个类型的消费者，不能扩大事实范围。

修订：[P2-T1](plan-p2.md#p2-t1) 把真实共享标题改为 PanelSectionHeader，连同 Action、折叠/帮助/无障碍整体归公共面板；[P3-T7](plan-p3.md#p3-t7) 用一份 WorkspaceChrome 承载现有通用 chrome。没有新增组件体系，也不保留旧名 alias。Files 的文件级 shellQuote 必须随实际消费者迁移，不能漏在混合文件末尾。

### 9. Git 执行不能只改入口、留下第二份进程实现

源码：`kero/Git/GitStatusModel.swift:961`、`kero/Git/GitStatusModel.swift:1138`、`kero/Git/DiffViewerView.swift:495`。

两处本地 Process/双管道/超时实现基本重复。Diff 的原始 bytes 和 stdout 上限是真实差异，但不要求两套 runner；直接换成无限字符串结果则会破坏二进制和大小判定。

修订：[P4-T1](plan-p4.md#p4-t1)。唯一 Git 专用 Data 执行实现，可选 stdout 捕获上限；文本入口只解码，远端仍使用现有 backend。达到上限后继续排空管道，保留 QoS、环境、超时/退出码和部分输出。SSH 当前先收完整输出，不把这次整理描述成新增远端流式上限。

新增回归沿用现有轻量脚本；启动失败可用不存在的 cwd 实测，不为了测试增加可执行路径注入或通用进程框架。

## 同任务清理清单

这张表是已核实删除对象的说明，不是第二份执行状态；执行状态仍只在 todo.toml。

| 责任任务 | 即时删除或收敛 | 必须保留的区别 |
| --- | --- | --- |
| [P1-T2/T3](plan-p1.md#p1-t2) | 迁移后的旧树/行/文件树路径、重复定义和旧编译命令 | 树原本已共享；项目仍持有文件树模型，不重造统一树 |
| [P2-T1/T2/T3](plan-p2.md#p2-t1) | ToolPanel 中迁出的整组旧定义、旧 GitSectionHeader 名称、Git 草稿重复状态 | ToolPanel 的渲染选择/必要刷新触发、Git 确认 UI 和共享行组件 |
| [P2-T2](plan-p2.md#p2-t2) | Git 的三个无消费者 rowID 属性、Operation.isSuccess、恒真 loadedDetails 字段/赋值/条件包装；不拖到 P4 | 真正使用的树行 ID、操作结果与 repository snapshot 状态更新 |
| [P2-T4](plan-p2.md#p2-t4) | PortForwardRegistry；controller.cancel/cancelAll → RemoteConnection.cancelForward；RemoteCommands.freeLocalPort/forwardSpec/forwardArguments/cancelForwardArguments 的死链 | 真正被会话转发和长期隧道使用的 isLocalPortFree；实际调用的 TunnelStore.runSelfCheck |
| [P2-T4](plan-p2.md#p2-t4) | 从未调用的 RemoteCommands.runSelfCheck App 测试体与淘汰 API 断言；有效断言转为可运行脚本 | 现行 SSH 参数、转义、IPv4/IPv6 与 wildcard 端口占用检查 |
| [P3-T1](plan-p3.md#p3-t1) | legacyDefaults、旧 font-thicken TOML 键、未来 API 复用布局的推测 | 现行默认/类型校验、原子写失败处理、保存时保留磁盘手工 workspace 修改；语言/Diff 偏好不是旧字体迁移 |
| [P3-T2](plan-p3.md#p3-t2) | ColumnSnapshot、旧单内容/列式 decoder、layout/stack 转换、PaneSnapshot.weight、顶层单窗口 fallback、旧兼容说明 | 当前 windows 内仍用 SessionSnapshot；当前 optional 字段有真实含义；Dock 引用过滤和焦点/上下文索引校验 |
| [P3-T3/T4](plan-p3.md#p3-t3) | 旧源码路径；错误的 Diff 挂载/分屏说明；refreshAllAppearances、processArguments 与旧 CLI/Agent/socket 注释 | 真实 cwd/可执行路径查询、窗口/会话 registry、PTY 和通知/SSH 寻址 |
| [P3-T5](plan-p3.md#p3-t5) | WorkspaceBackend 内迁出的实现；导航脚本的三个跨域桩；File/Diff 构造回退；未实例化 ProcessRemoteCommandRunner 的协议/实例层；无调用 argv/cwd run 重载及独占转义 helper | 活跃 RemoteCommandRunner 两实现、静态进程执行、机器身份、真实协议 run/信任/错误映射 |
| [P3-T6/T7](plan-p3.md#p3-t6) | 根 View 旧 toolbar/chrome；不可达空会话 UI 及其两条唯一文案；临时 logScroller/KERO_SCROLLER_DEBUG | 无项目入口、真实滚动重算与选区恢复、FPS 可见时启停、既有按钮/标签语义 |
| [P4-T1](plan-p4.md#p4-t1) | 两份 runner 合并后的旧 API/重复 PipeData、不可达 remoteTextLineCount fallback；不为死消费者设计迁移接口 | 远端批次/体积预算/路径去重、Diff 字节上限 |

上述死链已结合完整调用方与控制流核对，不只凭零搜索结果下结论。对相同名字的其他活跃行为，不连带删除。

## 删掉的过度安排与错误前提

- 不在 P1 重做一遍全仓研究或搭基线框架；源码/工具链变化时才重跑相关检查。
- 不为 Browser/Editor 大文件机械拆模块；已有内聚逻辑保留。不因协议只有一个实现就删除真实框架边界。
- 生成 MaterialFileIconView 已被十处生产 UI 复用，生成脚本是唯一来源；保留既有生成路径，不再包一层 IconProvider。原生命中脚本的图标桩有明确测试用途，不与导航脚本的三个淘汰跨域桩混删。
- 不新增 SSH 文件搜索、会话转发取消 UI、Diff 内层分屏、API/插件、配置驱动或依赖注入框架。
- 不把所有可选快照字段改成必填；删除的是旧格式路径，不是当前“自动名称/无固定目录/不恢复历史”等合法状态。
- 不把 UI 确认指纹与真正执行前仓库/HEAD 核对合并：它们发生在不同时间。SSH 信任、文件保存失败保留内容、临时导出路径约束和剪贴板请求寿命同样不能误删。
- Xcode 当前是单一 App Target，kero 下文件系统同步接入，只有 Info.plist 排除；不为每次移动手写工程文件列表。
- `--isolated-ui-test` 只隔离快照/历史并跳过长期隧道启动；设置、语言和 Diff 偏好仍共享。隔离验收不能修改用户设置/隧道，也不能清空 build 或用户已有隔离数据。
- 每个 Phase 完成即审计，再推进下一个；不是 P5 结束才集中生成审计文件。

## 本次实际验证

现有三个检查均在审查源码基线上重新编译后运行，而非引用过去的 PASS。下面是当时实际使用的路径，不是并行迁移后应重放的最新命令；最新编译路径以责任任务同步更新的 CONTRIBUTING 和脚本为准：

```sh
xcrun swiftc -swift-version 5 -o build/check-dock-workspace kero/Workspace/DockWorkspaceModel.swift scripts/check-dock-workspace.swift
build/check-dock-workspace

xcrun swiftc -swift-version 5 -o build/check-file-tree-navigation kero/Workspace/WorkspaceBackend.swift kero/Workspace/TreeDisplayModel.swift kero/Workspace/FileTreeModel.swift scripts/check-file-tree-navigation.swift
build/check-file-tree-navigation

xcrun swiftc -swift-version 5 -o build/check-tree-row-hit-testing kero/Workspace/TreeDisplayModel.swift kero/UI/Panels/TreeRowStyle.swift scripts/check-tree-row-hit-testing.swift
build/check-tree-row-hit-testing
```

实际通过范围：

- Dock：统一分组、分屏、标签顺序、快照和工具恢复。
- 文件树：Files/Git 压缩与状态、分区隔离、排序、创建草稿、叶子重命名、不可读根、符号链接边界、10,000 文件。
- 原生命中：Files/Git/提交历史行的缩进、上下边缘和尾部区域，两档字体；附件按钮命中不串行。
- 生成映射：28 个 light 名、1,346 个文件名、143 个完整路径文件名、1,003 个扩展名；328 个 SVG（300 个基础 + 28 个 light）引用检查通过。
- 数据结构：10 份本地化目录、518 个键、en/zh-Hans；三份资产目录可解析，Info.plist 与 entitlements lint 通过。
- Process 失败可测试性：不存在的 cwd 确实使 Process.run 抛错，没有新增任何生产注入参数。
- 文档快照校验：22 份 Markdown、128 个本地链接、31 个标题锚点和 26 个源码位置通过；不把这个结果套用到随后正在变动的工作区。
- todo.toml 校验通过；审查过程中曾核对 18 个任务全部 pending。本次没有写执行状态，收尾的并行执行已改变状态，因此不再断言实时 todo 仍全 pending。

当前用户快照仅只读核对结构：windows 顶层、现行 layout、所有项目具备 dock、无旧 columns；配置文件可读。未输出私人路径/历史内容，也未做修改。这不是当前 Codable 往返或 App 恢复已通过的证明。

本次审查没有构建/安装/替换 App，没有退出用户终端、操作用户 Git/文件、创建 SSH 转发或修改设置。新增回归脚本、真实保存恢复、转发监听与完整 App/SSH 验收属于责任任务，本次没有执行；其他执行流的验证不并入这份报告。

更新后的计划以这些具体不变量为验收条件；不能把“计划改好了”“编译成功”或“请求已发出”当作重构完成。

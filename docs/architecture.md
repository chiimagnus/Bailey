# 架构

本页负责 Bailey 的分层、装配、状态所有权和目录边界。所有者、依赖方向或文件归属改变时同步更新；功能内部契约见[功能文档](README.md#功能文档)，编码约定见 [standards.md](standards.md)。

## 平台范围

当前开发与验收只面向 Apple Silicon、macOS 15.6 及以后版本，先保证桌面工作区的正确性、交互与可维护性。iOS、iPadOS 与 visionOS 暂缓；重新启动需明确产品目标、执行后端和验收环境，不因历史讨论自动纳入当前重构。

保留 SwiftUI `App`／`Scene`／`WindowGroup` 与 AppKit、TextKit、Ghostty、WebKit 的现有分工。`NSWindow` 和原生输入桥接不是需要消灭的架构缺陷；只收拢职责，不为未开发的平台增加协议、条件编译、窗口包装、依赖或备用实现。

## 分层

Bailey 自有 SwiftUI 状态采用 **MVVM + Observation**。分层是职责，不是强制把全仓拆成 `Models/`、`Views/`、`ViewModels/` 三个目录。

| 层次 | 拥有什么 | 不应承担什么 |
| --- | --- | --- |
| Model | 领域值、身份、不变量与纯转换 | SwiftUI/AppKit/Combine、界面操作或文件与网络 IO |
| ViewModel | 可观察展示状态、用户动作、业务编排与异步任务 | 构建 View、弹原生对话框或直接执行底层 IO |
| View | 布局、显示、绑定、焦点、临时输入与交互转发 | 业务规则、Git 命令或文件与网络访问 |
| Service / Backend | 文件、Git、SSH、持久化及系统副作用 | 复制展示状态、决定无关窗口的交互 |

依赖通常为 `View → ViewModel → Service → Model`，各层可以读取纯 Model。环境事实由拥有者传入；耗时效果通过后端执行。`WorkspaceBackend` 是本机与 SSH 的真实多实现边界，协议用于这种实际替换或测试边界，不为每个具体类型制造接口。

## 模块化与依赖

模块是有明确职责、状态所有者和协作入口的业务边界，**不是 Manager、Coordinator、Protocol、文件或 Swift Package 的数量**。MVVM 只描述层次，不能替代领域依赖约束。以下是改动必须守住的方向，**不是声称现有代码已经达成**。

- **领域内聚**：Files、Git、Editor、Terminal、Browser 与 Remote 各自维护内部规则和效果。跨领域只传完成当前动作所需的身份、数据或回调，不依赖对方的私有控件结构。
- **装配与调用分开**：App／窗口入口创建并连接协作者；业务动作通过明确入口调用所属领域。协调者可以转发动作、组织保存和关闭流程，但不吸收目录导航、文本编辑、Git 命令或具体控件识别规则。
- **生命周期分开**：应用级负责跨窗口注册、外部请求路由、整体恢复和退出协调；窗口级负责自己的项目集合、选择及动作上下文；项目负责标签与 Dock；内容负责文档、网页或会话。应用级可汇集各窗口结果，但不建立第二份可写项目或内容状态。
- **规则只有一个所有者**：在拥有失效不变量的最小公共位置维护规则。跨组件明确传递“浏览、展开、打开、激活、聚焦、恢复”等必要意图，不能让下游根据 selected、hover 或窗口标题猜测。列表游标、目录展开、文档选区等局部状态不为集中管理而上收。
- **原生细节留在呈现边界**：控件适配可以处理 AppKit 响应者、field editor、挂载及可见性；工作区策略只使用其报告的身份、能力和结果，不逐个识别控件类或依赖屏幕几何猜测业务归属。拖放命中和原生输入协议确需的几何保留在原职责内。
- **依赖按需暴露**：优先现有类型、方法、值和闭包；只在真实多实现或替换边界使用协议。不要以模块化为由新增服务定位器、全局事件总线、万能上下文、镜像状态或一层层只转发的 Manager。

拆分前后必须说清：**原状态真源 → 新的唯一所有者 → 被删除的反向依赖／重复决策 → 最终用户结果**。如果只是拆 extension、搬目录、换名字或新增一层只转发的协议／协调者，却没有减少依赖和状态重复，就不是职责重构。Zed 的 GPUI、Entity 和多 Crate 是另一套运行时实现；Bailey 复用 SwiftUI Observation、AppKit、现有 Dock/Tab 与后端，不机械移植。

## 唯一所有者

| 生命周期 | 当前所有者 | 必须保持的边界 |
| --- | --- | --- |
| 应用 | `baileyApp`、`BaileyApplicationDelegate` 与现有应用级服务 | 启动装配和退出协调不复制成另一套容器 |
| 窗口 | `WindowRootView` 持有 `TerminalManager` | 每个窗口有自己的管理者；菜单不能操作后台窗口 |
| Git 面板展示 | `ContentView` 持有 `GitStatusModel` | 跟随当前项目与机器身份，不因一次失败丢弃有效展示 |
| 项目 | `Project` | 持有标签、文件树和停靠状态；视图重建不更换项目 |
| 标签内容 | `PaneTab` 及其 `TerminalSession`、`FileTab`、`DiffTab`、`BrowserTab` | 每个标签只有一份内容，原生对象随内容生存 |
| 设置与主题 | `AppSettings`、`Theme` | 现有应用级共享状态仍是唯一来源，不再缓存另一份偏好 |
| 长期隧道 | `TunnelManager` | 独立于某个终端或浏览器标签 |

表中类型是当前实现，不是禁止调整的永久名称。`Project`、`TerminalManager` 等名称不代表纯 Model；命名按 [standards.md](standards.md#职责与命名) 随真实职责更新，不另建并行状态容器。

**现状：** `TerminalManager` 实例持有单窗口项目与动作，又通过静态状态承担跨窗口注册、外部请求和快照汇集，还含命令面板的原生焦点恢复；这些职责尚未分离。`Project.syncFiles(in:)`、`GitStatusModel.syncSelectedProject(in:)` 目前还反向读取整个窗口管理对象。

**目标（未实施）：** 应用／delegate 装配一份应用级窗口登记和路由所有者；每个 `WindowRootView` 保留一个窗口级 `WorkspaceWindowModel`；`Project`／`DockNode`／`PaneTab` 继续分别拥有项目布局与真实内容。项目、Files、Git 只接收实际需要的项目身份、后端及当前目标校验，不依赖整个窗口或全局可遍历窗口表。窗口模型的名称改变必须与应用级职责真实迁移一致，不能靠 alias 保留旧双轨；实施步骤只在 [.github/features/workspace-focus-refactor](../.github/features/workspace-focus-refactor/idea.md) 维护。

## 入口与数据流

`baileyApp` 声明主 `WindowGroup` 和设置场景。`WindowRootView` 用 `@State` 持有窗口管理者，将它交给 `ContentView`，并通过 `.focusedSceneValue(\.baileyManager, manager)` 提供当前窗口上下文；菜单由 `@FocusedValue` 读取。

用户动作先表达**必要的目标与意图**，由对应所有者执行业务操作、窗口交接或局部输入；不是把可观察状态变化当作操作命令。领域动作经所属 Model／ViewModel 到达本机或 SSH 后端。异步结果回写前再次核对项目、机器、连接、路径与请求代次；失败留在原目标，不回退到本机同名路径。最终文件字节、Git index/HEAD、原生视图内容或真实第一响应者才是结果，不以事件派发替代。

## 焦点协调边界

焦点策略按窗口协调，不能由全 App 单例接管。协调的是输入交接，不是全部交互状态；新边界接通时必须同时移除被替代的决策路径。

| 责任 | 应持有的事实与动作 | 不应承担 |
| --- | --- | --- |
| 工作区 | 项目、Dock 活动组、各组展示内容及显式打开／仅浏览意图 | 复制原生输入状态，因展示变化无条件抢焦点 |
| 窗口焦点协调 | 根据所属窗口、目标有效性和临时输入决定交接、取消及恢复 | 拥有列表游标、编辑器选区、另一份活动组或原生内容 |
| 功能组件与原生适配 | 声明目标身份，报告挂载与实际焦点，执行聚焦并返回结果 | 重复窗口级许可与恢复策略，识别其它功能的内部控件 |

### 状态独立，动作明确

**展开 ≠ 选中 ≠ 悬停 ≠ 展示 ≠ 激活 ≠ 焦点。** 这是状态与所有权的区别，**不是禁止一次明确动作同时改变多个状态**。例如用户点击文件树目录可同时展开并把键盘交给树；但仅改变展示的 Diff 不能由此擅自聚焦另一个组。保持 Bailey 已有交互语义，不照抄其它 IDE 的单击／双击行为。

| 事实或意图 | 唯一真源／归属 | 不能误认为 |
| --- | --- | --- |
| 目录／图谱展开 | Files／Git 对应数据或局部展示状态 | 行选中或键盘焦点 |
| 行选中与悬停 | 各列表游标；Hover 为视图短暂状态 | 已打开文件、当前命令目标 |
| 哪个内容正在展示 | `DockGroup.selected`；每组独立 | 活动组或输入目标 |
| 活动组／最近工作标签 | `DockWorkspaceModel.activeGroupID`／`Project.selectedTabID` | 当前原生第一响应者 |
| 浏览／打开／激活意图 | 当前用户动作和显式调用参数 | 仅凭选中或展示变化自动推导的行为 |
| 当前接收键盘 | 前台 key window 的 `firstResponder` 与原生控件实际输入反馈 | 后台窗口残留的 responder、`Project.focusedContent` 或视觉描边 |

`Project.focusedContent` 用活动组选择**命令作用的工作内容**，不是直接观察原生键盘焦点。查找栏或 Palette 可以暂时持有输入，而不改变活动组；局部行游标、当前已打开文件灰底、Hover 和焦点描边允许并存，但分别绘制。

目标只携带当前交接实际需要的身份，复用已有项目、Dock 组和内容 ID；工具没有工作标签时不强造内容 ID。Git Changes／Graph、浏览器地址／正文的内部选择留在各自适配中，不要求全窗口统一输入角色枚举或为每个文本框登记目标。不以全局路径或裸 `NSView` 指针代替业务归属。

集中管理的仅是**跨组件**工作区自动聚焦许可、显式交接和被打断内容的恢复，不是每个输入控件的焦点状态。局部 `@FocusState`、原生 `NSTextFinder`、行内编辑提交／取消、浏览器地址／网页、Git Changes／Graph、弹窗初始响应者仍由所属组件或 AppKit 管理；窗口只能接收避免底层抢焦点所需的身份、挂载与实际结果。Settings、Sheet 和 `NSPopover` 自己维护原生输入生命周期，不建立工作区焦点栈。

自动请求只作用于当前前台 key window 的有效可见目标；临时输入（即使原生 field editor 尚未就绪）接管时，底层不能抢回。延迟执行、取消恢复和重挂载后的真正聚焦前，重新确认请求仍属于当前窗口与目标；关闭、隐藏、停车、切项目或更新的交接使旧请求失效。组件报告原生挂载、实际响应者和最终结果，**已请求 ≠ 已获得**；不要用无理由的定时轮询掩盖归属错误，也不能为消除轮询而删除真实的 AppKit 挂载顺序。菜单、Sheet 和弹窗的有效原生生命周期检查必须保留。

当前决策仍分布在 `WorkspaceDockView`、`TerminalManager` 与各内容／工具组件；以上是重构目标。具体单击、双击、临时输入和恢复行为由 [dock.md](features/dock.md)、[command-palette.md](features/command-palette.md) 与各功能页维护，不能借职责迁移改变交互。

## 原生表面与生命周期

SwiftUI 负责外层布局，Ghostty 负责终端，WebKit 只负责浏览器，Apple NSTextView/TextKit 2 负责文件和 Diff。标签内容拥有相应原生对象；切换项目、停靠、重挂载只移动它们，不重建 Shell、WebView、编辑器或撤销栈。

`DockNode` 是外层布局真源。一个标签不再拥有第二套分屏。窗口关闭、项目关闭和应用退出都要先处理未保存内容；视图的临时消失不能成为结束后台任务的理由。详见 [dock](features/dock.md) 与 [editor](features/editor.md)。

## Observation 与事件

可观察 ViewModel 使用 `@Observable`。由 View 拥有生命周期的对象用 `@State`，需要双向绑定时用 `@Bindable`，只读则直接传入对象；局部输入和动画仍使用局部状态。协作者和不应触发重绘的缓存按实际依赖使用 `@ObservationIgnored`。

**属性观察不是事件总线。** 设置变化、文件自动保存和窗口快照使用当前语义触发，不恢复旧 `objectWillChange` 发布级联。`TunnelManager.$tunnels/$states` 仍供原生 `NSTableView` 刷新，WebKit 的 KVO 仍承担平台桥接；这些必要事件不应为了“全部 Observation”被删除。

新增 `NSHostingView` 或窗口时核对依赖注入和事件订阅的建立、取消。编译成功不能证明注入站点、变化传播和原生效果正确。

## 目录

| 目录 | 负责内容 |
| --- | --- |
| `Bailey/App/` | App、设置、主题与应用入口 |
| `Bailey/Workspace/` | 项目、标签、窗口、布局和工作区后端 |
| `Bailey/Files/`、`Editor/`、`Git/`、`Terminal/`、`Browser/`、`Remote/` | 各业务领域的状态、效果及界面 |
| `Bailey/UI/` | 窗口布局、面板外壳和共享交互组件 |
| `Bailey/Shared/` | 跨功能共享表达，包括 Files/Git 共用树 |
| `Bailey/Resources/` | 本地化、字体、图标与应用资源 |
| `BaileyTests/` | 测试层次 → 业务功能；仍为一个 XCTest 目标 |
| `scripts/`、`shell-integration/` | 资源生成和 Shell 集成 |
| `Vendor/` | 确实需要随仓库维护的第三方源码 |

领域内按真实复杂度细分职责；小功能保持扁平。不为目录整齐拆 Xcode target、增加内部 SwiftPM 包或搬迁无关文件。测试目录的实际规则见 [testing.md](testing.md#测试目录与入口)。

只有明确的独立复用、依赖隔离或有测量支持的构建收益，才另行评估编译模块。当前职责重构沿用既有 Xcode 工程和 XCTest 目标，不预建跨平台包。

## 重构规则

沿**真实入口 → 状态真源 → 明确动作意图 → 目标所有者 → 原生或数据最终副作用**逐段迁移。每段独立完成接入、回归、文档同步及旧策略删除；不能先新建全局焦点协调器、长期并行新旧实现，或把所有组件堆在一个不可独立验收的任务。新增类型／状态／协议必须指出它取代了什么、减少了哪条依赖、为什么现有结构不够；没有证据就不引入。

纯架构重构不得改变 UI/UX。同一环境下对照布局、样式、动效、文案、点击、拖拽、键盘、焦点、滚动及无障碍；原有交互缺陷另案处理。验证方法见 [testing.md](testing.md)，视觉约束见 [ui.md](ui.md)。

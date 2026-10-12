# Kero 全面现代化重构：SwiftUI + Observation + MVVM

## 为什么做

Kero 已决定以 **MVVM + Observation** 为长期架构，但现有代码仍主要依赖 `ObservableObject`、`@Published`、Combine 和多层 `objectWillChange` 转发；部分 SwiftUI View 还负责异步业务编排、Git／文件操作和目标校验。状态所有权、界面刷新、持久化触发与系统桥接相互交织，使维护、测试和后续迭代成本偏高。

本次允许**跨模块、大规模重构**。目标不是给旧类改名、机械替换属性包装器或只调整目录，而是在保持产品行为的前提下，让整个 Kero 真正使用现代 SwiftUI 数据流、Observation、清晰的 MVVM 职责，以及适用的现代 Swift 并发／系统 API。完整迁移所需的工作量不作为主动缩减需求的理由。

## 目标架构与技术选择

1. **MVVM 职责真正分离**
   - **Model**：领域数据、身份与纯逻辑，不依赖 UI 或副作用框架。
   - **ViewModel**：唯一持有相应展示状态，编排用户动作、异步任务及错误／取消状态；对 View 提供可直接消费的状态和操作。
   - **View**：使用 SwiftUI 声明式渲染、绑定、焦点与交互转发；不再直接实现 Git／文件／SSH 命令、持久化、后台索引等业务流程。
   - **Service／系统适配层**：承载文件、Git、SSH、配置、持久化与原生框架副作用。复用当前真实的 `WorkspaceBackend` 等抽象，避免新建与已有 Service 平行的通道。
   - App／窗口入口负责依赖装配和生命周期；不为每个 View 强制制造空壳 ViewModel、协议、Repository 或依赖注入容器。

2. **Observation 成为界面状态的默认机制**
   - Kero 自有可观察 ViewModel 优先 `@Observable`，视图按所有权使用 `@State`、按需 `@Bindable`、直接对象读取及现有适合的环境注入。
   - 逐步移除自有 UI 状态链上的 `ObservableObject`、`@Published`、`@StateObject`、`@ObservedObject` 和为刷新 UI 人工层层转发的 `objectWillChange`。
   - **Observation 不是 Combine Publisher 的等价替身**。对自动保存、主题传播、对象嵌套变化、系统通知等，逐条追踪原事件语义并建立明确触发机制；只有确需事件流、节流、合并或第三方桥接时保留 Combine，不创建双套可写状态。
   - 迁移窗口菜单的焦点／命令路由，避免移除 `@FocusedObject` 后菜单指向错误窗口或失去可用状态。

3. **现代 Swift、并发与系统 API**
   - 以现有 Xcode／Swift 工具链支持且 **macOS 15.6+** 可用的 API 为准，优先使用原生 SwiftUI／Foundation／Swift Concurrency 实现，减少不必要的 AppKit UI、GCD 调度、旧式回调和兼容包装。
   - **以升级 Swift 6 语言模式、满足严格并发检查为目标**：梳理 `MainActor` 所有权、异步后端、跨 actor 传值、取消及 `Sendable`；不靠 `nonisolated(unsafe)` 或随意 `@unchecked Sendable` 压制诊断。第三方框架或编译器造成的限制须先用实际编译／最小实验确认，再决定边界，而不是预先放弃。
   - 原生 `Scene`、`Commands`、数据流、焦点、布局、控件及现代格式化／日志等 API 可在语义等价时更新；不得为追求“新”而改变交互或引入更多抽象。
   - 仍应使用 AppKit／Ghostty／WebKit／TextKit 处理 SwiftUI 无法等价覆盖的终端、编辑器、网页、原生焦点与输入；现代化不等于强行以纯 SwiftUI 重写这些能力。

4. **只保留一套真正运行的实现**
   - 每个状态有唯一拥有者，依赖方向明确；移走业务逻辑时同时改动调用方，删除被替代的事件转发、重复状态、旧入口和无消费者代码。
   - 允许按实际职责重组文件／类型，不为文件行数拆分，也不为目录外观增加空层。
   - 采用现有单一 Xcode App Target、`Makefile`、原生 XCTest 与已有本地／SSH 后端；不以现代化为由引入 SwiftData、额外 SwiftPM target、第三方状态框架或新测试体系。

## 已确认的当前边界

- **应用与窗口**：`kero/App/keroApp.swift` 的窗口根视图用 `@StateObject` 创建 `TerminalManager`，菜单借 `focusedSceneObject`／`@FocusedObject` 读取焦点窗口；多个窗口的恢复、关闭及动作路由有跨层耦合。
- **项目、标签与自动保存**：`TerminalManager → Project → PaneTab` 通过 Combine 与 `objectWillChange` 转发变化；`TerminalManager` 还使用防抖订阅调用 `SessionStore.save`。这是 Observation 迁移必须真实替代的行为链，而不只是界面刷新。
- **界面与业务混合**：`ContentView` 负责 Git 范围同步；`GitPanel` 包含文件指纹／远端丢弃准备；`CommandPaletteView` 直接索引文件、调用 Git 命令。应在重构阶段核对各自最终归属，保持原有目标校验和失败处理。
- **长生命周期的原生内容**：`TerminalSession`、`BrowserTab`、`FileTab`、`DiffTab` 及原生表面不能随 SwiftUI View 重建；`DockNode` 是外层布局真源，`PaneTab` 只有一个内容，**已不支持标签内部再分屏**。
- **现有技术配置**：当前最低 macOS 版本为 15.6，Xcode 工程的应用 Swift 语言模式仍为 5，已启用默认 `MainActor` 隔离及 Approachable Concurrency；本机工具链支持更现代 Swift。是否能完整切换严格 Swift 6 模式，要由后续实际构建验证。
- **历史文档**：旧 `modular-architecture` 计划涉及已废弃的标签内分屏与其它旧结构，不作为本次源码事实；以当前 `AGENTS.md`、各 `docs/` 契约和可运行源码为准。

## 必须保留的产品与数据行为

- **项目／窗口／标签**：多窗口、本机与 SSH 项目、唯一标签内容、外层自由停靠、标签拖动、选择与焦点、快捷键和菜单路由保持一致。移动与切换不能重建 Shell、WebView 或编辑器，也不能终止仍在执行的任务。
- **文件与 Git**：Files／Git／提交历史继续共用树与行交互；目录压缩、状态颜色、键盘／无障碍、Git 刷新、暂存、提交、diff、文件编辑与保存语义不退化。
- **远程与异步安全**：保留机器／连接／仓库／请求身份；旧异步结果不能覆盖新目标，远端失败绝不回退写入本机；继续遵守真实 SSH 命令批处理、超时及安全确认。
- **状态与恢复**：现行配置、窗口快照、项目布局、选中项、可恢复编辑器状态、终端历史、语言／主题／字体与隧道设置仍按当前契约读取和保存。不能为了改观察方式丢失数据、漏触发自动保存或重建时写入不完整快照；本次不擅自清理用户旧数据或更换存储键。
- **性能与交互**：重构不能引入全局无差别重绘、主线程 IO、重复请求、内存无法释放或焦点闪烁；无性能实测不宣称提速。保留 macOS 原生行为与英语／简体中文支持。

## 非目标

- 不新增与重构无关的产品功能、菜单、设置、窗口模式或远程协议。
- 不为了使用“最新 API”提高最低 macOS 版本、替换有必要的原生渲染内核，或无条件迁移到 SwiftData／Swift Testing。
- 不改变唯一应用身份、签名／发布流程、当前数据格式，亦不创建新的 App 变体或额外安装备份。
- 不在 idea 阶段实现任何源码改动、替换／重启正式 App、删除用户数据、发布或推送。

## 完成后的验收标准

1. **架构可审查**：主要窗口、项目、Dock、终端、文件、Git／diff、浏览器、SSH、设置及持久化路径均符合 MVVM 职责；SwiftUI View 不再直接承担业务 IO；不存在两套并行的状态真源、空壳转发层或无用兼容实现。
2. **Observation 真正生效**：Kero 自有 UI 状态以 Observation 为主；新旧状态链已收敛，未迁移的 Combine／ObservableObject 必须有具体、可验证的系统边界理由。嵌套状态变化、跨窗口菜单、编辑脏标记、Git 刷新、主题变更和自动保存都能正确传播。
3. **Swift 现代化可验证**：检查 Swift 6 语言模式与严格并发目标的真实编译结果；能迁移的旧 API／调度被替代，不能迁移的依赖限制有明确证据，不用不安全标注伪造通过。
4. **数据与生命周期无回归**：当前快照写入／读取、多窗口恢复、无损编辑与失败保存、终端进程和网页状态在重挂载中的保留、跨机器隔离、Git 写操作及转发行为均有针对性验证。
5. **测试覆盖真实结果**：按阶段扩展或调整现有 XCTest，既断言状态，也验证真实副作用；最终完成 Debug／Release 构建与签名核验，并使用隔离 Debug 实例做原生交互验收。真实 SSH 只使用获授权的专用连接；无法覆盖的路径诚实列明。
6. **代码与文档一次收敛**：迁移每块职责时立即删除其旧路径，及时更新相关 `docs/` 和 `AGENTS.md`；最终不存在一边维护 Observation、一边靠旧 Combine 状态链维持同一功能的双轨实现。

## 后续计划的边界

本文件只确定**需求、架构目标、不可破坏的行为和验收要求**。实施拆分、源码锚点、验证步骤与各 Task 的即时旧代码清理见同目录 `plan-pX.md`；实时任务状态由 `todo.toml` 唯一维护。全面迁移前先核对 Swift 6 与 Observation 的实际编译和事件语义，不把假设当成既定实现。

规划文件只决定后续任务与验收；任务实施和 phase 审计必须在进入执行工作流后开展，不能把编写计划视为修改源码、替换正式应用或操作用户数据的授权。

## 技术依据

- [Apple：从 ObservableObject 迁移到 Observation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro)
- [Swift：Swift 6.2 与 Approachable Concurrency](https://www.swift.org/blog/swift-6.2-released/)

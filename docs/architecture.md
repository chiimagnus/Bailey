# 架构

本页负责 Bailey 的分层、装配、状态所有权和目录边界。所有者、依赖方向或文件归属改变时同步更新；功能内部契约见[功能文档](README.md#功能文档)，编码约定见 [standards.md](standards.md)。

## 分层

Bailey 自有 SwiftUI 状态采用 **MVVM + Observation**。分层是职责，不是强制把全仓拆成 `Models/`、`Views/`、`ViewModels/` 三个目录。

| 层次 | 拥有什么 | 不应承担什么 |
| --- | --- | --- |
| Model | 领域值、身份、不变量与纯转换 | SwiftUI/AppKit/Combine、界面操作或文件与网络 IO |
| ViewModel | 可观察展示状态、用户动作、业务编排与异步任务 | 构建 View、弹原生对话框或直接执行底层 IO |
| View | 布局、显示、绑定、焦点、临时输入与交互转发 | 业务规则、Git 命令或文件与网络访问 |
| Service / Backend | 文件、Git、SSH、持久化及系统副作用 | 复制展示状态、决定无关窗口的交互 |

依赖通常为 `View → ViewModel → Service → Model`，各层可以读取纯 Model。环境事实由拥有者传入；耗时效果通过后端执行。`WorkspaceBackend` 是本机与 SSH 的真实多实现边界，协议用于这种实际替换或测试边界，不为每个具体类型制造接口。

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

`Project`、`TerminalManager` 等名称不代表纯 Model。按真实职责判断，不为统一后缀重命名，不为统一名称另建全局状态容器。

## 入口与数据流

`baileyApp` 声明主 `WindowGroup` 和设置场景。`WindowRootView` 用 `@State` 持有窗口管理者，将它交给 `ContentView`，并通过 `.focusedSceneValue(\.baileyManager, manager)` 提供当前窗口上下文；菜单由 `@FocusedValue` 读取。

用户动作经所属 ViewModel 到达本机或 SSH 后端。异步结果回写前再次核对项目、机器、连接、路径与请求代次；失败留在原目标，不回退到本机同名路径。最终文件字节、Git index/HEAD 或原生视图内容才是结果，不以事件派发替代。

## 原生表面与生命周期

SwiftUI 负责外层布局，Ghostty 负责终端，WebKit 只负责浏览器，STTextView/TextKit 负责文件和 Diff。标签内容拥有相应原生对象；切换项目、停靠、重挂载只移动它们，不重建 Shell、WebView、编辑器或撤销栈。

`DockNode` 是外层布局真源。一个标签不再拥有第二套分屏。窗口关闭、项目关闭和应用退出都要先处理未保存内容；视图的临时消失不能成为结束后台任务的理由。详见 [dock](features/dock.md) 与 [editor](features/editor.md)。

## Observation 与事件

可观察 ViewModel 使用 `@Observable`。由 View 拥有生命周期的对象用 `@State`，需要双向绑定时用 `@Bindable`，只读则直接传入对象；局部输入和动画仍使用局部状态。协作者和不应触发重绘的缓存按实际依赖使用 `@ObservationIgnored`。

**属性观察不是事件总线。** 设置变化、文件自动保存和窗口快照使用当前语义触发，不恢复旧 `objectWillChange` 发布级联。`TunnelManager.$tunnels/$states` 由 SwiftUI `@ObservedObject` 订阅以显示端口转发状态；WebKit 的 KVO 仍承担平台桥接。既有 `@Published` 是服务与界面的真实事件边界，不另造一套展示缓存。

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

## 重构规则

沿真实状态与副作用链逐块迁移，每块同时完成接入、回归、受影响文档同步和被替代实现的删除。最终核对全部受影响的自有状态链，不长期保留两套实现。

纯架构重构不得改变 UI/UX。同一环境下对照布局、样式、动效、文案、点击、拖拽、键盘、焦点、滚动及无障碍；原有交互缺陷另案处理。验证方法见 [testing.md](testing.md)，视觉约束见 [ui.md](ui.md)。

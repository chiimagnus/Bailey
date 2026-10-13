# Kero 开发规范

本文件是仓库级 AI 开发入口。用户说明见 [README](README.md)；功能细节由对应 `docs/` 文档维护，不以 `.github/features/` 的历史计划代替当前事实。

## 动手前

- 先读受影响功能的维护文档，沿入口、状态所有者、后端直到实际副作用检查。先执行 `rtk codegraph sync`，再用 `rtk codegraph explore` / `node` 定位；索引不全时核对源码与 XCTest，不凭文件名猜职责。
- 按改动阅读[产品](docs/PRODUCT.md)、[项目与 SSH](docs/PROJECTS.md)、[终端与停靠](docs/TERMINAL.md)、[文件与编辑器](docs/EDITOR.md)、[Git](docs/GIT.md)、[浏览器](docs/BROWSER.md)、[设置与恢复](docs/SETTINGS.md)；横向约束见[性能](docs/PERFORMANCE.md)、[安全](docs/SECURITY.md)、[本地化](docs/LOCALIZATION.md)及[依赖与生成](docs/DEPENDENCIES.md)。
- 优先复用现有实现、修复共享根因。只做获授权的修改；推送、发布及其它破坏性操作须另获授权。本地代码改动通过验证后按[本地安装](docs/RELEASE.md#本地安装)更新 App，不中断当前运行的进程或未保存编辑。

## 架构：MVVM + Observation

**当前自有 SwiftUI 状态以 MVVM + Observation 为主。** `TerminalManager` 负责窗口状态、`Project` 负责项目与标签，两者是现有长生命周期 ViewModel 所有者；Git、文件与 SSH 的实际操作经后端执行。新功能继续按此职责划分，不通过重命名类型、复制状态或引入旧的发布级联实现观察。

- **Model**：表达领域数据、身份、不变量与纯转换；不依赖 SwiftUI、AppKit、Combine，也不直接执行界面或文件／网络操作。
- **ViewModel**：持有可观察的展示状态、用户动作、业务流程和异步任务；调用注入的 Service，处理加载、错误、取消及目标失效。不直接构建 SwiftUI View、弹原生对话框或执行底层 IO。
- **View**：SwiftUI 只负责布局、显示、绑定、焦点和交互转发；临时输入／动画状态可用 `@State`，不在 `body`、事件回调或 View 的生命周期中新增业务规则、Git 命令、网络／文件访问。
- **Service / Repository**：集中管理文件、Git、SSH、持久化及系统副作用；已有 `WorkspaceBackend` 提供本机与 SSH 的真实多实现边界。仅在确实需要多实现、替换或测试注入时定义 protocol，不为每个类生成接口。
- **依赖与装配**：方向为 `View → ViewModel → Service → Model`（各层可读取纯 Model）；从 App／窗口入口显式传入依赖，复用现有唯一状态所有者，不新增平行缓存、全局单例、依赖容器或内部 SwiftPM target。简单无业务状态的 View 不必强造 ViewModel。
- **分阶段、全量收敛**：先沿真实状态和副作用链确定职责，再逐块迁移、验证并同时删除被取代的旧状态、转发与调用路径；最终核对所有自有 UI 状态链，不以只迁移碰到的代码结束，也不长期保留双套实现。分阶段不等于一次性乱改，更不能牺牲生命周期或数据保护。

## 不可破坏的状态与平台边界

- **纯架构重构的 UI/UX 零变化**：同一系统、窗口尺寸、主题、语言与内容下，布局、颜色、字体、图标、间距、动效、弹窗/菜单/文案、点击与拖拽、键盘快捷键、焦点、滚动、加载/失败/取消反馈和无障碍行为必须保持现状。改动前建立隔离 Debug 原生基线，受影响区域逐任务对照截图及实操；编译通过不能代替 UI/UX 验收。既有交互缺陷另案处理，不混入纯重构。
- **生命周期**：当前窗口由 `TerminalManager` 协调、项目由 `Project` 持有，每个 `PaneTab` 恰有一份内容。这些是现存真实 owner，迁移前不得复制其状态；临时 View 重建不能结束终端、丢失编辑或中断转发。
- **自由停靠**：`DockNode` 是外层布局真源；面板与标签一一对应，禁止标签内部二次分屏。移动、关闭、恢复须保留内容和焦点，不另建并行布局状态。
- **共享树**：文件与 Git 共用 `TreeDisplayModel` 和树行，保留目录压缩、状态、命中范围、悬停、滚动、键盘、无障碍和懒加载。
- **异步身份**：回写状态或执行操作前核对发起时的项目、机器、连接、路径与请求代次；旧结果不能覆盖新状态。失败保留未保存编辑，远端失败不得退回本机写入。
- **窗口焦点与事件**：菜单通过 `.focusedSceneValue(\.keroManager, manager)`／`@FocusedValue(\.keroManager)` 读取当前窗口；自动保存由语义变化回调经 500ms 防抖写盘，不依赖旧 `objectWillChange` 级联。修改菜单或嵌套状态时须实测两窗口切焦点、动作归属及快照，不能让后台窗口接管快捷键。
- **系统桥接**：SwiftUI 是主要界面；Ghostty 用于终端，WebKit 仅用于浏览器，Diff／文件编辑器使用 AppKit／TextKit。SwiftUI 重绘不得重新创建 Shell、浏览器 WebView 或原生编辑器。后端保留 Git 刷新合并、SSH 批量执行及超时；布局配置由窗口协调者传入项目。
- **生成与依赖**：图标资源和查询表只通过生成脚本修改；第三方源码、补丁和许可证按[依赖约束](docs/DEPENDENCIES.md)维护。

## Swift / SwiftUI 约定

- **Swift 6 编译基线**：App 与 XCTest 的 Debug／Release 均启用 Swift 6 语言模式和默认 `MainActor` 隔离，最低 macOS 仍为 15.6。修改并发代码须用真实 Swift 6 构建、测试与验签检查隔离边界；新 API 以当前 Xcode／SDK 和部署目标可用性为准，不为追新提高系统版本或增加兼容包装。
- **Observation 优先**：新建可观察 ViewModel 默认使用 `@Observable`；View 持有其生命周期时用 `@State`，需要双向绑定时用 `@Bindable`，只读取时直接传入对象，局部 UI 状态仍用 `@State`。依赖通过初始化参数或现有环境注入，不恢复自有 SwiftUI 状态的旧 `ObservableObject`／`@Published` 转发或双套观察机制。
- **Combine 限定用途**：SwiftUI 自有展示状态由 Observation 管理。`TunnelManager.$tunnels/$states` 的 Combine 事件仍供原生 `NSTableView` 刷新；WebKit 的 KVO 也保留必要的原生事件桥。Observation 属性追踪不等于事件订阅；嵌套变化、设置响应和自动保存须经现行语义触发，不恢复旧 `objectWillChange` 级联。
- **并发与错误**：可观察状态由 `MainActor` 管理；文件、Git、SSH 等耗时任务走异步后端，`Task {}` 本身不会脱离主 actor。优先 Swift Concurrency、`Sendable` 边界及 `Task.sleep(for:)`，任务取消或切换目标后不发布过期结果；只有确需 AppKit 事件／第三方桥接时保留 GCD。按 Swift 6 编译诊断修正隔离，不能用 `nonisolated(unsafe)`、无依据的 `@unchecked Sendable`、`try!` 或强制解包掩盖问题。
- **交互与无障碍**：普通点击用 `Button`，仅确需坐标或点击次数时用 `onTapGesture`；图标按钮必须有文字语义及辅助功能名称。核对键盘快捷键、焦点、悬停与 VoiceOver；尊重系统字号和用户配置的终端／编辑器字体，不以固定文字大小取代可调整字号。
- **视图结构**：较复杂且独立的界面块用独立 `View` 类型，不通过返回 `some View` 的计算属性堆叠子视图；避免无必要的 `AnyView`。可用原生布局替代时不用 `GeometryReader`，但 Dock 拖动和精确命中仍允许读取几何信息；`ForEach` 使用稳定身份，避免仅为遍历 `enumerated()` 转成数组。
- **SwiftUI 表达**：新增界面代码在语义及视觉等价、系统支持时优先 `foregroundStyle()`、`clipShape(.rect(cornerRadius:))`、`.scrollIndicators(.hidden)`；普通加粗可用 `.bold()`。**现有界面的纯架构重构不顺手替换样式 API。**自定义 Dock 标签不是系统导航，不为套用 `TabView` 或 `NavigationStack` 示例而改写工作区；SwiftUI 视图渲染图片时优先 `ImageRenderer`，原生表面仍由相应 AppKit／WebKit 接口处理。
- **Swift API 与日志**：优先 Swift 原生字符串方法、现代 Foundation URL／数字格式化及简洁的静态成员表达，不用 C 风格格式化显示数字；用户输入的普通文本匹配优先 `localizedStandardContains()`（不取代路径精确匹配或模糊搜索）。新诊断日志使用带明确 `subsystem`／`category` 的 `os.Logger`，保护路径、终端输出和凭据等隐私信息。

## 构建

项目使用单个 Xcode App Target、原生 `KeroTests`（XCTest）和唯一的 `Kero.app`／`chiimagnus.kero`，不再创建开发版身份、额外 scheme 或独立构建／测试 `.sh` 脚本。根目录 `Makefile` 是本地与 CI 的构建、测试入口，直接调用 `xcodebuild`：

```sh
make build
make test
make build:release
```

需要指定 XCTest 时使用 `make test ONLY_TESTING=KeroTests/类名`。本机签名要求有效 Apple Development 证书，默认 Team ID 为 `RDQHYSDFFG`；CI、发包、产物路径和 `DEVELOPER_DIR` 见[构建与发包](docs/RELEASE.md)。Ghostty 由 Xcode Swift Package Dependencies 管理；资源通过 Copy Files 打包，仅 `ssh -> kero` 符号链接需要一条 Xcode Build Phase。

测试源码统一放在 `KeroTests/` 并由 XCTest 执行；旧独立检查脚本已清理，不得在 Debug App 启动时运行断言式自检。Xcode TestAction 为真实 Debug App 传入 `--isolated-ui-test`，隔离窗口快照和终端历史，并避免启动已保存隧道；不在产品入口增加依赖 XCTest 环境变量的特殊逻辑。

**开发与测试闭环**：Feature 的需求／计划驱动负责定义目标和验收，测试驱动开发（TDD）负责证明行为：复现缺陷先写失败回归（Red）→修复根因（Green）→清理旧路径（Refactor）。按风险覆盖单元、原生组件、完整工作区与真正的 E2E，不能用单个面板 XCTest 冒充完整 App 点击验收；测试须核对真实副作用，并保护用户正在运行的 Kero。分层选择、隔离要求与 MVVM 目录归属统一见[开发与测试](docs/TESTING.md)。

## 验证

- **MVVM／Observation 验收**：每块迁移都验证状态、绑定、变化事件、真实 Service 副作用及错误／取消／过期结果；尤其核对焦点窗口菜单、嵌套状态、自动保存、窗口恢复、项目／标签切换及终端／编辑器重挂载。使用受影响的 XCTest 和必要的原生交互验收，编译通过或事件发出不等于行为完成。
- **Swift 6 收口**：全项目迁移完成时，必须在工程实际启用的 Swift 6 语言模式下构建、运行 XCTest 并严格验签，检查并发诊断；仅修改编译选项、静态扫描或屏蔽诊断不算通过。现代化不得改变既有行为，确有平台／依赖限制则记录实际证据和未完成范围。
- **测试边界**：自动测试使用临时数据或受控后端；真实 SSH 只用获准的专用测试 master，不复用用户连接。性能改动按[性能](docs/PERFORMANCE.md)测量；真实网络、重启恢复及原生界面未测时明确说明。
- **文案与文档**：纯名称、翻译只校验字符串表、中英文、占位符、链接；涉及字符串提取时按需构建，不机械要求真机验收。快捷键、动作路由和布局属于行为改动。只修改文档时检查事实与引用，无需重装 App。
- **隔离验收**：需要操作 App 时优先使用同一签名 Debug 包，不复制成另一套身份：
  ```sh
  open -n -a "$PWD/build/DerivedData/Build/Products/Debug/Kero.app" --args --isolated-ui-test
  ```
  此模式隔离窗口与终端历史，不启动保存的隧道，但普通设置仍共用；不得在隔离实例中改写全局设置。
- **本地安装**：功能代码通过测试及签名 Debug 构建后，默认按[本地安装](docs/RELEASE.md#本地安装)整包替换 `/Applications/Kero.app`；用户明确要求跳过时除外。**绝不退出、启动或重启现有 App**，用户自行重启后新代码才生效；安装失败应恢复原包，不留旧版备份。
- **收尾**：只清理本次可确认归属的临时产物，不动用户数据。分别报告已构建、已验签、已安装、已重启与恢复验收的实际状态；不以隔离实例成功冒充正式包已安装。

## 文档与提交

- 本文件是唯一的仓库级 AI 开发入口；MVVM 职责、唯一状态所有者、依赖边界或构建／验收入口变化时同步核对。各功能的具体行为、失败和恢复规则由对应 `docs/` 维护；用户可见内容再更新 [README](README.md)，不复制实现清单或历史计划。
- 自有文档使用中文，保留一个详细规则归属；`docs/` 负责维护约束，`.github/features/` 只保留实施历史，不作为当前功能事实。
- 独立改动验证后原子提交；中文提交标题概括结果，正文记录改动、原因、实际验证及未测项。只提交本任务文件，不创建新分支、不擅自推送。
- 提交前检查关联文档引用、无关改动及 `rtk git diff --check`；纯文档任务不为完成形式重复编译或重装 App。

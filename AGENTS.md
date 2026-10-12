# Kero 开发规范

本文件是仓库级 AI 开发入口。用户说明见 [README](README.md)；功能细节由对应 `docs/` 文档维护，不以 `.github/features/` 的历史计划代替当前事实。

## 动手前

- 先读受影响功能的维护文档，沿入口、状态所有者、后端直到实际副作用检查。先执行 `rtk codegraph sync`，再用 `rtk codegraph explore` / `node` 定位；索引不全时核对源码与 XCTest，不凭文件名猜职责。
- 按改动阅读[产品](docs/PRODUCT.md)、[项目与 SSH](docs/PROJECTS.md)、[终端与停靠](docs/TERMINAL.md)、[文件与编辑器](docs/EDITOR.md)、[Git](docs/GIT.md)、[浏览器](docs/BROWSER.md)、[设置与恢复](docs/SETTINGS.md)；横向约束见[性能](docs/PERFORMANCE.md)、[安全](docs/SECURITY.md)、[本地化](docs/LOCALIZATION.md)及[依赖与生成](docs/DEPENDENCIES.md)。
- 优先复用现有实现、修复共享根因。只做获授权的修改；推送、发布、破坏性操作和替换用户正在使用的 App 须另获授权，不中断运行中命令或未保存编辑。

## 架构：MVVM

**新功能及被修改的相关代码以 MVVM 为目标架构。当前项目尚未完成迁移**：`TerminalManager`、`Project` 等兼有状态协调与业务职责，部分 SwiftUI View 仍直接编排任务。不得仅改类名就宣称 MVVM 已落地。

- **Model**：表达领域数据、身份、不变量与纯转换；不依赖 SwiftUI、AppKit、Combine，也不直接执行界面或文件／网络操作。
- **ViewModel**：持有可观察的展示状态、用户动作、业务流程和异步任务；调用注入的 Service，处理加载、错误、取消及目标失效。不直接构建 SwiftUI View、弹原生对话框或执行底层 IO。
- **View**：SwiftUI 只负责布局、显示、绑定、焦点和交互转发；临时输入／动画状态可用 `@State`，不在 `body`、事件回调或 View 的生命周期中新增业务规则、Git 命令、网络／文件访问。
- **Service / Repository**：集中管理文件、Git、SSH、持久化及系统副作用；已有 `WorkspaceBackend` 提供本机与 SSH 的真实多实现边界。仅在确实需要多实现、替换或测试注入时定义 protocol，不为每个类生成接口。
- **依赖与装配**：方向为 `View → ViewModel → Service → Model`（各层可读取纯 Model）；从 App／窗口入口显式传入依赖，复用现有唯一状态所有者，不新增平行缓存、全局单例、依赖容器或内部 SwiftPM target。简单无业务状态的 View 不必强造 ViewModel。
- **渐进迁移**：改动触及旧混合实现时，先找正确的唯一归属，再连同调用方与测试收敛；不得保留两套可写状态，也不为迁移一次性重排全部源码或牺牲现有生命周期与失败保护。

## 不可破坏的状态与平台边界

- **生命周期**：当前窗口由 `TerminalManager` 协调、项目由 `Project` 持有，每个 `PaneTab` 恰有一份内容。这些是现存真实 owner，迁移前不得复制其状态；临时 View 重建不能结束终端、丢失编辑或中断转发。
- **自由停靠**：`DockNode` 是外层布局真源；面板与标签一一对应，禁止标签内部二次分屏。移动、关闭、恢复须保留内容和焦点，不另建并行布局状态。
- **共享树**：文件与 Git 共用 `TreeDisplayModel` 和树行，保留目录压缩、状态、命中范围、悬停、滚动、键盘、无障碍和懒加载。
- **异步身份**：回写状态或执行操作前核对发起时的项目、机器、连接、路径与请求代次；旧结果不能覆盖新状态。失败保留未保存编辑，远端失败不得退回本机写入。
- **系统桥接**：SwiftUI 是主要界面，AppKit／Ghostty／WebKit／TextKit 负责原生输入、终端和长生命周期视图；桥接不能因 SwiftUI 重绘重新创建 Shell、WebView 或编辑器。后端保留 Git 刷新合并、SSH 批量执行及超时；布局配置由窗口协调者传入项目。
- **生成与依赖**：图标资源和查询表只通过生成脚本修改；第三方源码、补丁和许可证按[依赖约束](docs/DEPENDENCIES.md)维护。

## Swift / SwiftUI 约定

- **真实工具链优先**：工程使用 macOS 15.6+、Swift 5 语言模式与默认 `MainActor` 隔离；使用较新 Swift、Foundation、SwiftUI API 前核对实际 Xcode／SDK 及部署目标，不引入为追新而造的兼容层。
- **观察与注入**：当前以 `ObservableObject`／`@Published`／Combine 为主。状态创建方用 `@StateObject`，使用方用 `@ObservedObject` 或 `Binding`，局部 UI 状态用 `@State`；依赖通过初始化参数或现有环境注入。仅在明确迁移观察链时采用 `@Observable`／`@Bindable`，不重复维护同一状态，也不为形式统一替换所有 Combine。
- **并发与错误**：可观察状态在 `MainActor` 发布；文件、Git、SSH 等耗时任务走异步后端，`Task {}` 本身不代表脱离主线程。优先 Swift Concurrency 与 `Task.sleep(for:)`，取消或切换目标后不发布过期结果；现有 Combine 调度及 AppKit 事件桥接可保留必要的 GCD。不要用 `nonisolated(unsafe)`、`try!` 或强制解包掩盖真实问题。
- **交互与无障碍**：普通点击用 `Button`，仅确需坐标或点击次数时用 `onTapGesture`；图标按钮必须有文字语义及辅助功能名称。核对键盘快捷键、焦点、悬停与 VoiceOver；尊重系统字号和用户配置的终端／编辑器字体，不以固定文字大小取代可调整字号。
- **视图结构**：较复杂且独立的界面块用独立 `View` 类型，不通过返回 `some View` 的计算属性堆叠子视图；避免无必要的 `AnyView`。可用原生布局替代时不用 `GeometryReader`，但 Dock 拖动和精确命中仍允许读取几何信息；`ForEach` 使用稳定身份，避免仅为遍历 `enumerated()` 转成数组。
- **SwiftUI 表达**：语义等价且系统支持时优先 `foregroundStyle()`、`clipShape(.rect(cornerRadius:))`、`.scrollIndicators(.hidden)`；普通加粗优先 `.bold()`。自定义 Dock 标签不是系统导航，不为套用 `TabView` 或 `NavigationStack` 示例而改写工作区；SwiftUI 视图渲染图片时优先 `ImageRenderer`，原生表面仍由相应 AppKit／WebKit 接口处理。
- **Swift API 与日志**：优先现代 Swift 字符串／Foundation URL API 与格式化接口，不用 C 风格格式化来显示数字；用户输入的普通文本匹配优先 `localizedStandardContains()`（不取代路径精确匹配或模糊搜索）。新诊断日志使用 `os.Logger` 并保护文件路径、终端输出、凭据等隐私信息。

## 构建

项目使用单个 Xcode App Target、原生 `KeroTests`（XCTest）和唯一的 `Kero.app`／`chiimagnus.kero`，不再创建开发版身份、额外 scheme 或独立构建／测试 `.sh` 脚本。根目录 `Makefile` 是本地与 CI 的构建、测试入口，直接调用 `xcodebuild`：

```sh
make build
make test
make build:release
```

需要指定 XCTest 时使用 `make test ONLY_TESTING=KeroTests/类名`。本机签名要求有效 Apple Development 证书，默认 Team ID 为 `RDQHYSDFFG`；CI、发包、产物路径和 `DEVELOPER_DIR` 见[构建与发包](docs/RELEASE.md)。Ghostty 由 Xcode Swift Package Dependencies 管理；资源通过 Copy Files 打包，仅 `ssh -> kero` 符号链接需要一条 Xcode Build Phase。

测试源码放在 `KeroTests/`，`KeroTests/references/` 中的历史检查不参与构建，也不是验收入口。Xcode TestAction 为真实 Debug App 传入 `--isolated-ui-test`，隔离窗口快照和终端历史，并避免启动已保存隧道；不在产品入口增加依赖 XCTest 环境变量的特殊逻辑。

## 验证

- **代码与 MVVM 改动**：按受影响流程运行 XCTest，验证状态、动作、实际 Service 副作用及错误／取消／过期结果；构建并严格验签，必要时以真实原生界面检查焦点、编辑、拖动或重挂载。编译通过或事件发出不等于行为完成。
- **测试边界**：自动测试使用临时数据或受控后端；真实 SSH 只用获准的专用测试 master，不复用用户连接。性能改动按[性能](docs/PERFORMANCE.md)测量；真实网络、重启恢复及原生界面未测时明确说明。
- **文案与文档**：纯名称、翻译只校验字符串表、中英文、占位符、链接；涉及字符串提取时按需构建，不机械要求真机验收。快捷键、动作路由和布局属于行为改动。只修改文档时检查事实与引用，无需重装 App。
- **隔离验收**：需要操作 App 时优先使用同一签名 Debug 包，不复制成另一套身份：
  ```sh
  open -n -a "$PWD/build/DerivedData/Build/Products/Debug/Kero.app" --args --isolated-ui-test
  ```
  此模式隔离窗口与终端历史，不启动保存的隧道，但普通设置仍共用；不得在隔离实例中改写全局设置。
- **正式安装**：默认路径 `/Applications/Kero.app`。只有获准时才在构建验签后于临时路径准备完整 App，再替换并复验签名；**不创建旧版备份**，禁止逐文件覆盖运行中的包，失败即停止并说明。默认不退出、启动或重启现有 App，不打断命令或未保存编辑；用户自行重启后才能验收恢复。
- **收尾**：只清理本次可确认归属的临时产物，不动用户数据。分别报告已构建、已验签、已安装、已重启与恢复验收的实际状态；不以隔离实例成功冒充正式包已安装。

## 文档与提交

- 本文件是唯一的仓库级 AI 开发入口；MVVM 职责、唯一状态所有者、依赖边界或构建／验收入口变化时同步核对。各功能的具体行为、失败和恢复规则由对应 `docs/` 维护；用户可见内容再更新 [README](README.md)，不复制实现清单或历史计划。
- 自有文档使用中文，保留一个详细规则归属；`docs/` 负责维护约束，`.github/features/` 只保留实施历史，不作为当前功能事实。
- 独立改动验证后原子提交；中文提交标题概括结果，正文记录改动、原因、实际验证及未测项。只提交本任务文件，不创建新分支、不擅自推送。
- 提交前检查关联文档引用、无关改动及 `rtk git diff --check`；纯文档任务不为完成形式重复编译或重装 App。

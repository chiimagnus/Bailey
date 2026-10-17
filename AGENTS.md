# Kero 开发规范

本文件是唯一的仓库级 AI 开发入口。文档总入口是 [docs/README.md](docs/README.md)，面向用户的说明在 [README](README.md)。先读受影响文档，再沿真实入口、状态所有者和后端查到最终结果。

## 开发立场

Kero 是自由组装的 AI IDE，以原生终端工作区承载 CLI、文件、Git 与浏览器。保持简单、准确和可检查，优先复用现有实现、标准库与平台能力；从共享根因修复，不为未来搭抽象或补丁链。

采用 Swift 6 与 MVVM + Observation，最低 macOS 15.6，支持 Apple Silicon。新 API 先核对实际 SDK 和部署目标，不为追新提高最低系统或增加旧实现包装。短状态操作保持同步，真实 IO 和耗时工作明确离开主 actor。

## 不可破坏的约束

- **数据和目标**：失败保留未保存编辑。异步结果核对项目、机器、连接、路径与请求代次；远端失败不得回退写本机。关闭文件、项目、窗口或 App 前先完成相应保存保护。
- **唯一所有者**：窗口由 `TerminalManager`、项目由 `Project`、内容由其标签持有。每个 `PaneTab` 只有一份内容；重绘、切换和重挂载不能重新创建 Shell、WebView 或编辑器。
- **自由停靠与焦点**：`DockNode` 是外层布局真源，标签内部不再分屏。菜单经当前窗口的 focused value 路由，不能让后台窗口接管操作。
- **共享界面**：Files 和所有 Git 树共用模型与树行。目录压缩、状态、命中、悬停、滚动、键盘与无障碍一起验证，不只修一个区域。
- **纯重构零 UI/UX 变化**：不顺手改样式、文案、布局或交互。逐任务对照原生基线，不能用编译通过代替界面验收。
- **测试与实际结果**：可测试的新行为和缺陷先 Red、再 Green、再 Refactor。按风险验证原触发条件、共享根因及相关环境／极端／并发边界，未测条件如实报告；低层测试不冒充 E2E，事件派发不冒充真实副作用。现有测试继续进入同一个 XCTest 目标，覆盖选择见 [testing.md](docs/testing.md#根因与回归覆盖)。
- **保护用户环境**：不退出、启动或重启正在使用的 Kero，不借用用户 SSH master、不结束其后台任务。只有一个 `Kero.app`／`chiimagnus.kero`，不恢复第二套开发版身份。
- **生成与依赖**：生成资源回到生成器修改；第三方源码、补丁、版权和许可证按其归属维护，不顺手覆盖或翻译。

## 动手前读什么

| 改动 | 必读 |
| --- | --- |
| 状态、分层、装配、目录 | [architecture.md](docs/architecture.md) |
| Swift、命名、并发、注释、性能原则 | [standards.md](docs/standards.md) |
| View、主题、共享组件、交互、本地化 | [ui.md](docs/ui.md) |
| 测试、隔离、性能测量、完成判断 | [testing.md](docs/testing.md) |
| 环境、构建、安装、依赖、生成资源 | [development.md](docs/development.md) |
| CI、发包与证书 | [release.md](docs/release.md)、[signing.md](docs/signing.md) |
| 具体功能 | [功能索引](docs/README.md#功能文档)中的对应页面 |
| 贡献和安全 | [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) |

## 执行

定位代码先执行 `rtk codegraph sync`，再使用 `rtk codegraph explore`／`node`；索引缺失时核对源码和测试，不凭目录或名字猜职责。返回的逐字源码视同已读，调用关系仍要结合真实控制流判断。

需求／Feature 计划决定范围与验收，测试驱动守住行为。简单改动不强制创建 Feature 计划；跨阶段工作沿用已有 `idea.md`、`todo.toml` 与 `plan-pX.md`。每个任务同时接入新实现、删除被替代路径、同步受影响文档并验证，不把必要测试、文档和清理延后。

构建和测试只使用根 [Makefile](Makefile) 及现有 Xcode 工程／scheme，不建立另一套 shell 测试系统。测试按层次和业务组织，详见 [testing.md](docs/testing.md#测试目录与入口)。

只操作获授权的范围；推送、发布、导出凭据和破坏性操作另需授权。代码通过验证后按[本地安装](docs/development.md#本地安装)整包更新 App，用户明确跳过时除外；不重启现有 App。纯文档任务不构建或安装。

## 完成与维护

以 [testing.md 的完成标准](docs/testing.md#完成标准)收尾。准确报告已测与未测，区分构建、签名、安装、重启和发布；只清理能确认属于本任务的临时产物。

文档每页一个详细归属，按 [docs/README.md](docs/README.md#文档维护) 同步更新。当前进度、试验、失败方案和下一步留在原任务／证据位置；长期教训提炼为有原因及适用范围的规则，不复制流水账，也不让已停止路线重新成为待办。

独立改动验证后原子提交，只包含本任务文件。中文标题概括结果，正文写清改动、原因和实际验证；通读 diff、检查现行引用及 `git diff --check`。不创建新分支，不擅自推送。

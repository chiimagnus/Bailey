# Bailey 开发规范

本文件是唯一的仓库级 AI 开发入口。文档总入口是 [docs/README.md](docs/README.md)，面向用户的说明见[中文 README](README.md) / [English README](README.en.md)。先读受影响文档，再沿真实入口、状态所有者和后端查到最终结果。

## 开发立场

Bailey 是自由组装的 AI IDE，以原生终端工作区承载 CLI、文件、Git 与浏览器。保持简单、准确和可检查，优先复用现有实现、标准库与平台能力；从共享根因修复，不为未来搭抽象或补丁链。

采用 Swift 6 与 MVVM + Observation，最低 macOS 15.6，支持 Apple Silicon。新 API 先核对实际 SDK 和部署目标，不为追新提高最低系统或增加旧实现包装。短状态操作保持同步，真实 IO 和耗时工作明确离开主 actor。

当前只做好 macOS App；iOS、iPadOS 与 visionOS 暂不进入开发和验收范围，也不为其预建跨平台接口、窗口包装或替代后端。平台范围的重新评估见 [架构边界](docs/architecture.md#平台范围)。

## 不可破坏的约束

- **数据和目标**：失败保留未保存编辑。异步结果核对项目、机器、连接、路径与请求代次；远端失败不得回退写本机。关闭文件、项目、窗口或 App 前先完成相应保存保护。
- **唯一所有者、单向依赖**：`WorkspaceApplication` 负责应用级窗口及恢复，`WorkspaceWindowModel` 负责单窗；项目、标签与功能局部状态各归其主，不复制可写状态或让领域反向读取整个窗口。重绘、切换和重挂载不能重新创建 Shell、WebView 或编辑器。职责重构必须证明减少了哪条依赖、删除了哪条旧路径，不能只增加 Manager／Coordinator／Protocol；见 [architecture.md](docs/architecture.md#模块化与依赖)。
- **模块边界**：按业务职责组织，跨模块通过明确动作与必要数据协作，不让上层遍历下层控件来决定业务归属。拆分必须减少耦合，不以文件搬迁、extension 或空协议冒充模块化；详见 [模块化与依赖](docs/architecture.md#模块化与依赖)。
- **自由停靠与焦点**：`DockNode` 是外层布局真源，标签内部不再分屏。菜单经当前窗口的 focused value 路由，不能让后台窗口接管操作。
- **状态与焦点分离**：展开、选中、悬停、展示、激活、真实焦点各有独立真源；允许明确动作联动，不允许凭状态变化推测动作。窗口仅协调跨组件交接，组件管理游标与实际原生输入；不新建全 App FocusManager，也不复制焦点状态。现有分散实现仍待迁移，见 [焦点边界](docs/architecture.md#焦点协调边界)。
- **共享界面**：Files 和所有 Git 树共用模型与树行。目录压缩、状态、命中、悬停、滚动、键盘与无障碍一起验证，不只修一个区域。
- **纯重构零 UI/UX 变化**：不顺手改样式、文案、布局或交互。逐任务对照原生基线，不能用编译通过代替界面验收。
- **测试与实际结果**：必须尽可能覆盖受影响功能的全部测试环境、测试条件、异常与极端情况及其组合，不能只测典型路径便结束；必须追到根因并验证同源影响。可测试的新行为和缺陷先 Red、再 Green、再 Refactor；未覆盖条件逐项说明原因与影响。低层测试不冒充 E2E，事件派发不冒充真实副作用；纯逻辑、后端及必须访问 TextKit 几何／IME 内部状态的 AppKit 组件契约保留在 `BaileyTests/Unit`／`Integration`；完整 App 用户路径使用独立 `BaileyUITests` 和专用 GUI 会话，组件截图／事件派发不能冒充完整 App 操作；不得在本机用户 Bailey 运行时启动 UI 自动化。详细验收要求见 [testing.md](docs/testing.md#根因与回归覆盖)。
- **保护用户环境**：不退出、启动或重启正在使用的 Bailey，不借用用户 SSH master、不结束其后台任务。只有一个 `Bailey.app`／`chiimagnus.bailey`，不恢复第二套开发版身份。
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

需求／Feature 计划决定范围与验收，测试驱动守住行为。简单改动不强制创建 Feature 计划；跨阶段工作沿用已有 `idea.md`、`todo.toml` 与 `plan-pX.md`。跨组件重构按真实入口拆成可独立验收的调用链；每个任务同时接入新实现、删除该链被替代的路径、同步文档并验证，不为后续清理留下双轨。

构建和测试只使用根 [Makefile](Makefile) 及现有 Xcode 工程／scheme，不建立另一套 shell 测试系统。测试按层次和业务组织，详见 [testing.md](docs/testing.md#测试目录与入口)。

只操作获授权的范围；推送、发布、导出凭据和破坏性操作另需授权。代码通过验证后按[本地安装](docs/development.md#本地安装)整包更新 App，用户明确跳过时除外；不重启现有 App。纯文档任务不构建或安装。

## 完成与维护

以 [testing.md 的完成标准](docs/testing.md#完成标准)收尾。准确报告已测与未测，区分构建、签名、安装、重启和发布；只清理能确认属于本任务的临时产物。

文档每页一个详细归属，按 [docs/README.md](docs/README.md#文档维护) 同步更新。当前进度、试验、失败方案和下一步留在原任务／证据位置；长期教训提炼为有原因及适用范围的规则，不复制流水账，也不让已停止路线重新成为待办。

独立改动验证后原子提交，只包含本任务文件。中文标题概括结果，正文写清改动、原因和实际验证；通读 diff、检查现行引用及 `git diff --check`。不创建新分支，不擅自推送。

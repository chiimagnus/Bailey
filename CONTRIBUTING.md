# 参与 Bailey 开发

先查看已有 [Issues](https://github.com/chiimagnus/Bailey/issues) 和 [Pull Requests](https://github.com/chiimagnus/Bailey/pulls)。非平凡功能先在 Issue 中确认需求与范围，再写实现；已有维护者明确授权的工作和纯文档修正说明对应背景即可，不重复创建同义需求。

## Issue 与标签

使用 Bug / Feature 模板分别自动添加 `bug` / `enhancement`；文档任务使用 `documentation`，性能相关问题额外标记 `performance`。同一 Issue 确实兼有缺陷修复和功能扩展时，可以同时标记两种类型。

`Open` / `Closed` 表示是否结案。只有实际开始开发时才添加 `in-progress`，明确暂缓时使用 `on-hold`；两者不并存，恢复或结案后移除。默认不设优先级、模块标签或 GitHub Projects，避免与 Issue 重复维护进度。

## 不可破坏的约束

[AGENTS.md](AGENTS.md#不可破坏的约束) 同时适用于人工贡献者和 AI。保存用户数据、机器身份、后台进程与原生视图生命周期，优先于让代码看起来更整齐。

新界面应与已有共享组件一致，见 [docs/ui.md](docs/ui.md)；新增依赖、抽象和缓存必须解决当前真实问题。性能和内存改动需要测量，不以“应该更快”作为结果。

## 开始开发

环境、本地构建、签名和安装见 [docs/development.md](docs/development.md)，结构见 [docs/architecture.md](docs/architecture.md)。[docs 索引](docs/README.md)列出每个功能的文档及更新时机。

当前只开发 macOS。职责重构前按 [模块化与依赖](docs/architecture.md#模块化与依赖) 查清旧／新唯一所有者、减少的反向依赖及被删除的重复规则；不能以增加 Manager、Coordinator、Protocol、搬文件或改名代替真实重构。焦点相关改动还须明确展开、选中、悬停、展示、激活、实际输入的独立状态与显式动作语义，不模仿别的 IDE 顺手改变 Bailey 的交互。

Bailey 只有一套 App 身份；开发构建和正式 App 不天然隔离，先阅读[测试隔离](docs/testing.md#隔离环境)。不要为了测试退出用户已有 App、占用其连接或改写个人配置。

## 提交之前

完成标准只有一份：[docs/testing.md](docs/testing.md#完成标准)。代码变更**必须尽可能覆盖受影响功能的全部适用测试环境、条件、异常与极端情况及其组合**，执行实际测试、构建和必要的原生／人工回归；无法执行的场景逐项说明原因、影响与补验，不能只凭几个测试或 CI 通过收尾。纯文档按该页的文档检查收尾；缺陷修复保留根因、失败复现和修复后的证据。

凡被本次修改弄错的文档都在同一提交修正；页面移动或删除同步更新索引和引用。任务进度、停止决定、失败证据及长期教训按[文档维护规则](docs/README.md#文档维护)归档，不在 PR 里建立第二套进度记录。

提交前从头到尾阅读自己的 diff，检查无关文件和敏感数据。逻辑独立的改动分别提交，中文标题说明结果，正文写清改了什么、为什么、实际验证和未测项。

## Pull Request

填写 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md)，关联已经讨论的 Issue。只有覆盖全部需求并完成验收才使用 `Closes #编号`；部分交付或尚需补验时使用 `Refs #编号`，避免提前关闭 Issue。没有对应 Issue 时说明来源和范围。自动检查的实际范围见 [release.md](docs/release.md#pr-检查)，提交者仍对未自动化的验收负责。

说明改动、必要架构取舍、状态所有者／依赖方向的变化、删除的旧路径、数据／权限／兼容影响、剩余限制及测试证据。视觉改动附同窗口尺寸、内容和动作的前后并排录屏，静态截图仅作补充；非视觉改动说明所测路径。

涉及内存、性能或生命周期时，提供空闲、使用峰值和关闭后稳定状态的前后数字，以及泄漏检查结果。没有运行的项明确标为未测，不用测试数量或 CI 绿色替代用户验收。

## 代码风格

[docs/standards.md](docs/standards.md) 维护命名、Swift、并发、注释和简化规则；功能页的 `Invariants` 维护局部不可破坏行为。看似特殊的实现先查原因，再修改。

非预期行为不能随清理改变；确实需要改变时在需求和 PR 中明确。不要为了满足文档模板批量重命名、调整样式或新增配置。

## 报告问题

Bug 提供 Bailey 版本或提交、macOS 与设备、复现步骤、预期和实际结果；SSH 问题补充远端系统与 shell。截图、录屏和日志先移除私人路径、凭据、终端内容与会话信息。

Feature 说明希望完成什么、解决哪个使用问题。安全漏洞不要放到公开 Issue，按 [SECURITY.md](SECURITY.md) 私下联系。

## 许可证与署名

项目许可证为 [GPLv3](LICENSE)，来源和第三方声明见 [NOTICE.md](NOTICE.md)。保留已有版权、许可证和署名；仓库没有另设贡献者或反馈授权协议。

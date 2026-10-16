# 测试与验收

本页是 Kero 完成标准的唯一归属，负责测试层次、执行入口、隔离、性能测量和人工回归。测试结构、覆盖范围或验收要求改变时同步更新；贡献指南与 PR 只引用本页，不维护第二份清单。

## 完成标准

需求／文档驱动决定做什么和如何验收，测试驱动验证实现；二者属于同一流程。

| 检查 | 完成条件与证据 |
| --- | --- |
| 行为回归 | 新增或调整受影响测试；可测试的新行为和缺陷先确认 Red，再修复为 Green，最后 Refactor |
| 自动测试 | 功能代码变更通过相关回归及 `make test`；测试必须实际被 XCTest 发现和执行 |
| 构建与签名 | 功能代码通过 `make build`；Swift 6 全面迁移、依赖或发布路径变更还检查 `make build:release`，无未解释的新诊断 |
| 架构与数据保护 | 核对状态所有者、依赖、取消、目标失效和真实副作用；旧实现的接入与清理在同一任务完成 |
| 用户路径 | 按下文运行受影响的原生／工作区和人工回归；未执行的 E2E、真实网络与恢复明确列出 |
| 文档与差异 | 受影响文档在同一提交更新，现行链接可达；通读 diff，`git diff --check` 通过 |

**纯文档改动**检查事实、路径、命令和导航，不机械编译或安装 App。文档体系调整逐页核对职责、更新时机、功能页首节、索引覆盖、路径大小写与标题锚点；现行计划单独查失效引用，历史审计不全局替换。检查脚本未覆盖的格式或目录明确列出，不将“无断链”冒充全部文档通过。纯翻译检查字符串表、中英文、占位符与链接，涉及提取时按需构建；快捷键、路由和布局不是纯文案改动。

编译成功、全部低层测试转绿或事件已发出，都不能证明完整用户路径正确。不能禁用失败用例或增加任意等待来制造绿色；既有正确行为也不能为了错误断言而被修改。

## 测试目录与入口

`KeroTests/` 使用**测试层次 → 业务功能**两级目录，全部仍归一个 `KeroTests` XCTest 目标。一级分 `Unit/`、`Integration/`、`NativeUI/`、`WorkspaceUI/`；二级按 App、Settings、Files、Editor、Git、Remote、Workspace 等领域，共享组件归 Shared，完整工作区中的标签／窗口分别归 Tabs／Windows。

每个文件按主要职责归档，不因混合用例机械拆类，不创建空目录或空测试。移动文件时核对工程发现路径，不能让它退出真实测试集合。

```sh
make test
make test ONLY_TESTING=KeroTests/FileTabTests
```

文件夹不进入 XCTest 类名选择参数。运行器由 [Makefile](../Makefile) 与 [共享 scheme](../kero.xcodeproj/xcshareddata/xcschemes/kero.xcscheme) 决定；不另建不参与 XCTest 的检查脚本，也不在产品启动时执行断言式自检。

## 测试层次

| 层次 | 证明什么 | 不证明什么 |
| --- | --- | --- |
| Unit | 模型、解析、状态不变量及边界 | 原生焦点、真实网络或完整 App 入口 |
| Integration | 临时文件、Git 仓库、持久化或受控后端之间的结果 | 模拟后端之外的真实 SSH 传输 |
| NativeUI | `NSWindow`／`NSHostingView` 中真实 TextKit、WebKit、滚动、焦点与撤销 | 从完整 App 菜单／点击入口走完路径 |
| WorkspaceUI | 真实 `ContentView`、项目、Dock、标签与多窗口的集成 | 独立进程的完整端到端 UI 自动化 |
| E2E | 启动完整 App，从用户入口操作并核对最终结果 | 不能由上面的测试数量或绿色状态推断 |

**当前没有独立 XCUITest 测试目标。** 宿主 XCTest 即使创建了原生窗口也不等于 E2E；报告按实际层次命名。

按行为风险选择层次，不给每个功能机械配五套测试。纯计算优先单元测试；影响标签身份、焦点、保存、连接、停靠和窗口生命周期时，加入真实原生或工作区回归，并补足相应人工路径。

## 改什么，测什么

下表是选择依据，不是另一套执行器；完整测试集合仍由 Xcode 目标发现。

| 改动 | 相关测试 |
| --- | --- |
| 应用身份与资源标识 | `AppIdentityTests` |
| Dock 模型、项目与上下文身份 | `DockWorkspaceTests`、`WorkspaceIdentityTests`、`PanelContextTests` |
| 偏好、隧道配置和异常输入 | `AppSettingsTests`、`TunnelStoreTests` |
| 文件树、创建和项目文件索引 | `FileTreeTests`、`ProjectFileIndexTests` |
| Git 环境、刷新、写操作与失败状态 | `GitExternalRefreshTests`、`GitExecutionTests`、`GitStatusModelTests`、`GitBranchActionTests`、`GitRemoteBranchActionTests`、`GitTagActionTests`、`GitWorkspaceActionTests`、`GitStashActionTests`、`GitBranchDialogTests`、`GitTagDialogTests`、`GitWorkspaceMenuTests`、`GitStashDialogTests` |
| SSH 命令、断线、重连和过期结果 | `RemoteCommandsTests`、`RemoteLifetimeTests` |
| 文件、Diff 和原生内容保留 | `FileTabTests`、`DiffTabTests`、`DiffEngineTests`、`PaneRetentionTests` |
| 高亮坐标、渲染色与字体／撤销 | `TextCoordinateIndexTests`、`SyntaxHighlightingTests` |
| 查询编译共享、固定资源失败与取消等待者 | `HighlightQueryCacheTests`、`SyntaxHighlightingTests` |
| 原生组合输入、结束标记与最终替换 | `EditorTextInputTests` |
| Files 与所有 Git 树的命中与交互 | `TreeRowHitTestingTests` |
| 快照、历史与测试隔离 | `SessionStoreTests` |
| 标签及窗口整合路径 | `WorkspaceContentIdentityTests`、`WorkspaceWindowCloseTests`、`WorkspaceWindowIsolationTests` |

测试断言应到达磁盘字节、Git index/HEAD、原生内容、窗口归属或实际焦点。只验证 mock 被调用、字段改变或事件送出，不足以守住最终结果。

## 隔离环境

Xcode TestAction 向 Debug 宿主传入 `--isolated-ui-test`，不通过 XCTest 私有环境变量在产品入口加入另一套行为。

需要单独检查原生界面时使用相同签名的 Debug 包：

```sh
open -n -a "$PWD/build/DerivedData/Build/Products/Debug/Kero.app" --args --isolated-ui-test
```

该模式为每个进程使用独立 UUID 快照和临时终端历史，不加载其他测试实例的项目，不启动已保存隧道。刻意测试重启恢复时，两次启动显式传入同一有效 UUID 环境变量 `KERO_UI_TEST_RUN_ID`。

**普通设置仍然共享。** 隔离实例中不得直接改写用户设置；确需设置测试时使用独立 Home，并核实真正的配置、UserDefaults 与数据写入位置。临时文件、Git 仓库和受控后端不得指向正式项目。

真实 SSH 只使用专用且获准的测试 master；不借用用户连接或结束其后台任务。真实 Windows SSH 回归必须**明确指定获授权的测试主机**。`KERO_P4_TEST_SSH_HOST` 是已有的共用参数名，P4 与后续 Git 外部刷新测试都使用它；未提供时专用用例按条件跳过，不能视为真实 SSH 验收。

`GitInteractiveRebaseTests` 检查固定与自动跟随项目的真实 PTY；`GitWorkspaceSSHTests` 检查专属远端临时仓库的 Push/Delete、ZIP 二进制内容、历史文件 index/工作区复位、Stash、Clean 和普通 FileTab Ignore；`GitExternalRefreshTests` 检查独立 SSH 外部写入后的可见面板自动更新和面板隐藏／App 后台暂停查询。这些是实际 SSH 后端与原生面板集成验证，不是完整独立 App 的菜单 E2E。当前已获授权的 `windows` 主机完整执行命令是：

```sh
KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test
```

必须核对原生 XCTest 的实际执行总数、0 failures、0 skipped 和 Windows SSH 用例的 passed 记录；不能以不带环境参数的绿色 `make test` 冒充实机验收。没有获准测试主机的 CI 不应擅自连接用户设备。XCUITest 启动同 Bundle ID 的应用可能影响正在使用的 Kero，在安全的独立执行环境建立前，不能在用户活跃会话直接调用 `XCUIApplication.launch()`。

只清理本次创建且可确认归属的窗口、进程和数据，不按 App 名或宽泛目录清理。安装不包含重启，见 [development.md](development.md#本地安装)。

## 架构与异步检查

纯 Model 不引入 UI 或环境效果；其时钟、文件事实和外部输入按实际边界注入。按真实职责和调用关系检查分层，不以文件名、目录名或一次文本扫描代替验证。

使用明确事件和有界等待控制异步测试，覆盖取消、目标切换和乱序回写。保存检查发起时身份、真实写入和编辑期间的新内容；原生集成检查观察、绑定、嵌套变化、窗口菜单和重挂载，不只检查类型注解。

全项目 Swift 6 迁移收口必须在真实语言模式下构建、运行测试并严格验签。静态扫描、只改编译选项或屏蔽并发诊断不算通过。

## 性能与内存测量

先测共享热点，再减少主线程工作、重复 IO、计算和无关进程。FPS、骨架出现或数据读完不代替真实显示和输入。

| 用户路径 | 分开记录 |
| --- | --- |
| 打开编辑器 | 文本可见、可输入、高亮稳定 |
| 按键输入 | 文本／光标响应、高亮追上、主线程最长占用 |
| Git | 状态可用、详情完成、进程数、读取量、SSH 往返 |
| Diff | 数据读取、差异计算、TextKit 首屏、滚动与编辑 |
| 多标签和空闲 | 冷开、重复切换、峰值内存、关闭后稳定内存、CPU 与唤醒 |

在同一机器、配置和公开／合成样本上前后比较，记录提交、系统、硬件、屏幕、字体、布局与缓存。Debug 与优化构建分开，冷开和热操作分开；按实际改动选择小／中／接近上限文件、长行、密集高亮、大变更、多标签和本机／SSH，包含受影响的空内容、Unicode、二进制和超限边界。

热操作至少重复 30 次，记录样本数、中位数、p95 与最差值；少量冷启动只报中位数和最差值。用 Instruments Time Profiler 查 CPU，卡顿但 CPU 不高时查等待；用 Allocations 检查视图与缓冲生命周期。确需阶段对齐时才增加轻量 signpost，不先搭埋点框架。

保留已有增量高亮、懒加载、刷新合并、视图复用及 SSH 批量操作。优化不能牺牲编辑内容、超时反馈、机器身份、Unicode 坐标、撤销和无障碍。测量日志可能包含用户数据，分享前脱敏，不默认入库。

没有测量就不宣称提速。历史数据是带环境的观测，不是永久预算；当前没有统一内存硬阈值。实验和失败证据留在对应 Feature 资料，长期文档只提炼会影响后续行动的约束。

## 人工回归

按修改范围执行，不把所有项目每次都全跑，也不把没有执行写成通过。

| 路径 | 检查结果 |
| --- | --- |
| 项目与 SSH | 本机／远端同名路径隔离，切换、断线、重连和失败不串目标 |
| 停靠与窗口 | 上下／左右组合、跨区移动、关闭、双窗口菜单和焦点，后台 Shell 不重启 |
| 文件与编辑 | 创建／重命名、中文输入、查找、撤销、滚动、保存失败和关闭保护 |
| Git 与 Diff | 工作区／索引／历史、首次提交、特殊路径、失败草稿、两侧滚动及真实写入 |
| Git 外部刷新 | 独立 CLI 修改本机或 SSH 仓库后，前台可见 Git 面板自动更新；隐藏／后台暂停、恢复前台重新读取、失败后手动重试 |
| 共享树 | Files、工作区、暂存和历史一致；窄面板、放大字体、长名称和动作命中 |
| 浏览器 | 表单、滚动、前进后退和重挂载；默认浏览器交接与开发服务 |
| 设置与恢复 | 隔离配置的即时传播、快照和真实重启，区分显示恢复与任务恢复 |
| 通知与命令面板 | 定位原会话、键盘选择和文件实际打开，而非仅收到事件 |
| 视觉、键盘与基础无障碍 | 两种外观、长文案、键盘焦点与动作目标、原生按钮辅助功能名称、不同字体；纯架构改动前后无变化 |

视觉改动使用同窗口尺寸、内容和动作的前后并排录屏；截图和自动检查作为补充，不能把静态图当成焦点、拖动或滚动验收。纯架构重构对受影响区域逐任务对照原生截图和交互，不夹带重设计。VoiceOver 的逐项语音导航与专项焦点适配不作为普遍验收门槛；仅在明确需求涉及屏幕阅读器时单独验收，现有基础无障碍语义仍须保留。

## 提交证据

说明新增／调整了什么测试、实际运行了什么命令、验证了哪些原生与用户路径，以及失败、阻塞和未测部分。与内存、生命周期或性能有关的改动附前后测量；普通文档任务不制造性能数字。

CI 的执行与签名限制见 [release.md](release.md#pr-检查)。报告区分本地验证、Actions、安装、重启和发布；任何一个成功都不能替代其他步骤。

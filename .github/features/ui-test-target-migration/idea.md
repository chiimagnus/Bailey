# Unit Test 与 UI Test 完整分离

## 目标与决定

将 Bailey 的测试分为且只分为两种 Xcode Test Target：

- `BaileyTests`（Unit Testing Bundle）：非界面单元和集成测试。允许 `@testable import Bailey` 验证模型、解析、Git／文件／SSH 后端、快照格式及独立的计算规则；**不得创建原生窗口／视图模拟用户交互、读取 UI 层级、发送鼠标键盘事件，或把 UI 表现断言当成单元测试**。
- `BaileyUITests`（UI Testing Bundle）：通过 `XCUIApplication` 启动真实 Bailey，从用户入口验证 Files、Editor、Diff、Git、Dock、Terminal、Browser、Settings、菜单、弹窗、窗口、焦点、外部文件事件、真实数据结果和可达的视觉／性能行为；不得 `@testable import Bailey` 或直接读取被测 App 的进程内模型。

**迁移行为覆盖，而非机械搬移 Swift 文件。** NativeUI／WorkspaceUI 中纯解析、字节／状态、图布局等断言迁到 `BaileyTests/Unit` 或 `BaileyTests/Integration`；用户可见部分由 `BaileyUITests` 重建。从前需 `NSWindow`／`NSHostingView`／`NSTextView` 直接证明的内部属性，优先用真实输入、AX、截图／录屏、磁盘／Git 结果与进程生命周期证明相应用户不变量，必要时把可纯化的算法另做单元回归。不能不加说明地删除无法直接跨进程读取的保障。

## 范围与起点

- 规划时当前分支：`test/native-xcuitest-layering@019765f`，基于 `origin/main@837ac9c`（2026-10-22）；后续实现先核对最新 HEAD、当前并行修改、可用 OS 与 CI 结果，不能用该 SHA 假装未来基线。
- 源码静态盘点：`BaileyTests/NativeUI` 19 文件、275 个 `test*` 方法；`BaileyTests/WorkspaceUI` 4 文件、54 个方法；**329 个方法需要逐一映射与核销**。`BaileyUITests` 当前 4 个测试文件、10 个方法（另有一个 Support 文件），并非已替代 329 项。`BaileyTests/Unit` 8 文件、75 方法；`Integration` 20 文件、231 方法，亦需扫描隐藏的 UI 操作。
- 额外混合源已确认：`BaileyTests/Integration/Workspace/SessionStoreTests.swift`（10 方法）含生产 `WindowRootView`、`NSWindow`／`NSHostingView` 装配；`BaileyTests/Integration/Settings/AppSettingsTests.swift`（5 方法）涉及 `NSApp` 外观状态但主要验证配置和 Observation，必须按断言行为判断而非见 `AppKit` 即移动。
- [方法级迁移清单](migration-inventory.md)是固定快照：对上述 329 项一条不漏地登记旧入口、预定 task 与迁移去向；执行中逐项填充真实替代用例／非 UI 归属及执行证据，不能只根据新用例总数宣称覆盖。
- 既有 10 条独立 UI 用例须重新在最新产品上实测；过往 CI 对选择器、超长 AX Identifier、Git Graph 历史与宿主焦点曾有失败，不能将先前编译成功等同于 UI 通过。

## 必须保持的契约

1. **零行为退化**：原有用户可观察行为、UI/UX、Accessibility、窗口归属、文件／Git 结果、保存失败保护、SSH 机器隔离、终端／编辑器／浏览器身份、Undo、选区、滚动、原生菜单和快捷键不因迁移而改变。迁移不是顺带实现焦点新功能、改菜单或重写编辑器。
2. **逐方法可追踪**：每一旧 `test*` 必须标记为「真正 UI 路径 → 新 UI 断言」、「纯逻辑 → 单元／集成断言」或「原测试混合 → 两类拆分」。迁移任务必须写明原条件、实际效果、目标用例、替代证据；旧方法所保护的不变量缺证则不能删。
3. **不要制造测试后门**：仅在现有控件缺少稳定 AX 语义时，经过真实 UI 语义核对后添加适度标识；不添加生产启动时跑测试、以 `--isolated-ui-test` 绕过业务逻辑、测试专用伪结果或额外隐藏控制页面。稳定 Identifier 不含沙盒绝对路径，不以长 sleep／无条件 retry／跳过用例制造绿色。
4. **测试真实副作用**：XCUITest 核对保存后的文件字节、Git status/index/HEAD、界面可见数据、目标窗口与真实键盘结果，以及窗口关闭／重开后的内容；夹具证明初始分支、冲突状态、权限、符号链接、文件编码和失败触发条件确实成立。
5. **安全隔离**：测试本机用户的正式 `/Applications/Bailey.app` 运行时，不调用 `XCUIApplication.launch()` 或结束同 Bundle ID 进程。自动 GUI 回归只在专用 CI GUI Runner／获准的独立会话执行；本机可安全用 `make build:ui` 编译。`--isolated-ui-test` 隔离快照和历史，**没有隔离常规设置、Bundle ID 或桌面**；涉及设置、持久化、跨进程恢复须先验证隔离路径与正确性。
6. **旧套件逐组删除**：在相关任务中完成 E2E／纯逻辑的替代与 Red→Green（适用时）后，同任务删除原 `NativeUI`／`WorkspaceUI` 文件或已替代方法以及失效的测试夹具；不保留并行双轨，也不在覆盖未完成时提前删除。项目当前另有的 UI 夹杂须同样归正。
7. **测试入口清晰**：`make test`／`make test:类名1,类名2` 只跑非 UI；`make test:ui` 跑 UI Test。按现有 `Makefile`、`Bailey.xcodeproj`、`Bailey`／`Bailey-UI` Scheme 与 `.github/workflows/ci.yml` 改动，不建立第三个 Test Target 或新的测试系统。CI 每次 PR 的 UI/非 UI 语义必须明确，保证完整 gate 不被增量选择或跳过掩盖。

## 非目标

- 在**规划这一轮**执行测试迁移、产品构建、真实 UI 自动化、修改正式 App、提交／合并 PR；只产生本地 Feature 计划与任务状态。
- 将所有 329 个方法机械地转成 329 个 XCUITest 方法；归属与断言强度比数量更重要，但**所有 329 个原始保障必须核销**。
- 为追求两种目录名而去掉非 UI 集成测试、Git 命令失败回归、TextKit 文本坐标纯逻辑或安全输入校验。
- 创造第二个 App Bundle ID、收费云设备、独立 Window/Focus mock 框架、永远不会触发的恢复状态；也不借测试迁移修改正常用户操作逻辑。
- 在未获授权的 Windows／SSH 主机上操作真实仓库，或强制终止／重新安装用户当前 Bailey。

## 验收门槛

1. **方法级完整性**：方法盘点在迁移开始与结束各重新生成一遍（包括方法增删、重命名、测试发现）；清单全部拥有实际去向、替代断言、已验证结果。特别检查 `NativeUI` 275 + `WorkspaceUI` 54、`SessionStoreTests` 等藏于 Integration 的原生 GUI 测试，以及 `BaileyUITests` 原有 10 项；原始 329 条不能无理由消失。
2. **目标隔离**：`BaileyTests/NativeUI` 和 `BaileyTests/WorkspaceUI` 已不存在，所有遗留非 UI 方法在 Unit/Integration；对整个 `BaileyTests` 审计，确认没有宿主窗口、SwiftUI 交互装配、鼠标键盘注入或 UI 像素断言。`BaileyUITests` 不直接导入被测 App 类型，Xcode `-only-testing` 可分别选择各目标，实际发现的数量与静态 inventory 可解释地对应。
3. **全链路验收**：分别执行 `make test`、`make test:ui`，按项目签名／构建要求核对完整退出状态、失败／跳过、CI Job 与本地可安全执行的针对性用例。关键 E2E 覆盖真实 App 输入到持久化／Git 结果，不能靠单位测试绿色。
4. **最大全适用覆盖**：实施前逐域检查下述所有可达条件及安全可执行组合；不能因为典型路径通过就主动忽略可行的边界测试。每个无法实测的环境或操作逐项记录原因、已取得的替代证据、影响、补验条件与是否阻塞完整验收。
5. **零迁移残留**：测试类引用、文件路径、`@testable`、旧 Scheme／CI 选择、Makefile 帮助、`AGENTS.md`、`docs/testing.md`、`docs/release.md`、`docs/development.md`、`CONTRIBUTING.md` 相关入口保持一致；产品代码只允许证据充分的 AX/测试隔离修正；全部不相关产品行为不变。

### 全条件核对范围（执行前逐项展开，非抽样上限）

| 维度 | 必须涵盖的适用状态与最终验证 |
| --- | --- |
| 工具链与系统 | 项目最低 macOS 15.6、当前可用 macOS 与 CI Xcode 27；Debug／Release、签名／无签名、测试宿主／独立 Runner；实际运行能力与编译支持分别说明 |
| 外观与语言 | 系统／浅／深主题、中文／英文／系统跟随、字体／面板缩放上下限、窗口最窄／典型／宽、Retina 等可用显示缩放、动态外观变化 |
| 输入与可访问性 | 鼠标单／双／右击、点击空白与边缘、拖放、滚动／横滚、Tab／方向／Space／Return／Escape／快捷键、中文 IME composition、emoji／组合字符、原生文本输入/Undo/Redo 与实际 AX |
| 编辑器／Diff | 空／只读／二进制／非法 UTF-8／Unicode／CRLF／裸 CR／大文件（已存在的十万行场景）、多光标、超长行／跳转／滚动、语法颜色、Tab／分屏、文件不存在／改名／链接／容量阈值、保存成功／失败／重试与并发编辑 |
| Git | 空／未初始化／有历史仓库、无变更／已暂存／未暂存／冲突、branch/tag/stash/worktree／remote、Git Graph 颜色／拓扑／菜单／键盘、实做 add/reset/commit/rebase 的最终 index/HEAD，二进制／大 blob／SHA-256／特殊路径／旧引用、取消／目标变化／失败恢复 |
| 项目／窗口 | 0／1／多窗口、首次启动／已保存恢复、当前／后台项目、层叠 Dock、分屏／移动／关闭／重新挂载、文件拖入／Finder 批量、晚到事件、命令面板与各种 Sheet 焦点交接、重启之后不复制／丢失文档 |
| 终端／浏览器 | Shell 会话/PID 与 Scrollback 保持、Find 和终端键盘、WebView 表单／导航／历史、浮层／JavaScript 原生弹窗、不同组切换和恢复后身份不变 |
| 连接与故障 | 本机及获准 SSH、未连接／断连／重连／延迟／交错回调、同名不同机器路径、权限／读写错误、取消／重试、资源释放／内存回落，不能误写或删除用户数据 |
| 容量与组合 | 空、单条、重复批次、千级文件或历史、数万行／十万行、长路径／特殊字符及超过 AX 限制的路径、50+ 文件事件／64+ 排队、最小和超限输入；对可承受组合尽量穷举，不能无限组合时先覆盖全部维度与极端，再扩展两两、多因素与已知故障交互 |

**未具备的实机与授权边界**：当前机器不能代替 macOS 15.6 真机、物理触控板、所有显示设备或未经授权的 Windows SSH 主机。先安排现有 runner/夹具可验证的范围；其余有具体补验任务和阻塞标记，**不以 CI 绿色宣布全条件验收**。这些限制不授权修改系统全局设置或访问用户私有资源。

## 任务与来源

- [全方法基线与去向](migration-inventory.md)：本次一次性执行核销清单，不另作实时状态机。
- [P1 清点、可行性和隔离执行基础](plan-p1.md) · [P2 编辑器与 Diff](plan-p2.md) · [P3 Git 界面](plan-p3.md) · [P4 工作区和窗口](plan-p4.md) · [P5 入口一致性与最终验收](plan-p5.md)。
- 实时状态仅 [todo.toml](todo.toml)，审计由阶段实际执行后生成，不在规划阶段预建。
- 当前产品契约以 `docs/testing.md`、`docs/ui.md`、`docs/architecture.md` 和各 `docs/features/*.md` 为准。本文描述**迁移要求**，不宣称该分层已经完成。

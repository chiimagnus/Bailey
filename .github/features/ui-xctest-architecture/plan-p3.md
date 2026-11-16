# P3｜让单 Runner 的完整 GUI 验收更快、可诊断且不丢覆盖

**交付：** 以现有 XCTest／XCResult 的真实时间与失败证据，
核销所有已改变的测试归属并完成单 GUI Runner 的完整验收。
不重新实现 Runner、测试枚举器或 CI 指标系统；只有已测出仍多余的公共测试夹具代码才在其任务内清理。

## 方案与执行边界

当前 `.github/workflows/ci-ui-test.yml` 以显式 `ci-ui-*` Tag
在两个独立 `xcode-27` Job 上分别调用 `make test` 和 `make test:ui`。
`Bailey-UI.xcscheme` 中 UI Target 为 `parallelizable="NO"`，
符合一套真实图形会话独占键盘焦点的约束。
`Makefile` 的 `ONLY_TESTING` 使用 Xcode 原生枚举预检查，
不能把未发现、跳过或取消的测试报告成已执行。
CI 仅在 XCTest 成功后运行 `Inspect XCTest results`，失败时仍始终上传 XCResult；
已有 Xcode 控制台每方法时间和错误、XCResult 及 GitHub Job step 时间。
**先利用现有证据**，确认真实缺口后才考虑最小 CI 改动。

旧 Actions #43720420544 是**被取消的部分样本**：136 项已结束、
3 项失败、方法耗时合计 55.8 分钟，不能直接外推完整测试时长。
对比应固定同一 Xcode 27.2、macOS Runner 类型、App 变体、完整测试发现结果，
区分 Xcode 构建、UI XCTest 执行、诊断压缩上传和整条 CI 关键路径。
部分新 UI 还未完成时，不把 Host 新运行通过冒充完整 GUI 验收。

P1／P2 **各自**完成「确认原断言 → 充分现有宿主证据或新增必要断言
→ 保留真实 App 接线 → 删除重复 AX 查询／旧 helper → 定点运行」；
**P3 不再承担迁移或统一清理。**
不得通过巨型测试方法、关闭 XCTest idle 同步、
跨方法复用进程、弱化断言或增加 Runner 来制造提速。

## 任务

<a id="p3-t1"></a>
### P3-T1｜核对并精简公共 UI 启动器实际不再使用的分支

- **位置：** `BaileyUITests/Support/WorkspaceUITestSupport.swift`
  的 `Session`／`launch`／`finishSession`、
  `UITestSessionObserver`、`WorkspaceUITestFixture`；
  `BaileyUITests/Workspace/WorkspaceSmokeUITests.swift` 的
  `testRepeatedLaunchDoesNotResetTheCurrentTestProject`；
  该文件所有当前调用方（含 P1／P2 已修改的方法）。
- **实施：** 在 P1／P2 各自完成旧用例和专用 helper 清理之后，
  枚举**公共**辅助函数的实际调用者，删除确无调用的成员、
  旧启动前提或迁移后不再可达的兼容路径。
  `Session.owner` 并不是旧跨用例共享机制：它使同一 XCTest 方法
  第二次 `launch` 保持原 App，已有 Smoke 用例会验证，必须保留。
  `UITestSessionObserver` 是 bundle 生命周期后的清理后备；
  只有证明异常退出后的清理不再需要或有等效保证，才允许简化。
  `HOME`、`CFFIXED_USER_HOME`、`ZDOTDIR`、
  独立 Bundle ID／Run ID、项目路径归属检查、
  真正可执行 Git、Clipboard／IME 与 Unicode Hex 的恢复、
  真实 SSH 隔离目录和拒绝附着未知 App 都承担已证实的保护。
  **不能按「防护很多」机械删除。**
  启动失败时要验证当前 teardown 是否仍清理 fixture／子进程；
  只有确认缺陷后才修其直接所有者，不新增另一个通用清理管理器。
- **判据：** 同一测试方法的第二次 `launch` 保留项目；
  下一方法仍完全隔离、老 App 无法被偷偷接管；
  启动／中断后临时目录、输入法与剪贴板按原意恢复，
  用户真实目录、SSH 和正式 Bailey 不被触及。
  删除确证无消费的共享 helper 与残余测试代码，
  保持 `make build:ui` 和相关 Smoke／Files／Git 定点 UI 通过；
  不重复清理 P1／P2 已各自归属的用例。

<a id="p3-t2"></a>
### P3-T2｜复用现有 XCResult／CI 证据，明确失败与性能耗时

- **位置：** `.github/workflows/ci-ui-test.yml` 的两个 Job
  与 `Inspect XCTest results`／`Pack XCTest diagnostics`；
  `Makefile` 的 `test`／`test:ui`／`SELECTED_TESTS_PREFLIGHT`；
  `Bailey.xcodeproj/xcshareddata/xcschemes/Bailey-UI.xcscheme`。
- **实施：** 对完整与取消运行分别使用现成的
  XCTest 控制台方法日志、`xcresulttool` summary、
  GitHub Step 时间和已有 XCResult 附件；
  核对执行数、通过／失败／环境性跳过、单方法耗时、
  构建 vs 运行 vs 打包上传的独立耗时。
  **只有如果现有 XCResult 失败时确实不足以判断原因**，
  才在原 `Inspect XCTest results` 的执行条件／输出上作最小修改；
  不新建 Python 日志工具、第二套结果 schema 或失败后的自动重试。
  原生 `ONLY_TESTING` 枚举不得出现空集合假通过。
  `ci-ui-*` Tag 仍跑完整 Host＋UI，手动选择仍可用于定点，
  UI 仍只用一个 Runner；需要真实 Git 历史的用例维持 `fetch-depth: 0`。
  若仅使用既有日志便足够，则**不改 Workflow、Makefile、Scheme**。
- **判据：** 原始工作流的 136 完成／3 失败／1 未完，
  不被误报为完整回归；错误选择确实拒绝执行，
  真正失败不因报表脚本退出零而变绿；
  授权 SSH／系统外观／非 Zoom 等 `XCTSkip` 的具体环境原因可读，
  但统计上不当成通过；取消后附件是否存在如实报告。
  同一代码、系统、签名、Runner 类型比较单项或阶段实际耗时，
  不把两次不同源版本的 CI 相减冒充确定性能提升。

<a id="p3-t3"></a>
### P3-T3｜执行 Host／UI 全量和真实用户路径，报告可比耗时

- **位置：** `Makefile`、
  `Bailey.xcodeproj/xcshareddata/xcschemes/Bailey-UI.xcscheme`、
  `docs/testing.md` 与现有 Host／UI Target。
- **实施：** 先确认被改动的宿主和真实 GUI 方法能由 Xcode
  正确发现；按 P1／P2 当次修改的测试类逐项定点运行，
  然后执行完整 `make test`、`make build:ui` 与
  独立 GUI 的完整 `make test:ui`。
  如果 P1／P2 确实需要修产品缺陷，按
  [测试完成标准](../../../docs/testing.md#完成标准)
  增加 `make build`；触及发布／依赖才额外跑 Release 构建，
  **纯测试迁移不机械运行无关发布流程**。
  真实云端完整 UI 使用现有 `ci-ui-*` Tag（推送／触发需相应授权）；
  本地不可独占 GUI 时不抢占用户桌面。
  先定点复验旧 CI 三失败：Git 分隔条、
  三组标题栏双击、中文菜单快捷键；
  实测究竟是生产缺陷、CI 环境还是测试不合理前提。
  记录相同 macOS Runner／Xcode／签名／提交的
  Host 执行、UI 执行、构建和 CI 关键路径。
  可比较的旧完整基线缺失时，先使用已知的逐方法耗时，
  不捏造旧全套耗时和百分比。
- **判据：** 相同修订完整 Host／UI 实际执行，
  方法发现数、错误、跳过和最终 Git／文件／窗口效果均可核对；
  三个旧失败有明确原因和真实 Red→Green 或记录环境阻塞。
  **性能以同环境的实际减少和覆盖不退步为成功条件**，
  不把此前推测的 30 分钟设为强制门槛。
  如果单项需要 40 次真实键盘滚动等不可省略动作，
  保留并说明实际成本，不凭测试总数减少来宣称完成。

<a id="p3-t4"></a>
### P3-T4｜复核覆盖与文档，交付实际验证结果

- **位置：** [docs/testing.md](../../../docs/testing.md)、
  [docs/release.md](../../../docs/release.md)；
  P1／P2 任务已同步的 [Git](../../../docs/features/git.md)、
  [Files](../../../docs/features/files.md)、
  [Dock](../../../docs/features/dock.md)、
  [编辑器](../../../docs/features/editor.md) 与
  [会话恢复](../../../docs/features/session-restore.md)；
  本 Feature `todo.toml`。
- **实施：** 不再修改测试源码或进行统一「最终清理」。
  仅对照 P1-T1 的一次性清点结果核实：
  每个实际删除／收短的断言已在**所属任务**得到宿主或剩余 GUI 证据；
  未修改的测试仍在 Xcode 可发现集合中；
  共享 helper 的清理已在 P3-T1 核销。
  按 CI macOS／本机系统、Apple Development／ad-hoc、
  独立 GUI console、远端 Windows SSH、系统主题和 Zoom 设置
  如实列出执行／失败／跳过／不可执行条件与补验入口，
  **不把正常环境性 skip 变成新增红测，也不算成通过**。
  文档只维护本次真正更改的长期测试规则和入口，
  历史审计记录不作为本次设计真源，不创建新的测试清单／审计状态表。
  所有迁移任务已分别删除无用代码，本任务禁止推迟任何代码债。
- **判据：** `docs/testing.md`、Makefile、Scheme、
  Workflow 和实际执行方法一致；不存在两份永久责任矩阵、
  过度防护或已经无消费的测试 helper。
  宿主、真实 App 与已获授权远端的结果分别陈述；
  若有必要的 GUI 条件无法验收，不宣布无保留 Go。
  实际耗时与用例覆盖可审查，而不是只报告“绿色”。

## 最终验收全集

| 层面 | 实际必须覆盖的条件与组合 | 完成判断 |
| --- | --- | --- |
| 构建／发现 | Xcode 27.2／现行本机工具链，Apple Development／CI ad-hoc，完整／精确选测、空选择与错误选择；一致 Git 提交、完整历史 | `make build:dev`、`make test`、`make build:ui` 与 `make test:ui` 命令成功且 >0 方法；选择失败不能变绿 |
| 宿主行为 | 真实 Git 各类 Ref／Index／Worktree、原始字节、常见及极端编码、原生 Dock／树／TextKit、中文／英文及主题边界；多窗口、失败恢复 | 不同测试层共用正确生产代码，所有原始断言有实际运行的等效替代 |
| 完整前台 | 冷启动、真实菜单／Sheet、命令路由、AX、键盘、Finder／Dock 拖放、窗口缩放／关闭／重启、Ghostty PTY、WebKit 表单和文件交付 | 对 Bailey Dev 做真实动作，检查屏幕／窗口及磁盘／Shell／Git 的最终结果 |
| 系统／远端 | 独立 macOS GUI 登录会话、窗口和剪贴板权限、已授权 Windows SSH、真实网络失败／重连、系统明暗自动切换 | 可执行条件逐一核销，受环境阻塞的条件按方法记账；关键未测不报全绿 |
| 错误／并发 | 文件或 Git 外部修改、丢失权限、取消、失效窗口/连接/仓库身份、重复输入、冲突 Ref、多批次刷新、测试中断和恢复 | 无跨项目误写、无用户状态污染，诊断反映真实失败且允许安全重跑 |
| 规模／性能 | 0／极大输入、12／33 引用、150／420 pt、9／18 pt、10k／100k 行、32MiB、多窗／多标签、冷热启动与 30 次操作循环 | 数据／组件极端由宿主广覆盖、真 GUI 交互仍执行；分别记录执行时长和关键路径 |

**验收顺序：** 先逐方法替代证据与旧失败 Red→Green，
再受影响宿主类及真实 GUI 方法，
然后完整 Host／UI、签名与独立环境验收；
最后对照基线、核销所有已识别的环境／输入／故障／时序及关键组合。
用户正式 Bailey 不启动、不退出、不替换、不使用其 SSH master。
由于当前只编写计划，**本阶段没有运行构建或自动测试**，
以上是后续实施时必须实际核销的结果，不是已通过的声明。

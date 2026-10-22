# Plan P5 — 目标纯度、CI 契约与完整验收 Gate

**Goal:** 在 P1–P4 各类测试已逐项替代且当场删除旧路径的前提下，检查 Xcode Test Target 只剩「非 UI」和「真实 App UI」两种职责，确保 Makefile、CI、文档与实际执行一致，并用最终方法级审计证明迁移无遗漏。

**Non-goals:** 不把以前没有验证过的产品新功能伪装成测试迁移结果；不为了测试数量制造无意义用例；不重新组织无关的应用模块或增设第三个 Xcode Test Target。**本阶段不是集中删除旧测试的补救阶段**：旧类必须已由 P2–P4 的负责 task 当场清理。

**Approach:** 按 `migration-inventory.md` 校对原旧方法、新套件和保留的非 UI 断言的真实实现，以 Xcode 发现的运行集合作为最终依据。沿已有 `Makefile`、`Bailey.xcscheme`／`Bailey-UI.xcscheme`、`.github/workflows/ci.yml` 执行，不另建 shell 测试 runner 或自维护的第二份 CI 类名名单。把变更契约归唯一 owner `docs/testing.md`，CI 与构建说明只在相应页面维护。

**Acceptance:**
- Xcode 工程恰有已存在的 `BaileyTests` 与 `BaileyUITests` 两个 Test Target，前者实际只含 Unit/Integration 非 UI 方法，后者独立启动真实 App 而不 `@testable import Bailey`；`NativeUI`、`WorkspaceUI` 及它们的失效引用不存在。
- 原始 329 条逐行核销，新测试的行为不变量与已确认的边界有原始输入／真实用户操作／最终结果的证据；原有 `BaileyUITests` 10 条未被意外删除或空转。另 306 个原 Unit/Integration 方法与混入的 SessionStore 2 项经过审计且去向正确。
- 日常命令 `make test` 和 `make test:多个类名` 不启动 UI 图形自动化；`make test:ui` 真正运行完整 App UI，并保留对正式 Bailey 的保护；独立 CI GUI Runner 与必要的全量 gate 不得空跑/跳过。
- 所有可安全执行的适用环境、条件、异常和边界尽最大能力实际验收；关键范围缺证保留为 No-Go，不宣称完工。Debug/Release 构建、签名、全套测试的退出状态均如实记录。

**Rules:** 编译与测试行为必须来源于现行 Makefile/Scheme；CI 的增量选择不能隐藏原生 UI；`AGENTS.md` 简述约束并链接 `docs/testing.md`，不复制第二张测试矩阵。测试过程不污染用户设置/工作树，不操作其正式 App 实例。

---

<a id="p5-t1"></a>

## P5-T1 统一工程、命令、CI 和维护文档的分层契约

**Files/anchors:** `Bailey.xcodeproj/project.pbxproj`、`Bailey.xcodeproj/xcshareddata/xcschemes/{Bailey,Bailey-UI}.xcscheme`、`Makefile`、`.github/workflows/ci.yml`、`docs/testing.md`、`docs/release.md`、`docs/development.md`、`AGENTS.md`、`CONTRIBUTING.md`；只更新因迁移不再准确的实际内容。

**Step 1 — 核对唯一机械源：**
- 检查 `BaileyTests` 实际 target member 和 build setting，不能因 `PBXFileSystemSynchronizedRootGroup` 自动发现漏掉迁入类；核对 `Bailey` Scheme 不含 UI suite、`Bailey-UI` 只含独立 UI suite，`@testable import Bailey` 不出现在 UI Test 源码。
- 审计 `BaileyTests` 现有 `TEST_HOST` 是否纯逻辑仍必需：没有产品独立模块可导入的真实证据前，不为了名称好看强制去掉 host；职责清晰优先于无关重构。但宿主测试不得依赖前台/键鼠/渲染才能通过，且不能触碰正式 App。
- 校对 `make test`、`make test:类名1,类名2,...`、`make build:ui` 和 `make test:ui` 的实际命令；定点运行多个类与测试 suite 识别要以 Xcode 结果证实，不允许文档中只写支持但执行失败。
- 审核 CI 的 `build`／`ui` Job：非 draft、首次 PR、同步、ready_for_review、标记 `ci/full`、仅 Markdown、同一 branch rebase 的增量选择和回退至全量逻辑；UI Job 必须被真实执行，不能因 `paths-ignore` 或 skipped status 被误算成通过。避免在多份 workflow/Makefile 维护重复测试清单，失败发生在真正控制源处修复。

**Step 2 — 最小同步：**
- 若 Scheme、target ID、构建设置、CI 条件有现实错误，只作确保两个执行入口正确的最小改动；不新增空 Target，不复制测试文件到两套。必要的签名配置兼容原有 free Apple Developer + CI ad hoc 路径。
- 更新 `docs/testing.md` 的「两层职责、目录、测试选择、完整性 Gate、隔离条件、E2E 的限制」；`docs/release.md` 只维护 CI 实际执行条件；`docs/development.md` 只维护 Makefile/构建；`AGENTS.md` 只短标必须遵守的入口；`CONTRIBUTING.md` 有现行执行指引才同步。检查全部旧 `NativeUI`／`WorkspaceUI` 引用、文档导航与链接，不将旧基线数量永久写进长期文档。
- 本阶段不作为旧测试搬迁的临时收尾；若发现 P2–P4 未迁或已删错，当即回到负责 task 修正并重新验证，不集中偷删。

**Step 3 — 验证：**
- 静态：`git diff --check`、Xcode schemes/targets 列表、代码全文 UI 操作禁入 `BaileyTests` 的人工+自动检查、每类测试实际发现和 `Makefile` dry-run。
- 运行：独立非 UI 定点与全量测试、独立 UI target 编译/完整 CI GUI 运行、CI 事件分支上的实际 Job 和退出码，确认 docs 与运行行为逐条对应。纯文档提交不冒充测试通过。
- Coverage：单类/多个类/不存在类、初次/重跑/同步/merge-base rebase/变更仅 CI 或仅 docs、Draft/ready、CI 运行与跳过、签名成功/失败、用户 Bailey 正在运行时拒绝 GUI 启动，专用 Runner 与本地没有 GUI 的行为。
- Uncovered：真实 GitHub branch protection 和未授权更改的远端管理设置不在本 task 修改范围；若平台规则影响必须另记 gate 状态与补验，不可绕过 PR 检查。
- **Commit boundary:** 只含 Target/Makefile/CI/文档必要更正与相应验证，不把其它迁移延后集中清理。

<a id="p5-t2"></a>

## P5-T2 全 329 方法与全环境组合独立验收并给出 Go/No-Go

**Files:** `migration-inventory.md`（填具名替代方法/非 UI 类、证据、原缺口）、`todo.toml` 由 `feature_tool.py` 维护 task 真状态；阶段审计完成后生成 `audit-p5.md`。测试源与产品仅在发现问题时返回对应 P1–P4 修复，不在这里新建第二套测试框架。

**Step 1 — 建立最后的实际集合：**
- 对原始规划 SHA 的 **329** 条方法运行完整核销：每条必须有①原不变量，②最终 UI method/非 UI method 及其独立目录归属，③真正测试通过的命令、环境、日志或附件，④旧方法被删除的差异证据；拆分为双层的两端必须均成立。某个新 UI 用例可对应多条旧测试，但须逐条证明差异边界（例如丢失了异常状态则算未完成）。
- 对 `BaileyTests/Unit` 75 与 `Integration` 231 的旧方法复核：没有旧 UI 代码混入、动态发现集合和目标数量准确；`SessionStoreTests` 的原生窗口两项确实被替代，其余快照算法安全保留。
- 原有 10 条 `BaileyUITests` E2E 在当前 Xcode / main 上确认确实执行、正常失败时有有效诊断，且用户工作区无副作用；新增 suites 的文件注册、AX IDs、数据夹具、teardown、隔离均覆盖。若原始清单后因并行 PR 改变，比较旧/新 source manifests，补全所有新增/重命名方法。
- 检查整个 repo 对 `BaileyTests/NativeUI`、`BaileyTests/WorkspaceUI`、旧 Swift 类／host test helpers 的活跃引用和工具构建成员，测试 bundle 目录与旧挂载不再存在；不存在被隐藏的 `XCTSkip`／`-skip-testing`／新禁用测试。

**Step 2 — 运行完整 Gate：**
- 非 UI：`make test SIGNING=adhoc` 完整 Xcode TestAction，所有归属非 UI 的模型/业务/恢复条件真实通过，附 `codesign` 后置验签成功及退出码；专用 GUI：`make test:ui SIGNING=adhoc` 在**可安全使用同 Bundle ID 的专用 Runner** 完整运行，给出 discovered / passed / failed / skipped 与 `xcresult`。
- 构建：`make build:ui SIGNING=adhoc`、`make build:release SIGNING=adhoc`，如有现行 Debug 验签额外条件照 `docs/testing.md` 执行；编译、签名与真实 E2E 分层陈述，不以其一代替另一。
- 数据结果：文件 bytes/mtime/脏缓冲/回退、Git index/HEAD/refs/工作树、真实窗口/Pane/焦点/滚动/Undo/图谱/菜单行为、终端/WebKit 内容与释放、SessionStore 跨重启、配置信息隔离；不要只证明 UI element exists 或后台 mock 已被调用。
- 按 `idea.md` 全条件表逐项执行受影响的可用环境：支持的 macOS/SDK、Debug/Release、浅深中文英文、多窗/窄宽/分屏、键盘鼠标IME、容量极值、长路径和特殊字符、签名权限、错误/恢复/取消/过期、时间交错、已知历史失败复现、真实远端（只在获准时）；组合数量可承受时穷举，扩大两两及高因素交互，绝不主动裁减单项可测条件。
- 独立复核数据污染/用户保护：不访问默认配置目录以外的用户隐私数据；所有操作针对唯一 fixture；UI 运行不终止/重启/覆盖正在使用的正式 App；失败后的遗留临时文件与测试实例清理须有明确归属和证据。

**Step 3 — 审计 Gate 与交付：**
- **Go**：329 全部核销、旧 UI suite 0 残留、两个 Target 分层纯净、当前 Runner 的相关完整测试及 CI 真实执行通过、UI/UX 没有未解释偏差、所有已识别可安全执行条件和可行组合均测到且留证；最低系统／获准 SSH／物理设备等适用但缺证项按照项目强制规则决定是否阻塞**完整验收**。
- **No-Go**：只要旧方法没有等价断言、E2E 核心用户动作无数据结果、运行器/环境 skip、超长路径/AX/原生像素/IME 不可验证却删除旧测试、正式 App 安全不确定、CI skipped，均不能将本 feature 标记 completed。整理具体阻塞原因、尝试、替代证据、影响、补验环境和回到哪一任务修正。
- 文档及用户汇报明确已完成的层次、真实测试命令/退出状态、未实测影响范围与下一步。旧历史 PR 和本 Feature 计划文档本身遵循默认本地/历史记录保留政策，未授权不强推/合并。

---

## Phase Audit

`executing-plans` 完成 P5 tasks 后生成并审计 `audit-p5.md`，对照原 `idea.md` 和方法清单做独立覆盖校核。**全绿 ≠ 全迁移**：只有真实后果、方法级迁移、所有已识别可测条件和未能执行场景的精确 Gate 一并闭环，才能对外宣称完成。

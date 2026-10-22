# Plan P5 — 两个 Test Target 的最终核销

**Goal:** 不再次搬代码，而是验证 P1–P4 已完成的行为迁移、旧测试清理、CI/Makefile 运行分层以及完整产品验收。**发现缺口应回到首次拥有该行为的 task 修复，不在最后补一批兼容测试或清理旧文件。**

**Non-goals:** 不增加第三个 Test Target、另建 CI 选择脚本/Runner、重构生产模块、强行删除仍承担安全或旧快照语义的代码。Docs/CI 变更均已要求在对应 P2–P4 task 当场同步，P5 不建立第二份维护机制。

**Approach:** 以 `migration-inventory.md` 的每条旧保障 → 当前 UI/非 UI 断言 → 实际执行证据为审查链；以 `Bailey.xcodeproj`、两份 Scheme、`Makefile`、`.github/workflows/ci.yml` 的真实执行结果为机械事实。XCUITest 必须由专用 GUI Runner 启动 App，`BaileyTests` 只能保留逻辑/集成，不再以原生窗口模拟用户交互。

**Acceptance:**
- 原有 329 条逐项核销，另 306 条 Unit/Integration（含 `SessionStoreTests` 2 条 UI 混入）重新核对；原 10 条 UI Test 与新增用例均有实际执行/失败证据。Xcode 真正发现的测试方法集合无非预期空项或禁用。
- `BaileyTests/NativeUI`、`BaileyTests/WorkspaceUI` 已不存在；所有测试专属旧窗口/鼠标注入/helper、CI 中旧类名、当前文档中的旧执行入口在**相应领域 task** 已同步移除；`BaileyUITests` 不直接 `@testable import Bailey`。
- `make test` 和 `make test:类名1,类名2` 不触发 XCUITest；`make test:ui` 在独立会话验证 App 原生界面，保留对用户正式 Bailey 同 Bundle ID 的保护。必要的 App 宿主 `TEST_HOST` 可以保留；“Unit Test”不意味着为了名字好看拆卸 App 可见类型所在的编译模块。
- 受影响用户行为零退化；条件覆盖遵循 `idea.md` 的全部可行环境/异常/极端组合，不能因为 XCTest 通过就隐藏 IME、最低系统、SSH、视觉、Finder 等真实限制。CI 若是 draft/docs-only 事件按现行条件合法 skipped，不能算已运行的 Go 证据。

**Rules:** 清理只删除被有效替代的测试代码及无消费的辅助路径，不删除 `SessionStore.localFile`、`BaileyInstanceMode`、未保存内容保护、SSH 机器隔离或用户配置兼容语义。构建/验签不等于 E2E；真实配置测试只能在独立账户/CI 用户运行。

---

<a id="p5-t1"></a>

## P5-T1 全方法、运行入口与最终 Go/No-Go 核销

**Files/anchors:** `migration-inventory.md`、`idea.md`、`todo.toml`、`Bailey.xcodeproj/project.pbxproj`、`Bailey.xcodeproj/xcshareddata/xcschemes/{Bailey,Bailey-UI}.xcscheme`、`Makefile`、`.github/workflows/ci.yml`；长期验证规范由 `docs/testing.md` 维护，贡献入口 `AGENTS.md`、`CONTRIBUTING.md`，CI 事实归 `docs/release.md`。本任务主要核查，不留到最后才删除旧测试/改掉过时规则。

**Step 1 — 源码及方法双向核销：**
1. 对照 plan 起点 `019765f` 的 329 条 `Class.testMethod`，确认每条在 `migration-inventory.md` 有原断言、目标 UI/非 UI 新方法、前置数据、实际最终结果、真实执行状态，以及当场删除原方法的变更证据。不能以新方法总数等于 329 作为通过，也不能多个方法对应同一空断言就算覆盖。每项差异先回原 task 补齐。
2. 重新清点 `BaileyTests/Unit` 的原 75 与 `Integration` 原 231 条测试（后续重命名/分拆要与当前 Xcode 发现匹配）；重点核对 `SessionStoreTests` 真实窗口两项已被替代，其他应用快照/SSH 本机路径仍保持数据兼容与安全。任何仍创建原生 View/Window、发真实鼠标键盘或断言像素的原低层测试必须返还 P1-T3/P2–P4 清理，而不能在这里偷删。
3. 检查 `BaileyUITests` 仍执行启动/命令面板、Files/保存、Git、Settings/多窗既有 10 条，新增控件查询能区分两目录同名和 Files/Git 共享 ID；确认未引入隐藏测试控件、第二个 App Bundle ID、旧方法的残留 UI 宿主/后门、`XCTSkip` 掩盖核心故障。
4. 对比迁移开始与当前源文件清单、Xcode Target members、build products、方法列表及活跃引用；查 `ci.yml` 中 `Bailey/Editor/*`、`Bailey/Git/Diff*` 的已删除类名，`Makefile` 帮助、`docs/testing.md`／功能文档／PR 模板中的失效层次。真正需要更新时回相关 task 同步，不设全仓额外配置/脚本。

**Step 2 — 真实命令与 CI 证明：**
1. Xcode Scheme 实际包含现有 `BaileyTests`、`BaileyUITests`，`make test:FileTreeTests,GitStatusModelTests` 能按要求发现多个真实非 UI 类；`make build:ui SIGNING=adhoc` 只编译不启动；`make test SIGNING=adhoc` 的完整 TestAction **及 codesign 后置检查**退出为 0。不存在类名、错误 target 等不能被假成功吞掉。
2. 专用 CI GUI Runner 执行 `make test:ui SIGNING=adhoc`，记录 xcodebuild/xcresult 中发现、运行、passed/failed/skipped、真实窗口状态、附件与退出码；另覆盖同步/draft→ready 等本次相关 CI 入口。对每个 `-only-testing` 目标核对**真实发现且运行的类和方法**，无效/过时类名不得得到假成功。草稿或 Markdown-only 合法 skipped 和已实际运行是不同事实；Go 必须具有明确成功的非 Draft UI Job 和必要宿主全量 Job。
3. 对比真实环境：当前 PR 的 `.github/workflows/ci.yml` 使用 `xcode-27`，发布 `.github/workflows/release.yml` 使用 `macos-26` + `Xcode_26.6.app`，本机为 Xcode 27.2；不能因 PR 下两个 Target 通过就认定 Tag 阶段的 App/宿主 TestAction 与 Release 构建可用。至少读取两条工作流对应 Head/Tag 的真实构建日志并核对版本兼容；若已有发布构建障碍，归 CI/发布所有者修根因，不顺便无依据更换 Runner/新增测试体系。
4. 在无共享用户副作用的环境核对 App UI 最终文件 bytes、Git index/HEAD/refs、主窗口/组归属、Palette 原生按键、Finder 分区接收、Git Graph 视觉/菜单、编辑器/终端/浏览器身份、保存否决及跨启动恢复。对需要内存/真实 IME/物理设备/远端测试的状态，用关联领域任务的原始证据判定，不新写空泛“做过”的报告。
5. Debug/Release 构建与签名按照 `docs/testing.md` 的实际相关门槛执行；macOS 最低 15.6、当前系统、CI、浅深主题、中文英文、窗口尺寸/触控与长输入、失败重试、连接及窗口时序组合按 `idea.md` 的适用条件最大可行覆盖。确实无法安全执行的环境逐项记录缺口、尝试、替代证据、风险及是否阻塞完成；不能为了数字好看禁用 SSH 条件测试或删除保留价值的底层回归。

**Step 3 — Gate 与交付：**
- **Go:** 329 全核销、两 Test Target 分层实证、所有当前适用且可安全执行的条件与重要组合真实验收、必要 CI 和构建退出成功、零未解释 UI/UX 退化、无过时测试入口与重叠旧代码。
- **No-Go:** 方法原断言没有替代、核心 GUI 根本没运行、选择错文件/仓库、真实数据保护/机器身份没有证明、缺少必要的前台/IME/本机或 SSH 证据、CI 只报告 skipped、配置隔离可能影响用户。说明未达条件与补验路径；**不因审查临近结束而改变接受标准。**
- 本轮计划/状态改动仍遵守 Feature 默认本地管理规则；实施代码按 Git 规则逐 task 原子提交。没有授权不推动合并 PR 或安装正式 App。

---

## Phase Audit

执行本 task 后由 Skill 按当时真实任务状态生成 `audit-p5.md`；已有的历史 `audit*.md` 不是本轮预审判断来源。最终只认可真实测试和源码核销的直接证据，未覆盖场景不冒充成功。

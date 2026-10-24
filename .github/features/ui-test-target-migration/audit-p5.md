# Audit P5 - ui-test-target-migration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p5.md`
- feature 目录：`.github/features/ui-test-target-migration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [ ] P5-T1 全方法、运行入口与最终 Go/No-Go 核销

## 任务到文件的映射

- P5-T1：`migration-inventory.md`、`todo.toml`、`plan-p1.md`–`plan-p5.md`、`BaileyTests/{Unit,Integration}`、`BaileyUITests/`、两份 Xcode Scheme、`Makefile`、`.github/workflows/{ci,release}.yml`、`docs/{testing,release}.md`。
- 本轮代码修复：`BaileyUITests/Support/WorkspaceUITestSupport.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`、`BaileyTests/Integration/Git/GitStatusModelTests.swift`。

## 原方法与当前测试的独立核对

以 `019765f` 为迁移前基准，不采用既有 `audit*.md` 结论。通过 `git show 019765f:<原路径>` 重建方法列表，再从当前 Swift 源码读取 `XCTestCase` 类名和 `func test*`，逐行解析 `migration-inventory.md` 的目标 `类名.方法名`。

| Task | 旧 UI 方法 | 当前目标存在 | 原断言边界 |
| --- | ---: | ---: | --- |
| P2-T1 | 38 | 38 | TextKit 导航、IME、Undo；组件验证与 GUI 分离 |
| P2-T2 | 49 | 49 | 文件保存、SSH 与原生编辑器实例 |
| P2-T3 | 22 | 22 | Neon、主题和原生像素 |
| P2-T4 | 35 | 35 | Diff 编辑、显示、保存 |
| P3-T1 | 21 | 21 | Git 历史文件和 Git revision |
| P3-T2 | 15 | 15 | Git Changes、远端刷新、工作树 |
| P3-T3 | 18 | 18 | Git 原生 Sheet 与真实 Git 副作用 |
| P3-T4 | 48 | 48 | Graph 几何、键盘、菜单 |
| P4-T1 | 11 | 11 | 树行、Dock 与菜单 |
| P4-T2 | 19 | 19 | 多窗口焦点与键盘 |
| P4-T3 | 17 | 17 | Finder 拖放和文件归属 |
| P4-T4 | 15 | 15 | 窗口关闭、保存和状态恢复 |
| P4-T5 | 21 | 21 | Ghostty、WebKit、Settings、资源释放 |
| **合计** | **329** | **329** | **0 个原方法漏登记；0 个目标类／方法缺失** |

- 旧 `BaileyTests/Unit`／`Integration` 共 **306** 项；原方法名 303 项保留，另外 3 项对应两个完整窗口宿主撤除和一个 App 身份测试重命名；需以具体替代断言判断，而非仅靠方法数。
- 旧独立 `BaileyUITests` 10 项在当前 133 项中全部同名保留，新增 123 项。当前宿主 549 项。源码静态对应不是动态通过：GitHub UI 133 项必须逐项实际执行。
- `BaileyTests/NativeUI`、`BaileyTests/WorkspaceUI`、完整 SwiftUI WorkspaceDock 测试宿主均已清理；`BaileyUITests` 未导入 `@testable Bailey`。Git Graph 等少数测试方法只调用共享 `verify...`，经核查辅助函数内部拥有 XCTest 断言，不是空测试。
- 最小 AppKit 的编辑器／TextKit／IME／PTY 组件测量保留；用户旧 Session 快照、机器归属、未保存文件保护仍有真实消费，**不应以“删除兼容”为由移除**。

### Git 提交逐项对应

审阅 `019765f..1475fdc` **46 条提交**的修改文件、阶段归属和最终活跃目标，包含文档提交，不以最终测试数量代替提交核销。以下按迁移期/责任区归组；方法级目的地见上表及 `migration-inventory.md`。

| 责任区 | 提交（按出现次序） | 核对的主要变化 |
| --- | --- | --- |
| P1 | `28a3f42`、`d77489a`、`921518a`、`70a103d`、`a7e4834`、`f712d52`、`9177817`、`a33641e`、`d122154` | 计划基线、夹具清理、独立 UI 入口与焦点、选择器作用域 |
| P2 | `1f5e83b`、`4e5d146`、`b094047`、`5bc6fe2`、`723c16b`、`dab44c3`、`7e27b61`、`6b65c00`、`2c7b51b`、`3136767`、`335ed7d` | 编辑器撤销、长文档、文件读写、开发版身份、Neon 与 Diff 原生约束 |
| P3 | `f0f8699`、`76c417e`、`e5fcb24`、`5f7d512`、`54e8e72`、`1112d9c`、`b515ace`、`0ae7397`、`c041742`、`6853d34`、`f9eb22a` | Git 的业务模型／真实 UI 拆分、菜单与窄栏、工作区宿主清理 |
| P4 | `87292c1`、`25effa0`、`be40be8`、`9a8e022`、`c88f218`、`f4f6f81`、`658eebe`、`fc61ce2`、`fe8acb3`、`0c2d26d`、`5fea926`、`4a176b5` | 共享组件／窗口／Finder／资源释放、原宿主与文档目标清理 |
| P5 基线 | `b79cff7`、`b7759ec`、`1475fdc` | 禁止空选择器假通过、测试中断后清锁、P5 状态待验 |

当前方法目标均存在于实际 Test Target，**但远端 CI 未完整通过，不能把 46 个提交视作全部动态验收通过**。

## 发现项

## 发现 F-04

- 任务：`P5-T1`
- 严重级别：`High`
- 状态：`Open`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:77-84`
- 摘要：`UI Target 硬编码要求 ABC 键盘源，CI 的 120 个已启动用例全部在共同启动前置条件失败`
- 风险：`PR#54 UI Job 40103474080 在 26 分钟后取消，记录 120 个测试启动和 120 条 ABC 键盘条件错误，没有取得任何真实 GUI 功能验收证据。现有保护误将其他真实 ASCII 键盘布局及已选中的合法输入源拒绝。`
- 预期修复：`不要无条件强行选中 ABC；优先保持已选中的 ASCII 键盘布局，允许标准 US 或系统报告的 ASCII 键盘布局，在实际非 ASCII/IME 时再切换。仍保留测试后恢复原输入源与失败即报错的安全要求。`
- 验证：`使用本机真实 XCUITest 复验已有 Git Changes 与文件输入选择；CI 同类 xcode-27 Runner 在修复后能进入真实 App 交互，逐项报告 133 个用例的实际通过/失败，而非统一初始化失败。`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-03

- 任务：`P5-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Integration/Git/GitStatusModelTests.swift:1125`
- 摘要：`Git 初始化失败后测试继续取空数组的第一个元素，触发 Fatal Index out of range 并中断其他测试`
- 风险：`CI 14:47:15 确认 Swift/ContiguousArrayBuffer Fatal、测试宿主重新启动，导致部分 549 条未运行；掩盖真正初始化失败根因。`
- 预期修复：`将依赖既有快照的 priorChanges[0] 改为 XCTUnwrap(priorChanges.first)，让前置条件失败被报告为单一 XCTest 失败而不是崩溃；不隐藏 Git 命令失败。`
- 验证：`原 CI 日志确认失败路径；在本机运行原 GitStatusModel 对应类并确认断言；CI 同一故障不能再由于空数组而崩溃。`
- 解决证据：`GitStatusModelTests.swift 以 try XCTUnwrap(priorChanges.first) 阻止空快照直接索引导致的 Fatal；make test:FileTreeTests,GitStatusModelTests: 76/76 passed，0 skipped，退出码0，build/ui-test-migration-host-targeted-audit.log。远端 CI 14:47:15 旧 HEAD 的崩溃属于未修复快照；本次修改后仍需提交并在 CI 重跑确认。`


## 发现 F-02

- 任务：`P5-T1`
- 严重级别：`High`
- 状态：`Open`
- 位置：`.github/workflows/ci.yml:16-36 / CI build job 40103474080`
- 摘要：`CI 测试进程调用 Xcode 27.1 的失效工具链，导致 git 与 Python shim 执行失败；549 项未完整执行`
- 风险：`GitStatusModel、远端刷新、Shell 输出等 25 种测试方法出现断言失败；测试进程崩溃并重启，CI 最后只报告 287 项、14 失败；不能用于最终 Go。`
- 预期修复：`先追踪 Actions Runner 测试子进程中 xcode-select/DEVELOPER_DIR/SDKROOT 及 login-shell 环境来源，使 Git 和 Python 确定调用有效工具链，不改动产品的 Git 错误语义、跳过测试或随意加超时。`
- 验证：`修复后在同类 xcode-27-arm64 Runner 上执行非 Draft 的完整 build 和 UI Job；记录 xcresult 发现与实际执行的方法集、退出码和签名。`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-01

- 任务：`P5-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:254-261`
- 摘要：`Git 测试夹具继承 GIT_DIR/GIT_WORK_TREE 等路径重定向变量，-C 临时仓库不能保证写入留在夹具内`
- 风险：`当测试运行器从设置过 GIT_DIR/GIT_WORK_TREE 的 shell 启动时，测试提交、Reset、Stash 等命令可能操作外部仓库。已用两个临时 Git 仓库实证 -C 无法覆盖继承的 GIT_DIR。`
- 预期修复：`Git 夹具构造 Process 环境时统一去除继承的 GIT_* 变量，再明确注入 Git 配置隔离和禁止 hooks 的选项；不增加生产代码测试开关。`
- 验证：`用两套真实临时 Git 仓库重放 GIT_DIR/GIT_WORK_TREE 污染与净化；构建独立 UI Target；执行已有真实 Git E2E 并确认工作区之外无变更。`
- 解决证据：`临时双仓库实证继承 GIT_DIR/GIT_WORK_TREE 可绕过 git -C；WorkspaceUITestFixture.git 统一剔除继承 GIT_*；WorkspaceGitUITests 在污染环境下注入两个仓库并核对真实 Git 作用域与其他仓库 HEAD 不变。make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests/testGitChangesAreScopedToTheOpenedRepository: 1/1 passed，退出码0，build/ui-test-migration-git-isolation.log。CI 对新提交仍须单独验证。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- F-01：限制测试 Git 夹具的 `GIT_*` 继承范围，复用现有真实 Git Changes UI 测试构造双仓库污染环境；不修改生产 Git 行为、也不增加测试专用 App 开关。
- F-03：将 `priorChanges[0]` 改为 `try XCTUnwrap(priorChanges.first)`。测试准备失败时应报告 XCTest 前置条件，而不是把整个宿主进程崩溃后重启。
- F-02：CI 两个 Job 在已有 `DEVELOPER_DIR` 配置基础上用 `sudo xcode-select --switch "$DEVELOPER_DIR"` 同步系统开发者路径，消除 Runner 默认 Xcode 27.1 与构建所用 Xcode 27 的不一致。**新提交尚无 CI 结果，不能标记解决。**
- F-04：移除仅允许 `com.apple.keylayout.ABC` 的硬编码单点条件，接受当前已选中的真实 ASCII 键盘布局、标准 US／ABC 以及系统提供的 ASCII 布局；只有确实无法选择时才报错，仍在 Teardown 恢复原输入法。

## 验证日志

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 迁移前 329 条旧方法与当前 `类.方法` 对照 | PASS 329/329 | `019765f` Git 历史 + `migration-inventory.md` + 当前 Swift 源码；所有 13 个 Task 均覆盖 |
| 旧独立 10 项与现 133 项 | PASS 静态对应 | 10 项同名保留；另新增 123 项，动态执行另行核销 |
| 宿主全量 `make test SIGNING=adhoc` | PASS 549 项，8 跳过、0 失败；退出码 0 | `build/ui-test-migration-host-audit.log`，445 秒；macOS 27.2、Xcode 27.2 |
| 无效选择器 `make test ONLY_TESTING=BaileyTests/DefinitelyMissingAuditTest` | PASS（正确拒绝） | `build/ui-test-migration-invalid-selector.log`；0 选中，退出码 2 |
| UI Git 双仓库污染 `make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests/testGitChangesAreScopedToTheOpenedRepository` | PASS 1/1，退出码 0 | `build/ui-test-migration-git-isolation.log`，40.589 秒，未替换正式 Bailey |
| UI 输入源修复后，按空格分隔的双选择器执行 Git + 文件保存真实 GUI | PASS 2/2，退出码 0 | `build/ui-test-migration-ui-double-audit.log`，95.990 秒；文件选择器、落盘、真实 Git 工作区与夹具环境污染均到达断言 |
| 精简宿主 `make test:FileTreeTests,GitStatusModelTests` | PASS 76/76，退出码 0 | `build/ui-test-migration-host-targeted-audit.log`，162 秒；包括 CI 曾崩溃的前置条件测试 |
| `make build:release SIGNING=adhoc` | PASS，代码签名验证 PASS | `build/ui-test-migration-release-audit.log`，`codesign --verify --deep --strict` 退出码 0 |
| PR #54 原 HEAD `1475fdc` 的 CI build Job 120900214620 | FAIL | Run `40103474080`：Runner macOS 27.0.1，Xcode 27 与 27.1 工具链路径冲突；287 项、6 跳过、14 失败，期间还有数组越界重启；本次 `ci.yml` 修复尚未运行于 CI |
| PR #54 原 HEAD `1475fdc` 的 CI UI Job 120900214828 | CANCELLED（非通过） | Run `40103474080`：开始 120 项、119 项记录 failed，120 条错误全部在 `selectASCIIInputSource` 强制 ABC 的共同前置条件；尚无有效 App 行为通过证据 |

### 保留的验证边界

- 全量宿主的 8 个 `XCTSkip` 均需要**明确授权的 Windows/SSH 测试主机**：交互式 rebase 1、远端刷新 1、远端 Git 工作树 2、SSH 文件树 3、远端 Git 恢复 1。无对应环境不能将跳过计为通过；复核方式是提供专用测试主机后定点运行这 8 项。
- 真正的独立 App UI **全 133 项通过证据缺失**；CI 的 120 项不是有效 GUI 验收。需用更新后的 CI 配置在干净的 `xcode-27` Runner 完整执行，并确认每个用例实际到达 UI 断言。
- 对新 SHA 的 Xcode 26.6 Release Runner、macOS 15.6 真机、实体触控板与真实中文 IME 全组合，均未取得证据；本机 Xcode 27.2 Release 编译不能替代。
- 原始迁移方法的 329 条静态对应不等于所有重写后的 UI 断言动态等价；特别是重写后的原生输入、拖放、剪贴板和多窗口用例须待真实 CI／实体测试补验。
- 未触碰正式 `/Applications/Bailey.app`、用户 SSH 机器、工作区外文件或正式签名身份。文档入口 `docs/testing.md` 和 `docs/release.md` 已核对；没有把临时审计信息写入长期规范。

## Gate（是否允许进入下一阶段）

- **结论：No-Go。**
- 理由：PR #54 的 2026-10-24 CI build 失败且 UI Job 取消；F-02／F-04 修改尚无新的 CI 复验，故不能宣布 P5-T1 完成。

## 最终状态与剩余风险

- 当前状态：**Open**；保持 `todo.toml` 中 P5-T1 的 In Progress，直到完整 CI 和必须的真实环境证据核销。
- 剩余风险：CI 系统工具链选择是否完全修复、UI 源选择是否能在 Runner 中恢复正常、133 项真实 GUI 回归时长及失败、跳过的 SSH 真机功能、Xcode26.6/macOS15.6 跨版本兼容。
- 下一步：本地修复的宿主 76 项与真实 GUI 2 项定点复验已通过。新提交的 PR CI 仍必须实际跑完并保存退出码／每用例状态，单纯手动取消或预先跳过不能通过 Gate。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

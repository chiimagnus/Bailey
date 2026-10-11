# P5：目录收尾、文档真源与整体验收

**Goal：** 收敛已经完成的迁移，删除旧路径/重复实现与无用转发代码，留下真实可维护的模块边界；对照重构前 P1 行为基线做完整签名 Debug 验收。

**Non-goals：** 不重新设计 UI，不以文件总行数作为成绩，不引入 SwiftPM/插件框架/测试平台，不借收尾实施独立的编辑器或 Git 性能 Feature。

**Approach：** 先以实际文件和调用关系审查目录归属/唯一状态 owner，清理迁移遗留并在唯一架构文档里说明真实结果；再运行全部相关检查与人工端到端验收。每项真实变更仍独立提交，验证数据不进入仓库。

**Acceptance：**
- 结构体现真实职责：`App` 负责设置/组装，`Workspace` 负责窗口项目/双层布局/持久化，`Terminal` 负责会话及 Ghostty，`Files/Git/Info` 各负责自己的视图与业务状态，`Remote` 保持 SSH，`Shared/Tree` 是各树唯一共享来源，`UI` 保留纯展示与复用控件。
- 现有 `Browser`、`Editor`、`Resources`、`Vendor` 不为形式迁移；文档/脚本中不存在本 Feature 引入的失效路径和错误编译命令。
- 测试、签名 Debug 实际安装/隔离对照、数据保护、Git 工作区和阶段审计均有真实证据；明确不能验证的项而非冒称通过。

**Rules：** 不删除任何未确认无用的会话数据或持久化兼容分支；用户不要求维护无用旧 API，但必须保护当前设备的可恢复数据。更改 `AGENTS.md` 仅用于修正最终事实，详细构建/验收细则仍归 `docs/CONTRIBUTING.md`。

---

<a id="p5-t1"></a>
## P5-T1 全仓目录、依赖与文档归属审查

**类型 / 依赖：** 收尾代码/文档变更；依赖 P1～P4 全部任务。

**Files / 锚点：**
- Review: `kero/App/`、`Workspace/`、`Terminal/`、`Files/`、`Git/`、`Info/`、`Remote/`、`Editor/`、`Browser/`、`UI/`、`Shared/Tree/`；源文件通过 `find kero -name '*.swift'` 确认，不能按预计目标树猜。
- Call chains: `ToolPanelView` → 各面板与现有模型，`WindowRootView` → `TerminalManager` → `Project` → `DockWorkspaceModel/PaneTab`，`GitStatusModel` → Git 内部执行层 → `WorkspaceBackend`。
- Docs/commands: `docs/CONTRIBUTING.md`、`docs/PRODUCT.md`、`docs/DEPENDENCIES.md`、`docs/README.md`、`AGENTS.md`，以及 `scripts/check-*.swift` 路径引用。

**当前依据：** 本 Feature 前文件树/Info 模型分别放在 Workspace/Terminal，ToolPanelView 同文件含三套面板；重构后的判断标准应是**单一职责与真实引用**，不能以新增了多少个文件夹/Protocol 衡量。

**实施：**
1. 对照 CodeGraph 及实际 `git diff` 查找旧定义、未消费的转发方法、重复树行、过期路径/注释；同一逻辑的旧路径须随新接入删除。生成图标和 `Vendor` 源码只读核对，绝不手改。
2. 对照各对象实际所有权审查循环依赖和意外新增协议；不为单一稳定实现引入 Protocol/Fake/Service。保留真实的 window registry、SSH backend、Git 本地性能路径及必要的存储边界，不盲删历史快照解析。
3. 增补**一份简短** `docs/ARCHITECTURE.md` 记录实际模块职责、状态归属、两层分屏、已有协议、配置输入与测试入口；不是目录/类型全清单。由 `AGENTS.md` 和 `docs/CONTRIBUTING.md` 链接它，避免重复规范。同步修正其他被本 Feature 改动的文档和编译命令。
4. 如发现仍在使用且职责混杂的类型，先列出真实调用链；只处理本 Feature 已确认的遗留，不在收尾时开启新大规模重写。特别是 `Editor/MaterialFileIcon.swift` 虽长但由脚本生成，禁止按行数拆。

**验证：** 所有本地 Markdown 链接和源码路径可达；对 `scripts/check-*.swift` 的实际新路径逐条编译并执行；完整 Debug build / codesign 通过；`git diff --check`、不存在重复定义/孤立新文件/旧目录转发层。只针对实际变更做一个或多个按逻辑原子中文提交，不能夹带测试产物。

**提交边界：** 有代码残留时按真实逻辑拆提交；文档/路径归属同一独立提交。不能为了产生提交而制造变更。

---

<a id="p5-t2"></a>
## P5-T2 对照 P1 基线的端到端验收与收尾

**类型 / 依赖：** 真实验收与证据交付；依赖 P5-T1，不提前声明完成。

**路径 / 锚点：**
- `docs/CONTRIBUTING.md` 的三项 `xcrun swiftc` 检查和 `xcodebuild` + `codesign` 命令。
- `kero/App/keroApp.swift::WindowRootView`、窗口恢复与 `SessionStore/TerminalHistoryStore`；
  `WorkspaceDockView`、`PaneLayoutView`、Files/Git/Info、`WorkspaceBackend` 的已验证功能入口。
- Local evidence: `evidence-p5.md` 与被忽略的 `build/` 下测试输出、可匿名化前后截图/进程信息。原始隐私数据不提交。

**操作：**
1. 检查 Git 工作区与正在运行的真实 Kero 任务；保护当前会话快照、未保存内容和 SSH 转发。签名 Debug 构建与校验后，若不能安全退出正式应用先用 `--isolated-ui-test`，说明隔离模式限制；待安全时再按开发规范验收正式安装和恢复，不强制结束 Shell。
2. 比对 P1 行为基线：本地/SSH 添加项目，固定目录与自动跟随，`DockNode` 跨组拖动/重排/四向分屏，`PaneNode` 内终端和文件/浏览器/Diff 分屏，切换项目/窗口及恢复；确认终端进程未异常重启。
3. Files：惰性文件树、压缩目录、新建/改名/打开、滚动/点击/无障碍；Git：未提交/暂存/历史树、状态颜色、在独立测试仓库执行可逆的暂存/丢弃/提交/分支/刷新与 diff；Info：本地和安全可达的远端目录、进程、端口/转发与断线。
4. 检查最后一个刷新事件不丢失、旧 workspace 结果不覆盖新项目；参照 `docs/PERFORMANCE.md` 核对未新增无条件轮询/显著额外进程或 SSH 往返，不以未测条件声称提速。无法实际连接 SSH 的场景明确标记缺失，不能将本地结果替代。
5. 逐项对照 `idea.md`、本 Feature 五份 plan、各提交与阶段发现；核对 `todo.toml` 任务状态，清理所有测试 App/安装备份/隔离配置，确保无临时构建产物加入 Git。将可复现动作、结果、缺口和最终判定写入 `evidence-p5.md`。

**验证与交付：** 三项独立检查、Debug 构建签名、真实窗口/项目和双层布局恢复、关键 UI 与本地/SSH（可用时）操作记录齐全，Git status 仅含按原任务授权保留的内容。此任务是验收，不为生成提交编写新代码；有真实缺陷则返回对应源码任务原子修复、重新验收，不能以审计文字代替修复。

---

## 阶段审查与 Feature 完成条件

- `plan-task-auditor` 在实际实施完成后按 phase 逐一审计；`audit-p5.md` 仅在该阶段进入审计时生成。
- “源码路径更漂亮”不是结束条件：要有持有者、真实调用方、唯一实现、具体回归与数据安全证据。
- 本计划只定义实施与验收，`todo.toml` 是唯一的实时任务状态；没有实际执行前一律不标记完成。

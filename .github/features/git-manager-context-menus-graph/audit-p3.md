# Audit P3 - git-manager-context-menus-graph

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/git-manager-context-menus-graph/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 复现并定位 Git 面板刷新迟滞
- [x] P3-T2 最小刷新修复与原生端到端验收

## 任务到文件的映射

- P3-T1（不提交生产代码；诊断证据在 `evidence-p3.md`）：`kero/UI/ContentView.swift` 的 Git 事件入口、`kero/UI/Panels/ToolPanelView.swift` 的可见任务与 Files/Git 分流、`kero/Git/GitStatusModel.swift` 的 `sync`/`refresh`/`refreshPending` 与请求代次；`KeroTests/NativeUI/Git/GitExternalRefreshTests.swift` Red 复现，日志 `/tmp/kero-p3-external-red.log`。
- P3-T2（`1d2be55`）：`kero/UI/Panels/ToolPanelView.swift` 复用 2 秒本地可见刷新入口；`KeroTests/NativeUI/Git/GitExternalRefreshTests.swift` 真实仓库 + 原生 SwiftUI 窗口的工作区、Index、历史、前后台、卸载、项目切换回归；`kero/Git/RecentCommitsView.swift` 修复标题/Ref 布局优先级；`docs/features/git.md` 记录现行刷新条件和 UI 行为。

## 发现项

## 发现 F-01

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/UI/Panels/ToolPanelView.swift:226`
- 摘要：`前台非 Git 目录由外部 CLI 初始化为仓库后 Git 面板永久不自动更新`
- 风险：`周期任务必须先满足旧 isRepo，导致非 Git 状态下的新仓库无法被发现，违反外部变更刷新及初次打开验收`
- 预期修复：`移除已经由 GitStatusModel.refresh 自行负责检查的 isRepo 冗余条件，仍受本机、前台、可见和忙碌状态限制`
- 验证：`新增 NativeUI 临时目录外部 git init 的 Red/Green，make test，make build`
- 解决证据：`aafd7ac: 本机非仓库外部 git init NativeUI 先 Red 后 Green、同一文件/暂存/提交回归 2/2，完整 make test 106/106、make build 验签及正式 Kero.app 重新安装 SHA256 对照成功`


经代码路径、Git 真源、原生截图、全量 XCTest 及签名构建复核，未发现有证据支持的未修复生产缺陷。发现的“缺少外部刷新入口”和“多 Ref 挤占标题”均已在本阶段按根因解决。独立 Debug 进程 NSOpenPanel 不可自动化的问题属于未完成的完整应用端到端验收，另列在验证边界与剩余风险中，不伪装为已通过。

## 修复日志

- T1 在原生 `NSHostingView` 常驻 Git 面板时两次外部 Git 真值变化均 Red：文件更改后等待 4.6 秒仍无 Changed，外部 Commit 后等待 4.6 秒仍旧 HEAD；同一模型手动 `refresh` 两次均能读回正确结果，定位“无事件触发”，非查询错误／状态回写错误。
- T2 只复用已有 2 秒可见面板任务：前台、本机 Git 面板才启动周期读取，后台/卸载/SSH 不轮询；保留 Git model 现有互斥、代次、手动刷新和超时逻辑，不引入文件 watcher／缓存／新的 Git 轮询器。
- 最终真实分叉合并及多 Ref 截图，发现 `merge feature` 被引用徽章挤成 `mer…`；调换 SwiftUI 布局优先级后重新截图，标题完整、Branch/Tag/`+2`、SHA/作者/时间与蓝绿合并连线正确。临时截图写入代码已从 XCTest 删除。

## 验证日志

- `make test ONLY_TESTING=KeroTests/GitExternalRefreshTests` → **PASS**，外部修改文件、暂存 Index、外部 Commit，前台响应分别约 **2.02/1.98/1.78 秒**；失焦与隐藏停止轮询，手动刷新和重新激活可恢复，切本地仓库不串状态。完整历史为真实二父合并及 Branch/Tag/Remote 多 Ref。
- `make doctor` → **PASS**（Xcode 27.0）。
- `make test` → **PASS**，**104/104，0 失败**，包含 GitStatusModel、RecentCommits、Files/Git 共享树、SSH 模拟错误与恢复的现有回归。
- `make build` → **PASS**，Debug 构建和 `codesign --verify --deep --strict` 成功。
- `git diff --check`、`.xcstrings` JSON 检查 → **PASS**。
- 原生合并仓库图谱截图 `/tmp/kero-p3-visual-qa.png` 已检查（不入 Git）；首次发现标题挤占，复测已修复。`GitPanel` 的分叉合并、Ref、标题、下行信息与其它面板区域正常；`docs/features/git.md` 现行语义与真实实现一致，`docs/ui.md` 共享树契约未改。
- 源码调用路径经 CodeGraph 核对：`DockTabGroupView → ToolPanelView` 对 `.git` 真正挂载/卸载，原生窗口与真实 GitStatusModel 对外部 IO 做端到端可观察刷新；保留 `ContentView → GitStatusModel.syncSelectedProject` 激活/终端回调。没有第二份缓存或双轨刷新。
- **未测／受阻**：独立 Debug Kero 进程可运行，试图通过 Peekaboo 向 macOS 原生 NSOpenPanel 导入测试仓库时，系统拒绝文件对话框焦点/AX 操作，故完整进程内的点击/右击菜单与 NSAlert 确认未完成 E2E；不能用 XCTest NativeUI 代称该项通过。真实 Windows SSH 主机（延迟、断线与重连、远端外部变更）也未实测，不能以模拟 SSH 代替。该次阶段审计时正式 App 尚未替换；后续用户明确授权并完成审计版重新安装（见末尾复审记录），此次安装未主动重启运行进程。

## Gate（是否允许进入下一阶段）

- 结论：**Go（P3 源码实现和可自动化验收）**
- 理由：影响实际功能的 T1/T2 缺陷已真实复现并修复，Git 真值及 NativeUI、104 项完整 XCTest、Debug 验签满足可执行的验收；独立 Debug 进程完整右键与真机 SSH 的未测部分按实际障碍披露，**不计入 Go 已验证范围**。

## 最终状态与剩余风险

- 当前状态：**Resolved（P3 功能及可执行回归）**
- 剩余风险：完整应用级的菜单及确认框人工/自动化 E2E、真实 Windows SSH 行为受测试环境限制尚未验收；不宣称整个功能在所有设备上完成终验。当时尚未安装；最终独立审计后已将新签名版本重新安装到正式位置，安装未主动重启运行进程（见末尾校验）。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-14 独立逐提交复审

- **P3-T1（按计划诊断不提交）**：重新对照 `ContentView.syncGit` 和 `ToolPanelView.pollsSelectedPanel`；原始 Red 测试真实临时 Git 外部修改后 4.6 秒仍未刷新、外部提交后 4.6 秒仍旧 HEAD，但手动刷新正常，根因为缺少外部变化触发，而非 Git 结果解析或 SwiftUI 更新丢失。证据见 `evidence-p3.md`。
- **P3-T2／`1d2be55`**：检查现有本机、前台、可见 Git 面板复用 2 秒任务，不在后台/SSH 建新 watcher；测试真实临时仓库的文件、Index、Commit、失焦、隐藏和跨项目，回归约 2 秒。Canvas 真机截图确认蓝色主干、多色分支和重合并的 Ref 在布局修复后可见。本轮发现 **F-01**：额外 `isRepo` 条件导致外部 `git init` 不会被检测；**`aafd7ac`** 去掉重复条件，真实外部初始化+原生窗口 Red→Green（2/2，包括原刷新回归）。没有改动旧请求去重、后台/SSH 性能契约。
- **验收边界**：本机原生 `NSHostingView` 的真实 Git IO、独立 Debug 安装包验签可查；实际远端 Windows SSH、完整独立进程的对象右键与对话框 E2E 尚未执行成功。最终 `make test` **106/106**、`make build` 和严格验签通过；最新版已重新安装 `/Applications/Kero.app`，已核对安装后二进制 SHA-256 为 `d507ac98634f9425c5cb5f1ac71065e39b9bc6bc2941002a124ae764d64767c4`。独立复审 Gate：**Go（已验收本机范围）**；未测跨设备端到端行为不计入通过。

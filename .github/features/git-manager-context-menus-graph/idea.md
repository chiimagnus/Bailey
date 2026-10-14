# Git Manager：Recent Commits 多分支图谱、Context Menu 与刷新

关联需求：[Kero Issue #2](https://github.com/chiimagnus/kero/issues/2)。

**2026-10-14 范围修订：** P1～P3 是已完成的原阶段，P2 当时主动排除的大部分 Git Graph 菜单**不是 Issue #2 的已完成需求**。现增 P4「完整对象右键菜单」，保留历史阶段与审计，不把新增任务倒灌进旧 task 的完成状态。当前实现事实见 [Git 功能文档](../../../docs/features/git.md)，对照证据与逐对象差异见 [research.md](research.md)。

## 背景

现有 Git Manager 已有仓库标题、分支菜单、Commit Staged、Stage/Unstage/Discard、Fetch/Pull/Push、Stash、文件 Diff、近期提交及懒加载。截图和 Issue 反映的问题是：提交右键只有复制操作；Commit 与 Branch/Tag 引用还没有独立的菜单命中；Recent Commits 只有单色直线，不表达合并/分叉；外部 Git 变更后面板更新有时落后。

原 P2 为了缩小实施范围主动省略了 Cherry-pick、Revert、Drop、Reset、Merge/Rebase、远端分支与 Tag 管理等操作；这不符合用户对 Issue #2「参照 Git Graph 与 VSCodium，把适合当前对象的菜单补齐」的最新明确要求。P4 不复制其它产品的整个 UI，但**不再以旧 P2 的非目标排除适用的 Git 操作**。每个动作必须有正确对象、原生命中、Git 真实结果与失败恢复。

已完成的 P1～P3 基线（不是 P4 交付）：
- [调研和已有功能对照](research.md)
- [Recent Commits HTML 设计稿](design.html)：以 Issue #2 的 Git Graph 截图为参考，**只展示 Recent Commits**；一条提交占两行，标题后紧跟 Ref，第二行显示简短 SHA、作者及右对齐时间；蓝色主干与多色侧分支绘制分叉/合并，支持 Commit / 本地分支 / Tag / 历史文件的模拟交互。**不是已实现的 SwiftUI 功能，也不设计 Changes、提交框、仓库工具栏。**

## 实施范围

- **P1～P3（已实施）**：真实提交拓扑与双行视图、Ref 类型与分页、Commit/本地分支/Tag 基础右键、在历史 SHA 创建本地分支和轻量 Tag、本机可见 Git 面板外部变更刷新；保持已有鼠标/键盘命中、文件树、Diff 和失败语义。`design.html` 仅作 Recent Commits 视觉历史参考，不约束 P4 的菜单功能范围。
- **P4：Git Graph + VSCodium 对象菜单补齐**：Commit 完整操作（Checkout 到选中 SHA、Cherry-pick、Revert、条件允许的 Drop、Merge into current、Rebase current onto、Soft/Mixed/Hard Reset、与 HEAD/Ref/合并基点比较、创建 Branch/Tag、复制）；当前/其他本地分支（切换、重命名、删除非当前分支、合并、Rebase、定向 Push、复制）；远端跟踪分支（基于实际 remote/ref Checkout、Fetch 到本地分支、Pull/Merge 的明确语义、删除远端分支、复制）；Tag（带注释/轻量创建、查看详情、删除本地、向指定 remote Push、删除指定 remote 上的 Tag、复制）；Stash（在现有 Git Manager 显示可右击的具体条目，选择 Apply/Pop/Drop/从 Stash 建分支）；未暂存/未跟踪/已暂存/冲突文件及分组（对照 VSCodium 的操作范围与禁用条件）；历史 Commit 的 Compare with HEAD/所选 Ref/合并基点，以及历史文件（Diff、打开指定修订、与工作区比较、复制路径）。
- **以对象及语义决定菜单**：Commit 行与 Ref Badge 仍是独立命中；`+N` 折叠入口中的菜单与直显 Badge 一致。各对象只暴露有效动作，当前分支不能删除，远端 HEAD 符号引用不作为可删分支，历史文件未必存在于工作区；不以一个通用菜单堆砌所有命令。
- **本机和 SSH 的相同语义**：Git 写操作复用 `GitStatusModel` → `GitCommandExecution` → 当前 `WorkspaceBackend` 的 argv 执行、仓库/机器身份、操作互斥、状态刷新和错误展示；不以本机文件路径操作 SSH 仓库。SSH 实机结果单独验收，不以模拟后端冒充通过。
- **破坏性操作与冲突恢复**：确认前显示目标仓库、当前分支/HEAD、引用或提交及影响范围；确认后重新校验。重写历史、远端删除与丢弃必须明确影响并防止误目标；Cherry-pick/Revert/Merge/Rebase 的冲突保留 Git 操作状态和真实变更，提供对应 Continue/Abort/必要时 Skip，不自动 Reset 或静默清理。
- **原有刷新需求不消失**：P3 已证明本机可见面板外部变化会刷新；Issue #2 对 SSH 的刷新覆盖仍未完成独立验收，不能因 P4 菜单验收而直接关闭 Issue。

## 默认设计与交互

- 左键整行展开/收起提交文件，短 SHA 独立复制；Commit、当前/其他本地分支、远端 Ref、Tag、Stash 条目、文件与分组拥有各自对应的右键动作。`+N` 不漏掉隐藏 Ref 的管理能力；不恢复右键「展开/收起提交文件」冗余项。
- 冲突、进行中的操作及脏工作区决定菜单禁用/恢复动作；没有可用目标或 remote 时说明原因，不展示假的可点击项。Git Graph 的 Drop 只对**拓扑允许且确实能安全改写的当前本地线性历史**开放，合并/共享引用等情形明示不可用，不能用 Reset/Revert 冒充 Drop。
- Checkout 到历史提交必须明示会进入 detached HEAD；Reset 提供 Soft/Mixed/Hard 的影响说明和显式选择，Hard 无默认执行；远端 Push/Delete 由用户选定 remote 和 ref，不暗中 Force Push、不推送全部 Tag、不发布 Release。
- 操作从菜单打开到真正发命令之间可能切换仓库或改变 HEAD/ref；对话框只捕获当前目标，最终执行时重新核对实际目标与工作区。拒绝过期命令，而不是退回本机或继续对旧仓库操作。
- 使用已有 SwiftUI `.contextMenu`、原生输入/确认和当前文件树/Diff；不引入 WebView、HTML 菜单、另一套 Git 状态机或无关的页面重设计。

## 非目标

- 不照搬 Git Graph 的 UI 配置、列可见性、Branches Dropdown 选择器、Create Archive、专用 PR/Code Review 集成、外部链接菜单或无限制历史搜索：Kero 没有对应的对象/服务，复制会制造无效入口；但**不得据此删掉**本次明确要求的 Git 操作。
- 不自动 Force Push/Force Delete、不自动创建 GitHub Release，不为历史命令直接引入自定义交互式 Git 编辑器；必要的冲突解决与 Continue/Abort 必须在当前 Git 工作流内可达。
- 不重做已有 Fetch/Pull/Push、Stage/Unstage/Discard、原生文件树或提交框；按对象复用已有动作，可用的缺口必须补齐。不改变既有图谱风格或增加线性/分叉模式切换。
- **本次授权只有 `$writing-plan`**：仅更新这份既有 Feature 的需求、研究、阶段计划及任务登记；不修改 Kero 生产代码、不执行 Git 写操作测试、不替换 App，也不借此关闭 Issue。

## 验收

1. P1～P3 已有图谱、Refs、文件树、提交编辑、刷新与键鼠交互全部不回归；不把 HTML 的模拟菜单当作产品测试。
2. **逐对象逐操作**对照 [P4 菜单矩阵](plan-p4.md#菜单矩阵与边界)，每个应有菜单项必须真实可见/可用或有明确的合法禁用原因；折叠的 `+N` 与直接显示的引用行为一致。
3. 在**临时真实 Git 仓库**证明 Cherry-pick/Revert/Checkout/Merge/Rebase/Soft-Mixed-Hard Reset/Drop、分支/远端 Ref/Tag/Stash、文件与分组动作的实际 HEAD/ref、index、工作区、reflog、远端 bare repo 结果；不是只断言命令构造或 View 回调。
4. 对不应改变数据的情况，验证取消/拒绝/命令失败后 HEAD、refs、index、工作区保持；冲突出现后继续/中止有真实结果，已存在的用户修改不会因隐藏自动清理而丢失。跨项目、跨机器、对话框期间 HEAD/ref 变化一律拒绝过期目标。
5. 对照原生窗口验证对象命中、禁用、确认对话框、菜单键盘/VoiceOver；独立 App E2E（本机与获准的真实 Windows SSH）分别记录，不用 NativeUI 或假 SSH 冒充完整验收。全部代码通过 `make test`、`make build` 与严格签名。
6. 仅计划阶段：`idea.md` 与 `plan-p4.md`、`todo.toml` 任务 ID/锚点一致，所有任务都有正确源文件、验证、文档同步和提交边界；P1～P3 已完成记录不变。Issue #2 的 SSH 刷新缺口必须另行验收，不能仅凭 P4 完成关闭 Issue。

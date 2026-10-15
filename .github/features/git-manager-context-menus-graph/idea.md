# Git Manager：Recent Commits 多分支图谱、Context Menu 与刷新

关联需求：[Kero Issue #2](https://github.com/chiimagnus/kero/issues/2)。

**当前状态（2026-10-15）：** P1～P4 均已完成，任务以 [todo.toml](todo.toml) 为准。`ca183bf` 已修复 SSH 外部 Git 变更自动刷新；后续 P4 独立复审及 Stash 图谱修正使 Git Graph 直接显示具体 `stash@{n}`，与基础提交连线，并支持原生右键及历史 Diff。最终包含真实 Windows SSH 的完整回归 **234/234 XCTest、0 失败、0 跳过**；窄侧栏完整序号修正后的独立 App 验收、构建与安装记录见 [audit-p4.md](audit-p4.md)。[PR #14](https://github.com/chiimagnus/kero/pull/14) 已于 2026-10-15 合并至 `main`，[Issue #2](https://github.com/chiimagnus/kero/issues/2) 同时关闭；此后 `crh` 上的修正已由本地提交 `42bbb53` 实现，不在已合并 PR 的提交中；尚未推送。

**P4 的实施决定（历史）：** 保留 P1～P3 的完成记录；按 [Git Graph 固定版本](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812) 补齐对象菜单与原生弹窗的真实后续动作，不只复制名称。Kero 使用 SwiftUI / AppKit，不照搬 WebView；依据见 [research.md](research.md) 和已完成的 [plan-p4.md](plan-p4.md)。

## 背景

现有 Git Manager 已有仓库标题、分支菜单、Commit Staged、Stage/Unstage/Discard、Fetch/Pull/Push、Stash、文件 Diff、近期提交及懒加载。最初截图与 Issue 记录的问题包括：提交右键只复制、Commit 与 Ref 命中不完整、历史图只画单色直线，以及外部 Git 变更刷新落后。**图谱、Ref 基础交互和本机刷新由 P1～P3 完成，完整对象菜单由 P4 补齐**；SSH 外部自动刷新则在 P4 之后单独修复，历史阶段边界不混写。

原 P2 为了缩小实施范围主动省略了 Cherry-pick、Revert、Drop、Reset、Merge/Rebase、远端分支与 Tag 管理等操作；这不符合用户对 Issue #2「参照 Git Graph 与 VSCodium，把适合当前对象的菜单补齐」的最新明确要求。P4 不复制其它产品的整个 UI，但**不再以旧 P2 的非目标排除适用的 Git 操作**。每个动作必须有正确对象、原生命中、Git 真实结果与失败恢复。

已完成的 P1～P3 基线（不是 P4 交付）：
- [调研和已有功能对照](research.md)
- [Recent Commits HTML 设计稿](design.html)：以 Issue #2 的 Git Graph 截图为参考，**只展示 Recent Commits**；一条提交占两行，标题后紧跟 Ref，第二行显示简短 SHA、作者及右对齐时间；蓝色主干与多色侧分支绘制分叉/合并，支持 Commit / 本地分支 / Tag / 历史文件的模拟交互。**这是当时的 HTML 原型而非 App 验收证据**；其 Git 图谱相关部分已在 P1～P3 对应实现，但并未设计 Changes、提交框、仓库工具栏及 P4 完整菜单。

## 实施范围

- **P1～P3（已实施）**：真实提交拓扑与双行视图、Ref 类型与分页、Commit/本地分支/Tag 基础右键、在历史 SHA 创建本地分支和轻量 Tag、本机可见 Git 面板外部变更刷新；保持已有鼠标/键盘命中、文件树、Diff 和失败语义。`design.html` 仅作 Recent Commits 视觉历史参考，不约束 P4 的菜单功能范围。
- **P4（已完成）：以 Git Graph 为一手基准的右键菜单**：Commit（创建 Branch/Tag、Checkout、Cherry-pick、Revert、Drop、Merge、Rebase、Reset、复制）；本地/远端 Branch（Checkout、Rename、Delete、Fetch/Pull/Merge、Rebase、Push、复制）；Tag（查看详情、创建/替换、删除本地和可选远端、Push、复制）；Stash（每条 Apply/Pop/Drop/从 Stash 创建分支）；Uncommitted Changes（Stash 带消息、Reset Mixed/Hard、Clean Untracked 带目录选项）；历史文件（View Diff、View Revision、与工作区比较、打开文件、Reset File to Revision、复制两种路径）。现有 Staged/Unstaged/Conflict 文件和分组菜单按 VSCodium 的 SCM 习惯保持适用动作。Branch/Tag/Remote Ref 的 Create Archive 在不复制 Web 下载栈的前提下按原生保存流程支持，明确二进制与远端限制。
- **以对象及语义决定菜单**：Commit 行与 Ref Badge 仍是独立命中；`+N` 折叠入口中的菜单与直显 Badge 一致。各对象只暴露有效动作，当前分支不能删除，远端 HEAD 符号引用不作为可删分支，历史文件未必存在于工作区；不以一个通用菜单堆砌所有命令。
- **本机和 SSH 的相同语义**：Git 写操作复用 `GitStatusModel` → `GitCommandExecution` → 当前 `WorkspaceBackend` 的 argv 执行、仓库/机器身份、操作互斥、状态刷新和错误展示；不以本机文件路径操作 SSH 仓库。SSH 实机结果单独验收，不以模拟后端冒充通过。
- **弹窗与副作用要相符**：除文本和字体改用原生控件外，保留上游适用的输入、单选/多选、复选框、默认值、主要/次要按钮及后续分支（包括重名替换/改名、Force Delete、Push Mode、Reinstate Index、Tag 推送警告）。每个按钮落到相应 Git argv 和后续动作；不能用同名但不同效果的命令蒙混。失误可能损失数据的操作须确认目标并在执行前校验，发生冲突时保留真实状态与 Git 错误，用户可从现有 Kero 终端继续/中止；不额外创建上游没有的恢复 GUI 或状态机。
- **外部 Git 变更刷新（已补修）**：前台可见 Git 面板对本机和 SSH 仓库的外部修改、暂存与提交均能自动更新；触发条件、间隔与失败边界由 [Git 功能文档](../../../docs/features/git.md#刷新与显示) 维护。修复提交 `ca183bf` 与真实 Windows SSH 原生面板回归见 [evidence-p3.md](evidence-p3.md)。

## 默认设计与交互

- 左键整行展开/收起提交文件，短 SHA 独立复制；Commit、当前/其他本地分支、远端 Ref、Tag、Stash 条目、文件与分组拥有各自对应的右键动作。`+N` 不漏掉隐藏 Ref 的管理能力；不恢复右键「展开/收起提交文件」冗余项。
- 没有可用对象、正在执行不兼容操作或可能丢失未保存编辑时明确拒绝；不把所有 dirty Git 状态都禁用，Git 能自行拒绝的前提沿用真实错误。Drop 遵循上游的父节点、Merge、多子分叉与当前 HEAD 路径条件；单个 Tag/同节点其它 Ref 不额外禁用，detached HEAD 下条件成立也不人为排除。尊重用户 Git 配置，不用 Reset/Revert 冒充 Drop。
- Checkout 到历史提交须提示 detached HEAD；Commit Reset 默认 Mixed，Hard 只能由用户明确选择；Branch Push 默认 Normal，可按 Git Graph 弹窗明确改为 Force With Lease/Force，Force Delete/Force Fetch/替换同名 Ref 同理明确选择。任何模式都不得悄悄 Force、推送全部 Tag 或发布 Release。
- 对话框捕获发起窗口、Project、机器与仓库，确认及异步预检后核对；写当前 HEAD、本地 Ref、Stash selector 和文件覆写按其真实作用对象保护。远端删除按确认的 remote/完整 Ref 名执行原生 Git 删除，不额外强制 expected-OID lease 或网络二次确认；Force With Lease 仍是用户明确选择的独立 Push 模式。不可变 SHA 的只读/创建动作不因无关 HEAD 变化被禁用，远端失败不能回退写本机。
- 使用已有 SwiftUI `.contextMenu`、原生输入/确认和当前文件树/Diff；不引入 WebView、HTML 菜单、另一套 Git 状态机或无关的页面重设计。

## 非目标

- 不照搬 Git Graph 的主题、列可见性、Branches Dropdown、Issue Linking、PR/Code Review Provider、Mark Reviewed、外部 Difftool 或无限制历史搜索；Kero 当前没有这些专属对象和服务。不额外创造 Git Graph Commit 右键不存在的通用两 Ref / Merge Base 比较器。VSCodium 的 **Ignore** 确实属于工作区/未跟踪文件及目录菜单，必须复用 Kero 现有的 `.gitignore` FileTab 编辑/保存路径实现，**不另建** `.gitignore` 专用编辑器或绕过未保存缓冲。
- 不**自动** Force Push/Force Delete、不自动创建 GitHub Release；用户在 Git Graph 对应弹窗里**明确选定**的 Force/替换操作不是非目标。交互式 Rebase 若被选择，应在 Kero 原生新终端执行，不能在后台假装支持或挪用用户正在工作的终端。
- 不重做已有 Fetch/Pull/Push、Stage/Unstage/Discard、原生文件树或提交框；按对象复用已有动作，可用的缺口必须补齐。不改变既有图谱风格或增加线性/分叉模式切换。
- 不为 Git Manager 增加专门的 VoiceOver 朗读、导航或焦点适配。保留原生控件的基础无障碍语义和常规键盘焦点；只有新的明确需求才安排 VoiceOver 专项验收。P4 当时的执行权限和安全边界保留在历史计划，不继续视为当前实施授权。

## 验收

1. P1～P3 已有图谱、Refs、文件树、提交编辑、刷新与键鼠交互全部不回归；不把 HTML 的模拟菜单当作产品测试。
2. **逐对象逐操作**对照 [P4 菜单矩阵](plan-p4.md#菜单矩阵与边界)，每个应有菜单项必须真实可见/可用或有明确的合法禁用原因；折叠的 `+N` 与直接显示的引用行为一致。
3. 每个适用的 Git Graph 弹窗都与 [P4 对照矩阵](plan-p4.md#原生弹窗行为合同)逐项一致：默认值、选项、确认/取消按钮、重名后的两个后续按钮、失败后的再选择，不能只有同名按钮。在**临时真实 Git 仓库**证明对应 HEAD/ref、index、工作区、reflog、远端 bare repo 与存档实际内容；不是只断言命令构造或 View 回调。
4. 验证取消/拒绝/旧目标不写入；Hard/Force/文件复位/永久 Clean 作用符合说明，包含 Hard 可删除阻挡 tracked 目标的 untracked 路径。未保存和在途保存受保护且失败不关 Tab；冲突保留真实 Git 状态，可从终端恢复。多远端 Delete/Push 的范围、停止顺序和部分结果遵循上游，Tag 已创建后取消 Push 不撤销本地 Tag。
5. 对照原生窗口验证对象命中、禁用、确认对话框、菜单键盘和焦点；保留基础辅助功能标签，不把 VoiceOver 专项语音走查列为本需求的强制项。独立 App E2E（本机与获准的真实 Windows SSH）分别记录，不用 NativeUI 或模拟 SSH 冒充完整验收。全部代码通过 `make test`、`make build` 与严格签名。
6. 完成的阶段任务与提交以 [todo.toml](todo.toml) 为准，历史测试结果保留在 `evidence-p3.md`、`evidence-p4.md` 与审计中。SSH 外部刷新已另行修复：真实 Windows 后端原生面板回归通过，已安装的完整独立 Kero 进程接入 SSH 仓库后，外部 CLI 修改、暂存与提交均在 Git 面板自动更新。PR #14 已合并、Issue #2 已关闭；后续 Stash 图谱修正按本次独立代码提交与审计记录，不冒充原 PR 的一部分。

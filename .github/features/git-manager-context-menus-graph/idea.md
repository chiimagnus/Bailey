# Git Manager：Recent Commits 多分支图谱、Context Menu 与刷新

关联需求：[Kero Issue #2](https://github.com/chiimagnus/kero/issues/2)。

**本次决定：** P1～P3 保持历史完成记录；P4 按 [Git Graph 上游源码](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812) 的对象菜单、原生弹窗选项、默认值和后续动作实现，不只复制按钮名称。Kero 使用原生 SwiftUI / AppKit，不照搬 WebView；事实依据见 [research.md](research.md)，逐项行为合同见 [plan-p4.md](plan-p4.md)。

## 背景

现有 Git Manager 已有仓库标题、分支菜单、Commit Staged、Stage/Unstage/Discard、Fetch/Pull/Push、Stash、文件 Diff、近期提交及懒加载。最初截图与 Issue 记录的问题包括：提交右键只复制、Commit 与 Ref 命中不完整、历史图只画单色直线，以及外部 Git 变更刷新落后。**图谱、Ref 基础交互和本机刷新已在 P1～P3 解决**；本阶段针对 Git Graph/VSCodium 更完整的对象菜单及弹窗行为，不重复修已完成的旧问题。

原 P2 为了缩小实施范围主动省略了 Cherry-pick、Revert、Drop、Reset、Merge/Rebase、远端分支与 Tag 管理等操作；这不符合用户对 Issue #2「参照 Git Graph 与 VSCodium，把适合当前对象的菜单补齐」的最新明确要求。P4 不复制其它产品的整个 UI，但**不再以旧 P2 的非目标排除适用的 Git 操作**。每个动作必须有正确对象、原生命中、Git 真实结果与失败恢复。

已完成的 P1～P3 基线（不是 P4 交付）：
- [调研和已有功能对照](research.md)
- [Recent Commits HTML 设计稿](design.html)：以 Issue #2 的 Git Graph 截图为参考，**只展示 Recent Commits**；一条提交占两行，标题后紧跟 Ref，第二行显示简短 SHA、作者及右对齐时间；蓝色主干与多色侧分支绘制分叉/合并，支持 Commit / 本地分支 / Tag / 历史文件的模拟交互。**这是当时的 HTML 原型而非 App 验收证据**；其 Git 图谱相关部分已在 P1～P3 对应实现，但并未设计 Changes、提交框、仓库工具栏及 P4 完整菜单。

## 实施范围

- **P1～P3（已实施）**：真实提交拓扑与双行视图、Ref 类型与分页、Commit/本地分支/Tag 基础右键、在历史 SHA 创建本地分支和轻量 Tag、本机可见 Git 面板外部变更刷新；保持已有鼠标/键盘命中、文件树、Diff 和失败语义。`design.html` 仅作 Recent Commits 视觉历史参考，不约束 P4 的菜单功能范围。
- **P4：以 Git Graph 为一手基准的右键菜单**：Commit（创建 Branch/Tag、Checkout、Cherry-pick、Revert、Drop、Merge、Rebase、Reset、复制）；本地/远端 Branch（Checkout、Rename、Delete、Fetch/Pull/Merge、Rebase、Push、复制）；Tag（查看详情、创建/替换、删除本地和可选远端、Push、复制）；Stash（每条 Apply/Pop/Drop/从 Stash 创建分支）；Uncommitted Changes（Stash 带消息、Reset Mixed/Hard、Clean Untracked 带目录选项）；历史文件（View Diff、View Revision、与工作区比较、打开文件、Reset File to Revision、复制两种路径）。现有 Staged/Unstaged/Conflict 文件和分组菜单按 VSCodium 的 SCM 习惯保持适用动作。Branch/Tag/Remote Ref 的 Create Archive 在不复制 Web 下载栈的前提下按原生保存流程支持，明确二进制与远端限制。
- **以对象及语义决定菜单**：Commit 行与 Ref Badge 仍是独立命中；`+N` 折叠入口中的菜单与直显 Badge 一致。各对象只暴露有效动作，当前分支不能删除，远端 HEAD 符号引用不作为可删分支，历史文件未必存在于工作区；不以一个通用菜单堆砌所有命令。
- **本机和 SSH 的相同语义**：Git 写操作复用 `GitStatusModel` → `GitCommandExecution` → 当前 `WorkspaceBackend` 的 argv 执行、仓库/机器身份、操作互斥、状态刷新和错误展示；不以本机文件路径操作 SSH 仓库。SSH 实机结果单独验收，不以模拟后端冒充通过。
- **弹窗与副作用要相符**：除文本和字体改用原生控件外，保留上游适用的输入、单选/多选、复选框、默认值、主要/次要按钮及后续分支（包括重名替换/改名、Force Delete、Push Mode、Reinstate Index、Tag 推送警告）。每个按钮落到相应 Git argv 和后续动作；不能用同名但不同效果的命令蒙混。失误可能损失数据的操作须确认目标并在执行前校验，发生冲突时保留真实状态与 Git 错误，用户可从现有 Kero 终端继续/中止；不额外创建上游没有的恢复 GUI 或状态机。
- **原有刷新需求不消失**：P3 已证明本机可见面板外部变化会刷新；Issue #2 对 SSH 的刷新覆盖仍未完成独立验收，不能因 P4 菜单验收而直接关闭 Issue。

## 默认设计与交互

- 左键整行展开/收起提交文件，短 SHA 独立复制；Commit、当前/其他本地分支、远端 Ref、Tag、Stash 条目、文件与分组拥有各自对应的右键动作。`+N` 不漏掉隐藏 Ref 的管理能力；不恢复右键「展开/收起提交文件」冗余项。
- 冲突、进行中的操作及脏工作区决定菜单禁用/恢复动作；没有可用目标或 remote 时说明原因，不展示假的可点击项。Git Graph 的 Drop 只对**拓扑允许且确实能安全改写的当前本地线性历史**开放，合并/共享引用等情形明示不可用，不能用 Reset/Revert 冒充 Drop。
- Checkout 到历史提交须提示 detached HEAD；Commit Reset 默认 Mixed，Hard 只能由用户明确选择；Branch Push 默认 Normal，可按 Git Graph 弹窗明确改为 Force With Lease/Force，Force Delete/Force Fetch/替换同名 Ref 同理明确选择。任何模式都不得悄悄 Force、推送全部 Tag 或发布 Release。
- 操作从菜单打开到真正发命令之间可能切换仓库或改变 HEAD/ref；对话框只捕获当前目标，最终执行时重新核对实际目标与工作区。拒绝过期命令，而不是退回本机或继续对旧仓库操作。
- 使用已有 SwiftUI `.contextMenu`、原生输入/确认和当前文件树/Diff；不引入 WebView、HTML 菜单、另一套 Git 状态机或无关的页面重设计。

## 非目标

- 不照搬 Git Graph 的主题、列可见性、Branches Dropdown、Issue Linking、PR/Code Review Provider、Mark Reviewed、外部 Difftool 或无限制历史搜索；Kero 当前没有这些专属对象和服务。不额外创造 Git Graph Commit 右键不存在的通用两 Ref / Merge Base 比较器。VSCodium 的 **Ignore** 确实属于工作区/未跟踪文件及目录菜单，必须复用 Kero 现有的 `.gitignore` FileTab 编辑/保存路径实现，**不另建** `.gitignore` 专用编辑器或绕过未保存缓冲。
- 不**自动** Force Push/Force Delete、不自动创建 GitHub Release；用户在 Git Graph 对应弹窗里**明确选定**的 Force/替换操作不是非目标。交互式 Rebase 若被选择，应在 Kero 原生新终端执行，不能在后台假装支持或挪用用户正在工作的终端。
- 不重做已有 Fetch/Pull/Push、Stage/Unstage/Discard、原生文件树或提交框；按对象复用已有动作，可用的缺口必须补齐。不改变既有图谱风格或增加线性/分叉模式切换。
- **本次授权只有 `$writing-plan`**：仅更新这份既有 Feature 的需求、研究、阶段计划及任务登记；不修改 Kero 生产代码、不执行 Git 写操作测试、不替换 App，也不借此关闭 Issue。

## 验收

1. P1～P3 已有图谱、Refs、文件树、提交编辑、刷新与键鼠交互全部不回归；不把 HTML 的模拟菜单当作产品测试。
2. **逐对象逐操作**对照 [P4 菜单矩阵](plan-p4.md#菜单矩阵与边界)，每个应有菜单项必须真实可见/可用或有明确的合法禁用原因；折叠的 `+N` 与直接显示的引用行为一致。
3. 每个适用的 Git Graph 弹窗都与 [P4 对照矩阵](plan-p4.md#原生弹窗行为合同)逐项一致：默认值、选项、确认/取消按钮、重名后的两个后续按钮、失败后的再选择，不能只有同名按钮。在**临时真实 Git 仓库**证明对应 HEAD/ref、index、工作区、reflog、远端 bare repo 与存档实际内容；不是只断言命令构造或 View 回调。
4. 验证取消/拒绝/旧目标不写入；用户明确选定的 Hard/Force/文件复位/永久 Clean 只影响弹窗说明的对象，其他用户编辑受保护。合并、Cherry-pick、Revert、Rebase 发生冲突后可恢复；跨项目、跨机器、弹窗期间 HEAD/ref 变化不允许误操作。
5. 对照原生窗口验证对象命中、禁用、确认对话框、菜单键盘/VoiceOver；独立 App E2E（本机与获准的真实 Windows SSH）分别记录，不用 NativeUI 或假 SSH 冒充完整验收。全部代码通过 `make test`、`make build` 与严格签名。
6. 仅计划阶段：`idea.md` 与 `plan-p4.md`、`todo.toml` 任务 ID/锚点一致，所有任务都有正确源文件、验证、文档同步和提交边界；P1～P3 已完成记录不变。Issue #2 的 SSH 刷新缺口必须另行验收，不能仅凭 P4 完成关闭 Issue。

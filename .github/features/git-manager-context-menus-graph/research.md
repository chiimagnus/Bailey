# Git Manager 调研：只补 Kero 真正缺少的部分

对应 [Issue #2](https://github.com/chiimagnus/kero/issues/2) · 设计稿 [design.html](design.html)。研究依据为 **当前 Kero 源码**、用户截图、Git Graph 官方材料，不把 Git Graph 的全量菜单当作 Kero 需求。

## 一手参考

- [Git Graph 仓库 README](https://github.com/mhutchie/vscode-git-graph)：区分 Commit、Branch、Tag、Stash、未提交变更与历史文件的菜单归属，以及图谱、Refs、详情界面。
- [Git Graph Context Menus](https://github.com/mhutchie/vscode-git-graph/wiki/Context-Menus)：参考原生语义和动作分类，**不直接迁移全部菜单项**。Issue 中也附有其 Commit 菜单截图。
- [Apple SwiftUI contextMenu](https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:))：正式 UI 使用 SwiftUI `.contextMenu`；右击对象本身决定 Menu 归属，不在 App 中引入自绘 HTML 菜单。
- Kero 本地 [Git 维护约束](../../../docs/GIT.md)、[安全](../../../docs/SECURITY.md)、[文件与共享树](../../../docs/EDITOR.md)和仓库 [AGENTS.md](../../../AGENTS.md)，以及用户提供的当前界面截图。

## 已经有的功能：无需再做

| 现有代码入口 | 已有行为 | 本次处理 |
| --- | --- | --- |
| `kero/Git/GitPanel.swift` `branchMenu` | 显示当前分支、切换本地分支、从 HEAD 新建分支 | 直接复用；只给需要的 Ref Badge 提供正确菜单命中 |
| `GitPanel.moreMenu` | Fetch、Pull (FF-only)、Push/Publish、Sync、Stash All/Pop、复制仓库路径 | 保留顶部菜单，不再创造独立的 Remote/Stash 管理 UI |
| `GitPanel.commitBox` / `commitMenu` | 提交已暂存、全部暂存并提交、Amend | 不重做提交框，不重做提交功能 |
| `GitEntryRow.menu` | merge/staged/unstaged 不同菜单，Stage/Unstage/Discard，本机 Finder、复制路径、终端插入 | 全部保留；远端和未跟踪删除走原有保护 |
| `GitPanel.changeList`、`TreeDisplayModel`/`TreeFileRow` | MERGE/STAGED/CHANGES、目录压缩、共享行、分组动作与懒加载 | 仅展示/复用；不生成重复树组件 |
| `RecentCommitsView` `changedFile` / `commitFiles` | 点击展开历史文件；打开历史 Diff，复制文件路径；保留 Tree / List 视图 | 不新造历史 Diff、文件管理器 |
| `GitStatusModel` `refresh`/`loadMoreCommits` | 异步刷新、请求 ID、待处理合并、超时、30 条分页、失败/断线反馈 | 在这里和实际事件入口定位刷新延迟，不能直接推翻其既有防护 |

## 确实缺少的增量（有源码证据）

1. **Commit 与 Ref 菜单归属**：`RecentCommitsView.commitRow` 整行放在一个 `Button` 中，右键仅复制 Hash/Subject；`primaryReference` 把一个引用挑成单一字符串胶囊。真实 Tag Badge 尚未独立呈现或拥有自己的 `.contextMenu`。需分离 Commit 行与 Ref Badge 的命中，不能用一个统一的菜单判断“点击位置”的字符串。
2. **选定提交创建 Ref**：`GitStatusModel.createBranch(named:)` 当前用 `git switch -c <name>` 从 HEAD 建立；不能用于“在历史 Commit 建分支”。需要在已有 `perform` 命令/身份校验链下增加指定 SHA 的创建路径，不能重新执行一次 `HEAD` 上的命令。创建、推送、删除 Tag 当前没有模型入口；正式实施时须明确 Tag 名称、源 SHA、远端选择与确认。
3. **真实合并/分叉**：`GitStatusModel.runGitStatus` 已使用 `git log ... %P ... %D` 一次拿到**完整父哈希与引用字符串**；但 `parseRecentCommits` 截断为首个 `parentHash`，`CommitTreeRails` 仅在 X=14 画单直线。应复用已有数据扩展 Model，并在 RecentCommitsView 中布局车道，而不是加一套网络查询。
4. **外部变更没有稳定的刷新触发证据**：`ContentView.syncGit` 监听 app 激活、terminal command completion 与项目切换；`ToolPanelView.pollsSelectedPanel` 明确排除 `.git`，并在 `performSync` 的 `.git` 分支不调用 `git.refresh()`。因此持续前台、外部程序修改仓库的情形**可能缺少刷新触发**。这只是静态可达路径证据，需复现实测后确认是否就是 Issue 的根因；现有 `GitStatusModel.refreshPending` 并发合并本身不是已证实的 bug。

## 精简后的 Context Menu 归属

| 对象 | 复用（已存在） | 真正建议增加 | 不做 |
| --- | --- | --- | --- |
| Commit 行 / 节点 | 复制 SHA、复制标题；单击展开历史文件 | 在指定提交创建本地分支、创建 Tag；明确目标 Commit | 不做 Cherry-pick、Revert、Drop、Merge、Rebase、Reset 的全量 Git Graph 复刻 |
| 当前本地分支 Badge | Top Branch/Menu 已有当前状态、Push、Fetch、创建分支 | 独立 Badge 命中、复制分支名 | 不允许 Checkout 自己 / 删除当前分支 |
| 其他本地分支 Badge | 已有 `switchBranch(to:)` | 独立 Badge 命中、复制分支名 | 不新造分支管理页、远程分支删除 |
| `origin/main` 等已有跟踪引用 | 顶部 upstream 状态、Fetch/Pull/Sync | 显示时区分外观，可复制名称 | **不新增 Remote Branch 右键命令集合** |
| Tag Badge | 历史 `%D` 可能携带 Tag 字符串 | Tag 类型/独立右键；查看 Commit/复制名称；按需 Push Tag、Delete Tag（确认） | 不扩展 Tag 列表页，不能误把 Tag 当普通 Branch |
| 未跟踪/未暂存/已暂存/冲突文件、历史文件 | 现有 `GitEntryRow` / `RecentCommitsView` 上下文菜单 | 只验证正确命中，不重做操作 | 不重复实现文件读取/暂存/删除/恢复 |
| 仓库标题、CHANGES、More、Stash | 现有 Menu / Button / `PanelSectionHeader` | 原布局维持；没有明显缺失则不改 | 不加第二套仓库/分组菜单 |

> HTML 原型允许点选所有这些对象来**验证命中差异**。其中展示的“历史分叉”“Tag”“Staged/Conflict”是合成示例，和当前仓库历史、真实 Stage 状态无关。`design.html` 的自绘菜单是浏览器演示，不是拟议的新 App 菜单组件；正式实现仍为 SwiftUI `contextMenu`。

## 图谱显示及事件边界

- Kero 截图里的长线性历史应继续只有**一条蓝色通道**。测试有真实双父合并时才额外分配侧车道；每次连接必须依据已加载 Commit 的 parent OID。分页边界可能存在未加载父提交：延续可知车道到边界，不能画无法证实的连接。
- Ref 必须解析 `HEAD -> main` / `origin/main` / `tag: v...` 的不同类型；同 Commit 允许多个 Badge。远程分支只作为**引用显示**，没有专门管理菜单。
- 右击 Badge 必须拦截 Commit 行；单击 Commit 展开文件的现有行为保留。历史文件继续使用共享树的键盘/hover/目录折叠语义，不能由 Badge 产生横向滚动或截断错误命中。
- 刷新调查需要区分：(a) 事件根本未触发，(b) 已触发但合并/丢弃，(c) Git/SSH 查询耗时，(d) 新状态未渲染。以外部 CLI 修改 `.github/features` 下文件和提交后的状态为可重复样本；在临时仓库运行，避免污染真实项目。
- 写入 Git 的新增菜单沿用 `GitStatusModel.perform`、`GitCommandExecution` 的独立 argv、互斥、身份和 HEAD 检查。Tag 推送尤其需用户明确执行与选择目标 remote；不能在原型中自动做 Tag/Release。

## 本轮交付边界

- 已调研、生成并使用 Linux Chromium 测试 `design.html`（Commit、Tag、本地分支、不同文件、Esc、窄屏），Mac Feature 目录保存同一 HTML。
- **尚未**修改正式 SwiftUI、未执行 Kero Git 写命令，也未证明刷新缺陷已经修好。后续按 `plan-p1.md`—`plan-p3.md` 实施并实际在本机/已有 SSH 测试环境验证。

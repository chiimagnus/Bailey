# Git Manager：按对象的 Context Menu、真实提交图谱与刷新

关联需求：[Kero Issue #2](https://github.com/chiimagnus/kero/issues/2)。

## 背景

现有 Git Manager 已有仓库标题、分支菜单、Commit Staged、Stage/Unstage/Discard、Fetch/Pull/Push、Stash、文件 Diff、近期提交及懒加载。截图和 Issue 反映的问题是：提交右键只有复制操作；Commit 与 Branch/Tag 引用还没有独立的菜单命中；Recent Commits 只有单色直线，不表达合并/分叉；外部 Git 变更后面板更新有时落后。

最初参考 Git Graph 的完整菜单清单过宽。**本 feature 不复制 Git Graph，也不重做 Kero 已有功能。** 以当前 Kero 原生 SwiftUI 界面和实际数据流为准。

本次已经完成的交付：
- [调研和已有功能对照](research.md)
- [交互式 HTML 设计稿](design.html)：按用户截图还原主要布局；支持右击不同对象、Tag 示例、合成分叉/合并、暂存/冲突示例。**只模拟，不是现有 SwiftUI 功能。**

## 实施范围

1. **最小增量的 Context Menu**：Commit 行、Commit 上的本地 Branch Badge 和 Tag Badge 各自拥有独立命中区域。Commit 保留已有复制 SHA/标题与展开文件，补充「在此创建分支」「在此创建 Tag」。Tag 只补与其身份相符的查看/复制/推送/删除（危险操作须确认）。现有本地分支切换、Push/Fetch 等直接复用现有模型，不造平行实现。
2. **文件和仓库菜单复用**：未暂存、未跟踪、已暂存、冲突文件，以及历史提交文件，继续复用现有 GitEntryRow / 共享树 / RecentCommitsView 的菜单与安全规则。顶部 More Menu、Stash、同步与仓库标题保持原位，不新增“远程分支管理器”“Stash 列表”或重复仓库菜单。
3. **真实图谱**：以 Git 日志的全部 parent hashes 和实际 Ref 关系绘制连续提交车道；只有真实分叉/合并才出现多色连接，线性历史保持当前 Kero 的干净单车道外观。同一 Commit 允许多个有类型的 Ref Badge，Tag 与 Branch 菜单不混淆。
4. **解决刷新迟滞**：以本机、外部 CLI 修改仓库而 Kero 持续前台可见等真实触发场景，查清缺少事件或慢查询的具体位置，再在既有 GitStatusModel 刷新/去重路径修复。不能把手动刷新按钮或伪进度当作修复。
5. **本机 / SSH**：保留现有机器与仓库身份、超时、写操作互斥、远端批量 Git 查询和失败反馈。这里的 SSH 是现有项目运行方式，**不是新增一套 Remote Branch Context Menu**。

## 默认设计与交互

- 单击 Commit 行仍展开其历史文件；右击 Commit 行打开 Commit Context Menu。右击 Ref Badge 只打开该 Badge 所属分支/Tag 菜单，不能穿透到 Commit。
- 当前本地分支不提供“再次 Checkout / 删除当前分支”；普通本地分支仅复用现有切换/复制行为。`origin/main` 仍在图谱中作为跟踪引用，不新增远端分支管理流程。
- 有破坏性或远端发布副作用的 Tag 操作必须明确目标仓库、Tag 与 Remote，在既有操作执行入口执行，不在 View 内自行拼接 Shell 命令。
- HTML 自定义浮层仅服务交互评审；正式产品使用 SwiftUI 原生 `.contextMenu`，不在 App 中引入 HTML/WebView 菜单。

## 非目标

- 不实现 Git Graph 全套 Cherry-pick/Revert/Drop/Reset/Merge/Rebase、分支管理页、PR 创建、Code Review 或任意仓库 Git 历史搜索。
- 不创建 Remote Branch 独立菜单或 Stash 列表；不复制已有 Stage/Unstage/Discard/Fetch/Pull/Push/Sync/More Menu。
- 不切换 Electron/Tauri，不替换 Files/Git 共用树，不引入新第三方图谱引擎。
- **本轮授权仅为设计稿与 feature plan；未获授权前不修改生产 SwiftUI/Git 行为、不操作真实 Git 历史、不发布。**

## 验收

1. HTML 在 Linux 浏览器能打开，视觉结构贴合现有 Kero 截图；右键 Commit/Branch/Tag/文件显示不同菜单，键盘 Esc 关闭，危险操作只模拟确认，移动端不横向溢出。
2. 线性真实提交只显示一条主车道；合成带两个父提交的测试仓库中连线真实反映 merge 分叉，不借装饰线伪造。
3. 右击 Ref Badge 不再触发 Commit 的菜单；仅本机当前存在的对象显示菜单，缺 Tag 时不显示 Tag 的 UI 命中。
4. Git 写操作使用既有 Model/Service 入口；已实现文件、分支和 Stash 操作行为不回归，跨项目/SSH 后不会误写前一仓库。
5. 在可复现的“Git 面板持续可见、外部修改仓库”场景下，状态最终及时更新；核对 Git 实际结果与面板。加载超时/断线仍有明确提示与手动重试。
6. 面向生产实施的每个 task 依据明确源文件与验证条件，可逐项实现；计划本身不冒充生产验收。

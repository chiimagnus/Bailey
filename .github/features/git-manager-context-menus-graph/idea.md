# Git Manager：Recent Commits 多分支图谱、Context Menu 与刷新

关联需求：[Kero Issue #2](https://github.com/chiimagnus/kero/issues/2)。

## 背景

现有 Git Manager 已有仓库标题、分支菜单、Commit Staged、Stage/Unstage/Discard、Fetch/Pull/Push、Stash、文件 Diff、近期提交及懒加载。截图和 Issue 反映的问题是：提交右键只有复制操作；Commit 与 Branch/Tag 引用还没有独立的菜单命中；Recent Commits 只有单色直线，不表达合并/分叉；外部 Git 变更后面板更新有时落后。

最初参考 Git Graph 的完整菜单清单过宽。**本 feature 不复制 Git Graph，也不重做 Kero 已有功能。** 以当前 Kero 原生 SwiftUI 界面和实际数据流为准。

本次已经完成的交付：
- [调研和已有功能对照](research.md)
- [Recent Commits HTML 设计稿](design.html)：以 Issue #2 的 Git Graph 截图为参考，**只展示 Recent Commits**；一条提交占两行，标题后紧跟 Ref，第二行显示简短 SHA、作者及右对齐时间；蓝色主干与多色侧分支绘制分叉/合并，支持 Commit / 本地分支 / Tag / 历史文件的模拟交互。**不是已实现的 SwiftUI 功能，也不设计 Changes、提交框、仓库工具栏。**

## 实施范围

1. **Recent Commits 的 Context Menu**：Commit 行、本地 Branch Badge、Tag Badge 和展开后的历史文件各自拥有命中区域。Commit 保留复制 SHA/标题与展开文件，补「在此创建本地分支」「在此创建 Tag」；当前本地分支只复制名称、其他本地分支复用已有切换/复制操作；Tag 只定位所指 Commit / 复制名称。`origin/*` 只显示为跟踪引用，**不新增远端分支菜单、Tag 推送或删除**。
2. **仅调整 Recent Commits**：历史文件继续复用 `TreeFileRow` 与现有 Diff/复制路径；未暂存、未跟踪、已暂存、冲突文件及仓库标题、顶部 More Menu、Stash、提交框、同步等均保持原样，不在设计稿重复展示或实现。
3. **提交图谱与双行布局**：使用 Git 日志的全部 parent hashes 和实际 Ref 关系绘制蓝色主干、不同颜色的分支及平滑合并线；线条必须来自真实父提交而非装饰。每个 Commit 第一行显示标题及紧随其后的 Ref Badge，第二行显示短 SHA、作者、右对齐相对时间，行间有细分隔线；展开文件后关系线不断裂。**设计稿只展示分叉/合并示例，不提供“线性历史”模式切换**；真实仓库没有分叉时仍需正确绘制单车道。
4. **解决刷新迟滞**：以本机、外部 CLI 修改仓库而 Kero 持续前台可见等真实触发场景，查清缺少事件或慢查询的具体位置，再在既有 GitStatusModel 刷新/去重路径修复。不能把手动刷新按钮或伪进度当作修复。
5. **本机 / SSH**：保留现有机器与仓库身份、超时、写操作互斥、远端批量 Git 查询和失败反馈。这里的 SSH 是现有项目运行方式，**不是新增一套 Remote Branch Context Menu**。

## 默认设计与交互

- 单击 Commit 标题展开历史文件，单击短 SHA 复制完整哈希；右击 Commit 行显示 Commit Context Menu，右击本地分支/Tag Badge 只显示自己的菜单，不穿透到 Commit。
- 当前本地分支只提供复制名称；其他本地分支只复用切换/复制。`origin/main` 等跟踪引用仅展示、不响应专属右键。多个 Ref 允许共存；狭窄空间隐藏 Ref 时必须提供可访问的完整列表（HTML 当前 `+N` 为静态提示，属于实施时需补齐的原型限制）。
- 从历史 Commit 新建本地分支或 Tag，须明确所选 SHA 与当前仓库，复用既有 Git 操作入口；设计稿只模拟创建，不包含 Tag Push/Delete，更不能在浏览设计时触发 Release。
- HTML 自定义浮层仅服务交互评审；正式产品使用 SwiftUI 原生 `.contextMenu`，不在 App 中引入 HTML/WebView 菜单。

## 非目标

- 不实现 Git Graph 全套 Cherry-pick/Revert/Drop/Reset/Merge/Rebase、分支管理页、PR 创建、Code Review 或任意仓库 Git 历史搜索。
- 不创建 Remote Branch 独立菜单、Tag Push/Delete 或 Stash 列表；不复制已有 Stage/Unstage/Discard/Fetch/Pull/Push/Sync/More Menu，也不新增线性/分叉模式切换控件。
- 不切换 Electron/Tauri，不替换 Files/Git 共用树，不引入新第三方图谱引擎。
- **本轮授权仅为设计稿与 feature plan；未获授权前不修改生产 SwiftUI/Git 行为、不操作真实 Git 历史、不发布。**

## 验收

1. `design.html` 作为 Recent Commits 唯一参考：双行提交、标题后的 Ref、蓝色主干/多色侧分支、平滑合并线、短 SHA、作者与右对齐时间；没有额外的 Git Manager 区域和“线性历史”模式控件。HTML 菜单只演示，不执行 Git。
2. 正式 App 根据全部 parent SHA 绘制有真实拓扑的车道；合并、展开历史文件、滚动/分页保持连续，纯线性仓库自然只有一条车道；Ref Badge 可区分当前本地分支、其他本地分支、跟踪引用与 Tag。
3. Commit 行、本地分支、Tag、历史文件的 Context Menu 按对象归属；跟踪引用不提供独立管理菜单，隐藏的 Ref 仍能访问；没有 Tag 就不显示 Tag Badge。
4. Git 写操作使用既有 Model/Service 入口；已实现文件、分支和 Stash 操作行为不回归，跨项目/SSH 后不会误写前一仓库。
5. 在可复现的“Git 面板持续可见、外部修改仓库”场景下，状态最终及时更新；核对 Git 实际结果与面板。加载超时/断线仍有明确提示与手动重试。
6. 面向生产实施的每个 task 依据明确源文件与验证条件，可逐项实现；计划本身不冒充生产验收。

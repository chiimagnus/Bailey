# Git Graph 历史树与 LFS Diff 正确性

关联 [#56](https://github.com/chiimagnus/Bailey/issues/56)、
[#82](https://github.com/chiimagnus/Bailey/issues/82)。

## 要解决的问题

Git Graph 必须完整呈现 Git 报告的历史文件变更；
Git Diff 应显示 LFS 实际文件内容，而不是版本指针。

### #56 历史文件树

- 同一提交中，旧文件／gitlink 被删除、新目录复用其路径时，
  Tree 模式仍完整显示被删除的文件和新目录下的所有新增文件。
  反向的目录→文件转换同样正确。
- 展开后的 Tree 和 List **文件变更、状态、路径一致**；
  折叠、压缩目录、键盘和鼠标导航、路径复制、历史 Diff 操作目标正确。
- 共享 Files、Git Changes、Worktree、Stash 的正常树行为不变；
  不修改 Git Graph 的提交拓扑、刷新机制或真实仓库内容。

### #82 LFS Diff

- 对历史文件／提交差异、暂存区与工作区，正确区分 Git Blob 指针、
  LFS 原文和可编辑工作区原始字节；按正确版本显示真实文本差异。
- 文件不存在、LFS 对象缺失／损坏、读取失败、二进制、
  超过 Diff 5 MiB 上限时明确反馈，不把 pointer、截断结果或失败当正文。
- 不改动用户工作区、Index、HEAD、历史对象或未保存编辑。
  保留本机／SSH 仓库身份、读取取消、重载、保存与 Git clean／EOL 语义；
  不能把指针的 Git Patch 坐标映射到 LFS 正文。
- 不新增自动 LFS 下载／上传功能；LFS 对象尚未在仓库本地可用时
  告知用户由 Git LFS 获取，不在普通 Diff 浏览中偷偷发起远程下载。

## 完成标准

- 只读复现 [真实提交 3eb51c6](https://github.com/chiimagnus/.codex/commit/3eb51c679a51c4ebe0dc4a002239442dc02ceb6c)：
  Git 有 **31 A、2 D、3 M**，展开的 Tree 完整呈现全部 36 条文件变更。
- 用隔离真实 Git 仓库验证同路径文件／目录双向转换、
  历史数据、List／Tree、菜单与键盘，以及共享树调用者。
- 用隔离 Git LFS 仓库验证历史／Staged／Worktree／原文预览，
  真实 CSV 差异、只读边界、异常与 5 MiB 容量边界。
- 使用现有宿主测试、隔离 Bailey Dev 完整 GUI 和仓库要求的构建／测试；
  记录真实结果及无法执行的适用条件，不以低层测试代替 GUI。

只处理这两个 Issue，不提高 Diff 上限、不重设计 UI、不加新依赖或
第二套文本编辑器。具体任务见 [P1](plan-p1.md)、[P2](plan-p2.md)；
唯一进度记录是 [todo.toml](todo.toml)。

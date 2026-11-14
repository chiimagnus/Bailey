# P3：按真实需求处理 Git Diff，并完成用户路径验收

**交付：** 普通文件编辑器与 Git Diff 共用的原生基础保持正确，
大文件支持范围由实际结果决定，全部旧双轨清理完成。
**不交付 GB Diff，也不为 Diff 单独建立新的分页文档体系。**

## 原则

当前 `DiffTab` 分别读取 Git blob／工作树全文，再通过 `DiffEngine`
计算差异并向 `DiffNativeSurface` 提供统一、分栏与编辑投影。
工作区编辑已有单一原生控件；这条链的重点是正确的 Git raw／canonical
比较与交互响应，而不是照搬旧分支外存索引和磁盘 spool。

备份 `back2026-11-14` 的 4／16 GiB Diff 算法与独立实验提供了边界知识，
但没有作为 Bailey 正式可用能力验收。旧分支的重复行、EOL 及折叠修复可参考，
不能未经复测整体 cherry-pick。

## <a id="p3-t1"></a>P3-T1：测量并修复实际 Git Diff 热点

**入口：** `DiffTab.gitContent`／`readWorktreeFile`／`gitComparisonBaseline`、
`DiffEngine.computeLineOps`、`DiffNativeSurface`／`DiffTextView`；
`NativeDiffTabTests`、`DiffEngineTests`、`GitWorkspaceSSHTests`。

- 对 **5 MiB 当前限制**、8／16／32 MiB 真实文本，分别测试 staged、unstaged、
  HEAD／历史只读、单文件与多文件；测读取、比较、构建视图、滚动、展开与内存。
- 修复直接观察到的重复行错误、CRLF／Git EOL 规范化差异、过时结果发布、
  工作区编辑保存错位或折叠坐标过期；先回归后改共享根因。
  比较使用 Git 的规范化语义，真正编辑和写回保留工作树原始字节。
- 复用 P2 的文件身份及原生编辑器，只保留确有用的 Diff 缓存和计算结果。
  删除本任务取代的冗余派生状态，不加第二套 TextView 或 GB 级缓存管理。
- **Diff 容量独立放行**：每档只有在精确内容、实际交互、取消与内存都达标时才开放；
  如果 5 MiB 仍是合理的稳定门限，就保留并提供清晰错误，
  不把编辑器达到 32 MiB 当作 Diff 必须同步达到 32 MiB 的理由。

**验收：** 小改动不被误判成整篇删除／添加；
随机和最坏重复行／Unicode／末尾空行／二进制输入与独立 Git 输出一致；
所有成功展示与编辑都能对应同一个源版本，关闭与取消不继续写入已失效目标。

## <a id="p3-t2"></a>P3-T2：完成全链验收、删除旧路径并交付

**入口：** `FileViewerView`、`SourceTextEditor`、`DiffViewerView`、
`WorkspaceWindowModel`／文件关闭入口，以及 `docs/features/{editor,diff,ssh}.md`。

- 从文件树、Finder 文件、历史／工作区 Diff、重载、另存编码、
  项目关闭与 App 退出逐条核对实际结果；验证鼠标、键盘、中文 IME、
  原生 Find、AX、折行、长行、行号及多窗标签恢复。
- 跑本机真实 32 MiB 完整保存并字节比较、重新打开；
  64 MiB 和 Diff 每档单独做 Go/No-Go，不靠临时扩大容量常量充数。
- 审查从新编辑入口到磁盘的完整调用路径，删除**已经被替代**的旧正文镜像、
  旧保存分支、重复缓存与过时测试；不删仍由 Git／文件其他调用者实际使用的公共逻辑。
  不建立备用兼容通道，验证没有可达的错误回退或写错机器路径。
- 在 `docs/features/editor.md`、`diff.md`、`ssh.md` 写明实际支持容量、
  失败信息、用户可用的终端替代和已知边界；
  旧 GB 研究继续作为 Git 历史，不把它转成当前使用说明或持续待办。

**验收：** `make build`、受影响套件、`make test`、`make build:ui`，
最终 Release 编译与签名按仓库规则完成；测试前后核对真实行为与生成结果。
只有在能够安全隔离焦点时才执行 Bailey Dev 的完整 GUI 用例；
不能抢占用户当前图形桌面，也不擅自搭建虚拟机。
单个任务完成即提交已验证的改动，不推送 `main` 或未获授权的远端。

## 必须逐项验收的条件

| 范围 | 真实条件和结果 |
| --- | --- |
| 文件与容量 | 0、1、5／8 MiB 边界、16／32／64 MiB、超出已证能力、无效 UTF／BOM、NUL、图片、非正规文件；核对打开、拒绝、返回和释放 |
| 原生编辑 | 中文 IME、代理对／组合字符、CRLF、巨行、多光标、Find／替换、选区、滚动、Undo／Redo、A→B→A、关闭后旧对象退役 |
| 保存与恢复 | 短写、权限／磁盘满、同大小／mtime 外部改写、路径替换、保存中继续编辑、连点保存、重命名、窗口关闭、SSH 断连／重连；核对原目标和草稿 |
| Git Diff | staged／unstaged／history、空与二进制、重复行、EOL 规范化、远端失败、视口折叠、切源时取消；对照实际 Git 语义 |
| 环境 | 本机当前支持环境、Debug／Release、签名、本机与**获授权** SSH；GUI 与未能接入的环境逐项列证据缺口，不冒称全部通过 |

这里列的是适用条件，不要求为每个组合创建新框架。
测试使用已有 XCTest、Makefile 与隔离临时文件；
全面执行可安全运行的边界及其关键交互，
不能用单个通过的性能样例替代全套原生、保存或 Git 验收。
若发现未经验证的条件，说明其影响及是否阻止对应容量放行，不通过新增大量防御性代码来掩盖事实。

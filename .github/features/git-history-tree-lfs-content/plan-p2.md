# P2｜LFS Diff 按真实文件内容比较

保留现有 Git Diff 的版本、取消与保存语义；
对已锁定的 LFS 指针按需读取可用的实际内容，
再让历史／Staged／Worktree 走同一原生 Diff。
不创建通用 LFS 缓存管理器或第二份可写缓冲。

## 方案与证据

### 缺陷发生在内容选择与比较坐标

`DiffTab.reload`（`Bailey/Git/DiffViewerView.swift`）按
`Source.commit/revision/staged/worktree/revisionWorktree`
先读 Git 历史或 Index 的 Blob，再读必要的 Worktree 字节。
`gitObject` 用 `ls-tree -z`／`ls-files --stage -z` 锁定
**Git Blob OID**；`gitContent` 以 `cat-file --batch`
校验 Blob 类型、长度及完整读取，然后直接调用
`TextFileEncoding.decode`。LFS 的 Git Blob 是 pointer，
因此现在显示 pointer 而不是真正的 CSV。

`gitComparisonBaseline` 使用
`hash-object --path --stdin` 与 `git diff --no-textconv`
核对 clean/EOL 规则和 Patch 坐标。
这些操作对 LFS 处理的是**pointer 版本**，
不能用得到的行号投影到实际 CSV。
`GitWorktreeComparison.resolve` 的非 LFS 规范化投影
是经过现有测试的正确路径，不应为修 LFS 将它删除。

### 已做的最小 Git CLI 实验

- 一份 30 字节 CSV 在 Git Blob 中是 127 字节 LFS pointer；
  `git cat-file --filters` 在缓存存在时能得到真实 CSV，
  但缓存缺失会试图下载远端对象。另一个隔离实验将历史 LFS 规则
  从当前 `.gitattributes` 删除后，对同一旧 Blob 的 `--filters`
  直接返回 pointer。因此历史读取必须基于**Blob 内容**，不能依赖当前属性。
- `git lfs smudge --skip` 在缓存存在时仍只返回 pointer，
  **不是**离线还原 API；`lfs.storage` 可以改变实际媒体目录，
  不能拼死 `.git/lfs/objects`。
- 对修改后的 LFS 工作文件运行 `git hash-object --path --stdin`
  或 `git diff`，本机隔离实验发现会**新增 LFS 缓存对象**；
  `git status` 在同一实验中未新增缓存对象。
- `WorkspaceBackend.read(maxBytes:)` 已提供本机／SSH 有界读取；
  `WorkspaceFileVersion(data:)` 已有 `CryptoKit` SHA-256，
  `GitCommandExecution.runData` 已有命令、输出与取消边界。
  **全部复用，不新建 SHA、命令执行器或文件读取协议**。

### 读取最短完整路径

只在 `gitContent` 完成**现有 Blob 校验**后识别标准 LFS 指针。
若确认为 LFS，则使用当前 Git 仓库的 `git lfs env`
取得本地 `LocalMediaDir`，按 pointer 的 SHA-256 找到媒体文件；
通过**同一后端**有界读取，以原有 `WorkspaceFileVersion`
核对 size 与 digest，再按原有 `TextFileEncoding` 解码。
这里的 Git Blob OID 仍是指针身份，LFS SHA-256 是媒体身份，
两者不能混用。

这只是一次**选中文件的读取**：不预加载整批历史或 Graph、
不调用会隐式 fetch 的 `--filters`、不自建常驻缓存；
对象缺失／无 Git LFS／损坏／超限时使用现有 `GitContent`
失败通道报告明确错误，保留已加载文本。
LFS v1 pointer 只需读取必要字段，不为不支持的未来扩展
搭解析框架。非 LFS Blob 保持原来的**单次 Git Batch**路径，
不多调用 Git、没有新状态机。

`LocalMediaDir` 解析必须遵循 Git LFS 真实配置与当前机器。
本机已证实自定义 `lfs.storage` 生效；Windows SSH
须在任务开始用**专属临时仓库**验证输出路径格式，
再确定是否能直接使用现有 `WorkspaceBackend.read`。
不能用 Mac 本地缓存替代 SSH 仓库，也不能为读不到对象
退回显示 pointer。

### 只让 LFS 走正文比较

对历史、Staged、两提交、Stash：
各侧依其真实版本取得文本，沿用已有 Git OID 重新核验和
`DiffCore`；不改文件操作目标、Git 拓扑或只读资格。

对 Worktree、Revision ↔ Worktree：
保持磁盘**原始字节**为编辑和条件保存真源，
仅在已确认 LFS 指针／当前 LFS filter 的相关路径跳过
不适用的 pointer Patch 投影；
改为将**实际正文**比较交给已有 DiffCore。
有必要时只读查询当前 `filter` 属性，不能仅凭旧历史属性
判定工作文件的 clean 规则。
Git clean 判断为未变的内容不能画假增删；本机修改、EOL
或属性变化必须与实际 Git 状态交叉校验。
已有非 LFS clean/EOL 快速路径保持不变。

若工作区自身尚是未 smudge 的 **pointer 原文**，
不能把历史 LFS 正文当成可以直接写回的同一原始缓冲：
显示实际内容时保持只读，仍以磁盘 pointer 原字节为保存边界，
不得悄悄“转换”为工作区文件。真实异常下优先明确错误，
不能把失败伪装成正常文本或丢弃原始文件。

## 任务

<a id="p2-t1"></a>
### P2-T1 离线解析锁定的 LFS 指针并读取经校验的真实字节

**位置**：`Bailey/Git/DiffViewerView.swift` 的
`GitContent`、`gitContent`、`firstGitContent`、
`requiredGitContent`；复用
`Bailey/Workspace/WorkspaceBackend.swift` 的 SHA 与有界读取；
测试 `BaileyTests/Git/NativeGitHistoryFileTests.swift`、
`NativeDiffTabTests.swift`。

- Red：真实临时 LFS 仓库历史原文、历史 Diff、Staged 显示 pointer；
  非 LFS 历史读取不变。
- Green：仅在锁定 Blob 后识别 pointer，读取当前机器
  `LocalMediaDir` 内的完整实际内容并校验 SHA／size；
  历史版本与当前 `.gitattributes` 不同也必须返回相同的真实内容；
  验证默认／自定义 `lfs.storage`、Worktree、缓存缺失／损坏、
  5 MiB 边界、二进制、无 Git LFS、错误编码、特殊路径。
  不能向网络发起隐式下载或误操作其它仓库。
- Refactor：删除原先把 LFS pointer 无条件交给
  `TextFileEncoding.decode` 的错误直通路径；
  不复制现有 `WorkspaceFileVersion` 和 `GitContent` 错误体系。
  与代码同时更新 `docs/features/diff.md` 对来源的描述。

<a id="p2-t2"></a>
### P2-T2 用真实 LFS 正文计算差异并守住 Git 规范化与保存边界

**位置**：`Bailey/Git/DiffViewerView.swift`：
`reload`、`gitComparisonBaseline`、`readWorktreeFile`；
仅需要时调整 `Bailey/Git/DiffEngine.swift`；
测试 `NativeDiffTabTests.swift`、
`NativeGitHistoryFileTests.swift`、`DiffEngineTests.swift`。

- 在真实 LFS 仓库先复现 pointer Patch 错行及
  `hash-object`／`git diff` 的不必要缓存写入；
  确认旧 Index、当前 filter 与 Worktree 原字节身份。
- 仅对 LFS 路径改用实际正文 Diff，复用现有后台计算；
  保持 Index OID／原始字节重核、取消与过期结果保护。
  删除与 LFS 错误投影有关的旧判断，保留非 LFS
  `GitWorktreeComparison.resolve` 和有效 clean/EOL 防护。
- 覆盖标准 LFS 正常文件、修改后 Staged／Unstaged、
  历史对工作区、无修改、属性变化、pointer-only checkout、
  读取过程工作区改变、过期请求、重载、Undo、真实保存。
  必须检查真实文件、Index/HEAD 和原生文本，不只检查某个状态字段。
- 同任务更新 `docs/features/diff.md` 的规范化、
  展示与原字节保存约束。

<a id="p2-t3"></a>
### P2-T3 以隔离真实仓库和 Bailey Dev 完成跨来源验收

**位置**：既有
`BaileyUITests/Git/GitHistoryUITests.swift`、
`WorkspaceGitUITests.swift`、
`GitGraphUITests.swift`；
并核对 `Bailey/Git/GitHistoricalFileLocator.swift` 的历史重命名解析；
真实 SSH GUI 入口还须核对 `SSHFolderPickerModel.swift` 的首次握手与路径状态，
必要时核对 `GitPanel.swift`、`RecentCommitsView.swift` 的历史菜单与二进制判定。

- 增补**必要的完整 App** 用户路径：
  展开真实历史 LFS 文件→打开 Diff／只读原文→
  看到实际 CSV 差异；与 Staged／Worktree 交替浏览，
  完整保留 Git Graph 焦点与文件身份。
  低层可证明的内容、错误和边界留在宿主测试，不复制整套 GUI 矩阵。
- 历史重命名的路径定位只比较不可变提交与 Index/HEAD；
  不对实时工作区执行可能触发 LFS clean 并新增媒体缓存的 Git Diff。
  用真实已提交、已暂存重命名和暂存内容降低相似度的场景核对最终路径、缓存与 Git 字节。
- 与 P1 同路径文件／目录样本交叉验证；
  SSH 首次连接期间手动输入目录时不得被默认目录覆盖；
  本机和已授权 Windows SSH 临时仓库核对真实最终内容，
  以及刷新、取消、切换项目和断线恢复。
  如果发现同源缺陷，修复归 P2-T1/T2 的所有者，不加 UI fallback。
- 按仓库要求完成完整宿主测试、受影响完整 App GUI、
  `make build` 和文档／Diff 检查；准确区分通过与阻塞。
  **不替换、不退出正式 Bailey**。

## 阶段验收

**来源**：历史原文、提交对首父、两提交、Staged、
Index／Worktree、Revision ↔ Worktree、Stash；
新增／删除／重命名、非 LFS 混合文件。
SHA-1／SHA-256 Git 仓库；路径含空格、Unicode 与换行；
真实 UTF-8／BOM／非 UTF-8、空、二进制内容。
`GitHistoryUITests` 与 `NativeDiffTabTests` 已覆盖普通来源，
新用例沿用其真实 Git 临时仓库夹具。

**容量与错误**：对象本地有／无、损坏、大小不匹配、
恰好 5 MiB／超限、Git LFS 未安装、
超时／取消／SSH 失联、外部编辑／Index 改变／重试；
保证成功一定是完整媒体字节，错误不覆盖已加载正文，
远端失败不能回退本机。验证读取、保存和 Index/HEAD 的最终副作用。

**界面与性能**：普通 Blob 不增 Git 命令数；
LFS 按选中读取，不后台遍历全部提交；
真实原生 Diff 的文本、折叠、菜单、滚动、键盘与焦点正确。
复用已有测试环境与性能测量，不新增独立性能基建。

**执行命令**：定点
`make test:NativeDiffTabTests,NativeGitHistoryFileTests,DiffEngineTests,GitExecutionTests`，
相关 Git History／Graph/Workspace UI 定点用例；
最终按 `docs/testing.md` 运行 `make test`、
`make build`、需要的完整 App GUI、
`git diff --check`。测试先确认真实夹具前提，
再检查退出码、实际执行数、失败／跳过、磁盘与 Index/HEAD。
不能实测的最低 macOS、真实 Windows SSH 或独占 GUI
逐项标明阻塞、影响、替代证据和补测条件，
不宣称无条件通过。

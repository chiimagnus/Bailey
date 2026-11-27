# Diff 数据来源与字节契约

维护工作区、索引、提交和历史原文的真实读取、编码、Git 规范化及 LFS。数据源、字节或读取边界改变时更新；布局及编辑见 [Diff](diff.md)。

## Invariants

- **历史及索引只读。** 工作区原始字节不与 Git 规范化文本混同。
- **真实对象决定比较端。** 锁定对象 ID、路径与请求身份；不能以截断或失败冒充空内容。
- **容量、编码和机器身份一致。** 不绕过真实数据限制，不在浏览中下载 LFS 或回退本机。

## 来源与字节

来源分别为工作区、暂存区、历史提交对首父的差异、
两个明确选定的 Git 提交之间的差异、选定提交的只读原文、
以及选定提交原文与当前工作区比较。只有普通工作区 Diff 的文本可以编辑和保存；
暂存和历史来源始终只读。干净工作区文件也可以直接编辑；保存不等于暂存或提交。

**字节与编码。** 任一侧超过 5 MiB 或确实包含二进制时不提供文本 Diff；
这一上限独立于 Files 的 32 MiB 完整编辑能力，不能因文件编辑支持更大正文便自动提高 Diff 容量。
Git 历史与 Index 的 LFS 文件先锁定 Git Blob OID，识别 pointer，再从 Git LFS 当前机器的
`LocalMediaDir` 读取真正媒体，按 pointer 的 size／SHA-256 校验后才解码；
自定义 `lfs.storage` 和 Windows SSH 路径由仓库的 Git LFS 环境确定。
LFS 的 5 MiB 上限针对真实媒体正文而非 pointer；本地未缓存、对象损坏、超限或工具不可用时
明确报错，不展示 pointer 冒充内容，也不在浏览 Diff 时隐式联网下载。
历史 Blob 是否为 LFS 由其不可变内容决定，不能受当前 `.gitattributes` 改动影响。
UTF-8、UTF BOM、`coding:` 及 Windows `mbcs` 使用与 Files 一致的严格编码规则，
未能判定的非 UTF-8 文本显示编码选择入口，而不是冒充二进制。
不能先丢掉 NUL、无效字节或进行有损解码再比较；**非 LFS** 路径的
`hash-object --path` 必须接收工作区原始字节，再由 Git 按 `.gitattributes`／clean filter
计算规范化 OID。对旧 Blob 为 LFS pointer、或当前 filter 已变为 LFS 的工作区文件，
直接比较真实媒体与原始可编辑正文，不使用 Git pointer 的 Patch 行坐标，也不运行
会产生 LFS 对象的 `hash-object`／clean filter。仅从 Git 比对 LFS 时重新核对原始字节和旧 OID。
工作区仍是 LFS pointer 占位文件时明确报错，不开放可写 Diff；
文件保存仍执行原有条件写入，不得以 Git 暂存区或 LFS 缓存代替工作区原始字节。
仅编码字节变化、解码后文字相同时，仍显示 Git 变更及编码差异，不误报「无修改」；
带 BOM 的工作区文本遇到 Git EOL／clean 规则时，以原字节计算 Git OID；规范化内容一致则不产生假差异。
Staged／历史为只读；可编辑 Worktree 保存沿用原编码，明确选定新编码时
必须通过[文件标签的严格编码规则](editor.md#读取与编码)，否则拒写并保留草稿。
工作区保存基线来自首次实际读取的**原始字节**，与 Git Index／clean filter 的规范化内容分开；
写入与回执恢复遵循[条件保存](file-saving.md#保存冲突与恢复)。
编码后超过 5 MiB 时拒绝写盘，避免保存成功却无法重新打开。

Git 内容先通过原始 NUL 分隔的 index／tree metadata 精确匹配目标路径，
Index 查询在 Git 端排除目录后代，不允许大量无关条目耗尽元数据容量；
旧文件被目录取代时，历史、暂存和工作区的对应新侧为空，
gitlink 和其它非文本对象仍按原有错误边界处理。
锁定 blob OID 后用一次 `git cat-file --batch` 核对对象类型、大小、完整字节和结束标记，
避免两次独立对象读取。Blob、metadata、patch 和 clean filter 的短输出
在本机与 SSH 的实际进程管道处设独立上限；超限即失败，不能以截断前缀作为成功结果，
其它文件清单及 Git 状态命令不受此限制。
Staged 两侧先并行读取 HEAD 与 Index 的不可变 Blob，发布前重新核对两侧当前 OID；
仓库在并行读取中切换时，不发布任何混合旧／新代次的虚假修改，沿既有快照重试路径重载。
Worktree／Revision ↔ Worktree 的 Git patch 即使 OID 完全匹配，也须在发布前再次读取原始工作区字节；
clean filter 可能在 Git 执行期间改写原始文件，但把不同原文映射成相同 OID。
原文变化沿同一代次重试，不能把过期编辑缓冲当作最新文件。
冲突取 index 0／2／1；只有 HEAD 所指分支引用确实不存在，才允许首次提交的空旧侧；
暂存删除文件的空 index 和有效历史删除提交的空 tree 可以是空侧。
悬空分支、无效删除提交、仅有冲突阶段却没有 stage 0 的 index，以及无效 revision、损坏 metadata、
权限／断线／超时和短读都必须报错。读取失败时展示错误并保留已成功显示的原生文本，
包括之后更换字体或主题；不能把故障变为空文件。折叠展开仅使用对应当前内容的解析结果；
较新读取开始计算后，旧内容的折叠操作不能抢先发布旧文本。

### Git 规范化

工作区 Diff 使用 Git 的清理规则和零上下文差异确认真正改动，再统一交给 `DiffEngine`。
Git 的 `core.autocrlf`、`.gitattributes` 的 `text`／`-text`／`eol` 和 clean filter
决定等价性；Git 的对象 ID 必须与本次读取的工作区内容匹配，
否则整次读取重新开始，不能把不同时间的行号和内容拼起来。
Staged 两个已确定来源的 Blob 可以并行读取；工作区校验必须先完成
`hash-object` 再读取 Git diff，避免 clean filter 改写文件时接受不一致的快照。
当 Git 的规范化文本与工作区原文逐行对应时，单一编辑器保留原始字节和行号，
并直接在原文上显示变化及删除行。
当过滤器改变内容或行数而无法逐行对应时，左侧同时显示 Git 实际比较的规范化差异，
右侧直接编辑原始工作区文件。不能用规范化行号错误定位原文，也不能丢掉被过滤器隐藏的行。
保存成功后重新读取 Git 比较快照；未保存草稿不会被异步读取覆盖。
源文件和可编辑缓冲区不被过滤器改写；Undo、保存始终保持用户编辑的原始字节。
暂存区和历史提交继续使用读取时已锁定 OID 的 Git blob；
未跟踪及无法进行单路径工作区映射的重命名使用原文比较。
Unicode 规范等价不意味着 Git 原文相同。

### 历史与 Stash 来源

图谱中普通提交默认对首父显示 Diff；⌘选择两条普通提交时，
使用真实 `git diff --name-status -z --find-renames --no-ext-diff <旧端> <新端> --`
获取文件范围，再按选定的两端 OID 读取不可变 blob。
新增、删除与重命名分别保持正确的空侧及旧／新路径；两端都必须是有效提交对象，
不能退化为当前工作树或以 merge-base 替代旧端。比较结果与过期操作须按窗口、
仓库、机器及请求身份核对；空结果不等于读取失败或输出截断。
历史 Git Diff 同样支持图谱里的 Stash：已跟踪文件比较 Stash 的基础提交和保存时的树；
第三父提交保存的未跟踪文件按新增文件读取，不与工作区混淆。
查看历史文件原文复用同一标签拥有的原生 TextKit 表面，
不显示整篇「新增行」或空文件的「没有变化」占位。只读原文和 Diff 均允许选择、复制文本，
但不向辅助功能声明值可写，也拒绝直接的辅助功能文本替换。
历史版本对工作区的 Diff 会在重新选中时读取最新工作文件；历史路径已消失时，
先按 Index，再按 HEAD 的 Git 重命名记录定位，必要时继续追踪 HEAD→Index 的二次重命名。
不对实时工作区执行会触发 LFS clean 的 Git Diff；历史 blob 本身保持不可修改。
所有来源共用 5 MiB、真实二进制及严格文本编码校验，
Git 命令失败不能被替换成空内容。

## 验证

`NativeGitHistoryFileTests`、`NativeDiffTabTests` 使用真实临时 Git 仓库核对读取、OID、LFS、编码、过滤器及失败；
`NativeDiffTabTests` 的授权 Windows SSH 用例核对 clean filter、CRLF 及 Staged 只读内容。
环境见[测试环境](../testing-environment.md)，实际展示与写盘见 [Diff](diff.md)。

Git Diff 数据还须按 Git 实际结果验收：Windows `core.autocrlf=true`、LF／CRLF、
`.gitattributes` 的 `text`／`-text`／`eol`、clean filter、暂存区／历史来源与大量重复行；
Git 判断无修改时不得显示整篇增删，必须同时核对原文字节、编辑占位和保存结果。

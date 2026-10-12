# P2：非阻塞打开与纯颜色高亮

**Goal:** 去掉已证实无必要的主线程文件读取与字体样式写入，保持打开、重载、编辑和保存正确。

**Non-goals:** 不改文本引擎，不新建文件状态机，不改变大小/图片政策，不把整份文档预热为高亮缓存。

**Approach:** 第一次加载与干净重载汇入 FileTab 的同一入口，复用现有有界后台 read 和请求代次。文本解码另有明确后台边界；去掉同步初始化读取及重复的发布守卫。高亮只写临时颜色，字体由 SourceTextEditor 负责。

**Acceptance:**
- 菜单、树、分屏与会话恢复的 FileTab 初始化不读取文件；选中视图才开始第一次加载。
- 普通文本读前限额，恰好 5 MiB 可打开，多一字节显示超限，不被吞成普通失败。
- 打开/加载中重命名/重载/保存/断线没有旧结果污染、长期空白或未保存内容丢失。
- 开始高亮、逐 token 着色与清理不再无条件写 .font，不再触发无变化的全文字体设置。
- 同机复测实际文本/可输入/高亮阶段；结论遵循 P1 噪声口径。

**Rules:**
- 首次 .loading 仍是“不具备可编辑文本”，不能暂时当空文本允许用户输入再被读取结果覆盖。
- 本地读取已用同一个 FileHandle、前后 seek 检查与 64 KiB 分块；复用它，不换成 stat 后无界 Data(contentsOf:)。
- NSImage 等 AppKit 对象不直接跨 executor 传递；后台交付 Sendable 数据/文本，UI 对象在正确隔离域创建。
- 字体仍由 SourceTextEditor.apply 管理，保留原生选区、输入法、查找替换和弱视图生命周期。
- 每 task 按 AGENTS.md 构建、验签并用隔离实例真机验收后提交，不以替换或重启正式应用作为验证前提。

<a id="p2-t1"></a>
## P2-T1 统一首次加载和有界后台读取

**类型 / 依赖:** 实现；依赖 P1 完成基线。

**Files / 锚点:**
- Modify: kero/Editor/FileViewerView.swift：FileTab.init、Content、LoadedContent、loadedContent、reloadFromDiskIfClean、updatePath、reevaluateWorkspace。
- Modify: `kero/Workspace/LocalWorkspaceBackend.swift`：删除 `readImmediately`，保留 `readSync` / `@concurrent read`；`WorkspaceBackend.swift` 只有契约与数据类型，不再含本地实现。
- Modify: `kero/Editor/SourceTextEditor.swift`：`apply` 的断线编辑禁用。
- Verify/modify only for the existing reconnect chain: `Project.connectedWorkspace/rebindRemoteTabs`、`SSHHostWorkspaces.setConnected/connectionState`。固定主机与终端交互 SSH 的状态来源不同，不能只测后者。
- Callers to verify, not automatically modify: Project.openFile/openFileToSide/makeContent、FileViewerView.onAppear/didBecomeActive/didBecomeKey。
- New: scripts/check-bounded-file-read.swift，复用现有独立 Swift 编译检查约定，检查真实 WorkspaceBackend 读取而不是复制算法。
- Modify: `scripts/check.sh` 注册新检查；`scripts/check-workspace-identity.swift` 与 `scripts/check-pane-retention.swift` 迁移初始化后立即读写的假设，并覆盖真实 FileTab 生命周期。
- Modify: docs/PERFORMANCE.md 的已实现约束；行为说明仅在需要时更新 docs/EDITOR.md。

**当前链路与根因:**
Project 的三个入口同步创建 FileTab；本地 init 调 readImmediately(.max)，读取/解码或 NSImage 创建之后才检查文本大小。远程 init 启动 reload，onAppear 再启动会取消旧任务；取消 Task 不等于同步 I/O 已停止。`LocalWorkspaceBackend` 当前已是 `nonisolated`，read/list/stat 等已是 `@concurrent`，不是本 task 尚需添加的能力。reload 用 try? 吞掉具体错误，loadedContent 仍在 MainActor；updatePath 假设已有内容，异步首次加载后不成立。SourceTextEditor 当前也未设置 `isEditable`，断线只有横幅，需与既有只读要求一致。

**实施:**
1. init 只保存身份/backend、空基线与 .loading，不做 I/O，也不在 init 启动第二套读取。既有 onAppear 负责第一次加载，未选中的恢复标签保持懒加载。
2. 第一次与干净重载使用同一 loader。普通文本传 maxTextBytes 到 backend.read；捕获 tooLarge 并使用已有超限文案，其他错误保留读取失败，UTF-8 失败保留二进制。删掉不再有消费者的 readImmediately，仅保留 backend 共享 readSync。
3. 复用现有 `nonisolated LocalWorkspaceBackend` / `@concurrent read`，不重写 executor。新增的纯文本解码在最小数据型后台入口完成，遵守当前 approachable concurrency 编译设置；主 actor 不再做大文本解码，不全局关闭隔离设置，不让 caller 各包 detached。
4. 读取后的文本解码在明确后台边界返回不可变结果，主 actor 仅做身份检查和发布。图片仍是现有扩展名策略：保留完整图片读取与主 actor NSImage 构造，不新增上限。无效图片回退原先文本/二进制规则；大图片另测，不宣称该例外已全部有界。
5. 发布只保留拥有实际职责的校验：`reloadGeneration` 拒绝旧读取，dirty/readOnly 拒绝新编辑或断线后的替换。`path` 只经 `updatePath` 改写且先 `invalidateReload`，取消也总伴随代次更新；删除发布处被同一代次覆盖的重复 path/cancellation 判定，不新增第二套身份或状态机。任务结束清对应 reloadTask，旧任务不得清新句柄；维护 matches、savedText、reloadRevision、saveError。
6. updatePath 在 .loading 时取消旧路径并从新路径继续加载；已有文本/图片仍保留原内容和编辑状态。断线时已有预览/未保存编辑不清空，重连只换同机器 backend。
7. 初次 onAppear/窗口激活重复请求先通过统一入口减少；若 P1 trace 仍发现实际重复在途读，用最小请求合并保留最后一次重载，不加通用队列。不得直接丢弃外部修改事件。
8. 不重新设计保存。继续使用原 save 的写入快照与原子 backend.write；重载不覆盖写入期间的新输入。SourceTextEditor.apply 使用原生 `isEditable` 表达断线只读，重连恢复；保留选择、复制和查找，不能只加横幅。
9. 同 task 删除同步 init 分支、init 自动启动的第二套读取、`readImmediately` 及其过时说明；保留仍被同步项目根目录调用的 statSync/gitRootSync/isLinkedWorktreeSync。新检查无须 app 类型壳：backend 文件已经独立。所有直接构造 FileTab 的既有检查显式触发加载并等待 `.text` 后再编辑，测试不得靠睡眠猜时间，也不为旧检查保留同步兼容入口。
10. 沿固定 SSH 主机的实际连接状态闭环：当前 connectedWorkspace 对匹配 sshHost 无条件返回缓存 backend，setConnected 也不是 Project 的通知源，不能认为 banner/isEditable 修复已覆盖它。复用 SSHHostWorkspaces 的状态发布到现有 Project rebind，不新建连接管理者或后台探测循环；首次未知/connecting 仍能由已有选中加载开始连接，已知断线保留预览与编辑。已有面板刷新或选中/激活的显式读取可恢复连接，失败不能清内容；恢复后换正确 backend 并失效旧读取。不能用只读守卫把首次连接或后续重连永久阻断。

**针对性验证:**
- 在 task 内完成 scripts/check-bounded-file-read.swift：
  - 编译 `WorkspaceBackend.swift` 与 `LocalWorkspaceBackend.swift` 的真实生产实现，不提供后端壳或复制读取算法。
  - 临时文件 0、cap-1、cap、cap+1、缺失、可读 symlink 目标；超限捕获 tooLarge，内容和字节正确。
  - 用现有工程并发 flags 编译应用，再用 trace 验证 executor；脚本默认编译语义不能代替 app 语义证明。
- Run（同 task 注册）：`bash scripts/check.sh bounded-file-read workspace-identity pane-retention`；后两项先构建 Debug App。独立检查编译输入为 `WorkspaceBackend.swift LocalWorkspaceBackend.swift scripts/check-bounded-file-read.swift`。
- 扩展实际 App 的 `workspace-identity` 检查：未显示 init 不读取、显式加载成功/超限/失败、延迟旧路径后 rename、干净/脏重载、同机器连接更换与关闭释放；`pane-retention` 在加载后编辑再重挂载。这两项不是单独 backend 读取检查可替代的。
- 真实 Kero：树/打开到旁边/恢复三入口；512 KiB 与 4 MiB 首开，纯文本无高亮与 Swift 分开；等待时能切终端/标签，实际文本出现后能输入、保存并对照磁盘。
- 加载中重命名/关闭、外部修改触发干净重载、脏文本激活窗口、保存失败和写入期间继续输入；有授权 SSH fixture 时检查断线保留与同路径不同机器隔离。
- 冷/热复测证明确少一次初始读、无界超限读消失，记录图片例外和实际可见延迟。旧结果未覆盖不仅看守卫代码，要看最终文本/路径/磁盘内容。

**提交边界:** 加载/解码、断线原生只读、旧读取路径删除、既有检查迁移与必要文档一次原子提交；不重做已存在的 read executor，不包含后续解析/缓存优化。

<a id="p2-t2"></a>
## P2-T2 去掉高亮路径的无效字体事务

**类型 / 依赖:** 实现；依赖 P1，按默认执行顺序在 P2-T1 后。

**Files / 锚点:**
- Modify: kero/Editor/SyntaxHighlightPlugin.swift：SyntaxHighlightCoordinator.init 的字体初始化与 AttributeProvider、SyntaxHighlightTextInterface.clearStyle/applyStyle。
- Verify: kero/Editor/SyntaxHighlighting.swift：theme 的空 fonts；kero/Editor/SourceTextEditor.swift：apply。
- Read-only dependency contract: Vendor/STTextView/Sources/STTextViewAppKit/STTextView.swift：font setter、addAttributes。
- Modify: `scripts/check-editor-highlighting.swift`，扩展 P1-T3 已接入的真实 App 检查，不新建样式测试框架。
- Modify: docs/PERFORMANCE.md。

**当前行为与根因:** Kero 的 theme fonts 明确为空，仍在 coordinator 初始化执行 textView.font = textView.font；该 setter 不比较值，会给整个已装入文档加字体属性。每 token 还带当前 .font，clearStyle 也写回字体，触发文本事务/布局。颜色本来已有 rendering attribute 路径。

**实施:**
1. 去掉当前空字体主题下的无条件字体设置；字体只由 SourceTextEditor 的有守卫配置管理。
2. AttributeProvider 只产生颜色；clearStyle 只清临时 foregroundColor。删掉不再需要的通用“其他属性进文本存储”分支，不为不存在的 per-token 字体保留脚手架。
3. 保留 metadata capture 跳过、themeColor 的别名/逐层回退、零长度 token 守卫和弱 textView 引用。不要修改 token 顺序或语法资源。
4. 除非复测证明颜色应用仍是主要热点，本 task 不引入合并属性事务或依赖补丁。

**针对性验证:**
- 真机同一 Swift/TSX 高密度样本，比较 trace 中高亮产生的字体 setter/addAttributes/编辑事务和布局占用；这些无效字体工作应消失。
- Markdown 空范围、TSX 标签/属性、TypeScript 继承 comment/string、未知类型纯文本、明暗主题、换字体/字号、行号、选区、撤销、查找替换和中文输入。
- 只切视口/完成高亮不改变 text/isDirty，不添加文本撤销动作；实际输入再撤销回保存原文，干净标记正确。文本与磁盘逐字对照。
- 构建、验签后在隔离 Debug 实例复测首屏/可输入/高亮和滚动，若仍慢记录残余热点给 P3，不声称字体改动解决全部解析性能。
- Run: `bash scripts/check.sh editor-highlighting`，断言真实插件高亮前后字体不变、text/isDirty 不变，换字体仍生效；扩展 P1-T3 的现有检查。不能只靠 trace 取代正确性检查，空范围的底层 TextKit 保护仍保留。

**提交边界:** 插件样式精简与事实文档一个原子提交，不顺手改 STTextView。

## 阶段自审与交接

- 核对所有首次加载 caller、加载中 rename 和真实最终保存路径，不只验证“任务发出”。
- 两项改动分开计时，区分去 I/O 与去样式事务的收益。
- 实际完成再进入 plan-task-auditor 并创建 audit-p2.md；规划时不创建。

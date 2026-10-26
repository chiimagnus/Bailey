# File Manager：多选、操作、拖放、隐藏规则与定位

需求归属：[Issue #5](https://github.com/chiimagnus/Bailey/issues/5)。本文保留立项需求与当时的实现基线；任务进度以 [todo.toml](todo.toml) 为准，当前行为见 [Files](../../../docs/features/files.md) 与 [设置](../../../docs/features/settings.md)。Files 的原生焦点基线已复用，不重做旧 `focus-navigation` 方案；[#40 文件事件](../event-driven-workspace-refresh/idea.md) 已落地本机和受支持的 Windows SSH Files 刷新，P4 联动 GUI 验收仍未完成。

## 立项背景（历史基线）

立项基线（`main`，`f3b965f`）：`FileTreeModel.selectedPath`、`TreeKeyboardHost`、单/双击与共享 `TreeRowSurface` 已实现；尚缺 Cmd/Shift 多选。Files 已有压缩目录、懒加载、新建／重命名、单项删除、复制路径、Finder→Files 本机批量复制。`LocalWorkspaceBackend.copyFromFinder` 已用暂存和 `RENAME_EXCL` 防覆盖，不得重写。现有本机 Files 外拖只发布公开 `fileURL`，内部拖放会被 Finder 接收入口误判为复制；SSH 不发布 Mac URL。`WorkspaceBackend` 无通用复制；`ProjectFileIndex` 仅索引本机，Git 失败会误回退全目录扫描。Files 的 `.git` 隐藏在 `FileTreeModel.children` 硬编码；自然排序和目录压缩属于 `TreeDisplayModel`，不重写。

立项时 Files 在前台每 2 秒同步本机／SSH 目录，SSH Git 另有 5 秒刷新；#40 独立负责事件化，本计划不建第二套刷新。**已确认的缺口**：`FileTab.writeCurrentText` 在 await 前捕获路径，`targetGeneration` 只能阻止旧结果回写，不能阻止已发生的旧路径写入；`WorkspaceWindowModel.fileRenamed` 仅遍历当前窗口的 `projects`；工作标签右键 `Reveal in Finder` 不区分 SSH／本机。**已具备而无需重做**：`ToolPanelView.openFilePath` 已通过 `file.workspaceIdentity == filesTarget.workspace` 校验当前文件高亮，且使用 `Project.selectedTab`，不是旧的 `focusedContent`。

## 需求与边界

1. **F1 多选与操作。** 在现有 Files 单行游标与原生焦点上增加 Cmd/Shift 多选、范围锚点、键盘选择、右键／快捷键和统一的复制、剪切、粘贴、副本、移动、批删入口。不新建第二个焦点状态。复制／移动保留文件、目录和链接语义，不覆盖；失败不得丢源或脏编辑。本机删除进废纸篓，远端永久删除必须确认；剪切仅在目标成功后移动。同一 Files 树内操作，跨机器／窗口／项目传输不在本轮范围。
2. **F2 真正的拖放。** 当前**同一个活动 Files 树内**拖动单项／多选项至目录；拖动源来自 F1 已选择的集合，悬停或预览不改变 #13 的真实活动组，成功落地后恢复焦点；默认移动、按 Option 明确复制。必须以**最小私有拖动标识**区别树内文件操作和已有公开 Mac `fileURL`（它在 Finder→Files 中始终是复制），否则本机内部移动会被误识别为 Finder 复制。支持目录行、文件行的父目录、压缩目录链、面板根与空白区，拒绝目标不存在、自身／子目录循环及目标身份失效。Finder→本机 Files 保留已验证的独立导入入口，只在实际共用底层原子复制时复用，不再安排单独的重复整合阶段。**SSH POSIX 路径不得冒充本机 file URL**。不跨项目／窗口、Mac ↔ SSH 或不同远端传文件。
3. **F3 快速打开与文件定位。** 不新增 Files 面板内搜索框、文件名／相对路径过滤或未展开目录递归搜索。保留现有 `⌘P` 专用文件快速打开及 Git tracked/nonignored 规则，仅扩展 SSH 当前项目的文件结果，异步操作须绑定正确项目、机器、根和连接，远端 IO／输出有界，旧结果不能误打开其它机器文件。「在文件管理器中显示当前文件」沿真实路径逐级展开、滚动并高亮；遇到排除规则时临时揭示目标及祖先，不修改持久设置，也不新建文件索引。
4. **F4 文件隐藏与可扩展 Exclude 约定。** 本次实现类似 VS Code `files.exclude` 的**Files 可见性**规则：支持项目根相对的路径／目录 Glob（`*`、`**`、`?`），目录匹配时隐藏整个子树；使用现有全局 `config.toml` 的字符串模式列表，在 #44 负责建立的 **Settings → File Manager** 原生页面提供编辑入口，并可临时显示被排除的项目。默认等价于现行隐藏 `.git`，不默认隐藏其它点文件或 `node_modules`；现有用户升级后显示内容不意外减少。隐藏不删除文件、不改 `.gitignore`／Git Graph／Git 状态，也不隐式改变 `⌘P` 搜索范围。无效规则明确反馈；文件定位可以临时越过规则。**不增加文件排序设置，也不修改共享树原有自然排序。** **为后续其它 Exclude 保留边界，而非现在实现它们**：`search.exclude` 归未来跨文件搜索；`files.watcherExclude` 归 #40 的实际监听范围／可靠性评估。它们可以沿用本任务验证过的纯 Glob 匹配语义，但必须有独立键、独立默认值和独立业务调用，不能使 `files.exclude` 自动改变 `⌘P`、Git 或监听，也不先创建通用 Exclude Manager。暂不支持 VS Code `when` 对象表达式、项目级 `.vscode/settings.json` 或不存在的搜索设置 UI。
5. **F6 外部变更同步的接入验收。** 终端、外部编辑器／Finder 和 Git 分支切换引起的真实变化应反馈到 Files 树、当前选中、多选、临时定位及现有 `⌘P` 文件结果；不覆盖未保存编辑。监听、事件丢失补验、取消及 SSH 轮询回退**由 #40 独立实现**；#5 不重复建设。#40 尚未满足必要验收前，不得以 #5 自测通过冒称整个 F6 已完成。

## 默认行为、身份与数据保护

- **焦点基线**：当前 `FileTreeModel.selectedPath`、`FileTreeScrollView.handleKey`、`TreeKeyboardHost` 与共享树行焦点描边已落地；P1-T1 在它们之上增加多选与修饰键，不新增焦点框架。回归单击、双击、Space、Return、键盘焦点及 Git 树共享行为；若发现基线缺陷，先修最小所有者。只有 Files 真正持有 first responder 才消费 ⌘A/C/X/V。
- 本机／SSH 采用共享 `FileTreeModel`、`TreeDisplayModel`、`WorkspaceBackend`，耗时文件 IO 不阻塞主 actor。当前的目录压缩、Git 装饰、行命中、滚动、主题、本地化及无障碍不得倒退。
- 选中集合与当前文件定位属于当前 Files 项目／根／连接，切项目、机器或通道后不得跨目标复用旧操作。复制／剪切保存来源描述，粘贴时重新确认源与目标属本次允许的**同一 Files 树和机器**，不可仅凭字符串路径判断身份。`PanelContext.Identity` 不携带连接 ID，因此仍须复核后端通道／树代次；操作后的过期回写不能污染新工作区。
- 移动／重命名前必须与受影响 FileTab 的**在途写入和失焦自动保存**完成正确排序；单纯更改 `FileTab.path`、写入完成后检查 generation 不能阻止已经写入旧路径。先保护未保存正文、Undo 和保存目标，再进行磁盘移动，只有成功项重定向打开的文件／目录孩子和项目固定路径。跨窗口同步优先复用现有窗口注册表，先用真实测试证明作用范围；不能造第二套全局协调器。
- 文件夹多选时先归一化父子重叠路径，批处理可部分成功但每项结果必须可见；失败和取消不删除尚未成功移动的源。对重名、权限、符号链接、不可读目录、连接异常，使用现有原生错误与确认机制。
- 全局隐藏配置优先使用 `AppSettings` 已有 TOML 读写、重置和测试约束，设置输入只位于 Settings → File Manager；`cachedDirectories` 保留后端原始列表，**改变规则时只对已缓存层级重新投影；新增可见且需要展开的未读子目录仍按原懒加载补读，不对整树 SSH 重列**；现有 `rebuild` 末尾会剔除未访问目录缓存，Exclude 隐藏后再显现时须明确修正缓存保留策略，不能一边声明零重列、一边逐次丢弃目录内容；临时「显示被排除的项目」只影响 Files 可见层，不更新存储或真实文件系统；`.git` 的默认排除可通过显式规则修改，不能把 Git 隐藏和 Git 忽略混为一谈。

## 非目标

Files 面板内搜索／名称路径过滤／全量目录索引；可配置排序／排序 UI；Markdown/PDF 预览 F5；双文件比较 F7；跨项目／跨窗口拖放传输、跨 Mac 与 SSH 或不同远端主机传输；远端 Server／后台守护程序；第二套文件树／Git 行组件／搜索面板、常驻全仓索引；没有实际调用需求的通用 move/batch/clipboard 协调层。`#3`（SSH 列目录）和 `#4`（SSH 连接复用）按当前实现复核而非照抄旧 Issue 描述。

## 验收全集

- **功能入口**：窗口／分屏／原生控件 Focus 与 Files 行多选要分别真实检查；文件／目录／压缩目录、根及空白区、⌘/⇧ 选择与键盘、右键、快捷键、拖放、Finder 导入、`⌘P`、当前编辑文件定位、Settings → File Manager 中的隐藏规则；全部验证磁盘结果／真实 UI，不能只断言回调。
- **机器／环境**：支持的 macOS 15.6+ 与当前 macOS，Swift 6 中英文、明暗主题、常规／窄侧栏及面板缩放；本机普通目录、Git／Worktree、授权的 Windows SSH/MSYS2，已实际获准的其它远端逐一核验；不同用户／主机别名／端口／目录与多窗口隔离。
- **输入／容量**：空目录、单项、大量项和大目录、深层目录／压缩链、Unicode NFC/NFD、中文、空格／引号／换行、大小写差异与只改大小写、以点开头文件、硬链接、普通／断链／循环／根外软链接，Git 已跟踪／忽略／未跟踪，命中／未命中与无效 Glob。
- **状态／时序**：重复与同时操作、父子多选、同名竞争、目录消失、权限拒绝／只读、跨卷移动结果、复制部分成功、取消、SSH 超时／断线／重连、文件外部移动、外部原子替换及 Git 检出、缓冲区脏／自动保存进行中、索引在途及项目 A→B→A、窗口切换／关闭／重启恢复。对可承受组合全部验证，其余覆盖每个值／极值并展开两两及已知失效组合。
- **性能与清理**：Files 保持已有懒加载，不为名称搜索扫描未展开目录或增加 SSH 查询；仅 `⌘P` SSH 快速打开按其自身任务控制 IO、输出和过期结果，无变化不重复发布，监视内存／CPU／SSH 请求。每个实现任务同步删除本任务取代的旧代码和冗余路径，原子防覆盖、远端真实回滚以及操作身份核对不得因「清理围栏」而削弱；watcher 生命周期仍归 #40。测冷／热目录与 `⌘P`、请求次数、响应中位数和 p95，并核对真实内容。
- **环境缺口**：未实际拥有的 macOS 最低版本机器、授权之外的 SSH 主机、真实网络故障条件及物理外设不能假装通过；执行时对每项写明具体阻塞、替代测试、风险、后续补验和是否阻塞验收。不能用少数示例代替已可安全执行的适用情形。

跨计划归属：原有 Focus 行为已落地，**不再依赖被移除的旧计划**。File Manager 设置页与 Exclude 已完成，现行约束见 [设置](../../../docs/features/settings.md)；[#40 刷新](../event-driven-workspace-refresh/idea.md) 由独立任务实现，P4 只验收其真实通知与 Files／⌘P 的联动。文件高亮继续复用 `ToolPanelView.openFilePath` 的机器与标签校验，不重写已有行为。

测试与证据归属：[docs/testing.md](../../../docs/testing.md)；功能文档分别由 `docs/features/files.md`、`command-palette.md`、`editor.md`、`settings.md`、`ssh.md`、`projects.md` 和 `docs/ui.md` 维护。仅在实现涉及行为的 task 中同步更新，不提前将计划写成已实现事实。

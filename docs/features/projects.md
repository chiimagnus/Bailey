# 项目与工作范围

项目统一承载本机或 SSH 的文件、目录和工作标签。本页负责项目身份、添加及范围选择；这些行为改变时同步更新，连接细节见 [ssh.md](ssh.md)。

## Invariants

- **只有明确添加目录才创建本机项目。** 添加目录不启动终端；打开 Mac 文件只创建或复用当前项目的编辑标签，不因文件父目录产生项目；重复添加目录选择已有项目。
- **项目不是终端的附属品。** 关闭全部终端或项目列表面板不删除项目；关闭项目是独立操作。
- **Files 与 Git 使用同一项目范围。** 面板移动、默认侧栏位置或终端进入同仓库的子目录，不能各自改变范围。
- **身份包含机器与路径。** 本机与远端、不同 SSH 端口的同名路径不能共用标签或结果。

## 所有权与范围选择

**当前实现**由窗口管理者持有项目，`Project` 持有标签、文件树和停靠状态；各面板通过项目的 `PanelContext` 取得后端和身份。项目选择、Dock 组激活、当前展示标签与真实键盘焦点是不同事实；窗口不复制一份项目可写状态。项目的 Files 同步只使用调用方提供的当前目标许可，始终核对所属机器与 `PanelContext.Identity`，不反向读取整个窗口模型；见 [architecture.md](../architecture.md#唯一所有者)。

手动固定目录优先于终端工作目录。自动范围采用会话所在仓库；前台命令进入其他仓库或 worktree 时可跟随，同一仓库的子目录不切换根。

项目名称可以由用户指定；未指定时沿用项目自身的名称解析。不能将临时窗口标题当成项目身份。

### 本机资源打开与手动添加

「添加文件夹」（⇧⌘A）是明确创建／选中本机目录项目的动作；本机文件不再作为新项目添加，历史快照中的 `pinnedFile` 单文件项目仍保持名称、图标、恢复及读写行为。Finder 投放在 **Projects 面板**时，文件打开为已有当前项目中的 FileTab，目录才执行 `WorkspaceWindowModel.addLocalFolders` 添加项目；不复制到现有文件树。重复添加同一目录优先复用原项目，不启动 Shell。「文件 → 打开文件…」（⌘O）和各 Dock 组「＋ → 打开文件…」使用原生多选文件面板；菜单默认在聚焦窗口的当前项目／活动组打开，组「＋」在所属分屏打开。外部文件打开（Finder「打开方式」、Dock、顶部工作标签栏和普通编辑区域）是另一种意图：已在任一 Bailey 窗口打开的 Mac 文件先定位**原项目／原窗口／原标签**，无论该文件是否属于项目目录；否则直接在接收窗口的**当前项目**增加文件标签，即使路径在项目根之外，也不新建或切换到其它项目。当前没有项目时新文件不会自动创建项目，Finder 接收窗口提示用户先添加项目文件夹；显式投递目录仍能添加项目。外部文件多选、同目录或不同目录的文件不根据其父目录自动建项目。

本机资源只交给本机后端。新文件须是可读的普通文件，添加的目录须可读取、可遍历；
不可读资源、命名管道等特殊文件、失效链接、包目录及非本机 URL 不会创建新标签或项目。
已打开的标签仍优先复用，避免权限变化时丢失原缓冲。
原有自动保存仍由项目／标签失焦触发，外部打开不新增另一个写入路径。

系统文件入口使用同一份 `Info.plist` 的 `CFBundleDocumentTypes` 将文本、图片和目录注册为 **Alternate**（备用程序）。`BaileyApplicationDelegate` 在 AppKit 启动阶段注册唯一的 `kAEOpenDocuments` 处理器，从系统 Apple Event 的文件列表还原**整个批次**，再交给 `WorkspaceApplication.openExternalFiles`。不能只依靠 SwiftUI `.onOpenURL`（只传第一个文件，且导致另建工作区窗口），也不保留不会被执行的 `application(_:openFiles:)` 回调。此入口不替换 Finder Service `openInBailey`，也不拦截任意非文件网页 URL。文件声明表示 Bailey 是候选打开程序，**不保证未知／二进制文件可编辑**。

## 切换、关闭与失败

异步根目录查询、文件读取和动作在发布或执行前再次核对发起项目与机器身份。切换后旧结果不得覆盖新项目，也不能因读取失败打开另一个目标。

关闭项目要先处理未保存内容，再结束它自己的终端和标签；保存失败保留项目及编辑内容，规则见 [editor.md](editor.md#保存与关闭)。停靠与窗口动作见 [dock.md](dock.md)。

## 验证

覆盖固定／自动目录、同仓库子目录／不同 worktree、重复添加、同名路径的机器与端口隔离、A→B→A 切换，以及在途结果晚到。使用 `WorkspaceIdentityTests`、`PanelContextTests` 和受影响的工作区 UI 回归；测试入口及真实 SSH 边界见 [testing.md](../testing.md)。

实现入口：[Project.swift](../../Bailey/Workspace/Project.swift)、[WorkspaceWindowModel.swift](../../Bailey/Workspace/WorkspaceWindowModel.swift)、[WorkspaceApplication.swift](../../Bailey/App/WorkspaceApplication.swift)。

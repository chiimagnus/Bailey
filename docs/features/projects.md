# 项目与工作范围

项目统一承载本机或 SSH 的文件、目录和工作标签。本页负责项目身份、添加及范围选择；这些行为改变时同步更新，连接细节见 [ssh.md](ssh.md)。

## Invariants

- **添加目录不启动终端。** 添加文件同时打开编辑器，以父目录作为工作范围；重复添加选择已有项目。
- **项目不是终端的附属品。** 关闭全部终端或项目列表面板不删除项目；关闭项目是独立操作。
- **Files 与 Git 使用同一项目范围。** 面板移动、默认侧栏位置或终端进入同仓库的子目录，不能各自改变范围。
- **身份包含机器与路径。** 本机与远端、不同 SSH 端口的同名路径不能共用标签或结果。

## 所有权与范围选择

窗口管理者持有项目，`Project` 持有标签、文件树和停靠状态；各面板通过项目的 `PanelContext` 取得后端和身份。具体装配见 [architecture.md](../architecture.md#唯一所有者)。

手动固定目录优先于终端工作目录。自动范围采用会话所在仓库；前台命令进入其他仓库或 worktree 时可跟随，同一仓库的子目录不切换根。

项目名称可以由用户指定；未指定时沿用项目自身的名称解析。不能将临时窗口标题当成项目身份。

### 本机资源打开与手动添加

「添加文件或文件夹」是明确创建／选中项目的动作：手动添加单个文件保留自己的 `pinnedFile` 项目、项目名称及文件图标；从 Finder 将文件／文件夹放在 **Projects 面板**也走 `TerminalManager.addLocalItems`，不是复制到现有文件树或打开通用标签。重复添加同一范围优先复用原项目，不启动 Shell。外部文件打开（Finder「打开方式」、Dock、顶部工作标签栏和普通编辑区域）是另一种意图：已在任一 Bailey 窗口打开的 Mac 文件先定位原标签；否则优先使用真正包含该路径的本机**目录项目**，而不是把另一个文件塞进手动单文件项目。没有合适项目时才按文件父目录创建；批量同目录的不同文件共用一个目录项目，目录本身不启动 Shell。

本机资源只交给本机后端。规范化路径和符号链接按文件系统事实判断；失效链接、包目录及非本机 URL 不被当成普通目录项目。原有自动保存仍由项目／标签失焦触发，外部打开不新增另一个写入路径。

系统文件入口使用同一份 `Info.plist` 的 `CFBundleDocumentTypes` 将文本、图片和目录注册为 **Alternate**（备用程序）。`BaileyApplicationDelegate` 在 AppKit 启动阶段注册唯一的 `kAEOpenDocuments` 处理器，从系统 Apple Event 的文件列表还原**整个批次**，再交给 `TerminalManager.openExternalFiles`。不能只依靠 SwiftUI `.onOpenURL`（只传第一个文件，且导致另建工作区窗口），也不保留不会被执行的 `application(_:openFiles:)` 回调。此入口不替换 Finder Service `openInBailey`，也不拦截任意非文件网页 URL。文件声明表示 Bailey 是候选打开程序，**不保证未知／二进制文件可编辑**。

## 切换、关闭与失败

异步根目录查询、文件读取和动作在发布或执行前再次核对发起项目与机器身份。切换后旧结果不得覆盖新项目，也不能因读取失败打开另一个目标。

关闭项目要先处理未保存内容，再结束它自己的终端和标签；保存失败保留项目及编辑内容，规则见 [editor.md](editor.md#保存与关闭)。停靠与窗口动作见 [dock.md](dock.md)。

## 验证

覆盖固定／自动目录、同仓库子目录／不同 worktree、重复添加、同名路径的机器与端口隔离、A→B→A 切换，以及在途结果晚到。使用 `WorkspaceIdentityTests`、`PanelContextTests` 和受影响的工作区 UI 回归；测试入口及真实 SSH 边界见 [testing.md](../testing.md)。

实现入口：[Project.swift](../../Bailey/Workspace/Project.swift)、[TerminalManager.swift](../../Bailey/Workspace/TerminalManager.swift)。

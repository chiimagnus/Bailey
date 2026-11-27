# Bailey 文档

本目录维护当前实现及开发约束。开始修改前先读 [AGENTS.md](../AGENTS.md)，
本地开发从 [development.md](development.md) 开始。

每页只负责一件事，并有明确的更新时机。文档与实现冲突时先查源码、配置和验证结果；
修正过时说明，不能把计划当成已经具备的能力。改动使文档失效时，在同一提交中更新。

## 核心文档

| 文档 | 职责 | 什么时候更新 |
| --- | --- | --- |
| [architecture.md](architecture.md) | macOS 范围、单一状态所有者、依赖方向、动作意图与窗口焦点边界 | 平台范围、状态真源、交接意图、模块职责或依赖方向改变 |
| [standards.md](standards.md) | Swift、命名、并发、注释、简化与性能原则 | 开发约定或平台基线改变 |
| [testing.md](testing.md) | 完成标准、测试层次、执行入口与通用验收 | 测试入口、覆盖范围或验收要求改变 |
| [testing-environment.md](testing-environment.md) | Dev 隔离、原生 GUI／SSH 夹具与清理 | 测试环境、授权或夹具改变 |
| [testing-performance.md](testing-performance.md) | 性能目标、测量方法与容量、长会话、释放证据 | 性能目标、场景或测量方式改变 |
| [development.md](development.md) | 环境、本地构建与安装 | 工具链、构建入口或安装流程改变 |
| [dependencies.md](dependencies.md) | 第三方依赖、本地补丁与生成资源 | 依赖、补丁、资源来源或生成方式改变 |
| [release.md](release.md) | Tag 发布、版本、打包和分发流程 | workflow、版本规则或分发方式改变 |
| [signing.md](signing.md) | 签名身份、证书、权限与验证 | 签名配置、证书或打包验证改变 |
| [ui.md](ui.md) | 主题、共享组件、字体、交互、无障碍和本地化 | 视觉规则、组件、交互或文案体系改变 |

## 功能文档

每页在简短用途说明后，以 `## Invariants` 作为第一个二级标题，说明修改此功能不能破坏的约束及原因。
随后解释所有权、内部机制、失败与恢复和验证入口；必要的调用路径与源码链接保留，不转录完整符号清单。

### 工作区与输入

| 文档 | 负责什么 | 什么时候更新 |
| --- | --- | --- |
| [projects.md](features/projects.md) | 项目身份、添加、工作范围和切换 | 项目或面板范围改变 |
| [dock.md](features/dock.md) | 停靠布局、标签、焦点交接与面板切换 | 布局、移动、关闭或焦点规则改变 |
| [windows.md](features/windows.md) | macOS 窗口、系统菜单、Finder 投递 | 系统入口、窗口路由或生命周期改变 |
| [terminal.md](features/terminal.md) | Shell、终端表面、输入与查找 | 终端生命周期或输入输出改变 |
| [notifications.md](features/notifications.md) | 会话通知、定位与 Bark 推送 | 通知路由、分发或凭据改变 |
| [command-palette.md](features/command-palette.md) | 命令面板、文件搜索与会话定位 | 搜索、选择或命令接入改变 |
| [session-restore.md](features/session-restore.md) | 窗口快照、恢复与终端历史 | 持久化内容、格式或恢复行为改变 |

### 文件与编辑

| 文档 | 负责什么 | 什么时候更新 |
| --- | --- | --- |
| [files.md](features/files.md) | 共享文件树、目录导航与刷新 | 树行、导航或刷新改变 |
| [file-operations.md](features/file-operations.md) | 新建、复制、移动、删除与剪贴板 | 文件操作、拖放或目标保护改变 |
| [file-viewer.md](features/file-viewer.md) | 文件身份、读取、格式分流和预览资源权限 | 文件打开、重载、展示模式或资源访问改变 |
| [editor.md](features/editor.md) | 原生文本缓冲、编码、输入法与布局 | 文本编辑、编码或布局改变 |
| [syntax-highlighting.md](features/syntax-highlighting.md) | 增量解析、查询共享与语法着色 | 解析器、查询、坐标或着色改变 |
| [find.md](features/find.md) | 内容查找、替换和共享浮层 | 搜索语义、范围、快捷键或焦点改变 |
| [file-saving.md](features/file-saving.md) | 条件写入、冲突恢复与关闭保护 | 保存、数据恢复或文件／Git 操作保护改变 |

### 专用文件预览

| 文档 | 负责什么 | 什么时候更新 |
| --- | --- | --- |
| [markdown-preview.md](features/markdown-preview.md) | Markdown 阅读、源码定位、富内容与选择 | 阅读排版、语义、导航或渲染改变 |
| [csv-table.md](features/csv-table.md) | CSV／TSV 原生表格、编辑和批量操作 | 分隔解析、表格交互或数据投影改变 |
| [html-preview.md](features/html-preview.md) | HTML 静态排版、安全资源与显式浏览器运行 | 静态渲染、资源限制或运行入口改变 |
| [svg-preview.md](features/svg-preview.md) | SVG 矢量显示、缩放与 PNG 输出 | 矢量解析、几何、渲染或导出改变 |
| [image-preview.md](features/image-preview.md) | 栅格解码、图形视口与 GIF | 图片解码、缩放或动画改变 |
| [image-annotations.md](features/image-annotations.md) | 图片标注、旁车与合成输出 | 标注、版本、配对或输出改变 |
| [media-playback.md](features/media-playback.md) | 音视频解码、AVKit 播放与嵌入媒体 | 格式验证、控件或播放生命周期改变 |

### Git

| 文档 | 负责什么 | 什么时候更新 |
| --- | --- | --- |
| [git.md](features/git.md) | 仓库状态、刷新、操作资格及执行环境 | 状态读取、缓存、目标绑定或命令环境改变 |
| [git-changes.md](features/git-changes.md) | 工作区／索引文件、选择、暂存、弃置与提交 | Changes 交互、文件操作或提交草稿改变 |
| [git-graph.md](features/git-graph.md) | 历史图谱、工作树与引用展示、导航 | 历史分页、图谱、选择或标签展示改变 |
| [git-operations.md](features/git-operations.md) | 提交、分支、Tag、Worktree 及 Stash 操作 | Git 命令、确认或目标校验改变 |
| [diff.md](features/diff.md) | 差异算法、原生渲染、编辑与重挂载 | Diff 布局、算法或编辑改变 |
| [diff-content.md](features/diff-content.md) | Diff 来源、字节、编码、规范化与 LFS | Git 比较端、读取或过滤规则改变 |

### 浏览器、连接与配置

| 文档 | 负责什么 | 什么时候更新 |
| --- | --- | --- |
| [browser.md](features/browser.md) | 浏览器标签、导航与开发服务入口 | WebView、地址处理或导航改变 |
| [ssh.md](features/ssh.md) | 远端身份、后端、断线和重连 | 连接、远端操作或目标绑定改变 |
| [tunnels.md](features/tunnels.md) | 长期 SSH 隧道的配置与生命周期 | 转发、认证或监听规则改变 |
| [settings.md](features/settings.md) | 偏好、配置文件和即时应用 | 设置项、读写或默认值改变 |

## 根目录入口

[中文 README](../README.md) 与 [English README](../README.en.md) 面向用户，负责能力、安装和使用；
[CONTRIBUTING](../CONTRIBUTING.md) 负责贡献流程；[SECURITY](../SECURITY.md) 负责漏洞报告和安全范围；
[NOTICE](../NOTICE.md) 负责来源与第三方声明。AI 开发规范只维护根目录的 `AGENTS.md`。

## 文档维护

1. 先确定受影响功能及其文档，核对真实入口、状态所有者和最终结果，再修改规则。
2. 一个事实只在一个位置详细维护。入口、贡献指南和 PR 引用它，不复制命令清单、测试矩阵或整段约束。
3. 新增、移动、合并或删除页面时，在同一任务和提交中更新本索引、入口和现行引用，
   核对真实文件名大小写及标题锚点。功能页必须给出不变量、更新时机和验证入口；
   不能把必要文档同步留到最后阶段。
4. 当前进度、阻塞和下一步保留在既有任务真源；需求和非目标保留在需求文档；失败试验保留在实施证据。
   已有 `.github/features/<功能>/` 使用 `idea.md`、`todo.toml`、`plan-pX.md` 分别维护需求、
   任务状态和实施路径，不另建同义看板。
5. 现行计划随文档迁移修正入口；已完成的审计、提交说明与失败证据保留当时语境。
   旧计划前提被后续实现推翻时，在其入口明确失效范围，不能把已停止路线重新列成待办，
   也不能未经验证改任务状态。长期教训提炼为有原因、适用范围和验证方法的规则。
6. 区分已实现、已验证、已安装和已发布；没有实测的结果明确标注。
   维护完成前重新枚举文档，核对漏页和并行变更；
   本地链接检查的排除范围要明确，全部文档核对不等于全源码或产品验收。
7. 保留产品定位和作者原意，当前页面直接讲本项目，来源和迁移差异集中在 NOTICE。
   普通事实、职责及链接维护不附加渲染预览或字符级排版检查。
8. 手写 Markdown 正文按语义软换行，通常不超过 100 显示列；
   不拆开代码块、表格、长链接，也不改变原有段落和列表结构。

本体系采用 Tinycast 的“短入口 → 核心职责 → 功能不变量 → 贡献与验收”组织方式，
参考来源见 [NOTICE](../NOTICE.md#文档体系来源)。

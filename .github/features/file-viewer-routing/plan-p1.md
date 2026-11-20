# P1｜复用既有 FileTab 分发，按需接入真实渲染器

Bailey 已有主文件展示入口，不需要预先开发渲染框架。
**本阶段仅随第一种真正可用的渲染器执行接线**；在渲染器准备好之前，
不做无用户收益的纯类型重构，也不新建插件系统。

## 源码核对与决策

文件打开和恢复有两条入口：

- Files／`⌘O` 等通过 `Project.openFile`，Finder 本机文件通过 `Project.openLocalFile`；
  同一项目内按路径和机器身份复用 `FileTab`。
- 会话恢复使用 `Project.restoreTab → makeContent` **直接创建 `FileTab`**，
  并非调用 `openFile`。这两条入口最终共享 `FileTab` 的惰性读取。
  `TabSnapshot.localFile` 缺失时按远端身份恢复，是已有 `SessionStoreTests` 验证的旧快照行为；
  本计划不修改会话格式，也不误删这段身份兼容。

真实数据流位于 `Bailey/Editor/FileViewerView.swift`：
`loadIfNeeded / refreshWhenSelected → reloadFromDiskIfClean → readContent → loadedContent → Content`。
`FileViewerView.body` 已经是主内容单一分发位置；
`Bailey/UI/Panes/TabSwitcherView.swift` 的 `TabContentThumbnail.filePreview` 还会读取同一 `Content`
生成轻量缩略图，新增 `Content` 分支时不能漏掉它。
`PanelContentView` 只交接文件标签，不应增加格式判断。

`imageExtensions` **只有一份集合**。
`readContent` 用它决定是否走超过 32 MiB 的图片读取路径，
并检查 `stat`、64 KiB 真实格式头、256 MiB 读取上限；
`loadedContent` 再用 ImageIO 验证并限制 3200 万像素、4096px 首帧缩略图。
这是 583e9cba 引入且已有回归的两阶段数据保护，**不是重复或兼容遗留，应保留**。
`loadedContent` 仍可将小型、有效的“图片后缀文本”交回 TextKit，不应按后缀强制变图片。

`SyntaxHighlighting.language(for:)` 的扩展名表负责源码语法，
`MaterialFileIcon` 负责图标；它们和**渲染器能力**是不同的事实，不合并。
`FileTab.Content` 目前仅有 `.text`、`.image`、`.loading`、`.unavailable`：
这四种结果已经足够支撑现有界面，不能额外建立 `FileKind`、Registry 或预留七种 case。

**实际接入方式：**

- Markdown／CSV／SVG／HTML：继续按已有文本编码和 32 MiB 上限得到 `.text`；
  真实预览 View 就绪后，才在 `FileViewerView` 的 `.text` 分支根据路径和该格式自己的模式选择展示。
  源码仍是唯一 `NSTextStorage`，未知／不支持的内容不丢失，仍显示原生源码。
  **重命名跨后缀**时不能只凭新名称立即隐藏旧编辑器或草稿；
  先保留当前已加载内容及撤销状态，确认新的有效内容／用户明确切换后才重设展示。
- 图片：仍是经 ImageIO 确认的 `.image`；图片查看功能真正就绪时，
  **同一任务直接替换旧的静态图片展示**，不能并存第二条缩放、滚动或渲染路径。
- 音／视频：二进制不能冒充 `.text`，也不能在当前 32 MiB 文本读取后再决定播放。
  对应功能实现时，才在 `FileTab` 的真实读取入口使用获授权本机媒体 URL 和 AVFoundation，
  并同步更新 `Content`、`loadIfNeeded`、`matches`、错误／刷新分支及标签缩略图。
  SSH 媒体按 [音频](../audio-file-playback/plan-p1.md)／
  [视频](../video-file-playback/plan-p1.md) 的不支持约定明确拒绝，不退回同名本机路径。

不修改 `Project`、Dock 布局、系统主菜单、标签焦点或会话持久化来实现格式判断。
`⌘⇧V` 仍由 [Markdown P1-T2](../markdown-live-preview/plan-p1.md#p1-t2) 在系统 File 菜单注册一次；
`FileViewerView` 不单独监听快捷键。
格式功能详见 [Markdown](../markdown-live-preview/idea.md)、
[CSV](../csv-table-view/idea.md)、[SVG](../svg-source-preview/idea.md)、
[HTML](../html-live-preview/idea.md)、[图片](../image-annotations/idea.md)、
[音频](../audio-file-playback/idea.md)、[视频](../video-file-playback/idea.md)。

## 任务

<a id="p1-t1"></a>
### P1-T1 核销现有读取链路，只修改首个渲染器真正需要的部分

- **位置**：`FileTab.readContent / loadedContent / reloadFromDiskIfClean`，
  `BaileyTests/Files/FileTabPersistenceTests.swift`；
  参考 `Project.openFile / openLocalFile / restoreTab` 的真实调用路径。
- **实施**：以首个已实现的格式 View 为前提，先核对该格式是否仍走现有文本／图片路径。
  Markdown、CSV、SVG、HTML 仍为 `.text` 时**不要改动读取链路**；
  若最先接入的是音／视频，才新增受控本机媒体加载，并同步处理
  首读、刷新、匹配、过期回调、关闭与不可用状态。
  绝不因为已知七种扩展名就预建 `FileKind`，也不将 `SyntaxHighlighting`／图标的扩展名表合并进读取层。
  被真实新读取路径取代的分支**在本任务立即删除**，不保留并行路径或“以后再删”的 fallback。
  `imageExtensions` 两处消费、真实头探测和有界读取已有有效用途，不属于待删旧代码。
- **验证**：用现有图片大文件、伪装图片、符号链接、32 MiB 文本边界、不可读及二进制回归
  证明真实文件仍正确打开或拒绝；新增读取类别时核对实际 IO 目标和字节上限，
  及本机与 SSH 同名路径不串读。
  若没有必要修改此处生产代码，直接记录“不需改动”的核验结果，
  **不得为了形成提交而添加转发类型或虚构代码提交**。

<a id="p1-t2"></a>
### P1-T2 接入真实预览，维护唯一主视图与标签缩略图

- **位置**：`FileViewerView.body` 的 `switch file.content`；
  新增 `Content` case 时同时核对 `FileTab.loadIfNeeded / matches / reloadFromDiskIfClean`
  和 `Bailey/UI/Panes/TabSwitcherView.swift` 的 `TabContentThumbnail.filePreview`；
  `SourceTextEditor`、`PanelContentView` 和菜单仅核验，不为分发创建另一层入口。
- **实施**：等实际渲染 View 就绪，直接在现有 `.text`／`.image` 分支放置该 View；
  源码视图继续使用唯一 `FileTab.nativeTextStorage`，保存、撤销与编码仍只走原链路。
  需要新 `Content` case 时，立即补上标签切换器的**有界缩略图或明示占位**；
  切换器不得另读整份文件、创建第二个播放器或对 32 MiB 文件全文排版。
  新图片 View 就绪时删除被替代的 `ScrollView + Image(nsImage:)` 旧展示；
  文本视图遵守各自的**现有计划默认模式**：Markdown／HTML 默认源码，CSV 默认表格、SVG 默认图形；
  默认源码的预览必须通过该格式计划中的系统菜单／标签右键实际可达，不能只挂一个用户无法打开的隐藏 View。
  不把“支持渲染”误写成“所有格式默认预览”，未实现格式仍走 `SourceTextEditor`。
  不提前改 `PaneTab`、Dock、主菜单或恢复数据格式。
  此任务同步更新 `docs/features/editor.md`；只有真正改变依赖归属时才更新 `docs/architecture.md`。
- **验证**：从 Files、系统 `⌘O`、Finder、会话恢复（独立 `restoreTab`）、多窗口／Dock
  打开并切回，核对实际 View、原生第一响应者、Tab 身份、缩略图、源文字节和 Undo；
  载入中、失败、断线、重命名、脏稿及关闭后过期任务不能显示错文件或泄漏资源。
  **旧格式零 UI/UX 变化**；新格式的可见差异由其自身 Feature Plan 验收，
  不把“渲染器工厂已注册”当作成功。

## 阶段验收

**开始条件**：已有某一格式的真实可用渲染 View，且该格式计划明确需要接入现有 `FileTab`。
如果尚未实现任何新 View，**不单独执行本计划来增加空壳代码**；
T1 可以记录无需改动的结论，T2 不能以空注册或临时占位宣称完成。

- **文件与边界**：旧文本、空文件、`SKILL.md`／`.mdx`、CSV/SVG/HTML 文本、
  大小写／无后缀／多重后缀及中文／emoji 路径；
  正常图像、有效图片后缀的纯文本、伪装的大文件、损坏／NUL／非法编码、
  符号链接、非普通文件、缺失及无权限文件。
  核对 32 MiB 文本、256 MiB 图片、3200 万像素与 4096px 缩略图仍由原路径限制。
  新格式还需覆盖该格式计划的完整输入矩阵，不把“路由正确”冒充解码／渲染通过。
- **身份与时序**：新开与重开、`openLocalFile`、独立 `restoreTab`、
  同一项目复用、跨窗口 Finder 复用、本机／SSH 同名路径；
  干净／脏稿刷新、编码保存、外部修改和保存冲突、改名跨后缀、
  旧读取乱序、断线／重连、视图卸载／重挂载、真实关闭和旧资源释放。
  核对文件实际字节、原生正文对象、Undo、请求目标与 `TabSwitcherView` 缩略图。
- **宿主测试**：按触及路径运行
  `make test:FileTabPersistenceTests,NativeContentIdentityIntegrationTests,NativePaneRetentionIntegrationTests,WorkspaceIdentityTests,SessionStoreTests,FinderDeliveryIntegrationTests`；
  改动高亮／重命名路径时补 `NativeSyntaxHighlightingTests`，需要源文件及菜单能力时补对应格式测试。
  功能代码完成后执行 `make build` 和 `make test`，以完整退出状态与结果为准。
  每个任务当场删除确已替代的旧分支，复查没有新增 `FileKind` 空枚举、镜像正文或双重展示。
- **真实 GUI 与环境**：只在隔离 Bailey Dev 进行 Files／Finder／Dock／多窗口实际打开和展示回归；
  新格式的视觉、菜单、焦点、手势等由其 Feature Plan 验收，旧格式零 UI/UX 变化。
  真实 SSH／Windows 环境和独占图形会话若不可用，分别写清未测的条件、影响和补验方法；
  没有远端证据不宣称 SSH 行为全面通过，也**不因未涉及远端的纯文本分发要求而虚构 Windows SSH 阻塞**。
  对照 [测试标准](../../../docs/testing.md#完成标准) 完成检验、文档同步和 `git diff --check`。

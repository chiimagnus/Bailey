# P1｜沿现有文件标签复用多格式预览

Markdown 已在 `swift-markdown` 分支接入文件标签、原生编辑器、Dock 并排和 File 菜单。
本计划不再等待“首个渲染器”，也不单独实施空壳路由；
**在接入下一种真实格式时，共用已有所有者，并删去被取代的 Markdown 专用分发代码。**
Markdown PR #101 已在 `main` 的 `4f336b88` 合并；所有后续格式直接以此为基线，不能从旧文件查看器路线重做一遍。

## 已确认的执行链

- 打开：`Project.openFile / openLocalFile`；恢复独立通过 `Project.restoreTab` 创建同一类 `FileTab`。
  本机 Finder 文件与 SSH 项目同路径时仍以本机身份打开。
- 读取：`FileTab.readContent → LoadedContent`；现有 `.text / .image / .loading / .unavailable`。
  文本的 32 MiB、图片的 256 MiB／3200 万像素／4096px 缩略图及真实格式头检查均已有用途。
  不因出现新后缀而复制读取链或撤销这些限制；独立本机音视频走 `.media`。
- 展示：`FileViewerView` 是主入口；`TabContentThumbnail.filePreview` 是有界缩略图入口。
  Markdown 的 `MarkdownFilePreview` 只负责该格式的 AST／阅读交互，不能改造成万能文件渲染器。
- 编辑与并排：唯一可写正文是 `FileTab.nativeTextStorage`；
  `Project.setFilePreviewMode → DockWorkspaceModel.setFilePreview → DockItem.filePreview`
  已建立外层 Dock 双展示，`BaileyApp` 的 File 菜单已有唯一 `⌘⇧V`。
  `WorkspaceWindowModel` 判定前台有效目标；`WorkspaceDockView` 右键判定被右键的标签。

## 哪些能力共用，哪些不共用

| 已有代码 | 后续接入方式 |
| --- | --- |
| `FileTab`／`SourceTextEditor`／`WorkspaceBackend` | CSV／SVG／HTML 仍是 `.text`，继续共用正文、编码、Undo、读取与条件保存；不增加格式专属可写副本。 |
| `PreviewResource`＋`LocalPathScope` | HTML 的 CSS／图片和 SVG 的授权相对资源应共用当前项目／机器的路径解析、范围与实际 IO 校验。HTML 引用链须以**发起请求的 CSS／资源文件**为相对基准，不能都从 HTML 文档目录解析。WebKit 仍独立限制脚本、网络与子请求。 |
| `RasterPreview`／`MarkdownPicture.decode`／`ImageInspector` | 文件和 Markdown 共用 ImageIO 解码；文件图片和内嵌图形共用原生缩放视口。继续按图片计划核销原像素、区域解码与内存预算。 |
| `SVGArtwork.sanitizedXML`／`SVGArtwork.render` | 共用一次安全解析与 SwiftDraw；Markdown 可用有界栅格，独立 SVG 要在相同净化结果上矢量重绘，不重写第二套 XML 校验／SVG parser。 |
| `NativeMedia.open`／`NativePlayerView` | 音视频共用 AVAsset 验证。独立音视频及 Markdown 嵌入共用 `AVPlayerView`；独立音频使用紧凑系统播放器，不自建控制条。嵌入媒体才需要有界暂存，独立本机文件使用真实 URL，生命周期各归其主。 |
| `FilePreviewMode`／`showsFilePreview`／`DockItem.filePreview`／`rendersOnlyPreview` | 下一种文本预览落地时将**展示模式与 Dock companion** 收敛为文件通用语义，替换所有调用、菜单和测试，删除旧 Markdown 专用状态及分支；Markdown AST、滚动映射和独立的 `MarkdownFilePreview` 仍归 Markdown。 |

**不能强行共用：**完整 HTML 页面需隔离 `WKWebView`；Markdown 的 `MarkdownHTML`
只处理少量静态片段，不是全 HTML/CSS 引擎。CSV 字段源区间解析也不同于 GFM 表格渲染。
两者复用文件及安全边界，不复用不等价的内容语义。
源码高亮扩展名表、文件图标和可预览性是三个不同判断，不建立统一 Registry／`FileKind`。

<a id="shared-save-conflicts"></a>
## 共享保存冲突：以 VS Code 为参考

先对照已阅读的 VS Code 上游提交 `d0ba83679483e1fd146517a8e62282ee32c0f4ec`，
而不是另造文件事务框架。关键执行链：

- [TextFileEditorModel 保存与结果](https://github.com/microsoft/vscode/blob/d0ba83679483e1fd146517a8e62282ee32c0f4ec/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L1030-L1098)：保存序列化、已读版本、快照代次；
  成功仅清除对应版本的 dirty，失败保留可编辑草稿及冲突状态。
- [FileService.validateWriteFile](https://github.com/microsoft/vscode/blob/d0ba83679483e1fd146517a8e62282ee32c0f4ec/src/vs/platform/files/common/fileService.ts#L457-L539)：通过 mtime／etag 检查外部变化，必要时比较待写与磁盘字节；
  [etag 定义](https://github.com/microsoft/vscode/blob/d0ba83679483e1fd146517a8e62282ee32c0f4ec/src/vs/platform/files/common/files.ts)仅基于修改时间与大小，上游明确允许同长度改写漏检的性能取舍。
- [DiskFileSystemProvider.writeFile／doWriteFileAtomic](https://github.com/microsoft/vscode/blob/d0ba83679483e1fd146517a8e62282ee32c0f4ec/src/vs/platform/files/node/diskFileSystemProvider.ts#L277-L338)：按 provider 能力选择写入方式，
  原子路径锁定本次资源、写临时文件并 rename 替换；不是文件系统级比较并交换（CAS）。
- [TextFileSaveErrorHandler](https://github.com/microsoft/vscode/blob/d0ba83679483e1fd146517a8e62282ee32c0f4ec/src/vs/workbench/contrib/files/browser/editors/textFileSaveErrorHandler.ts#L110-L136)：遇到 `FILE_MODIFIED_SINCE` 提供比较与显式覆盖，
  [冲突接受或回退](https://github.com/microsoft/vscode/blob/d0ba83679483e1fd146517a8e62282ee32c0f4ec/src/vs/workbench/contrib/files/browser/editors/textFileSaveErrorHandler.ts#L410-L442)由用户明确选择。

**落地：**在 [CSV P2-T2](../csv-table-view/plan-p2.md#p2-t2) 核对并吸收这套行为，
统一到 `FileTab.save`／`WorkspaceFileVersion`／`WorkspaceBackend.write(ifUnchanged:)`、
`LocalWorkspaceBackend` 与 `SSHWorkspaceBackend`，同步 `DiffTab`、图像旁车和确认导出。
比较冲突优先复用现有 Diff 与原生错误／确认入口，先核对实际可用能力，再做必要的最小改动；
显式覆盖须绑定本次用户确认的目标和磁盘版本，随后变化仍须提示，不放开自动保存的版本保护。
保留现有 SHA-256、同长度同 mtime 检测、原编码、已替换版本恢复和保存失败后的 dirty；
不照搬上游较弱的元数据判断、无条件覆盖或 Electron 架构。若直接移植代码，遵循上游 MIT 许可。

**验收：**在本机与获授权的 Windows Tailscale SSH 上复用现有双进程屏障：
检查前改写、检查至发布间原位写／替换、旧描述符迟到写、同长度同 mtime 改写、
保存中继续输入、断线／重连、比较、显式覆盖／取消、关闭否决及重试。
逐项核对原磁盘、冲突版本、草稿、提示及最终字节；不得让旧确认覆盖新版本。
VS Code 的分离版本检查和 rename 不等于严格 CAS；现有平台实测边界见
[CSV P2 审计](../csv-table-view/audit-p2.md#发现-f-02)。不再凭空尝试更多假锁或重复检查；
严格非协作 CAS 如仍不成立，保留未满足项及安全恢复边界，不能以复刻 VS Code 自动核销。

## 任务

<a id="p1-t1"></a>
### P1-T1 核销读取与公共资源边界，移除新格式产生的重复路径

- **位置**：`FileTab.readContent / matches / reloadFromDiskIfClean`、
  `PreviewResource`、`MarkdownFilePreview`、`MarkdownHTMLView`、`Project.openMarkdownLink`、
  `LocalWorkspaceBackend`、`BaileyTests/Files`。
- **实施**：文本格式仅接入现有 `.text`，不改写编码或保存；图片仍经现有 ImageIO 安全边界。
  HTML 首次消费外部资源时共用已验证的 `PreviewResource` 授权与本机／SSH 读取，
  仅提取确实有第二个调用者的公共部分，立即删除旧命名与重复路径。
  本机音／视频真正接入时才增加**所需的**媒体读取结果及 `Content` 处理，
  在 `readContent` 读取整个二进制之前分流，直接验证有权限的真实本机 URL，SSH 明确拒绝；
  不用 32 MiB 文本读取、整文件内存缓存或回退同名 Mac 路径。
  纯图片更高分辨率查看不可绕过源文件版本和有界解码。
  图片已从 FileTab 首次读取记录原字节版本，放大时同后端重读并核对版本；
  标注也须用同一版本，不以缩略图身份作为存盘凭据。
  现有 Markdown 资源路径以源文档为基准，HTML 引用链增加 CSS 所在路径时须重用同一范围校验，
  并在最终读取时再次核对实际打开文件；远端使用 Windows SSH 实际支持的路径校验能力。
- **验收**：无扩展名、大小写、混淆后缀、伪造格式头、符号链接／`../`／URL 编码、
  非普通文件、权限错误、缺失／损坏、32 MiB 文本及 256 MiB 图片边界；
  Finder 本机文件、受控 SSH 同名文件、断线／重连、读中改名、刷新失败和关闭后迟到结果。
  检查真实读入字节、机器、权限、取消和资源释放，不以渲染器实例化代替最终结果。

<a id="p1-t2"></a>
### P1-T2 让下一种预览复用同一展示模式、Dock 和系统菜单

- **位置**：`FileViewerView`、`FileTab`、`DockWorkspaceModel`、`Project`、
  `WorkspaceDockView`、`WorkspaceWindowModel`、`BaileyApp.swift`、
  `SourceTextEditor`、`PanelContentView`、`TabSwitcherView` 及相关测试。
- **实施**：从现有 Markdown 源码／预览／并排入口出发，按第二个真实格式的需要
  **一次性替换**特有的模式与 Dock companion 命名／分发；各格式只拥有自己的渲染内容和附加状态。
  右键操作命中标签，主菜单操作前台焦点文件，`⌘⇧V` 只注册一次，
  不新增第二个工具栏、第二套 Splitter、保存模型或事件监听。
  `SourceTextEditor.onResignFirstResponder → FileTab.autoSaveOnFocusLoss` 是现有用户失焦保存策略：
  切换渲染器自身不得写盘，但真正离开原生编辑器时仍按当前策略保存。
  共享化要逐一核对源码／并排／预览、`showsFilePreview` 原有特殊分支，
  不得为“保证预览不保存”额外取消或重复投递失焦保存。
  CSV 默认表格、SVG 默认图形、HTML 默认源码；错误时源码仍可见，
  损坏数据不得凭后缀宣称已成功预览。
  主视图与 `TabContentThumbnail.filePreview` 同时覆盖新增内容，缩略图不再次读取全部文件、
  创建播放器或触发脚本；跨后缀重命名时还要注销不再合法的 Dock companion，
  禁止 `rendersOnlyPreview` 式只读分栏残留空白或旧内容。
  当场删除被新路径替代的旧视图／枚举分支及旧测试断言。
- **验收**：Files／`⌘O`／Finder／独立 `restoreTab`／跨窗口打开，
  单标签与并排、Dock 拖动／关闭、右键后台标签与 File 菜单、切模式、焦点／IME／Undo／保存，
  跨后缀重命名、可写草稿、外部冲突、权限变化、旧读取乱序以及真实关闭释放。
  对照 Markdown 和现有图片的实际 GUI，**纯架构复用不得改变其 UI/UX**。

## 阶段验收与执行顺序

验收范围为 macOS App 与已授权 Windows Tailscale SSH，保留现有远端功能及路径安全契约。
全七份计划统一采用下方[本轮验收环境](#acceptance-environment)。

此计划与**下一种格式的首个接入任务共同执行**，不作为单独“框架项目”先行。
CSV 的字段索引不依赖图形视口，先以 [CSV P1-T2](../csv-table-view/plan-p1.md#p1-t2)
接入原生表格，同时完成路由 P1-T2 的通用化及旧分支替换。
SVG／HTML 后续使用同一模式；SVG 的图形能力仍依赖图片共用视口。
音频 P1 首次复用 AVAsset，视频 P1 首次共用 AVPlayerView。
这些是依赖关系而非额外大阶段；已验证的功能可按实际准备情况并行。
若所选格式尚不需要修改读取或并排路径，记录核验结论，不制造提交。

按 `docs/testing.md`，宿主覆盖 `FileTabPersistenceTests`、`MarkdownResourceScopeTests`、
`NativePaneRetentionIntegrationTests`、`DockWorkspaceTests`、`SessionStoreTests`、
`FinderDeliveryIntegrationTests` 以及新格式的解析／权限／IO 用例；
涉及阅读位置与菜单时加 `SwiftMarkdownLayoutTests` 和隔离的 `MarkdownPreviewUITests`／Dock UI。
按受影响路径执行 `make test:...`、`make build` 和必要的隔离 Bailey Dev；阶段整合时共用一次完整 `make test`。
测试应覆盖 macOS 支持基线、编码和大小极值、错误恢复、真实本机与获授权 SSH、
多窗口、窄宽 Dock、深浅主题、键盘与手势，以及跨格式、切换、刷新、关闭的交互组合。
未配备的设备按本轮延期规则处理；其它真实 SSH、输入或特殊运行环境不可用时，
逐项记明原因、影响、替代证据与补验方法；
未跑的组合不能冒称通过。完成后同步 `docs/features/editor.md`，只有所有权改变才改 `docs/architecture.md`。

<a id="acceptance-environment"></a>
### 本轮验收环境与延期条件

- 远端真实验收统一使用已授权 `windows-tailscale` SSH 别名；即 Windows OpenSSH 经 Tailscale 网络直连，
  不使用 Cloudflare SSH／Access／ProxyCommand 回退。沿用既有 `BAILEY_P4_TEST_SSH_HOST` 和
  `TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST` 参数，执行命令及隔离要求见
  [测试规范](../../../docs/testing.md)。连接失败记录实际错误，恢复后重验，不能换 CF 路线或报通过。
  此约束针对测试环境，不删除产品现有通用 SSH 支持。
- 用户明确延期当前没有的设备：物理 1×／外接 HDR 屏、多显示器迁移及其依赖组合。
  2026-11-26 用户提供已连接的 Beats Studio Pro，第二输出设备恢复验收；实际双向切换通过，详见音频 P2。
  不创建虚拟显示器、不安装虚拟音频驱动、不改系统权限；这些条件记为延期／未测，不计为通过，
  也不再单独阻塞本轮任务或阶段。设备具备时恢复原矩阵中的相应验收。
- 继续验证本机内置 2× XDR、内置扬声器、实际 HDR 解码与可执行的 EDR 软件链、
  已有鼠标／触控板、中文 IME、VoiceOver、减弱动态效果、窄宽 Dock 及长会话。
  2026-11-26 用户确认实体触控板捏合通过；真实系统睡眠／唤醒明确延期由用户亲验，
  不再单独阻塞本轮，既有系统通知路径回归保留。
  区分真正的物理呈现／听感与宿主通知、像素或状态验证；可执行项不因缺外设被豁免。
  真正无法安全执行的项目单独记录原因、替代证据与剩余门禁。
- 可通过现有软件及自动化继续执行、仅缺有效运行结果的事项为 pending；blocked 仅用于当前确实缺少必要的实体输入、设备、权限或安全执行条件的事项。已核销的实现缺陷不得因共享阶段门禁重新标成未实现。

<a id="acceptance-ownership"></a>
### 验收归属与任务核销

同一功能只在拥有实现的任务修复并核销根因；调用者验证自身接线和最终结果，不重复承担实现任务。
共用矩阵是阶段验收输入，不是每个任务都必须重新执行的一份全量清单。
原任务的直接需求、数据保护、实际失败及必要集成测试不减少。
任务自身满足实施和适用验证时立即完成；阶段仍可因未核销的共同验收、依赖或全量测试保持 No-Go。
已通过且未受改动影响的证据复用，禁止仅因另一格式仍待验证而把已完成任务重新置 blocked。

| 事项 | 唯一实施／验收归属 | 调用者需证明的结果 |
| --- | --- | --- |
| R02–R05、R07、R09、R10 公共读取／身份／授权／资源生命周期 | 本计划 P1-T1；R08 公共模式与窗口菜单为 P1-T2 | 各格式使用同一 FileTab 和真实后端；自己的读取／展示结果正确。 |
| R06 条件保存、冲突比较／显式覆盖、非协作 CAS 边界 | [CSV P2-T2](../csv-table-view/plan-p2.md#p2-t2) 负责共享后端、FileTab 与 DiffTab；原边界不豁免。 | 各格式保留草稿、实际字节、失败拒绝及正确目标；标注另验底图／旁车配对；HTML 另验拒绝执行非授权版本。SVG 新文件独占导出不涉及条件覆盖。 |
| R01／R08 共用图形手势、倍率与无障碍 | [图片 P1-T1](../image-annotations/plan-p1.md#p1-t1) 实测共用视口手势；SVG 核对自己的矢量几何、焦点及原生动作。 | 同一底层手势不分别重复测完整矩阵；独特的标注、SVG、表格和 WebKit 控件／播报仍实测。 |
| R01／R08 原生文字 IME 与焦点 | CSV 网格、图片标注各验独有输入；SVG／HTML 共享 TextKit，连续并排组合可用同一场隔离 App 验收。 | 自动选择系统拼音输入源，确认隔离 App 与控件持有真实焦点，发送字母键和候选确认（不重新激活窗口、不直接粘贴中文）；断言组合期磁盘字节、候选、连续 Undo／Redo、最终保存及对应预览。退出恢复原输入源，不依赖用户人工输入。 |
| R09／R11 音视频生命周期、真实睡眠、内置声音与设备 | [音频 P2-T2](../audio-file-playback/plan-p2.md#p2-t2) 和 [视频 P2-T2](../video-file-playback/plan-p2.md#p2-t2) 共享一次混合媒体实测；各任务保留自身结果。 | 两类播放器均核对暂停、定位、换源与资源退役；视频另验画面，音频另验紧凑控件。 |
| R11 格式专属几何／性能与环境交叉 | 各格式自己的阶段验收；共有 117 次双窗与 100+100 宿主生命周期只在本计划记录。 | 复用公共证据，不以格式未验事项阻塞路由的独立任务。 |

全量回归仍按测试规范在阶段整合时执行一次，同一源码及环境结果由相关阶段共享；
不为每个任务重复启动全量，也不将已知无关失败冒称该任务的实现缺陷。
发生共同依赖失败时记录到实际所有者，调用者仅在它自己的验收确实依赖缺失能力时阻塞。

<a id="shared-verification"></a>
### 所有格式共用的验收条件

以下是各格式的完整适用验收矩阵，按[验收归属](#acceptance-ownership)分配；本轮明确延期的设备项按[验收环境](#acceptance-environment)处理，
其它可执行条件仍为必验项，不代表当前已经通过。
先沿真实 `Files/Finder/⌘O → Project → FileTab → FileViewerView/TabSwitcher`
建立可观察的夹具，再分别验证加载、交互与磁盘最终结果。
宿主测试承担可控组合；完整 Bailey Dev 只负责菜单、手势、焦点与窗口等不可替代的路径。
不适用的条件说明原因，不靠“选几个典型案例”替代其它可执行边界。

| 编号 | 条件与具体样本 | 最终判据 |
| --- | --- | --- |
| R01 环境 | 本轮按用户确认的本机 macOS 27.3／Xcode 27.2／Apple Silicon 验收，不要求 macOS 15.6 实机；保留原部署目标。深浅／自动外观、中文／英文、缩放显示器 1×／2×、鼠标／触控板、减弱动态效果及 VoiceOver 按实际适用性核销。 | 同一文件内容、操作与辅助功能不随环境误变；不把部署目标编译当作旧系统实测。 |
| R02 入口 | Files 单双击、Finder、⌘O、文件拖入、SSH 项目内打开、冷启动会话恢复与已打开标签复用；激活／后台窗口和两个不同项目。 | 相同项目／机器／规范路径不产生第二个可写正文；Finder 本机文件在 SSH 项目中仍属本机，同字符串不同机器文件绝不串读。 |
| R03 路径 | ASCII、空格、中文／emoji、组合音调／不同规范形、大小写、单引号、`%/#/?`、255 字节合法文件名、文件夹重命名、相对 `.`／`..`、链接到允许／越界目标、悬空链接。 | 读取和打开的是授权的真实目标；失败不换机器、不泄漏外部字节；任何规范化／解析不改变原路径指向。 |
| R04 文件类型 | 后缀正确／大写／错误／无后缀、合法头与假后缀、空文件、截断或损坏、二进制 NUL、不可读、FIFO／socket／目录、存取时移除或换成链接。 | 不在类型未验证前走无界读取或执行内容；错误确实留在原目标，可编辑的草稿与旧有效内容按现有约定保护。 |
| R05 容量 | 文本 `0/1/32 MiB-1/32 MiB/32 MiB+1`，图片 `32 MiB` 分流点及 `256 MiB`、`32,000,000` 像素边界；新媒体大于内存但有效的文件、文件读时增长／截短。 | 等于预算可用，超过预算明确拒绝或按设计退化；无整文件媒体拷贝、内存无界增长、部分字节当作完整文件。 |
| R06 版本与编辑 | 未改、未保存、自动保存等待中、Undo 回原字节、编码不支持、外部同长度同 mtime 改写、两标签并发保存、刷新失败后恢复、文件重命名／删除；按[共用保存冲突方案](#shared-save-conflicts)核对比较、显式覆盖与恢复。 | 旧回调不覆盖新文本、草稿或实际磁盘；⌘S、失焦、关闭／取消关闭与真实 Git Diff 的字节结果一致。只读格式始终不写盘。 |
| R07 竞态 | 初读／重新载入／资源请求中先后触发切 Dock、切项目、重命名、删除、关闭和再次打开；重复切模式、快速输入／Undo、取消后完成回调。 | 核对文件 ID、机器、连接、路径和编辑／重载代次；旧内容不显示到新标签，关闭后没有未清理请求或新的磁盘写入。 |
| R08 UI/布局 | 单窗／双窗、同文件多 Dock、分栏窄／宽、标签右键后台目标、主菜单活动目标、⌘⇧V／⌘W／⌘S、TabSwitcher、主题与字体／折行（适用时）、读写焦点。 | Dock 只有一个布局所有者、每份源正文只有一个 Undo；主菜单与右键不串目标，无额外顶部栏，切模式与重挂载不清选区／阅读锚点。 |
| R09 生命周期 | 冷标签懒加载、后台标签不触发全尺寸预览、10 次与 100 次打开／切换／关标签、真正的项目／窗口关闭、外部重载、App 重启恢复。 | 原生正文／WebView／AVPlayer／解码任务在有效内容期间复用，真关闭后取消并释放；对比前后 RSS／retained heap 和对象引用，不把 100 次增长当作已证无泄漏。 |
| R10 权限／远端 | 本机允许／拒绝读取、已授权 Windows Tailscale SSH（`windows-tailscale`）、相同路径的本机假文件、断线→重连与旧通道回写；检验实际远端 Shell 能力。 | 不访问错误主机／越界路径、不以断线回退本机；没有可用且获授权的远端主机时记录具体阻塞、替代宿主证据及验收限制，不代替远端 E2E。 |
| R11 视觉/性能 | 短／超长行、巨宽图／表、多帧、多媒体、大资源和嵌套 Dock；快速滚动、持续输入、宽度／字号／主题变换、真实内存压力。 | 记录 MainActor 阻塞、首帧／交互延迟、CPU／RSS／解码峰值、重挂载前后原生对象与可见像素；先复现，解决有证据的共享瓶颈，不追加任意定时等待。 |

**必须执行的交叉组合：** R02×R03×R10（Finder 本机文件与 SSH 同名路径）；
R05×R07（边界容量下加载中改名／关闭）；R06×R07（脏稿、自动保存、外部替换和过期回调）；
R08×R07（后台右键、双 Dock 切换、窗口失焦）；R03×R04×R10（越界链接与伪造后缀）；
R09×R11（100 次生命周期后的内存、首帧与操作延迟）。
其余适用条件先逐值运行，再做可承受的完整组合及扩展两两／多因素组合，
不为这张矩阵引入新的产品状态机或永久测试框架。
完成报告对每个编号注明测试类／方法、真实环境、命令、运行数量、实际可见／磁盘结果及未运行原因；
CI / XCTest 绿色不能取代 Mac 原生图形或实际磁盘权限验收。

### 跨格式复用的回归组合

这是检验“共享同一能力”是否真正成立的**强制集成用例**，不是为每种格式另写一个 renderer：

- 同一 `image.png` 由 Markdown 内嵌、文件图片标签及 HTML 相对资源同时引用：
  改变原图后切窗口／刷新，三个位置取得各自授权的**同一新版本**；
  关闭任一观察者不释放其它正在使用的 FileTab／资源，不能留下两个独立图片解码器或查看手势。
- 同一 `plot.svg` 在 Markdown 片段和独立 `.svg` 标签打开；
  先验证**相同**净化规则和原始几何，再编辑 XML、切换双 Dock、放大、遇到不支持节点和非法 XML：
  文件端只读错误、Markdown 端安全渲染、共同 parser 及原文字节各有正确结果。
- 同一 `clip.mp4`／`audio.wav` 分别经 Markdown 嵌入按钮与本机媒体文件标签播放：
  嵌入需授权的 ≤64 MiB 私有暂存，独立文件直接受控 `file://`，
  AVAsset 与原生视频适配共用，**但各自 player 的暂停、取消和关闭互不越权**。
- 同一 `notes.md` 通过外部改名依次变为 `.svg`／`.html`／`.csv`／普通文本，
  且保留未保存 TextKit 输入：展示模式能力随真实格式改变、失效的 Dock companion 立刻收回，
  当前 `⌘⇧V` 及系统菜单不误操作，旧渲染结果与资源请求不得显示到新格式。
- `Finder` 本机文件、SSH 同字符串路径，以及另一个窗口打开的同名文件同时存在；
  交叉触发资源相对引用、请求取消、右键菜单、保存冲突和项目关闭，
  核对最终访问的机器、磁盘路径、文件字节、原生焦点与资源释放。
- 在同一工作区混合打开 Markdown、CSV、HTML、SVG、图片、音频、视频多标签，
  多次移动 Dock、切换 100 次、批量关闭和恢复；
  比对现有 Markdown 滚动锚点／图片放大／内嵌播放，以及唯一 Undo 和保存保护，
  记录前后原生对象数、活跃请求数、RSS 与残余有声播放器。

每组先建立真实文件／权限／状态前提，再核对最终用户可见内容及磁盘或声音结果；
仅同名类型、函数文件数量变少不算共用验收成功。

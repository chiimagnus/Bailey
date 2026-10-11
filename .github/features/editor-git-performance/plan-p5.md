# P5：优化 diff 从读取到实际首屏的完整流水线

**Goal:** 找到并减少用户等待 diff 的真实成本，同时保持编辑、滚动和已有 WebView 复用。

**Non-goals:** 不更换 WebKit/Pierre，不新增全项目多文件 diff，不缩小 5 MiB 上限，不降低差异或高亮质量。

**Approach:** 先分别测读取、Swift 桥接、JS 计算和页面布局，再对命中的阶段做最小修改。优先应用与依赖的已有入口；公开接口无法处理已证实热点时，才携带同一固定版本的最小依赖补丁。每个候选单独复测，保留数据和编辑正确性，而不是用提前发出 ready 隐藏等待。

**Acceptance:**
- 首次打开、复选、跨项目和当前停靠组切换的实际首屏/可编辑/高亮分别有记录。
- 命中候选的工作量与可见等待下降；未命中候选有保留理由，不制造无收益的 fork。
- Unicode、二进制、超限、冲突、历史、重命名和保存行为正确。
- 多标签关闭后，无过期编码任务、内容缓存或 worker 持续增长。

**Rules:**
- 前置 P1。P2 改善 backend 读取不等于 diff 的解码已离开主线程，须单独核对实际 executor。
- `DiffTab` 已保留 hosting view；历史 diff 已避免复选时重读；Pierre 已有相等输入检查、虚拟化和高亮 worker。不得重复搭建。
- 当前布局是 `WorkspaceDockView → DockTabGroupView.content / PaneLayoutView`；按正式基线核对可见组、挂载、重挂载和关闭，不能套用旧 visited-project stack 的事实。
- `bridgeReady`、`ready`、`evaluateJavaScript` 完成都不是实际绘制。布局、字体、可见行与高亮要在 WebKit timeline/截图中核对。
- 依赖固定为 resolved 中的 PierreDiffsSwift `3713d29360b750d3d6146b187ff3b77b7d498fee`，JS `@pierre/diffs 1.3.1`。上游最新文档不能替代固定版本契约。

<a id="p5-t1"></a>
## P5-T1 diff 分段归因与最小候选实验

**类型 / 依赖:** 实验；依赖 P1，比较时记录 P2/P3/P4 的实际实现状态。

**Files / 已核对锚点:**
- `kero/Git/DiffViewerView.swift`：`DiffTab.reload`、`firstGitContent`、`gitContent`、`runGitData`、`readWorktreeFile`、`materializeWebHostView`、`DiffWebRoot`。
- `kero/UI/WorkspaceDockView.swift`、`kero/UI/Panes/PaneLayoutView.swift`：当前实际挂载 caller。
- Read-only upstream: `build/SourcePackages/checkouts/PierreDiffsSwift/Sources/PierreDiffsSwift/WebView/{PierreMultiDiffView,DiffWebViewCoordinator}.swift`。
- Read-only upstream: 同包 `Models/PierreMultiDiffInput.swift`、`scripts/src/{diff-entry,worker-entry}.js`、`scripts/bundle.js`、`docs/upstream-pierre-diffs.md`、`AGENTS.md`、`CHANGELOG.md`。
- Local evidence: `evidence-p5.md`、`build/performance/diff/`。

**当前依据:**
- 应用先在 detached 任务串行读取 Git；live diff 的 worktree 随后读取。每个存在的 Git blob 当前先查大小，再读原始字节；本地读取有 cap+1 捕获和独立 stdout/stderr reader。
- coordinator 在 MainActor 做 JSON 编码、base64 和脚本构造；未 ready 时保存待执行闭包。输入 `PierreMultiDiffInput` 与 `PierreDiffFile` 已是 Sendable，可以传值，不能把 WKWebView 送到后台。
- `createCodeViewItem` 先同步 `parseDiffFromFile`，再算内容版本并调用 `CodeView.setItems`；现有 worker 只负责高亮。虚拟化不意味着差异计算也在后台。
- Swift 相等输入通常不会重新 render；不能把“JS 进入一次就算一次”误写成“每次标签切换都重算”。

**实验:**
1. 固定 P1 选中的小/大 diff，以及初次、live 再选、历史再选、edit/review 切换和多个可见停靠组。按同一源代码快照测 Kero 与关联 WebKit 进程。
2. 记录 Git 进程/SSH 往返及等待、worktree 读取/解码、JSON/base64/脚本、网页解码、差异计算/内容扫描、字体/DOM/布局与可见高亮。已有 signpost 不足才最小补充，不记录实际文本或路径。
3. 对主耗时只做对应最小原型：独立两侧读取重叠；Sendable 输入后台编码；重复输入在 parse 前复用。原型在 `build/` 的固定版本副本中进行，不把 checkout 临时改动当成正式成果。
4. 若单次 parse 是热点，检查固定 `1.3.1` 的源码/类型声明和 worker 能力，再试一条受支持路径；没有证据就不能预设高亮 worker 能计算 diff。需要网络获取锁定 npm 包时仅取现有锁定依赖，不升级，不上传样本。
5. 结果更新本阶段具体选择、源码位置、回归命令和准入；不能留给实现者凭空决定新协议或 worker 结构。公开 API 已能解决就不 vendoring；需要超出最小补丁的新引擎就停止并说明限制。

**验证 / 成本与停止:**
- 使用 P1 同机口径；每个命中阶段最多一个最小候选，测工作量、首屏/可编辑和内存。第一轮不能归因先改观测，不继续试多个架构。
- 调试计时关闭后复核扰动；相等复选必须证明没有新增全量 render，首屏必须证明真实内容已出现。
- 输出“命中 → 选择 → 前后数据 → 正确性边界”，或“未命中/不采用 → 证据”。不得把依赖 changelog 的提速数字当作本机结果。

**提交边界:** 无正式代码变化不提交；确需追加的 Debug 标记按 P1 的范围与真实机器要求单独验证后提交。

<a id="p5-t2"></a>
## P5-T2 收敛 diff 读取等待与后台解码

**类型 / 依赖:** 条件实现；依赖 P5-T1 的读取热点准入及 P2-T1 的 backend 契约。

**Files:**
- Modify: `kero/Git/DiffViewerView.swift` 的 `reload` 与读取结果回写。
- Only if needed: new `kero/Git/DiffContentReader.swift`，迁移实际 Git/worktree 内容读取；仅包含原有职责，不加 protocol 或缓存框架。
- New if this path changes: `scripts/check-diff-content.swift`，运行真实生产读取函数和临时 Git 仓库。
- Existing shared runners: `GitStatusModel.runGit / remoteGitData`、`WorkspaceBackend`；不另造通用进程池。

**不变量与实施:**
1. 只实施 P5-T1 已证明的最小路径。优先让彼此独立的两侧读取重叠、将工作树 UTF-8 扫描/解码显式放到非主执行器；同一侧冲突 fallback 仍按原顺序选择。每 tab 至多两侧，不并发启动所有 fallback。
2. 回写继续由 `DiffTab` 拥有，用原 `reloadGeneration`、workspace 和只读状态校验。不发布中间空文本重建 WebView。检查进入 edit mode 时已有 read 在途的路径：提交结果前也须保持“不替换正在编辑或 dirty 的文档”，不能只依赖启动时 guard。
3. 历史、staged、live、untracked、rename 的两侧语义不变；live 冲突仍依次 stage-0、stage-2、stage-1、HEAD。一次结果只聚合真实失败，另一侧成功不能清掉前一侧错误。
4. 不缓存可变 index/worktree 为 immutable HEAD。已有历史复用保留，不增加永久 blob 缓存。
5. 只有 P5-T1 证明进程启动/远程往返主导且 batch 原型值得采用时才改 blob 读取。按 [git-cat-file 官方协议](https://git-scm.com/docs/git-cat-file)核对本机与远端实际版本；优先两次有限调用：先批取类型、大小和对象 ID，再仅请求合限对象的内容，复用 backend.run 的 stdin 能力，不为两侧 blob 新造交互式进程服务。固定对象 ID 避免 size/content 指向不同 index 对象；按字节边界读响应，不按内容换行拆 blob。
6. batch 分支保留 missing、binary、tooLarge、UTF-8 和 cap+1 防护，每侧各有 5 MiB 边界；不能直接把 runGitData 的单个 stdout 全局 cap 套到两侧总响应，否则两个合法大 blob 会被截断。stdin/stdout/stderr 必须避免互等，退出/失败必须排空或正常终止，不建立常驻跨 tab 进程。含空格/换行的路径不能破坏帧。远端缺能力走原路径，不擅自提高最低 Git 版本。若这些成本超过收益，保留现有有界 runner。
7. 改动非平凡读取逻辑时，最小拆出 `DiffContentReader` 给 app 和回归脚本共同调用，接入与删除原重复实现在本 task 完成。仅移动 executor 的简单分支则保留原文件，复用 P2 有界读取检查，并用实际应用验证解码线程与回写。
8. 脚本若使用 shared runner，沿用 P4-T1 已验证的 app-only 类型壳，不复制 Git/字节算法。需要拆出真实读取逻辑时使用以下编译入口，纯 executor 调整则复用 P2 检查与真机 trace；不会声称规划时已验证尚不存在的脚本。

```sh
xcrun swiftc -swift-version 5 -o build/check-diff-content \
  kero/Workspace/WorkspaceBackend.swift kero/Workspace/TreeDisplayModel.swift \
  kero/Remote/RemoteCommands.swift kero/Git/GitStatusModel.swift \
  kero/Git/DiffContentReader.swift scripts/check-diff-content.swift \
  && build/check-diff-content
```

**验证:**
- 真实 temporary Git 检查：普通 live/staged/history、root commit 缺父、unborn、untracked、rename、删除、unmerged fallback；用 `git cat-file blob` 和磁盘原始字节作 oracle。
- 空、Unicode/组合字符、NUL、无效 UTF-8、恰好 5 MiB/多一字节、symlink 显示及禁止原子覆盖。若 batch 入选，额外检查两侧各 4 MiB 均合法、单侧超限不发送内容、协议截断、大 stderr、路径换行、失败退出和 size/content 竞态。
- 真机：打开时终端/光标可操作；读取中切换与关闭；在途 reload 后进入 edit、输入、撤销、保存，WebView 文档和 undo 不重置，磁盘只有实际保存的内容。
- 共享 SSH 分支变化须用授权 fixture 做真实连接；模拟只用于可控延迟/乱序，不冒充端到端。
- 与 P5-T1 比较同一阶段及实际首屏，记录进程/往返变化和内存，收益不显著则不保留复杂 batch。

**提交边界:** 选中的读取路径、必要 helper/真实回归检查一个原子提交；未命中时只回写本地证据，不制造代码提交。

<a id="p5-t3"></a>
## P5-T3 收敛桥接编码与在途渲染

**类型 / 依赖:** 条件实现；依赖 P5-T1 的 Swift 编码或重复排队热点准入。

**Files:**
- Existing application call: `kero/Git/DiffViewerView.swift` 的 `DiffWebRoot`，只有公开 API 能解决时在这里最小调整。
- Only if required by measured hotspot: 固定版本源码副本 `Vendor/PierreDiffsSwift/`，重点 `Sources/PierreDiffsSwift/WebView/DiffWebViewCoordinator.swift`、`PierreMultiDiffView.swift` 与现有 `Tests/PierreDiffsSwiftTests/PierreDiffsSwiftTests.swift`。
- If vendored: `kero.xcodeproj/project.pbxproj`、其实际 resolved 消费者、`docs/DEPENDENCIES.md`。

**准入与实施:**
1. 优先现有 API/相等检查；当前编码函数和 pending queue 在依赖内部，无法用 caller 的另一层 Task 把它们移出 MainActor。只有这部分在 trace 中主导时才替换 remote package reference 为同一固定 revision 的本地包。保留许可证、署名、资源与必要上游说明，不复制 `.git/.build/node_modules`，不升级其他包。
2. 在实际拥有 `PierreMultiDiffInput` 的 coordinator 内，让纯 Sendable 输入的 JSON/base64/脚本构造后台执行；WebKit 调用与 UI 状态仍在 MainActor。不使用 `@unchecked Sendable` 搬运 WKWebView、coordinator 或可变编辑对象。
3. 新异步间隙需要一个 coordinator 自有的最小 render revision / 最新在途输入；只在真实 full-render 路径使用。旧编码不能晚到覆盖新内容；关闭后取消/丢弃结果；未 ready 时不累积多份大文本编码。已有无数据变更的 style/theme/font 增量命令继续复用。
4. 明确内容与选项的顺序：full render、随后 theme/style/overflow/font 和 scroll 必须落在最新内容上，旧 input 的选项不能覆盖更新设置。保留一个最新期望值即可，不建立通用命令总线或第二套文档状态。
5. `lastFiles/lastRenderOptions` 是依赖的发送判定；编码/提交失败不能永远把未发送内容当作已成功。保留既有错误反馈，区分“期望输入”和“已提交”仅到该异步边界所需程度，不新增无限重试。
6. UTF-8 解码继续 `atob → Uint8Array → TextDecoder → JSON.parse`；不能直接按 Latin-1 解码。少一次复制只有测量证明且协议可保持才做，不换传输栈。
7. cleanup 清除 pending 大输入和自有任务。只有关闭/重复创建 trace 显示残留，才进一步沿现有 JS `cleanup → terminateWorkerPoolSingleton / revokeObjectURL` 到实际释放查明；不能只证明 cleanup 函数被调用。
8. 同一 task 完成本地 package 接入、补丁归属/固定来源/生成流程文档；不能在 checkout 留临时修复，不能把 plan 文件并入提交。

**验证:**
- 扩展同包现有 Swift Testing：实际 Sendable 编码结果保持默认选项、字体与 Unicode；控制旧/新编码完成顺序，验证最新输入/cleanup 的实际提交判定，不为 WKWebView 新增测试 protocol。
- If vendored: `swift test --package-path Vendor/PierreDiffsSwift`。现有 bridge 字符串/JSON 测试只证明构造，不等于网页绘制。
- 签名 Debug 真机快速切换内容/布局/主题/字体、重挂载、编辑与关闭；确认最后可见内容与选项对应，scroll/选择/undo 保留。使用中文、emoji、引号、反斜线和组合字符核对网页显示及最终保存。
- 原始 trace 检查 MainActor 编码占用下降、在途文本有界，以及实际首屏没有被异步往返拖慢。

**提交边界:** 实际补丁、本地包接入与依赖说明一个原子提交；没有准入不 vendoring、不提交。

<a id="p5-t4"></a>
## P5-T4 减少 JS 差异计算与内容扫描

**类型 / 依赖:** 条件实现；依赖 P5-T1 的 JS 热点结论。P5-T3 若未携带依赖，也可独立按同一准入规则接入必要最小补丁。

**Files:**
- If dependency patch is necessary: `Vendor/PierreDiffsSwift/scripts/src/diff-entry.js`、必要的固定版本 worker source，以及生成脚本的真实输出资源。
- Minimal pure helper only if needed: 同目录提取生产与检查共同使用的内容身份/复用函数；不复制算法写 oracle。
- Extend package checks: 同包 Swift Tests；JS 需要逻辑检查时使用 Node 内置 `node:test`，不装测试框架。
- 接入首次发生在本 task 时，包含 P5-T3 的项目与依赖归属文件。

**实施:**
1. 按 P5-T1 选择复用或调度，先在 `createCodeViewItem` 的 parse 前判断实际变化，不在 `setItems` 后才发现可以复用。已有 Swift 相等检查仍保留，JS 不建无限内容缓存。
2. 若复用值得采用，仅保留当前 CodeView items 的最新 descriptor 与已解析结果，更新/移除 item 同步失效。名称/oldName、语言、note、两侧内容、edit/review 语义都纳入比较，不能只按 path 或长度。
3. 不把 32 位 `contentVersion` 当成绝无碰撞的正确性凭证。已明确相等输入才能跳过解析；确有变化就用该 item 的单调版本/内容身份使 CodeView 和高亮缓存失效，不再为每次渲染多次扫描整份内容。身份不能跨已删除 item/另一文档误复用。
4. 若单次计算仍主导，必须使用 P5-T1 已核对固定版本的方案：复用可用 worker 能力，或一个已经证明能降低实际等待、序列化成本可接受的最小差异计算 worker。不得假定现有高亮 pool 支持 parseDiff；没有合适能力就先补实验结论和实施边界，不能暗中引入新 diff 引擎。
5. 新后台计算只传不可变值；根 bridge 持有最新 render 身份，旧结果不能覆盖新文本或 edit mode。取消、worker 不可用和异常仍有既有可用路径，不能显示空白或吞掉错误。
6. 保留虚拟化、内容相关 highlight cache key、null-origin 下 blob worker、编辑内的 undo/选择、字体行高和 layout/overflow/theme 增量设置。不要用禁用词级 diff、高亮或高亮预取来达成数字。
7. 生成 bundle 仍走原 `scripts/bundle.js`，保留 `ignoreAnnotations: true` 等防止空 worker 的约束，不手改 minified 资源。依赖/worker 新改动清理旧路径在同一 task 完成。

**验证:**
- 固定 `1.3.1` 的真实 `parseDiffFromFile` 作结果 oracle；同内容重复、同长度不同内容、Unicode、rename/语言变化、note ↔ diff、review ↔ edit、删除后重加均正确。
- JS 复用检查必须断言实际 parse 次数与最新结果，不能只比 cache key；若增加 worker，控制旧/新完成顺序与 fallback，测试最终使用结果，而不只看 postMessage。
- If JS changes: `npm ci --prefix Vendor/PierreDiffsSwift/scripts`；`npm --prefix Vendor/PierreDiffsSwift/scripts run build`；运行已接入的 Node 逻辑检查，再 `swift test --package-path Vendor/PierreDiffsSwift`。先核对锁定版本，不用安装时的 latest。
- 签名 Debug 实际 WKWebView 测首次大 diff、反复选同 diff、改一侧再看、历史/冲突、滚动、两种布局和编辑保存；确认差异行/词、高亮与磁盘内容，不仅是 bundle 含某字符串。
- 测真实首屏/可见高亮、JS 最长主线程段、两进程内存、关闭后 worker；如果优化只移动等待却端到端变差，不保留该调度方案。

**提交边界:** 选中的 JS 优化、实际检查、生成 bundle 及必要首次包接入一个原子提交；未命中时记录理由，不制造代码。

## 阶段自审与交接

- P5-T1 未得出的实现选择必须先补证并更新 task；不能将条件候选默认全开。
- 每个被保留的优化都有真实首屏证据；外部依赖补丁有来源、接入与可再生成链。
- 路径/容量/错误/编辑保护和清理验证齐全，不以“异步已启动/事件已发”替代完成。
- 实际阶段结束进入审计并创建 `audit-p5.md`；规划阶段不预建。

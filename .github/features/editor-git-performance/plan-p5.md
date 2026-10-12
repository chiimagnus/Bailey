# P5：优化 diff 从读取到实际首屏的完整流水线

**Goal:** 找到并减少用户等待 diff 的真实成本，同时保持编辑、滚动和已有 WebView 复用。

**Non-goals:** 不更换 WebKit/Pierre，不新增全项目多文件 diff，不缩小 5 MiB 上限，不降低差异或高亮质量。

**Approach:** 读取失败/编辑保留与内容身份正确性先闭环；性能分别测读取、Swift 桥接、JS 计算和布局，命中才改。优先现有入口，依赖内部的已复现正确性问题或准入热点才携带固定版本最小补丁，不以提前 ready 隐藏等待。

**Acceptance:**
- 首次打开、复选、跨项目和当前停靠组切换的实际首屏/可编辑/高亮分别有记录。
- 命中候选的工作量与可见等待下降；未命中候选有保留理由，不制造无收益的 fork。
- Unicode、二进制、超限、冲突、历史、重命名和保存行为正确。
- 多标签关闭后，无过期编码任务、内容缓存或 worker 持续增长。

**Rules:**
- 前置 P1。P2 改善 backend 读取不等于 diff 的解码已离开主线程，须单独核对实际 executor。
- `DiffTab` 保留 hosting view，`refreshWhenSelected` 跳过历史与初始在途读取；但 `Project.openDiff/openCommitDiff` 复用已有 tab 时仍直接 reload。区分“选回 tab”和“再次点击 Git 行”，不能声称所有历史复选已免读取。Pierre 已有相等输入检查、虚拟化和高亮 worker，不重复搭建。
- 当前布局是 `WorkspaceDockView → DockTabGroupView.content / PaneLayoutView`；按正式基线核对可见组、挂载、重挂载和关闭，不能套用旧 visited-project stack 的事实。
- `bridgeReady`、`ready`、`evaluateJavaScript` 完成都不是实际绘制。布局、字体、可见行与高亮要在 WebKit timeline/截图中核对。
- 依赖固定为 resolved 中的 PierreDiffsSwift `3713d29360b750d3d6146b187ff3b77b7d498fee`，JS `@pierre/diffs 1.3.1`。上游最新文档不能替代固定版本契约。

<a id="p5-t1"></a>
## P5-T1 diff 分段归因与最小候选实验

**类型 / 依赖:** 实验；依赖 P1，比较时记录 P2/P3/P4 的实际实现状态。

**Files / 已核对锚点:**
- `kero/Git/DiffViewerView.swift`：`DiffTab.reload`、`firstGitContent`、`gitContent`、`readWorktreeFile`、`materializeWebHostView`、`DiffWebRoot`；`GitCommandExecution.runData` 是实际共享 runner，旧模型/文件内 runner 不存在。
- `kero/Workspace/Project.swift`：`openDiff` / `openCommitDiff` 的已有 tab 分支。
- `kero/UI/WorkspaceDockView.swift`、`kero/UI/Panes/PaneLayoutView.swift`：当前实际挂载 caller。
- Read-only upstream: `build/SourcePackages/checkouts/PierreDiffsSwift/Sources/PierreDiffsSwift/WebView/{PierreMultiDiffView,DiffWebViewCoordinator}.swift`。
- Read-only upstream: 同包 `Models/PierreMultiDiffInput.swift`、`scripts/src/{diff-entry,worker-entry}.js`、`scripts/bundle.js`、`docs/upstream-pierre-diffs.md`、`AGENTS.md`、`CHANGELOG.md`。
- Local evidence: `evidence-p5.md`、`build/performance/diff/`。

**当前依据:**
- 应用先在 detached 任务串行读取 Git；live diff 的 worktree 随后读取。每个存在的 Git blob 当前先查大小，再读原始字节；本地读取有 cap+1 捕获和独立 stdout/stderr reader。
- coordinator 在 MainActor 做 JSON 编码、base64 和脚本构造；未 ready 时保存待执行闭包。输入 `PierreMultiDiffInput` 与 `PierreDiffFile` 已是 Sendable，可以传值，不能把 WKWebView 送到后台。
- `createCodeViewItem` 先同步 `parseDiffFromFile`，再算内容版本并调用 `CodeView.setItems`；现有 worker 只负责高亮。虚拟化不意味着差异计算也在后台。
- Swift 相等输入通常不会重新 render；不能把“JS 进入一次就算一次”误写成“每次标签切换都重算”。
- `contentVersion` 的 32 位 hash 被当作 CodeView 不更新记录与 worker 高亮缓存的身份。当前生产函数对 `fixture.txt`、空 before、review 模式的 after=` a` / `!@` 均产生 itemVersion=1381271817，两侧内容键也碰撞；身份修复属于 P5-T4 必修，不是未发生的理论风险。
- Swift cleanup 当前只停止导航、移除 handler/视图，未清 pendingOperations，也未调用 JS bridge.cleanup；JS 有销毁 CodeView/worker/blob URL 的能力不代表 App 已执行它。关闭增长仍需实际归因，不直接声称泄漏或立即加恢复框架。

**实验:**
1. 固定 P1 选中的小/大 diff，以及初次、live 再选、历史再选、edit/review 切换和多个可见停靠组。按同一源代码快照测 Kero 与关联 WebKit 进程。
2. 记录 Git 进程/SSH 往返及等待、worktree 读取/解码、JSON/base64/脚本、网页解码、差异计算/内容扫描、字体/DOM/布局与可见高亮。已有 signpost 不足才最小补充，不记录实际文本或路径。
3. 对主耗时只做对应最小原型：复用 tab 时免无益 reload、有限两侧读取重叠、Sendable 输入后台编码、parse 前复用。原型在 `build/` 固定版本副本中进行，不把 checkout 临时改动当正式成果；不预建 cat-file batch 协议或旧 Git 兼容分支。
4. 若单次 parse 是热点，检查固定 `1.3.1` 的源码/类型声明和 worker 能力，再试一条受支持路径；没有证据就不能预设高亮 worker 能计算 diff。需要网络获取锁定 npm 包时仅取现有锁定依赖，不升级，不上传样本。
5. 结果更新本阶段具体选择、源码位置、回归命令和准入；不能留给实现者凭空决定新协议或 worker 结构。公开 API 已能解决就不 vendoring；需要超出最小补丁的新引擎就停止并说明限制。

**验证 / 成本与停止:**
- 使用 P1 同机口径；每个命中阶段最多一个最小候选，测工作量、首屏/可编辑和内存。第一轮不能归因先改观测，不继续试多个架构。
- 调试计时关闭后复核扰动；相等复选必须证明没有新增全量 render，首屏必须证明真实内容已出现。
- 输出“命中 → 选择 → 前后数据 → 正确性边界”，或“未命中/不采用 → 证据”。不得把依赖 changelog 的提速数字当作本机结果。

**提交边界:** 无正式代码变化不提交；确需追加的 Debug 标记按 P1 的范围与真实机器要求单独验证后提交。

<a id="p5-t2"></a>
## P5-T2 收敛 diff 读取等待与后台解码

**类型 / 依赖:** 读取正确性必修 + 条件性能精简；依赖 P5-T1 归因、P2-T1 backend 契约。正确性不以耗时准入决定是否修。

**Files:**
- Modify: `kero/Git/DiffViewerView.swift` 的 `reload` 与读取结果回写。
- New: `kero/Git/DiffContentReader.swift`，迁移实际 Git/worktree 读取，单个生产与脚本共用的数据型职责；不加 protocol、factory、队列或缓存框架。
- New: `scripts/check-diff-content.swift` 并在 check.sh 接入；Extend: `scripts/check-workspace-identity.swift` 的真实 DiffTab 晚结果/编辑保留检查。
- Modify: `Project.openDiff/openCommitDiff` 的复用分支，按归因避免重复初读/历史重读。
- Existing shared runners: `GitCommandExecution.run / runData`、`WorkspaceBackend` 与 `LocalWorkspaceBackend`；不另造进程池或绕过登录 shell 环境。

**不变量与实施:**
1. 先复现实际缺口：gitContent 当前把 cat-file 的任何非零退出都当 missing，size 无法解析也默认为 0；DiffTab.reload 回写不再检查编辑状态；isLoading=true 后的 edit/reloadGeneration 变化还可能使旧任务不清 loading。检查最终 UI 内容/错误/等待，不只断言某个 guard 返回。
2. 回写由 DiffTab 拥有并复用 reloadGeneration。切入编辑、输入及保存时使旧加载失效并结束其 loading；发布前核对只读/正在编辑/dirty，不能等待到首个 dirty 才保护已打开的 editor/undo。不要加第二套 render 身份来补读取层错误；不发布中间空文本重建 WebView。
3. 用成功的结构化元数据区分缺失和失败，而非匹配任意 stderr：index 用 `--literal-pathspecs ls-files --stage -z -- <path>`（替代现有 isUnmerged 单次查询），按 stage 选 0/2/1 的对象 ID；tree 用 `--literal-pathspecs ls-tree -z <commit> -- <path>`，成功空输出才是该路径不存在。历史用已有 parentHash/commitStatus 判定无父/A/D，live/staged 需要 HEAD 时先 `rev-parse --verify --quiet HEAD` 区分正常 unborn 与非仓库/执行失败。路径按 NUL 原字节解析，不能 split 换行；HEAD/root 与同一轮 metadata 不借用别的面板旧快照。
4. 已找到的 blob 按固定对象 ID 调共享 runner 的 cat-file size/原字节入口，任何读取失败/坏 size 都是 error，不继续选另一 spec；size/content 不再分别解引用可变 index 路径。正常 index stage 缺失仍按 0 → 2 → 1 → HEAD 的现有语义选择，不把冲突 fallback 当旧版本兼容代码删除。保留两侧失败聚合、大小/二进制/UTF-8 策略与历史复用，不新增永久 blob cache。
5. 只对 P5-T1 命中的等待优化：先删除 Project 复用分支中的重复初始化读取/不可变历史重读，live metadata 实际变化仍刷新；工作树 UTF-8 扫描/解码明确后台，独立两侧至多有限并行，同侧 fallback 不并行。复用现有任务/选择入口，不同时跑新旧读取。
6. 删除旧计划的 batch 读取协议、版本能力探测与“远端不支持走原算法”双轨。若这些简单措施之后进程/往返仍主导，记录证据并另行回改设计，不在当前 task 默认增加 stdin 执行器、交互服务或大小/内容双阶段协议。保留现有每侧 cap、原始字节、symlink 和失败处理。
7. 在同 task 接入 DiffContentReader 并删除 DiffTab 旧 firstGitContent/gitContent/isUnmerged/readWorktreeFile 等迁出的读取算法及“任意失败是 missing”分支。共享字节上限归 reader，一个拥有者；不留旧 spec reader 作恢复兼容层，也不删除模型仍需的编辑性与保存保护。
8. Run（同 task 注册）：`bash scripts/check.sh diff-content workspace-identity git-execution`，后两类 App 检查按需先构建 Debug；DiffTab 用真实 App + 受控 backend 验证晚结果，临时 Git 为内容 oracle。diff-content 的编译输入为 WorkspaceBackend.swift、LocalWorkspaceBackend.swift、GitCommandExecution.swift、DiffContentReader.swift 与检查脚本，不拉入整份 GitStatusModel 或写 app-only 类型壳。

**验证:**
- 真实 temporary Git 检查：普通 live/staged/history、root commit 缺父、unborn、untracked、rename、删除、unmerged fallback；用 `git cat-file blob` 和磁盘原始字节作 oracle。
- 空、Unicode/组合字符、NUL、无效 UTF-8、恰好 5 MiB/多一字节、symlink 显示及禁止原子覆盖；区分真实缺失与启动/超时/读取失败/坏 size，坏结果不进入后续 fallback；两侧成功不能清掉另一侧错误。保留本地 raw-byte cap；远程 stdoutLimit 目前只在返回后截 prefix，不冒称传输本身已有同样有界能力。
- 真机：打开时终端/光标可操作；读取中切换与关闭；在途 reload 后进入 edit、输入、撤销、保存，WebView 文档和 undo 不重置，磁盘只有实际保存的内容。
- 共享 SSH 分支变化须用授权 fixture 做真实连接；模拟只用于可控延迟/乱序，不冒充端到端。
- 与 P5-T1 比较同一阶段及实际首屏，记录进程/往返变化和内存，收益不显著则不保留复杂 batch。

**提交边界:** 读取正确性、生产 reader 接入/旧路径删除与真实回归一个原子提交；未命中性能候选仍修正确性，只是不加入并行/预取等措施。

<a id="p5-t3"></a>
## P5-T3 收敛桥接编码与在途渲染

**类型 / 依赖:** 条件实现；依赖 P5-T1 的 Swift 编码或排队热点准入。P5-T4 的必修身份补丁可先提供同固定版本的包，没命中编码热点不强制移动 executor。

**Files:**
- Existing application call: `kero/Git/DiffViewerView.swift` 的 `DiffWebRoot`，只有公开 API 能解决时在这里最小调整。
- Only if required by measured hotspot: 固定版本源码副本 `Vendor/PierreDiffsSwift/`，重点 `Sources/PierreDiffsSwift/WebView/DiffWebViewCoordinator.swift`、`PierreMultiDiffView.swift` 与现有 `Tests/PierreDiffsSwiftTests/PierreDiffsSwiftTests.swift`。
- If vendored: `kero.xcodeproj/project.pbxproj`、其实际 resolved 消费者、`docs/DEPENDENCIES.md`。

**准入与实施:**
1. 优先现有 API/相等检查；当前编码函数和 pending queue 在依赖内部，无法用 caller 的另一层 Task 把它们移出 MainActor。只有这部分在 trace 中主导时才替换 remote package reference 为同一固定 revision 的本地包。保留许可证、署名、资源与必要上游说明，不复制 `.git/.build/node_modules`，不升级其他包。
2. 在实际拥有 `PierreMultiDiffInput` 的 coordinator 内，让纯 Sendable 输入的 JSON/base64/脚本构造后台执行；WebKit 调用与 UI 状态仍在 MainActor。不使用 `@unchecked Sendable` 搬运 WKWebView、coordinator 或可变编辑对象。
3. 新异步间隙需要一个 coordinator 自有的最小 render revision / 最新在途输入；只在真实 full-render 路径使用。旧编码不能晚到覆盖新内容；关闭后取消/丢弃结果；未 ready 时不累积多份大文本编码。已有无数据变更的 style/theme/font 增量命令继续复用。
4. 明确内容与选项的顺序：full render、随后 theme/style/overflow/font 和 scroll 必须落在最新内容上，旧 input 的选项不能覆盖更新设置。保留一个最新期望值即可，不建立通用命令总线或第二套文档状态。
5. `lastFiles/lastRenderOptions` 是依赖发送判定；编码/提交失败不能永远把未发送内容当成功。当前 Swift/JS error 只到 DiffLogger，不是 Kero 用户失败条，不能声称已有可见恢复。改异步时提供最小可见失败结果及用户触发重试/重载，不造自动重试框架；只区分该间隙需要的期望输入/已提交。
6. UTF-8 解码继续 `atob → Uint8Array → TextDecoder → JSON.parse`；不能直接按 Latin-1 解码。少一次复制只有测量证明且协议可保持才做，不换传输栈。
7. 同 task cleanup 清 pending 大输入/自有编码任务，替换 pending full-render 闭包队列时删除旧队列分支；非 full-render 的公开命令能力不顺手裁剪。只有关闭 trace 显示残留，才接通并验证实际 JS cleanup/worker/blob URL 释放，当前 Swift cleanup 未调用它，不能只证明 JS 存在一个函数。
8. 同一 task 完成本地 package 接入、补丁归属/固定来源/生成流程文档；不能在 checkout 留临时修复，不能把 plan 文件并入提交。

**验证:**
- 扩展同包现有 Swift Testing：实际 Sendable 编码结果保持默认选项、字体与 Unicode；控制旧/新编码完成顺序，验证最新输入/cleanup 的实际提交判定，不为 WKWebView 新增测试 protocol。
- If vendored: `swift test --package-path Vendor/PierreDiffsSwift`。现有 bridge 字符串/JSON 测试只证明构造，不等于网页绘制。
- 签名 Debug 真机快速切换内容/布局/主题/字体、重挂载、编辑与关闭；确认最后可见内容与选项对应，scroll/选择/undo 保留。使用中文、emoji、引号、反斜线和组合字符核对网页显示及最终保存。
- 原始 trace 检查 MainActor 编码占用下降、在途文本有界，以及实际首屏没有被异步往返拖慢。

**提交边界:** 实际补丁、本地包接入与依赖说明一个原子提交；没有准入不 vendoring、不提交。

<a id="p5-t4"></a>
## P5-T4 减少 JS 差异计算与内容扫描

**类型 / 依赖:** 内容身份必修 + 条件 JS 性能实现；依赖 P5-T1，P5-T3 未 vendoring 时本 task 独立接入同固定 revision。先闭环已复现的 identity 碰撞，parse 复用/调度仍以 trace 决定。

**Files:**
- If dependency patch is necessary: `Vendor/PierreDiffsSwift/scripts/src/diff-entry.js`、必要的固定版本 worker source，以及生成脚本的真实输出资源。
- Minimal pure helper only if needed: 同目录提取生产与检查共同使用的内容身份/复用函数；不复制算法写 oracle。
- Extend package checks: 同包 Swift Tests；JS 需要逻辑检查时使用 Node 内置 `node:test`，不装测试框架。
- 接入首次发生在本 task 时，包含 P5-T3 的项目与依赖归属文件。

**实施:**
1. 先用本轮 ` a` / `!@` fixture 在真实 CodeView/WKWebView 复现，检查内容、差异行和高亮最终更新；替换 hash 身份为当前 item 的明确内容变化 + 单调版本，并用于两侧 worker cacheKey。固定 hash 已被证据推翻，不能只升级 hash 位数或再套第二个 hash。公开 Swift API 没有传入 version 的入口，不通过改 fileID 重建编辑器规避。
2. 若复用值得采用，仅保留当前 CodeView items 的最新 descriptor 与已解析结果，更新/移除 item 同步失效。名称/oldName、语言、note、两侧内容、edit/review 语义都纳入比较，不能只按 path 或长度。
3. 同 task 删除 contentVersion 的旧扫描/hash 路径，不保留兼容 key；旧 cache 仅进程内，无磁盘迁移需求。内容未变只改 edit/review 时不改变 blob 内容键，避免无意义重新高亮；item 移除后不可重用旧版本串到另一文档。parse 前复用是否带来收益按 P5-T1 决定，没命中只修身份，不预建缓存层。
4. 若单次计算仍主导，只尝试 P5-T1 已核对固定版本支持的入口。未证明的自定义 diff worker/异常备用计算路径从本计划删除；现有高亮 pool 不可推定支持 parseDiff。没有可用入口则交付限制与具体 trace，再决定是否另行扩大设计，不暗中引入新引擎或双轨。
5. 若固定版本已有异步入口被证据选用，沿它的契约只传不可变值，复用最新 render 身份，旧结果不能覆盖新文本或 edit mode；真实失败应可见。当前 task 不为此预建另一套 worker、备用算法或无期限重试。
6. 保留虚拟化、内容相关 highlight cache key、null-origin 下 blob worker、编辑内的 undo/选择、字体行高和 layout/overflow/theme 增量设置。不要用禁用词级 diff、高亮或高亮预取来达成数字。
7. 生成 bundle 仍走原 `scripts/bundle.js`，保留 `ignoreAnnotations: true` 等防止空 worker 的约束，不手改 minified 资源。依赖/worker 新改动清理旧路径在同一 task 完成。

**验证:**
- 固定 `1.3.1` 的真实 `parseDiffFromFile` 作 oracle；至少包含已证实碰撞 ` a` → `!@` 的真实网页结果，而非只证明新 key 不同；同内容重复、同长度不同内容、Unicode、rename/语言变化、note ↔ diff、review ↔ edit、删除后重加均正确。
- JS 复用准入后断言实际 parse 次数与最新结果，不只比 cache key；已有异步入口入选才控制旧/新完成顺序，测试最终显示而非仅 postMessage。
- If JS changes: `npm ci --prefix Vendor/PierreDiffsSwift/scripts`；从 `Vendor/PierreDiffsSwift/scripts` 目录执行 `npm run build`（bundle.js 的输入/输出均相对 cwd）；运行已接入的 Node 检查，再 `swift test --package-path Vendor/PierreDiffsSwift`。核对 package-lock 的固定版本，不用 latest，也不在仓库根运行 bundle.js 导致写错资源位置。
- 签名 Debug 实际 WKWebView 测首次大 diff、反复选同 diff、改一侧再看、历史/冲突、滚动、两种布局和编辑保存；确认差异行/词、高亮与磁盘内容，不仅是 bundle 含某字符串。
- 测真实首屏/可见高亮、JS 最长主线程段、两进程内存、关闭后 worker；如果优化只移动等待却端到端变差，不保留该调度方案。

**提交边界:** 内容身份修复、实际检查、生成 bundle 及必要包接入一个原子提交；未命中性能候选仍修身份，不加入 parse 复用/调度。确有独立性能变更时先回改原子任务边界，不夹带未测措施。

## 阶段自审与交接

- P5-T1 未得出的实现选择必须先补证并更新 task；不能将条件候选默认全开。
- 每个被保留的优化都有真实首屏证据；外部依赖补丁有来源、接入与可再生成链。
- 路径/容量/错误/编辑保护和清理验证齐全，不以“异步已启动/事件已发”替代完成。
- 实际阶段结束进入审计并创建 `audit-p5.md`；规划阶段不预建。
